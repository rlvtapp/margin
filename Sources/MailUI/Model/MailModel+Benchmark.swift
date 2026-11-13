import Foundation
import MailCore

/// A made-up load for measuring the app at size: several full mailboxes with formatted mail,
/// conversations, labels and Sent, all in memory (nothing is fetched or saved). Used by the Mac
/// app's `-benchmark` run; see docs/architecture.md, "Measuring at size".
public enum MailBenchmark {
    /// Called when a formatted mail has loaded and been measured, so a run knows it's on screen.
    nonisolated(unsafe) public static var onPageMeasured: (() -> Void)?
}

/// Makes the made-up mail: conversation number `index` of mailbox number `number` is always
/// the same one, so a mailbox of a million needn't be held anywhere to be asked for.
struct BenchmarkMail: Sendable {
    let accounts: [MailAccount]
    let people: [EmailAddress]
    let shops: [EmailAddress]
    let pages: [(html: String, text: String)]
    /// Dates count back from here.
    let now: Date

    init(accounts count: Int, now: Date = Date()) {
        accounts = (0..<count).map { index in
            MailAccount(label: ["Work", "Personal", "Studio", "Shop", "Club", "School", "Side", "Old"][index % 8] + (index >= 8 ? " \(index)" : ""),
                        address: EmailAddress(name: "Alex Rivera", address: "alex\(index)@mailbox\(index).example"),
                        connection: .sample, auth: .password(username: "alex\(index)"), colorIndex: index % 12)
        }
        people = (0..<240).map { EmailAddress(name: "\(["Noor", "Sam", "Maya", "Lena", "Ines", "Jodi", "Omar", "Kim"][$0 % 8]) \(["Haddad", "Okafor", "Chen", "Fischer", "Moreau", "Park", "Aziz", "Lind"][($0 / 8) % 8]) \($0)", address: "person\($0)@company\($0 % 40).example") }
        shops = (0..<60).map { EmailAddress(name: "Shop \($0)", address: "no-reply@orders.shop\($0).example") }
        pages = (0..<16).map(MailModel.benchmarkPage)
        self.now = now
    }

    static let folders = [Mailbox(id: "INBOX", name: "Inbox", role: .inbox), Mailbox(id: "Sent", name: "Sent", role: .sent),
                          Mailbox(id: "Archive", name: "Archive", role: .archive), Mailbox(id: "Trash", name: "Trash", role: .trash),
                          Mailbox(id: "Drafts", name: "Drafts", role: .drafts)]

    /// Conversation `index` (0 is the newest) of mailbox `number`, with its texts when asked.
    func thread(_ index: Int, mailbox number: Int, bodies: inout [String: MessageBody]?) -> MailThread {
        let account = accounts[number]
        let kind = index % 20
        let date = now.addingTimeInterval(Double(-(index * 6 + number) * 173))
        var messages: [MailMessage] = []
        if kind < 12 {
            // Formatted mail from a shop or a newsletter.
            let headers = kind < 7 ? ["list-unsubscribe": "<mailto:leave@list.example>", "list-id": "<list\(index % 50).example>"] : [:]
            let message = MailMessage(id: "INBOX/\(index * 10)", mailboxID: "INBOX", messageID: "<m\(number)-\(index)@shop.example>",
                                      from: shops[(index + number) % shops.count], to: [account.address],
                                      subject: ["Your order is on its way", "Receipt for your purchase", "This week's issue", "Your statement is ready", "A new sign-in to your account"][index % 5] + " \(index)",
                                      date: date, snippet: "Thanks for your order. Here is a summary of what you bought and when it arrives.",
                                      flags: index % 3 == 0 ? [] : [.seen], listHeaders: headers)
            messages = [message]
            if bodies != nil {
                let page = pages[(index + number) % pages.count]
                bodies?[message.id] = MessageBody(text: page.text, html: page.html)
            }
        } else {
            // People: one message, or a conversation with the earlier mail quoted under each reply.
            let length = kind < 17 ? 1 : 2 + index % 5
            let other = people[(index * 7 + number) % people.count]
            var quoted = ""
            for part in 0..<length {
                let mine = part % 2 == 1
                let text = "Hi,\n\n" + String(repeating: "This is part \(part) of the plan for next week, with a few details about who does what. ", count: 4 + part)
                    + "\n\nBest,\n" + (mine ? "Alex" : other.displayName) + quoted
                let message = MailMessage(id: "INBOX/\(index * 10 + part)", mailboxID: "INBOX", messageID: "<p\(number)-\(index)-\(part)@example>",
                                          inReplyTo: part > 0 ? "<p\(number)-\(index)-\(part - 1)@example>" : nil,
                                          from: mine ? account.address : other, to: [mine ? other : account.address],
                                          subject: (part > 0 ? "Re: " : "") + "Plans for week \(index)", date: date.addingTimeInterval(Double(part) * 60),
                                          snippet: String(text.prefix(120)), flags: index % 4 == 0 && part == length - 1 ? [] : [.seen])
                messages.append(message)
                if bodies != nil {
                    bodies?[message.id] = MessageBody(text: text)
                    quoted = "\n\nOn Tuesday, \(mine ? "Alex" : other.displayName) wrote:\n" + text.split(separator: "\n").map { "> " + $0 }.joined(separator: "\n")
                }
            }
        }
        // Named after its first message, as conversations read from a server and from saved
        // mail are, so the two are the same conversation.
        return MailThread(id: "INBOX/\(index * 10)", messages: messages)
    }

