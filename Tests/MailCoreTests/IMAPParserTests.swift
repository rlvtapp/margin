import Testing
@testable import MailCore

@Suite struct IMAPParserTests {
    @Test func parsesStatusResponses() throws {
        #expect(try IMAPParser.parse(Array("* OK [CAPABILITY IMAP4rev1 MOVE] Ready\r\n".utf8))
            == .untaggedStatus(.ok, "[CAPABILITY IMAP4rev1 MOVE] Ready"))
        #expect(try IMAPParser.parse(Array("M4 NO [AUTHENTICATIONFAILED] Invalid \"credentials\"\r\n".utf8))
            == .tagged(tag: "M4", status: .no, text: "[AUTHENTICATIONFAILED] Invalid \"credentials\""))
        #expect(try IMAPParser.parse(Array("+ go ahead\r\n".utf8)) == .continuation("go ahead"))
    }

    @Test func framesLiterals() {
        #expect(IMAPParser.literalLength(endingLine: Array("* 1 FETCH (BODY[] {42}\r\n".utf8)) == 42)
        #expect(IMAPParser.literalLength(endingLine: Array("A1 APPEND x {7+}\r\n".utf8)) == 7)
        #expect(IMAPParser.literalLength(endingLine: Array("* OK done {not}\r\n".utf8)) == nil)
        #expect(IMAPParser.literalLength(endingLine: Array("* 3 EXISTS\r\n".utf8)) == nil)
    }

    @Test func parsesFetchWithEnvelopeAndLiteral() throws {
        let header = "List-Id: <news.example>\r\nReferences: <root@studio.example>\r\n\r\n"
        let wire = "* 7 FETCH (UID 101 FLAGS (\\Seen \\Flagged) RFC822.SIZE 400 "
            + "ENVELOPE (\"Tue, 3 Nov 2026 10:00:00 +0100\" \"=?UTF-8?B?w4l0w6k=?= plans\" "
            + "((\"Maya \\\"ML\\\" Lindqvist\" NIL \"maya\" \"studio.example\")) NIL NIL "
            + "((NIL NIL \"me\" \"example.com\")) NIL NIL \"<root@studio.example>\" \"<a1@studio.example>\") "
            + "BODYSTRUCTURE ((\"text\" \"plain\" NIL NIL NIL \"7bit\" 3 1 NIL NIL NIL NIL)(\"application\" \"pdf\" (\"name\" \"a.pdf\") NIL NIL \"base64\" 10 NIL (\"attachment\" (\"filename\" \"a.pdf\")) NIL NIL) \"mixed\" NIL NIL NIL NIL) "
            + "BODY[HEADER.FIELDS (LIST-ID REFERENCES)] {\(header.utf8.count)}\r\n\(header))\r\n"
        guard case .untagged(let values) = try IMAPParser.parse(Array(wire.utf8)), let item = IMAPFetchItem(values) else {
            Issue.record("not a fetch")
            return
        }
        #expect(item.sequence == 7)
        #expect(item.uid == 101)
        #expect(item.flags == [.seen, .flagged])
        #expect(item.size == 400)
        #expect(item.bodyStructureHasAttachment)
        let envelope = try #require(item.envelope)
        #expect(envelope.subject == "Été plans")
        #expect(envelope.from == [EmailAddress(name: "Maya \"ML\" Lindqvist", address: "maya@studio.example")])
        #expect(envelope.to == [EmailAddress(address: "me@example.com")])
        #expect(envelope.inReplyTo == "root@studio.example")
        #expect(envelope.messageID == "a1@studio.example")
        #expect(envelope.date != nil)
        let headers = MIMEHeaders.parse(String(decoding: item.sections["HEADER.FIELDS (LIST-ID REFERENCES)"] ?? [], as: UTF8.self))
        #expect(headers["list-id"] == "<news.example>")
    }

    @Test func parsesListAndRoles() throws {
        let lines = [
            "* LIST (\\HasNoChildren) \"/\" INBOX",
            "* LIST (\\HasNoChildren \\Sent) \"/\" \"Sent Items\"",
            "* LIST (\\Noselect \\HasChildren) \"/\" \"[Gmail]\"",
            "* LIST (\\HasNoChildren \\All) \"/\" \"[Gmail]/All Mail\"",
            "* LIST (\\HasNoChildren) \"/\" \"Deleted Items\"",
            "* LIST (\\HasNoChildren) \"/\" \"Entw&APw-rfe\"",
        ]
        let items = try lines.map { line -> IMAPListItem in
            guard case .untagged(let values) = try IMAPParser.parse(Array((line + "\r\n").utf8)),
                  let item = IMAPListItem(values) else { throw MailError.protocolViolation(line) }
            return item
        }
        #expect(items.map(\.role) == [.inbox, .sent, .other, .all, .trash, .other])
        #expect(items[2].isSelectable == false)
        #expect(ModifiedUTF7.decode(items[5].name) == "Entwürfe")
        #expect(ModifiedUTF7.decode("A&-B") == "A&B")
    }

    @Test func quotesAndCompressesSets() {
        #expect(IMAPParser.quoted("pa\"ss\\word") == "\"pa\\\"ss\\\\word\"")
        #expect(IMAPParser.quoted("two\nlines") == nil)
        #expect(IMAPClient.set([5, 1, 2, 3, 9, 10]) == "1:3,5,9:10")
    }

    @Test func rejectsUnclosedLists() {
        #expect(throws: MailError.self) { try IMAPParser.parse(Array("* 1 FETCH (UID 4\r\n".utf8)) }
    }
}
