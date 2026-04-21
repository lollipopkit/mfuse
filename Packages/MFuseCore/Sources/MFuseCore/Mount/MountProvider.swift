import Foundation

/// Errors from mount operations.
public enum MountError: Error, Sendable, LocalizedError {
    case domainAlreadyExists(String)
    case domainNotFound(String)
    case mountFailed(String)
    case unmountFailed(String)
    case extensionNotEnabled

    public var errorDescription: String? {
        switch self {
        case .domainAlreadyExists(let id): return "Domain already exists: \(id)"
        case .domainNotFound(let id):      return "Domain not found: \(id)"
        case .mountFailed(let msg):        return "Mount failed: \(msg)"
        case .unmountFailed(let msg):      return "Unmount failed: \(msg)"
        case .extensionNotEnabled:         return "File Provider extension is not enabled"
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
        case .unmounted:          return "Unmounted"
        case .mounting:           return "Mounting…"
        case .mounted(let path):  return path
        case .error(let msg):     return "Mount error: \(msg)"
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

/// Abstraction over the mounting mechanism.
public protocol MountProvider: Sendable {

    /// Base directory used for convenience symlinks.
    var symlinkBaseURL: URL { get }

    /// Mount a connection, making it visible in Finder / filesystem.
    func mount(config: ConnectionConfig) async throws

    /// Unmount a previously mounted connection.
    func unmount(config: ConnectionConfig) async throws

    /// List currently mounted domain identifiers.
    func mountedDomains() async throws -> [String]

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
