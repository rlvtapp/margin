import AuthenticationServices
import MailCore
import SwiftUI

/// The Calendar: a month to pick a day, and what's on from that day for two weeks, each
/// meeting with Going? Yes / Maybe / No and Join. Meetings come from invitations in the mail,
/// and from the account's own calendar where Margin may read it. Side by side when there's
/// room, stacked on a phone.
struct CalendarPage: View {
    @Bindable var model: MailModel
    var showsTitle = true
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var isRefreshing = false

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= 760
            ScrollView {
                VStack(alignment: .leading, spacing: wide ? 36 : 20) {
                    if showsTitle { header }
                    if wide {
                        HStack(alignment: .top, spacing: 72) {
                            VStack(alignment: .leading, spacing: 20) {
                                monthView
                                CalendarSources(model: model, month: month)
                            }
                            .frame(width: 240)
                            agendaView
                        }
                    } else {
                        monthView
                        CalendarSources(model: model, month: month)
                        agendaView
                    }
                }
                // A calm page with room around it, not panes stretched across the window.
                .padding(.horizontal, wide ? 64 : Space.l)
                .padding(.top, wide ? 44 : Space.l)
                .padding(.bottom, 64)
                .frame(maxWidth: 1040, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Paper.panel)
        }
        .task(id: month) { await model.refreshCalendar(around: month) }
    }

    private var header: some View {
        HStack {
            Text("Calendar").font(.system(size: Look.size(24), weight: .bold)).foregroundStyle(Ink.primary)
            Spacer()
            if isRefreshing {
                ProgressView().controlSize(.small).frame(width: 28, height: 28)
            } else {
                IconButton("arrow.clockwise", help: "Refresh") {
                    isRefreshing = true
                    Task {
                        await model.findInvites()
                        await model.refreshCalendar(around: month, force: true)
                        isRefreshing = false
                    }
                }
            }
        }
    }

    private var monthView: some View {
        MonthGrid(month: $month, day: $day,
                  marked: model.daysWithEvents(from: MonthGrid.firstShown(in: month), to: MonthGrid.lastShown(in: month)))
    }

    private var agendaView: some View {
        let end = Calendar.current.date(byAdding: .day, value: 14, to: day) ?? day
        return AgendaList(model: model, items: model.agenda(from: day, to: end), from: day)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A month of days, Monday or Sunday first as the region likes it, with a dot under days that
/// have something on. Today is in the accent colour; the chosen day sits on a soft circle.
struct MonthGrid: View {
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
            Button("Today") {
                day = Calendar.current.startOfDay(for: Date())
                month = Calendar.current.dateInterval(of: .month, for: day)?.start ?? month
            }
            .buttonStyle(.plain)
            .font(TypeScale.label.weight(.medium))
            .foregroundStyle(Palette.accent)
            .opacity(Calendar.current.isDateInToday(day) ? 0 : 1)
            .disabled(Calendar.current.isDateInToday(day))
        }
    }

    private func step(_ months: Int) {
        withAnimation(Motion.quick) { month = Calendar.current.date(byAdding: .month, value: months, to: month) ?? month }
    }
}

