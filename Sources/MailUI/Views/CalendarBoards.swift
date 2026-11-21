import MailCore
import SwiftUI

// The Calendar's Day, Week and Month: the same meetings as the agenda, laid out on a grid.
// Read-only: clicking a meeting shows it with Going?, Join and where it came from.

/// A meeting placed in a day's column: where it starts and ends that day, and which of the
/// side-by-side lanes it takes when meetings overlap.
struct PlacedMeeting: Identifiable {
    let item: AgendaItem
    let start: Date
    let end: Date
    var lane: Int
    var lanes: Int

    var id: String { item.id }

    /// Lays a day's timed meetings out in lanes: overlapping ones side by side, each group as
    /// wide as it needs.
    static func layout(_ items: [AgendaItem], on day: Date) -> [PlacedMeeting] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let timed = items
            .filter { !$0.isAllDay && $0.end > dayStart && $0.start < dayEnd }
            .map { PlacedMeeting(item: $0, start: max($0.start, dayStart), end: min(max($0.end, $0.start.addingTimeInterval(15 * 60)), dayEnd), lane: 0, lanes: 1) }
            .sorted { ($0.start, $1.end, $0.item.title) < ($1.start, $0.end, $1.item.title) }
        var placed: [PlacedMeeting] = []
        var group: [PlacedMeeting] = []
        var laneEnds: [Date] = []
        var groupEnd = Date.distantPast
        func close() {
            placed += group.map { var meeting = $0; meeting.lanes = laneEnds.count; return meeting }
            group = []
            laneEnds = []
        }
        for var meeting in timed {
            if meeting.start >= groupEnd { close() }
            if let free = laneEnds.firstIndex(where: { $0 <= meeting.start }) {
                meeting.lane = free
                laneEnds[free] = meeting.end
            } else {
                meeting.lane = laneEnds.count
                laneEnds.append(meeting.end)
            }
            groupEnd = max(groupEnd, meeting.end)
            group.append(meeting)
        }
        close()
        return placed
    }
}

/// A day or a week: a column per day with the hours down the side, all-day events and
/// reminders in a strip above, and a line for now.
struct CalendarTimeline: View {
    @Environment(\.mailAccent) private var accent
    @Environment(\.mailAccentInk) private var accentInk
    let model: MailModel
    let visibleDays: [Date]
    /// Clicking a day's heading in a week opens that day.
    let openDay: (Date) -> Void
    /// Scrolling sideways: moves the days in view by this many.
    var scrollDays: (Int) -> Void = { _ in }

    /// Sideways scrolling, kept in its own object so a move redraws only the sliding layers,
    /// not the whole week (which would re-sort every event at each step of the fingers).
    @State private var slider = DaySlider()
    @State private var columnWidth: CGFloat = 100
    /// A swipe in Day with colleagues: one day per swipe, as their columns can't slide.
    @State private var swipe: CGFloat = 0
    @State private var position = ScrollPosition(edge: .top)
    /// Where the hours are scrolled to, and how tall the view is, for zooming in place.
    /// Where the hours are scrolled to, for zooming in place. Not observed: it changes every
    /// frame of scrolling, and the week mustn't be rebuilt for that.
    @State private var scroll = ScrollMetrics()
    /// A pinch in progress: the hour height, scroll and finger position it started from.
    @State private var pinch: (height: Double, scroll: CGFloat, anchor: CGFloat)?

    /// The density's scale on the chosen hour height.
    private var hourHeight: CGFloat { CGFloat(model.calendarHourHeight) * Look.gap(48) / 48 }
    private let gutter: CGFloat = 56
    /// Room kept on the right of the hours.
    private let trailing: CGFloat = 12
    /// Colleagues compared with: in Day, a column each beside yours; in Week, a thin bar each
    /// down the side of every day.
    private var people: [ComparedPerson] { model.comparedPeople }
    private var sideBySide: Bool { visibleDays.count == 1 && !people.isEmpty }
    /// While sliding, as many days again come along on each side, so the fingers only move a
    /// picture: nothing is rebuilt until the days settle.
    private var buffer: Int { max(visibleDays.count, 2) }
    private var days: [Date] {
        guard slider.isSliding, let first = visibleDays.first else { return visibleDays }
        let calendar = Calendar.current
        return (-buffer..<(visibleDays.count + buffer)).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }

