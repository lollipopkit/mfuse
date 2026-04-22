import Foundation
import Security

/// Constants for App Group shared container.
public enum AppGroupConstants {
    /// The App Group identifier shared between the main app and the File Provider extension.
    /// NOTE: Replace the team identifier prefix with your actual team ID for distribution.
    public static let groupIdentifier = "group.com.lollipopkit.mfuse.shared"

    /// Key for storing connection configs in shared UserDefaults.
    public static let connectionsKey = "com.lollipopkit.mfuse.connections"

    /// Key for marking File Provider extension onboarding as completed.
    public static let extensionOnboardedKey = "extensionOnboarded"

    /// Key for persisting whether iCloud sync is enabled.
    public static let iCloudSyncEnabledKey = "iCloudSyncEnabled"

    /// Shared container directory name for databases.
    public static let databasesDir = "Databases"

    /// Filename for the metadata cache database.
    public static let metadataCacheDB = "metadata_cache.sqlite"

    /// Filename for the sync anchor store database.
    public static let syncAnchorDB = "sync_anchors.sqlite"

    /// The iCloud ubiquity container used by the main app.
    public static let ubiquityContainerIdentifier = "iCloud.com.lollipopkit.mfuse"

    /// Keychain access group shared between the app and the File Provider extension.
    public static var keychainAccessGroup: String? {
        guard hasAppGroupEntitlement(groupIdentifier) else {
            return nil
        }
        return groupIdentifier
    }

    /// Legacy team-prefixed keychain access group used by older MFuse builds.
    public static var legacyKeychainAccessGroup: String? {
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

    private static func hasAppGroupEntitlement(_ identifier: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.security.application-groups" as CFString,
                nil
              ) else {
            return false
        }

        if let groups = value as? [String] {
            return groups.contains(identifier)
        }
        if let groups = value as? [NSString] {
            return groups.contains(identifier as NSString)
        }
        return false
    }
}
