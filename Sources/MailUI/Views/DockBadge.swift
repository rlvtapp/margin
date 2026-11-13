#if os(macOS)
import AppKit
import MailCore
import SwiftUI
import UserNotifications

extension MailModel {
    /// Shows how much unread mail there is on Margin's Dock icon.
    public var showsDockBadge: Bool {
        get { _ = alertRevision; return environment.defaults.object(forKey: "showsDockBadge") as? Bool ?? true }
        set {
            guard newValue != showsDockBadge else { return }
            environment.defaults.set(newValue, forKey: "showsDockBadge")
            alertRevision += 1
        }
    }
}

/// Keeps the Dock icon's unread count in step with the inboxes: it drops the moment mail is
/// read, since it follows the same count the rail shows.
struct DockBadge: View {
    let model: MailModel

    var body: some View {
        let count = model.showsDockBadge ? model.unreadCount(account: nil) : 0
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { Self.show(count) }
            .onChange(of: count) { _, count in Self.show(count) }
    }

    static func label(_ count: Int) -> String? {
        count <= 0 ? nil : count > 999 ? "999+" : "\(count)"
    }

    private static func show(_ count: Int) {
        NSApp?.dockTile.badgeLabel = label(count)
        if count > 0 { allowBadge() }
    }

    /// macOS shows a Dock badge only for apps allowed to badge their icon in Notifications.
    /// Margin otherwise asks only before its first alert, so ask once there's a count to show
    /// (the same request as for alerts; the answer is the person's, in System Settings).
    private static func allowBadge() {
        guard !asked else { return }
        asked = true
        Task {
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    @MainActor private static var asked = false
}
#endif
