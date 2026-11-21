import MailCore
import SwiftUI

/// A slim column right of the reader on a wide window, read like a page of the calendar: the
/// next meeting as a card you can answer and join from, the rest of the week by day (each in its
/// calendar's colour), then mail that's coming back or waiting for a reply. Clicking a meeting
/// opens its details beside it, so you stay in your mail. Meetings you declined are left out, as
/// on the Calendar page.
struct NextUpColumn: View {
    @Environment(\.mailAccent) private var accent
    @Bindable var model: MailModel
    @State private var waiting: [MailThread] = []

    static let width: CGFloat = 260
    /// The list, reader and column need this much room together before the column shows.
    static let minimumPanelWidth: CGFloat = 880
    /// Meetings listed under the card at most; the Calendar has the rest.
    static let meetingLimit = 7

    var body: some View {
        // The whole column follows the clock, so a meeting that has ended leaves it.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .frame(width: Self.width)
        .background(Paper.panel)
        .task(id: model.lastUpdated) { waiting = await model.waitingThreads(nil) }
    }

    private func content(now: Date) -> some View {
        let today = Calendar.current.startOfDay(for: now)
        let items = model.calendarItems(from: today, to: today.addingTimeInterval(8 * 86_400))
        let plan = Self.plan(items, now: now)
        let snoozed = Array(model.snoozedInInboxes(nil).sorted { $0.until < $1.until }.prefix(4))
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(now: now)
                if let next = plan.next {
                    NextMeetingCard(model: model, item: next, now: now)
                        .padding(.top, Space.m)
                } else if plan.days.isEmpty {
                    Text("Nothing on your calendar this week.")
                        .font(TypeScale.label)
                        .foregroundStyle(Ink.tertiary)
                        .padding(.top, Space.m)
                }
                ForEach(plan.days, id: \.day) { day in
                    dayHeading(day.day)
                    ForEach(day.items) { item in NextUpMeetingRow(model: model, item: item) }
                }
                if !snoozed.isEmpty {
                    mailHeading("Snoozed", count: snoozed.count)
                    ForEach(snoozed, id: \.thread.id) { thread, until in
                        NextUpMailRow(title: thread.latest.from.displayName, detail: thread.subject, when: Text("Back \(Self.when(until))")) {
                            model.go(to: .snoozed(account: nil), selecting: thread.id)
                        }
                    }
                }
                if !waiting.isEmpty {
                    mailHeading("Waiting for a reply", count: waiting.count)
                    ForEach(waiting.prefix(4)) { thread in
                        NextUpMailRow(title: thread.latest.to.first?.displayName ?? thread.subject, detail: thread.subject,
                                      when: Text(verbatim: Self.when(thread.date))) {
                            model.go(to: .waiting(account: nil), selecting: thread.id)
                        }
                    }
                }
            }
            .padding(.horizontal, Space.l)
            .padding(.top, Space.l)
            .padding(.bottom, Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Next up, today's date under it, and the way to the whole calendar.
    private func header(now: Date) -> some View {
        HStack(alignment: .center, spacing: Space.xs) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Next up").font(TypeScale.heading).foregroundStyle(Ink.primary)
                Text(verbatim: now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(TypeScale.label)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            IconButton("calendar", help: "Open Calendar") { model.go(to: .calendar) }
        }
    }

    private func dayHeading(_ day: Date) -> some View {
        Text(verbatim: Self.title(for: day))
            .font(.system(size: Look.size(12), weight: .semibold))
            .foregroundStyle(Calendar.current.isDateInToday(day) ? accent : Ink.primary)
            .padding(.top, Space.l)
            .padding(.bottom, 4)
    }

    private func mailHeading(_ title: LocalizedStringKey, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: Look.size(12), weight: .semibold)).foregroundStyle(Ink.primary)
            Text(verbatim: "\(count)").font(.system(size: Look.size(12)).monospacedDigit()).foregroundStyle(Ink.tertiary)
        }
        .padding(.top, Space.xl)
        .padding(.bottom, 4)
    }

    // MARK: What it shows

    /// The next timed meeting (on now or the soonest to start) for the card, and the rest by day,
    /// soonest first. Meetings that have ended or that you declined are gone; days follow in
    /// order up to `limit` meetings, and a later day starts only when more than its heading fits.
    static func plan(_ items: [AgendaItem], now: Date, limit: Int = meetingLimit,
                     calendar: Calendar = .current) -> (next: AgendaItem?, days: [(day: Date, items: [AgendaItem])]) {
        let today = calendar.startOfDay(for: now)
        let upcoming = items.filter { $0.end > now && $0.response != .declined }.sorted { $0.start < $1.start }
        let next = upcoming.first { !$0.isAllDay }
        var days: [(day: Date, items: [AgendaItem])] = []
        var count = 0
        for item in upcoming where item.id != next?.id {
            guard count < limit else { break }
            let day = max(calendar.startOfDay(for: item.start), today)
            if days.last?.day != day {
                if day != today && count >= limit - 1 { break }
                days.append((day, []))
            }
            days[days.count - 1].items.append(item)
            count += 1
        }
        return (next, days)
    }

    static func title(for day: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInTomorrow(day) { return String(localized: "Tomorrow") }
        return day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
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

/// The next meeting: how soon in the accent colour, what, when and where, Yes/Maybe/No when it
/// asks for an answer, and Join (filled once it's about to start). Tinted in its calendar's
/// colour with the same edge as a block on the Calendar page; clicking it shows its details.
private struct NextMeetingCard: View {
    @Environment(\.mailAccent) private var accent
    let model: MailModel
    let item: AgendaItem
    let now: Date
    @State private var showsDetail = false

    var body: some View {
        let soon = item.start.timeIntervalSince(now) < 15 * 60
        let tint = Palette.account(item.colorIndex)
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: Countdown.text(for: item, now: now))
                    .font(TypeScale.label.weight(.semibold).monospacedDigit())
                    .foregroundStyle(accent)
                    .lineLimit(1)
                Text(verbatim: item.title)
                    .font(.system(size: Look.size(14), weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: details)
                    .font(TypeScale.label.monospacedDigit())
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
            }
            if item.canAnswer {
                GoingPicker(response: item.response, isSending: model.isAnswering(item)) { model.respond(to: item, with: $0) }
            }
            if let url = item.joinURL {
                Link(destination: url) { Text("Join").frame(maxWidth: .infinity) }
                    .buttonStyle(JoinButtonStyle(prominent: soon))
            }
        }
        .padding(.leading, 15)
        .padding([.vertical, .trailing], 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12))
        .overlay(alignment: .leading) { Rectangle().fill(tint).frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { showsDetail = true }
        .contextMenu { EventMenu(model: model, item: item) }
        .popover(isPresented: $showsDetail, arrowEdge: .leading) { EventDetail(model: model, item: item) }
        .accessibilityElement(children: .contain)
    }

    /// "20:50 – 21:35 · Room 4", or the call's service when there's no room.
    private var details: String {
        let time = item.start.formatted(date: .omitted, time: .shortened) + " – " + item.end.formatted(date: .omitted, time: .shortened)
        let place = item.location.flatMap { $0.isEmpty ? nil : $0 } ?? item.joinURL.flatMap(AgendaRow.service)
        return [time, place].compactMap { $0 }.joined(separator: " · ")
    }
}

