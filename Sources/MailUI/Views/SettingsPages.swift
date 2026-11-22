import MailCore
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The pages of Settings, the same on the Mac and on iPhone and iPad, with words to find them by.
enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case general, mailboxes, workspaces, contacts
    case notifications, reading, writing, signatures, templates, sorting, rules
    case appearance, layout, shortcuts
    case assistant, ask, permissions, writingStyle, connections
    case signInCodes, vips
    case backup, backupFiles, restore, experimental, changelog, about

    var id: String { rawValue }

    /// The page a name asks for: its own, or the page that took over an older one's settings.
    init?(named name: String) {
        switch name {
        case "ai": self = .assistant
        case "swipes": self = .shortcuts
        default: self.init(rawValue: name)
        }
    }

    /// Pages each platform shows: connections from AI apps are the Mac's, and so is Experimental
    /// while everything on it is.
    static var available: [SettingsPage] {
        #if os(macOS)
        allCases
        #else
        allCases.filter { $0 != .connections && $0 != .experimental }
        #endif
    }

    /// A named group of pages in the sidebar.
    struct Group: Identifiable {
        let id: String
        /// Nothing for the first group, which needs no name.
        let title: String?
        var pages: [SettingsPage]
    }

    /// The pages that were split off a long page and sit folded under it in the sidebar.
    static let outline: [(page: SettingsPage, under: [SettingsPage])] = [
        (.notifications, [.signInCodes, .vips]),
        (.assistant, [.ask, .permissions]),
        (.backup, [.backupFiles, .restore]),
    ]

    /// The row a page is folded under, when it is.
    var parent: SettingsPage? { Self.outline.first { $0.under.contains(self) }?.page }

    /// The pages folded under this row on this platform.
    var children: [SettingsPage] {
        (Self.outline.first { $0.page == self }?.under ?? []).filter(Self.available.contains)
    }

    /// The sidebar's groups: Margin and your mailboxes, how mail behaves, how Margin looks and
    /// is driven, everything AI, then your data. A page split off a long one follows it.
    static var groups: [Group] {
        [Group(id: "margin", title: nil, pages: [.general, .mailboxes, .workspaces, .contacts]),
         Group(id: "mail", title: String(localized: "Mail", table: "Settings"),
               pages: [.notifications, .signInCodes, .vips, .reading, .writing, .signatures, .templates, .sorting, .rules]),
         Group(id: "look", title: String(localized: "Look and feel", table: "Settings"), pages: [.appearance, .layout, .shortcuts]),
         Group(id: "ai", title: String(localized: "AI", table: "Settings"), pages: [.assistant, .ask, .permissions, .writingStyle, .connections]),
         Group(id: "data", title: String(localized: "Your data", table: "Settings"), pages: [.backup, .backupFiles, .restore, .experimental, .changelog, .about])]
            .map { Group(id: $0.id, title: $0.title, pages: $0.pages.filter(available.contains)) }
    }

    /// The groups, with only the pages that match a search.
    static func groups(matching query: String) -> [Group] {
        groups.map { Group(id: $0.id, title: $0.title, pages: $0.pages.filter { $0.matches(query) }) }.filter { !$0.pages.isEmpty }
    }

    static var sections: [[SettingsPage]] { groups.map(\.pages) }

    static func sections(matching query: String) -> [[SettingsPage]] { groups(matching: query).map(\.pages) }

    var title: String {
        switch self {
        case .general: String(localized: "General", table: "Settings")
        case .mailboxes: String(localized: "Mailboxes", table: "Settings")
        case .contacts: String(localized: "Contacts", table: "Settings")
        case .workspaces: String(localized: "Workspaces", table: "Settings")
        case .notifications: String(localized: "Notifications", table: "Settings")
        case .reading: String(localized: "Reading", table: "Settings")
        case .writing: String(localized: "Writing", table: "Settings")
        case .signatures: String(localized: "Signatures", table: "Settings")
        case .appearance: String(localized: "Appearance", table: "Settings")
        case .layout: String(localized: "Layout", table: "Settings")
        case .sorting: String(localized: "Sorting", table: "Settings")
        case .templates: String(localized: "Templates", table: "Settings")
        case .shortcuts:
            #if os(macOS)
            String(localized: "Shortcuts and Swipes", table: "Settings")
            #else
            String(localized: "Swipes", table: "Settings")
            #endif
        case .assistant: String(localized: "AI", table: "Settings")
        case .ask: String(localized: "Ask", table: "Settings")
        case .permissions: String(localized: "Permissions", table: "Settings")
        case .signInCodes: String(localized: "Sign-in codes", table: "Settings")
        case .vips: String(localized: "VIPs", table: "Settings")
        case .backupFiles: String(localized: "Backup", table: "Settings")
        case .restore: String(localized: "Restore", table: "Settings")
        case .writingStyle: String(localized: "Writing Style", table: "Settings")
        case .rules: String(localized: "Rules", table: "Settings")
        case .connections: String(localized: "AI Apps", table: "Settings")
        case .backup: String(localized: "Backup and Devices", table: "Settings")
        case .experimental: String(localized: "Experimental", table: "Settings")
        case .changelog: String(localized: "What's New", table: "Settings")
        case .about: String(localized: "About", table: "Settings")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .mailboxes: "tray.2.fill"
        case .contacts: "person.crop.circle.fill"
        case .workspaces: "square.stack.fill"
        case .notifications: "bell.badge.fill"
        case .reading: "text.justify.left"
        case .writing: "square.and.pencil"
        case .signatures: "signature"
        case .appearance: "paintbrush.fill"
        case .layout: "rectangle.split.3x1.fill"
        case .sorting: "square.stack.3d.up.fill"
        case .templates: "doc.on.doc.fill"
        case .shortcuts:
            #if os(macOS)
            "keyboard.fill"
            #else
            "hand.draw.fill"
            #endif
        case .assistant: "sparkles"
        case .ask: "bubble.left.and.text.bubble.right.fill"
        case .permissions: "hand.raised.fill"
        case .signInCodes: "number.square.fill"
        case .vips: "star.fill"
        case .backupFiles: "archivebox.fill"
        case .restore: "arrow.counterclockwise.circle.fill"
        case .writingStyle: "pencil.and.scribble"
        case .rules: "line.3.horizontal.decrease.circle.fill"
        case .connections: "point.3.connected.trianglepath.dotted"
        case .backup: "externaldrive.fill"
        case .experimental: "flask.fill"
        case .changelog: "sparkles"
        case .about: "info.circle.fill"
        }
    }

    /// The icon tile's colour: one family per group, so the sidebar reads as groups at a glance.
    var tint: Color {
        switch self {
        case .general: Ink.tertiary
        case .mailboxes: Palette.account(0)
        case .workspaces: Palette.account(5)
        case .contacts: Palette.account(1)
        case .notifications: Palette.account(6)
        case .reading: Palette.account(3)
        case .writing: Palette.account(4)
        case .signatures: Palette.account(8)
        case .templates: Palette.account(10)
        case .sorting: Palette.account(7)
        case .rules: Palette.account(9)
        case .appearance: Palette.account(4)
        case .layout: Palette.account(0)
        case .shortcuts: Ink.tertiary
        case .assistant, .ask, .permissions, .writingStyle, .connections: Palette.account(2)
        case .signInCodes, .vips: Palette.account(6)
        case .backup, .backupFiles, .restore: Palette.account(1)
        case .experimental: Palette.account(4)
        case .changelog: Palette.account(3)
        case .about: Ink.tertiary
        }
    }

    /// Words a search finds this page by, besides its title and the names of its settings.
    var keywords: [String] {
        switch self {
        case .general: ["language", "default mail app", "email links", "mailto", "login", "startup", "launch", "privacy", "tracker", "screen sharing", "recording",
                        "storage", "offline", "download", "disk", "saved mail", "cache"]
        case .mailboxes: ["account", "add", "remove", "signature", "alias", "send as", "server", "password", "picture", "imap", "smtp", "all inboxes", "sign in"]
        case .contacts: ["people", "address book", "carddav", "microsoft", "google", "outlook", "rooms", "calendar", "suggestions"]
        case .workspaces: ["work", "personal", "group", "switch"]
        case .notifications: ["alert", "sound", "menu bar", "notch", "drop down", "meeting", "reminder", "badge", "quiet"]
        case .signInCodes: ["sign-in", "code", "copy", "type", "paste", "verification", "otp", "2fa"]
        case .vips: ["vip", "important", "people", "star"]
        case .reading: ["text size", "plain text", "pictures", "images", "chat", "waiting", "translate", "dark mode", "follow up"]
        case .signatures: ["signature", "sign-off", "logo", "picture", "footer", "inbox", "copy", "sent from"]
        case .writing: ["undo send", "attachment", "reply", "send"]
        case .appearance: ["theme", "dark", "light", "white", "developer", "accent", "color", "app icon", "icon", "dock", "size", "roomy", "compact",
                           "contrast", "motion", "accessibility", "color blind", "underline"]
        case .layout: ["tabs", "minimal", "rows", "side by side", "wide", "window", "inset", "panel", "account column", "sidebar", "button names", "toolbar"]
        case .sorting: ["groups", "home", "classifier", "sort now", "bills", "travel", "people", "updates", "newsletters"]
        case .templates: ["template", "canned", "snippet", "fill-in"]
        case .shortcuts: ["keyboard", "keys", "hotkey", "swipe", "trackpad", "gesture", "hover"]
        case .assistant: ["ai", "assistant", "turn off ai", "disable ai", "no ai", "model", "claude", "chatgpt", "gemini", "grok", "ollama",
                          "apple intelligence", "api key", "summaries", "suggest", "actions"]
        case .ask: ["ai", "ask", "answer", "questions", "chat", "instructions"]
        case .permissions: ["ai", "permissions", "allow", "changes", "sending", "activity", "actions"]
        case .writingStyle: ["ai", "instructions", "style", "voice", "tone", "writing profile", "learn", "suggest", "replies", "drafts"]
        case .rules: ["rules", "filters", "block", "blocked", "mute", "muted", "move", "auto archive", "server rules", "sieve", "inbox rules"]
        case .connections: ["ai", "mcp", "agent", "cursor", "codex", "claude code", "vs code", "permissions", "connections", "token"]
        case .backup: ["icloud", "sync", "keychain", "link device", "another device", "devices"]
        case .backupFiles: ["backup", "export", "recovery key", "automatic", "password", "schedule"]
        case .restore: ["restore", "bring back", "undo restore", "import"]
        case .experimental: ["labs", "beta", "early", "dictate", "dictation", "voice", "speak", "space bar", "microphone"]
        case .changelog: ["changelog", "release notes", "what's new", "new version", "update", "changes"]
        case .about: ["version", "made by", "welcome", "feedback", "problem", "update", "upgrade"]
        }
    }

    func matches(_ query: String) -> Bool {
        let words = Self.folded(query)
        guard !words.isEmpty else { return true }
        return Self.holds(title, words) || Self.holds(rawValue, words) || keywords.contains { Self.holds($0, words) }
            || settings.contains { Self.holds($0, words) }
    }

    /// The settings on this page whose names hold the search words, to list under the page.
    func hits(for query: String) -> [String] {
        let words = Self.folded(query)
        guard !words.isEmpty else { return [] }
        return settings.filter { Self.holds($0, words) }
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).trimmingCharacters(in: .whitespaces)
    }

    /// Whether `text` holds the (folded) search words at the start of a word: "ai" finds
    /// "Use AI" and "AI Apps", not "Mailboxes" or "email". Scripts written without spaces
    /// match anywhere.
    static func holds(_ text: String, _ words: String) -> Bool {
        let text = folded(text)
        guard let first = words.unicodeScalars.first else { return true }
        let spaced = first.isASCII || first.properties.isAlphabetic && first.value < 0x2E80
        var from = text.startIndex
        while let range = text.range(of: words, range: from..<text.endIndex) {
            if !spaced || range.lowerBound == text.startIndex { return true }
            let before = text[text.index(before: range.lowerBound)]
            if !(before.isLetter || before.isNumber) { return true }
            from = text.index(after: range.lowerBound)
        }
        return false
    }
}