    var body: some View {
        let calendar = Calendar.current
        let first = days.first ?? calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: days.count, to: first) ?? first
        let items = model.agenda(from: first, to: end)
        GeometryReader { geometry in
            let width = geometry.size.width
            let column = (width - gutter - trailing) / CGFloat(max(visibleDays.count, 1))
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(spacing: 0) {
                    if visibleDays.count > 1 { rolling(width: width, column: column) { headings(now: context.date) } gutter: { Paper.panel } }
                    if sideBySide { personHeadings(now: context.date) }
                    // One row is always kept; a day with more opens it downward over the hours,
                    // as Apple's Calendar does, so the hours never move.
                    Color.clear
                        .frame(height: Look.gap(22) + 6)
                        .overlay(alignment: .top) {
                            rolling(width: width, column: column) { allDayStrip(items) } gutter: { Paper.panel }
                                .background(Paper.panel)
                                .overlay(alignment: .bottom) { Rectangle().fill(Line.hairline).frame(height: 1) }
                        }
                        .zIndex(1)
                    hours(items, now: context.date, width: width, column: column)
                }
            }
            .onAppear { columnWidth = column }
            .onChange(of: column) { _, new in columnWidth = new }
        }
        #if os(macOS)
        .background(DayScroller(start: { slider.travel = 0 }, move: slideBy, end: { settle(velocity: $0) }, step: { scrollDays($0) }))
        #endif
    }

    /// While sliding, the content is a day wider on each side and moves under a fixed gutter.
    @ViewBuilder
    private func rolling<Content: View, Gutter: View>(width: CGFloat, column: CGFloat, @ViewBuilder _ content: () -> Content,
                                                      @ViewBuilder gutter: () -> Gutter) -> some View {
        if slider.isSliding {
            RollingContent(slider: slider, width: width, column: column, buffer: buffer, gutterWidth: self.gutter, content: content(), gutter: gutter())
        } else {
            content()
        }
    }

    // MARK: Sliding sideways

    /// Moves the days with the fingers; each whole column moved is a day.
    private func slideBy(_ dx: CGFloat) {
        guard !sideBySide else {
            swipe += dx
            return
        }
        // A swipe during the snap takes over from where the days are now.
        slider.stopSpring()
        if !slider.isSliding { slider.isSliding = true }
        // One swipe moves at most the days in view (a week, or a day): it grows heavier towards
        // that, rather than hitting a wall.
        let cap = CGFloat(visibleDays.count) * columnWidth
        let dx = CalendarScroll.resisted(dx, travel: slider.travel, cap: cap)
        slider.travel += dx
        slider.noteMove(dx)
        var next = slider.offset + dx
        // Only past the extra days drawn on each side do the days in view change mid-swipe.
        let reach = CGFloat(buffer - 1) * columnWidth
        while next <= -reach { scrollDays(1); next += columnWidth }
        while next >= reach { scrollDays(-1); next -= columnWidth }
        slider.offset = next
    }

    /// Lets go: the days lock onto whole columns, to the nearer day.
    private func settle(velocity: CGFloat = 0) {
        guard !sideBySide else {
            if abs(swipe) > 60 { withAnimation(Motion.quick) { scrollDays(swipe < 0 ? 1 : -1) } }
            swipe = 0
            return
        }
        // Where this swipe ends, all told, and the part of it not already moved mid-swipe.
        let alreadyMoved = Int(((slider.offset - slider.travel) / columnWidth).rounded())
        // The first day shown when this swipe began, to find the real weeks around it.
        let began = visibleDays.first.flatMap { Calendar.current.date(byAdding: .day, value: -alreadyMoved, to: $0) }
        let total = CalendarScroll.swipeDays(travel: slider.travel, speed: slider.speed, column: columnWidth, days: visibleDays.count,
                                             daysToWeekStart: visibleDays.count == 7 ? began.map { CalendarScroll.daysToWeekStart(from: $0) } : nil)
        let days = total - alreadyMoved
        if days != 0 { scrollDays(days) }
        slider.offset += CGFloat(days) * columnWidth
        // A soft spring, run frame by frame from the speed the days were really moving, so
        // there's no catch at the hand-over, no bounce, and a new swipe can take it over.
        slider.springHome()
    }

    // MARK: Zooming

    /// Pinch: hours grow or shrink around the fingers, so what you're looking at stays put.
    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinch == nil { pinch = (model.calendarHourHeight, scroll.y, value.startLocation.y - scroll.y) }
                guard let pinch else { return }
                let height = CalendarScroll.zoomed(pinch.height, by: value.magnification, smallest: model.smallestHourHeight)
                model.calendarHourHeight = height
                position.scrollTo(y: CalendarScroll.anchoredScroll(scroll: pinch.scroll, anchor: pinch.anchor, ratio: height / pinch.height))
            }
            .onEnded { _ in pinch = nil }
    }

    // MARK: Headings and the all-day strip

    private func headings(now: Date) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter, height: 1)
            ForEach(days, id: \.self) { day in
                let isToday = Calendar.current.isDateInToday(day)
                Button { openDay(day) } label: {
                    HStack(spacing: 5) {
                        Text(verbatim: day.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.system(size: Look.size(12), weight: .medium))
                            .foregroundStyle(isToday ? accent : Ink.tertiary)
                        Text(verbatim: "\(Calendar.current.component(.day, from: day))")
                            .font(.system(size: Look.size(13), weight: .semibold).monospacedDigit())
                            .foregroundStyle(isToday ? accentInk : Ink.primary)
                            .frame(minWidth: 24, minHeight: 24)
                            .background { if isToday { Circle().fill(accent) } }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tip("Show this day")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 6)
        // The same room on the right as the hours, so each date sits exactly over its column,
        // also while the days slide.
        .padding(.trailing, trailing)
    }

    /// In Day with colleagues: You, then each of them, with their face and where they are now.
    private func personHeadings(now: Date) -> some View {
        let isToday = days.first.map(Calendar.current.isDateInToday) ?? false
        return HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: gutter, height: 1)
            PersonHeading(title: String(localized: "You"), address: nil, colorIndex: nil, detail: nil)
            ForEach(people) { person in
                PersonHeading(title: person.address.displayName, address: person.address, colorIndex: person.colorIndex,
                              detail: model.colleaguesHidden.contains(person.id) ? String(localized: "Not shared")
                                  : isToday ? model.availability(of: person, now: now) : nil)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    /// How many all-day rows the days in view need (not the ones sliding in), from one to four.
    private func allDayRows(_ items: [AgendaItem]) -> Int {
        let busiest = visibleDays.map { day in items.filter { $0.isAllDay && Self.covers($0, day) }.count + model.reminders(on: day).count }.max() ?? 0
        return max(min(busiest, 4), 1)
    }

    private func allDayStrip(_ items: [AgendaItem]) -> some View {
        let allDay = days.map { day in (day, items.filter { $0.isAllDay && Self.covers($0, day) }, model.reminders(on: day)) }
        let rows = allDayRows(items)
        return HStack(alignment: .top, spacing: 0) {
            Text("All day")
                .font(.system(size: Look.size(10), weight: .medium))
                .foregroundStyle(Ink.quaternary)
                .frame(width: gutter - 8, alignment: .trailing)
                .padding(.trailing, 8)
                .padding(.top, 3)
            ForEach(allDay, id: \.0) { _, events, reminders in
                VStack(alignment: .leading, spacing: 3) {
                    let total = events.count + reminders.count
                    let room = total > 4 ? 3 : 4
                    ForEach(events.prefix(room)) { item in AllDayChip(model: model, item: item) }
                    ForEach(reminders.prefix(max(0, room - events.count))) { reminder in
                        ReminderChip(model: model, reminder: reminder)
                    }
                    if total > room {
                        Text("\(total - room) more").font(TypeScale.caption).foregroundStyle(Ink.tertiary).padding(.leading, 4)
                    }
                }
                .padding(.horizontal, 2)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            if sideBySide, let day = days.first {
                ForEach(people) { person in
                    // Away the whole day: said once at the top, where it's always in view.
                    if model.busyTimes(of: person, on: day).contains(where: { $0.kind == .outOfOffice && $0.end.timeIntervalSince($0.start) >= 86_399 }) {
                        Label("Out of office", systemImage: "airplane")
                            .font(.system(size: Look.size(11.5), weight: .semibold))
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .frame(maxWidth: .infinity, minHeight: Look.gap(19), alignment: .leading)
                            .background(Palette.account(person.colorIndex).opacity(0.17), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .padding(.horizontal, 2)
                            .frame(maxWidth: .infinity, alignment: .top)
                    } else {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                }
            }
        }
        .padding(.trailing, trailing)
        .frame(height: CGFloat(rows) * Look.gap(22) + 6, alignment: .top)
        .padding(.top, days.count > 1 ? 0 : 4)
    }

    static func covers(_ item: AgendaItem, _ day: Date) -> Bool {
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
        return item.start < end && item.end > start
    }

    // MARK: The hours

    private func hours(_ items: [AgendaItem], now: Date, width: CGFloat, column: CGFloat) -> some View {
            ScrollView {
                rolling(width: width, column: column) {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ForEach(0..<24, id: \.self) { hour in
                            HStack(alignment: .top, spacing: 0) {
                                Text(verbatim: hour == 0 ? "" : Self.hourLabel(hour))
                                    .font(.system(size: Look.size(10), weight: .medium).monospacedDigit())
                                    .foregroundStyle(Ink.quaternary)
                                    .frame(width: gutter - 8, alignment: .trailing)
                                    .padding(.trailing, 8)
                                    .offset(y: -6)
                                    // The now pill sits in the same place; an hour it would cover steps aside.
                                    .opacity(Self.covers(now: now, hour: hour, in: days) ? 0 : 1)
                                Rectangle().fill(Line.hairline).frame(height: 1)
                            }
                            .frame(height: hourHeight, alignment: .top)
                            .id(hour)
                        }
                    }
                    HStack(spacing: 0) {
                        Color.clear.frame(width: gutter)
                        ForEach(days, id: \.self) { day in
                            self.column(PlacedMeeting.layout(items, on: day), day: day, now: now)
                                .overlay(alignment: .leading) { Rectangle().fill(Line.hairline).frame(width: 1) }
                                .overlay(alignment: .trailing) { if days.count > 1 { busyBars(on: day) } }
                        }
                        if sideBySide, let day = days.first {
                            ForEach(people) { person in
                                ColleagueColumn(model: model, person: person, day: day, hourHeight: hourHeight)
                                    .overlay(alignment: .leading) { Rectangle().fill(Line.hairline).frame(width: 1) }
                            }
                        }
                    }
                    // Now: a faint line across every day, the time in a pill by the hours; today's
                    // own column has the strong line and its dot.
                    if days.contains(where: { Calendar.current.isDateInToday($0) }) {
                        let y = offset(of: now, on: Calendar.current.startOfDay(for: now))
                        Rectangle().fill(accent.opacity(0.4)).frame(height: 1)
                            .padding(.leading, gutter)
                            .offset(y: y)
                            .allowsHitTesting(false)
                        Text(verbatim: now.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: Look.size(10), weight: .semibold).monospacedDigit())
                            .foregroundStyle(accentInk)
                            .padding(.horizontal, 5)
                            .frame(height: 16)
                            .background(accent, in: Capsule())
                            .frame(width: gutter - 3, alignment: .trailing)
                            .offset(y: y - 8)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    if sideBySide, let day = days.first {
                        ForEach(model.freeTogether(on: day, now: now), id: \.start) { slot in
                            FreeTogetherBand(slot: slot, day: day, hourHeight: hourHeight, people: people.filter { !model.colleaguesHidden.contains($0.id) })
                                .padding(.leading, gutter)
                        }
                    }
                }
                .frame(height: hourHeight * 24)
                .padding(.trailing, trailing)
                } gutter: {
                    hourLabels.frame(maxHeight: .infinity, alignment: .top).background(Paper.panel)
                }
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGRect.self) { CGRect(origin: $0.contentOffset, size: $0.containerSize) } action: { _, frame in
                scroll.y = frame.origin.y
                scroll.height = frame.height
                // The day always fills the view: a taller window can't leave a gap below.
                let smallest = max(Double(frame.height / 24 * 48 / Look.gap(48)).rounded(.up), 20)
                if model.smallestHourHeight != smallest { model.smallestHourHeight = smallest }
                if model.calendarHourHeight < smallest { model.calendarHourHeight = smallest }
            }
            .simultaneousGesture(pinchGesture)
            .onAppear {
                let start = Calendar.current.component(.hour, from: now)
                let showsToday = visibleDays.contains { Calendar.current.isDateInToday($0) }
                let hour = Self.snapshotHour ?? (showsToday ? max(0, min(start - 1, 15)) : 8)
                position.scrollTo(y: CGFloat(hour) * hourHeight)
            }
            .onChange(of: model.calendarHourHeight) { old, new in
                // ⌘+ and ⌘−: keep the middle of the view where it was.
                guard pinch == nil, old > 0 else { return }
                position.scrollTo(y: CalendarScroll.anchoredScroll(scroll: scroll.y, anchor: scroll.height / 2, ratio: new / old))
            }
    }

    /// The hours down the left, drawn over the grid while it slides.
    private var hourLabels: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(verbatim: hour == 0 ? "" : Self.hourLabel(hour))
                    .font(.system(size: Look.size(10), weight: .medium).monospacedDigit())
                    .foregroundStyle(Ink.quaternary)
                    .frame(width: gutter - 8, alignment: .trailing)
                    .offset(y: -6)
                    .frame(width: gutter, height: hourHeight, alignment: .topLeading)
            }
        }
    }

    /// In Week: a thin bar per colleague down the right of the day, where they're busy.
    private func busyBars(on day: Date) -> some View {
        HStack(spacing: 2) {
            ForEach(people) { person in
                ZStack(alignment: .top) {
                    ForEach(Array(model.busyTimes(of: person, on: day).enumerated()), id: \.offset) { _, busy in
                        let top = offset(of: busy.start, on: day)
                        Capsule()
                            .fill(Palette.account(person.colorIndex).opacity(busy.kind == .outOfOffice ? 0.3 : busy.kind == .workingElsewhere ? 0.15 : 0.7))
                            .frame(width: 3, height: max(offset(of: busy.end, on: day) - top, 4))
                            .offset(y: top)
                            .help(Text("\(person.address.displayName) is busy \(busy.start.formatted(date: .omitted, time: .shortened)) – \(busy.end.formatted(date: .omitted, time: .shortened))"))
                    }
                }
                .frame(width: 3, alignment: .top)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(.trailing, 2)
    }

    private func column(_ meetings: [PlacedMeeting], day: Date, now: Date) -> some View {
        GeometryReader { proxy in
            // Room on the right for colleagues' busy bars in a week.
            let width = proxy.size.width - 4 - (days.count > 1 ? CGFloat(people.count) * 5 : 0)
            ZStack(alignment: .topLeading) {
                // Weekends, and a weekday outside working hours, on quieter paper, so the
                // shape of the week shows at a glance.
                if Calendar.current.isDateInWeekend(day) {
                    Paper.band.frame(width: proxy.size.width, height: hourHeight * 24).allowsHitTesting(false)
                } else {
                    VStack(spacing: 0) {
                        Paper.band.frame(height: hourHeight * CGFloat(Self.workday.lowerBound))
                        Color.clear.frame(height: hourHeight * CGFloat(Self.workday.count))
                        Paper.band.frame(height: hourHeight * CGFloat(24 - Self.workday.upperBound))
                    }
                    .frame(width: proxy.size.width)
                    .allowsHitTesting(false)
                }
                // Empty time: drag down it to make an event that long, or double-click for an hour.
                NewEventSurface(day: day, hourHeight: hourHeight, width: proxy.size.width)
                ForEach(meetings) { meeting in
                    let top = offset(of: meeting.start, on: day)
                    let height = max(offset(of: meeting.end, on: day) - top, 18)
                    let laneWidth = width / CGFloat(meeting.lanes)
                    MeetingBlock(model: model, item: meeting.item, height: height, hourHeight: hourHeight,
                                 dayWidth: proxy.size.width, dayRange: dayRange(of: day))
                        .frame(width: max(laneWidth - 2, 8), height: height - 2)
                        .offset(x: 2 + laneWidth * CGFloat(meeting.lane), y: top + 1)
                }
                if Calendar.current.isDate(now, inSameDayAs: day) {
                    HStack(spacing: 0) {
                        Circle().fill(accent).frame(width: 7, height: 7)
                        Rectangle().fill(accent).frame(height: 1.5)
                    }
                    .offset(x: -3.5, y: offset(of: now, on: day) - 3.5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
        }
    }

    /// How many columns a meeting in this day can be dragged to the left and right.
    private func dayRange(of day: Date) -> ClosedRange<Int> {
        let index = days.firstIndex { Calendar.current.isDate($0, inSameDayAs: day) } ?? 0
        return -index...(days.count - 1 - index)
    }

    private func offset(of date: Date, on day: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(Calendar.current.startOfDay(for: day)) / 3600) * hourHeight
    }

    /// "09:00" or "9 AM", as the region writes hours.
    static func hourLabel(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    /// Whether the now pill covers an hour's label: today is in view and it's within 20 minutes.
    static func covers(now: Date, hour: Int, in days: [Date]) -> Bool {
        guard days.contains(where: { Calendar.current.isDate($0, inSameDayAs: now) }) else { return false }
        let minutes = now.timeIntervalSince(Calendar.current.startOfDay(for: now)) / 60
        return abs(minutes - Double(hour * 60)) < 20
    }

    /// For pictures of the app (`-snapshot-hour 8`): the hour Day and Week open at, whatever
    /// the time, so they can be taken at night.
    static let snapshotHour: Int? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-snapshot-hour"), index + 1 < arguments.count else { return nil }
        return Int(arguments[index + 1])
    }()

    /// Working hours, the same ones suggested times keep to; the rest of a weekday is quieter.
    static let workday = 9..<17
}

/// A meeting on the grid: tinted in the accent colour with a line down its side. Ones still
/// waiting for your answer are outlined; declined ones are faded. Clicking shows its details.
private struct MeetingBlock: View {
    let model: MailModel
    let item: AgendaItem
    let height: CGFloat
    let hourHeight: CGFloat
    let dayWidth: CGFloat
    /// The other day columns it can be dragged to.
    let dayRange: ClosedRange<Int>
    @Environment(CalendarEditor.self) private var editor: CalendarEditor?
    @State private var showsDetail = false
    /// While dragging: how far it has moved (snapped), and how much longer it has been made.
    @State private var move: (days: Int, minutes: Int) = (0, 0)
    @State private var stretch = 0

    private var waiting: Bool { item.canAnswer && item.response == nil }
    private var tint: Color { Palette.account(item.colorIndex) }
    private var canChange: Bool { model.canChange(item) && editor != nil }
    private var minuteHeight: CGFloat { hourHeight / 60 }
    private var isDragging: Bool { move != (0, 0) || stretch != 0 }

    var body: some View {
        block
            .offset(x: CGFloat(move.days) * dayWidth, y: CGFloat(move.minutes) * minuteHeight)
            .frame(height: max(height - 2 + CGFloat(stretch) * minuteHeight, 14), alignment: .top)
            .frame(maxHeight: .infinity, alignment: .top)
            .shadow(color: .black.opacity(isDragging ? 0.18 : 0), radius: 8, y: 3)
            .zIndex(isDragging ? 1 : 0)
            .contentShape(Rectangle())
            .onTapGesture { showsDetail = true }
            .gesture(canChange ? calendarDrag(changed: moveChanged, ended: moveEnded) : nil)
            .contextMenu { EventMenu(model: model, item: item) }
            .popover(isPresented: $showsDetail, arrowEdge: .trailing) {
                EventDetail(model: model, item: item)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: "\(item.title), \(item.start.formatted(date: .omitted, time: .shortened))"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { showsDetail = true }
    }

    private var block: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(tint).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.title)
                    .font(.system(size: Look.size(12), weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(height > 44 ? 2 : 1)
                if height > 34 || isDragging {
                    Text(verbatim: timeText)
                        .font(.system(size: Look.size(11)).monospacedDigit())
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, height > 26 ? 4 : 1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(tint.opacity(waiting ? 0.06 : 0.17))
        .background(Paper.panel)
        .overlay { if waiting { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(tint.opacity(0.6), lineWidth: 1) } }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .opacity(item.response == .declined ? 0.45 : 1)
        .overlay(alignment: .bottom) {
            // The bottom edge makes it longer or shorter.
            if canChange && height > 22 {
                Color.clear
                    .frame(height: 7)
                    .contentShape(Rectangle())
                    #if os(macOS)
                    .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                    #endif
                    .gesture(stretchGesture)
            }
        }
    }

    /// The time while it's being dragged: where it will land.
    private var timeText: String {
        let start = item.start.addingTimeInterval(Double(move.minutes * 60))
        let end = item.end.addingTimeInterval(Double((move.minutes + stretch) * 60))
        guard isDragging else {
            return start.formatted(date: .omitted, time: .shortened) + (item.location.map { " · " + $0 } ?? "")
        }
        return start.formatted(date: .omitted, time: .shortened) + " – " + end.formatted(date: .omitted, time: .shortened)
    }

    private func moveChanged(_ value: DragGesture.Value) {
        let minutes = Int((value.translation.height / minuteHeight / 15).rounded()) * 15
        let days = min(max(Int((value.translation.width / max(dayWidth, 1)).rounded()), dayRange.lowerBound), dayRange.upperBound)
        if move != (days, minutes) { move = (days, minutes) }
    }

    private func moveEnded() {
                let (days, minutes) = move
                move = (0, 0)
                guard days != 0 || minutes != 0, let editor else { return }
                let shifted = Calendar.current.date(byAdding: .day, value: days, to: item.start) ?? item.start
                let start = shifted.addingTimeInterval(Double(minutes * 60))
                var draft = model.draft(of: item)
                draft.start = start
                draft.end = start.addingTimeInterval(item.end.timeIntervalSince(item.start))
                editor.change(item, to: draft)
    }

    private var stretchGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let minutes = Int((value.translation.height / minuteHeight / 15).rounded()) * 15
                let shortest = 15 - Int(item.end.timeIntervalSince(item.start) / 60)
                stretch = max(minutes, shortest)
            }
            .onEnded { _ in
                let minutes = stretch
                stretch = 0
                guard minutes != 0, let editor else { return }
                var draft = model.draft(of: item)
                draft.end = item.end.addingTimeInterval(Double(minutes * 60))
                editor.change(item, to: draft)
            }
    }
}

/// The empty part of a day's column: drag to make an event as long as the drag, or
/// double-click for an hour from there. Snaps to the quarter hour.
private struct NewEventSurface: View {
    @Environment(\.mailAccent) private var accent
    @Environment(\.mailAccentInk) private var accentInk
    let day: Date
    let hourHeight: CGFloat
    let width: CGFloat
    @Environment(CalendarEditor.self) private var editor: CalendarEditor?
    @State private var span: (from: CGFloat, to: CGFloat)?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .overlay(alignment: .topLeading) {
                if let span {
                    let top = min(span.from, span.to), bottom = max(span.from, span.to)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(accent.opacity(0.18))
                        .overlay(alignment: .topLeading) {
                            Text(verbatim: time(at: top).formatted(date: .omitted, time: .shortened) + " – "
                                 + time(at: max(bottom, top + hourHeight / 4)).formatted(date: .omitted, time: .shortened))
                                .font(.system(size: Look.size(11), weight: .semibold).monospacedDigit())
                                .foregroundStyle(accent)
                                .padding(5)
                        }
                        .frame(width: width - 6, height: max(bottom - top, hourHeight / 4))
                        .offset(x: 3, y: top)
                        .allowsHitTesting(false)
                }
            }
            .onTapGesture(count: 2, coordinateSpace: .local) { point in
                guard let editor, editor.canAdd else { return }
                let start = time(at: point.y - hourHeight / 2)
                editor.newEvent(start: start, end: start.addingTimeInterval(3600))
            }
            .gesture(editor?.canAdd == true ? calendarDrag(changed: { value in
                span = (snap(value.startLocation.y), snap(value.location.y))
            }, ended: {
                guard let span, let editor else { return }
                self.span = nil
                let top = min(span.from, span.to), bottom = max(span.from, span.to)
                editor.newEvent(start: time(at: top), end: time(at: max(bottom, top + hourHeight / 4)))
            }) : nil)
    }

    private func snap(_ y: CGFloat) -> CGFloat {
        let quarter = hourHeight / 4
        return max(0, min((y / quarter).rounded() * quarter, hourHeight * 24))
    }

    private func time(at y: CGFloat) -> Date {
        let minutes = Int((snap(y) / hourHeight * 60).rounded())
        return Calendar.current.startOfDay(for: day).addingTimeInterval(Double(minutes * 60))
    }
}

/// An all-day event in the strip above the hours.
private struct AllDayChip: View {
    let model: MailModel
    let item: AgendaItem
    @State private var showsDetail = false

    var body: some View {
        Button { showsDetail = true } label: {
            Text(verbatim: item.title)
                .font(.system(size: Look.size(11.5), weight: .semibold))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: Look.gap(19), alignment: .leading)
                .background(Palette.account(item.colorIndex).opacity(0.17), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { EventMenu(model: model, item: item) }
        .popover(isPresented: $showsDetail) { EventDetail(model: model, item: item) }
    }
}

/// A reminder in the strip: its circle and title.
private struct ReminderChip: View {
    let model: MailModel
    let reminder: DueReminder

    var body: some View {
        HStack(spacing: 5) {
            ReminderCheck(model: model, reminder: reminder, size: 12)
            Text(verbatim: reminder.title)
                .font(.system(size: Look.size(11.5), weight: .medium))
                .foregroundStyle(reminder.isDone ? Ink.tertiary : Ink.primary)
                .strikethrough(reminder.isDone, color: Ink.tertiary)
                .lineLimit(1)
            if reminder.hasTime {
                Text(verbatim: reminder.due.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: Look.size(10.5)).monospacedDigit())
                    .foregroundStyle(ReminderRow.isOverdue(reminder) ? Status.danger : Ink.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, minHeight: Look.gap(19), alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu { Button("Open in Reminders") { model.openInReminders(reminder) } }
    }
}

/// A meeting's details, shown when it's clicked on the grid: when and where, who invited you
/// and who's going, Going?, Join, and where to see or change it.
struct EventDetail: View {
    let model: MailModel
    let item: AgendaItem
    @Environment(CalendarEditor.self) private var editor: CalendarEditor?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: item.title)
                    .font(.system(size: Look.size(15), weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: when)
                    .font(TypeScale.label)
                    .foregroundStyle(Ink.secondary)
                ForEach(details, id: \.self) { line in
                    Text(verbatim: line).font(TypeScale.label).foregroundStyle(Ink.tertiary).lineLimit(2)
                }
            }
            let guests = item.attendees.filter { $0.kind != .room }
            if !guests.isEmpty {
                Text("\(guests.count) invited · \(guests.filter { $0.response == .accepted }.count) going")
                    .font(TypeScale.caption)
                    .foregroundStyle(Ink.tertiary)
            }
            if item.canAnswer {
                GoingPicker(response: item.response, isSending: model.isAnswering(item)) { model.respond(to: item, with: $0) }
            }
            HStack(spacing: 8) {
                if let url = item.joinURL {
                    Link(destination: url) { Text("Join") }
                        .buttonStyle(JoinButtonStyle(prominent: item.start.timeIntervalSinceNow < 15 * 60 && item.end > Date()))
                }
                if model.canChange(item), let editor {
                    Button("Edit…") { editor.edit(item) }.buttonStyle(PillButtonStyle())
                }
                if item.invitationThreadID != nil {
                    Button("Show Invitation") { EventMenu.open(item, in: model) }.buttonStyle(PillButtonStyle())
                }
            }
        }
        .padding(Space.l)
        .frame(width: 300, alignment: .leading)
        // Backspace (or Delete) deletes the event that's open, as in the grid's own selection.
        .background {
            if model.canChange(item), let editor {
                Button("Delete") {
                    dismiss()
                    editor.delete(item)
                }
                .keyboardShortcut(.delete, modifiers: [])
                .hidden()
            }
        }
    }

    private var when: String {
        let day = item.start.formatted(.dateTime.weekday(.wide).day().month(.wide))
        if item.isAllDay { return day + " · " + String(localized: "All day") }
        return day + " · " + item.start.formatted(date: .omitted, time: .shortened) + " – " + item.end.formatted(date: .omitted, time: .shortened)
    }

    private var details: [String] {
        var lines: [String] = []
        if let location = item.location, !location.isEmpty {
            lines.append(location)
        } else if let url = item.joinURL, let service = AgendaRow.service(url) {
            lines.append(service)
        }
        if let organizer = item.organizer, !item.isMine { lines.append(String(localized: "Invited by \(organizer)")) }
        if let calendar = item.calendarName { lines.append(calendar) }
        if item.repeats { lines.append(String(localized: "Repeats")) }
        return lines
    }
}

/// Month: one continuous sheet of weeks, as Apple's Calendar has it. Scrolling moves week by
/// week and settles on a whole row, a month at most per swipe; the month in the middle of the
/// view is the month shown (its days in full ink, the others faded), and its name is the page's
/// title. The first of each month says which month it is.
struct MonthBoard: View {
    let model: MailModel
    @Binding var month: Date
    let openDay: (Date) -> Void

    private var calendar: Calendar { Calendar.current }

    private var weekdaySymbols: [String] {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let start = calendar.firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }

    var body: some View {
        // Everything on in the months around the one shown (what's been read), worked out once
        // and shared out by day; scrolling itself never redoes it.
        let byDay = Self.byDay(model.agenda(from: calendar.date(byAdding: .month, value: -2, to: month) ?? month,
                                            to: calendar.date(byAdding: .month, value: 3, to: month) ?? month))
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(verbatim: symbol)
                        .font(.system(size: Look.size(11), weight: .medium))
                        .foregroundStyle(Ink.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 8)
                }
            }
            .padding(.bottom, 6)
            .overlay(alignment: .bottom) { Rectangle().fill(Line.hairline).frame(height: 1) }
            MonthSheet(model: model, month: $month, byDay: byDay, openDay: openDay)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    /// Items by the days they're on (an all-day or long event on each of its days).
    static func byDay(_ items: [AgendaItem]) -> [Date: [AgendaItem]] {
        let calendar = Calendar.current
        var result: [Date: [AgendaItem]] = [:]
        for item in items {
            var day = calendar.startOfDay(for: item.start)
            let last = item.end > item.start ? item.end.addingTimeInterval(-1) : item.start
            var count = 0
            while day <= last && count < 62 {
                result[day, default: []].append(item)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
                count += 1
            }
        }
        return result
    }
}

/// The scrolling weeks. Only this redraws while scrolling; the month changes (and the page with
/// it) once a new month reaches the middle.
private struct MonthSheet: View {
    let model: MailModel
    @Binding var month: Date
    let byDay: [Date: [AgendaItem]]
    let openDay: (Date) -> Void
    /// The first week in view, kept so the buttons and the scroll agree.
    @State private var topWeek: Date?
    /// The month the list of weeks is built around; it moves only on a jump (‹ › or Today),
    /// so scrolling never rebuilds the list.
    @State private var anchor: Date?
    /// Set while the sheet itself moved the month, so it doesn't scroll to it again.
    @State private var settingFromScroll = false
    @State private var scroll = ScrollMetrics()

    private var calendar: Calendar { Calendar.current }

    /// Two years of weeks around the anchor.
    private var weeks: [Date] {
        let start = MonthGrid.firstShown(in: anchor ?? month)
        return (-60...60).compactMap { calendar.date(byAdding: .weekOfYear, value: $0, to: start) }
    }

    var body: some View {
        GeometryReader { proxy in
            // Five weeks to a view, like a month at a glance.
            let rowHeight = max(proxy.size.height / 5, 60)
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(weeks, id: \.self) { week in
                        MonthWeekRow(model: model, week: week, month: month, byDay: byDay, rowHeight: rowHeight, openDay: openDay)
                            .frame(height: rowHeight)
                            .id(week)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.never)
            .scrollTargetBehavior(WeekRows(row: rowHeight, maxRows: 5, scroll: scroll))
            .scrollPosition(id: $topWeek, anchor: .top)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in scroll.y = y }
            .onAppear {
                anchor = anchor ?? month
                topWeek = MonthGrid.firstShown(in: month)
            }
            .onChange(of: topWeek) { _, week in
                // The month is the one in the middle of the view: the week two rows down.
                guard let week, let middle = calendar.date(byAdding: .day, value: 2 * 7 + 3, to: week),
                      let shown = calendar.dateInterval(of: .month, for: middle)?.start, shown != month else { return }
                settingFromScroll = true
                month = shown
            }
            .onChange(of: month) { _, newMonth in
                if settingFromScroll { settingFromScroll = false; return }
                // A jump beyond the weeks built: build them around it.
                if let first = weeks.first, let last = weeks.last, !(first...last).contains(MonthGrid.firstShown(in: newMonth)) {
                    anchor = newMonth
                }
                withAnimation(Motion.quick) { topWeek = MonthGrid.firstShown(in: newMonth) }
            }
        }
    }
}

