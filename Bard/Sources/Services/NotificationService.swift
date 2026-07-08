import Foundation
import UserNotifications

enum NotificationService {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notifyAudiobookReady(title: String) {
        let content = UNMutableNotificationContent()
        content.title = "Audiobook Ready"
        content.body = title.isEmpty ? "Your audiobook has finished generating." : "\"\(title)\" has finished generating."
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
