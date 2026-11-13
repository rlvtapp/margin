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

    /// How far back a conversation can still "need you" because of its date: a reply is owed
    /// for three weeks, and a sign-in code older than that is no use to anyone. Meetings and
    /// bills count at any age. It's also what keeps "needs you" from reading the whole mailbox:
    /// only mail this recent is looked at, plus the conversations with a meeting or a bill.
    static let noteHorizon: TimeInterval = 21 * 86_400

    /// The note for a conversation, most important reason first; nil when nothing calls for one.
    public func marginNote(for thread: MailThread, now: Date = Date()) -> MarginNote? {
        // Every Home row, the Home header and the account column ask for notes on each redraw;
        // they're worked out once and kept until something they depend on changes.
        marginNote(for: thread, now: now, key: marginNoteKey(now: now))
    }

    /// The note for a conversation, with the cache key already worked out: asking for the notes
    /// of many conversations (the "needs you" count in the account column does, on each redraw)
    /// works the key out once, not once per conversation. A kept note is found by the
    /// conversation's id alone, and holds as long as its newest message and that message's
    /// flags are the same.
    private func marginNote(for thread: MailThread, now: Date, key: Int) -> MarginNote? {
        _ = noteRevision
        if marginNoteCache?.key != key { marginNoteCache = (key, [:]) }
        let latest = thread.latest
        if let known = marginNoteCache?.notes[thread.id], known.flags == latest.flags.rawValue, known.latest == latest.id {
            return known.note
        }
        let note = computeMarginNote(for: thread, now: now)
        marginNoteCache?.notes[thread.id] = KeptNote(latest: latest.id, flags: latest.flags.rawValue, note: note)
        return note
    }

    /// A message's text arrived: a sign-in code may be in it, so the conversation's note is
    /// worked out again.
    func forgetNote(of threadID: String) {
        guard marginNoteCache?.notes[threadID] != nil else { return }
        marginNoteCache?.notes[threadID] = nil
        noteRevision &+= 1
    }

    /// Changes whenever anything a note depends on does: the minute (meeting times, "owed 3d"),
    /// Sent, meetings, labels and groups, rules and contacts. (A message's text arriving is
    /// told to the one conversation it belongs to: `forgetNote`.)
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
        hasher.combine(labelStore.revision)
        hasher.combine(contacts.count)
        return hasher.finalize()
    }

    private func computeMarginNote(for thread: MailThread, now: Date) -> MarginNote? {
        if now.timeIntervalSince(thread.latest.date) < Self.noteHorizon, signInCode(in: thread) != nil {
            return MarginNote(kind: .code, text: String(localized: "code"))
        }
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
        // In the Bills group, but only a bill to act on when it asks you to pay: an invoice
        // that's taken automatically, or a receipt, needs nothing.
        if let group = group(of: thread), group.name == Self.billsGroupName,
           MailNotice.asksForPayment(subject: thread.latest.subject, text: latestText(of: thread)) {
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
        guard !answeredInSent(thread), isFromSomeoneYouKnow(thread) else { return false }
        // A reminder, confirmation or receipt from someone you know still asks nothing. Read
        // last, as the costliest check, only for mail that passed the rest.
        return !MailNotice.expectsNoReply(subject: latest.subject, text: latestText(of: thread))
    }

    /// The newest message's words: its text once downloaded, its preview until then.
    func latestText(of thread: MailThread) -> String {
        let latest = thread.latest
        return body(of: latest, in: thread)?.text ?? latest.snippet
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
    public var needYouCount: Int { needingYou.count }

    /// Home's one sentence about what needs you, kept the same way as the count.
    public var homeSummaryNow: String {
        derived.homeSummary.value { _ = clockTick; return homeSummary() }
    }

    /// A conversation on Home with its note.
    struct Needing {
        var thread: MailThread
        var note: MarginNote
    }

    /// What needs you, kept until the mail, labels, Sent or meetings change, or the clock ticks
    /// (the notes follow the time of day). The account column and Home ask on every redraw.
    var needingYou: [Needing] {
        derived.needingYou.value { _ = clockTick; return computeNeedingYou(now: Date()) }
    }

    /// The conversations that can have a note for a reason other than being recent: the ones
    /// with a meeting still to come, and the ones in the bills group. Found by one look through
    /// the mail when conversations arrive or leave, and kept (as id and date) in between.
    private var olderNoteCandidates: [(id: String, date: Date)] {
        derived.noteCandidates.value {
            _ = inboxOrder
            let now = Date()
            let meetings = Set(calendarEntries.lazy.filter { !$0.cancelled && $0.finish > now }.map(\.threadID))
            let billsName = Self.billsGroupName
            let bills = KeyLookup(labelStore.labelsByThread.lazy.filter { entry in
                entry.value.contains { $0.caseInsensitiveCompare(billsName) == .orderedSame }
            }.map(\.key))
            guard !meetings.isEmpty || !bills.isEmpty else { return [] }
            let horizon = now.addingTimeInterval(-Self.noteHorizon)
            var found: [(id: String, date: Date)] = []
            for id in allInboxesAccounts {
                guard let shelf = shelves[id] else { continue }
                for thread in shelf.threads[shelf.countNewer(than: horizon)...] where meetings.contains(thread.id) || bills.contains(thread) {
                    found.append((thread.id, thread.date))
                }
            }
            return found.sorted { $0.date > $1.date }
        }
    }

    private func computeNeedingYou(now: Date) -> [Needing] {
        _ = inboxRevision
        let key = marginNoteKey(now: now)
        let horizon = now.addingTimeInterval(-Self.noteHorizon)
        let snoozed = KeyLookup(snoozes.lazy.filter { $0.value > now }.map(\.key))
        var found: [Needing] = []
        func consider(_ thread: MailThread) {
            guard !snoozed.contains(thread), let note = marginNote(for: thread, now: now, key: key) else { return }
            found.append(Needing(thread: thread, note: note))
        }
        // Recent mail, newest first across the mailboxes…
        let recent = allInboxesAccounts.map { shelves[$0] ?? InboxShelf() }
        let reader = ShelfReader(shelves: recent, rows: recent.map { $0.countNewer(than: horizon) })
        reader.walk(filter: .everything) { shelf, row in
            consider(reader.shelves[shelf].threads[row])
            return true
        }
        // …then the older conversations with a meeting or a bill.
        for candidate in olderNoteCandidates {
            if let thread = inboxThread(candidate.id, date: candidate.date) { consider(thread) }
        }
        return found
    }

    /// The conversations on Home that have a note, newest first, each with its note: all
    /// inboxes, not snoozed. `only` narrows them (AI apps don't see hidden mailboxes).
    public func needsYou(now: Date = Date(), only: ((MailThread) -> Bool)? = nil) -> [(thread: MailThread, note: MarginNote)] {
        needingYou.compactMap { only?($0.thread) ?? true ? ($0.thread, $0.note) : nil }
    }

    /// "Two replies to write and a bill to open. Quarterly planning at 10:00." Or, with
    /// nothing waiting, "Nothing needs you right now." The line under Home's date.
    public func homeSummary(now: Date = Date(), only: ((MailThread) -> Bool)? = nil) -> String {
        var parts: [String] = []
        let owed = needingYou.filter { $0.note.kind == .reply && (only?($0.thread) ?? true) }.count
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

/// A conversation's note as it was worked out, with what it was worked out for.
struct KeptNote {
    var latest: String
    var flags: Int
    var note: MarginNote?
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
