import SwiftUI

/// Margin on Apple Watch: the inbox from Margin on the iPhone, a mail to read, and the quick
/// actions (Done, Star, Read, a short reply). Watch apps can't open IMAP connections, so the
/// iPhone does the mail work and the watch shows it.
@main
struct MarginWatchApp: App {
    @State private var store = WatchStore()
    @State private var path: [WatchMail] = []

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $path) {
                WatchInbox(store: store)
            }
            .task {
                store.start()
                // For screenshots: -open-mail <id> opens one mail straight away.
                let arguments = ProcessInfo.processInfo.arguments
                if let index = arguments.firstIndex(of: "-open-mail"), index + 1 < arguments.count,
                   let mail = store.mails.first(where: { $0.id == arguments[index + 1] }) {
                    path = [mail]
                }
            }
        }
    }
}
