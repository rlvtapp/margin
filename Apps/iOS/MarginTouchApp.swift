import BackgroundTasks
import MailCore
import MailUI
import SwiftUI
import UIKit
import UserNotifications

/// Margin on iPhone and iPad. Mail goes straight from the device to each provider, the same
/// as on the Mac. Launch with `-sample-mail` to try it with the sample mailboxes.
@main
struct MarginTouchApp: App {
    @State private var model = MailModel(
        environment: ProcessInfo.processInfo.arguments.contains("-sample-mail") ? .preview() : .standard
    )
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor private var pushes: PushDelegate

    /// The background check iOS runs now and then, as permitted in the Info.plist.
    nonisolated static let refreshTask = (Bundle.main.bundleIdentifier ?? "app.relevate.margin") + ".refresh"

    var body: some Scene {
        WindowGroup {
            TouchMailView(model: model)
                .onOpenURL { model.open($0) }
                .task {
                    pushes.attach(to: model)
                    TouchNotificationDelegate.shared.attach(to: model)
                    WatchBridge.shared.attach(to: model)
                    model.startClock()
                }
        }
        .commands { TouchCommands(model: model) }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // A Done or Trash still inside its undo window is sent before the app is put away.
                Task { await model.flushPendingChange() }
                // Open connections are suspended in the background; iOS wakes us instead.
                model.stopWatching()
                Self.scheduleRefresh()
            case .active:
                model.startWatching()
                Task { await model.refreshPushSubscriptions() }
            default:
                break
            }
        }
        // iOS decides when (often every 15 minutes to a few hours): fetch, alert, ask again.
        .backgroundTask(.appRefresh(Self.refreshTask)) {
            Self.scheduleRefresh()
            await MainActor.run { model }.checkForNewMail()
        }
    }

    nonisolated static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTask)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// Instant notifications: iOS's push token goes to the relay, and pushes wake Margin to fetch
/// the new mail itself (docs/push.md). Nothing to set up.
final class PushDelegate: NSObject, UIApplicationDelegate {
    private var model: MailModel?
    private var pendingToken: Data?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    @MainActor
    func attach(to model: MailModel) {
        self.model = model
        if let token = pendingToken { register(token) }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        MainActor.assumeIsolated {
            if model == nil { pendingToken = token } else { register(token) }
        }
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification info: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let model = await MainActor.run(body: { self.model }) else { return .noData }
        await model.handlePush(info)
        // The relay's alert only says "New mail"; Margin has now posted the real one (or decided
        // this mail isn't worth one), so the generic alerts go.
        let center = UNUserNotificationCenter.current()
        let generic = await center.deliveredNotifications()
            .filter { ($0.request.content.userInfo["margin"] as? [String: Any])?["subscription"] != nil }
            .map(\.request.identifier)
        center.removeDeliveredNotifications(withIdentifiers: generic)
        return .newData
    }

    @MainActor
    private func register(_ token: Data) {
        guard let model else { return }
        Task { await model.registerForPush(token: token, sandbox: Self.usesSandboxPush) }
    }

    /// Whether this build's push tokens belong to Apple's sandbox. Builds Xcode installs carry a
    /// development profile that says so (in Debug and Release alike); App Store and TestFlight
    /// builds have no embedded profile and use production.
    private static let usesSandboxPush: Bool = {
        #if targetEnvironment(simulator)
        return true
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return false }
        let text = String(decoding: data, as: UTF8.self)
        guard let key = text.range(of: "<key>aps-environment</key>") else { return false }
        return text[key.upperBound...].prefix(80).contains("development")
        #endif
    }()
}
