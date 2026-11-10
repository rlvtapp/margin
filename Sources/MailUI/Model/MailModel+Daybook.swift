import Foundation
import MailCore
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Working with Daybook, the calendar app, when it's installed (docs/daybook.md): invitations
/// and meetings open there, New Meeting can hand over to it, and Daybook's Email Guests and
/// Show Invitation Email open here.
extension MailModel {
    /// Whether Daybook is installed on this device.
    public var hasDaybook: Bool {
        _ = clockTick
        guard let probe = URL(string: "daybook://") else { return false }
        #if canImport(AppKit)
        return NSWorkspace.shared.urlForApplication(toOpen: probe) != nil
        #elseif canImport(UIKit)
        return UIApplication.shared.canOpenURL(probe)
        #else
        return false
        #endif
    }

    func openInDaybook(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #elseif canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }

    /// An invitation in Daybook: the meeting if Daybook has it, otherwise its day and an offer to add it.
    public func openInDaybook(_ invite: CalendarInvite) {
        openInDaybook(DaybookLink.event(uid: invite.uid, start: invite.start, ics: invite.raw))
    }

    public func openInDaybook(_ event: CalendarEntry) {
        openInDaybook(DaybookLink.event(uid: event.id, start: event.start))
    }

    /// A meeting being written here, carried over to Daybook to find a time and send it there.
    public func openNewMeetingInDaybook(title: String, start: Date, end: Date, attendees: [EmailAddress],
                                        location: String?, notes: String) {
        openInDaybook(DaybookLink.new(title: title, start: start, end: end, attendees: attendees.map(\.address),
                                      location: location, notes: notes))
    }

    /// `margin://compose` and `margin://invite` from Daybook.
    func openMarginLink(_ url: URL) -> Bool {
        guard let link = MarginLink(url) else { return false }
        switch link {
        case .compose:
            if let mailto = link.mailto { startCompose(mailto: mailto) }
        case .invite(let uid):
            if let thread = calendarEntries.first(where: { $0.id == uid && !$0.threadID.isEmpty })?.threadID {
                reveal(thread)
            } else {
                notice = Notice(text: String(localized: "Margin doesn't have the email for that invitation."))
            }
        }
        return true
    }
}