    func thread(_ index: Int, mailbox number: Int) -> MailThread {
        var none: [String: MessageBody]?
        return thread(index, mailbox: number, bodies: &none)
    }

    func sent(mailbox number: Int) -> [MailMessage] {
        (0..<200).map { index in
            MailMessage(id: "Sent/\(index)", mailboxID: "Sent", messageID: "<sent\(number)-\(index)@example>", from: accounts[number].address,
                        to: [people[index % people.count]], subject: "Re: Plans for week \(index * 3)", date: now.addingTimeInterval(Double(-index * 900)))
        }
    }

    /// The text of one message, from its id alone ("INBOX/<conversation × 10 + part>").
    func body(of messageID: String, mailbox number: Int) -> MessageBody? {
        guard let value = Int(messageID.dropFirst("INBOX/".count)) else { return nil }
        var bodies: [String: MessageBody]? = [:]
        _ = thread(value / 10, mailbox: number, bodies: &bodies)
        return bodies?[messageID]
    }
}

/// A made-up server for one benchmark mailbox: it holds `count` conversations and hands out the
/// newest ones asked for, the way a real one does, without anything going over a network.
actor BenchmarkProvider: MailProvider {
    let mail: BenchmarkMail
    let number: Int
    let count: Int
    /// Read marks and stars set during the run, by conversation number.
    private var changed: [Int: MailAction] = [:]
    private var gone = Set<Int>()

    init(mail: BenchmarkMail, number: Int, count: Int) {
        self.mail = mail
        self.number = number
        self.count = count
    }

    func mailboxes() async throws -> [Mailbox] { BenchmarkMail.folders }

    func threads(in mailbox: Mailbox, limit: Int) async throws -> [MailThread] {
        if mailbox.role == .sent { return mail.sent(mailbox: number).prefix(limit).map { MailThread(id: $0.id, messages: [$0]) } }
        guard mailbox.role == .inbox else { return [] }
        var found: [MailThread] = []
        var index = 0
        while found.count < limit, index < count {
            if !gone.contains(index) {
                let thread = mail.thread(index, mailbox: number)
                found.append(changed[index].map { MailModel.changed(thread, by: $0) } ?? thread)
            }
            index += 1
        }
        return found
    }

    func body(of message: MailMessage) async throws -> MessageBody {
        mail.body(of: message.id, mailbox: number) ?? MessageBody(text: message.snippet)
    }

    /// Pages of the inbox by conversation number, as a real server pages by its own order.
    /// `delay` stands in for the time a server takes to answer a page.
    var delay: Duration = .zero
    /// How many pages were asked for (for tests).
    private(set) var pagesAsked = 0

    func setDelay(_ delay: Duration) { self.delay = delay }

    func olderMessages(in mailbox: Mailbox, after position: String?, limit: Int) async throws -> OlderMailPage {
        guard mailbox.role == .inbox else { return OlderMailPage() }
        pagesAsked += 1
        if delay > .zero { try await Task.sleep(for: delay) }
        var index = position.flatMap { Int($0) } ?? 0
        var messages: [MailMessage] = []
        while messages.count < limit, index < count {
            if !gone.contains(index) {
                let thread = mail.thread(index, mailbox: number)
                messages += (changed[index].map { MailModel.changed(thread, by: $0) } ?? thread).messages
            }
            index += 1
        }
        return OlderMailPage(messages: messages, next: index < count ? String(index) : nil)
    }

    func checkSaved(_ ids: [String], in mailbox: Mailbox, since token: String?) async throws -> SavedMailCheck {
        var check = SavedMailCheck(token: "changes")
        for id in ids {
            guard let value = Int(id.dropFirst("INBOX/".count)) else { continue }
            if gone.contains(value / 10) { check.gone.append(id) } else if let action = changed[value / 10] {
                var flags: MessageFlags = mail.thread(value / 10, mailbox: number).messages.first?.flags ?? []
                switch action {
                case .markRead: flags.insert(.seen)
                case .markUnread: flags.remove(.seen)
                case .star: flags.insert(.flagged)
                case .unstar: flags.remove(.flagged)
                default: break
                }
                check.flags[id] = flags
            }
        }
        return check
    }

    func perform(_ action: MailAction, on threads: [MailThread]) async throws {
        for thread in threads {
            guard let index = (thread.id.split(separator: "/").last.flatMap { Int($0) }).map({ $0 / 10 }) else { continue }
            switch action {
            case .markRead, .markUnread, .star, .unstar: changed[index] = action
            default: gone.insert(index)
            }
        }
    }

    func send(_ draft: Draft) async throws {}
    func disconnect() async {}
}

