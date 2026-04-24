import Foundation

/// Factory that creates `RemoteFileSystem` instances from a `ConnectionConfig` and `Credential`.
public final class BackendRegistry: @unchecked Sendable {

    public typealias Factory = @Sendable (ConnectionConfig, Credential) -> any RemoteFileSystem

    public static let shared = BackendRegistry()

    private var factories: [BackendType: Factory] = [:]
    private let lock = NSLock()

    public init() {}

    /// Register a factory for a backend type. Call once at app/extension launch.
    public func register(_ type: BackendType, factory: @escaping Factory) {
        lock.lock()
        defer { lock.unlock() }
        factories[type] = factory
    }

    /// Create a `RemoteFileSystem` for the given config and credential.
    public func createFileSystem(config: ConnectionConfig, credential: Credential) -> (any RemoteFileSystem)? {
        lock.lock()
        let factory = factories[config.backendType]
        lock.unlock()
        return factory?(config, credential)
    }

    /// Whether a factory is registered for the given backend type.
    public func isSupported(_ type: BackendType) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return factories[type] != nil
    }

    /// All currently registered backend types.
    public var supportedTypes: [BackendType] {
        lock.lock()
        defer { lock.unlock() }
        return Array(factories.keys)
    }

    // MARK: - Built-in Registration

    /// Register all built-in backend factories.
    ///
    /// Call this once at startup from both the main app and the File Provider extension.
    /// Each backend's package must be imported by the caller so the concrete types are
    /// available for the factory closures.
    public func registerAllBuiltIns(
        sftpFactory: Factory? = nil,
        s3Factory: Factory? = nil,
        webdavFactory: Factory? = nil,
        smbFactory: Factory? = nil,
        ftpFactory: Factory? = nil,
        nfsFactory: Factory? = nil,
        googleDriveFactory: Factory? = nil,
        dropboxFactory: Factory? = nil,
        oneDriveFactory: Factory? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        if let f = sftpFactory { factories[.sftp] = f }
        if let f = s3Factory { factories[.s3] = f }
        if let f = webdavFactory { factories[.webdav] = f }
        if let f = smbFactory { factories[.smb] = f }
        if let f = ftpFactory { factories[.ftp] = f }
        if let f = nfsFactory { factories[.nfs] = f }
        if let f = googleDriveFactory { factories[.googleDrive] = f }
        if let f = dropboxFactory { factories[.dropbox] = f }
        if let f = oneDriveFactory { factories[.oneDrive] = f }
    }
}
