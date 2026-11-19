import Foundation
#if canImport(EventKit)
import EventKit
#endif

/// Adding reminders to the Reminders app, for AI apps connected to Margin.
extension DeviceCalendar {
    /// The Reminders lists new reminders can go in.
    public func reminderLists() -> [String] {
        #if canImport(EventKit)
        guard Self.reminderAccess() == .allowed else { return [] }
        return store.calendars(for: .reminder).filter(\.allowsContentModifications).map(\.title)
        #else
        []
        #endif
    }

    /// Adds a reminder to a list (the default one when nil), due on a day or at a time.
    public func addReminder(title: String, due: Date?, hasTime: Bool, list: String?) throws -> DueReminder? {
        #if canImport(EventKit)
        guard Self.reminderAccess() == .allowed else { throw CalendarWritingError.readOnly }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        let lists = store.calendars(for: .reminder).filter(\.allowsContentModifications)
        if let list {
            guard let found = lists.first(where: { $0.title.caseInsensitiveCompare(list) == .orderedSame }) else { throw CalendarWritingError.notFound }
            reminder.calendar = found
        } else {
            reminder.calendar = store.defaultCalendarForNewReminders()
        }
        if let due {
            let parts: Set<Calendar.Component> = hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
            reminder.dueDateComponents = Calendar.current.dateComponents(parts, from: due)
        }
        try store.save(reminder, commit: true)
        return due == nil ? nil : Self.reminder(reminder)
        #else
        throw CalendarWritingError.readOnly
        #endif
    }
}
