import Foundation
import MailCore
import Testing
@testable import MailUI

/// How long what the views ask for on every redraw takes with a big inbox. Prints timings;
/// fails only when something is far too slow for a frame (16 ms).
@MainActor @Suite struct PerformanceTests {
    private func bigModel(threadsPerAccount: Int = 1_000) async -> MailModel {
        let model = MailModel(environment: .preview())
        await model.reload()
        let senders = (0..<300).map { EmailAddress(name: "Person \($0)", address: "person\($0)@company\($0 % 40).example") }
        for account in model.accounts {
            model.inboxes[account.id] = (0..<threadsPerAccount).map { index in
                let headers: [String: String] = index % 3 == 0 ? ["list-unsubscribe": "<mailto:leave@list.example>", "list-id": "<list\(index % 50).example>"] : [:]
                let message = MailMessage(
                    id: "\(account.id)-\(index)", mailboxID: "INBOX", from: senders[index % senders.count],
                    to: [account.address], subject: "Subject \(index)", date: Date(timeIntervalSinceNow: Double(-index * 600)),
                    snippet: "A preview of message \(index) with some words in it", flags: index % 4 == 0 ? [] : [.seen],
                    listHeaders: headers)
                return MailThread(id: "\(account.id)-t\(index)", messages: [message], accountID: account.id)
            }
        }
        return model
    }

    private func time(_ label: String, runs: Int = 20, _ work: () -> Void) -> Double {
        work() // warm up
        let clock = ContinuousClock()
        let elapsed = clock.measure { for _ in 0..<runs { work() } }
        let ms = Double(elapsed.components.attoseconds) / 1e15 / Double(runs) + Double(elapsed.components.seconds) * 1000 / Double(runs)
        print(String(format: "PERF %-34@ %8.2f ms", label as NSString, ms))
        return ms
    }

    @Test func redrawWorkStaysWithinAFrame() async {
        let model = await bigModel()
        var results: [String: Double] = [:]
        results["visibleThreads (All inboxes)"] = time("visibleThreads (All inboxes)") { _ = model.visibleThreads }
        results["inboxThreads(nil)"] = time("inboxThreads(nil)") { _ = model.inboxThreads(nil) }
        results["unreadCount all"] = time("unreadCount all") { _ = model.unreadCount(account: nil) }
        results["unreadCount per split"] = time("unreadCount per split") {
            for split in InboxSplit.allCases { _ = model.unreadCount(account: nil, split: split) }
        }
        results["rail badges (every account)"] = time("rail badges (every account)") {
            for account in model.accounts { _ = model.unreadCount(account: account.id) }
        }
        results["selectedThread"] = time("selectedThread") {
            model.selectedThreadID = model.inboxThreads(nil).last?.id
            _ = model.selectedThread
        }
        results["newsletterSenders"] = time("newsletterSenders", runs: 5) { _ = model.newsletterSenders }
        results["addressBook"] = time("addressBook", runs: 5) { _ = model.addressBook }
        results["split of every thread"] = time("split of every thread") { _ = model.inboxThreads(nil).map(\.split) }
        // The reader asks for these on every redraw (resizing included): a big HTML mail.
        let thread = model.inboxThreads(nil)[1]
        let html = "<html><head><style>" + String(repeating: ".c{color:red} ", count: 1_500) + "</style></head><body>"
            + String(repeating: "<p>Some words <a href=\"https://shop.example/item?id=123456\">a link</a></p>", count: 600) + "</body></html>"
        model.bodies[MailModel.bodyKey(thread.accountID, thread.latest.id)] = MessageBody(text: HTMLText.plain(html), html: html)
        let first = ContinuousClock().measure { _ = model.signInCode(in: thread); _ = model.signInLink(in: thread) }
        print("PERF sign-in checks, first time         \(first)")
        results["sign-in checks, every redraw"] = time("sign-in checks, every redraw") {
            _ = model.signInCode(in: thread)
            _ = model.signInLink(in: thread)
        }
        let worst = results.max { $0.value < $1.value }!
        print("PERF worst: \(worst.key) \(String(format: "%.2f", worst.value)) ms")
        #expect(worst.value < 50, "\(worst.key) takes \(worst.value) ms with 2,000 conversations")
    }