extension SettingsPage {
    /// One friendly line under the page's title.
    var blurb: String {
        switch self {
        case .general: String(localized: "Language, privacy and what Margin keeps on this device.", table: "Settings")
        case .mailboxes: String(localized: "Your accounts, their names, servers and the addresses you send from.", table: "Settings")
        case .contacts: String(localized: "Address books Margin suggests people from.", table: "Settings")
        case .workspaces: String(localized: "Groups of mailboxes, like Work and Personal.", table: "Settings")
        case .notifications: String(localized: "Alerts for new mail, sign-in codes and meetings.", table: "Settings")
        case .reading: String(localized: "How the mail you open is shown.", table: "Settings")
        case .writing: String(localized: "Undo Send and the reminder for forgotten attachments.", table: "Settings")
        case .signatures: String(localized: "Signatures for all inboxes, a workspace or one inbox, with formatting and pictures.", table: "Settings")
        case .appearance: String(localized: "Theme, size, colors and the app icon.", table: "Settings")
        case .layout: String(localized: "How the window is arranged, and how much each row shows.", table: "Settings")
        case .sorting: String(localized: "The groups Home sorts your inbox into.", table: "Settings")
        case .templates: String(localized: "Text you can insert into any message.", table: "Settings")
        case .shortcuts:
            #if os(macOS)
            String(localized: "Single keys and swipes for the message list.", table: "Settings")
            #else
            String(localized: "What a swipe on a conversation does.", table: "Settings")
            #endif
        case .assistant: String(localized: "One switch for everything AI, and the assistants that do the work.", table: "Settings")
        case .ask: String(localized: "How Ask answers, and what it looks through.", table: "Settings")
        case .permissions: String(localized: "What the assistant and AI apps may change or send.", table: "Settings")
        case .signInCodes: String(localized: "Copying and typing the codes that arrive by mail.", table: "Settings")
        case .vips: String(localized: "The people whose mail always gets through.", table: "Settings")
        case .backupFiles: String(localized: "A file now, automatic backups and the recovery key.", table: "Settings")
        case .restore: String(localized: "Bring back mailboxes, settings and more from a backup file.", table: "Settings")
        case .writingStyle: String(localized: "How the assistant writes for you: your rules, and what it learned from your mail.", table: "Settings")
        case .rules: String(localized: "What happens to new mail, blocked senders and muted conversations.", table: "Settings")
        case .connections: String(localized: "Let AI apps on this Mac use your mail over MCP.", table: "Settings")
        case .backup: String(localized: "Keep your setup the same on every device, or move it to another one.", table: "Settings")
        case .experimental: String(localized: "Early features to try. They may change or go away.", table: "Settings")
        case .changelog: String(localized: "What changed in each version of Margin.", table: "Settings")
        case .about: String(localized: "Version \(Changelog.currentVersion)", table: "Settings")
        }
    }

