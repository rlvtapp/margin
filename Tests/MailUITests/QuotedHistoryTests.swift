import Testing
@testable import MailUI

@Suite struct QuotedHistoryTests {
    @Test func foldsAGmailReplyAtItsQuote() {
        let html = """
        <div dir="ltr">Thanks all.  It takes a village.<div>I've submitted the insurance request.</div><div>Valerie</div></div><br>\
        <div class="gmail_quote gmail_quote_container"><div dir="ltr" class="gmail_attr">On Tue, Nov 10, 2026 at 4:48 PM Jodi Roberts \
        &lt;jodi@example.ca&gt; wrote:<br></div><blockquote class="gmail_quote">Sorry for speaking for Gillian</blockquote></div>
        """
        let head = QuotedHistory.htmlWithoutQuote(html)
        #expect(head?.contains("It takes a village") == true)
        #expect(head?.contains("Valerie") == true)
        #expect(head?.contains("wrote:") == false)
        #expect(head?.contains("Sorry for speaking") == false)
    }

    @Test func takesTheOnWroteLineAlongWhenItSitsOutsideTheQuote() {
        let html = """
        <div>Sounds good, see you Friday.</div><div><br></div><div dir="ltr"><span>On 10 Nov 2026, at 16:41, Jodi Roberts \
        &lt;jodi@example.ca&gt; wrote:</span></div><blockquote type="cite"><div>No, these are items owned by Sardis.</div></blockquote>
        """
        let head = QuotedHistory.htmlWithoutQuote(html)
        #expect(head?.contains("see you Friday") == true)
        #expect(head?.contains("wrote:") == false)
        #expect(head?.contains("Jodi Roberts") == false)
        // A sentence that merely starts with "On" is not that line.
        let plain = "<div>On Monday we ship.</div><blockquote type=\"cite\">Earlier</blockquote>"
        #expect(QuotedHistory.htmlWithoutQuote(plain)?.contains("On Monday we ship.") == true)
    }

    @Test func leavesMailWithNoQuoteOrOnlyAQuoteAlone() {
        #expect(QuotedHistory.htmlWithoutQuote("<p>Just a note.</p>") == nil)
        #expect(QuotedHistory.htmlWithoutQuote("<blockquote type=\"cite\">Only the old mail</blockquote>") == nil)
        #expect(QuotedHistory.textWithoutQuote("Just a note.") == nil)
        #expect(QuotedHistory.textWithoutQuote("> only quoted") == nil)
    }

    @Test func foldsTextMailAtTheQuote() {
        let text = "Thanks for the clarification.\nValerie\n\nOn Tue, Nov 10, 2026 at 4:41 PM Jodi Roberts <jodi@example.ca> wrote:\n> No, these are items owned by Sardis."
        #expect(QuotedHistory.textWithoutQuote(text) == "Thanks for the clarification.\nValerie")
    }

    @Test func forwardsAreNotFolded() {
        #expect(QuotedHistory.isForward("Fwd: Insurance request"))
        #expect(QuotedHistory.isForward("FW: Insurance request"))
        #expect(QuotedHistory.isForward("WG: Anfrage"))
        #expect(!QuotedHistory.isForward("Re: Insurance request"))
        #expect(!QuotedHistory.isForward("Forward planning"))
    }

    @Test func foldsTheNewOutlooksQuoteContainer() {
        let html = """
        <div style="font-family: Aptos">Best,<br>Kaan</div><div id="mail-editor-reference-message-container">\
        <div style="padding: 3pt 0in 0in; border-width: 1pt medium medium; border-style: solid none none;">\
        <div><b>From:</b> Support &lt;support@example.com&gt;<br><b>Date:</b> Wednesday, 11 November 2026 at 01:13<br>\
        <b>To:</b> Hello<br><b>Subject:</b> Startup Program application<br></div></div><div>Hello team, I would like to apply.</div></div>
        """
        let head = QuotedHistory.htmlWithoutQuote(html)
        #expect(head?.contains("Kaan") == true)
        #expect(head?.contains("From:") == false)
        #expect(head?.contains("I would like to apply") == false)
    }

    @Test func foldsClassicOutlooksFromSentBlock() {
        let html = """
        <p class="MsoNormal">Sounds good.</p><div style="border:none;border-top:solid #E1E1E1 1.0pt;padding:3.0pt 0cm 0cm 0cm">\
        <p class="MsoNormal"><b>From:</b> Jodi Roberts &lt;jodi@example.ca&gt; <br><b>Sent:</b> Tuesday, November 10, 2026 4:41 PM<br>\
        <b>To:</b> Valerie<br><b>Subject:</b> RE: Insurance</p></div><p class="MsoNormal">No, these are items owned by Sardis.</p>
        """
        let head = QuotedHistory.htmlWithoutQuote(html)
        #expect(head?.contains("Sounds good.") == true)
        #expect(head?.contains("border-top") == false)
        #expect(head?.contains("owned by Sardis") == false)
        // Bold "From:" in ordinary writing, with no "Sent:" after it, is not a quote.
        #expect(QuotedHistory.htmlWithoutQuote("<p><b>From:</b> the kitchen team, with love.</p><p>See you Friday.</p>") == nil)
    }

    @Test func foldsARuleAndPlainHeaderRowsWithTheQuote() {
        let html = """
        <div>Thanks, that works for us.<br>Kaan</div><br><hr><div>From: Kaan Mol &lt;kaan@example.app&gt;<br>\
        To: "Support" &lt;support@example.com&gt;, "Hello" &lt;hello@example.app&gt;<br>Date: Wed, 11 Nov 2026 02:33:14 +0200<br>\
        Subject: Re: Startup Program application</div><br><blockquote>Hello team, I would like to apply.</blockquote>
        """
        let head = QuotedHistory.htmlWithoutQuote(html)
        #expect(head?.contains("that works for us") == true)
        #expect(head?.contains("<hr") == false)
        #expect(head?.contains("From:") == false)
        #expect(head?.contains("Subject:") == false)
    }

    @Test func aBookingsFromAndToAreNotAQuote() {
        let html = "<div>Your trip is booked.</div><div>From: Amsterdam<br>To: Lisbon<br>Date: 14 May</div><div>Have a good flight.</div>"
        #expect(QuotedHistory.htmlWithoutQuote(html) == nil)
    }
}
