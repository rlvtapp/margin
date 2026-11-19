import Foundation
#if canImport(EventKit)
import EventKit
#endif

/// A reminder with a due date, from the Reminders app, for the Calendar view.
public struct DueReminder: Hashable, Identifiable, Sendable {
    /// EventKit's `calendarItemIdentifier`.
    public var id: String
    public var title: String
    public var due: Date
    /// False when only a day was set, not a time.
    public var hasTime: Bool
    public var isDone: Bool
    /// The list it's in.
    public var list: String?

    public init(id: String, title: String, due: Date, hasTime: Bool, isDone: Bool = false, list: String? = nil) {
        self.id = id
        self.title = title
        self.due = due
        self.hasTime = hasTime
        self.isDone = isDone
        self.list = list
    }
}

/// One of the calendars in this device's Calendar app.
public struct DeviceCalendarInfo: Hashable, Identifiable, Sendable {
    public var title: String
    /// The account it belongs to: iCloud, Exchange, Google…
    public var source: String
    /// Its colour as 0xRRGGBB.
    public var color: UInt32?
    /// EventKit's `calendarIdentifier`, where new events are put.
    public var identifier: String?
    /// False for calendars that can only be read: subscriptions, birthdays, holidays.
    public var allowsChanges: Bool

    public var id: String { identifier ?? title }

    public init(title: String, source: String, color: UInt32? = nil, identifier: String? = nil, allowsChanges: Bool = true) {
        self.title = title
        self.source = source
        self.color = color
        self.identifier = identifier
        self.allowsChanges = allowsChanges
    }
}

/// What this device's Calendar and Reminders apps let Margin see.
public enum DeviceAccess: Sendable {
    case notAsked, allowed, refused
}

/// The calendars and reminders already on this device (iCloud, Exchange, Google, subscriptions:
/// whatever the Calendar app shows), read through EventKit. Read-only except for ticking a
/// reminder done, and its events made, moved and changed.
public final class DeviceCalendar: @unchecked Sendable {
    public static let shared = DeviceCalendar()

    #if canImport(EventKit)
    /// One store for the app: EventKit asks for it to be long-lived. Thread-safe for reading.
    let store = EKEventStore()
    #endif

    public init() {}

    public static func eventAccess() -> DeviceAccess {
        #if canImport(EventKit)
        access(EKEventStore.authorizationStatus(for: .event))
        #else
        .refused
        #endif
    }

    public static func reminderAccess() -> DeviceAccess {
        #if canImport(EventKit)
        access(EKEventStore.authorizationStatus(for: .reminder))
        #else
        .refused
        #endif
    }

    #if canImport(EventKit)
    static func access(_ status: EKAuthorizationStatus) -> DeviceAccess {
        switch status {
        case .notDetermined: .notAsked
        case .fullAccess: .allowed
        default: .refused
        }
    }
    #endif

    /// Asks once; afterwards the answer is in System Settings.
    public func requestEvents() async throws -> Bool {
        #if canImport(EventKit)
        try await store.requestFullAccessToEvents()
        #else
        false
        #endif
    }

    public func requestReminders() async throws -> Bool {
        #if canImport(EventKit)
        try await store.requestFullAccessToReminders()
        #else
        false
        #endif
    }

    /// The calendars that hold events, by account then name. Two with the same name show as one.
    public func calendars() -> [DeviceCalendarInfo] {
        #if canImport(EventKit)
        guard Self.eventAccess() == .allowed else { return [] }
        var seen = Set<String>()
        return store.calendars(for: .event)
            .sorted { ($0.source.title, $0.title) < ($1.source.title, $1.title) }
            .compactMap { calendar in
                guard seen.insert(calendar.title).inserted else { return nil }
                return DeviceCalendarInfo(title: calendar.title, source: calendar.source.title, color: Self.rgb(calendar.cgColor),
                                          identifier: calendar.calendarIdentifier, allowsChanges: calendar.allowsContentModifications)
            }
        #else
        []
        #endif
    }

