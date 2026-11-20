import AuthenticationServices
import MailCore
import SwiftUI

/// How the Calendar shows things: the agenda (a month to pick a day and two weeks of meetings
/// as a list), or a day, a week or a month laid out as a calendar.
enum CalendarMode: String, CaseIterable, Identifiable {
    case agenda, day, week, month

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .agenda: "Agenda"
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        }
    }
}

/// The Calendar: the agenda, or a day, week or month. Meetings come from invitations in the
/// mail, from the account's own calendar where Margin may read it, and from this device's
/// Calendar app and Reminders when they're turned on. Events are made, moved and changed here.
struct CalendarPage: View {
    @Bindable var model: MailModel
    @AppStorage("calendarMode") private var chosenMode = CalendarMode.agenda.rawValue
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    @State private var day = Calendar.current.startOfDay(for: Date())
    /// After scrolling sideways in Week, the week starts on whichever day it settled on.
    @State private var weekStart: Date?
    @State private var isRefreshing = false
    @State private var showsSources = false
    @State private var editor: CalendarEditor

    init(model: MailModel) {
        self.model = model
        _editor = State(initialValue: CalendarEditor(model: model))
    }

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= 760
            // A week needs room for seven columns; on a phone it's a day at a time.
            let modes: [CalendarMode] = proxy.size.width >= 560 ? CalendarMode.allCases : [.agenda, .day, .month]
            let chosen = CalendarMode(rawValue: chosenMode) ?? .agenda
            let mode = modes.contains(chosen) ? chosen : .day
            let side = wide ? CGFloat(28) : Space.l
            // The month and the list of calendars sit on the left when there's room.
            // Day and Week need the room for their columns first.
            let hasSidebar = !model.calendarSidebarHidden && proxy.size.width >= (mode == .week ? 1100 : 820)
            // The sidebar runs from the top; the toolbar sits over the calendar beside it.
            HStack(alignment: .top, spacing: 0) {
                if hasSidebar {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            monthView
                            CalendarSources(model: model, month: month)
                        }
                        // The same left edge as the mailbox list's rows.
                        .padding(.leading, 18)
                        .padding(.trailing, 16)
                        // Its month's name sits level with the toolbar beside it.
                        .padding(.top, wide ? 15 : Space.s + 3)
                        .padding(.bottom, 32)
                    }
                    .frame(width: 236 + side)
                    .scrollIndicators(.never)
                }
                VStack(alignment: .leading, spacing: 0) {
                    toolbar(mode: mode, modes: modes, hasSidebar: hasSidebar)
                        // Lined up with the edge of the grid below.
                        .padding(.leading, hasSidebar ? 12 : side)
                        // The same right edge as the inbox's buttons.
                        .padding(.trailing, Space.m)
                        .padding(.top, wide ? 12 : Space.s)
                        .padding(.bottom, wide ? 22 : Space.m)
                    switch mode {
                    case .agenda:
                        agendaPage(hasSidebar: hasSidebar, side: side)
                    case .day, .week:
                        CalendarTimeline(model: model, visibleDays: shownDays(mode), openDay: { go(to: $0, mode: .day) },
                                         scrollDays: { scrollDays($0, mode: mode) })
                            .id(mode)
                    case .month:
                        MonthBoard(model: model, month: $month, openDay: { go(to: $0, mode: .day) })
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // The sidebar on the mailbox list's grey, the whole height, with a hairline beside it.
            .background {
                HStack(spacing: 0) {
                    if hasSidebar {
                        Paper.sidebar.frame(width: 236 + side)
                        Rectangle().fill(Line.hairline).frame(width: 1)
                    }
                    Paper.panel
                }
                .ignoresSafeArea()
            }
        }
        .task(id: month) { await model.refreshCalendar(around: month) }
        .calendarEditing(editor)
    }

    private func toolbar(mode: CalendarMode, modes: [CalendarMode], hasSidebar: Bool) -> some View {
        HStack(spacing: 12) {
            if mode != .agenda {
                // Back, Today, forward: one glass capsule, as in Apple's calendars.
                HStack(spacing: 0) {
                    GlassIconButton("chevron.left", help: "Previous") { step(mode, by: -1) }
                    Button { go(to: Date(), mode: mode) } label: {
                        Text("Today")
                            .fixedSize()
                            .font(TypeScale.label.weight(.medium))
                            .foregroundStyle(Ink.primary)
                            .padding(.horizontal, 6)
                            .frame(height: Look.gap(30))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    GlassIconButton("chevron.right", help: "Next") { step(mode, by: 1) }
                }
                .padding(.horizontal, 3)
                .glassCapsule(tint: nil)
                .fixedSize()
                // The first thing to give way when the window narrows.
                Text(verbatim: Self.title(for: mode, day: day, month: month, week: shownDays(.week)))
                    .font(.system(size: Look.size(15), weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 8)
            CalendarModeSwitcher(modes: modes, mode: mode) { chosenMode = $0.rawValue }
                .fixedSize()
            HStack(spacing: 0) {
                GlassIconButton("plus", help: editor.canAdd ? "New Event" : "Show the Calendar app or connect a mailbox's calendar to add events") {
                    editor.newEvent(start: Self.newEventStart(on: day))
                }
                .disabled(!editor.canAdd)
                .opacity(editor.canAdd ? 1 : 0.4)
                if isRefreshing {
                    ProgressView().controlSize(.small).frame(width: Look.gap(30), height: Look.gap(30))
                } else {
                    GlassIconButton("arrow.clockwise", help: "Refresh") {
                        isRefreshing = true
                        Task {
                            await model.findInvites()
                            await model.refreshCalendar(around: month, force: true)
                            isRefreshing = false
                        }
                    }
                }
            }
            .padding(.horizontal, 3)
            .glassCapsule(tint: nil)
            .fixedSize()
            if !hasSidebar {
                IconButton("tray.full", help: "Where meetings come from") { showsSources.toggle() }
                    .popover(isPresented: $showsSources) {
                        CalendarSources(model: model, month: month)
                            .padding(Space.l)
                            .frame(width: 320)
                    }
            }
        }
        .frame(height: 36)
    }

    private func agendaPage(hasSidebar: Bool, side: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if hasSidebar {
                    agendaView
                } else {
                    monthView
                    CalendarSources(model: model, month: month)
                    agendaView
                }
            }
            // A calm page with room around it, not panes stretched across the window.
            .padding(.horizontal, side)
            .padding(.top, 4)
            .padding(.bottom, 64)
            .frame(maxWidth: 760 + side * 2, alignment: .leading)
            // Centred in the space beside the sidebar.
            .frame(maxWidth: .infinity)
        }
    }

    private var monthView: some View {
        MonthGrid(month: $month, day: $day,
                  marked: model.daysWithEvents(from: MonthGrid.firstShown(in: month), to: MonthGrid.lastShown(in: month)))
    }

    private var agendaView: some View {
        let end = Calendar.current.date(byAdding: .day, value: 14, to: day) ?? day
        return AgendaList(model: model, items: model.agenda(from: day, to: end), from: day, to: end)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Moving around

    /// The days in view: Week as the region starts weeks, until scrolling moves it a day at a time.
    private func shownDays(_ mode: CalendarMode) -> [Date] {
        let calendar = Calendar.current
        guard mode == .week, let weekStart else { return Self.days(for: mode, around: day) }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }

    /// Scrolling sideways: the days move one at a time, with no animation (the grid slides).
    private func scrollDays(_ count: Int, mode: CalendarMode) {
        let calendar = Calendar.current
        if mode == .week {
            let start = calendar.date(byAdding: .day, value: count, to: shownDays(.week).first ?? day) ?? day
            weekStart = start
            day = start
        } else {
            day = calendar.date(byAdding: .day, value: count, to: day) ?? day
        }
        // Only when it changes: a new month reads the calendars again.
        let newMonth = calendar.dateInterval(of: .month, for: day)?.start ?? month
        if newMonth != month { month = newMonth }
    }

    private func go(to date: Date, mode: CalendarMode) {
        let calendar = Calendar.current
        weekStart = nil
        withAnimation(Motion.quick) {
            chosenMode = mode.rawValue
            day = calendar.startOfDay(for: date)
            month = calendar.dateInterval(of: .month, for: day)?.start ?? month
        }
    }

    private func step(_ mode: CalendarMode, by count: Int) {
        let calendar = Calendar.current
        let next: Date? = switch mode {
        case .day: calendar.date(byAdding: .day, value: count, to: day)
        case .week: calendar.date(byAdding: .day, value: 7 * count, to: day)
        case .month, .agenda: calendar.date(byAdding: .month, value: count, to: month)
        }
        go(to: next ?? day, mode: mode)
    }

    /// A new event from the toolbar: the next half hour today, nine o'clock on another day.
    static func newEventStart(on day: Date) -> Date {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) {
            let half = 30.0 * 60
            return Date(timeIntervalSinceReferenceDate: (Date().timeIntervalSinceReferenceDate / half).rounded(.up) * half)
        }
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
    }

    /// The days a day or week shows: the day, or its week as the region starts weeks.
    static func days(for mode: CalendarMode, around day: Date) -> [Date] {
        let calendar = Calendar.current
        guard mode == .week else { return [calendar.startOfDay(for: day)] }
        let first = calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? day
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }

    /// "Thursday 19 November", "16 – 22 November 2026", "November 2026".
    static func title(for mode: CalendarMode, day: Date, month: Date, week: [Date]? = nil) -> String {
        switch mode {
        case .day:
            return day.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        case .week:
            let days = week ?? Self.days(for: .week, around: day)
            guard let first = days.first, let last = days.last else { return "" }
            return (first..<last).formatted(.interval.day().month(.wide).year())
        case .month, .agenda:
            return month.formatted(.dateTime.month(.wide).year())
        }
    }
}

