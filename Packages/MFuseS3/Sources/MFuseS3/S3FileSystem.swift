import Foundation
import MFuseCore
import SotoCore
import SotoS3
import NIOCore
import NIOFoundationCompat

/// S3 implementation of `RemoteFileSystem` using Soto.
public actor S3FileSystem: RemoteFileSystem {

    private let config: ConnectionConfig
    private let credential: MFuseCore.Credential
    private var awsClient: AWSClient?
    private var s3: S3?

    public var isConnected: Bool { s3 != nil }

    public init(config: ConnectionConfig, credential: MFuseCore.Credential) {
        self.config = config
        self.credential = credential
    }

    // MARK: - Config Helpers

    private var bucket: String { config.parameters["bucket"] ?? "" }
    private var region: String { config.parameters["region"] ?? "us-east-1" }
    private var customEndpoint: String? { config.parameters["endpoint"] }
    private var pathStyle: Bool { config.parameters["pathStyle"] == "true" }

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
        guard let keyID = credential.accessKeyID,
              let secret = credential.secretAccessKey else {
            throw RemoteFileSystemError.authenticationFailed
        }
        guard !bucket.isEmpty else {
            throw RemoteFileSystemError.connectionFailed("S3 bucket name is required")
        }

        let client = AWSClient(credentialProvider: .static(accessKeyId: keyID, secretAccessKey: secret))

        var serviceConfig: S3?
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
            // Test connectivity by listing with max 1 key
            let request = S3.ListObjectsV2Request(bucket: bucket, maxKeys: 1)
            _ = try await serviceConfig!.listObjectsV2(request)
        } catch {
            try? await client.shutdown()
            throw error
        }

        self.awsClient = client
        self.s3 = serviceConfig
    }

    public func disconnect() async throws {
        if let client = awsClient {
            try await client.shutdown()
        }
        s3 = nil
        awsClient = nil
    }

    // MARK: - Enumeration

    public func enumerate(at path: RemotePath) async throws -> [RemoteItem] {
        let s3 = try requireS3()
        let prefix = s3Key(for: path, isDirectory: true)

        var items: [RemoteItem] = []
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
                for p in prefixes {
                    guard let fullPrefix = p.prefix else { continue }
                    let name = directoryName(from: fullPrefix, parentPrefix: prefix)
                    guard !name.isEmpty else { continue }
                    let childPath = path.appending(name)
                    items.append(RemoteItem(
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
                    items.append(RemoteItem(
                        path: childPath,
                        type: .file,
                        size: UInt64(obj.size ?? 0),
                        modificationDate: obj.lastModified ?? Date()
                    ))
                }
            }

            continuationToken = response.nextContinuationToken
        } while continuationToken != nil

        return items
    }

    public func itemInfo(at path: RemotePath) async throws -> RemoteItem {
        let s3 = try requireS3()

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
        let buffer = try await response.body.collect(upTo: Int(length) + 1024)
        return Data(buffer: buffer)
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
            if let responseCode = error.context?.responseCode.code, responseCode == 409 || responseCode == 412 {
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
                _ = try await s3.deleteObjects(deleteReq)
                deletedDirectoryObjects = true
            }

            continuationToken = listResp.nextContinuationToken
        } while continuationToken != nil

        if !deletedDirectoryObjects {
            // Single file
            let key = s3Key(for: path, isDirectory: false)
            let request = S3.DeleteObjectRequest(bucket: bucket, key: key)
            _ = try await s3.deleteObject(request)
        }
    }

    public func move(from source: RemotePath, to destination: RemotePath) async throws {
        try await copy(from: source, to: destination)
        try await delete(at: source)
    }

    public func copy(from source: RemotePath, to destination: RemotePath) async throws {
        let s3 = try requireS3()
        let sourceItem = try await itemInfo(at: source)

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
                    try await copyObject(fromKey: key, toKey: destinationPrefix + suffix, using: s3)
                }

                continuationToken = listResp.nextContinuationToken
            } while continuationToken != nil
            return
        }

        try await copyObject(
            fromKey: s3Key(for: source, isDirectory: false),
            toKey: s3Key(for: destination, isDirectory: false),
            using: s3
        )
    }

    // MARK: - Helpers

    private func requireS3() throws -> S3 {
        guard let s3 = s3 else {
            throw RemoteFileSystemError.notConnected
        }
        return s3
    }

    private func copyObject(fromKey srcKey: String, toKey dstKey: String, using s3: S3) async throws {
        guard let encodedSrcKey = percentEncodeCopySourceKey(srcKey) else {
            throw RemoteFileSystemError.operationFailed("Failed to percent-encode S3 copy source key")
        }
        let request = S3.CopyObjectRequest(
            bucket: bucket,
            copySource: "\(bucket)/\(encodedSrcKey)",
            key: dstKey
        )
        _ = try await s3.copyObject(request)
    }

    /// Convert RemotePath to S3 key. Directory keys end with "/".
    private func s3Key(for path: RemotePath, isDirectory: Bool) -> String {
        let base = config.remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
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
