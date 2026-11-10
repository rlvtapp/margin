import Foundation
#if canImport(UserNotifications)
import UserNotifications

/// New-mail notifications: a sign-in code arrives with a Copy button, and tapping any alert
/// opens its conversation.
public enum MailNotifications {
    static let codeCategory = "signInCode"
    static let copyAction = "copyCode"

    static func registerCategories() {
        let copy = UNNotificationAction(identifier: copyAction, title: String(localized: "Copy code"), options: [])
        let category = UNNotificationCategory(identifier: codeCategory, actions: [copy], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Handles a tap on a notification or its Copy button. Returns the conversation to open,
    /// or nil when the button already did what was needed.
    public static func handle(_ response: UNNotificationResponse) -> String? {
        let info = response.notification.request.content.userInfo
        if response.actionIdentifier == copyAction, let code = info["code"] as? String {
            MailModel.putOnPasteboard(code)
            return nil
        }
        return info["threadID"] as? String
    }
}

#if os(iOS)
/// On iPhone and iPad: shows alerts while Margin is open too, and routes taps and buttons.
@MainActor
public final class TouchNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = TouchNotificationDelegate()
    weak var model: MailModel?

    public func attach(to model: MailModel) {
        self.model = model
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = MailNotifications.handle(response) else { return }
        await MainActor.run { model?.reveal(id) }
    }

    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
#endif
#endif
