import Foundation
import MailCore

/// A colleague whose calendar the Calendar shows next to yours.
public struct ComparedPerson: Codable, Hashable, Identifiable, Sendable {
    public var address: EmailAddress
    public var colorIndex: Int

    public var id: String { address.address.lowercased() }
}

/// Comparing calendars with colleagues (docs/calendar.md): their busy times beside yours in Day
/// and Week, asked from a connected Microsoft 365 or Google calendar (`busyTimes`). Only when
/// busy, never what: that's all a work calendar shares with colleagues by default. People
/// outside the organization, or whose calendars aren't shared, show as unknown, not free.
extension MailModel {
    /// Whether any mailbox's calendar is connected, which is what can ask.
    public var canCompareCalendars: Bool {
        accounts.contains { usesAccountCalendar($0) } || (environment.isPreview && !comparedPeople.isEmpty)
    }

    public func addColleague(_ address: EmailAddress) {
        let key = address.address.lowercased()
        guard EmailAddress.isValid(address.address), !comparedPeople.contains(where: { $0.id == key }),
              !accounts.contains(where: { $0.address.address.lowercased() == key }) else { return }
        // Colours not used by the mailboxes or the others, so each person is told apart.
        let used = Set(accounts.map(\.colorIndex) + comparedPeople.map(\.colorIndex))
        let color = (0..<8).first { !used.contains($0) } ?? comparedPeople.count % 8
        comparedPeople.append(ComparedPerson(address: address, colorIndex: color))
        saveColleagues()
        colleagueRange = nil
        Task { await refreshColleagues(around: Date(), force: true) }
    }

    /// Who to suggest under Compare with, matching what's typed: people who shared their
    /// calendar with you first, then people you know at your own organization (whose busy times
    /// a work calendar shows). Nobody at a public mail service, nobody already compared, not you.
    public func colleagueSuggestions(for typed: String, limit: Int = 6) -> [EmailAddress] {
        let text = typed.trimmingCharacters(in: .whitespaces).lowercased()
        let taken = Set(comparedPeople.map(\.id) + accounts.flatMap { [$0.address] + ($0.aliases ?? []) }.map { $0.address.lowercased() })
        func matches(_ person: EmailAddress) -> Bool {
            text.isEmpty || person.address.lowercased().contains(text) || (person.name?.lowercased().contains(text) ?? false)
        }
        var seen = taken
        var result = knownSharers.filter { matches($0) && seen.insert($0.address.lowercased()).inserted }
        if !text.isEmpty {
            let domains = workDomains
            for person in addressBook.suggestions(for: text, excluding: taken)
            where domains.contains(Self.domain(of: person)) && seen.insert(person.address.lowercased()).inserted {
                result.append(person)
            }
        }
        return Array(result.prefix(limit))
    }