extension MailModel {
    /// Replaces the sample mailboxes with `count` mailboxes of `threads` conversations each, all
    /// of them in memory: as if every conversation had been scrolled to.
    public func loadBenchmarkMail(accounts count: Int, threads: Int) {
        guard environment.isPreview else { return }
        let mail = BenchmarkMail(accounts: count)
        accounts = mail.accounts
        var newBodies: [String: MessageBody] = [:]
        for (number, account) in mail.accounts.enumerated() {
            mailboxes[account.id] = BenchmarkMail.folders
            var made: [MailThread] = []
            made.reserveCapacity(threads)
            for index in 0..<threads {
                var bodies: [String: MessageBody]? = index < Self.benchmarkBodies ? [:] : nil
                made.append(Self.tag(mail.thread(index, mailbox: number, bodies: &bodies), account: account.id))
                for (id, body) in bodies ?? [:] { newBodies[Self.bodyKey(account.id, id)] = body }
            }
            shelves[account.id] = InboxShelf(made)
            sentMail[account.id] = mail.sent(mailbox: number)
            providers[account.id] = BenchmarkProvider(mail: mail, number: number, count: threads)
        }
        bodies = newBodies
        // All of it is here: nothing older to fetch.
        reachedOldest = Set(mail.accounts.map(\.id))
        finishBenchmarkLoad(mail)
    }