    /// The name of every setting and button on the page, as the page shows it, so a search for
    /// "undo send" or "recovery key" finds where it lives. Keep in step with the pages.
    var settings: [String] {
        switch self {
        case .general:
            var names = [String(localized: "Language", table: "Settings"), String(localized: "Block trackers, even when pictures are loaded", table: "Settings"),
                         String(localized: "Keep on this device", table: "Settings"), String(localized: "Open recent mail instantly", table: "Settings"), String(localized: "Clear Downloaded Mail", table: "Settings")]
            #if os(macOS)
            names += [String(localized: "Email links", table: "Settings"), String(localized: "Make Margin the default mail app", table: "Settings"), String(localized: "Open at login", table: "Settings"),
                      String(localized: "Hide Margin from screen sharing and recordings", table: "Settings")]
            #endif
            return names
        case .mailboxes:
            return [String(localized: "Add Mailbox…", table: "Settings"), String(localized: "Edit…", table: "Settings"), String(localized: "Sign In Again…", table: "Settings"), String(localized: "Remove", table: "Settings"),
                    String(localized: "Mailbox name", table: "Settings"), String(localized: "Sender name", table: "Settings"), String(localized: "Notify me about", table: "Settings"),
                    String(localized: "Show in All Inboxes", table: "Settings"), String(localized: "Picture", table: "Settings"), String(localized: "Server and sign-in", table: "Settings"),
                    String(localized: "Send as", table: "Settings"), String(localized: "Signatures", table: "Settings")]
        case .workspaces:
            return [String(localized: "Make Workspaces…", table: "Settings"), String(localized: "Edit Workspaces…", table: "Settings")]
        case .contacts:
            #if os(macOS)
            let system = String(localized: "Contacts on this Mac", table: "Settings")
            #else
            let system = String(localized: "Contacts on this device", table: "Settings")
            #endif
            return [system, String(localized: "Accounts", table: "Settings"), String(localized: "Add Address Book…", table: "Settings"), "CardDAV", String(localized: "Refresh Now", table: "Settings")]
        case .notifications:
            var names = [String(localized: "Notify me about", table: "Settings"), String(localized: "People you know", table: "Settings"), String(localized: "All new mail", table: "Settings"),
                         String(localized: "Only VIPs", table: "Settings"), String(localized: "Nothing", table: "Settings"), String(localized: "Sound", table: "Settings"),
                         String(localized: "Meeting reminders", table: "Settings"), String(localized: "Reminder sound", table: "Settings")]
            #if os(macOS)
            names += [String(localized: "Drop-down alerts", table: "Settings"), String(localized: "Menu bar", table: "Settings"), String(localized: "Unread count on the Dock icon", table: "Settings")]
            #else
            names += [String(localized: "Instant notifications", table: "Settings")]
            #endif
            return names
        case .signInCodes:
            var names = [String(localized: "Copy sign-in codes when they arrive", table: "Settings")]
            #if os(macOS)
            names += [String(localized: "Type new codes into the field you're in", table: "Settings")]
            #endif
            return names
        case .vips:
            return [String(localized: "VIPs", table: "Settings"), String(localized: "Remove", table: "Settings")]
        case .reading:
            return [String(localized: "Text size", table: "Settings"), String(localized: "Show mail as", table: "Settings"), String(localized: "Original layout", table: "Settings"), String(localized: "Plain text", table: "Settings"),
                    String(localized: "Show conversations as a chat", table: "Settings"), String(localized: "Offer to translate", table: "Settings"),
                    String(localized: "Dark mode for emails", table: "Settings"), String(localized: "Waiting for reply after", table: "Settings")]
        case .writing:
            return [String(localized: "Undo send", table: "Settings"), String(localized: "Forgotten attachment reminder", table: "Settings")]
        case .signatures:
            return [String(localized: "Add a Signature…", table: "Settings"), String(localized: "For replies and forwards", table: "Settings"), String(localized: "Sent from Margin", table: "Settings")]
        case .templates:
            return [String(localized: "New template", table: "Settings")]
        case .sorting:
            return [String(localized: "Sort new mail as it arrives", table: "Settings"), String(localized: "Sort Now", table: "Settings"), String(localized: "Add Group", table: "Settings"), String(localized: "Start Over", table: "Settings")]
        case .rules:
            return [String(localized: "Add Rule", table: "Settings"), String(localized: "New rule", table: "Settings"), String(localized: "Recent activity", table: "Settings"),
                    String(localized: "Blocked senders", table: "Settings"), String(localized: "Muted conversations", table: "Settings"), String(localized: "Unmute All", table: "Settings")]
        case .appearance:
            return [String(localized: "Theme", table: "Settings"), String(localized: "Accent", table: "Settings"), String(localized: "Size", table: "Settings"), String(localized: "Roomy", table: "Settings"), String(localized: "Compact", table: "Settings"),
                    String(localized: "App icon", table: "Settings"), String(localized: "Color-blind safe", table: "Settings"), String(localized: "Increase contrast", table: "Settings"),
                    String(localized: "Underline links in mail", table: "Settings"), String(localized: "Reduce motion", table: "Settings")]
        case .layout:
            var names = [String(localized: "Layout", table: "Settings"), String(localized: "Rows", table: "Settings"), String(localized: "One line", table: "Settings"), String(localized: "Three lines", table: "Settings")]
            #if os(macOS)
            names += [String(localized: "Inset panel", table: "Settings"), String(localized: "Edge to edge", table: "Settings"), String(localized: "Account column", table: "Settings"), String(localized: "Show button names", table: "Settings")]
            #endif
            return names
        case .shortcuts:
            var names = [String(localized: "Swipe right", table: "Settings"), String(localized: "Swipe left", table: "Settings"), String(localized: "Second action", table: "Settings")]
            #if os(macOS)
            names += [String(localized: "Single-key shortcuts (E, R, J, K…)", table: "Settings"), String(localized: "Start from the keys of", table: "Settings"),
                      String(localized: "Restore the original keys", table: "Settings"), String(localized: "Buttons on hover", table: "Settings")]
            #endif
            return names
        case .assistant:
            return [String(localized: "Use AI", table: "Settings"), String(localized: "Add Assistant", table: "Settings"), String(localized: "Ask and writing", table: "Settings"),
                    String(localized: "Quick suggestions", table: "Settings"), String(localized: "Sorting into groups", table: "Settings"), String(localized: "For actions, use", table: "Settings")]
        case .ask:
            return [String(localized: "Answer length", table: "Settings"), String(localized: "Your instructions", table: "Settings"), String(localized: "Only the mailbox in view", table: "Settings"),
                    String(localized: "Suggested questions to start", table: "Settings")]
        case .permissions:
            return [String(localized: "Allow changes", table: "Settings"), String(localized: "Allow settings changes", table: "Settings"), String(localized: "Allow sending", table: "Settings"),
                    String(localized: "Recent activity", table: "Settings")]
        case .writingStyle:
            return [String(localized: "Instructions for the assistant", table: "Settings"), String(localized: "Learn how I write", table: "Settings"),
                    String(localized: "Suggest short replies", table: "Settings"), String(localized: "Your voice", table: "Settings"), String(localized: "Try it", table: "Settings")]
        case .connections:
            return [String(localized: "Let AI apps use Margin", table: "Settings"), String(localized: "Allow changes", table: "Settings"), String(localized: "Allow settings changes", table: "Settings"),
                    String(localized: "Allow sending", table: "Settings"), String(localized: "Mailboxes AI apps can see", table: "Settings"), String(localized: "New token", table: "Settings")]
        case .backup:
            return [String(localized: "Sync with iCloud", table: "Settings"), String(localized: "Sync Now", table: "Settings"), String(localized: "Link Another Device…", table: "Settings")]
        case .backupFiles:
            return [String(localized: "Export Backup…", table: "Settings"), String(localized: "Include mail passwords and API keys", table: "Settings"),
                    String(localized: "Automatic backups", table: "Settings"), String(localized: "Back Up Now", table: "Settings"), String(localized: "Recovery key", table: "Settings")]
        case .restore:
            return [String(localized: "Restore from Backup…", table: "Settings"), String(localized: "Undo Restore", table: "Settings")]
        case .experimental:
            return [String(localized: "Hold Space to dictate", table: "Settings")]
        case .changelog:
            return Changelog.releases.flatMap { $0.changes.map(\.title) }
        case .about:
            return [String(localized: "Show Welcome", table: "Settings"), String(localized: "Something broken?", table: "Settings"), String(localized: "Check for Updates…", table: "Settings"),
                    String(localized: "Check for updates automatically", table: "Settings"), String(localized: "Download and install updates", table: "Settings")]
        }
    }
}

