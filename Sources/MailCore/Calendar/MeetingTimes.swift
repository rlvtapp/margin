import Foundation

/// A time for a meeting that suits the people invited: when it is, and who's free, busy or
/// can't be seen then.
public struct SuggestedTime: Hashable, Sendable, Identifiable {
    public var start: Date
    public var end: Date
    /// Free then, as far as their calendar says.
    public var free: [EmailAddress]
    /// Busy, tentative or away then. Empty for times worked out here, which skip anyone busy.
    public var busy: [EmailAddress]
    /// Whose calendar couldn't be seen (outside the organization, or not shared): unknown, not free.
    public var unknown: [EmailAddress]
    /// Whether the mailbox's own calendar service suggested it, rather than Margin working it out.
    public var fromCalendar: Bool

    public var id: Date { start }

    public init(start: Date, end: Date, free: [EmailAddress] = [], busy: [EmailAddress] = [],
                unknown: [EmailAddress] = [], fromCalendar: Bool = false) {
        self.start = start
        self.end = end
        self.free = free
        self.busy = busy
        self.unknown = unknown
        self.fromCalendar = fromCalendar
    }
}

/// A calendar service that can suggest meeting times itself (Microsoft 365).
public protocol MeetingTimeFinding: Sendable {
    /// Times between `from` and `to` in working hours when everyone is free, at most `limit`.
    func meetingTimes(with attendees: [EmailAddress], length: TimeInterval, from: Date, to: Date,
                      limit: Int) async throws -> [SuggestedTime]
}

/// Suggesting meeting times (docs/calendar.md, "Suggested times"): from the calendar service
/// when it can, otherwise worked out here from everyone's busy times with `FreeTime.slots`.
public enum MeetingTimes {
    /// Times when you and everyone whose calendar can be seen are free: in working hours on
    /// weekdays, from the next quarter hour, soonest first, at most two a day so the choice
    /// spans more than one morning.
    ///
    /// `busy` is keyed by lowercased address; anyone missing from it can't be seen and is
    /// listed as unknown, never taken for free.
    public static func suggest(people: [EmailAddress], busy: [String: [BusyTime]], mine: [DateInterval],
                               length: TimeInterval, from: Date, days: Int = 14, workday: ClosedRange<Int> = 9...17,
                               limit: Int = 5, now: Date, calendar: Calendar = .current) -> [SuggestedTime] {
        guard length > 0, limit > 0 else { return [] }
        let seen = people.filter { busy[key($0)] != nil }
        let unknown = people.filter { busy[key($0)] == nil }
        let theirs = seen.flatMap { busy[key($0)] ?? [] }.filter(\.blocks).map { DateInterval(start: $0.start, end: max($0.start, $0.end)) }
        let start = calendar.startOfDay(for: from)
        let end = calendar.date(byAdding: .day, value: max(days, 1), to: start) ?? start.addingTimeInterval(Double(days) * 86_400)
        let slots = FreeTime.slots(busy: mine + theirs, in: DateInterval(start: start, end: end), duration: length,
                                   workday: workday, includeWeekends: false, now: max(from, now), calendar: calendar)
        var starts: [Date] = []
        for slot in slots {
            starts.append(slot.start)
            // A long gap offers a second, later time too: the first whole hour past its middle.
            let latest = slot.end.addingTimeInterval(-length)
            let middle = slot.start.addingTimeInterval(latest.timeIntervalSince(slot.start) / 2)
            if let hour = calendar.nextDate(after: middle.addingTimeInterval(-1), matching: DateComponents(minute: 0, second: 0),
                                            matchingPolicy: .nextTime),
               hour <= latest, hour.timeIntervalSince(slot.start) >= length + 3600 {
                starts.append(hour)
            }
        }
        var perDay: [Date: Int] = [:]
        var times: [SuggestedTime] = []
        for start in starts.sorted() where times.count < limit {
            let day = calendar.startOfDay(for: start)
            guard perDay[day, default: 0] < 2 else { continue }
            perDay[day, default: 0] += 1
            times.append(SuggestedTime(start: start, end: start.addingTimeInterval(length), free: seen, unknown: unknown))
        }
        return times
    }

    /// The calendar service's suggestions first (leaving out any that clash with your own
    /// events, which it may not know: other calendars on the device), topped up with the
    /// ones worked out here, then soonest first.
    public static func merged(calendar suggested: [SuggestedTime], local: [SuggestedTime], mine: [DateInterval],
                              limit: Int = 5) -> [SuggestedTime] {
        let clear = suggested.filter { time in !mine.contains { $0.start < time.end && time.start < $0.end } }
            .sorted { $0.start < $1.start }
        var chosen = Array(clear.prefix(limit))
        for time in local where chosen.count < limit && !chosen.contains(where: { $0.start == time.start }) {
            chosen.append(time)
        }
        return chosen.sorted { $0.start < $1.start }
    }

    /// Who among `people` is busy at some point between `start` and `end`.
    public static func busyPeople(_ people: [EmailAddress], busy: [String: [BusyTime]], start: Date, end: Date) -> [EmailAddress] {
        people.filter { person in (busy[key(person)] ?? []).contains { $0.blocks && $0.overlaps(start, end) } }
    }

    static func key(_ address: EmailAddress) -> String { address.address.lowercased() }
}

extension BusyTime {
    /// Whether the time can't be booked: working elsewhere still can.
    var blocks: Bool { kind != .workingElsewhere }
}
