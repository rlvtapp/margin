import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct RowCodeTests {
    func thread(sent date: Date) -> MailThread {
        let message = MailMessage(id: UUID().uuidString, mailboxID: "INBOX", from: EmailAddress(name: "Speedrun", address: "login@speedrun.example"),
                                  to: [EmailAddress(address: "alex@example.com")], subject: "Your Speedrun login code", date: date,
                                  snippet: "Your Speedrun login code is: Y7024GVWL0 This code expires in 2 minutes.")
        return MailThread(id: message.id, messages: [message])
    }

    @Test func aNewCodeShowsOnItsRowAndAnOldOneDoesnt() {
        let model = MailModel(environment: .preview())
        let now = Date()
        #expect(model.rowSignInCode(in: thread(sent: now.addingTimeInterval(-120)), now: now) == "Y7024GVWL0")
        #expect(model.rowSignInCode(in: thread(sent: now.addingTimeInterval(-2 * 3600)), now: now) == nil)
    }

    @Test func onlyDigitCodesAreSpacedOut() {
        #expect(ReaderSuggestion.spaced("481207") == "481 207")
        #expect(ReaderSuggestion.spaced("K7Q9XM") == "K7Q9XM")
    }
}
