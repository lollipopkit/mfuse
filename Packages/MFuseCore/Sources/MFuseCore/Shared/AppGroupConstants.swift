import Foundation
import Security

/// Constants for App Group shared container.
public enum AppGroupConstants {
    /// The App Group identifier shared between the main app and the File Provider extension.
    /// NOTE: Replace the team identifier prefix with your actual team ID for distribution.
    public static let groupIdentifier = "group.com.lollipopkit.mfuse.shared"

    /// Key for storing connection configs in shared UserDefaults.
    public static let connectionsKey = "com.lollipopkit.mfuse.connections"

    /// Shared container directory name for databases.
    public static let databasesDir = "Databases"

    /// Filename for the metadata cache database.
    public static let metadataCacheDB = "metadata_cache.sqlite"

    /// Filename for the sync anchor store database.
    public static let syncAnchorDB = "sync_anchors.sqlite"

    /// Keychain access group shared between the app and the File Provider extension.
    public static var keychainAccessGroup: String? {
        guard let appIdentifierPrefix = appIDPrefix() else {
            return nil
        }

        return "\(appIdentifierPrefix)com.lollipopkit.mfuse.shared"
    }

    private static func appIDPrefix() -> String? {
        guard let task = SecTaskCreateFromSelf(nil) else {
            return nil
        }

        guard let value = SecTaskCopyValueForEntitlement(
            task,
            "application-identifier" as CFString,
            nil
        ) else {
            return nil
        }

        guard let applicationIdentifier = value as? String else {
            return nil
        }
        let prefix = applicationIdentifier.split(separator: ".", maxSplits: 1).first
        guard let prefix, !prefix.isEmpty else {
            return nil
        }

        return "\(prefix)."
    }
}
