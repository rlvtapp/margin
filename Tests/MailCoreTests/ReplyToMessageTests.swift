import Foundation
import Testing
@testable import MailCore

@Suite struct ReplyToMessageTests {
    let me = EmailAddress(name: "Alex", address: "alex@example.com")
    let noor = EmailAddress(name: "Noor", address: "noor@example.com")
    let sam = EmailAddress(name: "Sam", address: "sam@example.com")
    let maya = EmailAddress(name: "Maya", address: "maya@example.com")

    private func thread() -> MailThread {
        let first = MailMessage(id: "1", mailboxID: "INBOX", messageID: "<1@example.com>", from: noor, to: [me, sam], cc: [maya],
                                subject: "Launch", date: Date(timeIntervalSince1970: 100))
        let second = MailMessage(id: "2", mailboxID: "INBOX", messageID: "<2@example.com>", references: ["<1@example.com>"], from: sam,
                                 to: [noor, me], subject: "Re: Launch", date: Date(timeIntervalSince1970: 200))
        return MailThread(id: "t", messages: [first, second], accountID: nil)
    }

    @Test func repliesToAnOlderMessageNotTheLatest() {
        let thread = thread()
        let draft = Draft.reply(to: thread.messages[0], in: thread, from: me)
        #expect(draft.to == [noor])
        #expect(draft.cc.isEmpty)
        #expect(draft.inReplyTo == "<1@example.com>")
        #expect(draft.subject == "Re: Launch")
    }

    @Test func replyAllCopiesEveryoneOnThatMessage() {
        let thread = thread()
        let draft = Draft.reply(to: thread.messages[0], in: thread, from: me, all: true)
        #expect(draft.to == [noor])
        #expect(Set(draft.cc.map(\.address)) == ["sam@example.com", "maya@example.com"])
    }

    @Test func aPlainReplyStillAnswersTheLatest() {
        let thread = thread()
        #expect(Draft.reply(to: thread, from: me).to == [sam])
        #expect(Draft.reply(to: thread, from: me).inReplyTo == "<2@example.com>")
    }
}
