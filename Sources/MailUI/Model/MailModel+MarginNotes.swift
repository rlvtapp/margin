import Foundation
import MailCore

/// Home's margin notes: one short line beside a conversation saying why it matters now
/// ("reply owed", "at 15:00", "bill"). Home leads with these instead of a greeting.
public struct MarginNote: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case reply, meeting, bill, code }
    public var kind: Kind
    public var text: String
}

extension MailModel {
    /// The note for a conversation, most important reason first; nil when nothing calls for one.
    public func marginNote(for thread: MailThread, now: Date = Date()) -> MarginNote? {
        if signInCode(in: thread) != nil { return MarginNote(kind: .code, text: String(localized: "code")) }
        if let event = calendarEntries.first(where: { $0.threadID == thread.id && !$0.cancelled && $0.finish > now }) {
            let calendar = Calendar.current
            let time = event.start.formatted(date: .omitted, time: .shortened)
            let text: String = if event.start <= now {
                String(localized: "now")
            } else if calendar.isDateInToday(event.start) {
                String(localized: "at \(time)")
            } else {
                event.start.formatted(.dateTime.weekday(.abbreviated)) + " " + time
            }
            return MarginNote(kind: .meeting, text: text)
        }
        if let group = group(of: thread), group.name == EmailGroup.starters[3].name {
            return MarginNote(kind: .bill, text: String(localized: "bill"))
        }
        if owesReply(thread, now: now) {
            let days = Calendar.current.dateComponents([.day], from: thread.latest.date, to: now).day ?? 0
            return MarginNote(kind: .reply, text: days >= 2 ? String(localized: "owed \(days)d") : String(localized: "reply owed"))
        }
        return nil
    }

    /// The last word is someone else's, a person you know, in the last three weeks, and you
    /// haven't answered.
    func owesReply(_ thread: MailThread, now: Date = Date()) -> Bool {
        let latest = thread.latest
        guard thread.split == .people, !isMine(latest), !latest.flags.contains(.answered),
              now.timeIntervalSince(latest.date) < 21 * 86_400 else { return false }
        return isFromSomeoneYouKnow(thread)
    }

    /// How many conversations on Home have a note: what needs you.
    public var needYouCount: Int {
        allInboxesThreads(nil).filter { !isSnoozed($0) && marginNote(for: $0) != nil }.count
    }

    /// "Monday 9 November", for the top of Home.
    public var homeDate: String {
        Date().formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}
