import MailCore
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The pages of Settings, the same on the Mac and on iPhone and iPad, with words to find them by.
enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case mailboxes, contacts, workspaces, notifications, reading, writing, appearance, sorting, templates, shortcuts, assistant, rules, connections, backup, experimental, about

    var id: String { rawValue }

    /// Pages each platform shows: shortcuts and connections are the Mac's.
    static var available: [SettingsPage] {
        #if os(macOS)
        allCases
        #else
        allCases.filter { $0 != .shortcuts && $0 != .connections }
        #endif
    }

    /// The sidebar's groups, as in System Settings: mail, how it behaves, how it looks, the
    /// assistant and AI apps, then your data.
    static var sections: [[SettingsPage]] {
        [[.mailboxes, .contacts, .workspaces], [.notifications, .reading, .writing, .templates], [.appearance, .shortcuts],
         [.assistant, .sorting, .rules, .connections], [.backup, .experimental, .about]]
            .map { $0.filter(available.contains) }
    }

    /// The groups, with only the pages that match a search.
    static func sections(matching query: String) -> [[SettingsPage]] {
        sections.map { $0.filter { $0.matches(query) } }.filter { !$0.isEmpty }
    }

    var title: String {
        switch self {
        case .mailboxes: String(localized: "Mailboxes")
        case .contacts: String(localized: "Contacts")
        case .workspaces: String(localized: "Workspaces")
        case .notifications: String(localized: "Notifications")
        case .reading: String(localized: "Reading")
        case .writing: String(localized: "Writing")
        case .appearance: String(localized: "Appearance")
        case .sorting: String(localized: "Sorting")
        case .templates: String(localized: "Templates")
        case .shortcuts: String(localized: "Shortcuts")
        case .assistant: String(localized: "Assistant")
        case .rules: String(localized: "Rules")
        case .connections: String(localized: "Connections")
        case .backup: String(localized: "Backup and Devices")
        case .experimental: String(localized: "Experimental")
        case .about: String(localized: "About")
        }
    }

    var symbol: String {
        switch self {
        case .mailboxes: "tray.2.fill"
        case .contacts: "person.crop.circle.fill"
        case .workspaces: "square.stack.fill"
        case .notifications: "bell.badge.fill"
        case .reading: "text.justify.left"
        case .writing: "square.and.pencil"
        case .appearance: "paintbrush.fill"
        case .sorting: "square.stack.3d.up.fill"
        case .templates: "doc.on.doc.fill"
        case .shortcuts: "keyboard.fill"
        case .assistant: "sparkles"
        case .rules: "line.3.horizontal.decrease.circle.fill"
        case .connections: "point.3.connected.trianglepath.dotted"
        case .backup: "externaldrive.fill"
        case .experimental: "flask.fill"
        case .about: "info.circle.fill"
        }
    }

    /// The icon tile's colour.
    var tint: Color {
        switch self {
        case .mailboxes: Palette.account(0)
        case .contacts: Palette.account(3)
        case .workspaces: Palette.account(5)
        case .notifications: Palette.account(1)
        case .reading: Palette.account(3)
        case .writing: Palette.account(4)
        case .appearance: Palette.account(6)
        case .sorting: Palette.account(7)
        case .templates: Palette.account(8)
        case .shortcuts: Ink.tertiary
        case .assistant: Palette.account(2)
        case .rules: Palette.account(7)
        case .connections: Palette.account(9)
        case .backup: Palette.account(10)
        case .experimental: Palette.account(4)
        case .about: Ink.tertiary
        }
    }

    /// Words a search finds this page by, besides its title.
    var keywords: [String] {
        switch self {
        case .mailboxes: ["account", "add", "remove", "signature", "alias", "send as", "server", "password", "picture", "imap", "smtp", "all inboxes"]
        case .contacts: ["people", "address book", "carddav", "microsoft", "google", "outlook", "rooms", "calendar", "suggestions"]
        case .workspaces: ["work", "personal", "group", "switch"]
        case .notifications: ["alert", "sound", "vip", "sign-in", "code", "menu bar", "notch", "drop down", "meeting", "reminder", "badge", "quiet"]
        case .reading: ["text size", "plain text", "pictures", "images", "tracker", "privacy", "screen sharing", "chat", "waiting"]
        case .writing: ["undo send", "instructions", "style", "default mail app", "email links", "mailto", "reply"]
        case .appearance: ["theme", "dark", "light", "white", "developer", "accent", "color", "app icon", "icon", "dock", "layout", "tabs", "minimal", "rows", "language", "contrast", "motion", "swipe"]
        case .sorting: ["groups", "home", "classifier", "sort now", "bills", "travel"]
        case .templates: ["template", "canned", "snippet"]
        case .shortcuts: ["keyboard", "keys", "hotkey"]
        case .assistant: ["ai", "model", "claude", "chatgpt", "gemini", "grok", "ollama", "apple intelligence", "writing profile", "suggest"]
        case .rules: ["rules", "filters", "block", "blocked", "mute", "muted", "move", "auto archive"]
        case .connections: ["mcp", "agent", "cursor", "codex", "claude code", "vs code", "permissions"]
        case .backup: ["restore", "export", "recovery key", "icloud", "sync", "keychain", "link device", "another device", "automatic"]
        case .experimental: ["labs", "beta", "block editor", "slash", "headings", "lists", "checklist", "formatting", "blocks", "dictate", "dictation", "voice", "speak", "space bar", "microphone"]
        case .about: ["version", "made by", "welcome"]
        }
    }

    func matches(_ query: String) -> Bool {
        let words = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return true }
        return title.lowercased().contains(words) || rawValue.contains(words) || keywords.contains { $0.contains(words) }
    }
}

