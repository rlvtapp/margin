import MailCore
import SwiftUI

/// Under a To or Cc field: people matching what's being typed. Clicking one fills it in.
struct RecipientSuggestions: View {
    let model: MailModel
    @Binding var field: String
    /// Colleagues found in the work directory for what's typed, after a short pause.
    @State private var directory: [EmailAddress] = []

    var body: some View {
        let typed = AddressBook.lastToken(of: field)
        let already = Set((EmailAddress.parseList(field) ?? []).map { $0.address.lowercased() })
        let known = typed.count >= 1 ? model.addressBook.suggestions(for: typed, excluding: already) : []
        let knownAddresses = Set(known.map { $0.address.lowercased() })
        let fromDirectory = typed.count >= 2
            ? directory.filter { !already.contains($0.address.lowercased()) && !knownAddresses.contains($0.address.lowercased()) }
            : []
        let matches = Array((known + fromDirectory).prefix(8))
        // A stack that's always there, so the directory search runs even while nothing shows.
        VStack(spacing: 0) {
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(matches, id: \.address) { person in
                    Button { field = AddressBook.completing(field, with: person) } label: {
                        HStack(spacing: Space.s) {
                            Avatar(person, size: 22)
                            Text(verbatim: person.displayName).font(TypeScale.rowStrong).foregroundStyle(Ink.primary)
                            Text(verbatim: person.address).font(TypeScale.label).foregroundStyle(Ink.tertiary)
                            Spacer(minLength: 0)
                        }
                        .lineLimit(1)
                        .padding(.horizontal, Space.s)
                        .frame(height: Look.gap(34))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(Paper.popover, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Line.edge))
            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        }
        }
        .task(id: typed) {
            guard typed.count >= 2 else { directory = []; return }
            // Wait for a pause in typing before asking the directory.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = await model.searchDirectories(typed)
            if !Task.isCancelled { directory = found }
        }
    }
}
