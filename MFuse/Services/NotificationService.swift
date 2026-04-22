import Foundation
import UserNotifications

/// Posts local notifications for mount lifecycle events.
final class NotificationService {

    static let shared = NotificationService()
    var isEnabled = false

    private init() {
        requestAuthorization()
    }

    private func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func postMounted(name: String) {
        post(
            title: AppL10n.string("notification.mounted.title", fallback: "Mounted"),
            body: AppL10n.string(
                "notification.mounted.body",
                fallback: "%@ is now available in Finder.",
                name
            ),
            identifier: "mounted-\(name)"
        )
    }

    func postUnmounted(name: String) {
        post(
            title: AppL10n.string("notification.unmounted.title", fallback: "Unmounted"),
            body: AppL10n.string(
                "notification.unmounted.body",
                fallback: "%@ has been removed from Finder.",
                name
            ),
            identifier: "unmounted-\(name)"
        )
    }

    func postMountError(name: String, error: String) {
        post(
            title: AppL10n.string("notification.mountError.title", fallback: "Mount Error"),
            body: AppL10n.string(
                "notification.mountError.body",
                fallback: "%1$@: %2$@",
                name,
                error
            ),
            identifier: "error-\(name)"
        )
    }

    private func post(title: String, body: String, identifier: String) {
        guard isEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
