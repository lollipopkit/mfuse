import Foundation

/// Errors from mount operations.
public enum MountError: Error, Sendable, LocalizedError {
    case domainAlreadyExists(String)
    case domainNotFound(String)
    case managerNotFound(String)
    case mountFailed(String)
    case unmountFailed(String)
    case extensionNotEnabled

    public var errorDescription: String? {
        switch self {
        case .domainAlreadyExists(let id):
            return MFuseCoreL10n.string("mount.error.domainAlreadyExists", fallback: "Domain already exists: %@", id)
        case .domainNotFound(let id):
            return MFuseCoreL10n.string("mount.error.domainNotFound", fallback: "Domain not found: %@", id)
        case .managerNotFound(let id):
            return MFuseCoreL10n.string("mount.error.managerNotFound", fallback: "File Provider manager not found: %@", id)
        case .mountFailed(let msg):
            return MFuseCoreL10n.string("mount.error.mountFailed", fallback: "Mount failed: %@", msg)
        case .unmountFailed(let msg):
            return MFuseCoreL10n.string("mount.error.unmountFailed", fallback: "Unmount failed: %@", msg)
        case .extensionNotEnabled:
            return MFuseCoreL10n.string("mount.error.extensionNotEnabled", fallback: "File Provider extension is not enabled")
        }
    }

    /// These strings come from File Provider / launchd error descriptions surfaced by macOS.
    /// They are not stable API, so this list may need updates when system wording changes.
    /// Whether this error indicates the FP extension needs to be enabled by the user.
    public var isExtensionNotEnabled: Bool {
        switch self {
        case .extensionNotEnabled: return true
        case .mountFailed(let msg): return Self.matchesExtensionNotEnabledMessage(msg)
        default: return false
        }
    }

    static func matchesExtensionNotEnabledMessage(_ message: String) -> Bool {
        let normalized = message.lowercased()
        let knownIndicators = [
            "helper application",
            "extension is not enabled",
            "file provider extension",
            "provider not found",
            "cannot find extension",
            "must be enabled",
        ]
        return knownIndicators.contains { normalized.contains($0) }
    }
}

/// State of a filesystem mount.
public enum MountState: Sendable, Equatable {
    case unmounted
    case mounting
    case mounted(path: String)
    case error(String)

    public var isMounted: Bool {
        if case .mounted = self { return true }
        return false
    }

    public var mountPath: String? {
        if case .mounted(let path) = self { return path }
        return nil
    }

    public var statusText: String {
        switch self {
        case .unmounted:
            return MFuseCoreL10n.string("mount.unmounted", fallback: "Unmounted")
        case .mounting:
            return MFuseCoreL10n.string("mount.mounting", fallback: "Mounting…")
        case .mounted(let path):
            return path
        case .error(let msg):
            return MFuseCoreL10n.string("mount.error.status", fallback: "Mount error: %@", msg)
        }
    }

    /// Whether this mount error indicates the extension needs user activation.
    public var needsExtensionSetup: Bool {
        if case .error(let msg) = self {
            return MountError.mountFailed(msg).isExtensionNotEnabled
        }
        return false
    }
}

public struct RegisteredDomainState: Sendable, Equatable {
    public let identifier: String
    public let isDisconnected: Bool

    public init(identifier: String, isDisconnected: Bool) {
        self.identifier = identifier
        self.isDisconnected = isDisconnected
    }

    public var isConnected: Bool {
        !isDisconnected
    }
}

/// Abstraction over the mounting mechanism.
public protocol MountProvider: Sendable {

    /// Base directory used for convenience symlinks.
    var symlinkBaseURL: URL { get }

    /// Ensure a File Provider domain exists for the connection and refresh bootstrap state.
    func ensureRegistered(config: ConnectionConfig) async throws

    /// Remove the File Provider domain for the connection.
    func unregister(config: ConnectionConfig) async throws

    /// Reconnect a registered domain so the extension becomes active again.
    func reconnect(config: ConnectionConfig) async throws

    /// Disconnect a registered domain while keeping it registered.
    func disconnect(config: ConnectionConfig) async throws

    /// List currently registered domains and whether they are disconnected.
    func domainStates() async throws -> [RegisteredDomainState]

    /// Signal the system to re-enumerate a domain (e.g. after changes).
    func signalEnumerator(for config: ConnectionConfig) async throws

    /// Get the user-visible filesystem URL for a mounted connection.
    func mountURL(for config: ConnectionConfig) async throws -> URL?

    /// Create a convenience symlink at ~/MFuse/<name> pointing to the actual mount path.
    @discardableResult
    func createSymlink(for config: ConnectionConfig) async throws -> URL?

    /// Remove the convenience symlink for a connection.
    func removeSymlink(for config: ConnectionConfig) async throws
}

public extension MountProvider {
    func mountedDomains() async throws -> [String] {
        try await domainStates()
            .filter(\.isConnected)
            .map(\.identifier)
    }
}