    /// This round's per-redraw work: Home's "needs you", its sections, the reply-owed check
    /// against Sent, label colours, previews, and Ask's facts. With 2,000 conversations and
    /// 400 sent messages per mailbox.
    @Test func homeWorkStaysWithinAFrame() async {
        let model = await bigModel()
        for account in model.accounts {
            model.sentMail[account.id] = (0..<400).map { index in
                MailMessage(id: "\(account.id)-s\(index)", mailboxID: "Sent", messageID: "sent-\(index)@example",
                            from: account.address, to: [EmailAddress(address: "person\(index % 300)@company\(index % 40).example")],
                            subject: "Re: Subject \(index * 3)", date: Date(timeIntervalSinceNow: Double(-index * 500)))
            }
        }
        let threads = model.allInboxesThreads(nil)
        var results: [String: Double] = [:]
        results["needYouCount"] = time("needYouCount", runs: 5) { _ = model.needYouCount }
        results["homeSections"] = time("homeSections", runs: 5) { _ = model.homeSections(threads) }
        results["marginNote, every thread"] = time("marginNote, every thread", runs: 5) { for thread in threads { _ = model.marginNote(for: thread) } }
        results["answeredInSent, every thread"] = time("answeredInSent, every thread", runs: 5) { for thread in threads { _ = model.answeredInSent(thread) } }
        results["conversation(selected)"] = time("conversation(selected)") { _ = model.conversation(threads[3]) }
        results["label colours, 50 labels"] = time("label colours, 50 labels") { for index in 0..<50 { _ = LabelColors.index(for: "Label \(index)") } }
        let snippets = (0..<2_000).map { "Dear Kaan, ------------------------------ We received request \($0) ====" }
        results["tidyPreview, 2,000 previews"] = time("tidyPreview, 2,000 previews", runs: 5) { for text in snippets { _ = HTMLText.tidyPreview(text) } }
        results["askFacts"] = time("askFacts", runs: 5) { _ = model.askFacts() }
        results["offersAsk"] = time("offersAsk") { _ = model.offersAsk(for: "when is my flight to lisbon") }
        let worst = results.max { $0.value < $1.value }!
        print("PERF worst (home): \(worst.key) \(String(format: "%.2f", worst.value)) ms")
        #expect(worst.value < 50, "\(worst.key) takes \(worst.value) ms with 2,000 conversations")
    }

    /// Saved-mail lookups behind the To field and the person card, over 6,000 saved messages.
    @Test func savedMailLookupsAreQuick() async {
        let cache = MailCache(url: nil)
        let me = EmailAddress(address: "me@example.com")
        for batch in 0..<6 {
            let messages = (0..<1_000).map { index -> MailMessage in
                let n = batch * 1_000 + index
                return MailMessage(id: "m\(n)", mailboxID: "INBOX", messageID: "m\(n)@x",
                                   from: EmailAddress(name: "Person \(n % 500)", address: "person\(n % 500)@company\(n % 40).example"),
                                   to: [me], subject: "Subject \(n)", date: Date(timeIntervalSinceNow: Double(-n * 300)))
            }
            await cache.saveThreads(messages.map { MailThread(id: $0.id, messages: [$0]) }, account: UUID(), mailbox: "INBOX")
        }
        let clock = ContinuousClock()
        var people: [EmailAddress] = []
        let typed = clock.measure { }
        _ = typed
        let start = clock.now
        for _ in 0..<10 { people = await cache.people(matching: "pers") }
        let peopleMs = Double((clock.now - start).components.attoseconds) / 1e15 / 10 + Double((clock.now - start).components.seconds) * 100
        let start2 = clock.now
        for _ in 0..<10 { _ = await cache.history(with: "person7@company7.example") }
        let historyMs = Double((clock.now - start2).components.attoseconds) / 1e15 / 10 + Double((clock.now - start2).components.seconds) * 100
        print(String(format: "PERF people(matching:) over 6,000     %8.2f ms", peopleMs))
        print(String(format: "PERF history(with:) over 6,000         %8.2f ms", historyMs))
        #expect(!people.isEmpty)
        // Both run after a pause in typing or on opening a card, not every frame.
        #expect(peopleMs < 150 && historyMs < 150)
    }
}