/// One meeting under a day: its calendar's colour as an edge, the start time in a fixed column,
/// the title, and where it is, or that it still waits for your answer. Clicking it shows its
/// details (answer, Join, the invitation) beside the column.
private struct NextUpMeetingRow: View {
    @Environment(\.mailAccent) private var accent
    let model: MailModel
    let item: AgendaItem
    @State private var isHovered = false
    @State private var showsDetail = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Palette.account(item.colorIndex))
                .frame(width: 2)
                .frame(maxHeight: .infinity)
            Text(verbatim: time)
                .font(.system(size: Look.size(12)).monospacedDigit())
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.title)
                    .font(TypeScale.rowStrong)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let state {
                    // A small dot in the accent colour marks it; the words stay quiet.
                    HStack(spacing: 5) {
                        Circle().fill(accent).frame(width: 5, height: 5)
                        Text(verbatim: state).font(TypeScale.label).foregroundStyle(Ink.secondary).lineLimit(1)
                    }
                } else if !place.isEmpty {
                    Text(verbatim: place).font(TypeScale.label).foregroundStyle(Ink.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(isHovered || showsDetail ? Fill.one : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, -6)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { showsDetail = true }
        .contextMenu { EventMenu(model: model, item: item) }
        .popover(isPresented: $showsDetail, arrowEdge: .leading) { EventDetail(model: model, item: item) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { showsDetail = true }
    }

    private var time: String {
        item.isAllDay ? String(localized: "All day") : item.start.formatted(date: .omitted, time: .shortened)
    }

    /// Asking for an answer, or answered Maybe: said instead of the place, marked with an accent dot.
    private var state: String? {
        guard item.canAnswer else { return nil }
        if item.response == nil { return String(localized: "Not answered yet") }
        if item.response == .tentative { return CalendarInvite.Response.tentative.shortTitle }
        return nil
    }

    private var place: String {
        item.location.flatMap { $0.isEmpty ? nil : $0 } ?? item.joinURL.flatMap(AgendaRow.service) ?? ""
    }
}

/// A snoozed or waiting conversation: who, when, and the subject. Clicking opens it in its list.
private struct NextUpMailRow: View {
    let title: String
    let detail: String
    let when: Text
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    Text(verbatim: title).font(TypeScale.rowStrong).foregroundStyle(Ink.primary).lineLimit(1)
                    Spacer(minLength: 0)
                    when.font(TypeScale.label.monospacedDigit()).foregroundStyle(Ink.tertiary).lineLimit(1).layoutPriority(1)
                }
                Text(verbatim: detail).font(TypeScale.label).foregroundStyle(Ink.tertiary).lineLimit(1)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .background(isHovered ? Fill.one : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, -6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
