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

    /// The pages opened, so a row on one page can open another.
    @State private var path: [SettingsPage] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(SettingsPage.groups(matching: search)) { group in
                    Section {
                        ForEach(group.pages) { item in
                            NavigationLink(value: item) {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(verbatim: item.title)
                                        ForEach(item.hits(for: search).prefix(4), id: \.self) { hit in
                                            Text(verbatim: hit).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                } icon: { SettingsIcon(page: item, size: 28) }
                            }
                        }
                    } header: {
                        if let title = group.title { Text(verbatim: title) }
                    }
                }
            }
            .searchable(text: $search, prompt: Text("Search settings"))
            .navigationDestination(for: SettingsPage.self) { item in
                SettingsDetail(model: model, page: item, editingAccount: $editingSignature)
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
        // A row on one page asked for another.
        .onChange(of: model.settingsPageRequest) { _, request in
            guard let request else { return }
            model.settingsPageRequest = nil
            if let wanted = SettingsPage(named: request), SettingsPage.available.contains(wanted) { path.append(wanted) }
        }
        .sheet(isPresented: $model.isAddingAccount) { AccountSetupView(model: model) }
        .sheet(item: Binding(get: { editingSignature.map(SignatureTarget.init) }, set: { editingSignature = $0?.id })) { item in
            SignatureEditor(model: model, accountID: item.id)
        }
    }
}

private struct SignatureTarget: Identifiable { let id: UUID }
#endif
