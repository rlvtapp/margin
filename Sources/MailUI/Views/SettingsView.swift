import MailCore
import SwiftUI

/// Settings on the Mac: a search field and the pages in named groups on the left, the chosen
/// page on the right under its own icon, name and one line about it.
public struct MailSettingsView: View {
    @Bindable var model: MailModel
    @State private var page: SettingsPage = .general
    @State private var search = ""
    @State private var editingAccount: UUID?
    /// The mailbox picked under Mailboxes in the sidebar; its own settings fill the page.
    @State private var mailbox: UUID?
    /// Pages visited, for Back and Forward in the toolbar, as in a browser.
    @State private var history = SettingsHistory()

    public init(model: MailModel) { self.model = model }

    /// Opens on one page, by its name ("notifications"); for screenshots.
    public init(model: MailModel, startingAt page: String) {
        self.model = model
        _page = State(initialValue: SettingsPage(named: page) ?? .general)
    }

    /// Opens on the first mailbox's own settings, as picked in the sidebar; for screenshots.
    public init(firstMailboxOf model: MailModel) {
        self.model = model
        _page = State(initialValue: .mailboxes)
        _mailbox = State(initialValue: model.accounts.first?.id)
    }

    /// Opens with words in the search field; for screenshots.
    public init(model: MailModel, searching words: String) {
        self.model = model
        _search = State(initialValue: words)
        _page = State(initialValue: SettingsPage.groups(matching: words).first?.pages.first ?? .general)
    }

    public var body: some View {
        NavigationSplitView {
            SettingsSidebar(model: model, page: $page, mailbox: $mailbox, search: $search,
                            canGoBack: history.canGoBack, canGoForward: history.canGoForward,
                            back: { go(history.back(from: page)) }, forward: { go(history.forward(from: page)) })
            .onChange(of: search) { _, query in
                // The first match opens as you type.
                if !page.matches(query), let first = SettingsPage.groups(matching: query).first?.pages.first { page = first }
            }
            .onChange(of: page) { old, new in history.visited(from: old, to: new) }
            // Another part of Margin, or a row on another page, asked for a page.
            .onChange(of: model.settingsPageRequest) { _, request in
                guard let request else { return }
                model.settingsPageRequest = nil
                guard let wanted = SettingsPage(named: request), SettingsPage.available.contains(wanted) else { return }
                search = ""
                mailbox = nil
                page = wanted
            }
            .onAppear {
                if let request = model.settingsPageRequest {
                    model.settingsPageRequest = nil
                    if let wanted = SettingsPage(named: request), SettingsPage.available.contains(wanted) { page = wanted }
                }
            }
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(Look.pick(230, roomy: 264))
        } detail: {
            detail
                .id(mailbox?.uuidString ?? page.rawValue)
                #if os(macOS)
                // Up under the bar that only holds Back and Forward, so no room is lost above the page.
                .ignoresSafeArea(.container, edges: .top)
                #endif
                .scrollContentBackground(.hidden)
                .background(Paper.ground)
                // Bigger rows and controls than a system form's, so Settings reads like the rest of Margin.
                .controlSize(.large)
                #if os(macOS)
                .background(SettingsWindowLook())
                #endif
                .environment(\.settingsTint, page.tint)
                .navigationTitle(Text(verbatim: page.title))
                // The page says its own name; no second one in the window's title bar.
                #if os(macOS)
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                #endif
        }
        .frame(width: Look.pick(900, roomy: 980), height: Look.pick(700, roomy: 780))
        .sheet(isPresented: $model.isAddingAccount) { AccountSetupView(model: model) }
        .sheet(item: Binding(get: { editingAccount.map(IdentifiedID.init) }, set: { editingAccount = $0?.id })) { item in
            SignatureEditor(model: model, accountID: item.id)
        }
    }

    /// Goes to a page from history without recording the move as a new visit.
    private func go(_ target: SettingsPage?) {
        guard let target else { return }
        history.isMoving = true
        search = ""
        mailbox = nil
        page = target
    }

    @ViewBuilder
    private var detail: some View {
        if let mailbox, model.account(mailbox) != nil {
            SignatureEditor(model: model, accountID: mailbox, isEmbedded: true)
        } else {
            SettingsDetail(model: model, page: page, editingAccount: $editingAccount)
        }
    }
}

/// The page itself, the same on the Mac and on iPhone and iPad.
struct SettingsDetail: View {
    let model: MailModel
    let page: SettingsPage
    @Binding var editingAccount: UUID?

