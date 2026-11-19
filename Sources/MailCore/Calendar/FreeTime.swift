import Foundation

/// Open time between meetings, for AI apps asking when the person is free.
public enum FreeTime {
    /// Open slots of at least `duration` inside working hours on each day of `range`, skipping
    /// weekends unless asked, never before `now`.
    ///
    /// `workday` is start hour...end hour: 9...17 means 09:00 to 17:00. Each slot is a whole gap
    /// between busy times (not chopped into `duration` pieces), its start rounded up and its end
    /// rounded down to `step`, so a meeting ending 10:07 frees you from 10:15.
    public static func slots(busy: [DateInterval], in range: DateInterval, duration: TimeInterval,
                             workday: ClosedRange<Int> = 9...17, includeWeekends: Bool = false, step: TimeInterval = 900,
                             now: Date, calendar: Calendar = .current) -> [DateInterval] {
        let step = step > 0 ? step : 60
        let startHour = max(0, min(workday.lowerBound, 24)), endHour = max(0, min(workday.upperBound, 24))
        guard endHour > startHour, range.duration > 0 else { return [] }
        let busy = merge(busy)
        var slots: [DateInterval] = []
        func append(_ start: Date, _ end: Date, day: Date) {
            let alignedStart = align(start, to: step, from: day, up: true)
            let alignedEnd = align(end, to: step, from: day, up: false)
            if alignedEnd.timeIntervalSince(alignedStart) >= max(duration, 1) {
                slots.append(DateInterval(start: alignedStart, end: alignedEnd))
            }
        }
        var day = calendar.startOfDay(for: range.start)
        // Bounded, in case of a pathological calendar.
        for _ in 0..<400 where day < range.end {
            defer { day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400) }
            if !includeWeekends && calendar.isDateInWeekend(day) { continue }
            guard let open = at(startHour, on: day, calendar), let close = at(endHour, on: day, calendar) else { continue }
            let from = max(open, range.start, now), to = min(close, range.end)
            guard from < to else { continue }
            var cursor = from
            for interval in busy where interval.end > cursor && interval.start < to {
                if interval.start > cursor { append(cursor, interval.start, day: day) }
                cursor = max(cursor, interval.end)
            }
            if cursor < to { append(cursor, to, day: day) }
        }
        return slots
    }

    /// Overlapping or touching intervals joined, soonest first.
    static func merge(_ intervals: [DateInterval]) -> [DateInterval] {
        var merged: [DateInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    private static func at(_ hour: Int, on day: Date, _ calendar: Calendar) -> Date? {
        hour == 24 ? calendar.date(byAdding: .day, value: 1, to: day) : calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)
    }

    private static func align(_ date: Date, to step: TimeInterval, from day: Date, up: Bool) -> Date {
        let offset = date.timeIntervalSince(day) / step
        return day.addingTimeInterval((up ? offset.rounded(.up) : offset.rounded(.down)) * step)
    }
}