    /// Events between two moments, repeating ones as single occurrences.
    public func events(from start: Date, to end: Date) -> [CalendarEvent] {
        #if canImport(EventKit)
        guard Self.eventAccess() == .allowed else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).compactMap(Self.event)
        #else
        []
        #endif
    }

    /// Reminders still to do that are due between two moments, and overdue ones when `start` is
    /// today or earlier.
    public func reminders(from start: Date, to end: Date) async -> [DueReminder] {
        #if canImport(EventKit)
        guard Self.reminderAccess() == .allowed else { return [] }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: start, ending: end, calendars: nil)
        let found: [DueReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).compactMap(Self.reminder))
            }
        }
        return found.sorted { ($0.due, $0.title) < ($1.due, $1.title) }
        #else
        []
        #endif
    }

    /// Ticks a reminder done, or not done again.
    public func setDone(_ done: Bool, reminder id: String) throws {
        #if canImport(EventKit)
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        reminder.isCompleted = done
        try store.save(reminder, commit: true)
        #endif
    }

    /// Posted when anything in the device's calendars or reminders changes.
    public static var changed: Notification.Name {
        #if canImport(EventKit)
        .EKEventStoreChanged
        #else
        Notification.Name("DeviceCalendarChanged")
        #endif
    }

    /// The prefix of every event id from this device, so it can't clash with an account's.
    public static let idPrefix = "device:"

    /// The EventKit identifier inside one of our ids.
    public static func eventIdentifier(in id: String) -> String? {
        guard id.hasPrefix(idPrefix) else { return nil }
        let rest = id.dropFirst(idPrefix.count)
        return rest.split(separator: "|", maxSplits: 1).first.map(String.init)
    }

    #if canImport(EventKit)
    static func event(_ event: EKEvent) -> CalendarEvent? {
        guard let start = event.startDate, let end = event.endDate, let identifier = event.eventIdentifier else { return nil }
        let attendees = event.attendees ?? []
        let me = attendees.first(where: \.isCurrentUser)
        let response: CalendarInvite.Response? = switch me?.participantStatus {
        case .accepted: .accepted
        case .tentative: .tentative
        case .declined: .declined
        default: nil
        }
        let link = event.url.flatMap { $0.scheme == "https" ? $0 : nil }
            ?? CalendarInvite.meetingLink(in: [event.location, event.notes].compactMap { $0 }.joined(separator: "\n"))
        let organizer = event.organizer
        // A repeating event's occurrences share one identifier; the start tells them apart.
        var result = CalendarEvent(
            id: "\(idPrefix)\(identifier)|\(Int(start.timeIntervalSince1970))",
            uid: event.calendarItemExternalIdentifier,
            title: (event.title ?? "").isEmpty ? String(localized: "Untitled event") : event.title,
            start: start, end: end, isAllDay: event.isAllDay,
            location: event.location.flatMap { $0.isEmpty ? nil : $0 }, joinURL: link,
            organizer: organizer.flatMap { $0.name ?? address(of: $0) },
            response: response,
            isOrganizer: organizer == nil || organizer?.isCurrentUser == true,
            isCancelled: event.status == .canceled,
            repeats: event.hasRecurrenceRules)
        result.calendarName = event.calendar?.title
        result.calendarColor = event.calendar.flatMap { rgb($0.cgColor) }
        result.notes = event.notes
        result.canChange = event.calendar?.allowsContentModifications == true && result.isOrganizer
        result.attendees = attendees.compactMap { person in
            guard let address = address(of: person), EmailAddress.isValid(address) else { return nil }
            let answer: CalendarInvite.Response? = switch person.participantStatus {
            case .accepted: .accepted
            case .tentative: .tentative
            case .declined: .declined
            default: nil
            }
            let kind: MeetingAttendee.Kind = person.participantType == .room || person.participantType == .resource ? .room
                : person.participantRole == .optional ? .optional : .required
            return MeetingAttendee(address: EmailAddress(name: person.name, address: address), kind: kind, response: answer)
        }
        return result
    }

    static func rgb(_ color: CGColor?) -> UInt32? {
        guard let color, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: space, intent: .defaultIntent, options: nil),
              let parts = converted.components, parts.count >= 3 else { return nil }
        func byte(_ value: CGFloat) -> UInt32 { UInt32(max(0, min(1, value)) * 255 + 0.5) }
        return byte(parts[0]) << 16 | byte(parts[1]) << 8 | byte(parts[2])
    }

    static func address(of person: EKParticipant) -> String? {
        let url = person.url
        guard url.scheme?.lowercased() == "mailto" else { return nil }
        let text = url.absoluteString.dropFirst("mailto:".count)
        return String(text).removingPercentEncoding
    }

    static func reminder(_ reminder: EKReminder) -> DueReminder? {
        guard let components = reminder.dueDateComponents,
              let due = Calendar.current.date(from: components) else { return nil }
        return DueReminder(id: reminder.calendarItemIdentifier,
                           title: (reminder.title ?? "").isEmpty ? String(localized: "Untitled reminder") : reminder.title,
                           due: due, hasTime: components.hour != nil, isDone: reminder.isCompleted,
                           list: reminder.calendar?.title)
    }
    #endif
}
