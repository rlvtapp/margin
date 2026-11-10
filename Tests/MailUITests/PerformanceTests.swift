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
}
