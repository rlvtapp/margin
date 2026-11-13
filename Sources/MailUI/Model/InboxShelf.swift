import Foundation
import MailCore

/// One mailbox's inbox as the model holds it: its conversations newest first, and beside each
/// one a byte of facts (unread, starred, has a file, which part of the inbox) and its date.
///
/// The lists on screen, the counts in the sidebar and "which conversation is this" used to be
/// worked out by walking every conversation each time one of them changed. Here a change to one
/// conversation touches that conversation: counts are kept as it changes, and finding the newest
/// few that pass a filter reads the bytes, not the conversations.
struct InboxShelf: Sendable {
    private(set) var threads: [MailThread]
    /// `Facts` of each conversation, in step with `threads`.
    private(set) var facts: [UInt8]
    /// Each conversation's date (seconds), in step with `threads`: for merging mailboxes and
    /// for finding one conversation without looking inside the others.
    private(set) var dates: [Double]
    /// Conversations per part of the inbox, and how many of them are unread.
    private(set) var totals = [0, 0, 0]
    private(set) var unread = [0, 0, 0]

    enum Facts {
        static let unread: UInt8 = 1 << 0
        static let starred: UInt8 = 1 << 1
        static let attachment: UInt8 = 1 << 2
        /// Two bits: 00 people, 10 updates, 11 newsletters. The high bit alone is "Other"
        /// (updates and newsletters), the inbox tab beside Important.
        static let splitShift: UInt8 = 3
        static let splitMask: UInt8 = 0b11 << 3
        static let otherBit: UInt8 = 0b10 << 3

        static func split(_ split: InboxSplit) -> UInt8 {
            let number: UInt8 = switch split {
            case .people: 0b00
            case .updates: 0b10
            case .newsletters: 0b11
            }
            return number << splitShift
        }

        static func of(_ thread: MailThread) -> UInt8 {
            var byte = split(thread.split)
            for message in thread.messages {
                if message.isUnread { byte |= unread }
                if message.isStarred { byte |= starred }
                if message.hasAttachments { byte |= attachment }
            }
            return byte
        }

        /// 0 people, 1 updates, 2 newsletters: where each is counted.
        static func splitIndex(_ byte: UInt8) -> Int {
            switch (byte & splitMask) >> splitShift {
            case 0b00: 0
            case 0b10: 1
            default: 2
            }
        }
    }

    /// A filter on the facts: a conversation passes when `byte & mask == want`.
    struct Filter: Hashable, Sendable {
        var mask: UInt8 = 0
        var want: UInt8 = 0

        static let everything = Filter()
        func passes(_ byte: UInt8) -> Bool { byte & mask == want }
        var isEverything: Bool { mask == 0 }

        mutating func require(_ bit: UInt8) { mask |= bit; want |= bit }
        mutating func require(_ split: InboxSplit) {
            mask |= Facts.splitMask
            want = (want & ~Facts.splitMask) | Facts.split(split)
        }

        /// The inbox tab a part belongs to: Important (people) or Other (updates and newsletters).
        mutating func require(tabOf split: InboxSplit) {
            if split == .people {
                require(.people)
            } else {
                mask = (mask & ~Facts.splitMask) | Facts.otherBit
                want = (want & ~Facts.splitMask) | Facts.otherBit
            }
        }
    }

    init() {
        threads = []
        facts = []
        dates = []
    }

    /// Builds the shelf; can be done away from the main thread. Conversations that aren't
    /// newest first are put in that order.
    init(_ list: [MailThread]) {
        var list = list
        var dates = list.map { $0.date.timeIntervalSinceReferenceDate }
        if !zip(dates, dates.dropFirst()).allSatisfy({ $0 >= $1 }) {
            list.sort { $0.date > $1.date }
            dates = list.map { $0.date.timeIntervalSinceReferenceDate }
        }
        threads = list
        self.dates = dates
        facts = list.map(Facts.of)
        for byte in facts { count(byte, by: 1) }
    }

    var count: Int { threads.count }
    var isEmpty: Bool { threads.isEmpty }

    private mutating func count(_ byte: UInt8, by step: Int) {
        let part = min(Facts.splitIndex(byte), 2)
        totals[part] += step
        if byte & Facts.unread != 0 { unread[part] += step }
    }

