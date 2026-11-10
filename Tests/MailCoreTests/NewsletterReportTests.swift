import Foundation
import Testing
@testable import MailCore

@Suite struct NewsletterReportTests {
    private func issue(_ number: Int, from address: String, read: Bool, listID: String? = nil) -> MailThread {
        var headers = ["list-unsubscribe": "<mailto:leave@\(address)>"]
        if let listID { headers["list-id"] = listID }
        let message = MailMessage(
            id: "\(address)/\(number)", mailboxID: "Archive", messageID: "\(number)@\(address)",
            from: EmailAddress(name: "List", address: address), subject: "Issue \(number)",
            date: Date(timeIntervalSince1970: Double(number) * 86_400), flags: read ? [.seen] : [], listHeaders: headers
        )
        return MailThread(id: message.id, messages: [message])
    }

    @Test func countsOpenedIssuesPerList() {
        var threads = (1...20).map { issue($0, from: "digest@lists.example", read: $0 == 4) }
        threads += (1...6).map { issue($0, from: "bakes@shop.example", read: $0 <= 5) }
        let senders = NewsletterReport.senders(from: threads + [threads[0]])
        let digest = try! #require(senders.first { $0.address == "digest@lists.example" })
        #expect(digest.received == 20)
        #expect(digest.opened == 1)
        #expect(digest.isRarelyRead)
        let suggestions = NewsletterReport.suggestions(from: senders)
        #expect(suggestions.map(\.address) == ["digest@lists.example"])
    }

    @Test func openedInMarginCountsAndKeptListsStayQuiet() {
        let threads = (1...5).map { issue($0, from: "news@site.example", read: false, listID: "Site News <news.site.example>") }
        let opened = Set(threads.prefix(2).map { NewsletterReport.identity($0.messages[0]) })
        let sender = try! #require(NewsletterReport.senders(from: threads, openedIDs: opened).first)
        #expect(sender.id == "news.site.example")
        #expect(sender.opened == 2)
        #expect(!sender.isRarelyRead)
        let quiet = NewsletterReport.senders(from: threads)
        #expect(NewsletterReport.suggestions(from: quiet, keeping: ["news.site.example"]).isEmpty)
    }
}
