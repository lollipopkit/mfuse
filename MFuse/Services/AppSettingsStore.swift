import Foundation
import ServiceManagement

@MainActor
final class AppSettingsStore: ObservableObject {
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginStatusDescription = ""
    @Published var errorMessage: String?

    init() {
        refreshLaunchAtLoginStatus()
    }

    var versionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    var buildString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    }

    func refreshLaunchAtLoginStatus() {
        let status = SMAppService.mainApp.status
        launchAtLoginEnabled = status == .enabled

        switch status {
        case .enabled:
            launchAtLoginStatusDescription = "MFuse will launch automatically after you sign in."
        case .notRegistered:
            launchAtLoginStatusDescription = "Launch at login is off."
        case .requiresApproval:
            launchAtLoginStatusDescription = "Launch at login needs approval in System Settings."
        case .notFound:
            launchAtLoginStatusDescription = "Move MFuse into /Applications before enabling launch at login."
        @unknown default:
            launchAtLoginStatusDescription = "Launch at login status is unavailable."
        }
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLaunchAtLoginStatus()
        } catch {
            refreshLaunchAtLoginStatus()
            errorMessage = error.localizedDescription
        }
    }
}
