import Foundation
import Testing
@testable import MailCore

/// A pretend Graph: each request is answered by the first route whose method and URL match,
/// from recorded answers in Fixtures/Graph. Remembers every request.
final class GraphMailFake: @unchecked Sendable {
    struct Route {
        var method: String
        var match: String
        /// For batches: answers only when the request body mentions this.
        var bodyContains: String?
        var status: Int
        var body: Data
    }

    private let lock = NSLock()
    private var routes: [Route] = []
    private(set) var requests: [URLRequest] = []

    func on(_ method: String = "GET", _ match: String, body bodyContains: String? = nil, status: Int = 200, fixture: String) throws {
        let name = (fixture as NSString).deletingPathExtension
        let type = (fixture as NSString).pathExtension
        let url = try #require(Bundle.module.url(forResource: name, withExtension: type, subdirectory: "Fixtures/Graph"))
        try on(method, match, body: bodyContains, status: status, data: Data(contentsOf: url))
    }

    func on(_ method: String = "GET", _ match: String, body bodyContains: String? = nil, status: Int = 200, json: String = "{}") {
        on(method, match, body: bodyContains, status: status, data: Data(json.utf8))
    }

    func on(_ method: String, _ match: String, body bodyContains: String?, status: Int, data: Data) {
        lock.withLock { routes.append(Route(method: method, match: match, bodyContains: bodyContains, status: status, body: data)) }
    }