    /// The same mailboxes the way the app really holds them: each mailbox has `threads`
    /// conversations on its (made-up) server and in the saved-mail database, and the app shows
    /// its newest page and fetches older mail as the list is scrolled. `fill` false leaves the
    /// database as it is (a file filled by an earlier run). Returns how long the two parts took.
    public func loadBenchmarkStore(accounts count: Int, threads: Int) async -> (fill: Duration?, open: Duration) {
        guard environment.isPreview else { return (nil, .zero) }
        // The made-up mail ends today, at noon, so a file saved earlier in the day still fits.
        let noon = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3_600)
        let mail = BenchmarkMail(accounts: count, now: noon)
        // Mailboxes keep their ids between runs, so a saved file is found again.
        let made = mail.accounts.enumerated().map { number, account in
            var copy = account
            copy.id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", number)) ?? account.id
            return copy
        }
        let last = made.count - 1
        let fill = await environment.cache.messageCount(account: made[last].id, mailbox: "INBOX") == 0
        let clock = ContinuousClock()
        // Reading ahead is part of how the app really opens mail; previews leave it off.
        readsAhead = true
        let filled = await clock.measure {
            guard fill else { return }
            for (number, account) in made.enumerated() {
                await environment.cache.saveMailboxes(BenchmarkMail.folders, account: account.id)
                var start = 0
                while start < threads {
                    let batch = (start..<min(start + 20_000, threads)).map { mail.thread($0, mailbox: number) }
                    await environment.cache.addThreads(batch, account: account.id, mailbox: "INBOX")
                    start += 20_000
                }
            }
        }
        accounts = made
        for (number, account) in made.enumerated() {
            providers[account.id] = BenchmarkProvider(mail: mail, number: number, count: threads)
            sentMail[account.id] = mail.sent(mailbox: number)
        }
        // What the app does when it starts: the window fills from saved mail.
        let opened = await clock.measure { await loadSavedMail() }
        finishBenchmarkLoad(mail)
        return (fill ? filled : nil, opened)
    }

    private func finishBenchmarkLoad(_ mail: BenchmarkMail) {
        inboxesChanged(order: true)
        contactStore = mail.people.enumerated().map { Contact(id: "c\($0.offset)", name: $0.element.name, emails: [$0.element.address], source: .system) }
        // Half the newest conversations carry a label, as after a few weeks of sorting. Written
        // in one go: adding them one by one saved the label file each time.
        var labels: [String: [String]] = [:]
        for (index, thread) in newestInInboxes(1_600).enumerated() where index % 2 == 0 {
            labels[LabelStore.key(for: thread)] = [["Receipts", "Travel", "Bills", "Newsletters", "Work", "Family", "Orders", "Updates"][index % 8]]
        }
        labelStore.merge(labels)
        selectedThreadID = nil
        go(to: .allInboxes)
    }

    /// Conversations per mailbox that get their text: the run steps through the newest ones, and
    /// a million texts would measure the made-up mail, not the app.
    static let benchmarkBodies = 2_000

    /// A formatted mail of the kind shops send: nested tables, inline styles, a style block,
    /// links and remote pictures (which stay blocked). Between about 40 and 120 KB.
    nonisolated static func benchmarkPage(_ seed: Int) -> (html: String, text: String) {
        let rows = 40 + seed * 9
        var html = "<html><head><meta charset=\"utf-8\"><style>" + String(repeating: ".cell{padding:8px 12px;font:14px/1.5 Helvetica,Arial,sans-serif;color:#333}.total{font-weight:bold}@media (max-width:600px){.wrap{width:100%!important}} ", count: 30 + seed * 4)
            + "</style></head><body style=\"margin:0;background:#f5f5f7\"><table class=\"wrap\" width=\"600\" align=\"center\" cellpadding=\"0\" cellspacing=\"0\" style=\"background:#ffffff\">"
        html += "<tr><td style=\"padding:24px\"><img src=\"https://images.shop\(seed).example/logo.png\" width=\"120\" height=\"40\" alt=\"\"><h1 style=\"font:600 24px Helvetica\">Thanks for your order</h1></td></tr>"
        var text = "Thanks for your order\n\n"
        for row in 0..<rows {
            html += "<tr><td><table width=\"100%\" cellpadding=\"0\" cellspacing=\"0\"><tr><td class=\"cell\" width=\"64\"><img src=\"https://images.shop\(seed).example/item\(row).jpg\" width=\"48\" height=\"48\" alt=\"\"></td>"
                + "<td class=\"cell\"><a href=\"https://shop\(seed).example/item?id=\(row)&utm_source=mail\" style=\"color:#0066cc;text-decoration:none\">Item number \(row) with a fairly long name</a><br><span style=\"color:#888\">Size M, colour blue, delivered by Friday</span></td>"
                + "<td class=\"cell total\" align=\"right\">€ \(10 + row),00</td></tr></table></td></tr>"
            text += "Item number \(row) with a fairly long name, € \(10 + row),00\n"
        }
        html += "<tr><td class=\"cell\" style=\"color:#888;font-size:12px\">" + String(repeating: "You receive this message because you bought something from us. ", count: 12) + "</td></tr></table></body></html>"
        return (html, text)
    }
}
