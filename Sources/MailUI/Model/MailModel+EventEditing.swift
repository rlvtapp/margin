import Foundation
import MailCore

/// A calendar new events can go in: one of this device's, or a connected mailbox's own calendar.
public enum EventDestination: Hashable, Identifiable, Sendable {
    case device(identifier: String, title: String, color: UInt32?)
    case account(UUID)

    public var id: String {
        switch self {
        case .device(let identifier, _, _): "device:" + identifier
        case .account(let id): "account:" + id.uuidString
        }
    }
}

/// For a repeating event: change only this one, or every one.
public enum EventScope: Sendable {
    case thisEvent, allEvents

    func repeatScope(for item: AgendaItem) -> RepeatScope {
        self == .allEvents && item.repeats ? .allEvents(occurrenceStart: item.start) : .thisEvent
    }
}

/// Making, changing and deleting events from the Calendar (docs/calendar.md). Each change goes to
/// the calendar the event lives in: this device's Calendar app through EventKit, Microsoft 365 or
/// Google through their own APIs (which tell the guests). Invitations only known from the mail
/// can't be changed, only answered. The page changes at once; if the calendar refuses, it goes
/// back and says why. Every change can be undone.
extension MailModel {
    /// Where new events can go: this device's writable calendars (when the Calendar app is
    /// shown), then each mailbox whose calendar is connected.
    public var eventDestinations: [EventDestination] {
        var result: [EventDestination] = []
        if showsDeviceCalendar {
            let calendars = environment.isPreview ? deviceCalendars.filter(\.allowsChanges) : DeviceCalendar.shared.writableCalendars()
            result += calendars.map { .device(identifier: $0.identifier ?? $0.title, title: $0.title, color: $0.color) }
        }
        result += accounts.filter { usesAccountCalendar($0) || (environment.isPreview && $0.connection == .sample) }.map { .account($0.id) }
        return result
    }

    /// The calendar a new event goes in: the one used last, else the device's default.
    public var defaultEventDestination: EventDestination? {
        let all = eventDestinations
        if let last = environment.defaults.string(forKey: "calendar.newEventsIn"), let found = all.first(where: { $0.id == last }) {
            return found
        }
        if let identifier = environment.isPreview ? nil : DeviceCalendar.shared.defaultCalendarIdentifier(),
           let found = all.first(where: { if case .device(identifier, _, _) = $0 { true } else { false } }) {
            return found
        }
        return all.first
    }

    public func title(of destination: EventDestination) -> String {
        switch destination {
        case .device(_, let title, _): title
        case .account(let id): account(id)?.address.address ?? ""
        }
    }

    public func colorIndex(of destination: EventDestination) -> Int {
        switch destination {
        case .device(_, _, let color): color.map(Palette.nearestAccountIndex(to:)) ?? 0
        case .account(let id): account(id)?.colorIndex ?? 0
        }
    }

    /// The meeting as a draft, to edit it.
    public func draft(of item: AgendaItem) -> EventDraft {
        EventDraft(title: item.title, start: item.start, end: item.end, isAllDay: item.isAllDay,
                   location: item.location ?? "", notes: item.notes, videoCall: item.joinURL != nil)
    }

    // MARK: Making

    /// Makes an event. Returns whether the calendar took it.
    @discardableResult
    public func createEvent(_ draft: EventDraft, in destination: EventDestination) async -> Bool {
        environment.defaults.set(destination.id, forKey: "calendar.newEventsIn")
        guard !environment.isPreview else {
            addLocally(draft, in: destination)
            return true
        }
        var made = Self.normalized(draft)
        do {
            switch destination {
            case .device(let identifier, _, _):
                made.calendar = identifier
                _ = try await DeviceCalendar.shared.addEvent(made, notify: true)
            case .account(let id):
                made.calendar = nil
                _ = try await writer(for: id).addEvent(made, notify: true)
            }
        } catch {
            show(error)
            return false
        }
        await reloadCalendars()
        offerUndo(String(localized: "Added “\(draft.title)”")) { [weak self] in
            guard let self, let made = self.agenda(from: draft.start.addingTimeInterval(-1), to: draft.end.addingTimeInterval(1))
                .first(where: { $0.title == draft.title && $0.start == draft.start && $0.canChange }) else { return }
            await self.deleteEvent(made, offersUndo: false)
        }
        return true
    }

