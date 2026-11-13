import AppKit
import MailCore
import MailUI
import SwiftUI
import UserNotifications

/// Margin starts as the mail app, or, with `--mcp`, as the small bridge that MCP apps
/// launch: it passes their messages to the running app's server on 127.0.0.1.
@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--mcp") {
            MCPBridge.run()
        } else {
            MarginApp.main()
        }
    }
}

struct MarginApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Margin", id: "main") {
            MailRootView(model: delegate.model)
                // Small enough to sit beside another app; the columns give way as it narrows.
                .frame(minWidth: 480, minHeight: 440)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1480, height: 960)
        .commands { MarginCommands(model: delegate.model) }

        Settings {
            MailSettingsView(model: delegate.model)
        }

        // Sign-in codes and links from the last few minutes, and the newest mail, from the menu bar.
        MenuBarExtra(isInserted: Binding(get: { delegate.model.showsMenuBarItem }, set: { delegate.model.showsMenuBarItem = $0 })) {
            MenuBarMail(model: delegate.model)
        } label: {
            let unread = delegate.model.unreadCount(account: nil)
            Label(unread > 0 ? "\(unread)" : "Margin", systemImage: unread > 0 ? "envelope.badge" : "envelope")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model: MailModel
    private let snapshot = SnapshotMode.fromArguments()
    private let benchmark = BenchmarkMode.fromArguments()

    override init() {
        // Before anything reads them: mailboxes and settings kept by the sandboxed Margin of
        // earlier versions come over once (the container itself is left as it was).
        if snapshot == nil && benchmark == nil { SandboxMigration.runIfNeeded() }
        model = MailModel(environment: snapshot == nil && benchmark == nil ? .standard : (benchmark?.environment ?? .preview()))
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        snapshot?.run(model: model)
        benchmark?.run(model: model)
        if snapshot == nil, benchmark == nil {
            model.applyAppIcon()
            model.startConnectionIfEnabled()
            model.startClock()
            UNUserNotificationCenter.current().delegate = self
            // New windows follow the screen-sharing setting too.
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { MailModel.applyScreenSharing(self?.model.hidesFromScreenSharing ?? false) }
            }
        }
    }

    /// Email links from websites and other apps, and device-link files.
    func application(_ application: NSApplication, open urls: [URL]) {
        NSApp.activate()
        for url in urls { model.open(url) }
    }

    /// Clicking a new-mail notification opens that conversation.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = MailNotifications.handle(response) else { return }
        await MainActor.run {
            NSApp.activate()
            model.reveal(id)
        }
    }

    /// A Done or Trash still inside its undo window is sent first, but quitting never waits
    /// more than a few seconds for a slow or unreachable server.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if snapshot != nil { return .terminateNow }
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.model.flushPendingChange() }
                group.addTask { try? await Task.sleep(for: .seconds(3)) }
                await group.next()
                group.cancelAll()
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct MarginCommands: Commands {
    let model: MailModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") { model.startCompose() }
                .keyboardShortcut("n")
            Button("New Meeting") { model.isNewMeetingOpen = true }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }
        CommandMenu("Go") {
            Button("Command Palette…") { model.isPaletteOpen = true }
                .keyboardShortcut("k")
            Button("Search") { model.searchRequest += 1 }
                .keyboardShortcut("f")
            Divider()
            Button("Inbox") { model.go(to: .inbox(account: model.place.accountID, split: nil)) }
                .keyboardShortcut("1")
            ForEach(Array(InboxSplit.tabs.enumerated()), id: \.element) { index, split in
                Button(split.tabTitle) { model.go(to: .inbox(account: model.place.accountID, split: split)) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 2)")))
            }
            Button("Starred") { model.go(to: .starred(account: model.place.accountID)) }
            Divider()
            Button("All Inboxes") { model.go(to: .allInboxes) }
                .keyboardShortcut("1", modifiers: .control)
            ForEach(Array(model.accounts.prefix(8).enumerated()), id: \.element.id) { index, account in
                Button(account.label) { model.go(to: .inbox(account: account.id, split: nil)) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 2)")), modifiers: .control)
            }
        }
        CommandGroup(after: .toolbar) {
            Button("Bigger Text") { model.textScale = min(model.textScale + 0.1, 2) }
                .keyboardShortcut("+")
            Button("Smaller Text") { model.textScale = max(model.textScale - 0.1, 0.8) }
                .keyboardShortcut("-")
            Button("Actual Size") { model.textScale = 1 }
                .keyboardShortcut("0")
        }
        CommandGroup(before: .toolbar) {
            Button(model.isSidebarHidden ? "Show Sidebar" : "Hide Sidebar") { model.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.control, .command])
        }
        CommandMenu("Message") {
            Button("Reply") { model.startReply() }
                .keyboardShortcut("r")
            Button("Reply All") { model.startReply(all: true) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Forward") { model.startForward() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Divider()
            // The standard Mac mail keys, always there whichever single-key set is chosen.
            Button("Archive") { model.perform(.done) }
                .keyboardShortcut("a", modifiers: [.command, .control])
            Button("Move to Trash") { model.perform(.trash) }
                .keyboardShortcut(.delete, modifiers: .command)
            Button("Mark as Read or Unread") { model.toggleRead() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            Button("Star") { model.toggleStar() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            Button("Check for New Mail") { Task { await model.reload() } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .help) {
            Button("Welcome to Margin") { model.isShowingOnboarding = true }
            Button("Keyboard Shortcuts") { model.isShowingShortcuts = true }
                .keyboardShortcut("/")
            Divider()
            Button("Margin Help…") { model.isShowingHelp = true }
            Button("Send Feedback…") { model.startFeedback() }
        }
    }
}