    /// People to invite to an event, matching what's typed: only people you've written to, who
    /// shared a calendar with you, or are in your organization's directory, so automated senders
    /// and people who only wrote to you once stay out. Those whose busy times can be seen first.
    public func inviteeSuggestions(for typed: String, excluding: Set<String>, directory: [EmailAddress] = [],
                                   limit: Int = 6) -> [(person: EmailAddress, seesCalendar: Bool)] {
        let text = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return [] }
        let book = addressBook
        let mine = Set(accounts.flatMap { [$0.address] + ($0.aliases ?? []) }.map { $0.address.lowercased() })
        let sharers = Set(knownSharers.map { $0.address.lowercased() })
        let domains = workDomains
        func matches(_ person: EmailAddress) -> Bool {
            let words = (person.name ?? "").lowercased().split(separator: " ")
            return person.address.lowercased().hasPrefix(text) || words.contains { $0.hasPrefix(text) }
                || (person.name ?? "").lowercased().hasPrefix(text)
        }
        var seen = excluding.union(mine)
        var found: [(EmailAddress, Bool)] = []
        for person in knownSharers + directory + book.entries where matches(person) {
            let key = person.address.lowercased()
            let known = sharers.contains(key) || book.writtenTo.contains(key) || directory.contains { $0.address.lowercased() == key }
            guard known, seen.insert(key).inserted else { continue }
            found.append((person, sharers.contains(key) || domains.contains(Self.domain(of: person))))
        }
        // Stable: calendar first, then as ranked (people written to most come first).
        let ranked = found.enumerated().sorted { ($0.element.1 ? 0 : 1, $0.offset) < ($1.element.1 ? 0 : 1, $1.offset) }.map(\.element)
        return Array(ranked.prefix(limit)).map { (person: $0.0, seesCalendar: $0.1) }
    }

    /// People who shared a calendar with you and are people you know: in your mail or contacts,
    /// or at your organization. Shared calendars also belong to families, groups and rooms
    /// ("Your family"), whose made-up addresses aren't anyone to compare with or invite.
    var knownSharers: [EmailAddress] {
        let book = addressBook
        let known = Set(book.entries.map { $0.address.lowercased() }).union(book.writtenTo)
        let domains = workDomains
        return calendarSharers.filter { person in
            EmailAddress.isValid(person.address)
                && (known.contains(person.address.lowercased()) || domains.contains(Self.domain(of: person)))
        }
    }

    /// The domains of mailboxes with a connected calendar, leaving out public mail services
    /// (anyone can have an address there, and their calendars aren't shared with you).
    var workDomains: Set<String> {
        let public_ = Set(ProviderCatalog.all.flatMap(\.domains).map { $0.lowercased() })
        return Set(accounts.filter { usesAccountCalendar($0) || (environment.isPreview && $0.connection == .sample) }
            .map { Self.domain(of: $0.address) }).subtracting(public_)
    }

    static func domain(of address: EmailAddress) -> String {
        address.address.split(separator: "@").last.map { $0.lowercased() } ?? ""
    }

    /// Reads who shared a calendar with you, from each connected calendar.
    func refreshCalendarSharers() async {
        guard !environment.isPreview else { return }
        var found: [EmailAddress] = []
        for account in accounts where usesAccountCalendar(account) {
            guard let sharing = try? await calendarAdapter(for: account) as? any CalendarSharing,
                  let owners = try? await sharing.sharedCalendarOwners() else { continue }
            found += owners
        }
        var seen = Set<String>()
        calendarSharers = found.filter { seen.insert($0.address.lowercased()).inserted }
    }

    public func removeColleague(_ person: ComparedPerson) {
        comparedPeople.removeAll { $0.id == person.id }
        colleagueBusy[person.id] = nil
        colleaguesHidden.remove(person.id)
        saveColleagues()
    }

    /// When a colleague is busy on a day, clipped to it.
    public func busyTimes(of person: ComparedPerson, on day: Date) -> [BusyTime] {
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (colleagueBusy[person.id] ?? []).filter { $0.overlaps(start, end) }
            .map { BusyTime(start: max($0.start, start), end: min($0.end, end), kind: $0.kind) }
    }

    /// Times on a day when you and everyone compared (whose calendar can be seen) are all free:
    /// half an hour or more, between 8:00 and 18:00, from now on today.
    public func freeTogether(on day: Date, now: Date = Date()) -> [DateInterval] {
        let visible = comparedPeople.filter { !colleaguesHidden.contains($0.id) }
        guard !visible.isEmpty else { return [] }
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        // Working elsewhere is still working: only time they're taken counts.
        var busy = visible.flatMap { busyTimes(of: $0, on: day) }.filter { $0.kind != .workingElsewhere }.map { DateInterval(start: $0.start, end: max($0.start, $0.end)) }
        busy += agenda(from: start, to: end).filter { !$0.isAllDay && $0.response != .declined }
            .map { DateInterval(start: $0.start, end: max($0.start, $0.end)) }
        return FreeTime.slots(busy: busy, in: DateInterval(start: start, end: end), duration: 30 * 60, workday: 8...18,
                              includeWeekends: true, now: Calendar.current.isDateInToday(day) ? now : start)
    }

    /// "Busy until 15:00", "Free until 13:00", "Free for the rest of the day": where a colleague
    /// is at a moment, for their heading. Nil on other days than today.
    public func availability(of person: ComparedPerson, now: Date = Date()) -> String? {
        guard !colleaguesHidden.contains(person.id) else { return nil }
        if let away = outOfOffice(person, at: now) {
            return String(localized: "Out of office until \(Self.untilText(away.end, from: now))")
        }
        let busy = busyTimes(of: person, on: now).filter { $0.kind != .workingElsewhere }.sorted { $0.start < $1.start }
        if let current = busy.first(where: { $0.start <= now && $0.end > now }) {
            // Back-to-back meetings count as one.
            var until = current.end
            for next in busy where next.start <= until && next.end > until { until = next.end }
            return String(localized: "Busy until \(until.formatted(date: .omitted, time: .shortened))")
        }
        if let next = busy.first(where: { $0.start > now }) {
            return String(localized: "Free until \(next.start.formatted(date: .omitted, time: .shortened))")
        }
        return String(localized: "Free for the rest of the day")
    }

    /// The out-of-office time a colleague is in at a moment, joined with any right after it.
    public func outOfOffice(_ person: ComparedPerson, at moment: Date = Date()) -> BusyTime? {
        let away = (colleagueBusy[person.id] ?? []).filter { $0.kind == .outOfOffice }.sorted { $0.start < $1.start }
        guard var current = away.first(where: { $0.start <= moment && $0.end > moment }) else { return nil }
        // A gap of a night or a weekend between two out-of-office stretches is still away.
        for next in away where next.start > current.start && next.start.timeIntervalSince(current.end) < 3 * 86_400 {
            current.end = max(current.end, next.end)
        }
        return current
    }

    /// "15:00" today, "Friday" this week, "28 Nov" further off. An end at midnight is the day
    /// before: out until Friday means back on Saturday's start, so it reads as Friday.
    static func untilText(_ end: Date, from now: Date) -> String {
        let calendar = Calendar.current
        let lastMoment = calendar.startOfDay(for: end) == end ? end.addingTimeInterval(-1) : end
        if calendar.isDate(lastMoment, inSameDayAs: now) && calendar.startOfDay(for: end) != end {
            return end.formatted(date: .omitted, time: .shortened)
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: lastMoment)).day ?? 0
        return days < 7 ? lastMoment.formatted(.dateTime.weekday(.wide)) : lastMoment.formatted(.dateTime.day().month(.abbreviated))
    }

    /// Asks for everyone's busy times around a day (its month, a week either side), each from
    /// the connected mailbox in their own domain when there is one.
    func refreshColleagues(around day: Date, force: Bool = false) async {
        guard !comparedPeople.isEmpty, !environment.isPreview else { return }
        let calendar = Calendar.current
        let month = calendar.dateInterval(of: .month, for: day) ?? DateInterval(start: day, duration: 31 * 86_400)
        let start = calendar.date(byAdding: .day, value: -7, to: month.start) ?? month.start
        let end = calendar.date(byAdding: .day, value: 14, to: month.end) ?? month.end
        if !force, let range = colleagueRange, range.contains(start), range.contains(end) { return }
        let connected = accounts.filter { usesAccountCalendar($0) }
        guard let fallback = connected.first else { return }
        var groups: [UUID: [String]] = [:]
        for person in comparedPeople {
            let domain = person.address.address.split(separator: "@").last.map { $0.lowercased() }
            let account = connected.first { $0.address.address.lowercased().hasSuffix("@" + (domain ?? "")) } ?? fallback
            groups[account.id, default: []].append(person.address.address)
        }
        var busy: [String: [BusyTime]] = [:]
        var asked = Set<String>()
        for (accountID, emails) in groups {
            guard let account = account(accountID) else { continue }
            asked.formUnion(emails.map { $0.lowercased() })
            do {
                let found = try await busyTimes(for: emails, from: start, to: end, account: account)
                busy.merge(found) { $1 }
            } catch {
                Self.calendarLog.error("colleagues: free/busy failed: \(error.localizedDescription, privacy: .public)")
                if force { show(error, account: accountID) }
            }
        }
        colleagueBusy = busy
        colleaguesHidden = asked.subtracting(busy.keys)
        colleagueRange = start...end
    }

    private func saveColleagues() {
        environment.defaults.set(try? JSONEncoder().encode(comparedPeople), forKey: "calendar.compare")
    }

    /// Two colleagues with busy times, for screenshots and previews.
    func addSampleColleagues(today: Date) {
        func at(_ day: Int, _ hour: Double) -> Date { today.addingTimeInterval(Double(day) * 86_400 + hour * 3600) }
        let maya = ComparedPerson(address: EmailAddress(name: "Maya Chen", address: "maya.chen@example.com"), colorIndex: 4)
        let sam = ComparedPerson(address: EmailAddress(name: "Sam Ortiz", address: "sam.ortiz@example.com"), colorIndex: 5)
        let leo = ComparedPerson(address: EmailAddress(name: "Leo Brooks", address: "leo.brooks@example.com"), colorIndex: 2)
        comparedPeople = [maya, sam, leo]
        colleagueBusy = [
            maya.id: [BusyTime(start: at(0, 9), end: at(0, 10.5)), BusyTime(start: at(0, 13), end: at(0, 14)),
                      BusyTime(start: at(0, 17.5), end: at(0, 18.5)), BusyTime(start: at(1, 10), end: at(1, 11)),
                      BusyTime(start: at(2, 14), end: at(2, 16))],
            sam.id: [BusyTime(start: at(0, 8), end: at(0, 9)), BusyTime(start: at(0, 15), end: at(0, 17)),
                     BusyTime(start: at(1, 13), end: at(1, 15)), BusyTime(start: at(3, 9), end: at(3, 12))],
            leo.id: [BusyTime(start: at(-1, 0), end: at(2, 0), kind: .outOfOffice)],
        ]
        colleagueRange = at(-40, 0)...at(60, 0)
    }
}