/// A month of days, Monday or Sunday first as the region likes it, with a dot under days that
/// have something on. Today is in the accent colour; the chosen day sits on a soft circle.
struct MonthGrid: View {
    @Environment(\.mailAccent) private var accent
    @Binding var month: Date
    @Binding var day: Date
    let marked: Set<Date>

    static func firstShown(in month: Date) -> Date {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: month)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -offset, to: month) ?? month
    }

    static func lastShown(in month: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: 42, to: firstShown(in: month)) ?? month
    }

    private var days: [Date] {
        let first = Self.firstShown(in: month)
        return (0..<42).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: first) }
    }

    private var weekdaySymbols: [String] {
        let calendar = Calendar.current
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let start = calendar.firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 2) {
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(.system(size: Look.size(15), weight: .semibold))
                    .foregroundStyle(Ink.primary)
                Spacer()
                IconButton("chevron.left", help: "Previous month") { step(-1) }
                IconButton("chevron.right", help: "Next month") { step(1) }
            }
            let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
            // The old and new month fade over each other in one place. Stacked in the column, both
            // would take room for a moment and push everything below down and back up.
            ZStack(alignment: .top) {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(verbatim: symbol)
                        .font(.system(size: Look.size(11), weight: .medium))
                        .foregroundStyle(Ink.tertiary)
                        .frame(height: Look.gap(22))
                }
                ForEach(days, id: \.self) { date in
                    DayCell(date: date, inMonth: Calendar.current.isDate(date, equalTo: month, toGranularity: .month),
                            isChosen: Calendar.current.isDate(date, inSameDayAs: day), isMarked: marked.contains(date)) {
                        withAnimation(Motion.quick) { day = date }
                        if !Calendar.current.isDate(date, equalTo: month, toGranularity: .month) {
                            month = Calendar.current.dateInterval(of: .month, for: date)?.start ?? month
                        }
                    }
                }
            }
            .id(month)
            .transition(.opacity)
            }
        }
    }

    private func step(_ months: Int) {
        withAnimation(Motion.quick) { month = Calendar.current.date(byAdding: .month, value: months, to: month) ?? month }
    }
}

