import Foundation
import MailCore
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The calendars and reminders already on this device, in the Calendar view (docs/calendar.md):
/// shown once you turn them on and allow it. Events can be made, moved and changed here;
/// reminders can be ticked done.
extension MailModel {
    /// Turns the device's calendars on or off in the Calendar. Turning on asks for access the
    /// first time; when it was refused, System Settings opens instead.
    public func setShowsDeviceCalendar(_ on: Bool) async {
        if on, !environment.isPreview {
            guard await allow(DeviceCalendar.eventAccess(), request: { try await DeviceCalendar.shared.requestEvents() }) else { return }
        }
        showsDeviceCalendar = on
        environment.defaults.set(on, forKey: "calendar.device")
        if !on {
            deviceEvents = []
            deviceCalendars = []
        }
        deviceCalendarRange = nil
        await refreshDeviceCalendar(around: Date(), force: true)
    }

    public func setShowsReminders(_ on: Bool) async {
        if on, !environment.isPreview {
            guard await allow(DeviceCalendar.reminderAccess(), request: { try await DeviceCalendar.shared.requestReminders() }) else { return }
        }
        showsReminders = on
        environment.defaults.set(on, forKey: "calendar.reminders")
        if !on { dueReminders = [] }
        deviceCalendarRange = nil
        await refreshDeviceCalendar(around: Date(), force: true)
    }

    private func allow(_ access: DeviceAccess, request: () async throws -> Bool) async -> Bool {
        switch access {
        case .allowed: return true
        case .refused:
            openPrivacySettings()
            return false
        case .notAsked:
            do {
                if try await request() { return true }
                notice = Notice(text: String(localized: "Margin wasn't allowed to see them. You can change that in System Settings → Privacy & Security."), isError: true)
            } catch {
                show(error)
            }
            return false
        }
    }

    /// Where calendar access is changed.
    func openPrivacySettings() {
        #if canImport(AppKit)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") { NSWorkspace.shared.open(url) }
        #elseif canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #endif
    }

    /// Reads the device's events and reminders around a day (its month, a week either side),
    /// and keeps them up to date while the Calendar app or Reminders change them.
    func refreshDeviceCalendar(around day: Date, force: Bool = false) async {
        guard showsDeviceCalendar || showsReminders, !environment.isPreview else { return }
        let calendar = Calendar.current
        let month = calendar.dateInterval(of: .month, for: day) ?? DateInterval(start: day, duration: 31 * 86_400)
        let start = calendar.date(byAdding: .day, value: -7, to: month.start) ?? month.start
        let end = calendar.date(byAdding: .day, value: 14, to: month.end) ?? month.end
        if !force, let range = deviceCalendarRange, range.contains(start), range.contains(end) { return }
        watchDeviceCalendar()
        let device = DeviceCalendar.shared
        let showsEvents = showsDeviceCalendar, showsDue = showsReminders
        async let events = Task.detached { showsEvents ? device.events(from: start, to: end) : [] }.value
        // Overdue ones too, from a month back.
        let overdueFrom = calendar.date(byAdding: .month, value: -1, to: calendar.startOfDay(for: Date())) ?? start
        async let reminders = showsDue ? device.reminders(from: min(start, overdueFrom), to: end) : []
        deviceEvents = await events
        deviceCalendars = showsEvents ? device.calendars() : []
        dueReminders = await reminders
        deviceCalendarRange = start...end
        Self.calendarLog.info("device calendar: \(self.deviceEvents.count, privacy: .public) events, \(self.dueReminders.count, privacy: .public) reminders")
    }

