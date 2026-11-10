import MailCore
import SwiftUI

/// A slim column right of the reader on a wide window: meetings coming up, snoozed mail and when
/// it comes back, and mail waiting for a reply. Sections with nothing in them are left out.
struct NextUpColumn: View {
    @Bindable var model: MailModel
    @State private var waiting: [MailThread] = []

    static let width: CGFloat = 260
    /// The list, reader and column need this much room together before the column shows.
    static let minimumPanelWidth: CGFloat = 880

    var body: some View {
        let meetings = Array(model.upcomingEvents.filter { $0.start < Date().addingTimeInterval(7 * 86_400) }.prefix(5))
        let snoozed = model.inboxThreads(nil)
            .compactMap { thread in model.snoozedUntil(thread).map { (thread, $0) } }
            .sorted { $0.1 < $1.1 }
            .prefix(5)
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                Text("Next up").font(TypeScale.heading).foregroundStyle(Ink.primary)
                if meetings.isEmpty && snoozed.isEmpty && waiting.isEmpty {
                    Text("Nothing coming up.").font(TypeScale.row).foregroundStyle(Ink.tertiary)
                }
                if !meetings.isEmpty {
                    section("Meetings") {
                        ForEach(meetings) { event in meetingRow(event) }
                    }
                }
                if !snoozed.isEmpty {
                    section("Snoozed") {
                        ForEach(Array(snoozed), id: \.0.id) { thread, until in
                            row(title: thread.latest.from.displayName, detail: thread.subject,
                                when: Text("Back \(Self.when(until))")) {
                                model.go(to: .snoozed(account: nil))
                                model.select(thread.id)
                            }
                        }
                    }
                }
                if !waiting.isEmpty {
                    section("Waiting for a reply") {
                        ForEach(waiting.prefix(5)) { thread in
                            row(title: thread.messages.first?.to.first?.displayName ?? thread.subject, detail: thread.subject,
                                when: Text(verbatim: Self.when(thread.date))) {
                                model.go(to: .waiting(account: nil))
                            }
                        }
                    }
                }
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: Self.width)
        .background(Paper.panel)
        .task(id: model.lastUpdated) { waiting = await model.waitingThreads(nil) }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(TypeScale.label.weight(.medium)).foregroundStyle(Ink.tertiary).padding(.bottom, 4)
            content()
        }
    }

    private func meetingRow(_ event: CalendarEntry) -> some View {
        let now = Date()
        let soon = event.start <= now || event.start.timeIntervalSince(now) < 10 * 60
        return HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            row(title: event.title, detail: event.location, when: Text(verbatim: event.start <= now ? String(localized: "now") : Self.when(event.start))) {
                model.open(event)
            }
            if soon, let join = event.joinURL {
                Link("Join", destination: join)
                    .font(TypeScale.label.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(Palette.accent, in: Capsule())
            }
        }
    }

    private func row(title: String, detail: String?, when: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: title).font(TypeScale.rowStrong).foregroundStyle(Ink.primary).lineLimit(1)
                    Spacer(minLength: Space.xs)
                    when.font(TypeScale.label.monospacedDigit()).foregroundStyle(Ink.tertiary).lineLimit(1)
                }
                if let detail, !detail.isEmpty {
                    Text(verbatim: detail).font(TypeScale.label).foregroundStyle(Ink.tertiary).lineLimit(1)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "14:00" today, "Tue 09:30" this week, "12 Nov" later.
    static func when(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if abs(date.timeIntervalSinceNow) < 6 * 86_400 {
            return date.formatted(.dateTime.weekday(.abbreviated)) + " " + date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
