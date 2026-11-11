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
    /// The starter group bills sort into (its name doesn't change).
    static let billsGroupName = EmailGroup.starters[3].name

    /// The note for a conversation, most important reason first; nil when nothing calls for one.
    public func marginNote(for thread: MailThread, now: Date = Date()) -> MarginNote? {
        // Every Home row, the Home header and the account column ask for notes on each redraw;
        // they're worked out once and kept until something they depend on changes.
        let key = marginNoteKey(now: now)
        if marginNoteCache?.key != key { marginNoteCache = (key, [:]) }
        let threadKey = "\(thread.accountID?.uuidString ?? "-")|\(thread.id)|\(thread.latest.id)|\(thread.latest.flags.rawValue)"
        if let known = marginNoteCache?.notes[threadKey] { return known }
        let note = computeMarginNote(for: thread, now: now)
        marginNoteCache?.notes[threadKey] = .some(note)
        return note
    }

    /// Changes whenever anything a note depends on does: the minute (meeting times, "owed 3d"),
    /// Sent, meetings, labels and groups, rules, contacts, and message bodies (sign-in codes).
    private func marginNoteKey(now: Date) -> Int {
        var hasher = Hasher()
        hasher.combine(Int(now.timeIntervalSince1970 / 60))
        hasher.combine(sentMail.values.reduce(0) { $0 + $1.count })
        hasher.combine(sentMail.values.compactMap { $0.last?.id })
        hasher.combine(calendarEntries.count)
        hasher.combine(calendarEntries.first?.id)
        hasher.combine(rsvps.count)
        hasher.combine(sortingRevision)
        hasher.combine(priorityRevision)
        hasher.combine(labelStore.labelsByThread.count)
        hasher.combine(labelStore.labelsByThread.values.reduce(0) { $0 + $1.count })
        hasher.combine(contacts.count)
        hasher.combine(bodies.count)
        return hasher.finalize()
    }

    private func computeMarginNote(for thread: MailThread, now: Date) -> MarginNote? {
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
        if let group = group(of: thread), group.name == Self.billsGroupName {
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
        // Answered from anywhere (another app, the web, another device): your reply is in Sent,
        // even when the server doesn't mark their message as answered.
        guard !answeredInSent(thread) else { return false }
        return isFromSomeoneYouKnow(thread)
    }

    /// Whether something you sent answers the conversation's latest message: a reply to it by
    /// its headers, or, when the headers were lost, a message to them with the same subject
    /// sent after it. A lookup in `sentIndex`, so it's cheap for every row on every redraw.
    func answeredInSent(_ thread: MailThread) -> Bool {
        let latest = thread.latest
        let index = sentIndex
        if let id = latest.messageID, index.repliedTo.contains(id) { return true }
        let key = SentIndex.key(subject: latest.subject, to: latest.from.address)
        if let sent = index.latestTo[key], sent > latest.date { return true }
        return false
    }

    /// Sent mail, indexed: every message ID it replies to, and the newest send per subject and
    /// recipient. Rebuilt only when `sentMail` changes.
    var sentIndex: SentIndex {
        if let sentIndexCache { return sentIndexCache }
        let built = SentIndex(sentMail.values.joined())
        sentIndexCache = built
        return built
    }

    /// How many conversations on Home have a note: what needs you.
    public var needYouCount: Int { needsYou().count }

    /// The conversations on Home that have a note, newest first, each with its note: all
    /// inboxes, not snoozed. `only` narrows them (AI apps don't see hidden mailboxes).
    public func needsYou(now: Date = Date(), only: ((MailThread) -> Bool)? = nil) -> [(thread: MailThread, note: MarginNote)] {
        allInboxesThreads(nil).compactMap { thread in
            guard !isSnoozed(thread), only?(thread) ?? true, let note = marginNote(for: thread, now: now) else { return nil }
            return (thread, note)
        }
    }

    /// "Two replies to write and a bill to open. Quarterly planning at 10:00." Or, with
    /// nothing waiting, "Nothing needs you right now." The line under Home's date.
    public func homeSummary(now: Date = Date(), only: ((MailThread) -> Bool)? = nil) -> String {
        var parts: [String] = []
        let owed = allInboxesThreads(nil).filter { !isSnoozed($0) && (only?($0) ?? true) && owesReply($0, now: now) }.count
        if owed > 0 { parts.append(owed == 1 ? String(localized: "a reply to write") : String(localized: "\(owed) replies to write")) }
        let bills = unopenedBills.filter { only?($0) ?? true }.count
        if bills > 0 { parts.append(bills == 1 ? String(localized: "a bill to open") : String(localized: "\(bills) bills to open")) }
        var sentence = parts.isEmpty ? "" : parts.formatted(.list(type: .and))
        if !sentence.isEmpty { sentence = sentence.prefix(1).uppercased() + sentence.dropFirst() + "." }
        if let next = todaysEvents.first(where: { !$0.isAllDay && $0.finish > now }) {
            let time = next.start.formatted(date: .omitted, time: .shortened)
            let line = next.start <= now ? String(localized: "\(next.title) is on now.") : String(localized: "\(next.title) at \(time).")
            sentence = sentence.isEmpty ? line : sentence + " " + line
        }
        return sentence.isEmpty ? String(localized: "Nothing needs you right now.") : sentence
    }

    /// "Monday 9 November", for the top of Home.
    public var homeDate: String {
        Date().formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

/// Sent mail reduced to what "have I answered this?" needs.
struct SentIndex {
    var repliedTo: Set<String> = []
    var latestTo: [String: Date] = [:]

    init<S: Sequence>(_ messages: S) where S.Element == MailMessage {
        for message in messages {
            if let parent = message.inReplyTo { repliedTo.insert(parent) }
            repliedTo.formUnion(message.references)
            for recipient in message.to + message.cc {
                let key = Self.key(subject: message.subject, to: recipient.address)
                if let known = latestTo[key], known >= message.date { continue }
                latestTo[key] = message.date
            }
        }
    }

    static func key(subject: String, to address: String) -> String {
        Subject.normalized(subject) + "|" + address.lowercased()
    }
}
