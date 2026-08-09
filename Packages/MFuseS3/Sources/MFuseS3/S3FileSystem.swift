import Foundation
import MFuseCore
import SotoCore
import SotoS3
import NIOCore
import NIOFoundationCompat
import os.log

/// S3 implementation of `RemoteFileSystem` using Soto.
public actor S3FileSystem: RemoteFileSystem {

    // Qualified: SotoCore re-exports swift-log's `Logger`, which would win here.
    private static let logger = os.Logger(
        subsystem: "com.lollipopkit.mfuse.s3",
        category: "S3FileSystem"
    )

    private let config: ConnectionConfig
    private let credential: MFuseCore.Credential
    private var awsClient: AWSClient?
    private var s3: S3?
    /// Deduplicates overlapping `connect()` calls. This is an actor, but `connect`
    /// suspends on the connectivity probe, so a second caller could otherwise enter and
    /// build a second client that overwrites — and leaks — the first.
    ///
    /// Carries the client the attempt published, so the caller that started it can tell its
    /// own connection from whatever happens to be published when it resumes.
    private var connectTask: Task<AWSClient, Error>?
    /// Callers waiting on someone else's `connectTask`, keyed so each can be resumed —
    /// or cancelled — on its own, and tagged with the attempt they joined.
    ///
    /// `disconnect()` clears `connectTask` while its attempt is still unwinding, so a
    /// replacement attempt can be registered before the old one finishes: without the
    /// tag, the old attempt's failure would be handed to callers waiting on the new one.
    private var connectWaiters: [UUID: (task: Task<AWSClient, Error>, continuation: CheckedContinuation<Void, Error>)] = [:]

    /// Test seam: replaces the connectivity probe so a connection attempt can be held at
    /// the exact suspension point where `disconnect()` interleaves. Never set in production.
    var connectivityProbe: (@Sendable () async throws -> Void)?

    /// Test seam: runs at the head of an attempt, before it reads or writes anything the
    /// actor publishes, so an attempt can be held there while its replacement connects.
    /// Never set in production.
    var attemptStartHook: (@Sendable () async -> Void)?

    /// Test seam: whether a connection attempt is still registered for deduplication.
    var hasPendingConnectTask: Bool { connectTask != nil }

    /// Test seam: how many callers are parked on an attempt someone else started.
    var pendingConnectWaiterCount: Int { connectWaiters.count }

    public var isConnected: Bool { s3 != nil }

    public init(config: ConnectionConfig, credential: MFuseCore.Credential) {
        self.config = config
        self.credential = credential
    }

    func setConnectivityProbe(_ probe: (@Sendable () async throws -> Void)?) {
        connectivityProbe = probe
    }

    func setAttemptStartHook(_ hook: (@Sendable () async -> Void)?) {
        attemptStartHook = hook
    }

    // MARK: - Config Helpers

    // Resolved in MFuseCore like the endpoint, so the bucket shown in the UI is the one
    // requests are signed for — and a whitespace-only value still trips the guard in
    // `performConnect()` instead of reaching S3 as a blank bucket.
    private var bucket: String { config.s3Bucket ?? "" }
    // Resolved in MFuseCore too, so what the UI compares — and decides a synced edit by —
    // is what requests are actually signed for.
    private var region: String { config.s3Region }
    private var customEndpoint: String? { config.s3Endpoint }
    private var pathStyle: Bool { config.s3UsesPathStyle }

    private func isNotFoundError(_ error: Error) -> Bool {
        if let awsError = error as? AWSErrorType {
            let normalizedCode = awsError.errorCode.lowercased()
            return normalizedCode == "nosuchkey"
                || normalizedCode == "notfound"
                || awsError.context?.responseCode.code == 404
        }

        return false
    }

    // MARK: - Lifecycle

    public func connect() async throws {
        while true {
            if awsClient != nil, s3 != nil {
                return
            }
            if let inFlight = connectTask {
                do {
                    // Retries when the attempt ended before this caller could join it:
                    // there is then nothing left to wait for, and the loop re-decides what
                    // to do.
                    guard try await waitForConnectAttempt(inFlight) else { continue }
                } catch is CancellationError where !Task.isCancelled {
                    // Someone else's cancellation: the caller that started this attempt
                    // withdrew in the window before this one had registered as a joiner,
                    // so `relinquishConnectAttempt` found nobody waiting and cancelled the
                    // shared task. This caller never withdrew, and answering it with a
                    // cancellation reports the connection it asked for as deliberately
                    // stopped. The loop starts one of its own instead.
                    continue
                }
                return
            }

            let task = Task { try await performConnect() }
            connectTask = task
            // `disconnect()` can clear this while we are suspended below, after which
            // another caller registers its own task. Clearing unconditionally would drop
            // that newer task and let the next caller start a second, overlapping attempt.
            defer {
                if connectTask == task {
                    connectTask = nil
                }
            }
            let published: AWSClient
            do {
                // Cancellation does not reach into an unstructured task, so without this a
                // cancelled caller would keep waiting for a probe that then publishes a
                // client nobody is left to disconnect. It is forwarded through
                // `relinquishConnectAttempt` rather than applied directly: this caller
                // started the probe, but callers that joined it since are waiting on the
                // same task and were never cancelled themselves.
                published = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    Task { await self.relinquishConnectAttempt(task) }
                }
            } catch {
                // Runs before the `defer` above clears `connectTask`, so a caller that
                // joins cannot observe a live attempt whose result was already handed out.
                resumeConnectWaiters(of: task, with: .failure(error))
                throw error
            }
            // A `disconnect()` can land between the attempt publishing its client and this
            // caller resuming here. Reporting success then hands every caller a session
            // that has already been shut down, and each of them goes on to fail on its
            // first request instead of retrying the connection.
            //
            // Compared by identity, not merely for presence: a connection that replaced the
            // torn-down one belongs to the caller that asked for it, and claiming it here
            // would answer this attempt — and everyone who joined it — with a success it
            // never achieved, leaving them to shut down a session someone else is using.
            guard awsClient === published, s3 != nil else {
                let interrupted = CancellationError()
                resumeConnectWaiters(of: task, with: .failure(interrupted))
                throw interrupted
            }
            // Joiners first, then this caller's own answer. A cancellation that arrived
            // while the probe was still running left the probe to them, so the connection
            // is established and published and only this caller no longer wants it —
            // reporting the cancellation is what stops it acting on one it never took.
            let resumedJoiners = resumeConnectWaiters(of: task, with: .success(()))
            guard Task.isCancelled else { return }
            // With no joiner to take it, the connection goes down with the caller that
            // withdrew rather than being handed back as a success. Reporting one relies on
            // that caller noticing its own cancellation and disconnecting anyway — nothing
            // makes it, and a client left open here stays open until the actor is released,
            // which is the release Soto asserts on.
            if !resumedJoiners, awsClient === published {
                awsClient = nil
                s3 = nil
                await Self.shutdown(published)
            }
            throw CancellationError()
        }
    }

    /// Give up this caller's interest in the probe it started.
    ///
    /// Cancelling the shared task outright would take the connection down for callers that
    /// joined it and were never cancelled; the starter stays on `task.value` either way, so
    /// they are still resumed when it finishes.
    private func relinquishConnectAttempt(_ task: Task<AWSClient, Error>) {
        let hasJoiners = connectWaiters.values.contains { $0.task == task }
        guard !hasJoiners else { return }
        task.cancel()
    }

    /// Wait for the attempt another caller started, without waiting past *this* caller's
    /// own cancellation.
    ///
    /// `Task.value` resumes only when the awaited task finishes: a cancelled joiner would
    /// otherwise stay suspended for the rest of the probe and then report that probe's
    /// result as its own. Cancelling the shared task instead is not an option — the
    /// caller that started it is still waiting on it — so joiners are parked on their own
    /// continuation and resumed individually.
    ///
    /// Returns `false` when the attempt ended before this caller could join it.
    private func waitForConnectAttempt(_ task: Task<AWSClient, Error>) async throws -> Bool {
        let waiterID = UUID()
        var joined = true
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    // The handler below has nothing to resume until the continuation is
                    // registered, so a cancellation that lands first is answered here.
                    continuation.resume(throwing: CancellationError())
                } else if connectTask == task {
                    connectWaiters[waiterID] = (task: task, continuation: continuation)
                } else {
                    joined = false
                    continuation.resume()
                }
            }
        } onCancel: {
            Task { await self.cancelConnectWaiter(waiterID) }
        }
        // The handler above removes this waiter through a task hop, so an attempt that
        // finished in the same turn can resume it first and leave that hop with nothing to
        // cancel. Without this check the cancellation would simply be lost and a caller
        // that gave up would be handed a connection anyway.
        try Task.checkCancellation()
        return joined
    }

    private func cancelConnectWaiter(_ waiterID: UUID) {
        connectWaiters.removeValue(forKey: waiterID)?.continuation.resume(throwing: CancellationError())
    }

    /// Returns whether anyone was waiting.
    @discardableResult
    private func resumeConnectWaiters(
        of task: Task<AWSClient, Error>,
        with result: Result<Void, Error>
    ) -> Bool {
        let waiters = connectWaiters.filter { $0.value.task == task }
        for waiterID in waiters.keys {
            connectWaiters.removeValue(forKey: waiterID)
        }
        for waiter in waiters.values {
            waiter.continuation.resume(with: result)
        }
        return !waiters.isEmpty
    }

    /// Returns the client it published, which is what tells the caller that started this
    /// attempt whether the connection it is about to report is still its own.
    private func performConnect() async throws -> AWSClient {
        if let attemptStartHook {
            await attemptStartHook()
        }

        // Creating the task does not run its body, so an attempt can be cancelled and
        // replaced before it reaches its first line. Checked before anything below reads
        // the published client: `disconnect()` cancels the attempt it de-registers in the
        // turn that clears it, and only a cleared attempt can be replaced, so an attempt
        // that finds itself cancelled here has been superseded — and what is published by
        // then belongs to the attempt that replaced it. Tearing that down as this
        // attempt's own leftover takes a live connection from the caller that established
        // it, which then fails its identity check and reports a connection it made as
        // interrupted.
        try Task.checkCancellation()

        // A previous attempt can leave a client behind — the File Provider extension
        // times out and retries `connect()`, and Soto asserts in `AWSClient.deinit` if a
        // client is released without being shut down.
        if let stale = awsClient {
            await Self.shutdown(stale)
            awsClient = nil
            s3 = nil
        }

        guard let keyID = credential.accessKeyID,
              let secret = credential.secretAccessKey else {
            throw RemoteFileSystemError.authenticationFailed
        }
        guard !bucket.isEmpty else {
            throw RemoteFileSystemError.connectionFailed("S3 bucket name is required")
        }

        let client = AWSClient(credentialProvider: .static(accessKeyId: keyID, secretAccessKey: secret))

        // Path style only reaches the wire for a custom endpoint: Soto's S3 middleware
        // rewrites every request to an `amazonaws.com` host into virtual-host form
        // whatever the options say, so there is nothing to pass on the AWS path. The
        // editor offers the toggle only alongside an endpoint for the same reason.
        let serviceConfig: S3
        if let endpoint = customEndpoint, !endpoint.isEmpty {
            serviceConfig = S3(
                client: client,
                region: .init(rawValue: region),
                endpoint: endpoint,
                options: pathStyle ? [] : .s3ForceVirtualHost
            )
        } else {
            serviceConfig = S3(
                client: client,
                region: .init(rawValue: region)
            )
        }

        do {
            if let connectivityProbe {
                try await connectivityProbe()
            } else {
                // Test connectivity by listing with max 1 key
                let request = S3.ListObjectsV2Request(bucket: bucket, maxKeys: 1)
                _ = try await serviceConfig.listObjectsV2(request)
            }
        } catch {
            await Self.shutdown(client)
            // Cancellation is not a connection failure; misreporting it makes callers
            // retry work that was deliberately stopped. A cancelled request surfaces as
            // an SDK transport error rather than a `CancellationError`, so report the
            // cancellation itself — callers only test for `CancellationError`.
            if error is CancellationError {
                throw error
            }
            if Task.isCancelled {
                throw CancellationError()
            }
            // Raw SDK errors are not RemoteFileSystemError, so callers such as the File
            // Provider extension cannot classify them and fall back to "server
            // unreachable" even for bad credentials.
            throw Self.mapConnectionError(error, bucket: bucket, endpoint: customEndpoint)
        }

        // `disconnect()` may have run while the probe above was suspended; publishing now
        // would resurrect a connection the caller already tore down.
        guard !Task.isCancelled else {
            await Self.shutdown(client)
            throw CancellationError()
        }

        self.awsClient = client
        self.s3 = serviceConfig
        return client
    }

    /// Every path that drops an `AWSClient` must go through here: Soto asserts in
    /// `AWSClient.deinit` when a client is released without a shutdown, which crashes
    /// the File Provider extension in debug builds.
    private static func shutdown(_ client: AWSClient) async {
        do {
            try await client.shutdown()
        } catch {
            // `alreadyShutdown` is benign, and nothing else here is actionable.
        }
    }

    /// AWS error codes that mean the credentials, not the endpoint, are the problem.
    private static let authenticationIndicators: Set<String> = [
        "accessdenied",
        "invalidaccesskeyid",
        "signaturedoesnotmatch",
        "invalidsecurity",
        "notauthorized",
        "unauthorized"
    ]

    /// Classify an SDK error raised while establishing the connection.
    ///
    /// Credential problems must surface as `.authenticationFailed` so the UI prompts for
    /// new keys instead of blaming the network.
    static func mapConnectionError(
        _ error: Error,
        bucket: String,
        endpoint: String?
    ) -> RemoteFileSystemError {
        if let remoteError = error as? RemoteFileSystemError {
            return remoteError
        }

        // Classify from the structured answer wherever the SDK provides one: it is a
        // diagnosis, where the scan below is only a reading of prose.
        if let awsError = error as? AWSErrorType {
            if let classified = classifyAWSError(
                code: awsError.errorCode,
                httpStatus: awsError.context?.responseCode.code,
                bucket: bucket,
                error: error
            ) {
                return classified
            }
        }

        // Fallback for SDK errors that carry no structured code.
        let description = Self.withoutConfiguredAddress(
            String(describing: error),
            bucket: bucket,
            endpoint: endpoint
        )
        let normalized = description.lowercased()
        if Self.authenticationIndicators.contains(where: { normalized.contains($0) }) {
            return .authenticationFailed
        }
        if normalized.contains("nosuchbucket") {
            return missingBucketError(bucket: bucket)
        }
        return unreachableEndpointError(bucket: bucket, error: error)
    }

    /// The description with the address the request was aimed at taken out of it.
    ///
    /// The scan reads an unstructured description for words like "unauthorized", and a
    /// transport failure spells out what it could not reach: a DNS or TCP failure against
    /// `https://unauthorized.internal.example` carries no error code to classify it by, so
    /// the endpoint's own name was read as a rejection of the keys and sent the user to
    /// re-enter credentials that work. The bucket goes with it — it names a target too, and
    /// virtual-host addressing puts it in the hostname.
    private static func withoutConfiguredAddress(
        _ description: String,
        bucket: String,
        endpoint: String?
    ) -> String {
        let host = endpoint.flatMap { URLComponents(string: $0)?.host }
        var stripped = description
        for token in [endpoint, host, bucket].compactMap({ $0 }) where !token.isEmpty {
            stripped = stripped.replacingOccurrences(of: token, with: " ", options: .caseInsensitive)
        }
        return stripped
    }

    /// Classify an SDK error from its structured parts, or `nil` to fall through to the
    /// description scan.
    ///
    /// Taken separately so the HTTP answers can be tested: `AWSErrorContext` cannot be
    /// constructed outside SotoCore.
    static func classifyAWSError(
        code rawCode: String,
        httpStatus: UInt?,
        bucket: String,
        error: Error
    ) -> RemoteFileSystemError? {
        let code = rawCode.lowercased()
        if Self.authenticationIndicators.contains(code) {
            return .authenticationFailed
        }

        // The status is the part every S3-compatible server agrees on; the XML code beside
        // it is vendor-specific, and an empty one is common. A 401 or 403 is about the keys
        // or the access policy whatever the body calls it, and telling the user to check
        // the network instead sends them nowhere.
        if let httpStatus {
            if httpStatus == 401 || httpStatus == 403 {
                return .authenticationFailed
            }
            // The probe is a list against the bucket, so a not-found answer is about the
            // bucket — the same spread `isNotFoundError` already handles for objects.
            if httpStatus == 404 {
                return missingBucketError(bucket: bucket)
            }
        }

        if code == "nosuchbucket" || code == "notfound" {
            return missingBucketError(bucket: bucket)
        }
        if !code.isEmpty {
            // Any other structured code is the SDK's own diagnosis, and it outranks
            // whatever the description happens to spell: falling through would let a
            // `RequestTimeout` naming a redirect target or a proxy that reads like an
            // auth failure be reported as bad keys. Only the configured address is taken
            // out of the scan below, and a description can name more than that.
            return unreachableEndpointError(bucket: bucket, error: error)
        }
        return nil
    }

    /// The bucket identifier stays out of the message: connection errors are surfaced
    /// through `LocalizedError` and logged with public privacy by both the app and the
    /// File Provider bootstrap, which is why the log below marks it private.
    private static func missingBucketError(bucket: String) -> RemoteFileSystemError {
        Self.logger.error(
            "S3 bucket \(bucket, privacy: .private) does not exist"
        )
        return .connectionFailed("The configured S3 bucket does not exist")
    }

    private static func unreachableEndpointError(
        bucket: String,
        error: Error
    ) -> RemoteFileSystemError {
        // The raw description can carry response diagnostics from a custom endpoint, and
        // error descriptions are logged with public privacy — keep it out of the message.
        Self.logger.error(
            "S3 connection to bucket \(bucket, privacy: .private) failed: \(String(describing: error), privacy: .private)"
        )
        return .connectionFailed("Could not reach the S3 endpoint")
    }

    public func disconnect() async throws {
        // Stop any probe still in flight so it cannot publish a client afterwards.
        let inFlight = connectTask
        inFlight?.cancel()
        connectTask = nil
        let client = awsClient
        // Clear the references first so a failing shutdown cannot leave a client that
        // callers still consider connected — and before the wait below, so an attempt
        // starting during it keeps the client it publishes.
        awsClient = nil
        s3 = nil
        if let client {
            await Self.shutdown(client)
        }
        // Awaited, not just cancelled: the cancelled attempt shuts down the client it
        // built on its way out, and returning before that lets a replacement attempt
        // allocate a second client while the first one is still open.
        _ = await inFlight?.result
    }

    // MARK: - Enumeration

    public func enumerate(at path: RemotePath) async throws -> [RemoteItem] {
        let s3 = try requireS3()
        let prefix = s3Key(for: path, isDirectory: true)

        var fileItems: [RemoteItem] = []
        var directoryItems: [RemoteItem] = []
        var continuationToken: String?

        repeat {
            let request = S3.ListObjectsV2Request(
                bucket: bucket,
                continuationToken: continuationToken,
                delimiter: "/",
                prefix: prefix
            )
            let response = try await s3.listObjectsV2(request)

            // Directories (common prefixes)
            if let prefixes = response.commonPrefixes {
                for commonPrefix in prefixes {
                    guard let fullPrefix = commonPrefix.prefix else { continue }
                    let name = directoryName(from: fullPrefix, parentPrefix: prefix)
                    guard !name.isEmpty else { continue }
                    let childPath = path.appending(name)
                    directoryItems.append(RemoteItem(
                        path: childPath,
                        type: .directory,
                        size: 0,
                        modificationDate: Date()
                    ))
                }
            }

            // Files (objects that are not the prefix itself)
            if let contents = response.contents {
                for obj in contents {
                    guard let key = obj.key else { continue }
                    guard key != prefix else { continue } // skip the directory marker itself
                    let name = fileName(from: key, parentPrefix: prefix)
                    guard !name.isEmpty && !name.contains("/") else { continue }
                    let childPath = path.appending(name)
                    fileItems.append(RemoteItem(
                        path: childPath,
                        type: .file,
                        size: UInt64(obj.size ?? 0),
                        modificationDate: obj.lastModified ?? Date()
                    ))
                }
            }

            continuationToken = response.nextContinuationToken
        } while continuationToken != nil

        // An object and a prefix can carry the same name: a bucket holding `foo` and
        // `foo/bar` lists `foo` in contents and `foo/` in the common prefixes. `itemInfo`
        // resolves that name to the object, so listing both put two entries with the same
        // path — one file, one directory — into the namespace, and the operations that
        // followed acted on whichever one they were handed.
        let filePaths = Set(fileItems.map(\.path.absoluteString))
        return fileItems + directoryItems.filter { !filePaths.contains($0.path.absoluteString) }
    }

    public func itemInfo(at path: RemotePath) async throws -> RemoteItem {
        let s3 = try requireS3()

        // The root of the mount is the namespace everything else hangs off, whatever the
        // bucket happens to hold at the key it maps to. A configured remote path of
        // `tenant` alongside an object literally named `tenant` otherwise answered the HEAD
        // below and reported the mount's own root as a file.
        guard !path.isRoot else {
            return RemoteItem(
                path: path,
                type: .directory,
                size: 0,
                modificationDate: Date()
            )
        }

        // Try as file first
        let fileKey = s3Key(for: path, isDirectory: false)
        do {
            let request = S3.HeadObjectRequest(bucket: bucket, key: fileKey)
            let head = try await s3.headObject(request)
            return RemoteItem(
                path: path,
                type: .file,
                size: UInt64(head.contentLength ?? 0),
                modificationDate: head.lastModified ?? Date()
            )
        } catch {
            guard isNotFoundError(error) else {
                throw error
            }

            // Try as directory (check if prefix has children)
            let dirPrefix = s3Key(for: path, isDirectory: true)
            let listReq = S3.ListObjectsV2Request(bucket: bucket, maxKeys: 1, prefix: dirPrefix)
            let listResp = try await s3.listObjectsV2(listReq)
            if (listResp.keyCount ?? 0) > 0 {
                return RemoteItem(
                    path: path,
                    type: .directory,
                    size: 0,
                    modificationDate: Date()
                )
            }
            throw RemoteFileSystemError.notFound(path)
        }
    }

    // MARK: - Read

    public func readFile(at path: RemotePath) async throws -> Data {
        let s3 = try requireS3()
        let key = s3Key(for: path, isDirectory: false)
        let request = S3.GetObjectRequest(bucket: bucket, key: key)
        let response = try await s3.getObject(request)
        let buffer = try await response.body.collect(upTo: .max)
        return Data(buffer: buffer)
    }

    public func readFile(at path: RemotePath, offset: UInt64, length: UInt32) async throws -> Data {
        guard length > 0 else {
            return Data()
        }

        let s3 = try requireS3()
        let key = s3Key(for: path, isDirectory: false)
        let (sum, overflow) = offset.addingReportingOverflow(UInt64(length))
        let end = overflow ? UInt64.max : sum - 1
        let request = S3.GetObjectRequest(
            bucket: bucket,
            key: key,
            range: "bytes=\(offset)-\(end)"
        )
        let response = try await s3.getObject(request)
        // Collected with slack and then cut to the requested length: a server that ignores
        // or overshoots the Range header answers with more than was asked for, and the
        // caller assembles these reads at fixed offsets — the extra bytes would land inside
        // the next chunk's interval and corrupt the file being downloaded.
        let buffer = try await response.body.collect(upTo: Int(length) + 1024)
        let data = Data(buffer: buffer)
        guard data.count > Int(length) else { return data }
        return Data(data.prefix(Int(length)))
    }

    // MARK: - Write

    public func writeFile(at path: RemotePath, data: Data) async throws {
        let s3 = try requireS3()
        let key = s3Key(for: path, isDirectory: false)
        let request = S3.PutObjectRequest(
            body: AWSHTTPBody(bytes: data),
            bucket: bucket,
            key: key
        )
        _ = try await s3.putObject(request)
    }

    public func createFile(at path: RemotePath, data: Data) async throws {
        let s3 = try requireS3()
        let key = s3Key(for: path, isDirectory: false)
        let request = S3.PutObjectRequest(
            body: AWSHTTPBody(bytes: data),
            bucket: bucket,
            ifNoneMatch: "*",
            key: key
        )

        do {
            _ = try await s3.putObject(request)
        } catch let error as AWSErrorType {
            // S3 signals an If-None-Match precondition failure with HTTP 412.
            if let responseCode = error.context?.responseCode.code, responseCode == 412 {
                throw RemoteFileSystemError.alreadyExists(path)
            }
            throw error
        } catch {
            throw error
        }
    }

    // MARK: - Mutations

    public func createDirectory(at path: RemotePath) async throws {
        let s3 = try requireS3()
        let key = s3Key(for: path, isDirectory: true)
        let request = S3.PutObjectRequest(
            body: AWSHTTPBody(),
            bucket: bucket,
            key: key
        )
        _ = try await s3.putObject(request)
    }

    public func delete(at path: RemotePath) async throws {
        let s3 = try requireS3()

        // The object at the exact key first, and on its own: a bucket can hold both `foo`
        // and `foo/bar`, and `itemInfo` resolves `/foo` to the object — that is the file the
        // namespace shows and the only thing the caller asked to delete. Sweeping the prefix
        // as well took `foo/bar` with it, which nothing displayed under the item being
        // deleted.
        let exactKey = s3Key(for: path, isDirectory: false)
        if !exactKey.isEmpty, try await objectExists(key: exactKey, using: s3) {
            _ = try await s3.deleteObject(S3.DeleteObjectRequest(bucket: bucket, key: exactKey))
            return
        }

        // Check if it's a directory with contents
        let dirPrefix = s3Key(for: path, isDirectory: true)
        var continuationToken: String?
        var deletedDirectoryObjects = false

        repeat {
            let listReq = S3.ListObjectsV2Request(
                bucket: bucket,
                continuationToken: continuationToken,
                prefix: dirPrefix
            )
            let listResp = try await s3.listObjectsV2(listReq)

            let objects = (listResp.contents ?? [])
                .compactMap { $0.key }
                .map { S3.ObjectIdentifier(key: $0) }

            if !objects.isEmpty {
                let deleteReq = S3.DeleteObjectsRequest(
                    bucket: bucket,
                    delete: S3.Delete(objects: objects)
                )
                let deleteResp = try await s3.deleteObjects(deleteReq)
                // A bulk delete answers 200 with a per-object error list, so an object a
                // policy or a legal hold refused is reported in the body rather than by the
                // request failing. Discarding it reported a directory as deleted with part
                // of it still there — and let `move` go on to delete the source of a copy
                // that had not been made.
                if let failure = deleteResp.errors?.first {
                    throw RemoteFileSystemError.operationFailed(
                        "Failed to delete \(failure.key ?? path.absoluteString): \(failure.message ?? failure.code ?? "unknown S3 error")"
                    )
                }
                deletedDirectoryObjects = true
            }

            continuationToken = listResp.nextContinuationToken
        } while continuationToken != nil

        // Nothing under the prefix and no object at the exact key — checked above — is a
        // path that is not there at all.
        if !deletedDirectoryObjects {
            throw RemoteFileSystemError.notFound(path)
        }
    }

    /// Whether an object is stored under exactly this key.
    private func objectExists(key: String, using s3: S3) async throws -> Bool {
        do {
            _ = try await s3.headObject(.init(bucket: bucket, key: key))
            return true
        } catch {
            guard isNotFoundError(error) else {
                throw error
            }
            return false
        }
    }

    public func move(from source: RemotePath, to destination: RemotePath) async throws {
        let s3 = try requireS3()
        let sourceItem = try await itemInfo(at: source)
        try ensureDestinationIsOutside(sourceItem, source: source, destination: destination)
        try await ensureDestinationDoesNotExist(destination, using: s3)
        try await copyItem(sourceItem, from: source, to: destination, using: s3)
        try await delete(at: source)
    }

    public func copy(from source: RemotePath, to destination: RemotePath) async throws {
        let s3 = try requireS3()
        let sourceItem = try await itemInfo(at: source)
        try ensureDestinationIsOutside(sourceItem, source: source, destination: destination)
        try await ensureDestinationDoesNotExist(destination, using: s3)
        try await copyItem(sourceItem, from: source, to: destination, using: s3)
    }

    // MARK: - Helpers

    private func copyItem(_ sourceItem: RemoteItem, from source: RemotePath, to destination: RemotePath, using s3: S3) async throws {

        if sourceItem.isDirectory {
            let sourcePrefix = s3Key(for: source, isDirectory: true)
            let destinationPrefix = s3Key(for: destination, isDirectory: true)
            var continuationToken: String?

            repeat {
                let listReq = S3.ListObjectsV2Request(
                    bucket: bucket,
                    continuationToken: continuationToken,
                    prefix: sourcePrefix
                )
                let listResp = try await s3.listObjectsV2(listReq)

                for key in (listResp.contents ?? []).compactMap(\.key) {
                    let suffix = String(key.dropFirst(sourcePrefix.count))
                    try await copyObject(
                        fromKey: key,
                        toKey: destinationPrefix + suffix,
                        destination: destination.appending(suffix),
                        using: s3
                    )
                }

                continuationToken = listResp.nextContinuationToken
            } while continuationToken != nil
            return
        }

        try await copyObject(
            fromKey: s3Key(for: source, isDirectory: false),
            toKey: s3Key(for: destination, isDirectory: false),
            destination: destination,
            using: s3
        )
    }

    /// Refuse a directory whose destination is itself or lies inside it.
    ///
    /// There is no rename on S3: a directory is copied object by object, and the listing it
    /// walks has the source prefix while every object it writes lands under that same
    /// prefix. Pagination therefore reaches what the copy has just written and copies it
    /// again, deeper each time; `move` then deletes the source, which now contains the
    /// destination it created.
    private func ensureDestinationIsOutside(
        _ sourceItem: RemoteItem,
        source: RemotePath,
        destination: RemotePath
    ) throws {
        guard sourceItem.isDirectory else { return }
        let sourcePrefix = s3Key(for: source, isDirectory: true)
        let destinationPrefix = s3Key(for: destination, isDirectory: true)
        guard destinationPrefix.hasPrefix(sourcePrefix) else { return }
        throw RemoteFileSystemError.operationFailed(
            "Cannot copy or move \(source.absoluteString) into itself"
        )
    }

    private func requireS3() throws -> S3 {
        guard let s3 = s3 else {
            throw RemoteFileSystemError.notConnected
        }
        return s3
    }

    private func ensureDestinationDoesNotExist(_ destination: RemotePath, using s3: S3) async throws {
        let fileKey = s3Key(for: destination, isDirectory: false)
        if try await objectExists(key: fileKey, using: s3) {
            throw RemoteFileSystemError.alreadyExists(destination)
        }

        let directoryPrefix = s3Key(for: destination, isDirectory: true)
        let listRequest = S3.ListObjectsV2Request(
            bucket: bucket,
            maxKeys: 1,
            prefix: directoryPrefix
        )
        let listResponse = try await s3.listObjectsV2(listRequest)
        if (listResponse.keyCount ?? 0) > 0 {
            throw RemoteFileSystemError.alreadyExists(destination)
        }
    }

    /// Copy one object, refusing to write over a key that already holds one.
    ///
    /// `ensureDestinationDoesNotExist` answers for the destination as it was when it looked,
    /// and there is no lock between that answer and this request: another client creating
    /// the destination in between had it overwritten — and for `move`, the source was then
    /// deleted, so what that client wrote was gone with nothing left to recover it from.
    /// `If-None-Match: *` moves the check to the server, the way `createFile` does it for
    /// PutObject. A server that does not implement the condition is no worse off than
    /// before.
    private func copyObject(
        fromKey srcKey: String,
        toKey dstKey: String,
        destination: RemotePath,
        using s3: S3
    ) async throws {
        guard let encodedSrcKey = percentEncodeCopySourceKey(srcKey) else {
            throw RemoteFileSystemError.operationFailed("Failed to percent-encode S3 copy source key")
        }
        let request = S3.CopyObjectRequest(
            bucket: bucket,
            copySource: "\(bucket)/\(encodedSrcKey)",
            ifNoneMatch: "*",
            key: dstKey
        )

        do {
            _ = try await s3.copyObject(request)
        } catch let error as AWSErrorType {
            // S3 signals an If-None-Match precondition failure with HTTP 412.
            if let responseCode = error.context?.responseCode.code, responseCode == 412 {
                throw RemoteFileSystemError.alreadyExists(destination)
            }
            throw error
        }
    }

    /// Convert RemotePath to S3 key. Directory keys end with "/".
    private func s3Key(for path: RemotePath, isDirectory: Bool) -> String {
        // Whitespace first: the editor writes the field as typed, so a path of spaces — or
        // one padded around a real prefix — rooted every request at a prefix nothing is
        // stored under. `ConnectionConfig.s3Bucket` reads a blank bucket the same way.
        let base = config.remotePath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let relative = path.components.joined(separator: "/")

        var key: String
        if base.isEmpty {
            key = relative
        } else if relative.isEmpty {
            key = base
        } else {
            key = base + "/" + relative
        }

        if isDirectory && !key.isEmpty && !key.hasSuffix("/") {
            key += "/"
        }
        if isDirectory && key.isEmpty {
            key = "" // root listing uses empty prefix
        }
        return key
    }

    private func directoryName(from prefix: String, parentPrefix: String) -> String {
        var name = prefix
        if name.hasPrefix(parentPrefix) {
            name = String(name.dropFirst(parentPrefix.count))
        }
        if name.hasSuffix("/") {
            name = String(name.dropLast())
        }
        return name
    }

    private func fileName(from key: String, parentPrefix: String) -> String {
        var name = key
        if name.hasPrefix(parentPrefix) {
            name = String(name.dropFirst(parentPrefix.count))
        }
        return name
    }

    private func percentEncodeCopySourceKey(_ key: String) -> String? {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let components = key.split(separator: "/", omittingEmptySubsequences: false)
        let encodedComponents = components.compactMap {
            String($0).addingPercentEncoding(withAllowedCharacters: allowedCharacters)
        }
        guard encodedComponents.count == components.count else {
            return nil
        }
        return encodedComponents.joined(separator: "/")
    }
}
