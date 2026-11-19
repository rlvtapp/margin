import Foundation
import Testing
@testable import MailCore

@Suite struct SearchOperatorTests {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// 2026-11-19 12:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_795_089_600)

    static func query(_ text: String) -> SearchQuery { SearchQuery(text, now: now, calendar: utc) }
    static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day))!
    }

    // MARK: Parsing

    @Test func readsOperators() {
        let query = Self.query(#"from:maya to:sam subject:"launch plan" has:attachment is:unread budget"#)
        #expect(query.from == ["maya"])
        #expect(query.to == ["sam"])
        #expect(query.subject == ["launch plan"])
        #expect(query.hasAttachment)
        #expect(query.isUnread == true)
        #expect(query.words == ["budget"])
    }

    @Test func freeTextStaysText() {
        let query = Self.query("Lisbon flight re: http://x.test")
        #expect(query.words == ["lisbon", "flight", "re:", "http://x.test"])
        #expect(query.from.isEmpty && query.mailbox == nil && query.after == nil)
    }

    @Test func operatorsIgnoreCase() {
        let query = Self.query("FROM:Maya IS:Unread In:Sent")
        #expect(query.from == ["maya"])
        #expect(query.isUnread == true)
        #expect(query.mailbox == "sent")
        #expect(query.mailboxRole == .sent)
    }

    @Test func readsDates() {
        let query = Self.query("after:2026/03/14 before:2026-04-01")
        #expect(query.after == Self.day(2026, 3, 14))
        #expect(query.before == Self.day(2026, 4, 1))
        #expect(Self.query("after:2026/3/4").after == Self.day(2026, 3, 4))
    }

    @Test func readsRelativeDates() {
        #expect(Self.query("older_than:7d").before == Self.now.addingTimeInterval(-7 * 86_400))
        #expect(Self.query("older_than:2w").before == Self.now.addingTimeInterval(-14 * 86_400))
        #expect(Self.query("newer_than:1m").after == Self.utc.date(byAdding: .month, value: -1, to: Self.now))
        #expect(Self.query("older_than:1y").before == Self.utc.date(byAdding: .year, value: -1, to: Self.now))
    }

    @Test func badDatesStayWords() {
        #expect(Self.query("before:tomorrow").before == nil)
        #expect(Self.query("before:tomorrow").words == ["before:tomorrow"])
        #expect(Self.query("after:2026/02/30").after == nil)
        #expect(Self.query("older_than:7x").words == ["older_than:7x"])
    }

    @Test func readsIn() {
        #expect(Self.query("in:people").split == .people)
        #expect(Self.query("in:people").mailbox == nil)
        #expect(Self.query("in:spam").mailboxRole == .junk)
        #expect(Self.query("in:starred").isStarred == true)
        #expect(Self.query("in:anywhere").mailbox == nil)
        #expect(Self.query("in:anywhere").isEmpty)
        #expect(Self.query("in:receipts").mailbox == "receipts")
        #expect(Self.query("in:receipts").mailboxRole == nil)
    }

    @Test func findsTheFolderInNamed() {
        let boxes = [
            Mailbox(id: "INBOX", name: "Inbox", role: .inbox),
            Mailbox(id: "[Mail]/All", name: "All Mail", role: .all),
            Mailbox(id: "Work/Receipts", name: "Receipts", role: .other),
        ]
        #expect(Self.query("in:inbox").mailbox(in: boxes)?.id == "INBOX")
        #expect(Self.query("in:archive").mailbox(in: boxes)?.id == "[Mail]/All")
        #expect(Self.query("in:receipts").mailbox(in: boxes)?.id == "Work/Receipts")
        #expect(Self.query("in:nowhere").mailbox(in: boxes) == nil)
        #expect(Self.query("budget").mailbox(in: boxes) == nil)
    }

    @Test func savedMailTermsLeaveOperatorsOut() {
        #expect(Self.query("from:maya is:unread budget").savedMailTerms == "budget maya")
        #expect(Self.query(#"subject:"launch plan""#).savedMailTerms == #""launch plan""#)
        #expect(Self.query("is:unread older_than:7d").savedMailTerms == "")
    }

    // MARK: Matching on the device

    static func message(_ id: String, mailbox: String = "INBOX", date: Date) -> MailMessage {
        MailMessage(id: id, mailboxID: mailbox, from: EmailAddress(name: "Maya", address: "maya@example.com"),
                    to: [EmailAddress(address: "me@example.com")], subject: "Plan", date: date)
    }

    @Test func matchesDates() {
        let thread = MailThread(id: "1", messages: [Self.message("1", date: Self.day(2026, 3, 20))])
        #expect(Self.query("after:2026/03/14").matches(thread))
        #expect(!Self.query("after:2026/03/21").matches(thread))
        #expect(Self.query("before:2026/03/21").matches(thread))
        #expect(!Self.query("before:2026/03/20").matches(thread))
        #expect(Self.query("older_than:7d").matches(thread))
        #expect(!Self.query("newer_than:7d").matches(thread))
    }

    @Test func matchesFolders() {
        let boxes = [Mailbox(id: "INBOX", name: "Inbox", role: .inbox), Mailbox(id: "Sent", name: "Sent", role: .sent)]
        let thread = MailThread(id: "1", messages: [Self.message("1", mailbox: "Sent", date: Self.now)])
        #expect(Self.query("in:sent").matches(thread, in: boxes))
        #expect(!Self.query("in:inbox").matches(thread, in: boxes))
        // A folder the account doesn't have narrows nothing.
        #expect(Self.query("in:receipts").matches(thread, in: boxes))
    }

    // MARK: IMAP

    @Test func buildsIMAPCriteria() {
        let criteria = IMAPSearch.criteria(Self.query(#"from:maya to:sam subject:"launch plan" is:unread is:starred budget"#), calendar: Self.utc)
        #expect(criteria == #"FROM "maya" OR TO "sam" CC "sam" SUBJECT "launch plan" UNSEEN FLAGGED TEXT "budget""#)
    }

    @Test func buildsIMAPDates() {
        #expect(IMAPSearch.criteria(Self.query("after:2026/03/04 before:2026/12/31"), calendar: Self.utc) == "SINCE 4-Mar-2026 BEFORE 31-Dec-2026")
        #expect(IMAPSearch.criteria(Self.query("older_than:7d"), calendar: Self.utc) == "BEFORE 12-Nov-2026")
        #expect(IMAPSearch.date(Self.day(2026, 1, 9), calendar: Self.utc) == "9-Jan-2026")
    }

    @Test func buildsIMAPAttachmentsAndRead() {
        #expect(IMAPSearch.criteria(Self.query("has:attachment is:read"), calendar: Self.utc) == #"HEADER Content-Type "multipart/mixed" SEEN"#)
    }

    @Test func folderAloneSearchesEverythingInIt() {
        #expect(IMAPSearch.criteria(Self.query("in:sent")) == "ALL")
        #expect(IMAPSearch.criteria(Self.query("")) == nil)
    }

    @Test func escapesIMAPQuotes() {
        #expect(IMAPSearch.criteria(Self.query(#"subject:a\b"#)) == #"SUBJECT "a\\b""#)
    }

    @Test func leavesNonASCIIToSavedMail() {
        #expect(IMAPSearch.criteria(Self.query("café")) == nil)
        #expect(IMAPSearch.criteria(Self.query("from:zoë")) == nil)
        #expect(IMAPSearch.rawCriteria(Self.query("café")) == nil)
    }

    @Test func buildsRawSearch() {
        let query = Self.query(#"from:maya subject:"launch plan" has:attachment is:unread in:people budget"#)
        #expect(IMAPSearch.rawText(query) == #"from:maya subject:"launch plan" has:attachment is:unread budget"#)
        #expect(IMAPSearch.rawCriteria(query) == #"X-GM-RAW "from:maya subject:\"launch plan\" has:attachment is:unread budget""#)
    }

    @Test func rawSearchDatesAreExact() {
        let after = Self.day(2026, 3, 14)
        #expect(IMAPSearch.rawText(Self.query("after:2026/03/14")) == "after:\(Int(after.timeIntervalSince1970))")
        let week = Self.now.addingTimeInterval(-7 * 86_400)
        #expect(IMAPSearch.rawText(Self.query("older_than:7d")) == "before:\(Int(week.timeIntervalSince1970))")
    }

    // MARK: JMAP

    static func json(_ value: [String: Any]?) -> String {
        guard let value, let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "nil" }
        return String(decoding: data, as: UTF8.self)
    }

    @Test func buildsJMAPFilter() {
        let filter = JMAPSearch.filter(Self.query("from:maya is:unread budget plan"))
        #expect(Self.json(filter) == #"{"conditions":[{"from":"maya"},{"notKeyword":"$seen"},{"text":"budget plan"}],"operator":"AND"}"#)
    }

    @Test func oneJMAPConditionStandsAlone() {
        #expect(Self.json(JMAPSearch.filter(Self.query("budget"))) == #"{"text":"budget"}"#)
        #expect(Self.json(JMAPSearch.filter(Self.query("has:attachment"))) == #"{"hasAttachment":true}"#)
        #expect(JMAPSearch.filter(Self.query("in:people")) == nil)
    }

    @Test func buildsJMAPRecipientsFlagsAndFolders() {
        let filter = JMAPSearch.filter(Self.query("to:sam is:starred is:read"), mailboxID: "m1")
        #expect(Self.json(filter) == #"{"conditions":[{"conditions":[{"to":"sam"},{"cc":"sam"}],"operator":"OR"},{"hasKeyword":"$seen"},{"hasKeyword":"$flagged"},{"inMailbox":"m1"}],"operator":"AND"}"#)
    }

    @Test func buildsJMAPDates() {
        let filter = JMAPSearch.filter(Self.query("after:2026/03/14 before:2026/04/01"))
        #expect(Self.json(filter) == #"{"conditions":[{"after":"2026-03-14T00:00:00Z"},{"before":"2026-04-01T00:00:00Z"}],"operator":"AND"}"#)
    }
}
