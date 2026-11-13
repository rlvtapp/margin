import Foundation
import Testing
@testable import MailCore

@Suite struct MailNoticeTests {
    @Test func remindersReceiptsAndConfirmationsAskNothing() {
        #expect(MailNotice.expectsNoReply(subject: "Herinnering aan uw afspraak bij de tandarts",
                                          text: "Geachte, Graag herinneren wij u aan de volgende afspraak."))
        #expect(MailNotice.expectsNoReply(subject: "Uw afspraken", text: "Geachte, Graag herinneren wij u aan de volgende afspraken."))
        #expect(MailNotice.expectsNoReply(subject: "SG Commerce GmbH: € 71,30 EUR", text: "Authorized with SG Commerce GmbH."))
        #expect(MailNotice.expectsNoReply(subject: "Your booking is confirmed", text: "See you on Friday."))
        // A friend mentioning a confirmation doesn't make it one.
        #expect(!MailNotice.expectsNoReply(subject: "Re: Lisbon in May?", text: "Booked. Sending the confirmation in a minute."))
        // A person asking something does.
        #expect(!MailNotice.expectsNoReply(subject: "Dinner Friday?", text: "Hoi, zullen we vrijdag eten? Laat maar weten!"))
    }

    @Test func onlyBillsThatAskToPayNeedYou() {
        // An invoice notice with a due date and nothing to do: taken automatically.
        #expect(!MailNotice.asksForPayment(subject: "Your invoice is attached", text: """
            Your latest invoice is attached to this email.
            Invoice details:
            - Invoice ID: IN-84928116
            - Due on: October 21, 2026
            - Amount: $5.00
            You are receiving this because billing contact settings for this account send invoice notifications to this email address.
            """))
        #expect(!MailNotice.asksForPayment(subject: "Card payment of €42.10", text: "A payment of €42.10 was made with your card ending 4410."))
        #expect(!MailNotice.asksForPayment(subject: "Factuur november", text: "Het bedrag wordt automatisch afgeschreven van uw rekening."))
        // Asking to pay, a transfer to make, or a failed charge.
        #expect(MailNotice.asksForPayment(subject: "Invoice 1042", text: "Payment due by 1 December. Please pay via the link."))
        #expect(MailNotice.asksForPayment(subject: "Factuur", text: "Graag het bedrag overmaken naar IBAN NL00 BANK 0123 4567 89."))
        #expect(MailNotice.asksForPayment(subject: "Payment failed", text: "We couldn't charge the card ending in 4242."))
        #expect(MailNotice.asksForPayment(subject: "Aanmaning", text: "Uw factuur is nog niet betaald."))
    }

    @Test func serviceAddressesAreUpdates() {
        let message = MailMessage(id: "1", mailboxID: "INBOX", from: EmailAddress(name: nil, address: "service@paypal.example"),
                                  to: [], subject: "Receipt", date: Date(), snippet: "")
        #expect(InboxSplit.classify(message) == .updates)
    }
}
