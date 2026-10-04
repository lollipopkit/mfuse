import Foundation
import MFuseCore
import NFS

/// NFSv3 through nfs.swift's `NFSClient`.
///
/// The connection's remote path is the export to mount; `uid` and `gid` parameters set the
/// `AUTH_SYS` ids, the Mac user's own by default. The File Provider extension cannot use a
/// port below 1024, so Linux exports need the `insecure` option.
public actor NFSFileSystem: RemoteFileSystem {

    private let config: ConnectionConfig
    private let client: NFSClient
    /// Mirrors the client's state, which it can only report asynchronously.
    private var connected = false

    public var isConnected: Bool { connected }

    public init(config: ConnectionConfig, credential: Credential) {
        self.config = config
        let current = RPCCredential.currentProcess
        let exportPath = config.remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.client = NFSClient(configuration: .init(
            host: config.host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: Int(config.port),
            exportPath: exportPath.isEmpty ? "/" : exportPath,
            credential: RPCCredential(
                uid: config.parameters["uid"].flatMap { UInt32($0) } ?? current.uid,
                gid: config.parameters["gid"].flatMap { UInt32($0) } ?? current.gid,
                machineName: "mfuse"
            )
        ))
    }

    // MARK: - Lifecycle

    public func connect() async throws {
        guard !config.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteFileSystemError.connectionFailed("NFS server address is required")
        }
        do {
            try await client.connect()
            connected = true
        } catch {
            throw Self.connectionError(error)
        }
    }

    public func disconnect() async throws {
        connected = false
        await client.disconnect()
    }

    // MARK: - Enumeration

    public func enumerate(at path: RemotePath) async throws -> [RemoteItem] {
        try await perform(on: path) {
            var items: [RemoteItem] = []
            for entry in try await client.contentsOfDirectory(at: path.absoluteString) {
                // Devices, sockets and FIFOs cannot be read like files; listing them would
                // only offer items that fail to open.
                guard [.regular, .directory, .symlink].contains(entry.attributes.type) else { continue }
                items.append(await item(at: path.appending(entry.name), attributes: entry.attributes))
            }
            return items
        }
    }

    public func itemInfo(at path: RemotePath) async throws -> RemoteItem {
        try await perform(on: path) {
            await item(at: path, attributes: try await client.attributes(of: path.absoluteString))
        }
    }

    // MARK: - Read

    public func readFile(at path: RemotePath) async throws -> Data {
        try await perform(on: path) { try await client.read(path.absoluteString) }
    }

    public func readFile(at path: RemotePath, offset: UInt64, length: UInt32) async throws -> Data {
        try await perform(on: path) {
            try await client.read(path.absoluteString, offset: offset, length: UInt64(length))
        }
    }

    // MARK: - Write

    public func writeFile(at path: RemotePath, data: Data) async throws {
        try await perform(on: path) { try await client.write(data, to: path.absoluteString, mode: .unchecked) }
    }

    public func writeFile(at path: RemotePath, from localFileURL: URL) async throws {
        try await perform(on: path) {
            try await client.write(try FileUploadSource(url: localFileURL), to: path.absoluteString, mode: .unchecked)
        }
    }

    public func createFile(at path: RemotePath, data: Data) async throws {
        try await perform(on: path) { try await client.write(data, to: path.absoluteString, mode: .guarded) }
    }

    public func createFile(at path: RemotePath, from localFileURL: URL) async throws {
        try await perform(on: path) {
            try await client.write(try FileUploadSource(url: localFileURL), to: path.absoluteString, mode: .guarded)
        }
    }

    // MARK: - Mutations

    public func createDirectory(at path: RemotePath) async throws {
        guard !path.isRoot else { throw RemoteFileSystemError.alreadyExists(path) }
        try await perform(on: path) { try await client.createDirectory(at: path.absoluteString) }
    }

    public func delete(at path: RemotePath) async throws {
        guard !path.isRoot else {
            throw RemoteFileSystemError.operationFailed("The root of an NFS mount cannot be deleted")
        }
        try await perform(on: path) { try await client.removeItem(at: path.absoluteString) }
    }

    /// Refuses an existing destination, like every other backend; NFS itself would
    /// replace it.
    public func move(from source: RemotePath, to destination: RemotePath) async throws {
        guard !source.isRoot, !destination.isRoot else {
            throw RemoteFileSystemError.operationFailed("The root of an NFS mount cannot be moved")
        }
        try await perform(on: source) {
            try await client.moveItem(at: source.absoluteString, to: destination.absoluteString)
        }
    }

    /// Copied through the Mac: NFSv3 has no server-side copy.
    public func copy(from source: RemotePath, to destination: RemotePath) async throws {
        guard !source.isRoot, !destination.isRoot else {
            throw RemoteFileSystemError.operationFailed("The root of an NFS mount cannot be copied")
        }
        do {
            try await client.copyItem(at: source.absoluteString, to: destination.absoluteString)
        } catch NFSClientError.alreadyExists {
            // About the destination, where `perform` would name the source.
            throw RemoteFileSystemError.alreadyExists(destination)
        } catch {
            connected = await client.isConnected
            throw Self.mapped(error, path: source)
        }
    }

    public func setPermissions(_ permissions: UInt16, at path: RemotePath) async throws {
        try await perform(on: path) { try await client.setPermissions(UInt32(permissions), at: path.absoluteString) }
    }

    // MARK: - Helpers

    private func perform<T>(on path: RemotePath, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            // The client drops its session when the export's root handle goes stale.
            connected = await client.isConnected
            throw Self.mapped(error, path: path)
        }
    }

    private func item(at path: RemotePath, attributes: NFSAttributes) async -> RemoteItem {
        let type: RemoteItemType
        switch attributes.type {
        case .directory:
            type = .directory
        case .symlink:
            type = .symlink(target: (try? await client.destinationOfSymbolicLink(at: path.absoluteString)) ?? "")
        default:
            type = .file
        }
        return RemoteItem(
            path: path,
            type: type,
            size: attributes.type == .directory ? 0 : attributes.size,
            modificationDate: attributes.modified,
            permissions: UInt16(attributes.mode & 0o7777),
            isHidden: path.name.hasPrefix(".")
        )
    }

    /// nfs.swift reports paths as it was given them, which here is always
    /// `path.absoluteString`; the error is about `path` either way.
    static func mapped(_ error: Error, path: RemotePath) -> Error {
        switch error {
        case is RemoteFileSystemError, is CancellationError:
            return error
        case let error as NFSClientError:
            switch error {
            case .notConnected: return RemoteFileSystemError.notConnected
            case .notFound: return RemoteFileSystemError.notFound(path)
            case .alreadyExists: return RemoteFileSystemError.alreadyExists(path)
            case .notDirectory: return RemoteFileSystemError.notDirectory(path)
            case .isDirectory: return RemoteFileSystemError.notFile(path)
            case .permissionDenied, .credentialsRejected: return RemoteFileSystemError.permissionDenied(path)
            case .exportNoLongerMounted, .noMountService, .mountRefused:
                return RemoteFileSystemError.connectionFailed(error.localizedDescription)
            default:
                return RemoteFileSystemError.operationFailed(error.localizedDescription)
            }
        case let error as RPCError:
            return RemoteFileSystemError.connectionFailed(error.localizedDescription)
        default:
            return RemoteFileSystemError.operationFailed(error.localizedDescription)
        }
    }

    static func connectionError(_ error: Error) -> RemoteFileSystemError {
        if let error = error as? RemoteFileSystemError { return error }
        return .connectionFailed(error.localizedDescription)
    }
}
