import Testing
import MFuseCore
import SotoCore

@testable import MFuseS3

@Test func placeholder() async throws {
    // Integration tests require real S3 credentials
}

/// Credential problems must not be reported as an unreachable server, or the UI asks the
/// user to check the network instead of the keys.
@Test func credentialErrorsMapToAuthenticationFailed() {
    for code in [
        "AccessDenied",
        "InvalidAccessKeyId",
        "SignatureDoesNotMatch",
        "InvalidSecurity",
        "NotAuthorized"
    ] {
        let mapped = S3FileSystem.mapConnectionError(StubError(text: code), bucket: "b")
        guard case .authenticationFailed = mapped else {
            Issue.record("\(code) mapped to \(mapped) instead of .authenticationFailed")
            continue
        }
    }
}

/// The bucket is identified as missing rather than unreachable, but the identifier itself
/// stays out of the message: connection errors are surfaced through `LocalizedError` and
/// logged with public privacy by both the app and the File Provider bootstrap.
@Test func missingBucketIsReportedWithoutNamingIt() {
    let mapped = S3FileSystem.mapConnectionError(StubError(text: "NoSuchBucket"), bucket: "photos")
    guard case .connectionFailed(let message) = mapped else {
        Issue.record("expected .connectionFailed, got \(mapped)")
        return
    }
    #expect(!message.contains("photos"))
    #expect(message.contains("bucket"))
    #expect(message != S3FileSystem.mapConnectionError(StubError(text: "boom"), bucket: "photos").errorDescription)
}

/// SDK descriptions can carry response diagnostics from a custom endpoint, and error
/// descriptions are logged with public privacy — they must not reach the message.
@Test func unclassifiedErrorsDoNotLeakTheSDKDescription() {
    let secret = "x-amz-signature=deadbeef"
    let mapped = S3FileSystem.mapConnectionError(StubError(text: secret), bucket: "b")
    guard case .connectionFailed(let message) = mapped else {
        Issue.record("expected .connectionFailed, got \(mapped)")
        return
    }
    #expect(!message.contains(secret))
}

/// A RemoteFileSystemError raised inside connect() is already classified.
@Test func alreadyClassifiedErrorsPassThrough() {
    let mapped = S3FileSystem.mapConnectionError(
        RemoteFileSystemError.authenticationFailed,
        bucket: "b"
    )
    guard case .authenticationFailed = mapped else {
        Issue.record("expected .authenticationFailed, got \(mapped)")
        return
    }
}

/// `connect()` deduplicates overlapping attempts through `connectTask`. A first attempt
/// finishing after `disconnect()` must not deregister the attempt that replaced it, or the
/// next caller opens a second, overlapping connection.
@Test func completingConnectAttemptKeepsTheAttemptThatReplacedIt() async throws {
    let coordinator = ProbeCoordinator()
    let fileSystem = S3FileSystem(
        config: ConnectionConfig(
            name: "s3",
            backendType: .s3,
            host: "s3.example.com",
            parameters: ["bucket": "bucket", "region": "us-east-1"]
        ),
        credential: MFuseCore.Credential(accessKeyID: "key", secretAccessKey: "secret")
    )
    await fileSystem.setConnectivityProbe {
        await coordinator.probeStarted()
        try await Task.sleep(nanoseconds: 60_000_000_000)
    }

    let first = Task { try await fileSystem.connect() }
    await coordinator.waitForProbes(count: 1)

    // Cancels the first probe and clears the registered attempt.
    try await fileSystem.disconnect()

    let second = Task { try await fileSystem.connect() }
    await coordinator.waitForProbes(count: 2)

    _ = await first.result
    #expect(await fileSystem.hasPendingConnectTask)

    // Only `disconnect()` reaches the probe: `connect()` awaits an unstructured task, so
    // cancelling `second` would leave the second probe sleeping.
    try await fileSystem.disconnect()
    _ = await second.result
}

/// The probe runs in an unstructured task, which cancellation does not reach on its own.
/// Without propagation the caller waits for a connection it no longer wants, and the actor
/// publishes a client nobody is left to disconnect.
@Test func cancellingConnectStopsTheProbeInsteadOfPublishing() async throws {
    let coordinator = ProbeCoordinator()
    let fileSystem = S3FileSystem(
        config: ConnectionConfig(
            name: "s3",
            backendType: .s3,
            host: "s3.example.com",
            parameters: ["bucket": "bucket", "region": "us-east-1"]
        ),
        credential: MFuseCore.Credential(accessKeyID: "key", secretAccessKey: "secret")
    )
    await fileSystem.setConnectivityProbe {
        await coordinator.probeStarted()
        try await Task.sleep(nanoseconds: 60_000_000_000)
    }

    let attempt = Task { try await fileSystem.connect() }
    await coordinator.waitForProbes(count: 1)

    attempt.cancel()
    switch await attempt.result {
    case .success:
        Issue.record("expected the cancelled connect to fail")
    case .failure(let error):
        #expect(error is CancellationError)
    }

    #expect(await fileSystem.isConnected == false)
    #expect(await fileSystem.hasPendingConnectTask == false)
}