/// Where a swipe through the month sheet lands: wherever the trackpad's own deceleration takes
/// it (nothing snaps), but no more than `maxRows` weeks away, however hard it's flicked.
private struct WeekRows: ScrollTargetBehavior {
    let row: CGFloat
    let maxRows: Int
    let scroll: ScrollMetrics

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        guard row > 0 else { return }
        let from = scroll.y
        let reach = row * CGFloat(maxRows)
        target.rect.origin.y = max(min(max(target.rect.minY, from - reach), from + reach), 0)
    }
}

/// One week of the month sheet.
private struct MonthWeekRow: View {
    let model: MailModel
    let week: Date
    let month: Date
    let byDay: [Date: [AgendaItem]]
    let rowHeight: CGFloat
    let openDay: (Date) -> Void

    var body: some View {
        let calendar = Calendar.current
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { weekday in
                let day = calendar.date(byAdding: .day, value: weekday, to: week) ?? week
                MonthDayBox(model: model, day: day,
                            inMonth: calendar.isDate(day, equalTo: month, toGranularity: .month),
                            items: byDay[calendar.startOfDay(for: day)] ?? [],
                            height: rowHeight) { openDay(day) }
            }
        }
    }
}

private struct MonthDayBox: View {
    @Environment(\.mailAccent) private var accent
    @Environment(\.mailAccentInk) private var accentInk
    @Environment(CalendarEditor.self) private var editor: CalendarEditor?
    let model: MailModel
    let day: Date
    let inMonth: Bool
    let items: [AgendaItem]
    let height: CGFloat
    let open: () -> Void
    @State private var isHovered = false

