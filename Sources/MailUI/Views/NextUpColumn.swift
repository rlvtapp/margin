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
        let now = Date()
        let agenda = model.agenda(from: now, to: now.addingTimeInterval(7 * 86_400)).filter { $0.response != .declined && $0.end > now }
        let next = agenda.first { !$0.isAllDay }
        let meetings = Array(agenda.filter { $0.id != next?.id }.prefix(5))
        let snoozed = model.inboxThreads(nil)
            .compactMap { thread in model.snoozedUntil(thread).map { (thread, $0) } }
            .sorted { $0.1 < $1.1 }
            .prefix(5)
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                Text("Next up").font(TypeScale.heading).foregroundStyle(Ink.primary)
                if next == nil && meetings.isEmpty && snoozed.isEmpty && waiting.isEmpty {
                    Text("Nothing coming up.").font(TypeScale.row).foregroundStyle(Ink.tertiary)
                }
                if next != nil || !meetings.isEmpty {
                    section("Meetings") {
                        if let next { NextMeetingCard(model: model, item: next) }
                        ForEach(meetings) { item in meetingRow(item) }
                        Button { model.go(to: .calendar) } label: {
                            Text("Open Calendar").font(TypeScale.label.weight(.medium)).foregroundStyle(Palette.accent)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 6)
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

    private func meetingRow(_ item: AgendaItem) -> some View {
        let when = item.isAllDay
            ? (Calendar.current.isDateInToday(item.start) ? String(localized: "All day") : item.start.formatted(.dateTime.weekday(.abbreviated)))
            : Self.when(item.start)
        return row(title: item.title, detail: item.location, when: Text(verbatim: when)) {
            if let threadID = item.invitationThreadID {
                model.showInvitation(threadID: threadID, title: item.title)
            } else {
                model.go(to: .calendar)
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

/// The next meeting at the top of Next up: how soon, what, when and where, and Join.
private struct NextMeetingCard: View {
    let model: MailModel
    let item: AgendaItem

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let soon = item.start.timeIntervalSince(context.date) < 15 * 60
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: Countdown.text(for: item, now: context.date))
                    .font(TypeScale.label.weight(.semibold))
                    .foregroundStyle(Palette.accent)
                Text(verbatim: item.title)
                    .font(TypeScale.rowStrong)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(2)
                Text(verbatim: [item.start.formatted(date: .omitted, time: .shortened) + " – " + item.end.formatted(date: .omitted, time: .shortened),
                                item.location].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                    .font(TypeScale.label)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
                if let url = item.joinURL {
                    Link(destination: url) {
                        Text("Join")
                            .font(TypeScale.label.weight(.semibold))
                            .foregroundStyle(soon ? Ink.inverse : Palette.accent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .background(soon ? Palette.accent : Palette.accent.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
            .padding(12)
            .background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture {
                if let threadID = item.invitationThreadID { model.showInvitation(threadID: threadID, title: item.title) }
            }
            .padding(.bottom, 6)
        }
    }
}
