import MailCore
import SwiftUI

/// Saved searches in the sidebar: a click runs one again; rename or delete from its menu.
struct SavedSearchesSection: View {
    @Bindable var model: MailModel
    @State private var renaming: SavedSearch?
    @State private var name = ""
    @AppStorage("sidebarSearchesFolded") private var isFolded = false

    var body: some View {
        let searches = model.savedSearches
        // One stack, so the rename alert is attached once (on a Group it would go on every row).
        VStack(alignment: .leading, spacing: 1) {
            if !searches.isEmpty {
                Button { withAnimation(Motion.quick) { isFolded.toggle() } } label: {
                    HStack(spacing: 4) {
                        Text("Searches")
                        Image(systemName: isFolded ? "chevron.right" : "chevron.down").font(.system(size: Look.size(8), weight: .bold))
                    }
                    .font(TypeScale.label.weight(.medium))
                    .foregroundStyle(Ink.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.top, Space.l)
                    .padding(.bottom, Space.xs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if !isFolded {
                    ForEach(searches) { search in
                        SidebarRow(title: search.name, symbol: "magnifyingglass", count: nil,
                                   isSelected: model.place == .search(search.text)) {
                            model.openSavedSearch(search)
                        }
                        .tip(Text(verbatim: search.text))
                        .contextMenu {
                            Button("Rename…") { name = search.name; renaming = search }
                            Divider()
                            Button("Delete", role: .destructive) { model.deleteSavedSearch(search.id) }
                        }
                    }
                }
            }
        }
        .alert("Rename search", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let renaming { model.renameSavedSearch(renaming.id, to: name) }
                renaming = nil
            }
        }
    }
}