extension SettingsPage {
    /// One friendly line under the page's title.
    var blurb: String {
        switch self {
        case .mailboxes: String(localized: "Accounts, signatures and the addresses you send from.")
        case .contacts: String(localized: "Address books Margin suggests people from.")
        case .workspaces: String(localized: "Groups of mailboxes, like Work and Personal.")
        case .notifications: String(localized: "Alerts for new mail, sign-in codes and meetings.")
        case .reading: String(localized: "How mail is shown, and privacy.")
        case .writing: String(localized: "Sending, email links and instructions for the assistant.")
        case .appearance: String(localized: "Theme, layout, colors and language.")
        case .sorting: String(localized: "The groups Home sorts your inbox into.")
        case .templates: String(localized: "Text you can insert into any message.")
        case .shortcuts: String(localized: "Single-key shortcuts for the message list.")
        case .assistant: String(localized: "The model that drafts replies and sorts mail. Off by default.")
        case .rules: String(localized: "What happens to new mail, blocked senders and muted conversations.")
        case .connections: String(localized: "Let AI apps on this Mac use your mail over MCP.")
        case .backup: String(localized: "Back up your setup, or move it to another device.")
        case .experimental: String(localized: "Early features to try. They may change or go away.")
        case .about: String(localized: "Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
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

/// The top of every page, as in System Settings: the page's big icon, its name and one line
/// about what's on it.
struct SettingsHeader: View {
    let page: SettingsPage

    init(_ page: SettingsPage) { self.page = page }

    /// On the page itself, not in a box: the page's title, nothing above it.
    var body: some View {
        Section {
        } header: {
            HStack(spacing: Space.m) {
                icon
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: page == .about ? Self.appName : page.title)
                        .font(.system(size: Look.size(20), weight: .bold))
                        .foregroundStyle(Ink.primary)
                    Text(verbatim: page.blurb).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .textCase(nil)
            .padding(.top, 4)
            .padding(.bottom, 6)
        }
    }

    private static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName")) as? String ?? "Margin"
    }

    /// About shows Margin's own icon on the Mac; every other page its tile.
    @ViewBuilder
    private var icon: some View {
        #if os(macOS)
        if page == .about {
            Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 48, height: 48).padding(-4)
        } else {
            SettingsIcon(page: page, size: 40)
        }
        #else
        SettingsIcon(page: page, size: 40)
        #endif
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

    init(verbatim title: String) {
        self.title = Text(verbatim: title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            title
            if let detail {
                detail.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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

/// Notifications: what to hear about, how, VIPs, sign-in codes, meetings.
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
        case .people: String(localized: "People you know")
        case .all: String(localized: "All new mail")
        case .vips: String(localized: "Only VIPs")
        case .none: String(localized: "Nothing")
        }
    }

    static func detail(_ alerts: NewMailAlerts) -> String {
        switch alerts {
        case .people: String(localized: "Contacts, VIPs and people you've written to, plus sign-in codes. Newsletters and updates stay quiet.")
        case .all: String(localized: "Every message that lands in your inboxes.")
        case .vips: String(localized: "Just the people you marked as VIP, plus sign-in codes.")
        case .none: String(localized: "No notifications. The badge still counts unread mail.")
        }
    }

    var body: some View {
        Form {
            SettingsHeader(.notifications)
            Section {
                ChoiceList(options: [NewMailAlerts.people, .all, .vips, .none], selection: $model.newMailAlerts,
                           symbol: Self.symbol, title: Self.title, detail: Self.detail)
            } header: {
                Text("Notify me about")
            }
            Section {
                Picker(selection: Binding(get: { model.alertSound }, set: { model.alertSound = $0 })) {
                    ForEach(AlertSound.choices) { Text(verbatim: $0.title).tag($0) }
                } label: { SettingLabel("Sound", detail: "Played with each notification.") }
                Picker(selection: Binding(get: { model.eventReminderMinutes }, set: { model.eventReminderMinutes = $0 })) {
                    Text("Off").tag(0)
                    ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) minutes before").tag($0) }
                } label: { SettingLabel("Meeting reminders", detail: "A heads-up before meetings from your invitations.") }
                if model.eventReminderMinutes > 0 {
                    Picker(selection: Binding(get: { model.reminderSound }, set: { model.reminderSound = $0 })) {
                        ForEach(AlertSound.choices) { Text(verbatim: $0.title).tag($0) }
                    } label: { SettingLabel("Reminder sound", detail: "Its own sound, so a meeting doesn't sound like an email.") }
                }
            } footer: {
                Text("Each mailbox can have its own setting: Mailboxes → Edit…. Workspaces you're not in stay quiet.")
            }
            #if os(iOS)
            if model.hasPushRelay {
                Section {
                    Toggle("Instant notifications", isOn: Binding(get: { model.usesPushRelay }, set: { model.usesPushRelay = $0 }))
                } footer: {
                    Text("For Gmail, Outlook and Fastmail, your provider tells Margin's relay that new mail arrived, and the relay wakes this device. The relay never sees your mail. Off, this device is removed from the relay and checks for mail in the background instead, which iOS may only allow every so often.")
                }
            }
            #endif
            #if os(macOS)
            Section("At the top of the screen") {
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
                    LabeledContent("Type codes for you") { Text("Needs the direct download of Margin").foregroundStyle(Ink.tertiary) }
                }
                #endif
            } header: {
                Text("Sign-in codes")
            } footer: {
                #if os(macOS)
                Text("Typing codes in needs Accessibility permission. macOS doesn't let App Store apps type into other apps.")
                #endif
            }
            Section {
                if model.vipAddresses.isEmpty {
                    SettingsEmptyRow("Add someone from a conversation's … menu: Add to VIPs.")
                }
                ForEach(model.vipAddresses.sorted(), id: \.self) { address in
                    LabeledContent {
                        Button("Remove") { model.vipAddresses.remove(address) }.buttonStyle(.borderless)
                    } label: {
                        Text(verbatim: address)
                    }
                }
            } header: {
                Text("VIPs")
            }
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
                        Text("\(Int((model.textScale * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                } label: { SettingLabel("Text size", detail: "For the mail you read; the rest of Margin stays the same.") }
                // A line of mail at the chosen size.
                Text("Hi Alex, the flat by the river is free in May. Shall I book it?")
                    .font(.system(size: Look.size(15) * model.textScale))
                    .foregroundStyle(Ink.secondary)
                    .padding(.vertical, 2)
            } header: {
                Text("Text")
            }
            Section {
                ChoiceList(options: [false, true], selection: $model.prefersPlainText,
                           symbol: { $0 ? "text.alignleft" : "photo.on.rectangle" },
                           title: { $0 ? String(localized: "Plain text") : String(localized: "Original layout") },
                           detail: { $0 ? String(localized: "Just the words, in Margin's own font. Fastest and calmest.")
                                        : String(localized: "As the sender designed it, without scripts. Pictures from the web wait until you allow them.") })
            } header: {
                Text("Show mail as")
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
                Picker(selection: $model.followUpDays) {
                    ForEach([2, 3, 5, 7], id: \.self) { Text("\($0) days").tag($0) }
                } label: { SettingLabel("Waiting for reply after", detail: "When mail you sent counts as unanswered.") }
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
                Text("Privacy")
            } footer: {
                Text("Tracker blocking removes the hidden pictures that report when you open mail, and takes the tracking out of links.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Writing: sending, the assistant's instructions, and email links.
struct WritingSettings: View {
    @Bindable var model: MailModel
    @State private var instructions = ""

    var body: some View {
        Form {
            SettingsHeader(.writing)
            Section {
                Picker(selection: $model.undoSendDelay) {
                    Text("Off").tag(0)
                    ForEach([5, 10, 20, 30], id: \.self) { Text("\($0) seconds").tag($0) }
                } label: { SettingLabel("Undo send", detail: "How long you have to take a message back after Send.") }
                Toggle(isOn: Binding(get: { model.remindsAboutAttachments }, set: { model.remindsAboutAttachments = $0 })) {
                    SettingLabel("Forgotten attachment reminder", detail: "Asks before sending when a message mentions an attachment but has none.")
                }
                #if os(macOS)
                LabeledContent("Email links") {
                    let _ = model.defaultAppRevision
                    if model.isDefaultMailApp {
                        Text("Open in Margin").foregroundStyle(Ink.secondary)
                    } else {
                        Button("Make Margin the default mail app") { Task { await model.becomeDefaultMailApp() } }
                    }
                }
                #endif
            }
            SentFromMarginSection(model: model)
            Section {
                TextEditor(text: $instructions)
                    .frame(minHeight: 90)
                    .onChange(of: instructions) { _, value in model.writingInstructions = value }
            } header: {
                Text("Instructions for the assistant")
            } footer: {
                Text("Followed in every draft and suggested reply, for example: “No exclamation marks. Sign off with just my first name.”")
            }
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
                Text("Switch from the top of the sidebar, or with ⌥⌘1, ⌥⌘2…. Workspaces you're not in check mail quietly: no alerts except sign-in codes.")
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
