import Foundation
import UserNotifications

/// Posts local notifications for connection lifecycle events.
final class NotificationService {

    static let shared = NotificationService()

    private init() {
        requestAuthorization()
    }

    private func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func postConnected(name: String) {
        post(title: "Connected", body: "\(name) is now connected.", identifier: "connected-\(name)")
    }

    func postDisconnected(name: String) {
        post(title: "Disconnected", body: "\(name) has been disconnected.", identifier: "disconnected-\(name)")
    }

    func postError(name: String, error: String) {
        post(title: "Connection Error", body: "\(name): \(error)", identifier: "error-\(name)")
    }

    private func post(title: String, body: String, identifier: String) {
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
