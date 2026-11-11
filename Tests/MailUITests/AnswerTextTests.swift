import Testing
@testable import MailUI

@Suite struct AnswerTextTests {
    /// A first sentence, then a list: one paragraph and a bullet per item, whatever the marker.
    @Test func splitsParagraphsAndBullets() {
        let text = "Three meetings this week.\n\n- **Tue 10:00** Design review\n* Wed lunch with Noor\n2. Fri 15:00 call\nThat's all."
        #expect(AnswerText.blocks(text) == [
            .paragraph("Three meetings this week."),
            .bullet("**Tue 10:00** Design review"),
            .bullet("Wed lunch with Noor"),
            .bullet("Fri 15:00 call"),
            .paragraph("That's all."),
        ])
    }

    /// Wrapped lines of one paragraph join up; a year like "2026." isn't a list item.
    @Test func keepsParagraphsTogether() {
        #expect(AnswerText.blocks("Paid on 7 Nov\n2026. Nothing else.") == [.paragraph("Paid on 7 Nov 2026. Nothing else.")])
    }
}
