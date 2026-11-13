import MailCore
import SwiftUI

/// Settings on the Mac, laid out like System Settings: a search field and grouped pages on the
/// left, the chosen page as a grouped form on the right.
public struct MailSettingsView: View {
    @Bindable var model: MailModel
    @State private var page: SettingsPage = .mailboxes
    /// The sidebar's selection. Kept apart from `page` so the list can clear it (it does while
    /// searching) without leaving the window without a page.
    @State private var selection: SettingsPage? = .mailboxes
    @State private var search = ""
    @State private var editingAccount: UUID?
    /// Pages visited, for Back and Forward in the toolbar, as in a browser.
    @State private var history = SettingsHistory()

    public init(model: MailModel) { self.model = model }

    /// Opens on one page, by its name ("notifications"); for screenshots.
    public init(model: MailModel, startingAt page: String) {
        self.model = model
        let start = SettingsPage(rawValue: page) ?? .mailboxes
        _page = State(initialValue: start)
        _selection = State(initialValue: start)
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(Array(SettingsPage.sections(matching: search).enumerated()), id: \.offset) { _, pages in
                    Section {
                        ForEach(pages) { item in
                            Label { Text(verbatim: item.title) } icon: { SettingsIcon(page: item, size: 20) }
                                .tag(item)
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: Text("Search settings"))
            .onChange(of: search) { _, query in
                // The first match opens as you type.
                if !page.matches(query), let first = SettingsPage.sections(matching: query).first?.first { selection = first }
            }
            .onChange(of: selection) { _, new in if let new { page = new } }
            .onChange(of: page) { old, new in history.visited(from: old, to: new) }
            // Another part of Margin asked for a page (the Help panel).
            .onChange(of: model.settingsPageRequest) { _, request in
                guard let request, let wanted = SettingsPage(rawValue: request) else { return }
                model.settingsPageRequest = nil
                search = ""
                selection = wanted
            }
            .onAppear {
                if let request = model.settingsPageRequest, let wanted = SettingsPage(rawValue: request) {
                    model.settingsPageRequest = nil
                    page = wanted
                    selection = wanted
                }
            }
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(215)
        } detail: {
            detail
                .environment(\.settingsTint, page.tint)
                .navigationTitle(Text(verbatim: page.title))
                // The page says its own name; no second one in the window's title bar.
                #if os(macOS)
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                #endif
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        Button { go(history.back(from: page)) } label: { Image(systemName: "chevron.backward") }
                            .disabled(!history.canGoBack)
                            .keyboardShortcut("[", modifiers: .command)
                            .help(Text("Back"))
                        Button { go(history.forward(from: page)) } label: { Image(systemName: "chevron.forward") }
                            .disabled(!history.canGoForward)
                            .keyboardShortcut("]", modifiers: .command)
                            .help(Text("Forward"))
                    }
                }
        }
        .frame(width: 780, height: 580)
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
        page = target
        selection = target
    }

    @ViewBuilder
    private var detail: some View {
        switch page {
        case .mailboxes: MailboxesSettings(model: model, editing: $editingAccount)
        case .contacts: ContactsSettings(model: model)
        case .workspaces: WorkspacesSettings(model: model)
        case .notifications: NotificationSettings(model: model)
        case .reading: ReadingSettings(model: model)
        case .writing: WritingSettings(model: model)
        case .signatures: SignaturesSettings(model: model)
        case .appearance: AppearanceSettings(model: model)
        case .sorting: SortingSettings(model: model)
        case .templates: TemplateSettings(model: model)
        case .shortcuts: ShortcutSettings(model: model)
        case .assistant: AssistantSettingsView(model: model)
        case .rules: RulesSettings(model: model)
        case .connections: ConnectionsSettingsView(model: model)
        case .backup: BackupSettings(model: model)
        case .experimental: ExperimentalSettings(model: model)
        case .about: AboutSettings(model: model)
        }
    }
}

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