/// A caller that joins someone else's probe must still honour its own cancellation, and
/// must not take the probe down with it: awaiting an unstructured task resumes only when
/// that task finishes, so the joiner would otherwise sit out the whole probe and then
/// report its result as its own.
@Test func cancellingAJoinedConnectLeavesTheSharedProbeRunning() async throws {
    let coordinator = ProbeCoordinator()
    let fileSystem = S3FileSystem(
        config: ConnectionConfig(
            name: "s3",
            backendType: .s3,
            host: "s3.example.com",
            parameters: ["bucket": "bucket", "region": "us-east-1"]
        ),
        credential: MFuseCore.Credential(accessKeyID: "key", secretAccessKey: "secret")
    )
    await fileSystem.setConnectivityProbe {
        await coordinator.probeStarted()
        try await Task.sleep(nanoseconds: 60_000_000_000)
    }

    let first = Task { try await fileSystem.connect() }
    await coordinator.waitForProbes(count: 1)

    let joined = Task { try await fileSystem.connect() }
    joined.cancel()
    switch await joined.result {
    case .success:
        Issue.record("expected the cancelled joiner to fail")
    case .failure(let error):
        #expect(error is CancellationError)
    }

    // The caller that started the probe is still waiting on it.
    #expect(await fileSystem.hasPendingConnectTask)
    #expect(await fileSystem.isConnected == false)

    try await fileSystem.disconnect()
    _ = await first.result
}

/// The attempt is shared, so the caller that happened to start it does not own it: its
/// cancellation must not take the connection down for callers that joined it and were
/// never cancelled themselves.
@Test func cancellingTheStarterLeavesAJoinedConnectRunning() async throws {
    let coordinator = ProbeCoordinator()
    let fileSystem = S3FileSystem(
        config: ConnectionConfig(
            name: "s3",
            backendType: .s3,
            host: "s3.example.com",
            parameters: ["bucket": "bucket", "region": "us-east-1"]
        ),
        credential: MFuseCore.Credential(accessKeyID: "key", secretAccessKey: "secret")
    )
    await fileSystem.setConnectivityProbe {
        await coordinator.probeStarted()
        await coordinator.waitForRelease()
    }

    let starter = Task { try await fileSystem.connect() }
    await coordinator.waitForProbes(count: 1)

    let joiner = Task { try await fileSystem.connect() }
    while await fileSystem.pendingConnectWaiterCount == 0 {
        await Task.yield()
    }

    starter.cancel()
    await coordinator.release()

    // The joiner asked for a connection and never withdrew, so it gets one.
    switch await joiner.result {
    case .success:
        break
    case .failure(let error):
        Issue.record("the joined connect was taken down with the starter: \(error)")
    }
    #expect(await fileSystem.isConnected)

    // The starter still answers for itself.
    switch await starter.result {
    case .success:
        Issue.record("expected the cancelled starter to fail")
    case .failure(let error):
        #expect(error is CancellationError)
    }

    try await fileSystem.disconnect()
}

/// The interrupted attempt shuts down the client it built as it unwinds. `disconnect()`
/// returning before that lets a replacement attempt allocate a second client while the
/// first one is still open — and Soto asserts on a client released without a shutdown.
@Test func disconnectWaitsForTheInterruptedAttemptToUnwind() async throws {
    let coordinator = ProbeCoordinator()
    let fileSystem = S3FileSystem(
        config: ConnectionConfig(
            name: "s3",
            backendType: .s3,
            host: "s3.example.com",
            parameters: ["bucket": "bucket", "region": "us-east-1"]
        ),
        credential: MFuseCore.Credential(accessKeyID: "key", secretAccessKey: "secret")
    )
    await fileSystem.setConnectivityProbe {
        await coordinator.probeStarted()
        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        } catch {
            await coordinator.probeUnwound()
            throw error
        }
    }

    let attempt = Task { try await fileSystem.connect() }
    await coordinator.waitForProbes(count: 1)

    try await fileSystem.disconnect()
    #expect(await coordinator.didUnwind)

    _ = await attempt.result
}