    private func watchDeviceCalendar() {
        guard deviceCalendarWatcher == nil else { return }
        deviceCalendarWatcher = NotificationCenter.default.addObserver(forName: DeviceCalendar.changed, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let range = self.deviceCalendarRange else { return }
                let middle = range.lowerBound.addingTimeInterval(range.upperBound.timeIntervalSince(range.lowerBound) / 2)
                await self.refreshDeviceCalendar(around: middle, force: true)
            }
        }
    }

    /// Reminders due on a day, or overdue ones on today, soonest first.
    public func reminders(on day: Date) -> [DueReminder] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let isToday = calendar.isDate(day, inSameDayAs: today)
        guard isCalendarShown(Self.remindersKey) else { return [] }
        return dueReminders.filter { reminder in
            calendar.isDate(reminder.due, inSameDayAs: day) || (isToday && !reminder.isDone && reminder.due < today)
        }
    }

    /// Ticks a reminder done here and in Reminders. It stays on the page, ticked, until the next
    /// refresh, so a slip can be undone.
    public func setDone(_ done: Bool, reminder: DueReminder) {
        guard let index = dueReminders.firstIndex(where: { $0.id == reminder.id }) else { return }
        dueReminders[index].isDone = done
        guard !environment.isPreview else { return }
        do {
            try DeviceCalendar.shared.setDone(done, reminder: reminder.id)
        } catch {
            dueReminders[index].isDone = !done
            show(error)
        }
    }

    /// Shows an event from this device in the Calendar app.
    public func openInCalendarApp(_ item: AgendaItem) {
        #if canImport(AppKit)
        if let identifier = DeviceCalendar.eventIdentifier(in: item.eventID),
           let encoded = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/:"))),
           let url = URL(string: "ical://ekevent/\(encoded)?method=show&options=more") {
            NSWorkspace.shared.open(url)
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.open(url)
        }
        #elseif canImport(UIKit)
        // The Calendar app opens on the day; it has no link to one event.
        if let url = URL(string: "calshow:\(item.start.timeIntervalSinceReferenceDate)") { UIApplication.shared.open(url) }
        #endif
    }

    /// Opens a reminder in the Reminders app.
    public func openInReminders(_ reminder: DueReminder) {
        guard let url = URL(string: "x-apple-reminderkit://REMCDReminder/\(reminder.id)") else { return }
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #elseif canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }

    /// Sample events and reminders from "this device", for screenshots and previews.
    func addSampleDeviceCalendar(today: Date) {
        let calendar = Calendar.current
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(byAdding: .minute, value: (day * 24 + hour) * 60 + minute, to: today) ?? today
        }
        func event(_ id: String, _ title: String, _ start: Date, _ end: Date, calendar name: String, allDay: Bool = false) -> CalendarEvent {
            var event = CalendarEvent(id: DeviceCalendar.idPrefix + id, title: title, start: start, end: end, isAllDay: allDay, isOrganizer: true)
            event.calendarName = name
            event.calendarColor = deviceCalendars.first { $0.title == name }?.color
            event.canChange = name != "Birthdays"
            return event
        }
        showsDeviceCalendar = true
        showsReminders = true
        deviceCalendars = [
            DeviceCalendarInfo(title: "Personal", source: "iCloud", color: 0x34C759, identifier: "personal"),
            DeviceCalendarInfo(title: "Work", source: "iCloud", color: 0xFF9500, identifier: "work"),
            DeviceCalendarInfo(title: "Birthdays", source: "Other", color: 0x8E8E93, identifier: "birthdays", allowsChanges: false),
        ]
        deviceEvents = [
            event("d1", "Gym", at(0, 7, 30), at(0, 8, 30), calendar: "Personal"),
            event("d2", "Lunch with Maya", at(0, 12, 30), at(0, 13, 30), calendar: "Personal"),
            event("d3", "Focus time", at(1, 8, 30), at(1, 10), calendar: "Work"),
            event("d4", "Dentist", at(2, 16), at(2, 17), calendar: "Personal"),
            event("d5", "Leo's birthday", at(4, 0), at(5, 0), calendar: "Birthdays", allDay: true),
        ]
        dueReminders = [
            DueReminder(id: "r1", title: "Send the signed contract", due: at(0, 17), hasTime: true, list: "Work"),
            DueReminder(id: "r2", title: "Book flights for Lisbon", due: at(1, 0), hasTime: false, list: "Personal"),
        ]
        deviceCalendarRange = at(-40, 0)...at(60, 0)
    }
}
