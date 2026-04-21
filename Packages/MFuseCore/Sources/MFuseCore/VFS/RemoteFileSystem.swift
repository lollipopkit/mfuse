import Foundation

// MARK: - Errors

public enum RemoteFileSystemError: Error, Sendable, LocalizedError {
    case notConnected
    case connectionFailed(String)
    case authenticationFailed
    case notFound(RemotePath)
    case alreadyExists(RemotePath)
    case notDirectory(RemotePath)
    case notFile(RemotePath)
    case permissionDenied(RemotePath)
    case operationFailed(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected"
        case .connectionFailed(let message):
            return "Connection failed: \(message)"
        case .authenticationFailed:
            return "Authentication failed"
        case .notFound(let path):
            return "Remote path not found: \(path.absoluteString)"
        case .alreadyExists(let path):
            return "Remote path already exists: \(path.absoluteString)"
        case .notDirectory(let path):
            return "Remote path is not a directory: \(path.absoluteString)"
        case .notFile(let path):
            return "Remote path is not a file: \(path.absoluteString)"
        case .permissionDenied(let path):
            return "Permission denied: \(path.absoluteString)"
        case .operationFailed(let message):
            return message
        case .unsupported(let message):
            return message
        }
    }

    public var isTransientConnectionFailure: Bool {
        switch self {
        case .authenticationFailed:
            return false
        case .connectionFailed:
            return true
        default:
            return false
        }
    }
}

// MARK: - Protocol

/// Actor protocol that all remote filesystem backends must implement.
/// Guarantees thread safety via actor isolation.
public protocol RemoteFileSystem: Actor {

    /// Whether the filesystem is currently connected.
    var isConnected: Bool { get }

    // MARK: Lifecycle

    func connect() async throws
    func disconnect() async throws

    // MARK: Enumeration

    /// List items in a directory.
    func enumerate(at path: RemotePath) async throws -> [RemoteItem]

    /// Get info for a single item.
    func itemInfo(at path: RemotePath) async throws -> RemoteItem

    // MARK: Read

    /// Read an entire file into memory.
    func readFile(at path: RemotePath) async throws -> Data

    /// Read a range of bytes from a file.
    func readFile(at path: RemotePath, offset: UInt64, length: UInt32) async throws -> Data

    // MARK: Write

    /// Write (overwrite) an entire file.
    func writeFile(at path: RemotePath, data: Data) async throws

    /// Write (overwrite) a file from a local file URL without requiring callers to materialize full Data.
    func writeFile(at path: RemotePath, from localFileURL: URL) async throws

    /// Create a new file (fails if exists).
    func createFile(at path: RemotePath, data: Data) async throws

    /// Create a new file from a local file URL without requiring callers to materialize full Data.
    func createFile(at path: RemotePath, from localFileURL: URL) async throws

    // MARK: Mutations

    func createDirectory(at path: RemotePath) async throws
    func delete(at path: RemotePath) async throws
    func move(from source: RemotePath, to destination: RemotePath) async throws
    func copy(from source: RemotePath, to destination: RemotePath) async throws

    // MARK: Permissions

    func setPermissions(_ permissions: UInt16, at path: RemotePath) async throws
}

// MARK: - Default Implementations

public extension RemoteFileSystem {

    func readFile(at path: RemotePath, offset: UInt64, length: UInt32) async throws -> Data {
        _ = (path, offset, length)
        throw RemoteFileSystemError.unsupported("Range reads must be implemented by the backend")
    }

    func copy(from source: RemotePath, to destination: RemotePath) async throws {
        let info = try await itemInfo(at: source)
        if info.isDirectory {
            throw RemoteFileSystemError.unsupported("Recursive copy not supported by default")
        }
        let data = try await readFile(at: source)
        try await writeFile(at: destination, data: data)
    }

    func writeFile(at path: RemotePath, from localFileURL: URL) async throws {
        _ = (path, localFileURL)
        throw RemoteFileSystemError.unsupported("Streaming writes from local files must be implemented by the backend")
    }

    func createFile(at path: RemotePath, from localFileURL: URL) async throws {
        _ = (path, localFileURL)
        throw RemoteFileSystemError.unsupported("Streaming creates from local files must be implemented by the backend")
    }

    func setPermissions(_ permissions: UInt16, at path: RemotePath) async throws {
        throw RemoteFileSystemError.unsupported("setPermissions")
    }
}