    /// How many of the first `rows` conversations pass the filter, and how many of those are
    /// unread.
    func tally(_ filter: Filter, rows: Int) -> (count: Int, unread: Int) {
        if rows >= threads.count {
            if filter.isEverything { return (threads.count, unread.reduce(0, +)) }
            if filter.mask == Facts.splitMask {
                let part = min(Facts.splitIndex(filter.want), 2)
                return (totals[part], unread[part])
            }
            if filter.mask == Facts.otherBit {
                return (totals[1] + totals[2], unread[1] + unread[2])
            }
        }
        var count = 0, unreadCount = 0
        for byte in facts.prefix(rows) where filter.passes(byte) {
            count += 1
            if byte & Facts.unread != 0 { unreadCount += 1 }
        }
        return (count, unreadCount)
    }

    /// Unread in an inbox tab: everything, Important (people) or Other (updates and newsletters).
    func unreadCount(split: InboxSplit?) -> Int {
        guard let split else { return unread.reduce(0, +) }
        return split == .people ? unread[0] : unread[1] + unread[2]
    }

    // MARK: Finding

    /// Where a conversation is, given its date: a binary search, then the few that share the date.
    func position(of id: String, date: Date) -> Int? {
        let wanted = date.timeIntervalSinceReferenceDate
        var low = 0, high = dates.count
        // First index whose date is not newer than the one wanted.
        while low < high {
            let middle = (low + high) / 2
            if dates[middle] > wanted { low = middle + 1 } else { high = middle }
        }
        var index = low
        while index < dates.count, dates[index] == wanted {
            if threads[index].id == id { return index }
            index += 1
        }
        return nil
    }

    /// Where a conversation is when only its id is known: looks at every one.
    func position(of id: String) -> Int? {
        threads.firstIndex { $0.id == id }
    }

    func position(of thread: MailThread) -> Int? {
        position(of: thread.id, date: thread.date) ?? position(of: thread.id)
    }