/// Endpoint diagnostics carry the configured hostname, so classifying by scanning the
/// whole description can blame the credentials for an unrelated transport failure.
@Test func structuredErrorCodesOutrankTheDescriptionScan() {
    let mapped = S3FileSystem.mapConnectionError(
        StubAWSError(errorCode: "NoSuchBucket"),
        bucket: "photos"
    )
    guard case .connectionFailed(let message) = mapped else {
        Issue.record("expected .connectionFailed, got \(mapped)")
        return
    }
    #expect(message.contains("bucket"))

    // An unrecognized structured code is still the SDK's own diagnosis: falling through
    // to the description scan would blame the keys for a transport failure that merely
    // names an endpoint reading like one.
    let transport = S3FileSystem.mapConnectionError(
        StubAWSError(errorCode: "RequestTimeout"),
        bucket: "photos"
    )
    guard case .connectionFailed = transport else {
        Issue.record("expected .connectionFailed, got \(transport)")
        return
    }
}

/// The XML code an S3-compatible server sends is vendor-specific and often empty, but the
/// HTTP status is not: a 401 or 403 is about the keys or the access policy whatever the
/// body calls it, and reporting an unreachable endpoint sends the user to check a network
/// that is working.
@Test func authenticationStatusCodesOutrankTheVendorErrorCode() {
    for status: UInt in [401, 403] {
        for code in ["", "AccessForbidden", "SomeVendorCode"] {
            let mapped = S3FileSystem.classifyAWSError(
                code: code,
                httpStatus: status,
                bucket: "photos",
                error: StubError(text: "forbidden")
            )
            guard case .authenticationFailed = mapped else {
                Issue.record("\(status) with code \"\(code)\" mapped to \(String(describing: mapped))")
                continue
            }
        }
    }

    // A 404 on the list probe is still the bucket, whatever the code says.
    guard case .connectionFailed(let message) = S3FileSystem.classifyAWSError(
        code: "",
        httpStatus: 404,
        bucket: "photos",
        error: StubError(text: "missing")
    ) else {
        Issue.record("404 did not map to a bucket error")
        return
    }
    #expect(message.contains("bucket"))

    // Anything else with no code at all is left to the description scan.
    #expect(
        S3FileSystem.classifyAWSError(
            code: "",
            httpStatus: 500,
            bucket: "photos",
            error: StubError(text: "boom")
        ) == nil
    )
}

/// The description scan still classifies SDK errors that carry no structured code.
@Test func descriptionScanRemainsForErrorsWithoutACode() {
    let mapped = S3FileSystem.mapConnectionError(StubError(text: "AccessDenied"), bucket: "b")
    guard case .authenticationFailed = mapped else {
        Issue.record("expected .authenticationFailed, got \(mapped)")
        return
    }
}

private actor ProbeCoordinator {
    private struct Waiter {
        let id: Int
        let threshold: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var started = 0
    private var nextWaiterID = 0
    private var waiters: [Waiter] = []
    private var unwound = false
    private var isReleased = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    /// Holds a probe without observing cancellation, which is what a backend that ignores
    /// it looks like from here.
    func waitForRelease() async {
        guard !isReleased else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func release() {
        isReleased = true
        let pending = releaseWaiters
        releaseWaiters = []
        for continuation in pending {
            continuation.resume()
        }
    }

    /// Whether a probe has finished unwinding after being cancelled.
    var didUnwind: Bool { unwound }

    func probeUnwound() {
        unwound = true
    }

    func probeStarted() {
        started += 1
        let ready = waiters.filter { $0.threshold <= started }
        waiters.removeAll { $0.threshold <= started }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    /// Bounded: a probe that never starts must fail the test rather than hang the suite.
    func waitForProbes(count: Int, timeoutNanoseconds: UInt64 = 10_000_000_000) async {
        guard started < count else { return }

        let id = nextWaiterID
        nextWaiterID += 1
        let timeout = Task { [weak self] in
            try await Task.sleep(nanoseconds: timeoutNanoseconds)
            await self?.timeOutWaiter(id, expected: count)
        }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(id: id, threshold: count, continuation: continuation))
        }
        timeout.cancel()
    }

    private func timeOutWaiter(_ id: Int, expected: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        Issue.record("timed out waiting for \(expected) probe(s); \(started) started")
        waiter.continuation.resume()
    }
}

private struct StubError: Error, CustomStringConvertible {
    let text: String
    var description: String { text }
}

/// An SDK error whose description points at an endpoint that reads like an auth failure.
private struct StubAWSError: AWSErrorType {
    let errorCode: String
    var context: AWSErrorContext? { nil }
    var description: String { "https://unauthorized.internal.example is unreachable" }

    init(errorCode: String) {
        self.errorCode = errorCode
    }

    init?(errorCode: String, context: AWSErrorContext) {
        nil
    }
}