    var body: some View {
        let isToday = Calendar.current.isDateInToday(day)
        let reminders = model.reminders(on: day).filter { !$0.isDone }
        let lineHeight = Look.gap(17)
        let room = max(0, Int((height - 34) / lineHeight))
        let total = items.count + reminders.count
        let shown = total > room ? max(0, room - 1) : room
        Button(action: open) {
            VStack(alignment: .leading, spacing: 1) {
                // The first of a month says which month, so the sheet reads as it scrolls.
                let first = Calendar.current.component(.day, from: day) == 1
                Text(verbatim: first && !isToday ? day.formatted(.dateTime.day().month(.abbreviated))
                                                 : "\(Calendar.current.component(.day, from: day))")
                    .font(.system(size: Look.size(12), weight: isToday || first ? .bold : .medium).monospacedDigit())
                    .foregroundStyle(isToday ? accentInk : inMonth ? Ink.primary : Ink.quaternary)
                    .padding(.horizontal, first && !isToday ? 4 : 0)
                    .frame(minWidth: 22, minHeight: 22)
                    .background { if isToday { Circle().fill(accent) } }
                    .padding(.bottom, 2)
                ForEach(items.prefix(shown)) { item in
                    line(item)
                }
                ForEach(reminders.prefix(max(0, shown - items.count))) { reminder in
                    HStack(spacing: 4) {
                        Circle().strokeBorder(Ink.quaternary, lineWidth: 1.2).frame(width: 8, height: 8)
                        Text(verbatim: reminder.title).lineLimit(1)
                    }
                    .font(.system(size: Look.size(11)))
                    .foregroundStyle(Ink.secondary)
                    .frame(height: lineHeight)
                }
                if total > shown {
                    Text("\(total - shown) more")
                        .font(.system(size: Look.size(11), weight: .medium))
                        .foregroundStyle(Ink.tertiary)
                        .frame(height: lineHeight)
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(isHovered ? Fill.one : .clear)
            .opacity(inMonth ? 1 : 0.55)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            if let editor, editor.canAdd {
                Button("New Event") { editor.newEvent(start: CalendarPage.newEventStart(on: day)) }
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Line.hairline).frame(height: 1) }
        .overlay(alignment: .trailing) { Rectangle().fill(Line.hairline).frame(width: 1) }
        .accessibilityLabel(Text(verbatim: day.formatted(date: .complete, time: .omitted)))
        .accessibilityHint(Text("\(total) on this day"))
    }

    @ViewBuilder
    private func line(_ item: AgendaItem) -> some View {
        if item.isAllDay {
            Text(verbatim: item.title)
                .font(.system(size: Look.size(11), weight: .semibold))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, minHeight: lineHeight - 2, alignment: .leading)
                .background(Palette.account(item.colorIndex).opacity(0.17), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .frame(height: lineHeight)
        } else {
            HStack(spacing: 4) {
                Circle().fill(Palette.account(item.colorIndex).opacity(item.response == .declined ? 0.35 : 1)).frame(width: 6, height: 6)
                Text(verbatim: item.start.formatted(date: .omitted, time: .shortened))
                    .foregroundStyle(Ink.tertiary)
                    .monospacedDigit()
                Text(verbatim: item.title).foregroundStyle(Ink.primary).lineLimit(1)
            }
            .font(.system(size: Look.size(11)))
            .lineLimit(1)
            .frame(height: lineHeight)
            .opacity(item.response == .declined ? 0.5 : 1)
        }
    }

    private var lineHeight: CGFloat { Look.gap(17) }
}

/// Dragging on the calendar grid. With a mouse it starts as soon as the pointer moves; on a
/// touch screen it starts after a short press, so a swipe still scrolls the hours.
@MainActor
func calendarDrag(changed: @escaping (DragGesture.Value) -> Void, ended: @escaping () -> Void) -> AnyGesture<Void> {
    #if os(iOS)
    AnyGesture(
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { value in
                if case .second(true, let drag?) = value { changed(drag) }
            }
            .onEnded { value in
                if case .second(true, _) = value { ended() }
            }
            .map { _ in () }
    )
    #else
    AnyGesture(
        DragGesture(minimumDistance: 5, coordinateSpace: .local)
            .onChanged(changed)
            .onEnded { _ in ended() }
            .map { _ in () }
    )
    #endif
}

/// A colleague's day beside yours: when they're busy, striped in their colour. Busy is all a
/// work calendar shares; when theirs can't be seen, the column says so rather than looking free.
private struct ColleagueColumn: View {
    let model: MailModel
    let person: ComparedPerson
    let day: Date
    let hourHeight: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let tint = Palette.account(person.colorIndex)
            ZStack(alignment: .topLeading) {
                if model.colleaguesHidden.contains(person.id) {
                    Rectangle()
                        .fill(Fill.one)
                        .overlay {
                            VStack(spacing: 6) {
                                Image(systemName: "eye.slash").font(.system(size: Look.size(13))).foregroundStyle(Ink.tertiary)
                                Text("Their calendar isn't shared with you")
                                    .font(TypeScale.caption)
                                    .foregroundStyle(Ink.tertiary)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.horizontal, 12)
                            .offset(y: -hourHeight * 3)
                        }
                } else {
                    ForEach(Array(model.busyTimes(of: person, on: day).enumerated()), id: \.offset) { _, busy in
                        let top = y(busy.start)
                        let height = max(y(busy.end) - top, 14)
                        ZStack(alignment: .topLeading) {
                            if busy.kind != .workingElsewhere {
                                Stripes().stroke(tint.opacity(busy.kind == .tentative ? 0.12 : 0.22), lineWidth: 1.5)
                            }
                            if height > 22 {
                                Label {
                                    Text(verbatim: Self.label(busy))
                                } icon: {
                                    if let symbol = Self.symbol(busy.kind) { Image(systemName: symbol) }
                                }
                                    .labelStyle(.titleAndIcon)
                                    .font(.system(size: Look.size(11), weight: .medium).monospacedDigit())
                                    .foregroundStyle(busy.kind == .outOfOffice ? Ink.primary : Ink.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Paper.panel.opacity(0.85), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                    .padding(4)
                            }
                        }
                        .frame(width: proxy.size.width - 6, height: height - 2)
                        .background(tint.opacity(0.08))
                        .background(Paper.panel)
                        .overlay(alignment: .leading) { Rectangle().fill(tint).frame(width: 3) }
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .offset(x: 3, y: top + 1)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("\(person.address.displayName) is busy \(busy.start.formatted(date: .omitted, time: .shortened)) – \(busy.end.formatted(date: .omitted, time: .shortened))"))
                    }
                }
            }
        }
    }