    var body: some View {
        switch page {
        case .general: GeneralSettings(model: model)
        case .mailboxes: MailboxesSettings(model: model, editing: $editingAccount)
        case .contacts: ContactsSettings(model: model)
        case .workspaces: WorkspacesSettings(model: model)
        case .notifications: NotificationSettings(model: model)
        case .reading: ReadingSettings(model: model)
        case .writing: WritingSettings(model: model)
        case .signatures: SignaturesSettings(model: model)
        case .appearance: AppearanceSettings(model: model)
        case .layout: LayoutSettings(model: model)
        case .sorting: SortingSettings(model: model)
        case .templates: TemplateSettings(model: model)
        case .shortcuts: ShortcutSettings(model: model)
        case .assistant: AssistantSettingsView(model: model)
        case .writingStyle: WritingStyleSettings(model: model)
        case .rules: RulesSettings(model: model)
        case .connections: ConnectionsSettingsView(model: model)
        case .backup: BackupSettings(model: model, part: .devices)
        case .backupFiles: BackupSettings(model: model, part: .backups)
        case .restore: BackupSettings(model: model, part: .restore)
        case .ask: AskSettingsPage(model: model)
        case .permissions: PermissionSettingsPage(model: model)
        case .signInCodes: SignInCodeSettings(model: model)
        case .vips: VIPSettings(model: model)
        case .experimental: ExperimentalSettings(model: model)
        case .about: AboutSettings(model: model)
        }
    }
}

/// The sidebar: the pages under their groups' names, each with its small coloured icon. While
/// searching, only the pages that match, each with the settings on it that the words found.
struct SettingsSidebar: View {
    let model: MailModel
    @Binding var page: SettingsPage
    @Binding var mailbox: UUID?
    @Binding var search: String
    var canGoBack = false
    var canGoForward = false
    var back: () -> Void = {}
    var forward: () -> Void = {}
    @FocusState private var isFocused: Bool
    /// The rows whose pages are unfolded, by name; remembered. Mailboxes to start with, so
    /// the list opens short; picking a row unfolds it.
    @AppStorage("settingsOpenRows") private var opened = "mailboxes"

    private func isOpen(_ row: SettingsPage) -> Bool { opened.split(separator: ",").contains(Substring(row.rawValue)) }

    private func fold(_ row: SettingsPage) -> Binding<Bool> {
        Binding(get: { isOpen(row) }, set: { open in
            var rows = opened.split(separator: ",").map(String.init).filter { $0 != row.rawValue }
            if open { rows.append(row.rawValue) }
            opened = rows.joined(separator: ",")
            // Folding rows away while one of them is open goes back to the row itself.
            if !open, page.parent == row || (row == .mailboxes && mailbox != nil) {
                mailbox = nil
                page = row
            }
        })
    }

