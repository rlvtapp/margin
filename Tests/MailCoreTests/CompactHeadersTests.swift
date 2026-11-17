import Foundation
import Testing
@testable import MailCore

/// List headers are kept small in memory and saved mail, and sorting reads them the same way.
@Suite struct CompactHeadersTests {
    @Test func bulkHeadersKeepOnlyThatTheyreThere() {
        let raw = ["x-sg-eid": String(repeating: "u001.pDXn7XyDvIUG5VuGYC", count: 20), "references": "<a@x> <b@x>",
                   "list-unsubscribe": "<https://example.com/u>", "list-unsubscribe-post": "List-Unsubscribe=One-Click"]
        let kept = InboxSplit.compact(raw)
        #expect(kept["x-sg-eid"] == "")
        #expect(kept["references"] == nil)
        #expect(kept["list-unsubscribe"] == raw["list-unsubscribe"])
        #expect(kept["list-unsubscribe-post"] == raw["list-unsubscribe-post"])

        func message(_ headers: [String: String]) -> MailMessage {
            MailMessage(id: "INBOX/1", mailboxID: "INBOX", from: EmailAddress(address: "noreply@shop.example"), subject: "Order",
                        date: Date(), listHeaders: headers)
        }
        let bulk = ["x-sg-eid": "abc", "feedback-id": "1:2:3"]
        #expect(InboxSplit.classify(message(InboxSplit.compact(bulk))) == InboxSplit.classify(message(bulk)))
        #expect(Unsubscribe.method(from: kept) == Unsubscribe.method(from: raw))
    }
}

/// Previews read as text: what plain-text versions of designed mail leave in them goes.
@Suite struct PreviewAddressTests {
    @Test func linksKeepTheirWordsAndAddressesGo() {
        #expect(HTMLText.tidyPreview("[Secretlab](https://secretlab.eu/nl) [Holiday Shop](https://secretlab.eu/nl/pages/holiday) Gifts for everyone")
                == "Secretlab Holiday Shop Gifts for everyone")
        // Cut off by the end of the preview, in the address or in the words.
        #expect(HTMLText.tidyPreview("[Secretlab](https://secretlab.eu/nl) [Holiday Shop](https://secretlab.eu/nl/pa") == "Secretlab Holiday Shop")
        #expect(HTMLText.tidyPreview("Shop now at Secretlab [Holiday Sh") == "Shop now at Secretlab Holiday Sh")
        #expect(HTMLText.tidyPreview("Read it online <https://news.example/1> or (https://news.example/2) today") == "Read it online or today")
        #expect(HTMLText.tidyPreview("See https://example.com/a?b=1 for more") == "See for more")
    }

    @Test func commentMarksGo() {
        #expect(HTMLText.tidyPreview("--> --> Microsoft Defender Smart Network Data") == "Microsoft Defender Smart Network Data")
        #expect(HTMLText.tidyPreview("<!--[if mso]> Hello <![endif]--> there") == "Hello there")
        // Ordinary words with arrows and brackets stay.
        #expect(HTMLText.tidyPreview("Price -> €20 [sale] (today)") == "Price -> €20 [sale] (today)")
        #expect(HTMLText.snippet("[Secretlab](https://secretlab.eu/nl)\n\nCadeau gids") == "Secretlab Cadeau gids")
    }
}
