import Foundation

/// Observable state of a single connection.
public enum ConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var statusText: String {
        switch self {
        case .disconnected:
            return MFuseCoreL10n.string("connection.disconnected", fallback: "Disconnected")
        case .connecting:
            return MFuseCoreL10n.string("connection.connecting", fallback: "Connecting…")
        case .connected:
            return MFuseCoreL10n.string("connection.connected", fallback: "Connected")
        case .error(let msg):
            return MFuseCoreL10n.string("connection.error", fallback: "Error: %@", msg)
        }
    }

    public var iconName: String {
        switch self {
        case .disconnected: return "circle"
        case .connecting:   return "circle.dotted"
        case .connected:    return "circle.fill"
        case .error:        return "exclamationmark.circle.fill"
        }
    }
}
