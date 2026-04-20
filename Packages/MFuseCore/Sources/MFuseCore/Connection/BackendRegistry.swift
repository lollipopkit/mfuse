import Foundation

/// Factory that creates `RemoteFileSystem` instances from a `ConnectionConfig` and `Credential`.
public final class BackendRegistry: @unchecked Sendable {

    public typealias Factory = @Sendable (ConnectionConfig, Credential) -> any RemoteFileSystem

    public static let shared = BackendRegistry()

    private var factories: [BackendType: Factory] = [:]
    private let lock = NSLock()

    private init() {}

    /// Register a factory for a backend type. Call once at app/extension launch.
    public func register(_ type: BackendType, factory: @escaping Factory) {
        lock.lock()
        defer { lock.unlock() }
        factories[type] = factory
    }

    /// Create a `RemoteFileSystem` for the given config and credential.
    public func createFileSystem(config: ConnectionConfig, credential: Credential) -> (any RemoteFileSystem)? {
        lock.lock()
        defer { lock.unlock() }
        return factories[config.backendType]?(config, credential)
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
}