    var body: some View {
        let groups = SettingsPage.groups(matching: search)
        GeometryReader { geometry in
        VStack(spacing: 0) {
        // Back and Forward in the window's own top row, at the sidebar's right edge, level
        // with the close, minimize and zoom buttons.
        HStack(spacing: 2) {
            Spacer()
            SettingsStepButton(symbol: "chevron.backward", help: "Back", isEnabled: canGoBack, action: back)
                .keyboardShortcut("[", modifiers: .command)
            SettingsStepButton(symbol: "chevron.forward", help: "Forward", isEnabled: canGoForward, action: forward)
                .keyboardShortcut("]", modifiers: .command)
        }
        .padding(.trailing, Space.s)
        // Centred on the same line the window buttons are moved to (`SettingsBar.center`).
        .frame(height: SettingsBar.center * 2)
        .frame(height: max(geometry.safeAreaInsets.top, SettingsBar.center * 2), alignment: .top)
        // Over the list, not in it, so rows never show behind the field.
        SettingsSearchField(text: $search)
            .padding(.horizontal, Space.m)
            .padding(.top, Space.s)
            .padding(.bottom, Space.m)
        ScrollViewReader { reader in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if groups.isEmpty {
                    Text("No settings match “\(search)”.")
                        .font(TypeScale.label)
                        .foregroundStyle(Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Space.s)
                        .padding(.top, Space.m)
                }
                ForEach(groups) { group in
                    if let title = group.title {
                        Text(verbatim: title)
                            .font(TypeScale.key)
                            .foregroundStyle(Ink.tertiary)
                            .padding(.horizontal, Space.s)
                            .padding(.top, Space.l)
                            .padding(.bottom, Space.xs)
                            .accessibilityAddTraits(.isHeader)
                    }
                    ForEach(group.pages) { item in
                        // Under its row when the row is there too; on its own when a search left only it.
                        let under = item.parent.map { group.pages.contains($0) } ?? false
                        let hasRows = !item.children.isEmpty || (item == .mailboxes && !model.accounts.isEmpty)
                        if !under || search.isEmpty == false || item.parent.map(isOpen) ?? true {
                            SettingsSidebarRow(page: item, isSelected: item == page && mailbox == nil, hits: item.hits(for: search),
                                               isUnder: under, isOpen: hasRows && search.isEmpty ? fold(item) : nil) {
                                mailbox = nil
                                page = item
                                // Picking a row shows what's under it.
                                if hasRows, !isOpen(item) { withAnimation(Motion.quick) { fold(item).wrappedValue = true } }
                            }
                            .id(item)
                        }
                        // Each mailbox under Mailboxes, to go straight to its own settings.
                        if item == .mailboxes, isOpen(.mailboxes), search.isEmpty {
                            ForEach(model.accounts) { account in
                                SettingsMailboxRow(model: model, account: account, isSelected: mailbox == account.id) {
                                    page = .mailboxes
                                    mailbox = account.id
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Space.m)
            .padding(.bottom, Space.l)
        }
        // A page opened from elsewhere is unfolded and brought into view.
        .onChange(of: page) { _, new in
            if let row = new.parent, !isOpen(row) { fold(row).wrappedValue = true }
            reader.scrollTo(new)
        }
        .onAppear {
            // Opened straight onto a page under a folded row: the row unfolds.
            if let row = page.parent, !isOpen(row) { fold(row).wrappedValue = true }
            reader.scrollTo(page)
        }
        }
        }
        .ignoresSafeArea(.container, edges: .top)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.downArrow) { step(1); return .handled }
        .onKeyPress(.upArrow) { step(-1); return .handled }
    }

    /// The arrow keys move through the pages in view.
    private func step(_ offset: Int) {
        let pages = SettingsPage.groups(matching: search).flatMap(\.pages)
        guard let index = pages.firstIndex(of: page), pages.indices.contains(index + offset) else { return }
        mailbox = nil
        page = pages[index + offset]
    }
}

private struct SettingsSidebarRow: View {
    let page: SettingsPage
    let isSelected: Bool
    let hits: [String]
    /// Under another row: set in, with a smaller icon.
    var isUnder = false
    /// Set on a row with rows of its own under it: whether they show.
    var isOpen: Binding<Bool>?
    let open: () -> Void
    @State private var isHovered = false

    var body: some View {
        row.overlay(alignment: .trailing) {
            if let isOpen {
                Button { withAnimation(Motion.quick) { isOpen.wrappedValue.toggle() } } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: Look.size(10), weight: .semibold))
                        .foregroundStyle(Ink.tertiary)
                        .rotationEffect(.degrees(isOpen.wrappedValue ? 90 : 0))
                        .frame(width: Look.gap(24), height: Look.gap(24))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, Space.xs)
                .accessibilityLabel(isOpen.wrappedValue ? Text("Hide") : Text("Show"))
            }
        }
    }

    private var row: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: Space.s) {
                SettingsIcon(page: page, size: isUnder ? Look.pick(20, roomy: 22) : Look.pick(22, roomy: 24))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: page.title)
                        .font(.system(size: Look.size(isUnder ? 13 : 14), weight: isSelected ? .medium : .regular))
                        .foregroundStyle(Ink.primary)
                        .frame(minHeight: isUnder ? Look.pick(20, roomy: 22) : Look.pick(22, roomy: 24))
                    ForEach(hits.prefix(4), id: \.self) { hit in
                        Text(verbatim: hit)
                            .font(TypeScale.caption)
                            .foregroundStyle(Ink.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, isUnder ? Space.s + Look.pick(22, roomy: 24) : Space.s)
            .padding(.trailing, Space.s)
            .padding(.vertical, Look.pick(5, roomy: 6))
            .background(isSelected ? Fill.three : isHovered ? Fill.one : Color.clear,
                        in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The top row of the Settings window: how far down its middle is, for the window buttons on
/// the left and Back and Forward on the right, so the two sit on one line.
enum SettingsBar {
    static let center: CGFloat = 22
}

/// Back or Forward: a quiet chevron on the page.
private struct SettingsStepButton: View {
    let symbol: String
    let help: LocalizedStringKey
    let isEnabled: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Look.size(12), weight: .semibold))
                .foregroundStyle(isEnabled ? Ink.secondary : Ink.quaternary)
                .frame(width: Look.gap(26), height: Look.gap(26))
                .background(isHovered && isEnabled ? Fill.two : Color.clear, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
        .help(Text(help))
        .accessibilityLabel(Text(help))
    }
}