    // MARK: Changing

    /// Whether an event can be changed or deleted here.
    public func canChange(_ item: AgendaItem) -> Bool {
        if case .invite = item.source { return false }
        return item.canChange
    }

    /// Whether it can be deleted: your own events, and someone else's meeting, which is
    /// declined (the organizer is told) and so leaves your calendar.
    public func canDelete(_ item: AgendaItem) -> Bool {
        canChange(item) || (item.canAnswer && item.organizer != nil)
    }

    /// Changes an event: moved, resized or edited. The page shows the change at once.
    @discardableResult
    public func updateEvent(_ item: AgendaItem, with draft: EventDraft, scope: EventScope = .thisEvent, offersUndo: Bool = true) async -> Bool {
        guard canChange(item) else { return false }
        let before = self.draft(of: item)
        changeLocally(item, to: draft)
        guard !environment.isPreview else { return true }
        do {
            let changes = Self.changes(from: before, to: draft)
            switch item.source {
            case .device(let eventID):
                _ = try await DeviceCalendar.shared.updateEvent(id: eventID, changes, scope: scope.repeatScope(for: item), notify: true)
            case .account(let accountID, let eventID):
                _ = try await writer(for: accountID).updateEvent(id: eventID, changes, scope: scope.repeatScope(for: item), notify: true)
            case .invite:
                return false
            }
        } catch {
            changeLocally(item.moved(to: draft), to: before)
            show(error)
            return false
        }
        await reloadCalendars()
        if offersUndo {
            let moved = draft.start != before.start || draft.end != before.end
            let text = moved ? String(localized: "Moved “\(draft.title)”") : String(localized: "Changed “\(draft.title)”")
            offerUndo(text) { [weak self] in
                guard let self, let now = self.agenda(from: draft.start.addingTimeInterval(-1), to: draft.end.addingTimeInterval(1))
                    .first(where: { $0.title == draft.title && $0.start == draft.start && $0.canChange }) else { return }
                await self.updateEvent(now, with: before, scope: scope, offersUndo: false)
            }
        }
        return true
    }

    // MARK: Deleting

    @discardableResult
    public func deleteEvent(_ item: AgendaItem, scope: EventScope = .thisEvent, offersUndo: Bool = true) async -> Bool {
        if !canChange(item), canDelete(item) {
            // Someone else's meeting: deleting it is declining it.
            await respond(to: item, with: .declined)?.value
            return true
        }
        guard canChange(item) else { return false }
        let before = draft(of: item)
        let destination = destination(of: item)
        removeLocally(item)
        guard !environment.isPreview else { return true }
        do {
            switch item.source {
            case .device(let eventID):
                try await DeviceCalendar.shared.deleteEvent(id: eventID, scope: scope.repeatScope(for: item), notify: true)
            case .account(let accountID, let eventID):
                try await writer(for: accountID).deleteEvent(id: eventID, scope: scope.repeatScope(for: item), notify: true)
            case .invite:
                return false
            }
        } catch {
            await reloadCalendars()
            show(error)
            return false
        }
        await reloadCalendars()
        // A deleted series can't come back as it was; one event can.
        if offersUndo, !(item.repeats && scope == .allEvents), let destination {
            offerUndo(String(localized: "Deleted “\(item.title)”")) { [weak self] in
                await self?.createEvent(before, in: destination)
            }
        } else {
            notice = Notice(text: String(localized: "Deleted “\(item.title)”"))
        }
        return true
    }

    /// The calendar an event is in, to put it back there.
    func destination(of item: AgendaItem) -> EventDestination? {
        switch item.source {
        case .account(let id, _): return .account(id)
        case .invite: return nil
        case .device:
            return eventDestinations.first { destination in
                if case .device(_, let title, _) = destination { title == item.calendarName } else { false }
            }
        }
    }

    /// The video call service events in this calendar can get (“Microsoft Teams”, “Google Meet”),
    /// nil for this device's calendars, which can't make calls. Asked once per mailbox.
    public func videoCallService(for destination: EventDestination) async -> String? {
        guard case .account(let id) = destination else { return nil }
        if environment.isPreview { return account(id).map { oauthProvider(of: $0) == .google } == true ? "Google Meet" : "Microsoft Teams" }
        if let known = videoCallServices[id] { return known }
        let service = try? await writer(for: id).videoCallService()
        videoCallServices[id] = service
        return service
    }

