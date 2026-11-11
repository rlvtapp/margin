#if os(iOS)
import MailCore
import SwiftUI

extension ReaderView {
    /// On iPhone and iPad the reader's actions sit in the navigation bar and the bottom bar,
    /// where a thumb reaches them.
    @ToolbarContentBuilder
    func touchToolbar(_ thread: MailThread) -> some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { model.toggleStar() } label: {
                Label(thread.isStarred ? "Remove star" : "Star", systemImage: thread.isStarred ? "star.fill" : "star")
                    .symbolEffect(.bounce, value: thread.isStarred)
            }
            .tint(thread.isStarred ? Status.star : Ink.primary)
            .sensoryFeedback(.impact(weight: .light), trigger: thread.isStarred)
            ReaderMoreMenu(model: model, thread: thread, addsLabel: $addsLabel)
        }
        ToolbarItemGroup(placement: .bottomBar) {
            Button { model.perform(.done) } label: { Label("Done", systemImage: "checkmark.circle") }
            Menu {
                ForEach(SnoozePreset.allCases, id: \.self) { preset in
                    let date = preset.date()
                    Button {
                        model.snooze(until: date)
                    } label: {
                        Text(verbatim: "\(preset.title) · \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                    }
                }
            } label: { Label("Snooze", systemImage: "clock") }
            Button { model.perform(.trash) } label: { Label("Trash", systemImage: "trash") }
            Spacer()
            if model.isAssistantOn {
                Button { model.summarizeSelected() } label: { Label("Summarize", systemImage: "text.alignleft") }
                    .disabled(model.isWorking("summary", on: thread))
            }
            Menu {
                Button { model.startReply() } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                Button { model.startReply(all: true) } label: { Label("Reply all", systemImage: "arrowshape.turn.up.left.2") }
                Button { model.startForward() } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            } primaryAction: {
                model.startReply()
            }
        }
    }
}
#endif
