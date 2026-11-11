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
        }
        .frame(width: 780, height: 580)
        .sheet(isPresented: $model.isAddingAccount) { AccountSetupView(model: model) }
        .sheet(item: Binding(get: { editingAccount.map(IdentifiedID.init) }, set: { editingAccount = $0?.id })) { item in
            SignatureEditor(model: model, accountID: item.id)
        }
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