private struct DayCell: View {
    @Environment(\.mailAccent) private var accent
    let date: Date
    let inMonth: Bool
    let isChosen: Bool
    let isMarked: Bool
    let action: () -> Void

    var body: some View {
        let isToday = Calendar.current.isDateInToday(date)
        Button(action: action) {
            VStack(spacing: 2) {
                Text(verbatim: "\(Calendar.current.component(.day, from: date))")
                    .font(.system(size: Look.size(13), weight: isToday ? .bold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isToday ? accent : inMonth ? Ink.primary : Ink.quaternary)
                    .frame(width: 30, height: 30)
                    .background { if isChosen { Circle().fill(accent.opacity(0.14)) } }
                Circle()
                    .fill(isMarked ? accent.opacity(inMonth ? 1 : 0.4) : .clear)
                    .frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(date.formatted(date: .complete, time: .omitted)))
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}

/// The days from the chosen one, laid out like a diary: each day's date large on the left, its
/// meetings beside it. Meetings that have ended are left out; today has a quiet line for now,
/// gaps of half an hour or more say so, and a meeting that clashes with the one before says it.
private struct AgendaList: View {
    @Environment(\.mailAccent) private var accent
    let model: MailModel
    let items: [AgendaItem]
    let from: Date
    let to: Date

    /// One line in a day: a meeting, the time left free before the next, or now.
    enum Entry: Identifiable {
        case meeting(AgendaItem, overlaps: String?)
        case free(TimeInterval, until: Date)
        case now(Date)

        var id: String {
            switch self {
            case .meeting(let item, _): "m-" + item.id
            case .free(_, let until): "f-\(until.timeIntervalSince1970)"
            case .now: "now"
            }
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        let upcoming = items.filter { $0.isAllDay || $0.end > now }
        let next = upcoming.first { !$0.isAllDay && $0.response != .declined }
        let reminders = model.dueReminders.filter { !$0.isDone || Calendar.current.isDateInToday($0.due) }
        let days = Self.days(upcoming, reminders: reminders, from: from, to: to)
        return VStack(alignment: .leading, spacing: 0) {
            if days.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nothing on your calendar for the next two weeks.")
                        .font(TypeScale.row)
                        .foregroundStyle(Ink.secondary)
                    if !model.readsAccountCalendars && !model.showsDeviceCalendar {
                        Text("Margin shows meetings from invitations in your mail. Connect a mailbox to see its whole calendar.")
                            .font(TypeScale.label)
                            .foregroundStyle(Ink.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 16)
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(days, id: \.day) { entry in
                    let isToday = Calendar.current.isDateInToday(entry.day)
                    Section {
                        ForEach(model.reminders(on: entry.day)) { reminder in
                            ReminderRow(model: model, reminder: reminder)
                        }
                        let lines = Self.lines(entry.items, now: isToday ? now : nil)
                        ForEach(lines) { line in
                            switch line {
                            case .meeting(let item, let overlaps):
                                AgendaRow(model: model, item: item, overlaps: overlaps,
                                          startsIn: item.id == next?.id ? Countdown.short(for: item, now: now) : nil)
                            case .free:
                                EmptyView()
                            case .now(let time):
                                NowLine(time: time)
                            }
                        }
                    } header: {
                        HStack(spacing: 8) {
                            Text(verbatim: Self.title(for: entry.day))
                                .font(.system(size: Look.size(13), weight: .semibold))
                                .foregroundStyle(isToday ? accent : Ink.primary)
                            if !Calendar.current.isDateInToday(entry.day) && !Calendar.current.isDateInTomorrow(entry.day) {
                                EmptyView()
                            } else {
                                Text(verbatim: entry.day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                                    .font(.system(size: Look.size(13)))
                                    .foregroundStyle(Ink.tertiary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, entry.day == days.first?.day ? 4 : 28)
                        .padding(.bottom, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .animation(Motion.present, value: items.map(\.id))
    }

    static func title(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInTomorrow(day) { return String(localized: "Tomorrow") }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    static func days(_ items: [AgendaItem], reminders: [DueReminder] = [], from: Date, to: Date = .distantFuture) -> [(day: Date, items: [AgendaItem])] {
        let calendar = Calendar.current
        var result: [Date: [AgendaItem]] = [:]
        for item in items {
            result[max(calendar.startOfDay(for: item.start), from), default: []].append(item)
        }
        // A day with only reminders still gets its heading; overdue ones sit on today.
        let today = calendar.startOfDay(for: Date())
        for reminder in reminders {
            let day = max(calendar.startOfDay(for: reminder.due), reminder.due < today ? today : from)
            if day >= from, day < to, result[day] == nil { result[day] = [] }
        }
        return result.keys.sorted().map { ($0, result[$0] ?? []) }
    }

    /// A day's meetings with what's between them: free time of half an hour or more, the now line
    /// (today only), and which earlier meeting each one overlaps.
    static func lines(_ items: [AgendaItem], now: Date?) -> [Entry] {
        var lines: [Entry] = []
        var latestEnd: (Date, String)?
        var placedNow = now == nil
        for item in items {
            if !item.isAllDay {
                if !placedNow, let now, item.start > now {
                    lines.append(.now(now))
                    placedNow = true
                }
                if let (end, _) = latestEnd {
                    let begins = max(end, now ?? end)
                    if item.start.timeIntervalSince(begins) >= 30 * 60 { lines.append(.free(item.start.timeIntervalSince(begins), until: item.start)) }
                }
            }
            var overlaps: String?
            if !item.isAllDay, let (end, title) = latestEnd, item.start < end { overlaps = title }
            lines.append(.meeting(item, overlaps: overlaps))
            if !item.isAllDay, item.response != .declined, latestEnd.map({ item.end > $0.0 }) ?? true { latestEnd = (item.end, item.title) }
        }
        if !placedNow, let now { lines.append(.now(now)) }
        return lines
    }
}

/// "In 25 min", "Now · 20 min left", "Tomorrow at 10:00": how far away a meeting is.
enum Countdown {
    static func text(for item: AgendaItem, now: Date) -> String {
        let calendar = Calendar.current
        if item.start <= now {
            let left = Int(ceil(item.end.timeIntervalSince(now) / 60))
            return String(localized: "Now · \(Self.length(minutes: left)) left")
        }
        let minutes = Int(ceil(item.start.timeIntervalSince(now) / 60))
        if minutes < 120 { return String(localized: "In \(Self.length(minutes: minutes))") }
        let time = item.start.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(item.start) { return String(localized: "Today at \(time)") }
        if calendar.isDateInTomorrow(item.start) { return String(localized: "Tomorrow at \(time)") }
        return item.start.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)) + " · " + time
    }

    /// Beside the next meeting's time: "now", "in 25 min", "in 3 h"; nil when it's days away.
    static func short(for item: AgendaItem, now: Date) -> String? {
        if item.start <= now { return String(localized: "now") }
        let minutes = Int(ceil(item.start.timeIntervalSince(now) / 60))
        guard minutes < 24 * 60 else { return nil }
        return String(localized: "in \(Self.length(minutes: minutes < 120 ? minutes : (minutes / 60) * 60))")
    }

    /// "25 min", "1 h", "1 h 30".
    static func length(minutes: Int) -> String {
        if minutes < 60 { return String(localized: "\(minutes) min") }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? String(localized: "\(hours) h") : String(localized: "\(hours) h \(rest)")
    }
}

/// Where now is in today's meetings: a dot, the time and a thin line in the accent colour.
private struct NowLine: View {
    @Environment(\.mailAccent) private var accent
    let time: Date

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(accent).frame(width: 7, height: 7)
            Text(verbatim: time.formatted(date: .omitted, time: .shortened))
                .font(.system(size: Look.size(11), weight: .semibold).monospacedDigit())
                .foregroundStyle(accent)
            Rectangle().fill(accent.opacity(0.5)).frame(height: 1)
        }
        .padding(.leading, 9)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Now"))
    }
}

/// One meeting, as in the reference: a line in the accent colour, the time (with how soon, for
/// the next one), what and where, Going? with Yes, Maybe and No, and Join. Clicking it opens the
/// email its invitation came in.
struct AgendaRow: View {
    @Environment(\.mailAccent) private var accent
    let model: MailModel
    @Environment(CalendarEditor.self) private var editor: CalendarEditor?
    let item: AgendaItem
    var overlaps: String?
    var startsIn: String?
    @State private var isHovered = false

    private var isSoon: Bool { !item.isAllDay && item.start.timeIntervalSinceNow < 15 * 60 }
    private var declined: Bool { item.response == .declined }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Palette.account(item.colorIndex).opacity(declined ? 0.35 : 1))
                .frame(width: 2)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(verbatim: time)
                        .font(.system(size: Look.size(13)))
                        .monospacedDigit()
                        .foregroundStyle(Ink.secondary)
                    if item.repeats {
                        Image(systemName: "repeat").font(.system(size: Look.size(9), weight: .semibold)).foregroundStyle(Ink.quaternary)
                            .tip("Repeats")
                    }
                }
                if let startsIn {
                    Text(verbatim: startsIn)
                        .font(.system(size: Look.size(12), weight: .semibold))
                        .foregroundStyle(accent)
                }
            }
            .frame(width: 120, alignment: .leading)
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: item.title)
                        .font(.system(size: Look.size(14), weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !place.isEmpty {
                        Text(verbatim: place).font(TypeScale.label).foregroundStyle(Ink.tertiary).lineLimit(1)
                    }
                    if let overlaps {
                        Text("Overlaps with \(overlaps)").font(TypeScale.label).foregroundStyle(Status.star).lineLimit(1)
                    }
                }
                if item.canAnswer { GoingPicker(response: item.response, isSending: model.isAnswering(item)) { model.respond(to: item, with: $0) } }
            }
            Spacer(minLength: Space.m)
            if let url = item.joinURL {
                Link(destination: url) { Text("Join") }
                    .buttonStyle(JoinButtonStyle(prominent: isSoon && !declined))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 16)
        .padding(.horizontal, 16)
        .background(isHovered ? Fill.one : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(declined ? 0.5 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { open() }
        .onHover { isHovered = $0 }
        .accessibilityAction(named: Text("Show Invitation")) { open() }
        .contextMenu { EventMenu(model: model, item: item) }
    }

    private func open() { EventMenu.open(item, in: model, editor: editor) }

    private var time: String {
        if item.isAllDay { return String(localized: "All day") }
        return item.start.formatted(date: .omitted, time: .shortened) + " – " + item.end.formatted(date: .omitted, time: .shortened)
    }

    /// Where: the room or address, else the call's service; and which of this device's
    /// calendars it's in.
    private var place: String {
        let where_ = item.location.flatMap { $0.isEmpty ? nil : $0 } ?? item.joinURL.flatMap(Self.service)
        return [where_, item.calendarName].compactMap { $0 }.joined(separator: " · ")
    }

    /// The video service a meeting link is on, by its address.
    static func service(_ url: URL) -> String? {
        let host = url.host()?.lowercased() ?? ""
        if host.contains("teams.microsoft") || host.contains("teams.live") { return "Microsoft Teams" }
        if host.contains("meet.google") { return "Google Meet" }
        if host.contains("zoom.us") { return "Zoom" }
        if host.contains("webex") { return "Webex" }
        return String(localized: "Video call")
    }
}

/// Yes, Maybe and No; your answer is filled in the accent colour.
struct GoingPicker: View {
    @Environment(\.mailAccent) private var accent
    let response: CalendarInvite.Response?
    /// An answer is on its way: the picker waits, so it can't be sent twice.
    var isSending = false
    let choose: (CalendarInvite.Response) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach([CalendarInvite.Response.accepted, .tentative, .declined], id: \.self) { option in
                let isOn = response == option
                Button { choose(option) } label: {
                    Text(verbatim: option.shortTitle)
                        .font(.system(size: Look.size(12), weight: .semibold))
                        .foregroundStyle(isOn ? Ink.inverse : Ink.secondary)
                        .padding(.horizontal, 11)
                        .frame(height: Look.gap(24))
                        .background(isOn ? accent : Fill.one, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isSending)
                .opacity(isSending ? (isOn ? 0.7 : 0.45) : 1)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Going?"))
    }
}

/// Join: filled in the accent colour when the meeting is about to start or on now, a soft
/// tint of it before that.
struct JoinButtonStyle: ButtonStyle {
    @Environment(\.mailAccent) private var accent
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: Look.size(12), weight: .semibold))
            .foregroundStyle(prominent ? Ink.inverse : accent)
            .padding(.horizontal, 16)
            .frame(height: Look.gap(28))
            .background(prominent ? accent : accent.opacity(0.12), in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// The Calendar's list of calendars, ticked to show them: each mailbox (its invitations, and its
/// whole calendar once connected), the calendars in this device's Calendar app, and Reminders.
/// Each in its own colour, as on the page. Connecting and showing more happens here too.
struct CalendarSources: View {
    @Environment(\.mailAccent) private var accent
    let model: MailModel
    let month: Date
    @Environment(\.webAuthenticationSession) private var webAuthentication
    @State private var connecting: UUID?
    @State private var problem: String?
    @State private var working: String?
    /// Mailboxes whose list of calendars is folded away, kept between launches.
    @AppStorage("calendar.foldedMailboxes") private var foldedList = ""
    private var foldedMailboxes: Set<UUID> {
        get { Set(foldedList.split(separator: ",").compactMap { UUID(uuidString: String($0)) }) }
        nonmutating set { foldedList = newValue.map(\.uuidString).sorted().joined(separator: ",") }
    }

    private var mailboxes: [MailAccount] { model.accounts }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SidebarSection(id: "mailboxes", title: "Mailboxes") { EmptyView() } content: {
            ForEach(mailboxes) { account in
                let calendars = model.accountCalendars[account.id] ?? []
                CalendarCheckRow(title: account.address.address, colorIndex: account.colorIndex,
                                 isOn: model.isCalendarShown(MailModel.calendarKey(account: account.id))) {
                    model.setCalendarShown(MailModel.calendarKey(account: account.id), $0)
                } trailing: {
                    if calendars.count > 1 {
                        FoldButton(folded: foldedMailboxes.contains(account.id)) {
                            if foldedMailboxes.contains(account.id) { foldedMailboxes.remove(account.id) } else { foldedMailboxes.insert(account.id) }
                        }
                    }
                    mailboxAction(account)
                }
                // Each of the mailbox's calendars, its own first, then ones shared with you.
                if calendars.count > 1, !foldedMailboxes.contains(account.id), model.isCalendarShown(MailModel.calendarKey(account: account.id)) {
                    ForEach(calendars.sorted { ($0.isDefault ? 0 : 1, $0.owner == nil ? 0 : 1) < ($1.isDefault ? 0 : 1, $1.owner == nil ? 0 : 1) }) { calendar in
                        let key = MailModel.calendarKey(account: account.id, calendar: calendar.id)
                        CalendarCheckRow(title: calendar.name,
                                         colorIndex: calendar.isDefault ? account.colorIndex : (calendar.color.map(Palette.nearestAccountIndex(to:)) ?? account.colorIndex),
                                         isOn: model.isCalendarShown(key)) { model.setCalendarShown(key, $0) } trailing: { EmptyView() }
                            .padding(.leading, Look.size(23))
                            .help(Text(verbatim: calendar.owner?.displayName ?? calendar.name))
                    }
                }
            }
            Text(model.readsAccountCalendars ? "Invitations in your mail, and the calendars you connected."
                                             : "Invitations in your mail. Connect a mailbox to see its whole calendar.")
                .font(TypeScale.caption)
                .foregroundStyle(Ink.quaternary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 10)

            ColleagueList(model: model)
                .padding(.bottom, 10)

            SidebarSection(id: "device", title: "Calendar app") {
                if model.showsDeviceCalendar {
                    stopMenu { await model.setShowsDeviceCalendar(false) }
                }
            } content: {
            if model.showsDeviceCalendar {
                ForEach(model.deviceCalendars) { calendar in
                    let key = MailModel.calendarKey(device: calendar.title)
                    CalendarCheckRow(title: calendar.title, colorIndex: calendar.color.map(Palette.nearestAccountIndex(to:)) ?? 0,
                                     isOn: model.isCalendarShown(key)) { model.setCalendarShown(key, $0) } trailing: { EmptyView() }
                }
                if model.deviceCalendars.isEmpty {
                    Text("No calendars on this device.").font(TypeScale.caption).foregroundStyle(Ink.quaternary)
                }
            } else {
                showRow("The calendars on this device: iCloud, work accounts, holidays.", id: "device") {
                    await model.setShowsDeviceCalendar(true)
                }
            }
            }

            SidebarSection(id: "reminders", title: "Reminders") {
                if model.showsReminders {
                    stopMenu { await model.setShowsReminders(false) }
                }
            } content: {
            if model.showsReminders {
                CalendarCheckRow(title: String(localized: "Reminders with a due date"), colorIndex: nil,
                                 isOn: model.isCalendarShown(MailModel.remindersKey)) {
                    model.setCalendarShown(MailModel.remindersKey, $0)
                } trailing: { EmptyView() }
            } else {
                showRow("To-dos with a due date, ticked off right here.", id: "reminders") {
                    await model.setShowsReminders(true)
                }
            }
            }
            .padding(.top, 10)
            if let problem {
                Text(verbatim: problem).font(TypeScale.caption).foregroundStyle(Status.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 4)
    }

    private func heading(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: Look.size(12), weight: .semibold))
            .foregroundStyle(Ink.secondary)
            .padding(.bottom, 2)
    }

    /// A line saying what turning it on shows, and Show.
    private func showRow(_ text: LocalizedStringKey, id: String, turnOn: @escaping () async -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text)
                .font(TypeScale.caption)
                .foregroundStyle(Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            ZStack {
                // Room for the word, so nothing moves while it's asking.
                Text("Show").font(TypeScale.label.weight(.semibold)).hidden()
                if working == id {
                    ProgressView().controlSize(.mini)
                } else {
                    Button("Show") {
                        working = id
                        Task {
                            await turnOn()
                            working = nil
                        }
                    }
                    .buttonStyle(.plain)
                    .font(TypeScale.label.weight(.semibold))
                    .foregroundStyle(accent)
                }
            }
        }
    }

    private func stopMenu(_ stop: @escaping () async -> Void) -> some View {
        Menu {
            Button("Stop Showing") { Task { await stop() } }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: Look.size(11), weight: .semibold)).foregroundStyle(Ink.tertiary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicatorHidden()
        .fixedSize()
    }

    @ViewBuilder
    private func mailboxAction(_ account: MailAccount) -> some View {
        if account.connection == .sample || !model.canAskForAccess(account) {
            EmptyView()
        } else if model.usesAccountCalendar(account) {
            Menu {
                Button("Connect Again…") { Task { await reconnect(account) } }
                Button("Disconnect", role: .destructive) { disconnect(account) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: Look.size(11), weight: .semibold)).foregroundStyle(Ink.tertiary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicatorHidden()
            .fixedSize()
            .tip("Showing this mailbox's whole calendar")
        } else if connecting == account.id {
            ProgressView().controlSize(.mini)
        } else {
            Button("Connect") { Task { await connect(account) } }
                .buttonStyle(.plain)
                .font(TypeScale.label.weight(.semibold))
                .foregroundStyle(accent)
                .tip("Show this mailbox's whole calendar")
        }
    }

    private func disconnect(_ account: MailAccount) {
        model.removeAccess(for: account)
        model.forgetCalendar(of: account.id)
    }

    /// A new sign-in replaces the old one, so nothing needs removing first.
    private func reconnect(_ account: MailAccount) async {
        model.forgetCalendar(of: account.id)
        await connect(account)
    }

    private func connect(_ account: MailAccount) async {
        connecting = account.id
        defer { connecting = nil }
        do {
            try await model.requestAccess([.calendar, .contacts], for: account) { url, scheme in
                // A private sign-in with the mailbox's address filled in, so an account already signed in
                // to the browser can't be picked by mistake.
                try await webAuthentication.authenticate(using: url, callbackURLScheme: scheme, preferredBrowserSession: .ephemeral)
            }
            problem = nil
            await model.refreshCalendar(around: month, force: true)
        } catch let failure as ASWebAuthenticationSessionError where failure.code == .canceledLogin {
            return
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// A sidebar section whose heading folds it away; the choice is kept between launches.
struct SidebarSection<Accessory: View, Content: View>: View {
    let id: String
    let title: LocalizedStringKey
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let content: () -> Content
    @AppStorage private var folded: Bool

    init(id: String, title: LocalizedStringKey, @ViewBuilder accessory: @escaping () -> Accessory, @ViewBuilder content: @escaping () -> Content) {
        self.id = id
        self.title = title
        self.accessory = accessory
        self.content = content
        _folded = AppStorage(wrappedValue: false, "calendar.folded.\(id)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Button {
                    withAnimation(Motion.quick) { folded.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Text(title)
                            .font(.system(size: Look.size(12), weight: .semibold))
                            .foregroundStyle(Ink.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: Look.size(8.5), weight: .bold))
                            .foregroundStyle(Ink.quaternary)
                            .rotationEffect(.degrees(folded ? 0 : 90))
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(Text(folded ? "Collapsed" : "Expanded"))
                accessory()
            }
            .padding(.bottom, 2)
            if !folded {
                content()
                    .transition(.opacity)
            }
        }
    }
}

/// The small chevron that folds a mailbox's list of calendars.
private struct FoldButton: View {
    let folded: Bool
    let toggle: () -> Void

    var body: some View {
        Button { withAnimation(Motion.quick) { toggle() } } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: Look.size(8.5), weight: .bold))
                .foregroundStyle(Ink.quaternary)
                .rotationEffect(.degrees(folded ? 0 : 90))
                .frame(width: 18, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(folded ? "Show calendars" : "Hide calendars"))
    }
}

/// A calendar in the list: a box in its colour, ticked while it's shown, its name, and
/// whatever goes on the right.
private struct CalendarCheckRow<Trailing: View>: View {
    @Environment(\.mailAccent) private var accent
    let title: String
    /// Nil for the app's accent colour.
    let colorIndex: Int?
    let isOn: Bool
    let set: (Bool) -> Void
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Button { set(!isOn) } label: {
                HStack(spacing: 8) {
                    let color = colorIndex.map(Palette.account) ?? accent
                    ZStack {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isOn ? color : .clear)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(color, lineWidth: 1.5)
                        if isOn {
                            Image(systemName: "checkmark").font(.system(size: Look.size(9), weight: .heavy)).foregroundStyle(.white)
                        }
                    }
                    .frame(width: Look.size(15), height: Look.size(15))
                    Text(verbatim: title)
                        .font(TypeScale.label)
                        .foregroundStyle(isOn ? Ink.primary : Ink.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isOn ? .isSelected : [])
            trailing()
        }
        .frame(minHeight: Look.gap(24))
    }
}

/// A reminder in the agenda: a circle to tick it done, its title, when it's due and its list.
struct ReminderRow: View {
    let model: MailModel
    let reminder: DueReminder

    var body: some View {
        HStack(spacing: 12) {
            ReminderCheck(model: model, reminder: reminder)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: reminder.title)
                    .font(.system(size: Look.size(13), weight: .medium))
                    .foregroundStyle(reminder.isDone ? Ink.tertiary : Ink.primary)
                    .strikethrough(reminder.isDone, color: Ink.tertiary)
                Text(verbatim: Self.detail(reminder))
                    .font(TypeScale.caption)
                    .foregroundStyle(Self.isOverdue(reminder) ? Status.danger : Ink.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu { Button("Open in Reminders") { model.openInReminders(reminder) } }
    }

    static func isOverdue(_ reminder: DueReminder) -> Bool {
        !reminder.isDone && (reminder.hasTime ? reminder.due < Date() : reminder.due < Calendar.current.startOfDay(for: Date()))
    }

    /// "17:00 · Work", "Overdue · since 12 Nov · Personal".
    static func detail(_ reminder: DueReminder) -> String {
        var parts: [String] = []
        if isOverdue(reminder) && !Calendar.current.isDateInToday(reminder.due) {
            parts.append(String(localized: "Overdue since \(reminder.due.formatted(.dateTime.day().month(.abbreviated)))"))
        } else {
            parts.append(reminder.hasTime ? reminder.due.formatted(date: .omitted, time: .shortened) : String(localized: "Reminder"))
        }
        if let list = reminder.list { parts.append(list) }
        return parts.joined(separator: " · ")
    }
}

/// The circle that ticks a reminder done, here and in the Reminders app.
struct ReminderCheck: View {
    @Environment(\.mailAccent) private var accent
    let model: MailModel
    let reminder: DueReminder
    var size: CGFloat = 16

    var body: some View {
        Button { withAnimation(Motion.quick) { model.setDone(!reminder.isDone, reminder: reminder) } } label: {
            ZStack {
                Circle().strokeBorder(reminder.isDone ? accent : Ink.quaternary, lineWidth: 1.5)
                if reminder.isDone {
                    Circle().fill(accent).padding(3)
                }
            }
            .frame(width: Look.size(size), height: Look.size(size))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(reminder.isDone ? "Mark as not done" : "Mark as done"))
    }
}

/// What a meeting's right-click menu and the detail card offer, and what clicking it does.
struct EventMenu: View {
    let model: MailModel
    let item: AgendaItem
    @Environment(CalendarEditor.self) private var editor: CalendarEditor?

    var body: some View {
        if model.canChange(item), let editor {
            Button("Edit…") { editor.edit(item) }
            Button("Delete", role: .destructive) { editor.delete(item) }
            Divider()
        }
        if item.invitationThreadID != nil {
            Button("Show Invitation") { model.showInvitation(threadID: item.invitationThreadID ?? "", title: item.title) }
        }
        if let url = item.joinURL {
            Button("Copy Meeting Link") { model.copy(url.absoluteString, announce: "Meeting link copied") }
        }
    }

    /// The invitation's email when Margin has it; otherwise the event itself, to change it.
    static func open(_ item: AgendaItem, in model: MailModel, editor: CalendarEditor? = nil) {
        if let threadID = item.invitationThreadID {
            model.showInvitation(threadID: threadID, title: item.title)
        } else if let editor, model.canChange(item) {
            editor.edit(item)
        }
    }
}

/// Colleagues whose busy times show next to yours in Day and Week: each in a colour, with a way
/// to add more (names or addresses, with suggestions) and to take them off.
private struct ColleagueList: View {
    let model: MailModel
    @State private var field = ""
    /// The add field and its suggestions stay folded away behind + until wanted.
    @State private var isAdding = false
    @FocusState private var focused: Bool

    var body: some View {
        if model.canCompareCalendars || !model.comparedPeople.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("Compare with")
                        .font(.system(size: Look.size(12), weight: .semibold))
                        .foregroundStyle(Ink.secondary)
                    Spacer(minLength: 0)
                    if model.canCompareCalendars {
                        Button {
                            withAnimation(Motion.quick) { isAdding.toggle() }
                            field = ""
                            focused = isAdding
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .semibold))
                                .rotationEffect(.degrees(isAdding ? 45 : 0))
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Ink.tertiary)
                        .help(Text(isAdding ? "Done" : "Compare with a colleague"))
                    }
                }
                .padding(.bottom, 2)
                ForEach(model.comparedPeople) { person in
                    ColleagueRow(model: model, person: person)
                }
                if isAdding {
                    adding
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .task(id: isAdding) { if isAdding { await model.refreshCalendarSharers() } }
        }
    }

    @ViewBuilder private var adding: some View {
        let suggestions = model.colleagueSuggestions(for: field)
        VStack(alignment: .leading, spacing: 4) {
            TextField("Add a colleague", text: $field, prompt: Text("Name or address"))
                .textFieldStyle(.plain)
                .font(TypeScale.label)
                .autocorrectionDisabled()
                .focused($focused)
                .padding(.horizontal, 8)
                .frame(height: Look.gap(26))
                .background(Fill.one, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .onSubmit { add(suggestions.first.map { [$0] } ?? EmailAddress.parseList(field) ?? []) }
            ForEach(suggestions, id: \.address) { person in
                Button { add([person]) } label: {
                    HStack(spacing: 8) {
                        Avatar(person, size: 18)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: person.displayName).font(TypeScale.label).foregroundStyle(Ink.primary)
                            if person.name != nil {
                                Text(verbatim: person.address).font(TypeScale.caption).foregroundStyle(Ink.tertiary)
                            }
                        }
                        .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text(suggestions.isEmpty && field.isEmpty
                 ? "People who share their calendar with you show here. Only busy times are shared, never what."
                 : "Only busy times are shared, never what.")
                .font(TypeScale.caption)
                .foregroundStyle(Ink.quaternary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    private func add(_ people: [EmailAddress]) {
        for person in people { model.addColleague(person) }
        field = ""
    }
}

/// A colleague in the sidebar: their face with a ring in their colour, their name, and whether
/// their calendar can be seen. The remove button shows on hover (always on touch screens), with
/// its room kept so nothing moves.
private struct ColleagueRow: View {
    let model: MailModel
    let person: ComparedPerson
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Avatar(person.address, size: 20)
                .overlay(Circle().strokeBorder(Palette.account(person.colorIndex), lineWidth: 1.5).padding(-2.5))
                .padding(2.5)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: person.address.displayName)
                    .font(TypeScale.label)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                if model.colleaguesHidden.contains(person.id) {
                    Text("Not shared with you")
                        .font(TypeScale.caption)
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                }
                if let away = model.outOfOffice(person) {
                    Label("Out of office", systemImage: "airplane")
                        .font(TypeScale.caption)
                        .foregroundStyle(Status.star)
                        .lineLimit(1)
                        .help(Text(verbatim: String(localized: "Out of office until \(MailModel.untilText(away.end, from: Date()))")))
                }
            }
            Spacer(minLength: 4)
            IconButton("xmark", help: "Stop comparing") { model.removeColleague(person) }
                #if os(macOS)
                .opacity(isHovered ? 1 : 0)
                #endif
        }
        .frame(minHeight: Look.gap(28))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu { Button("Stop comparing") { model.removeColleague(person) } }
    }
}

/// Agenda, Day, Week, Month: a glass capsule with the picked one in dark glass, as Margin's
/// filter chips are, sliding to the new one when it changes.
private struct CalendarModeSwitcher: View {
    let modes: [CalendarMode]
    let mode: CalendarMode
    let choose: (CalendarMode) -> Void
    @Namespace private var picked

    var body: some View {
        HStack(spacing: 2) {
            ForEach(modes) { option in
                let isOn = option == mode
                Button {
                    withAnimation(Motion.quick) { choose(option) }
                } label: {
                    Text(option.title)
                        .font(TypeScale.label.weight(isOn ? .semibold : .medium))
                        .foregroundStyle(isOn ? Color.white : Ink.secondary)
                        .padding(.horizontal, 12)
                        .frame(height: Look.gap(26))
                        .background {
                            if isOn {
                                Capsule().fill(Palette.pickedGlass)
                                    .matchedGeometryEffect(id: "picked", in: picked)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(2)
        .glassCapsule(tint: nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("View"))
    }
}

/// An icon inside a glass capsule group: no fill of its own, the capsule is the surface.
private struct GlassIconButton: View {
    let symbol: String
    let help: LocalizedStringKey
    let action: () -> Void

    init(_ symbol: String, help: LocalizedStringKey, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Look.size(12.5), weight: .medium))
                .foregroundStyle(Ink.primary)
                .frame(width: Look.gap(30), height: Look.gap(30))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tip(help)
        .accessibilityLabel(Text(help))
    }
}