    var send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) {
        { [self] request in
            let url = request.url!.absoluteString.removingPercentEncoding ?? request.url!.absoluteString
            let text = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            let route = lock.withLock { () -> Route? in
                requests.append(request)
                return routes.first {
                    $0.method == (request.httpMethod ?? "GET") && url.contains($0.match)
                        && ($0.bodyContains.map(text.contains) ?? true)
                }
            }
            let status = route?.status ?? 404
            let body = route?.body ?? Data(#"{"error":{"code":"NotFound","message":"not found"}}"#.utf8)
            return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
    }

    func sent(_ method: String, _ match: String) -> [URLRequest] {
        lock.withLock {
            requests.filter { ($0.httpMethod ?? "GET") == method && ($0.url!.absoluteString.removingPercentEncoding ?? "").contains(match) }
        }
    }

    func json(_ method: String, _ match: String) -> [String: Any]? {
        sent(method, match).last?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// The requests inside every batch sent.
    func batched() -> [[String: Any]] {
        sent("POST", "/$batch").flatMap { request -> [[String: Any]] in
            let object = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return object?["requests"] as? [[String: Any]] ?? []
        }
    }
}

private struct FixedToken: CredentialSource {
    func secret(for account: MailAccount) async throws -> String { "graph-token" }
}

@Suite struct GraphMailTests {
    static let me = MailAccount(label: "Work", address: EmailAddress(name: "Alex Rivera", address: "alex@work.example"),
                                connection: .graph(), auth: .oauth(provider: .microsoft, username: "alex@work.example"),
                                providerID: "microsoft")
    static let inbox = Mailbox(id: "AAMkInbox=", name: "Inbox", role: .inbox)

    func provider(_ fake: GraphMailFake, account: MailAccount = me) throws -> GraphMailProvider {
        try GraphMailProvider(account: account, credentials: FixedToken(), send: fake.send)
    }

    func foldersFake() throws -> GraphMailFake {
        let fake = GraphMailFake()
        try fake.on("GET", "/me/mailFolders?$top=250&$select=id,displayName,parentFolderId,unreadItemCount,childFolderCount&$skip=4", fixture: "mailFolders-page2.json")
        try fake.on("GET", "/me/mailFolders/AAMkInbox=/childFolders", fixture: "childFolders.json")
        try fake.on("GET", "/me/mailFolders?", fixture: "mailFolders.json")
        try fake.on("POST", "/$batch", body: "mailFolders", fixture: "wellKnown-batch.json")
        return fake
    }

    // MARK: Folders

    @Test func foldersFollowPagesAndChildFoldersWithRoles() async throws {
        let fake = try foldersFake()
        let folders = try await provider(fake).mailboxes()
        #expect(folders.count == 7)
        let byName = Dictionary(uniqueKeysWithValues: folders.map { ($0.name, $0) })
        #expect(byName["Inbox"]?.role == .inbox && byName["Inbox"]?.unreadCount == 3)
        #expect(byName["Sent Items"]?.role == .sent)
        #expect(byName["Drafts"]?.role == .drafts)
        #expect(byName["Deleted Items"]?.role == .trash)
        #expect(byName["Junk Email"]?.role == .junk)
        #expect(byName["Archive"]?.role == .archive)
        // Inside Inbox; the top-level folders' parent (the hidden root) isn't one of them.
        #expect(byName["Projects"]?.parentID == "AAMkInbox=" && byName["Projects"]?.role == .other)
        #expect(byName["Inbox"]?.parentID == nil)
        // Every request asks for ids that survive moves, and carries the token.
        #expect(fake.requests.allSatisfy { $0.value(forHTTPHeaderField: "Prefer")?.contains("IdType=\"ImmutableId\"") == true })
        #expect(fake.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer graph-token" })
    }

    // MARK: Delta sync

    @Test func threadsListNewestThenFollowOnlyTheChanges() async throws {
        let fake = GraphMailFake()
        try fake.on("GET", "$deltatoken=round1", fixture: "inbox-delta-changes.json")
        try fake.on("GET", "/messages/delta", fixture: "inbox-delta-initial.json")
        try fake.on("GET", "/me/mailFolders/AAMkInbox=/messages?", fixture: "inbox-messages.json")
        try fake.on("POST", "/$batch", body: "AAkALgMsg4=", fixture: "new-message-batch.json")
        let graph = try provider(fake)

        let first = try await graph.threads(in: Self.inbox, limit: 3)
        #expect(first.map(\.id) == ["AAQkConvA=", "AAQkConvB="])
        #expect(first.first?.latest.threadID == "AAQkConvA=")
        let plan = try #require(first.first)
        #expect(plan.messages.map(\.id) == ["AAkALgMsg1=", "AAkALgMsg2="])
        let reply = plan.latest
        #expect(reply.isUnread && reply.isStarred)
        #expect(reply.from == EmailAddress(name: "Noor Haddad", address: "noor@work.example"))
        #expect(reply.messageID == "<reply-1@work.example>" && reply.inReplyTo == "<plan-1@work.example>")
        #expect(reply.references == ["<plan-1@work.example>"])
        #expect(GraphMailProvider.categories(of: reply) == ["Red category", "Planning"])
        #expect(reply.listHeaders["received"] == nil)
        #expect(plan.messages[0].hasAttachments)
        let invite = try #require(first.last?.latest)
        #expect(invite.calendarMethod == "REQUEST" && invite.listHeaders["list-id"] == "<design.work.example>")
        // The delta starts from the oldest message shown.
        let delta = try #require(fake.sent("GET", "/messages/delta").first?.url?.absoluteString.removingPercentEncoding)
        #expect(delta.contains("$filter=receivedDateTime ge 2026-11-16T08:00:00Z"))

        // Next time only the delta link is asked: one gone, one read and unflagged, one new.
        let second = try await graph.threads(in: Self.inbox, limit: 3)
        #expect(fake.sent("GET", "/me/mailFolders/AAMkInbox=/messages?").count == 1)
        #expect(second.map(\.id) == ["AAQkConvC=", "AAQkConvA="])
        let news = try #require(second.first?.latest)
        #expect(news.subject == "Your weekly digest" && news.isUnread)
        #expect(news.listHeaders["list-unsubscribe"] == "<https://news.example/unsubscribe>")
        #expect(news.listHeaders["feedback-id"] == "1234:news")
        let updated = try #require(second.last?.latest)
        #expect(!updated.isUnread && !updated.isStarred && GraphMailProvider.categories(of: updated).isEmpty)
    }

    @Test func anExpiredDeltaStartsTheFolderOver() async throws {
        let fake = GraphMailFake()
        fake.on("GET", "$deltatoken=round1", status: 410, json: #"{"error":{"code":"SyncStateNotFound","message":"Sync state not found"}}"#)
        try fake.on("GET", "/messages/delta", fixture: "inbox-delta-initial.json")
        try fake.on("GET", "/me/mailFolders/AAMkInbox=/messages?", fixture: "inbox-messages.json")
        let graph = try provider(fake)
        _ = try await graph.threads(in: Self.inbox, limit: 3)
        let again = try await graph.threads(in: Self.inbox, limit: 3)
        #expect(again.count == 2)
        #expect(fake.sent("GET", "/me/mailFolders/AAMkInbox=/messages?").count == 2)
    }

    // MARK: Reading

    @Test func bodiesAreTheMessageItselfWithItsFiles() async throws {
        let fake = GraphMailFake()
        try fake.on("GET", "/me/messages/AAkALgMsg2=/$value", fixture: "message.eml")
        let message = MailMessage(id: "AAkALgMsg2=", mailboxID: "AAMkInbox=", from: EmailAddress(address: "noor@work.example"),
                                  subject: "RE: Quarterly plan", date: Date())
        let body = try await provider(fake).body(of: message)
        #expect(body.text == "Sounds good, let's meet Thursday.")
        #expect(body.attachments.map(\.filename) == ["numbers.csv"])
        #expect(body.attachments.first?.data == Data("a,b\n1,2\n".utf8))
    }

    @Test func readableBodiesComeInABatchAndMarkMailWithFilesPartial() async throws {
        let fake = GraphMailFake()
        try fake.on("POST", "/$batch", fixture: "readable-batch.json")
        let messages = ["AAkALgMsg1=", "AAkALgMsg2=", "AAkALgGone="].map {
            MailMessage(id: $0, mailboxID: "AAMkInbox=", from: EmailAddress(address: "a@work.example"), subject: "", date: Date())
        }
        let bodies = try await provider(fake).readableBodies(of: messages)
        #expect(bodies.count == 2)
        #expect(bodies["AAkALgMsg1="]?.html?.contains("<b>draft</b>") == true)
        #expect(bodies["AAkALgMsg1="]?.text.contains("draft plan") == true)
        #expect(bodies["AAkALgMsg1="]?.isPartial == true)
        #expect(bodies["AAkALgMsg2="]?.html == nil && bodies["AAkALgMsg2="]?.isPartial == nil)
    }

    // MARK: Changes

    @Test func actionsGoInOneBatch() async throws {
        let fake = try foldersFake()
        try fake.on("POST", "/$batch", body: "destinationId", fixture: "action-batch.json")
        try fake.on("POST", "/$batch", body: "PATCH", fixture: "action-batch.json")
        let graph = try provider(fake)
        _ = try await graph.mailboxes()
        let thread = MailThread(id: "AAQkConvA=", messages: [
            MailMessage(id: "AAkALgMsg1=", mailboxID: "AAMkInbox=", from: EmailAddress(address: "a@work.example"), subject: "", date: Date()),
            MailMessage(id: "AAkALgMsg2=", mailboxID: "AAMkInbox=", from: EmailAddress(address: "a@work.example"), subject: "", date: Date()),
        ])

        try await graph.perform(.done, on: [thread])
        var batched = fake.batched().filter { ($0["url"] as? String)?.hasSuffix("/move") == true }
        #expect(batched.count == 2)
        #expect((batched.first?["body"] as? [String: Any])?["destinationId"] as? String == "AAMkArchive=")
        #expect((batched.first?["headers"] as? [String: String])?["Prefer"] == "IdType=\"ImmutableId\"")

        try await graph.perform(.star, on: [thread])
        batched = fake.batched().filter { $0["method"] as? String == "PATCH" }
        #expect(((batched.first?["body"] as? [String: Any])?["flag"] as? [String: String])?["flagStatus"] == "flagged")
    }

    @Test func trashMovesToDeletedItemsAndDeletesWhatsAlreadyThere() async throws {
        let fake = try foldersFake()
        fake.on("POST", "/$batch", body: "destinationId", json: #"{"responses":[{"id":"m1","status":201,"body":{}}]}"#)
        fake.on("POST", "/$batch", body: "DELETE", json: #"{"responses":[{"id":"m2","status":204}]}"#)
        let graph = try provider(fake)
        _ = try await graph.mailboxes()
        let inInbox = MailMessage(id: "m1", mailboxID: "AAMkInbox=", from: EmailAddress(address: "a@work.example"), subject: "", date: Date())
        let inTrash = MailMessage(id: "m2", mailboxID: "AAMkDeleted=", from: EmailAddress(address: "a@work.example"), subject: "", date: Date())
        try await graph.perform(.trash, on: [MailThread(id: "t1", messages: [inInbox])])
        try await graph.perform(.trash, on: [MailThread(id: "t2", messages: [inTrash])])
        let requests = fake.batched().filter { $0["method"] as? String != "GET" }
        #expect((requests.first?["body"] as? [String: Any])?["destinationId"] as? String == "AAMkDeleted=")
        #expect(requests.last?["method"] as? String == "DELETE" && requests.last?["url"] as? String == "/me/messages/m2")
    }

    @Test func failedChangesAreReported() async throws {
        let fake = GraphMailFake()
        fake.on("POST", "/$batch", json: #"{"responses":[{"id":"m1","status":404,"body":{"error":{"message":"gone"}}}]}"#)
        let message = MailMessage(id: "m1", mailboxID: "AAMkInbox=", from: EmailAddress(address: "a@work.example"), subject: "", date: Date())
        await #expect(throws: MailError.self) {
            try await provider(fake).perform(.markRead, on: [MailThread(id: "t", messages: [message])])
        }
    }

    @Test func categoriesAreSetOnEveryMessage() async throws {
        let fake = GraphMailFake()
        fake.on("POST", "/$batch", json: #"{"responses":[{"id":"m1","status":200,"body":{}}]}"#)
        let message = MailMessage(id: "m1", mailboxID: "AAMkInbox=", from: EmailAddress(address: "a@work.example"), subject: "", date: Date())
        try await provider(fake).setCategories(["Planning"], on: [MailThread(id: "t", messages: [message])])
        let request = try #require(fake.batched().first)
        #expect(request["method"] as? String == "PATCH")
        #expect((request["body"] as? [String: Any])?["categories"] as? [String] == ["Planning"])
    }

    @Test func labelsAreOutlookCategories() async throws {
        let fake = GraphMailFake()
        fake.on("POST", "/$batch", json: #"{"responses":[{"id":"m1","status":200,"body":{}}]}"#)
        var message = MailMessage(id: "m1", mailboxID: "AAMkInbox=", from: EmailAddress(address: "a@work.example"), subject: "", date: Date())
        message.labels = ["Planning", "Red category"]
        let thread = MailThread(id: "t", messages: [message])
        let graph = try provider(fake)
        try await graph.changeLabel("planning", adding: false, on: [thread])
        try await graph.changeLabel("Travel", adding: true, on: [thread])
        let bodies = fake.batched().map { ($0["body"] as? [String: Any])?["categories"] as? [String] }
        #expect(bodies == [["Red category"], ["Planning", "Red category", "Travel"]])
    }

    // MARK: Sending

    @Test func newMailGoesThroughSendMailWithItsFiles() async throws {
        let fake = GraphMailFake()
        fake.on("POST", "/me/sendMail", status: 202)
        var draft = Draft(from: Self.me.address, to: [EmailAddress(name: "Noor Haddad", address: "noor@work.example")],
                          bcc: [EmailAddress(address: "records@work.example")], subject: "Numbers", text: "See attached.")
        draft.attachments = [OutgoingAttachment(filename: "numbers.csv", mimeType: "text/csv", data: Data("a,b\n".utf8))]
        try await provider(fake).send(draft)
        let json = try #require(fake.json("POST", "/me/sendMail"))
        #expect(json["saveToSentItems"] as? Bool == true)
        let message = try #require(json["message"] as? [String: Any])
        #expect(message["subject"] as? String == "Numbers")
        #expect((message["body"] as? [String: String]) == ["contentType": "Text", "content": "See attached."])
        let to = try #require((message["toRecipients"] as? [[String: Any]])?.first?["emailAddress"] as? [String: String])
        #expect(to == ["name": "Noor Haddad", "address": "noor@work.example"])
        #expect((message["bccRecipients"] as? [Any])?.count == 1)
        #expect(message["from"] == nil)
        let file = try #require((message["attachments"] as? [[String: Any]])?.first)
        #expect(file["@odata.type"] as? String == "#microsoft.graph.fileAttachment")
        #expect(file["contentBytes"] as? String == Data("a,b\n".utf8).base64EncodedString())
    }

    @Test func repliesUseCreateReplyThenSend() async throws {
        let fake = GraphMailFake()
        fake.on("GET", "/me/messages?", json: #"{"value":[{"id":"AAkALgMsg2="}]}"#)
        try fake.on("POST", "/me/messages/AAkALgMsg2=/createReply", status: 201, fixture: "createReply.json")
        try fake.on("PATCH", "/me/messages/AAkALgDraft9=", fixture: "createReply.json")
        fake.on("POST", "/me/messages/AAkALgDraft9=/attachments", status: 201)
        fake.on("POST", "/me/messages/AAkALgDraft9=/send", status: 202)
        var draft = Draft(from: Self.me.address, to: [EmailAddress(address: "noor@work.example")], subject: "RE: Quarterly plan",
                          text: "Thursday works.", inReplyTo: "<reply-1@work.example>", references: ["<plan-1@work.example>", "<reply-1@work.example>"])
        draft.html = "<p>Thursday works.</p>"
        draft.attachments = [OutgoingAttachment(filename: "logo.png", mimeType: "image/png", data: Data([1, 2, 3]), contentID: "logo1")]
        try await provider(fake).send(draft)

        let lookup = try #require(fake.sent("GET", "/me/messages?").first?.url?.absoluteString.removingPercentEncoding)
        #expect(lookup.contains("$filter=internetMessageId eq '<reply-1@work.example>'"))
        let patch = try #require(fake.json("PATCH", "/me/messages/AAkALgDraft9="))
        #expect((patch["body"] as? [String: String])?["contentType"] == "HTML")
        let attachment = try #require(fake.json("POST", "/attachments"))
        #expect(attachment["isInline"] as? Bool == true && attachment["contentId"] as? String == "logo1")
        #expect(fake.sent("POST", "/me/messages/AAkALgDraft9=/send").count == 1)
        #expect(fake.sent("POST", "/me/sendMail").isEmpty)
    }

    @Test func aReplyToMailThatIsntThereIsSentAsNew() async throws {
        let fake = GraphMailFake()
        fake.on("GET", "/me/messages?", json: #"{"value":[]}"#)
        fake.on("POST", "/me/sendMail", status: 202)
        let draft = Draft(from: Self.me.address, to: [EmailAddress(address: "noor@work.example")], subject: "RE: Hi",
                          text: "Hello", inReplyTo: "elsewhere@work.example")
        try await provider(fake).send(draft)
        let lookup = try #require(fake.sent("GET", "/me/messages?").first?.url?.absoluteString.removingPercentEncoding)
        #expect(lookup.contains("'<elsewhere@work.example>'"))
        #expect(fake.sent("POST", "/me/sendMail").count == 1)
    }

    @Test func bigFilesGoUpInParts() async throws {
        let fake = GraphMailFake()
        fake.on("POST", "/me/messages/AAkALgDraft9=/attachments/createUploadSession",
                json: #"{"uploadUrl":"https://upload.example/AttachmentSessions/s?authtoken=x"}"#)
        fake.on("PUT", "AttachmentSessions", json: "{}")
        fake.on("POST", "/me/messages/AAkALgDraft9=/send", status: 202)
        fake.on("POST", "/me/messages", status: 201, json: #"{"id":"AAkALgDraft9="}"#)
        let big = Data(repeating: 7, count: GraphMailProvider.smallAttachment + GraphMailProvider.uploadChunk + 10)
        var draft = Draft(from: Self.me.address, to: [EmailAddress(address: "noor@work.example")], subject: "Video", text: "Here")
        draft.attachments = [OutgoingAttachment(filename: "clip.mov", mimeType: "video/quicktime", data: big)]
        try await provider(fake).send(draft)
        let parts = fake.sent("PUT", "AttachmentSessions")
        #expect(parts.count == 2)
        #expect(parts.first?.value(forHTTPHeaderField: "Content-Range") == "bytes 0-\(GraphMailProvider.uploadChunk - 1)/\(big.count)")
        // The upload address carries its own permission; the account's token isn't sent there.
        #expect(parts.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        #expect(fake.sent("POST", "/me/messages/AAkALgDraft9=/send").count == 1)
    }

    @Test func invitationAnswersGoAsTheMessageItself() async throws {
        let fake = GraphMailFake()
        fake.on("POST", "/me/sendMail", status: 202)
        var draft = Draft(from: Self.me.address, to: [EmailAddress(address: "sam@work.example")], subject: "Accepted: Design review", text: "Yes")
        draft.calendar = "BEGIN:VCALENDAR\r\nMETHOD:REPLY\r\nEND:VCALENDAR\r\n"
        try await provider(fake).send(draft)
        let request = try #require(fake.sent("POST", "/me/sendMail").first)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "text/plain")
        let mime = String(decoding: Data(base64Encoded: request.httpBody ?? Data()) ?? Data(), as: UTF8.self)
        #expect(mime.contains("text/calendar") && mime.contains("METHOD:REPLY"))
    }

    @Test func draftsAreFiledInDrafts() async throws {
        let fake = GraphMailFake()
        fake.on("POST", "/me/messages", status: 201, json: #"{"id":"AAkALgDraft1="}"#)
        try await provider(fake).saveDraft(Draft(from: Self.me.address, to: [EmailAddress(address: "noor@work.example")], subject: "Later", text: "Not yet"))
        let json = try #require(fake.json("POST", "/me/messages"))
        #expect(json["subject"] as? String == "Later")
    }

    // MARK: Search

    @Test func searchOperatorsBecomeKQL() throws {
        let utc = TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 19)))
        let query = SearchQuery(#"from:noor subject:"launch plan" has:attachment after:2026/01/01 budget is:unread"#, now: now, calendar: calendar)
        let parameters = try #require(GraphMailProvider.searchParameters(query, limit: 50, timeZone: utc))
        let search = try #require(parameters["$search"])
        #expect(search.hasPrefix("\"") && search.hasSuffix("\""))
        for term in ["budget", "from:noor", "subject:launch", "subject:plan", "hasAttachments:true", "received>=2026-01-01"] {
            #expect(search.contains(term), "\(term)")
        }
        // Graph won't take $filter beside $search: unread is checked on the results instead.
        #expect(parameters["$filter"] == nil && parameters["$orderby"] == nil)
    }

    @Test func unreadAndStarredAloneGoAsAFilter() throws {
        let parameters = try #require(GraphMailProvider.searchParameters(SearchQuery("is:unread is:starred"), limit: 20))
        #expect(parameters["$search"] == nil)
        #expect(parameters["$filter"] == "isRead eq false and flag/flagStatus eq 'flagged'")
    }

    @Test func searchInAFolderAsksThatFolder() async throws {
        let fake = try foldersFake()
        fake.on("GET", "/me/mailFolders/AAMkProjects=/messages?", json: #"{"value":[{"id":"m9","conversationId":"c9","subject":"Plan","isRead":false,"receivedDateTime":"2026-11-10T10:00:00Z","from":{"emailAddress":{"address":"noor@work.example"}}},{"id":"m8","conversationId":"c8","subject":"Plan","isRead":true,"receivedDateTime":"2026-11-09T10:00:00Z","from":{"emailAddress":{"address":"noor@work.example"}}}]}"#)
        let found = try await provider(fake).search("in:Projects plan is:unread", limit: 20)
        #expect(found.map(\.id) == ["c9"])
        #expect(found.first?.latest.mailboxID == "AAMkProjects=")
        let url = try #require(fake.sent("GET", "/messages?").last?.url?.absoluteString.removingPercentEncoding)
        #expect(url.contains(#"$search="plan""#))
    }

    // MARK: Shared mailboxes

    static let shared = MailAccount(label: "sales@work.example", address: EmailAddress(address: "sales@work.example"),
                                    connection: .graph(sharedMailbox: "sales@work.example"),
                                    auth: .oauth(provider: .microsoft, username: "alex@work.example"), providerID: "microsoft")

    @Test func aSharedMailboxIsReadAndSentFromUnderItsAddress() async throws {
        let fake = GraphMailFake()
        try fake.on("GET", "/users/sales@work.example/mailFolders?", fixture: "mailFolders-page2.json")
        fake.on("POST", "/$batch", json: #"{"responses":[{"id":"inbox","status":200,"body":{"id":"AAMkJunk="}}]}"#)
        fake.on("POST", "/users/sales@work.example/sendMail", status: 202)
        let graph = try provider(fake, account: Self.shared)
        #expect(try await graph.mailboxes().count == 2)
        #expect(fake.batched().allSatisfy { ($0["url"] as? String)?.hasPrefix("/users/sales@work.example/") == true })
        try await graph.send(Draft(from: Self.shared.address, to: [EmailAddress(address: "noor@work.example")], subject: "Quote", text: "Attached"))
        #expect(fake.json("POST", "/users/sales@work.example/sendMail")?["message"] != nil)
        #expect(fake.sent("POST", "/me/").isEmpty)
    }

    @Test func aSharedMailboxWithoutAccessSaysSo() async throws {
        let fake = GraphMailFake()
        fake.on("GET", "/users/sales@work.example/mailFolders", status: 403, json: #"{"error":{"code":"ErrorAccessDenied","message":"Access is denied."}}"#)
        await #expect(throws: MailError.serverRejected(String(localized: "You don't have access to this shared mailbox."))) {
            try await provider(fake, account: Self.shared).mailboxes()
        }
    }

    @Test func aSharedMailboxSignInAsksForSharedMail() throws {
        let registry = OAuthClientRegistry(googleClientID: nil, microsoftClientID: "client")
        let own = try #require(registry.client(for: Self.me))
        #expect(own.scopes.contains("https://graph.microsoft.com/Mail.ReadWrite"))
        #expect(own.scopes.contains("https://graph.microsoft.com/Mail.Send"))
        #expect(!own.scopes.contains("https://graph.microsoft.com/Mail.ReadWrite.Shared"))
        let shared = try #require(registry.client(for: Self.shared))
        #expect(shared.scopes.contains("https://graph.microsoft.com/Mail.ReadWrite.Shared"))
        #expect(shared.scopes.contains("https://graph.microsoft.com/Mail.Send.Shared"))
        // One service per token: every mail scope is Graph's.
        #expect(shared.tokenScopes == shared.scopes)
    }

    // MARK: Setup

    @Test func microsoftMailboxesUseGraph() throws {
        let preset = try #require(ProviderCatalog.preset(id: "microsoft"))
        #expect(preset.connection == .graph())
        let account = MailAccount(label: "Work", address: EmailAddress(address: "alex@work.example"), connection: preset.connection,
                                  auth: .oauth(provider: .microsoft, username: "alex@work.example"))
        #expect(try ProviderFactory.make(for: account, credentials: FixedToken()) is GraphMailProvider)
        // Saved and read back the same.
        let saved = try JSONDecoder().decode(MailAccount.self, from: JSONEncoder().encode(Self.shared))
        #expect(saved.sharedMailbox == "sales@work.example")
    }
}
