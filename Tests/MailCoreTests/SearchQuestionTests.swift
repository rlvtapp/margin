import Testing
@testable import MailCore

@Suite struct SearchQuestionTests {
    @Test func recognisesQuestions() {
        #expect(SearchQuery.looksLikeQuestion("when is my flight to Lisbon"))
        #expect(SearchQuery.looksLikeQuestion("what did Noor say about the flat?"))
        #expect(SearchQuery.looksLikeQuestion("wanneer komt het pakket"))
        #expect(SearchQuery.looksLikeQuestion("did Sam pay the invoice"))
        #expect(SearchQuery.looksLikeQuestion("rent for May?"))
    }

    @Test func leavesSearchesAlone() {
        #expect(!SearchQuery.looksLikeQuestion("lisbon flight"))
        #expect(!SearchQuery.looksLikeQuestion("invoice"))
        #expect(!SearchQuery.looksLikeQuestion("from:noor is:unread flat"))
        #expect(!SearchQuery.looksLikeQuestion("what?"))
        #expect(!SearchQuery.looksLikeQuestion("Quarterly planning notes"))
    }
}

@Suite struct PreviewTidyTests {
    /// Plain-text dividers don't fill the preview line.
    @Test func dropsDividers() {
        #expect(HTMLText.snippet("Dear Kaan,\n------------------------------------------------\nWe've received your request.")
                == "Dear Kaan, We've received your request.")
        #expect(HTMLText.tidyPreview("Hello Kaan, -------------------- You've provided this address")
                == "Hello Kaan, You've provided this address")
        #expect(HTMLText.tidyPreview("Total ==== €12 ____ paid ***") == "Total €12 paid")
        // Ordinary punctuation stays.
        #expect(HTMLText.tidyPreview("A well-known co-op -- see you") == "A well-known co-op -- see you")
    }
}
