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
        post(title: "Mounted", body: "\(name) is now available in Finder.", identifier: "mounted-\(name)")
    }

    func postUnmounted(name: String) {
        post(title: "Unmounted", body: "\(name) has been removed from Finder.", identifier: "unmounted-\(name)")
    }

    func postMountError(name: String, error: String) {
        post(title: "Mount Error", body: "\(name): \(error)", identifier: "error-\(name)")
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
