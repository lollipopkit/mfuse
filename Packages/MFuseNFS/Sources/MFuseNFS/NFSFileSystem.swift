import Foundation
import MFuseCore

/// NFS stub implementation.
///
/// A pure-Swift NFS client does not currently exist. This stub provides
/// the backend registration point so the UI can show NFS as an option.
/// All operations throw `.unsupported` until a real implementation is provided
/// (e.g. via macOS `mount_nfs` CLI wrapper or a future Swift NFS library).
public actor NFSFileSystem: RemoteFileSystem {

    private let config: ConnectionConfig
    private let credential: Credential
    private var connected = false

    public var isConnected: Bool { connected }

    public init(config: ConnectionConfig, credential: Credential) {
        self.config = config
        self.credential = credential
    }

    // MARK: - Lifecycle

    public func connect() async throws {
        // NFS mount could be done via Process("mount_nfs") in the future
        throw RemoteFileSystemError.operationFailed(
            "NFS is not yet implemented. A pure-Swift NFS client is not available."
        )
    }

    public func disconnect() async throws {
        connected = false
    }

    // MARK: - Stubs

    public func enumerate(at path: RemotePath) async throws -> [RemoteItem] {
        throw nfsUnsupported()
    }

    public func itemInfo(at path: RemotePath) async throws -> RemoteItem {
        throw nfsUnsupported()
    }

    public func readFile(at path: RemotePath) async throws -> Data {
        throw nfsUnsupported()
    }

    public func writeFile(at path: RemotePath, data: Data) async throws {
        throw nfsUnsupported()
    }

    public func createFile(at path: RemotePath, data: Data) async throws {
        throw nfsUnsupported()
    }

    public func createDirectory(at path: RemotePath) async throws {
        throw nfsUnsupported()
    }

    public func delete(at path: RemotePath) async throws {
        throw nfsUnsupported()
    }

    public func move(from source: RemotePath, to destination: RemotePath) async throws {
        throw nfsUnsupported()
    }

    // MARK: - Private

    private func nfsUnsupported() -> RemoteFileSystemError {
        .operationFailed("NFS is not yet implemented")
    }
}
