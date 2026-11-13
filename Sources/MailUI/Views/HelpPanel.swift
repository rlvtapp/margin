import MailCore
import SwiftUI

extension MailModel {
    /// Where feedback and problem reports go, for now.
    static let feedbackAddress = "hello@relevate.app"

    /// A new message to the Margin team with what was said and which version this is. Nothing
    /// goes out until the person sends it.
    public func startFeedback(_ text: String = "", problem: Bool = false) {
        var state = ComposeState(account: currentAccount)
        state.to = Self.feedbackAddress
        state.draft.subject = problem ? "Margin: a problem" : "Margin feedback"
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        state.draft.text = (said.isEmpty ? "\n" : said + "\n") + "\n— " + Self.appDescription + state.draft.text
        isAsking = false
        isShowingHelp = false
        compose = state
    }

    /// "Margin 1.4 (20261112.2117) · macOS 26.1", for feedback.
    static var appDescription: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if os(macOS)
        let system = "macOS"
        #else
        let system = "iOS"
        #endif
        return "Margin \(version) (\(build)) · \(system) \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }
}

/// Help, as a panel beside the mail (the ? above Settings): how each mailbox is doing, short
/// how-tos for what Margin does with a button that goes there, the keys used most, and a way to
/// tell the Margin team something. A search narrows it all.
struct HelpPanel: View {
    let model: MailModel
    static let width: CGFloat = 320
    @State private var query = ""
    @State private var open: Set<String> = []
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    struct Topic: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let lines: [String]
        var action: (title: String, run: () -> Void)?
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Help").font(.system(size: Look.size(17), weight: .semibold))
                Spacer()
                IconButton("xmark", help: "Close") { model.isShowingHelp = false }
            }
            .padding(.horizontal, Space.l)
            .padding(.top, Space.m)
            TextField("Search help", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, Space.l)
                .padding(.vertical, Space.s)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    if query.isEmpty { mailboxes }
                    let shown = topics.filter(matches)
                    if !shown.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            heading("How to")
                            ForEach(shown) { topic in card(topic) }
                        }
                    }
                    let keys = keyCommands.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
                    if !keys.isEmpty { keysSection(keys) }
                    if !query.isEmpty && shown.isEmpty && keys.isEmpty {
                        Text("Nothing in Help about that. Tell us what you were looking for:")
                            .font(TypeScale.caption).foregroundStyle(Ink.tertiary)
                    }
                    feedback
                }
                .padding(Space.l)
            }
        }
    }

    // MARK: Mailboxes

    /// Each mailbox: fine, offline, or needing a sign-in, with what fixes it.
    private var mailboxes: some View {
        VStack(alignment: .leading, spacing: 6) {
            heading("Your mailboxes")
            ForEach(model.accounts) { account in
                HStack(spacing: Space.s) {
                    AccountAvatar(account: account, size: 18, showsProvider: false)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: account.label).font(TypeScale.row).foregroundStyle(Ink.primary).lineLimit(1)
                        Text(status(of: account)).font(TypeScale.caption)
                            .foregroundStyle(model.loadErrors[account.id] == nil || model.isUnreachable(account.id) ? Ink.tertiary : Status.danger)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    if model.needsSignIn(account.id), model.canSignInAgain(account) {
                        Button("Sign In") { model.signingInAgain = account }.buttonStyle(.borderless).font(TypeScale.label)
                    }
                }
            }
            if model.accounts.isEmpty {
                Button("Add a mailbox") { model.isAddingAccount = true }.buttonStyle(.borderless)
            }
            HStack {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(model.lastUpdated.map { String(localized: "Checked \($0.formatted(.relative(presentation: .named)))") } ?? String(localized: "Not checked yet"))
                        .font(TypeScale.caption).foregroundStyle(Ink.tertiary)
                }
                Spacer()
                Button("Check Now") { Task { await model.reload() } }
                    .buttonStyle(.borderless).font(TypeScale.label)
                    .disabled(model.isLoading)
            }
        }
        .padding(Space.m)
        .background(Fill.one, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func status(of account: MailAccount) -> String {
        if model.needsSignIn(account.id) { return String(localized: "Signed out. Sign in again to get new mail.") }
        if model.isUnreachable(account.id) { return String(localized: "Offline. Showing saved mail; it keeps trying.") }
        if let error = model.loadErrors[account.id] { return error }
        return String(localized: "Up to date")
    }

    // MARK: How-tos

    private var topics: [Topic] {
        var list = [
            Topic(id: "home", symbol: "house", title: String(localized: "Home and what needs you"),
                  lines: [String(localized: "Home shows what needs you today: replies you owe, meetings, bills to open and sign-in codes, each with a short note beside it."),
                          String(localized: "The rest is sorted into groups like Bills to Pay and Travel. Right-click a conversation to move it to another group.")],
                  action: (String(localized: "Open Home"), { model.go(to: .home(group: nil)) })),
            Topic(id: "search", symbol: "magnifyingglass", title: String(localized: "Searching"),
                  lines: [String(localized: "Type words, or narrow it with from:, to:, subject:, is:unread, is:starred, has:attachment or in:people."),
                          String(localized: "Search looks through mail saved on this device first, then asks your mail servers.")],
                  action: (String(localized: "Search"), { model.searchRequest += 1 })),
            Topic(id: "rules", symbol: "line.3.horizontal.decrease.circle", title: String(localized: "Rules for new mail"),
                  lines: [String(localized: "Right-click a conversation and choose Create Rule… to start from its sender, their domain or its subject."),
                          String(localized: "A rule can move, label, star, forward or answer new mail, or keep it quiet. When one moves mail, Undo brings it back.")],
                  action: (String(localized: "Open Rules"), { settings("rules") })),
            Topic(id: "later", symbol: "clock", title: String(localized: "Snooze, Send later and Undo"),
                  lines: [String(localized: "Press H to snooze a conversation; it comes back to the inbox at the time you pick."),
                          String(localized: "Send later is in the menu next to Send. Undo Send gives you a few seconds after Send; set how long in Settings → Writing."),
                          String(localized: "Z undoes your last change, like archiving or moving mail.")],
                  action: nil),
            Topic(id: "ai", symbol: "point.3.connected.trianglepath.dotted", title: String(localized: "AI apps"),
                  lines: [String(localized: "AI apps on your Mac can search your mail, sort it, save drafts and make rules through Margin once you turn it on."),
                          String(localized: "You choose what they may change or send, and which mailboxes they see.")],
                  action: (String(localized: "Open Connections"), { settings("connections") })),
            Topic(id: "backup", symbol: "externaldrive", title: String(localized: "Backups and other devices"),
                  lines: [String(localized: "Back up your settings, mailboxes and signatures on a schedule, locked with a password."),
                          String(localized: "Link Device copies everything to your iPhone or iPad.")],
                  action: (String(localized: "Open Backups"), { settings("backup") })),
        ]
        if model.isAssistantOn {
            list.insert(Topic(id: "ask", symbol: "text.bubble", title: String(localized: "Ask about your mail"),
                              lines: [String(localized: "Ask answers from your mail on this device: what needs a reply, what's on this week, which bills are open."),
                                      String(localized: "Type / in Ask for commands like /catchup and /replies.")],
                              action: (String(localized: "Ask"), { model.isShowingHelp = false; model.isAsking = true })), at: 2)
        }
        return list
    }

    private func matches(_ topic: Topic) -> Bool {
        let typed = query.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return true }
        return ([topic.title] + topic.lines).contains { $0.localizedCaseInsensitiveContains(typed) }
    }

    private func card(_ topic: Topic) -> some View {
        let isOpen = open.contains(topic.id) || !query.isEmpty
        return VStack(alignment: .leading, spacing: Space.s) {
            Button {
                withAnimation(Motion.quick) {
                    if open.contains(topic.id) { open.remove(topic.id) } else { open.insert(topic.id) }
                }
            } label: {
                HStack(spacing: Space.s) {
                    Image(systemName: topic.symbol).font(.system(size: Look.size(12))).foregroundStyle(Ink.secondary).frame(width: 18)
                    Text(verbatim: topic.title).font(TypeScale.rowStrong).foregroundStyle(Ink.primary)
                    Spacer(minLength: 0)
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: Look.size(9), weight: .semibold)).foregroundStyle(Ink.quaternary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                ForEach(topic.lines, id: \.self) { line in
                    Text(verbatim: line).font(TypeScale.caption).foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let action = topic.action {
                    Button(action.title, action: action.run).buttonStyle(.borderless).font(TypeScale.label)
                }
            }
        }
        .padding(Space.m)
        .background(Fill.one, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Keys

    private var keyCommands: [MailCommand] {
        let wanted = ["compose", "reply", "done", "star", "read", "snooze", "undo", "search", "next", "previous"]
        let all = MailCommand.all(for: model)
        return wanted.compactMap { id in all.first { $0.id == id } }
    }

    private func keysSection(_ commands: [MailCommand]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            heading("Keys")
            ForEach(commands) { command in
                HStack {
                    Text(verbatim: command.title).font(TypeScale.row).foregroundStyle(Ink.secondary)
                    Spacer()
                    KeyCap(keys: command.keys)
                }
            }
            Button("All Keyboard Shortcuts") { model.isShowingHelp = false; model.isShowingShortcuts = true }
                .buttonStyle(.borderless).font(TypeScale.label)
        }
    }

    // MARK: Feedback

    private var feedback: some View {
        VStack(alignment: .leading, spacing: 6) {
            heading("Tell us")
            HStack(spacing: Space.s) {
                Button("Send Feedback…") { model.startFeedback() }
                Button("Report a Problem…") { model.startFeedback(problem: true) }
            }
            .font(TypeScale.label)
            Text("Or write to \(MailModel.feedbackAddress).")
                .font(TypeScale.caption).foregroundStyle(Ink.tertiary)
                .textSelection(.enabled)
        }
    }

    private func heading(_ text: LocalizedStringKey) -> some View {
        Text(text).font(TypeScale.label.weight(.semibold)).foregroundStyle(Ink.tertiary)
    }

    private func settings(_ page: String) {
        #if os(macOS)
        model.settingsPageRequest = page
        openSettings()
        #endif
    }
}
