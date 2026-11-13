import Foundation
import Testing
@testable import MailCore

/// An answer only shows the conversations it actually speaks of, and never borrows names from
/// the instructions it was given.
@Suite struct AnswerSourcesTests {
    private let me = EmailAddress(name: "Alex Rivera", address: "alex@example.com")

    private func thread(from: EmailAddress, subject: String, text: String) -> (MailThread, [String: MessageBody]) {
        let message = MailMessage(id: UUID().uuidString, mailboxID: "INBOX", from: from, to: [me], subject: subject, date: Date())
        return (MailThread(id: message.id, messages: [message]), [message.id: MessageBody(text: text, html: nil, attachments: [])])
    }

    @Test func anUnrelatedVerificationMailIsNotASource() {
        let (verification, bodies) = thread(from: EmailAddress(name: nil, address: "no-reply@signin.example"),
                                            subject: "Verify your Builder ID email address", text: "Your verification code is 482913.")
        let answer = "You have a meeting with the design team at 15:00 today, and a second round on 17 November."
        #expect(!MailIntelligence.answer(answer, speaksOf: verification, bodies: bodies))
    }

    @Test func theSenderNamedInTheAnswerIsASource() {
        let (mail, bodies) = thread(from: EmailAddress(name: "Sam Okafor", address: "sam@example.com"),
                                    subject: "Invoice question", text: "Quick one: the October invoice lists 14 seats.")
        #expect(MailIntelligence.answer("Sam is waiting to hear about the October invoice.", speaksOf: mail, bodies: bodies))
    }

    @Test func aTellingSubjectWordIsEnough() {
        let (mail, bodies) = thread(from: EmailAddress(name: nil, address: "billing@power.example"),
                                    subject: "Your electricity bill for October", text: "Amount due: 84,20.")
        #expect(MailIntelligence.answer("Your electricity bill is due.", speaksOf: mail, bodies: bodies))
    }

    @Test func aTimeFromTheMailIsEnoughEvenInAnotherLanguage() {
        let (mail, bodies) = thread(from: EmailAddress(name: nil, address: "bookings@air.example"),
                                    subject: "Booking confirmation", text: "Your flight departs at 09:40 on Friday from gate B12.")
        #expect(MailIntelligence.answer("Je vlucht vertrekt vrijdag om 09:40.", speaksOf: mail, bodies: bodies))
    }

    @Test func theInstructionsCarryNoNamesToCopy() {
        let request = MailIntelligence.answerRequest("What needs a reply from me?", threads: [], me: me, budget: 4000,
                                                     facts: "Mail that needs a reply: none.")
        #expect(!request.instructions.contains("Noor"))
        #expect(request.instructions.contains("exactly as"))
        #expect(request.prompt.contains("Mail that needs a reply: none."))
    }
}
