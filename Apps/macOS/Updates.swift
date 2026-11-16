import Combine
import MailUI
import Sparkle
import SwiftUI

/// Updates for the Mac app, which is downloaded from the website rather than the App Store
/// (docs/updates.md). Sparkle reads the feed in `SUFeedURL` and only installs versions signed
/// with the key whose public half is `SUPublicEDKey`. A build without both (from source, a fork)
/// gets no updater: no menu item and nothing in Settings.
@MainActor
final class Updates: NSObject, AppUpdates {
    private let controller: SPUStandardUpdaterController

    /// Nil when this build has no feed or key.
    static func makeIfConfigured() -> Updates? {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = (info["SUFeedURL"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let key = (info["SUPublicEDKey"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !feed.isEmpty, !key.isEmpty, URL(string: feed)?.scheme == "https" else { return nil }
        return Updates()
    }

    private override init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        super.init()
    }

    private var updater: SPUUpdater { controller.updater }

    func checkForUpdates() { controller.checkForUpdates(nil) }
    var canCheckForUpdates: Bool { updater.canCheckForUpdates }
    /// Sparkle reports this over key-value observing.
    var canCheckChanges: AnyPublisher<Bool, Never> { updater.publisher(for: \.canCheckForUpdates).eraseToAnyPublisher() }

    var checksAutomatically: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    var installsAutomatically: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { updater.automaticallyDownloadsUpdates = newValue }
    }
}

/// "Check for Updates…" under About Margin in the app menu, greyed out while a check is running.
struct UpdateCommands: Commands {
    let updates: Updates?

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if let updates {
                CheckForUpdatesButton(updates: updates)
            }
        }
    }
}

private struct CheckForUpdatesButton: View {
    let updates: Updates
    @State private var canCheck = true

    var body: some View {
        Button("Check for Updates…") { updates.checkForUpdates() }
            .disabled(!canCheck)
            .onReceive(updates.canCheckChanges) { canCheck = $0 }
    }
}