    private func y(_ date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(Calendar.current.startOfDay(for: day)) / 3600) * hourHeight
    }

    /// "Out of office", "Working elsewhere · 9:00 – 17:00", or the time when just busy.
    static func label(_ busy: BusyTime) -> String {
        let time = busy.start.formatted(date: .omitted, time: .shortened) + " – " + busy.end.formatted(date: .omitted, time: .shortened)
        return switch busy.kind {
        case .outOfOffice: String(localized: "Out of office")
        case .workingElsewhere: String(localized: "Working elsewhere") + " · " + time
        case .tentative: String(localized: "Maybe busy") + " · " + time
        case .busy: time
        }
    }

    static func symbol(_ kind: BusyTime.Kind) -> String? {
        switch kind {
        case .outOfOffice: "airplane"
        case .workingElsewhere: "building.2"
        default: nil
        }
    }
}

/// Diagonal lines, the usual way calendars draw time that's taken but not shown.
private struct Stripes: Shape {
    var spacing: CGFloat = 7

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = -rect.height
        while x < rect.width {
            path.move(to: CGPoint(x: x, y: rect.height))
            path.addLine(to: CGPoint(x: x + rect.height, y: 0))
            x += spacing
        }
        return path
    }
}

/// A person at the top of their column: face (or You), name, and where they are now.
private struct PersonHeading: View {
    let title: String
    let address: EmailAddress?
    let colorIndex: Int?
    let detail: String?

