#if os(iOS)
import MailCore
import SwiftUI

/// Settings on iPhone and iPad, as a standard form. The same options as on the Mac, except
/// Connections (the MCP server for AI apps runs on the Mac) and Shortcuts (single-key
/// shortcuts belong to the Mac's keyboard-first list).
struct TouchSettingsView: View {
    @Bindable var model: MailModel
    @Environment(\.dismiss) private var dismiss
    @State private var editingSignature: UUID?

    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(SettingsPage.sections(matching: search).enumerated()), id: \.offset) { _, pages in
                    Section {
                        ForEach(pages) { item in
                            NavigationLink(value: item) {
                                Label { Text(verbatim: item.title) } icon: { SettingsIcon(page: item, size: 28) }
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: Text("Search settings"))
            .navigationDestination(for: SettingsPage.self) { item in
                detail(item)
                    .environment(\.settingsTint, item.tint)
                    .navigationTitle(Text(verbatim: item.title))
                    .navigationBarTitleDisplayMode(.inline)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .tint(Ink.primary)
        .sheet(isPresented: $model.isAddingAccount) { AccountSetupView(model: model) }
        .sheet(item: Binding(get: { editingSignature.map(SignatureTarget.init) }, set: { editingSignature = $0?.id })) { item in
            SignatureEditor(model: model, accountID: item.id)
        }
    }

    @ViewBuilder
    private func detail(_ page: SettingsPage) -> some View {
        switch page {
        case .mailboxes: MailboxesSettings(model: model, editing: $editingSignature)
        case .contacts: ContactsSettings(model: model)
        case .workspaces: WorkspacesSettings(model: model)
        case .notifications: NotificationSettings(model: model)
        case .reading: ReadingSettings(model: model)
        case .writing: WritingSettings(model: model)
        case .signatures: SignaturesSettings(model: model)
        case .appearance: AppearanceSettings(model: model)
        case .sorting: SortingSettings(model: model)
        case .templates: TemplateSettings(model: model)
        case .assistant: AssistantSettingsView(model: model)
        case .rules: RulesSettings(model: model)
        case .backup: BackupSettings(model: model)
        case .experimental: ExperimentalSettings(model: model)
        case .about: AboutSettings(model: model)
        case .shortcuts, .connections: EmptyView()
        }
    }
}

private struct SignatureTarget: Identifiable { let id: UUID }
#endif