    /// How many conversations at the top are newer than `date`.
    func countNewer(than date: Date) -> Int {
        let wanted = date.timeIntervalSinceReferenceDate
        var low = 0, high = dates.count
        while low < high {
            let middle = (low + high) / 2
            if dates[middle] > wanted { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// How many conversations at the top are from `seconds` or later.
    func countNotOlder(than seconds: Double) -> Int {
        var low = 0, high = dates.count
        while low < high {
            let middle = (low + high) / 2
            if dates[middle] >= seconds { low = middle + 1 } else { high = middle }
        }
        return low
    }

    // MARK: Changing

    /// Puts a changed conversation in the place of the one at `index`. Returns whether the
    /// order of the shelf changed (its date did).
    @discardableResult
    mutating func replace(at index: Int, with thread: MailThread) -> Bool {
        let date = thread.date.timeIntervalSinceReferenceDate
        let byte = Facts.of(thread)
        count(facts[index], by: -1)
        count(byte, by: 1)
        if dates[index] == date {
            threads[index] = thread
            facts[index] = byte
            return false
        }
        threads.remove(at: index)
        facts.remove(at: index)
        dates.remove(at: index)
        let place = countNewer(than: thread.date)
        threads.insert(thread, at: place)
        facts.insert(byte, at: place)
        dates.insert(date, at: place)
        return true
    }

    /// Takes conversations out, by position.
    mutating func remove(at positions: [Int]) {
        for index in Set(positions).sorted(by: >) {
            count(facts[index], by: -1)
            threads.remove(at: index)
            facts.remove(at: index)
            dates.remove(at: index)
        }
    }

    /// Takes out every conversation with one of these ids, wherever it is.
    mutating func remove(ids: Set<String>) {
        let positions = threads.indices.filter { ids.contains(threads[$0].id) }
        remove(at: positions)
    }

    /// Adds conversations (older mail arriving as the list is scrolled), keeping newest first.
    /// One that's already here is replaced.
    mutating func add(_ more: [MailThread]) {
        guard !more.isEmpty else { return }
        let known = Set(threads.map(\.id))
        let new = more.filter { !known.contains($0.id) }.sorted { $0.date > $1.date }
        for thread in more where known.contains(thread.id) {
            if let index = position(of: thread.id) { replace(at: index, with: thread) }
        }
        guard !new.isEmpty else { return }
        // The usual case: everything new is older than everything here.
        if let last = dates.last, let first = new.first, first.date.timeIntervalSinceReferenceDate > last {
            self = InboxShelf(threads + new)
            return
        }
        threads += new
        dates += new.map { $0.date.timeIntervalSinceReferenceDate }
        let bytes = new.map(Facts.of)
        facts += bytes
        for byte in bytes { count(byte, by: 1) }
    }

    /// Keeps only the newest `limit` conversations.
    mutating func trim(to limit: Int) {
        guard threads.count > limit else { return }
        for byte in facts[limit...] { count(byte, by: -1) }
        threads.removeSubrange(limit...)
        facts.removeSubrange(limit...)
        dates.removeSubrange(limit...)
    }
}

/// A conversation by where it is: which mailbox (by its place in a list of mailboxes) and which
/// row of that mailbox's shelf. Only good until the shelves' order changes.
struct ThreadSpot: Hashable, Sendable {
    var shelf: Int32
    var row: Int32
}

/// Several shelves read together, newest first across all of them, without building the merged
/// list: the newest few are found by stepping down each shelf.
struct ShelfReader {
    let shelves: [InboxShelf]
    /// How many rows of each shelf are read. Mailboxes shown together are only read down to
    /// where the first of them runs out of loaded mail: below that, a mailbox with older mail
    /// still to fetch would have gaps, and rows would later appear in the middle of the list.
    let rows: [Int]

    init(shelves: [InboxShelf], rows: [Int]? = nil) {
        self.shelves = shelves
        self.rows = rows ?? shelves.map(\.count)
    }

    /// Reads the shelves together down to the newest "oldest loaded conversation" among the
    /// mailboxes that have older mail to fetch (`open`).
    init(shelves: [InboxShelf], open: [Bool]) {
        self.shelves = shelves
        let floors = zip(shelves, open).compactMap { shelf, isOpen in isOpen ? shelf.dates.last : nil }
        if shelves.count > 1, let floor = floors.max() {
            rows = shelves.map { $0.countNotOlder(than: floor) }
        } else {
            rows = shelves.map(\.count)
        }
    }

    /// The newest conversations that pass, at most `limit`: the bytes say which rows to look
    /// at, and `passes` (when given) decides about those.
    func newest(_ limit: Int, filter: InboxShelf.Filter = .everything, passes: ((MailThread) -> Bool)? = nil) -> [MailThread] {
        var found: [MailThread] = []
        found.reserveCapacity(min(limit, 512))
        walk(filter: filter) { shelf, row in
            let thread = shelves[shelf].threads[row]
            if passes?(thread) ?? true { found.append(thread) }
            return found.count < limit
        }
        return found
    }

    /// Every conversation that passes, newest first, by where it is.
    func spots(filter: InboxShelf.Filter = .everything, passes: ((MailThread) -> Bool)? = nil) -> [ThreadSpot] {
        var found: [ThreadSpot] = []
        walk(filter: filter) { shelf, row in
            if passes?(shelves[shelf].threads[row]) ?? true { found.append(ThreadSpot(shelf: Int32(shelf), row: Int32(row))) }
            return true
        }
        return found
    }

    /// Steps through the rows that pass the filter, newest first across the shelves, until
    /// `visit` says stop.
    func walk(filter: InboxShelf.Filter, _ visit: (_ shelf: Int, _ row: Int) -> Bool) {
        // One mailbox: straight down.
        if shelves.count == 1 {
            let facts = shelves[0].facts
            for row in 0..<rows[0] where filter.passes(facts[row]) {
                if !visit(0, row) { return }
            }
            return
        }
        var cursors = [Int](repeating: 0, count: shelves.count)
        func settle(_ shelf: Int) {
            let facts = shelves[shelf].facts
            let end = rows[shelf]
            var row = cursors[shelf]
            while row < end, !filter.passes(facts[row]) { row += 1 }
            cursors[shelf] = row
        }
        for shelf in shelves.indices { settle(shelf) }
        while true {
            var best = -1
            var bestDate = -Double.infinity
            for shelf in shelves.indices where cursors[shelf] < rows[shelf] {
                let date = shelves[shelf].dates[cursors[shelf]]
                if date > bestDate { bestDate = date; best = shelf }
            }
            guard best >= 0 else { return }
            let row = cursors[best]
            cursors[best] += 1
            settle(best)
            if !visit(best, row) { return }
        }
    }

    /// Every conversation that's read, newest first.
    func merged() -> [MailThread] {
        if shelves.count == 1, rows[0] == shelves[0].count { return shelves[0].threads }
        var all: [MailThread] = []
        all.reserveCapacity(rows.reduce(0, +))
        walk(filter: .everything) { shelf, row in
            all.append(shelves[shelf].threads[row])
            return true
        }
        return all
    }

    func tally(_ filter: InboxShelf.Filter) -> (count: Int, unread: Int) {
        zip(shelves, rows).reduce((0, 0)) { sum, pair in
            let part = pair.0.tally(filter, rows: pair.1)
            return (sum.0 + part.count, sum.1 + part.unread)
        }
    }

    subscript(spot: ThreadSpot) -> MailThread { shelves[Int(spot.shelf)].threads[Int(spot.row)] }
    func facts(at spot: ThreadSpot) -> UInt8 { shelves[Int(spot.shelf)].facts[Int(spot.row)] }
}