    var body: some View {
        HStack(spacing: 8) {
            if let address {
                Avatar(address, size: 26)
                    .overlay(Circle().strokeBorder(colorIndex.map(Palette.account) ?? .clear, lineWidth: 2).padding(-3))
                    .padding(3)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title)
                    .font(.system(size: Look.size(13), weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                // Always a second line, so the headings line up and nothing moves as it changes.
                Text(verbatim: detail ?? " ")
                    .font(TypeScale.caption)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Time when you and everyone compared are all free, across the columns: how long, and a button
/// that starts a meeting with them then.
private struct FreeTogetherBand: View {
    let slot: DateInterval
    let day: Date
    let hourHeight: CGFloat
    let people: [ComparedPerson]
    @Environment(CalendarEditor.self) private var editor: CalendarEditor?

    var body: some View {
        let top = CGFloat(slot.start.timeIntervalSince(Calendar.current.startOfDay(for: day)) / 3600) * hourHeight
        let height = CGFloat(slot.duration / 3600) * hourHeight
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Status.done.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Status.done.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .allowsHitTesting(false)
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 8) {
                    Text("Everyone's free · \(Countdown.length(minutes: Int(slot.duration / 60)))")
                        .font(.system(size: Look.size(11), weight: .semibold))
                        .foregroundStyle(Status.done)
                    if let editor, editor.canAdd, height >= 30 {
                        Button("Meet") {
                            editor.newEvent(start: slot.start, end: min(slot.end, slot.start.addingTimeInterval(1800)),
                                            invitees: people.map(\.address))
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: Look.size(11), weight: .semibold))
                        .foregroundStyle(Ink.inverse)
                        .padding(.horizontal, 10)
                        .frame(height: Look.gap(20))
                        .background(Status.done, in: Capsule())
                        .tip("Make a meeting with everyone then")
                    }
                }
                .padding(5)
                .frame(maxHeight: height, alignment: .top)
                .clipped()
            }
            .frame(height: height - 2)
            .padding(.trailing, 4)
            .offset(y: top + 1)
            .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Where a sideways swipe has the days: observed only by the layers that slide. Settling is a
/// spring it runs itself on the display's refresh, so it can be taken over mid-way.
@MainActor @Observable
final class DaySlider: NSObject {
    /// How far the days have moved, in points, short of a whole day.
    var offset: CGFloat = 0
    /// From the first sideways movement until the days settle on whole columns.
    var isSliding = false
    /// How far this swipe has moved the days, to keep it within one week.
    @ObservationIgnored var travel: CGFloat = 0
    /// How fast the days are moving, in points a second.
    @ObservationIgnored private var velocity: CGFloat = 0
    @ObservationIgnored private var lastMove: CFTimeInterval = 0
    #if os(macOS)
    @ObservationIgnored private var link: CADisplayLink?
    #endif

    /// How fast the days were moving when the fingers lifted, in points a second.
    /// Held still before lifting: no speed at all.
    var speed: CGFloat { CACurrentMediaTime() - lastMove > 0.08 ? 0 : velocity }

    /// The fingers (or their momentum) moved the days by `dx`: keeps a smoothed speed.
    func noteMove(_ dx: CGFloat) {
        let now = CACurrentMediaTime()
        let dt = now - lastMove
        lastMove = now
        guard dt > 0, dt < 0.1 else { velocity = 0; return }
        velocity = velocity * 0.4 + (dx / CGFloat(dt)) * 0.6
    }

    /// Springs the offset to zero from the speed the days had.
    func springHome() {
        // Heading home, never faster than the spring can stop without passing it; heading
        // away, it turns round.
        let limit = CalendarScroll.springOmega * abs(offset)
        if velocity * offset < 0 { velocity = max(min(velocity, limit), -limit) }
        velocity = min(max(velocity, -3000), 3000)
        #if os(macOS)
        stopSpring()
        guard let screen = NSScreen.main else { finish(); return }
        let link = screen.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        #else
        withAnimation(.spring(response: 0.42, dampingFraction: 1)) { offset = 0 } completion: { [weak self] in
            if self?.offset == 0 { self?.isSliding = false }
        }
        #endif
    }

    func stopSpring() {
        #if os(macOS)
        link?.invalidate()
        link = nil
        #endif
    }

    #if os(macOS)
    @objc private func step(_ link: CADisplayLink) {
        let dt = min(max(link.targetTimestamp - link.timestamp, 1.0 / 240), 1.0 / 30)
        let next = CalendarScroll.springStep(offset: offset, velocity: velocity, dt: dt)
        velocity = next.velocity
        if abs(next.offset) < 0.3 && abs(next.velocity) < 6 {
            finish()
        } else {
            offset = next.offset
        }
    }
    #endif

    private func finish() {
        stopSpring()
        offset = 0
        velocity = 0
        isSliding = false
    }
}

/// A layer of the grid while it slides: a day wider on each side, moved under a fixed gutter.
/// Only this reads the offset, so each step of the fingers just moves it.
private struct RollingContent<Content: View, Gutter: View>: View {
    let slider: DaySlider
    let width: CGFloat
    let column: CGFloat
    /// Days drawn on each side of the ones in view.
    let buffer: Int
    let gutterWidth: CGFloat
    let content: Content
    let gutter: Gutter

    var body: some View {
        content
            .frame(width: width + 2 * CGFloat(buffer) * column)
            .offset(x: -CGFloat(buffer) * column + slider.offset)
            .frame(width: width, alignment: .leading)
            .clipped()
            .overlay(alignment: .leading) { gutter.frame(width: gutterWidth).allowsHitTesting(false) }
    }
}

/// The hours' scroll position, kept without telling SwiftUI (see `CalendarTimeline.scroll`).
final class ScrollMetrics {
    var y: CGFloat = 0
    var height: CGFloat = 600
}