/// The search field over the sidebar's pages.
private struct SettingsSearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Look.size(12), weight: .medium))
                .foregroundStyle(Ink.tertiary)
            TextField("Search settings", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: Look.size(13)))
                .focused($isFocused)
            Button { text = "" } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Ink.tertiary)
            }
            .buttonStyle(.plain)
            .opacity(text.isEmpty ? 0 : 1)
            .disabled(text.isEmpty)
            .accessibilityLabel(Text("Clear"))
        }
        .padding(.horizontal, Space.s)
        .frame(height: Look.gap(30))
        .background(Fill.two, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        // ⌘F goes to the field.
        .background {
            Button("") { isFocused = true }.keyboardShortcut("f", modifiers: .command).opacity(0).accessibilityHidden(true)
        }
    }
}

/// A mailbox's picture in Settings: the one chosen for the mailbox, else your own photo from
/// your address book when there is one, else its letter. Always the same size, so a photo
/// arriving moves nothing.
struct MailboxPhoto: View {
    let model: MailModel
    let account: MailAccount
    var size: CGFloat = 20
    @State private var photo: Image?

    var body: some View {
        ZStack {
            AccountMark(account, size: size)
            if account.picture == nil, let photo {
                photo.resizable().scaledToFill().frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            }
        }
        .frame(width: size, height: size)
        .task(id: account.address.address) {
            guard account.picture == nil else { return }
            photo = await model.pictureData(for: account.address.address).flatMap(AccountMark.image)
        }
    }
}

/// A mailbox under Mailboxes in the sidebar: its mark and its name, set in from the pages.
private struct SettingsMailboxRow: View {
    let model: MailModel
    let account: MailAccount
    let isSelected: Bool
    let open: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: Space.s) {
                MailboxPhoto(model: model, account: account, size: Look.pick(20, roomy: 22))
                Text(verbatim: account.label)
                    .font(.system(size: Look.size(13), weight: isSelected ? .medium : .regular))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, Space.s + Look.pick(22, roomy: 24))
            .padding(.trailing, Space.s)
            .padding(.vertical, Look.pick(5, roomy: 6))
            .background(isSelected ? Fill.three : isHovered ? Fill.one : Color.clear,
                        in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#if os(macOS)
/// The Settings window has no bar or line of its own over the page: the page runs to the top,
/// with its header beside Back and Forward.
private struct SettingsWindowLook: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }

    func updateNSView(_ view: NSView, context: Context) { (view as? Probe)?.applySoon() }

    private final class Probe: NSView {
        private var watching: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            watching.forEach(NotificationCenter.default.removeObserver)
            watching = []
            guard let window else { return }
            apply()
            applySoon()
            // The system puts the buttons back where it likes on these; they're moved again.
            for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.didExitFullScreenNotification] {
                watching.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.applySoon() }
                })
            }
        }

        /// Again once SwiftUI has set the window up, which puts some of this back.
        func applySoon() {
            for delay in [0.0, 0.3, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.apply() }
            }
        }

        private func apply() {
            guard let window else { return }
            window.titlebarSeparatorStyle = .none
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            // Close, minimize and zoom stay, a little lower: on one line with Back and Forward.
            // Only down: left to right they stay where the system puts them.
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(kind), let bar = button.superview else { continue }
                button.isHidden = false
                let top = bar.convert(NSPoint(x: 0, y: window.frame.height), from: nil).y
                let middle = bar.isFlipped ? top + SettingsBar.center : top - SettingsBar.center
                let y = (middle - button.frame.height / 2).rounded()
                if abs(button.frame.origin.y - y) > 0.5 { button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: y)) }
            }
            // The split view's panes each bring their own line; they go too.
            func clear(_ view: NSView?) {
                guard let view else { return }
                ((view as? NSSplitView)?.delegate as? NSSplitViewController)?.splitViewItems.forEach { $0.titlebarSeparatorStyle = .none }
                view.subviews.forEach(clear)
            }
            clear(window.contentView)
        }
    }
}
#endif

private struct IdentifiedID: Identifiable { let id: UUID }

/// Settings pages visited, so Back and Forward work as in a browser.
struct SettingsHistory: Equatable {
    var backStack: [SettingsPage] = []
    var forwardStack: [SettingsPage] = []
    /// Set while Back or Forward moves, so that move isn't a new visit.
    var isMoving = false

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    mutating func visited(from old: SettingsPage, to new: SettingsPage) {
        if isMoving { isMoving = false; return }
        guard old != new else { return }
        backStack.append(old)
        if backStack.count > 50 { backStack.removeFirst() }
        forwardStack = []
    }

    mutating func back(from current: SettingsPage) -> SettingsPage? {
        guard let target = backStack.popLast() else { return nil }
        forwardStack.append(current)
        return target
    }

    mutating func forward(from current: SettingsPage) -> SettingsPage? {
        guard let target = forwardStack.popLast() else { return nil }
        backStack.append(current)
        return target
    }
}
