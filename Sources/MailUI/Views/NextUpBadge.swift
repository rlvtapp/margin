import MailCore
import SwiftUI

/// The one next thing, top right of the window: a meeting happening now or within a few hours
/// (with Join when it's about to start), or else the next snoozed conversation coming back
/// today. Nothing when there's nothing.
struct NextUpBadge: View {
    let model: MailModel

    var body: some View {
        if model.nextEvent != nil {
            NextEventChip(model: model)
        } else if let (thread, until) = comingBack {
            Button {
                model.go(to: .snoozed(account: nil))
                model.select(thread.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.tertiary)
                    Text(verbatim: thread.latest.from.displayName).font(TypeScale.label.weight(.medium)).foregroundStyle(Ink.primary).lineLimit(1)
                    Text("Back \(until.formatted(date: .omitted, time: .shortened))")
                        .font(TypeScale.label.monospacedDigit()).foregroundStyle(Ink.tertiary)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .glassCapsule(tint: nil)
                .frame(maxWidth: 320)
            }
            .buttonStyle(.plain)
            .help(thread.subject)
        }
    }

    /// The snoozed conversation that comes back next, if it does today.
    private var comingBack: (MailThread, Date)? {
        _ = model.clockTick
        return model.inboxThreads(nil)
            .compactMap { thread in model.snoozedUntil(thread).map { (thread, $0) } }
            .filter { Calendar.current.isDateInToday($0.1) }
            .min { $0.1 < $1.1 }
    }
}
