import Foundation
import MailCore

/// Meetings through each account's calendar adapter: Microsoft 365 or Google when connected,
/// otherwise an invitation by email that any calendar understands.
extension MailModel {
    /// Whether meetings from this account go through its own calendar.
    public func usesAccountCalendar(_ account: MailAccount) -> Bool {
        oauthProvider(of: account) != nil && apiAccess[account.id]?.contains(.calendar) == true
    }

    /// Whether the account has been allowed to look for rooms.
    public func canListRooms(_ account: MailAccount) -> Bool {
        usesAccountCalendar(account) && apiAccess[account.id]?.contains(.rooms) == true
    }

    /// The calendar for an account: its provider's, or invitations by email.
    func calendarAdapter(for account: MailAccount) async throws -> any CalendarAdapter {
        if usesAccountCalendar(account) {
            let token = try await credentials.apiToken(for: account)
            switch oauthProvider(of: account) {
            case .microsoft: return MicrosoftGraphClient(accessToken: token)
            case .google: return GoogleCalendarClient(accessToken: token)
            case nil: break
            }
        }
        let mail = try provider(for: account)
        return EmailCalendar(organizer: account.address) { try await mail.send($0) }
    }

    /// The organization's meeting rooms.
    public func meetingRooms(for account: MailAccount) async throws -> [MeetingRoom] {
        try await calendarAdapter(for: account).rooms()
    }

    /// When each address (people or rooms) is taken between `start` and `end`.
    public func busyTimes(for emails: [String], from start: Date, to end: Date,
                          account: MailAccount) async throws -> [String: [BusyTime]] {
        guard !emails.isEmpty else { return [:] }
        return try await calendarAdapter(for: account).busyTimes(for: emails, from: start, to: end)
    }

    /// Sends the meeting and remembers it, with everyone waiting to answer.
    public func sendMeeting(_ meeting: MeetingRequest, from account: MailAccount) async throws {
        try await calendarAdapter(for: account).createEvent(meeting)
        let place = meeting.rooms.isEmpty ? meeting.location : meeting.rooms.map(\.name).joined(separator: ", ")
        var entry = CalendarEntry(id: meeting.uid, title: meeting.title, start: meeting.start, end: meeting.end, isAllDay: false,
                                  location: place, joinURL: meeting.location.flatMap { CalendarInvite.meetingLink(in: $0) },
                                  organizer: account.address.displayName, threadID: "", cancelled: false)
        entry.accountID = account.id
        entry.isMine = true
        entry.attendees = meeting.attendees.map { MeetingAttendee(address: $0) }
            + meeting.rooms.map { MeetingAttendee(address: EmailAddress(name: $0.name, address: $0.email), kind: .room) }
        saveCalendar(calendarEntries + [entry])
        notice = Notice(text: String(localized: "Invitation sent"))
    }

    /// Opens a meeting: its message, or for one sent from here, the meeting on its own.
    public func open(_ event: CalendarEntry) {
        if hasDaybook { openInDaybook(event) } else if event.threadID.isEmpty { shownMeetingID = event.id } else { reveal(event.threadID) }
    }

    /// Asks the account's calendar for the latest answers, when it can tell.
    public func refreshAnswers(_ id: CalendarEntry.ID) async {
        guard let entry = calendarEntries.first(where: { $0.id == id }), let account = account(entry.accountID),
              usesAccountCalendar(account),
              let found = try? await calendarAdapter(for: account).attendees(ofEventWithUID: id) else { return }
        var entries = calendarEntries
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let updated = entries[index].attendees.updating(with: found)
        guard updated != entries[index].attendees else { return }
        entries[index].attendees = updated
        saveCalendar(entries)
    }
}
