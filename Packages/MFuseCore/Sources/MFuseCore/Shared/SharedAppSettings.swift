import Foundation

public enum SharedAppSettings {
    private static let defaults = UserDefaults(suiteName: AppGroupConstants.groupIdentifier)

    public static var iCloudSyncEnabled: Bool {
        defaults?.bool(forKey: AppGroupConstants.iCloudSyncEnabledKey) ?? false
    }

    public static func setICloudSyncEnabled(_ enabled: Bool) {
        defaults?.set(enabled, forKey: AppGroupConstants.iCloudSyncEnabledKey)
    }
}