    // MARK: Helpers

    /// All-day events end at midnight after their last day, as calendars count them.
    static func normalized(_ draft: EventDraft) -> EventDraft {
        guard draft.isAllDay else { return draft }
        let calendar = Calendar.current
        var copy = draft
        copy.start = calendar.startOfDay(for: draft.start)
        let lastDay = calendar.startOfDay(for: max(copy.start, draft.end.addingTimeInterval(-1)))
        copy.end = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay.addingTimeInterval(86_400)
        return copy
    }

    /// Only what changed, so the rest of the event (and what Margin can't see of it) stays.
    static func changes(from before: EventDraft, to after: EventDraft) -> EventChanges {
        let old = normalized(before), new = normalized(after)
        let retimed = old.start != new.start || old.end != new.end || old.isAllDay != new.isAllDay
        return EventChanges(title: old.title == new.title ? nil : new.title,
                            start: retimed ? new.start : nil, end: retimed ? new.end : nil,
                            location: (old.location ?? "") == (new.location ?? "") ? nil : new.location,
                            notes: new.notes == nil || old.notes == new.notes ? nil : new.notes,
                            isAllDay: new.isAllDay, addVideoCall: new.videoCall && !old.videoCall)
    }

    private func writer(for accountID: UUID) async throws -> any CalendarWriting {
        guard let account = account(accountID),
              let writer = try await calendarAdapter(for: account) as? any CalendarWriting else {
            throw CalendarWritingError.readOnly
        }
        return writer
    }

    /// Reads the calendars again around the change, so the page shows what the calendar has.
    private func reloadCalendars() async {
        let middle = calendarEventsRange.map { $0.lowerBound.addingTimeInterval($0.upperBound.timeIntervalSince($0.lowerBound) / 2) } ?? Date()
        await refreshCalendar(around: middle, force: true)
    }

    private func offerUndo(_ text: String, _ action: @escaping () async -> Void) {
        calendarUndo = action
        notice = Notice(text: text, undo: .calendar)
    }

    private func changeLocally(_ item: AgendaItem, to draft: EventDraft) {
        func apply(_ event: inout CalendarEvent) {
            event.title = draft.title
            event.start = draft.start
            event.end = draft.isAllDay ? max(draft.end, Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: draft.start)) ?? draft.end) : draft.end
            event.isAllDay = draft.isAllDay
            if let location = draft.location { event.location = location.isEmpty ? nil : location }
            if let notes = draft.notes { event.notes = notes }
        }
        switch item.source {
        case .device(let id):
            if let index = deviceEvents.firstIndex(where: { $0.id == id }) { apply(&deviceEvents[index]) }
        case .account(let accountID, let id):
            if var events = calendarEvents[accountID], let index = events.firstIndex(where: { $0.id == id }) {
                apply(&events[index])
                calendarEvents[accountID] = events
            }
        case .invite:
            break
        }
    }

    private func removeLocally(_ item: AgendaItem) {
        switch item.source {
        case .device(let id): deviceEvents.removeAll { $0.id == id }
        case .account(let accountID, let id): calendarEvents[accountID]?.removeAll { $0.id == id }
        case .invite: break
        }
    }

    /// In previews and snapshots: the event goes straight into the sample calendars.
    private func addLocally(_ draft: EventDraft, in destination: EventDestination) {
        var event = CalendarEvent(id: DeviceCalendar.idPrefix + UUID().uuidString, title: draft.title, start: draft.start,
                                  end: draft.end, isAllDay: draft.isAllDay, location: draft.location, isOrganizer: true)
        event.canChange = true
        event.notes = draft.notes
        if draft.videoCall { event.joinURL = URL(string: "https://meet.example.com/new") }
        switch destination {
        case .device(_, let title, let color):
            event.calendarName = title
            event.calendarColor = color
            deviceEvents.append(event)
        case .account(let id):
            event.id = UUID().uuidString
            calendarEvents[id, default: []].append(event)
        }
    }
}

extension AgendaItem {
    /// The same item at the draft's time, to find it again after a change.
    func moved(to draft: EventDraft) -> AgendaItem {
        var copy = self
        copy.start = draft.start
        copy.end = draft.end
        copy.title = draft.title
        return copy
    }
}
