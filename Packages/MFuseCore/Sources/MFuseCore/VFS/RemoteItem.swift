import Foundation

/// The type of a remote filesystem item.
public enum RemoteItemType: Sendable, Codable, Equatable {
    case file
    case directory
    case symlink(target: String)
}

/// Represents a single item (file, directory, or symlink) in a remote filesystem.
public struct RemoteItem: Sendable, Identifiable, Codable {

    /// Stable identifier — typically the absolute path string.
    public let id: String

    /// The remote path to this item.
    public let path: RemotePath

    /// Whether this is a file, directory, or symlink.
    public let type: RemoteItemType

    /// File size in bytes (0 for directories).
    public let size: UInt64

    /// Last modification date.
    public let modificationDate: Date

    /// Creation date, if available.
    public let creationDate: Date?

    /// POSIX permissions (e.g. 0o644), if available.
    public let permissions: UInt16?

    // MARK: - Convenience

    public var name: String { path.name }

    public var isDirectory: Bool {
        if case .directory = type { return true }
        return false
    }

    public var isSymlink: Bool {
        if case .symlink = type { return true }
        return false
    }

    // MARK: - Initializer

    public init(
        id: String? = nil,
        path: RemotePath,
        type: RemoteItemType,
        size: UInt64 = 0,
        modificationDate: Date = Date(),
        creationDate: Date? = nil,
        permissions: UInt16? = nil
    ) {
        self.id = id ?? path.absoluteString
        self.path = path
        self.type = type
        self.size = size
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.permissions = permissions
    }
}
