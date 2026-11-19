import Foundation
import MailCore

/// Mailboxes whose calendar service turned down suggesting times (a personal account, or one
/// that hasn't allowed reading shared calendars), so it isn't asked again this run.
@MainActor private var meetingTimesRefused: Set<UUID> = []

/// Suggested times (docs/calendar.md): when making an event with people, times that suit
/// everyone. Microsoft 365 suggests them itself; otherwise, and to fill up, Margin works them
/// out from your calendars (every one the Calendar shows) and everyone's busy times.
extension MailModel {
    /// Up to `limit` times of `length` from `from` on, soonest first, in working hours on
    /// weekdays. The calendar service's own suggestions come first when it has any.
    public func suggestTimes(with people: [EmailAddress], length: TimeInterval, from: Date = Date(),
                             in destination: EventDestination?, limit: Int = 5, now: Date = Date(),
                             forAIApps: Bool = false, counting: Set<String>? = nil) async -> [SuggestedTime] {
        guard length > 0 else { return [] }
        let people = uniquePeople(people)
        let calendar = Calendar.current
        let start = max(from, now)
        let days = 14
        let rangeStart = calendar.startOfDay(for: start)
        let rangeEnd = calendar.date(byAdding: .day, value: days, to: rangeStart) ?? rangeStart.addingTimeInterval(Double(days) * 86_400)
        let mine = await ownBusy(from: rangeStart, to: rangeEnd, forAIApps: forAIApps, counting: counting)
        let busy = await busyTimes(of: people, from: rangeStart, to: rangeEnd, in: destination, forAIApps: forAIApps)
        let local = MeetingTimes.suggest(people: people, busy: busy, mine: mine, length: length, from: start, days: days,
                                         limit: limit, now: now, calendar: calendar)
        var suggested: [SuggestedTime] = []
        if !people.isEmpty, let account = askingAccount(for: people, in: destination, forAIApps: forAIApps), !meetingTimesRefused.contains(account.id),
           !environment.isPreview {
            do {
                if let finder = try await calendarAdapter(for: account) as? any MeetingTimeFinding {
                    suggested = try await finder.meetingTimes(with: people, length: length, from: Self.nextQuarter(start),
                                                              to: rangeEnd, limit: limit)
                }
            } catch {
                // Turned down for good (no permission, or a personal account); other failures may pass.
                if case MailError.authenticationFailed = error { meetingTimesRefused.insert(account.id) }
                Self.calendarLog.error("suggested times: calendar service failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return MeetingTimes.merged(calendar: suggested, local: local, mine: mine, limit: limit)
    }

    /// Whether an event is in one of the calendars counted. An invitation from the mail belongs
    /// to its mailbox, which counts when any of that mailbox's calendars does.
    nonisolated static func counts(_ item: AgendaItem, in counting: Set<String>?) -> Bool {
        guard let counting else { return true }
        if counting.contains(item.calendarKey) { return true }
        if case .invite(_, let account?) = item.source {
            let prefix = calendarKey(account: account)
            return counting.contains { $0 == prefix || $0.hasPrefix(prefix + ":") }
        }
        return false
    }

    /// The calendars your own busy time can come from, for choosing which count when suggesting
    /// times: each mailbox (or each of its calendars, when it has several) and this device's.
    public var busyCalendarChoices: [BusyCalendar] {
        var result: [BusyCalendar] = []
        for account in accounts where account.connection != .sample || environment.isPreview {
            let calendars = accountCalendars[account.id] ?? []
            if calendars.count > 1 {
                result += calendars.filter { $0.owner == nil }.map {
                    BusyCalendar(id: Self.calendarKey(account: account.id, calendar: $0.id), title: $0.name,
                                 detail: account.address.address,
                                 colorIndex: $0.isDefault ? account.colorIndex : ($0.color.map(Palette.nearestAccountIndex(to:)) ?? account.colorIndex))
                }
            } else {
                result.append(BusyCalendar(id: Self.calendarKey(account: account.id), title: account.address.address, detail: nil,
                                           colorIndex: account.colorIndex))
            }
        }
        if showsDeviceCalendar {
            result += deviceCalendars.map {
                BusyCalendar(id: Self.calendarKey(device: $0.title), title: $0.title, detail: $0.source,
                             colorIndex: $0.color.map(Palette.nearestAccountIndex(to:)) ?? 0)
            }
        }
        return result.filter { isCalendarShown($0.id) }
    }

    /// The calendars left out when suggesting times, remembered between events.
    public var suggestionSkips: Set<String> {
        get { Set(environment.defaults.stringArray(forKey: "calendar.suggest.skip") ?? []) }
        set { environment.defaults.set(Array(newValue).sorted(), forKey: "calendar.suggest.skip") }
    }

    /// Who among `people` is busy at some point between `start` and `end` (as far as their
    /// calendars can be seen), for "Sam is busy then".
    public func busyPeople(_ people: [EmailAddress], from start: Date, to end: Date,
                           in destination: EventDestination?) async -> [EmailAddress] {
        let people = uniquePeople(people)
        guard !people.isEmpty, end > start else { return [] }
        let busy = await busyTimes(of: people, from: start, to: end, in: destination)
        return MeetingTimes.busyPeople(people, busy: busy, start: start, end: end)
    }

    /// Your own busy time: every timed event in the calendars the Calendar shows, all
    /// mailboxes and the device's, except ones you declined.
    /// With `forAIApps`, mailboxes hidden from AI apps are left out.
    /// With `counting`, only events in those calendars (`busyCalendarChoices` keys).
    func ownBusy(from start: Date, to end: Date, forAIApps: Bool = false, counting: Set<String>? = nil) async -> [DateInterval] {
        await toolEventsReading(from: start, to: end, forAIApps: forAIApps).items
            .filter { !$0.isAllDay && $0.response != .declined && Self.counts($0, in: counting) }
            .map { DateInterval(start: $0.start, end: max($0.start, $0.end)) }
    }

    /// Everyone's busy times keyed by lowercased address, each asked through the connected
    /// mailbox in their own domain (or the event's mailbox). People nobody could ask about are
    /// left out: unknown, not free.
    func busyTimes(of people: [EmailAddress], from start: Date, to end: Date,
                   in destination: EventDestination?, forAIApps: Bool = false) async -> [String: [BusyTime]] {
        guard !people.isEmpty else { return [:] }
        if environment.isPreview {
            return Dictionary(people.compactMap { person in
                colleagueBusy[person.address.lowercased()].map { (person.address.lowercased(), $0) }
            }, uniquingKeysWith: { $0 + $1 })
        }
        var groups: [UUID: [String]] = [:]
        for person in people {
            guard let account = askingAccount(for: [person], in: destination, forAIApps: forAIApps) else { continue }
            groups[account.id, default: []].append(person.address)
        }
        var result: [String: [BusyTime]] = [:]
        for (accountID, emails) in groups {
            guard let account = account(accountID) else { continue }
            do {
                let found = try await busyTimes(for: emails, from: start, to: end, account: account)
                for (key, value) in found { result[key.lowercased(), default: []] += value }
            } catch {
                Self.calendarLog.error("suggested times: free/busy failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return result
    }

    /// The connected mailbox to ask about these people: one in their domain when they share
    /// one, else the event's own mailbox, else the first connected one.
    private func askingAccount(for people: [EmailAddress], in destination: EventDestination?, forAIApps: Bool = false) -> MailAccount? {
        let connected = accounts.filter {
            usesAccountCalendar($0) && !(forAIApps && connectionSettings.hiddenAccounts.contains($0.id))
        }
        let domains = Set(people.compactMap { $0.address.split(separator: "@").last.map { $0.lowercased() } })
        if domains.count == 1, let domain = domains.first,
           let sameDomain = connected.first(where: { $0.address.address.lowercased().hasSuffix("@" + domain) }) {
            return sameDomain
        }
        if case .account(let id)? = destination, let own = connected.first(where: { $0.id == id }) { return own }
        return connected.first
    }

    /// The people once each, leaving out your own addresses.
    private func uniquePeople(_ people: [EmailAddress]) -> [EmailAddress] {
        let mine = Set(accounts.map { $0.address.address.lowercased() })
        var seen = Set<String>()
        return people.filter { EmailAddress.isValid($0.address) && !mine.contains($0.address.lowercased()) && seen.insert($0.address.lowercased()).inserted }
    }

    static func nextQuarter(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 900).rounded(.up) * 900)
    }
}

/// A calendar your busy time can come from, to count or leave out when suggesting times.
public struct BusyCalendar: Identifiable, Hashable, Sendable {
    /// Its key in the Calendar's list (`MailModel.calendarKey`).
    public let id: String
    public let title: String
    /// Its mailbox or account, under the name.
    public let detail: String?
    public let colorIndex: Int
}
