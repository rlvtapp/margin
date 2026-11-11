import MailCore
import SwiftUI

/// Under a conversation from a person: three short replies in the person's own style.
/// Tapping one opens the reply and drafts it in full.
struct ReplySuggestionsRow: View {
    @Bindable var model: MailModel
    let thread: MailThread

    var body: some View {
        let suggestions = model.replySuggestions[thread.id] ?? []
        // A view that's always there, so the task runs even before there's anything to show.
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 0)
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    GlassChipRow {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button { model.reply(with: suggestion) } label: {
                                GlassChip(Text(verbatim: suggestion), symbol: "arrowshape.turn.up.left", color: Ink.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
                        .transition(.opacity)
            }
        }
        .animation(Motion.quick, value: suggestions)
        .task(id: thread.latest.id) { await model.suggestReplies(for: thread) }
    }
}