private struct DayCell: View {
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
                    .foregroundStyle(isToday ? Palette.accent : inMonth ? Ink.primary : Ink.quaternary)
                    .frame(width: 30, height: 30)
                    .background { if isChosen { Circle().fill(Palette.accent.opacity(0.14)) } }
                Circle()
                    .fill(isMarked ? Palette.accent.opacity(inMonth ? 1 : 0.4) : .clear)
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
    let model: MailModel
    let items: [AgendaItem]
    let from: Date

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
        let days = Self.days(upcoming, from: from)
        return VStack(alignment: .leading, spacing: 0) {
            if upcoming.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nothing on your calendar for the next two weeks.")
                        .font(TypeScale.row)
                        .foregroundStyle(Ink.secondary)
                    if !model.readsAccountCalendars {
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
                                .foregroundStyle(isToday ? Palette.accent : Ink.primary)
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

    static func days(_ items: [AgendaItem], from: Date) -> [(day: Date, items: [AgendaItem])] {
        let calendar = Calendar.current
        var result: [Date: [AgendaItem]] = [:]
        for item in items {
            result[max(calendar.startOfDay(for: item.start), from), default: []].append(item)
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
    let time: Date

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Palette.accent).frame(width: 7, height: 7)
            Text(verbatim: time.formatted(date: .omitted, time: .shortened))
                .font(.system(size: Look.size(11), weight: .semibold).monospacedDigit())
                .foregroundStyle(Palette.accent)
            Rectangle().fill(Palette.accent.opacity(0.5)).frame(height: 1)
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
private struct AgendaRow: View {
    let model: MailModel
    let item: AgendaItem
    var overlaps: String?
    var startsIn: String?
    @State private var isHovered = false

    private var isSoon: Bool { !item.isAllDay && item.start.timeIntervalSinceNow < 15 * 60 }
    private var declined: Bool { item.response == .declined }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Palette.accent.opacity(declined ? 0.35 : 1))
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
                        .foregroundStyle(Palette.accent)
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
                if !item.isMine { GoingPicker(response: item.response) { model.respond(to: item, with: $0) } }
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
        .contextMenu {
            if item.invitationThreadID != nil {
                Button("Show Invitation") { open() }
            }
            if let url = item.joinURL {
                Button("Copy Meeting Link") { model.copy(url.absoluteString, announce: "Meeting link copied") }
            }
        }
    }

    private func open() {
        guard let threadID = item.invitationThreadID else { return }
        model.showInvitation(threadID: threadID, title: item.title)
    }

    private var time: String {
        if item.isAllDay { return String(localized: "All day") }
        return item.start.formatted(date: .omitted, time: .shortened) + " – " + item.end.formatted(date: .omitted, time: .shortened)
    }

    /// Where: the room or address, else the call's service.
    private var place: String {
        if let location = item.location, !location.isEmpty { return location }
        return item.joinURL.flatMap(Self.service) ?? ""
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
private struct GoingPicker: View {
    let response: CalendarInvite.Response?
    let choose: (CalendarInvite.Response) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach([CalendarInvite.Response.accepted, .tentative, .declined], id: \.self) { option in
                let isOn = response == option
                Button { if !isOn { choose(option) } } label: {
                    Text(verbatim: option.shortTitle)
                        .font(.system(size: Look.size(12), weight: .semibold))
                        .foregroundStyle(isOn ? Ink.inverse : Ink.secondary)
                        .padding(.horizontal, 11)
                        .frame(height: Look.gap(24))
                        .background(isOn ? Palette.accent : Fill.one, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Going?"))
    }
}

/// Join: filled in the accent colour when the meeting is about to start or on now, a soft
/// tint of it before that.
private struct JoinButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: Look.size(12), weight: .semibold))
            .foregroundStyle(prominent ? Ink.inverse : Palette.accent)
            .padding(.horizontal, 16)
            .frame(height: Look.gap(28))
            .background(prominent ? Palette.accent : Palette.accent.opacity(0.12), in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// Where the meetings come from, and the way to add the rest: each Microsoft 365, Outlook or
/// Google mailbox can show its whole calendar here once it's connected (one sign-in, which also
/// lets New Meeting use that calendar and suggests people from its contacts).
private struct CalendarSources: View {
    let model: MailModel
    let month: Date
    @Environment(\.webAuthenticationSession) private var webAuthentication
    @State private var connecting: UUID?
    @State private var problem: String?

    private var connectable: [MailAccount] {
        model.accounts.filter { $0.connection != .sample && model.canAskForAccess($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.readsAccountCalendars ? "From your calendars and invitations in your mail"
                                             : "Meetings from invitations in your mail")
                .font(TypeScale.caption)
                .foregroundStyle(Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(connectable) { account in
                HStack(spacing: 8) {
                    AccountMark(account, size: 18)
                    Text(verbatim: account.address.address)
                        .font(TypeScale.label)
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if model.usesAccountCalendar(account) {
                        Menu {
                            Button("Connect Again…") { Task { await reconnect(account) } }
                            Button("Disconnect", role: .destructive) { disconnect(account) }
                        } label: {
                            Image(systemName: "checkmark").font(.system(size: Look.size(10), weight: .bold)).foregroundStyle(Ink.tertiary)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicatorHidden()
                        .fixedSize()
                        .tip("Showing this calendar")
                    } else if connecting == account.id {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button("Connect") { Task { await connect(account) } }
                            .buttonStyle(.plain)
                            .font(TypeScale.label.weight(.semibold))
                            .foregroundStyle(Palette.accent)
                            .tip("Show this mailbox's whole calendar")
                    }
                }
            }
            if let problem {
                Text(verbatim: problem).font(TypeScale.caption).foregroundStyle(Status.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 4)
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