/// A page's icon: a white symbol on a rounded tile in the page's colour.
struct SettingsIcon: View {
    let page: SettingsPage
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: page.symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(page.tint, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
    }
}

/// The top of every page: the page's icon, its name and one line about what's on it, centred
/// over the settings so every page opens the same way.
struct SettingsHeader: View {
    let page: SettingsPage

    init(_ page: SettingsPage) { self.page = page }

    /// On the page itself, not in a box: the page's title, nothing above it.
    var body: some View {
        // As the section's footer: as a header, the group after it lost its own header's style.
        Section {
        } footer: {
            VStack(spacing: 0) {
                SettingsIcon(page: page, size: Look.gap(40))
                Text(verbatim: page.title)
                    .font(.system(size: Look.size(20), weight: .bold))
                    .foregroundStyle(Ink.primary)
                    .padding(.top, Space.s)
                Text(verbatim: page.blurb)
                    .font(TypeScale.label)
                    .foregroundStyle(Ink.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .textCase(nil)
            #if os(macOS)
            // The page runs up under the window's bar, so its header sits beside Back and Forward.
            .padding(.top, Space.l)
            #endif
            .padding(.bottom, Space.s)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
    }
}

/// The name over a group of settings, the same on every page.
struct SettingsSectionTitle: View {
    let title: Text

    init(_ title: LocalizedStringKey) { self.title = Text(title) }

    var body: some View {
        title
            .font(TypeScale.rowStrong)
            .foregroundStyle(Ink.primary)
            .textCase(nil)
    }
}

/// At the top of every AI page besides the switch's own: whether AI is on, said plainly, with
/// the way to turn it back on. Always there and always the same height, so nothing moves when
/// it's switched.
struct AIOffNotice: View {
    @Bindable var model: MailModel

    var body: some View {
        Section {
            HStack(spacing: Space.m) {
                Image(systemName: model.usesAI ? "checkmark" : "power")
                    .font(.system(size: Look.size(13), weight: .semibold))
                    .foregroundStyle(model.usesAI ? Status.done : Ink.secondary)
                    .frame(width: Look.gap(28), height: Look.gap(28))
                    .background(Fill.two, in: RoundedRectangle(cornerRadius: Look.gap(7), style: .continuous))
                ZStack(alignment: .leading) {
                    SettingLabel("AI is on", detail: "Everything on this page works. The switch on the AI page turns all of it off.")
                        .opacity(model.usesAI ? 1 : 0)
                        .accessibilityHidden(!model.usesAI)
                    SettingLabel("AI is off", detail: "Nothing on this page runs until AI is turned on again. Your choices here are kept.")
                        .opacity(model.usesAI ? 0 : 1)
                        .accessibilityHidden(model.usesAI)
                }
                Spacer(minLength: Space.s)
                ZStack(alignment: .trailing) {
                    Button(String(localized: "Turn On AI", table: "Settings")) { model.usesAI = true }
                        .opacity(model.usesAI ? 0 : 1)
                        .disabled(model.usesAI)
                        .accessibilityHidden(model.usesAI)
                    Button(String(localized: "Open", table: "Settings")) { model.settingsPageRequest = SettingsPage.assistant.rawValue }
                        .opacity(model.usesAI ? 1 : 0)
                        .disabled(!model.usesAI)
                        .accessibilityHidden(!model.usesAI)
                }
            }
        }
    }
}

extension EnvironmentValues {
    /// The colour of the Settings page in view.
    @Entry var settingsTint: Color = .accentColor
}

/// A Settings row's label: the title, and an optional line under it.
struct SettingLabel: View {
    let title: Text
    var detail: Text?

    init(_ title: LocalizedStringKey, detail: LocalizedStringKey? = nil) {
        self.title = Text(title)
        self.detail = detail.map { Text($0) }
    }

    init(verbatim title: String, detail: String? = nil) {
        self.title = Text(verbatim: title)
        self.detail = detail.map { Text(verbatim: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            title.font(TypeScale.row)
            if let detail {
                detail.font(TypeScale.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// What a list says while it's empty.
struct SettingsEmptyRow: View {
    let text: Text

    init(_ text: LocalizedStringKey) { self.text = Text(text) }

    var body: some View {
        text.foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Shared pages

/// Notifications: what to hear about, how, and meetings. Sign-in codes and VIPs are pages under it.
struct NotificationSettings: View {
    @Bindable var model: MailModel

    static func symbol(_ alerts: NewMailAlerts) -> String {
        switch alerts {
        case .people: "person.2.fill"
        case .all: "tray.full.fill"
        case .vips: "star.fill"
        case .none: "bell.slash.fill"
        }
    }

    static func title(_ alerts: NewMailAlerts) -> String {
        switch alerts {
        case .people: String(localized: "People you know", table: "Settings")
        case .all: String(localized: "All new mail", table: "Settings")
        case .vips: String(localized: "Only VIPs", table: "Settings")
        case .none: String(localized: "Nothing", table: "Settings")
        }
    }

    static func detail(_ alerts: NewMailAlerts) -> String {
        switch alerts {
        case .people: String(localized: "Contacts, VIPs and people you've written to, plus sign-in codes. Newsletters and updates stay quiet.", table: "Settings")
        case .all: String(localized: "Every message that lands in your inboxes.", table: "Settings")
        case .vips: String(localized: "Just the people you marked as VIP, plus sign-in codes.", table: "Settings")
        case .none: String(localized: "No notifications. The badge still counts unread mail.", table: "Settings")
        }
    }

    var body: some View {
        Form {
            SettingsHeader(.notifications)
            Section {
                ChoiceList(options: [NewMailAlerts.people, .all, .vips, .none], selection: $model.newMailAlerts,
                           symbol: Self.symbol, title: Self.title, detail: Self.detail)
            } header: {
                Text("Notify me about", tableName: "Settings")
            }
            Section {
                Picker(selection: Binding(get: { model.alertSound }, set: { model.alertSound = $0 })) {
                    ForEach(AlertSound.choices) { Text(verbatim: $0.title).tag($0) }
                } label: { SettingLabel("Sound", detail: "Played with each notification.") }
                Picker(selection: Binding(get: { model.eventReminderMinutes }, set: { model.eventReminderMinutes = $0 })) {
                    Text("Off", tableName: "Settings").tag(0)
                    ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) minutes before", tableName: "Settings").tag($0) }
                } label: { SettingLabel("Meeting reminders", detail: "A heads-up before meetings from your invitations.") }
                if model.eventReminderMinutes > 0 {
                    Picker(selection: Binding(get: { model.reminderSound }, set: { model.reminderSound = $0 })) {
                        ForEach(AlertSound.choices) { Text(verbatim: $0.title).tag($0) }
                    } label: { SettingLabel("Reminder sound", detail: "Its own sound, so a meeting doesn't sound like an email.") }
                }
            } footer: {
                Text("Each mailbox can have its own setting: Mailboxes → Edit…. Workspaces you're not in stay quiet.", tableName: "Settings")
            }
            #if os(iOS)
            if model.hasPushRelay {
                Section {
                    Toggle(String(localized: "Instant notifications", table: "Settings"), isOn: Binding(get: { model.usesPushRelay }, set: { model.usesPushRelay = $0 }))
                } footer: {
                    Text("For Gmail, Outlook and Fastmail, your provider tells Margin's relay that new mail arrived, and the relay wakes this device. The relay never sees your mail. Off, this device is removed from the relay and checks for mail in the background instead, which iOS may only allow every so often.", tableName: "Settings")
                }
            }
            #endif
            #if os(macOS)
            Section(String(localized: "At the top of the screen", table: "Settings")) {
                Toggle(isOn: Binding(get: { model.showsDropDownAlerts }, set: { model.showsDropDownAlerts = $0 })) {
                    SettingLabel("Drop-down alerts", detail: "Slide down from the top of the screen with sign-in codes, links and Reply.")
                }
                Toggle(isOn: Binding(get: { model.showsMenuBarItem }, set: { model.showsMenuBarItem = $0 })) {
                    SettingLabel("Menu bar", detail: "Sign-in codes, links and the latest mail in the menu bar.")
                }
                Toggle(isOn: Binding(get: { model.showsDockBadge }, set: { model.showsDockBadge = $0 })) {
                    SettingLabel("Unread count on the Dock icon", detail: "Drops as soon as you read your mail.")
                }
            }
            #endif
        }
        .formStyle(.grouped)
    }
}

/// Sign-in codes: copying them, and on the Mac typing them in.
struct SignInCodeSettings: View {
    @Bindable var model: MailModel

    var body: some View {
        Form {
            SettingsHeader(.signInCodes)
            Section {
                Toggle(isOn: Binding(get: { model.copiesSignInCodes }, set: { model.copiesSignInCodes = $0 })) {
                    SettingLabel("Copy sign-in codes when they arrive", detail: "Ready to paste the moment the email lands.")
                }
                #if os(macOS)
                if MailModel.canTypeIntoOtherApps {
                    Toggle(isOn: Binding(get: { model.typesSignInCodes }, set: { on in
                        model.typesSignInCodes = on
                        if on { MailModel.requestTypingPermission() }
                    })) {
                        SettingLabel("Type new codes into the field you're in", detail: "No pasting: the code appears where your cursor is.")
                    }
                } else {
                    LabeledContent("Type codes for you") { Text("Needs the direct download of Margin", tableName: "Settings").foregroundStyle(Ink.tertiary) }
                }
                #endif
            } header: {
                Text("Sign-in codes", tableName: "Settings")
            } footer: {
                #if os(macOS)
                Text("Typing codes in needs Accessibility permission. macOS doesn't let App Store apps type into other apps.", tableName: "Settings")
                #endif
            }
        }
        .formStyle(.grouped)
    }
}

/// VIPs: the people marked as VIP, each with Remove.
struct VIPSettings: View {
    @Bindable var model: MailModel

    var body: some View {
        Form {
            SettingsHeader(.vips)
            Section {
                if model.vipAddresses.isEmpty {
                    SettingsEmptyRow("Add someone from a conversation's … menu: Add to VIPs.")
                }
                ForEach(model.vipAddresses.sorted(), id: \.self) { address in
                    LabeledContent {
                        Button(String(localized: "Remove", table: "Settings")) { model.vipAddresses.remove(address) }.buttonStyle(.borderless)
                    } label: {
                        Text(verbatim: address)
                    }
                }
            } header: {
                Text("VIPs", tableName: "Settings")
            }
        }
        .formStyle(.grouped)
    }
}

/// Ask: how answers come out and what they draw on.
struct AskSettingsPage: View {
    @Bindable var model: MailModel

    var body: some View {
        Form {
            SettingsHeader(.ask)
            AIOffNotice(model: model)
            AskSettingsSection(model: model).disabled(!model.usesAI)
        }
        .formStyle(.grouped)
    }
}

/// Permissions: what the assistant, and AI apps connected to Margin, may change or send.
struct PermissionSettingsPage: View {
    @Bindable var model: MailModel

    var body: some View {
        Form {
            SettingsHeader(.permissions)
            AIOffNotice(model: model)
            AgentPermissionsSection(model: model).disabled(!model.usesAI)
        }
        .formStyle(.grouped)
    }
}

/// Reading: how mail looks and what it may do.
struct ReadingSettings: View {
    @Bindable var model: MailModel

    var body: some View {
        Form {
            SettingsHeader(.reading)
            Section {
                LabeledContent {
                    HStack(spacing: Space.s) {
                        Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                        Slider(value: $model.textScale, in: 0.8...2).frame(maxWidth: 180)
                        Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
                        Text("\(Int((model.textScale * 100).rounded()))%", tableName: "Settings").monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                } label: {
                    #if os(macOS)
                    SettingLabel("Email text size", detail: "For the mail you read, on top of the app size (Appearance). ⌥⌘+ and ⌥⌘− change it.")
                    #else
                    SettingLabel("Email text size", detail: "For the mail you read, on top of the app size (Appearance).")
                    #endif
                }
                // A line of mail at the chosen size.
                Text("Hi Alex, the flat by the river is free in May. Shall I book it?", tableName: "Settings")
                    .font(.system(size: Look.size(15) * model.textScale))
                    .foregroundStyle(Ink.secondary)
                    .padding(.vertical, 2)
            } header: {
                Text("Text", tableName: "Settings")
            }
            Section {
                ChoiceList(options: [false, true], selection: $model.prefersPlainText,
                           symbol: { $0 ? "text.alignleft" : "photo.on.rectangle" },
                           title: { $0 ? String(localized: "Plain text", table: "Settings") : String(localized: "Original layout", table: "Settings") },
                           detail: { $0 ? String(localized: "Just the words, in Margin's own font. Fastest and calmest.", table: "Settings")
                                        : String(localized: "As the sender designed it, without scripts. Pictures from the web wait until you allow them.", table: "Settings") })
            } header: {
                Text("Show mail as", tableName: "Settings")
            }
            Section {
                Toggle(isOn: Binding(get: { model.showsAsChat }, set: { model.showsAsChat = $0 })) {
                    SettingLabel("Show conversations as a chat", detail: "Short back-and-forth reads as bubbles instead of a stack of emails.")
                }
                Toggle(isOn: $model.offersTranslation) {
                    SettingLabel("Offer to translate", detail: "Mail in a language you don't read gets a Translate button. It's translated on this device.")
                }
                Toggle(isOn: $model.darkensMail) {
                    SettingLabel("Dark mode for emails", detail: "Light emails without pictures turn dark with Margin. Emails with pictures sit on a white sheet.")
                }
            } header: {
                Text("Conversations", tableName: "Settings")
            }
            Section {
                Picker(selection: $model.followUpDays) {
                    ForEach([2, 3, 5, 7], id: \.self) { Text("\($0) days", tableName: "Settings").tag($0) }
                } label: { SettingLabel("Waiting for reply after", detail: "When mail you sent counts as unanswered.") }
            } header: {
                Text("Follow-ups", tableName: "Settings")
            }
        }
        .formStyle(.grouped)
    }
}

/// Writing: what happens around Send. Signatures and Templates sit under it in the sidebar.
struct WritingSettings: View {
    @Bindable var model: MailModel

    var body: some View {
        Form {
            SettingsHeader(.writing)
            Section {
                Picker(selection: $model.undoSendDelay) {
                    Text("Off", tableName: "Settings").tag(0)
                    ForEach([5, 10, 20, 30], id: \.self) { Text("\($0) seconds", tableName: "Settings").tag($0) }
                } label: { SettingLabel("Undo send", detail: "How long you have to take a message back after Send.") }
                Toggle(isOn: Binding(get: { model.remindsAboutAttachments }, set: { model.remindsAboutAttachments = $0 })) {
                    SettingLabel("Forgotten attachment reminder", detail: "Asks before sending when a message mentions an attachment but has none.")
                }
            } header: {
                Text("Sending", tableName: "Settings")
            }
        }
        .formStyle(.grouped)
    }
}

/// General: Margin's language, the default mail app, privacy, and the mail kept on this device.
struct GeneralSettings: View {
    @Bindable var model: MailModel

    var body: some View {
        Form {
            SettingsHeader(.general)
            Section {
                LabeledContent { LanguageSetting() } label: { SettingLabel("Language", detail: "Margin's own language, apart from the system's.") }
                #if os(macOS)
                LabeledContent {
                    let _ = model.defaultAppRevision
                    if model.isDefaultMailApp {
                        Text("Open in Margin", tableName: "Settings").foregroundStyle(Ink.secondary)
                    } else {
                        Button(String(localized: "Make Margin the default mail app", table: "Settings")) { Task { await model.becomeDefaultMailApp() } }
                    }
                } label: { SettingLabel("Email links", detail: "What opens when you click an email address anywhere on this Mac.") }
                OpenAtLoginSetting()
                #endif
            }
            Section {
                Toggle(isOn: Binding(get: { model.blocksTrackers }, set: { model.blocksTrackers = $0 })) {
                    SettingLabel("Block trackers, even when pictures are loaded", detail: "Senders can't see when you open their mail.")
                }
                #if os(macOS)
                Toggle(isOn: Binding(get: { model.hidesFromScreenSharing }, set: { model.hidesFromScreenSharing = $0 })) {
                    SettingLabel("Hide Margin from screen sharing and recordings", detail: "Others in a call see an empty window instead of your mail.")
                }
                #endif
            } header: {
                Text("Privacy", tableName: "Settings")
            } footer: {
                Text("Tracker blocking removes the hidden pictures that report when you open mail, and takes the tracking out of links.", tableName: "Settings")
            }
            SavedMailSection(model: model)
        }
        .formStyle(.grouped)
    }
}

/// Writing Style: the person's rules for everything the assistant writes, and what Margin
/// learned from their mail.
struct WritingStyleSettings: View {
    @Bindable var model: MailModel
    @State private var instructions = ""

    var body: some View {
        Form {
            SettingsHeader(.writingStyle)
            AIOffNotice(model: model)
            Group {
                Section {
                    TextEditor(text: $instructions)
                        .frame(minHeight: 90)
                        .onChange(of: instructions) { _, value in model.writingInstructions = value }
                } header: {
                    Text("Instructions for the assistant", tableName: "Settings")
                } footer: {
                    Text("Followed in every draft and suggested reply, for example: “No exclamation marks. Sign off with just my first name.”", tableName: "Settings")
                }
                WritingProfileView(model: model)
            }
            .disabled(!model.usesAI)
        }
        .formStyle(.grouped)
        .onAppear { instructions = model.writingInstructions }
    }
}

/// Workspaces: the list, and the editor.
struct WorkspacesSettings: View {
    let model: MailModel
    @State private var editing = false

    var body: some View {
        Form {
            SettingsHeader(.workspaces)
            Section {
                if model.workspaces.isEmpty {
                    SettingsEmptyRow("No workspaces yet. Group your mailboxes, like Work and Personal, to see one group at a time.")
                }
                ForEach(model.workspaces) { workspace in
                    HStack(spacing: Space.s) {
                        WorkspaceBadge(workspace: workspace, size: 22)
                        Text(verbatim: workspace.name)
                        Spacer()
                        Text(verbatim: model.accounts.filter { workspace.accounts.contains($0.id) }.map(\.label).formatted(.list(type: .and)))
                            .foregroundStyle(Ink.tertiary).lineLimit(1)
                    }
                }
            } footer: {
                Text("Switch from the top of the sidebar, or with ⌥⌘1, ⌥⌘2…. Workspaces you're not in check mail quietly: no alerts except sign-in codes.", tableName: "Settings")
            }
            Section {
                Button(model.workspaces.isEmpty ? LocalizedStringKey("Make Workspaces…") : LocalizedStringKey("Edit Workspaces…")) { editing = true }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $editing) { WorkspaceEditor(model: model) }
    }
}

/// Experimental: early features, each off until turned on.
struct ExperimentalSettings: View {
    @Bindable var model: MailModel

    var body: some View {
        Form {
            SettingsHeader(.experimental)
            #if os(macOS)
            Section {
                Toggle(isOn: Binding(get: { model.holdSpaceDictates }, set: { model.holdSpaceDictates = $0 })) {
                    SettingLabel("Hold Space to dictate",
                                 detail: "While writing, hold the space bar and speak. A short press is still a space.")
                }
            }
            #endif
        }
        .formStyle(.grouped)
    }
}

#if os(macOS)
import ServiceManagement

/// Open at login, through the system's own login items. Scheduled mail, snoozes, reminders and
/// rules run on this Mac, so they need Margin open; this keeps it open after a restart.
private struct OpenAtLoginSetting: View {
    @State private var status = SMAppService.mainApp.status
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { status == .enabled || status == .requiresApproval }, set: set)) {
                SettingLabel("Open at login", detail: "So scheduled mail goes out, snoozed mail comes back and rules keep running after you restart.")
            }
            if status == .requiresApproval {
                HStack(spacing: 6) {
                    Text("Allow Margin in System Settings to finish.", tableName: "Settings").font(TypeScale.caption).foregroundStyle(Ink.secondary)
                    Button(String(localized: "Open Login Items", table: "Settings")) { SMAppService.openSystemSettingsLoginItems() }
                        .buttonStyle(.link)
                        .font(TypeScale.caption)
                }
            }
            if let problem {
                Text(verbatim: problem).font(TypeScale.caption).foregroundStyle(Status.danger)
            }
        }
        .onAppear { status = SMAppService.mainApp.status }
    }

    private func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        status = SMAppService.mainApp.status
    }
}
#endif
