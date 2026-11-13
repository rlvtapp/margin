import Foundation

/// JMAP for mail (RFC 8620, RFC 8621): JSON over HTTPS, straight to the account's server.
public actor JMAPProvider: MailProvider {
    private let account: MailAccount
    private let sessionURL: URL
    private let credentials: any CredentialSource
    private let http: URLSession
    private var session: JMAPSession?
    var folders: [Mailbox] = []
    /// State strings and what was fetched with them, so refreshes ask only for changes.
    var sync = JMAPSyncState()

    public init(account: MailAccount, credentials: any CredentialSource, http: URLSession = .shared) throws {
        guard case .jmap(let url) = account.connection else { throw MailError.notSupported(String(localized: "Not a JMAP account.")) }
        guard url.scheme == "https" || url.host() == "localhost" else { throw MailError.insecureConnection }
        self.account = account
        self.sessionURL = url
        self.credentials = credentials
        self.http = http
    }

    /// Folders; after the first call only those that changed are fetched (see JMAPSync.swift).
    public func mailboxes() async throws -> [Mailbox] {
        try await syncMailboxes()
    }

    /// The newest conversations; after the first call only changed emails are fetched.
    public func threads(in mailbox: Mailbox, limit: Int) async throws -> [MailThread] {
        try await syncThreads(in: mailbox, limit: limit)
    }

    public func olderMessages(in mailbox: Mailbox, after position: String?, limit: Int) async throws -> OlderMailPage {
        try await olderPage(in: mailbox, after: position, limit: limit)
    }

    public func checkSaved(_ ids: [String], in mailbox: Mailbox, since token: String?) async throws -> SavedMailCheck {
        try await checkSavedEmails(ids, in: mailbox, since: token)
    }

    public func body(of message: MailMessage) async throws -> MessageBody {
        let session = try await connected()
        let responses = try await call([
            ["Email/get", [
                "accountId": session.accountID, "ids": [message.id],
                "properties": ["textBody", "htmlBody", "bodyValues", "attachments"],
                "fetchTextBodyValues": true, "fetchHTMLBodyValues": true, "maxBodyValueBytes": 2_000_000,
            ], "b"],
        ])
        guard let email = (responses.first?.arguments["list"] as? [[String: Any]])?.first else {
            throw MailError.protocolViolation(String(localized: "The message body was missing."))
        }
        var body = JMAPEmail.body(from: email)
        // Pictures shown inside the message come down with it, so they can be put in place.
        if let html = body.html {
            for index in body.attachments.indices {
                let file = body.attachments[index]
                guard let id = file.contentID, file.data == nil, file.mimeType.lowercased().hasPrefix("image/"),
                      (file.size ?? 0) <= 10_000_000, html.range(of: "cid:" + id, options: .caseInsensitive) != nil else { continue }
                body.attachments[index].data = try? await attachmentData(file, of: message)
            }
        }
        return body.embeddingInlineImages()
    }

    public func rawSource(of message: MailMessage) async throws -> Data {
        let session = try await connected()
        let responses = try await call([
            ["Email/get", ["accountId": session.accountID, "ids": [message.id], "properties": ["blobId"]], "s"],
        ])
        guard let blob = ((responses.first?.arguments["list"] as? [[String: Any]])?.first?["blobId"]) as? String else {
            throw MailError.protocolViolation(String(localized: "The message body was missing."))
        }
        let file = AttachmentInfo(filename: "message.eml", mimeType: "message/rfc822", blobID: blob)
        return try await attachmentData(file, of: message)
    }

    public func perform(_ action: MailAction, on threads: [MailThread]) async throws {
        let session = try await connected()
        let inbox = folders.first { $0.role == .inbox }?.id
        let archive = folders.first { $0.role == .archive }?.id
        let trash = folders.first { $0.role == .trash }?.id
        var update: [String: Any] = [:]
        for message in threads.flatMap(\.messages) {
            var patch: [String: Any] = [:]
            switch action {
            case .markRead: patch["keywords/$seen"] = true
            case .markUnread: patch["keywords/$seen"] = NSNull()
            case .star: patch["keywords/$flagged"] = true
            case .unstar: patch["keywords/$flagged"] = NSNull()
            case .done:
                // JMAP lets a message sit in several mailboxes; leaving the inbox is enough.
                if let inbox { patch["mailboxIds/\(inbox)"] = NSNull() }
                if let archive { patch["mailboxIds/\(archive)"] = true }
            case .moveToInbox:
                guard let inbox else { continue }
                patch["mailboxIds"] = [inbox: true]
            case .trash:
                guard let trash else { throw MailError.notSupported(String(localized: "This account has no Trash folder.")) }
                patch["mailboxIds"] = [trash: true]
            case .move(let target):
                patch["mailboxIds"] = [target: true]
            }
            update[message.id] = patch
        }
        let responses = try await call([["Email/set", ["accountId": session.accountID, "update": update], "s"]])
        if let failed = responses.first?.arguments["notUpdated"] as? [String: Any], !failed.isEmpty {
            throw MailError.serverRejected(String(localized: "\(failed.count) message(s) couldn't be changed."))
        }
    }

    public func send(_ draft: Draft) async throws {
        let session = try await connected()
        guard let drafts = folders.first(where: { $0.role == .drafts })?.id,
              let sent = folders.first(where: { $0.role == .sent })?.id else {
            throw MailError.notSupported(String(localized: "This account has no Drafts or Sent folder."))
        }
        let identities = try await call([["Identity/get", ["accountId": session.accountID], "i"]])
        let list = identities.first?.arguments["list"] as? [[String: Any]] ?? []
        let identity = list.first { ($0["email"] as? String)?.lowercased() == draft.from.address.lowercased() } ?? list.first
        guard let identityID = identity?["id"] as? String else { throw MailError.notSupported(String(localized: "No sending identity for this address.")) }
        let addresses = { (list: [EmailAddress]) in list.map { ["name": $0.name ?? "", "email": $0.address] } }
        var email: [String: Any] = [
            "mailboxIds": [drafts: true], "keywords": ["$draft": true, "$seen": true],
            "from": addresses([draft.from]), "to": addresses(draft.to), "cc": addresses(draft.cc), "bcc": addresses(draft.bcc),
            "subject": draft.subject,
            "bodyValues": ["body": ["value": draft.text]],
            "textBody": [["partId": "body", "type": "text/plain"]],
        ]
        if !draft.attachments.isEmpty {
            var parts: [[String: Any]] = []
            for file in draft.attachments {
                let blob = try await upload(file, session: session)
                parts.append(["blobId": blob, "type": file.mimeType, "name": file.filename, "disposition": "attachment"])
            }
            email["attachments"] = parts
        }
        if let inReplyTo = draft.inReplyTo { email["inReplyTo"] = [inReplyTo] }
        if !draft.references.isEmpty { email["references"] = draft.references }
        let responses = try await call([
            ["Email/set", ["accountId": session.accountID, "create": ["draft": email]], "c"],
            ["EmailSubmission/set", [
                "accountId": session.accountID,
                "create": ["send": ["emailId": "#draft", "identityId": identityID]],
                "onSuccessUpdateEmail": ["#send": ["mailboxIds/\(drafts)": NSNull(), "mailboxIds/\(sent)": true, "keywords/$draft": NSNull()]],
            ], "s"],
        ])
        for response in responses {
            if let failed = response.arguments["notCreated"] as? [String: Any], let first = failed.values.first as? [String: Any] {
                throw MailError.serverRejected((first["description"] as? String) ?? (first["type"] as? String) ?? "Sending failed.")
            }
        }
    }

    public func disconnect() async { session = nil }

    public func search(_ text: String, limit: Int) async throws -> [MailThread] {
        let words = text.split(separator: " ").map(String.init).filter { !$0.contains(":") }.joined(separator: " ")
        guard !words.isEmpty else { return [] }
        let session = try await connected()
        let responses = try await call([
            ["Email/query", ["accountId": session.accountID, "filter": ["text": words],
                             "sort": [["property": "receivedAt", "isAscending": false]], "limit": limit], "q"],
            ["Email/get", ["accountId": session.accountID, "#ids": ["resultOf": "q", "name": "Email/query", "path": "/ids"],
                           "properties": JMAPEmail.listProperties], "e"],
        ])
        let emails = responses.last?.arguments["list"] as? [[String: Any]] ?? []
        let messages = emails.compactMap { JMAPEmail.message(from: $0, folders: folders, fallbackMailbox: folders.first?.id ?? "") }
        let byThread = Dictionary(grouping: messages) { $0.listHeaders["x-jmap-thread"] ?? $0.id }
        return byThread.map { MailThread(id: $0.key, messages: $0.value) }.sorted { $0.date > $1.date }
    }

    public func createMailbox(named name: String) async throws {
        try await mailboxChange(["create": ["new": ["name": name]]])
    }

    public func renameMailbox(_ mailbox: Mailbox, to name: String) async throws {
        try await mailboxChange(["update": [mailbox.id: ["name": name]]])
    }

    public func deleteMailbox(_ mailbox: Mailbox) async throws {
        // Messages only in this folder go with it (RFC 8621 §2.5 onDestroyRemoveEmails).
        try await mailboxChange(["destroy": [mailbox.id], "onDestroyRemoveEmails": true])
    }

    public func saveDraft(_ draft: Draft) async throws {
        let session = try await connected()
        guard let drafts = folders.first(where: { $0.role == .drafts })?.id else { throw MailError.notSupported(String(localized: "This account has no Drafts folder.")) }
        let addresses = { (list: [EmailAddress]) in list.map { ["name": $0.name ?? "", "email": $0.address] } }
        let email: [String: Any] = [
            "mailboxIds": [drafts: true], "keywords": ["$draft": true, "$seen": true],
            "from": addresses([draft.from]), "to": addresses(draft.to), "cc": addresses(draft.cc), "subject": draft.subject,
            "bodyValues": ["body": ["value": draft.text]], "textBody": [["partId": "body", "type": "text/plain"]],
        ]
        _ = try await call([["Email/set", ["accountId": session.accountID, "create": ["draft": email]], "d"]])
    }

    private func mailboxChange(_ arguments: [String: Any]) async throws {
        let session = try await connected()
        var arguments = arguments
        arguments["accountId"] = session.accountID
        let responses = try await call([["Mailbox/set", arguments, "m"]])
        for key in ["notCreated", "notUpdated", "notDestroyed"] {
            if let failed = responses.first?.arguments[key] as? [String: Any], let first = failed.values.first as? [String: Any] {
                throw MailError.serverRejected((first["description"] as? String) ?? (first["type"] as? String) ?? "The folder change failed.")
            }
        }
        _ = try await mailboxes()
    }

    public func attachmentData(_ attachment: AttachmentInfo, of message: MailMessage) async throws -> Data {
        if let data = attachment.data { return data }
        let session = try await connected()
        guard let blob = attachment.blobID, !session.downloadURL.isEmpty else { throw MailError.notSupported(String(localized: "This attachment can't be downloaded.")) }
        let encode = { (value: String) in value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value }
        let address = session.downloadURL
            .replacingOccurrences(of: "{accountId}", with: encode(session.accountID))
            .replacingOccurrences(of: "{blobId}", with: encode(blob))
            .replacingOccurrences(of: "{type}", with: encode(attachment.mimeType))
            .replacingOccurrences(of: "{name}", with: encode(attachment.filename))
        guard let url = URL(string: address) else { throw MailError.protocolViolation(String(localized: "Bad download address.")) }
        var request = URLRequest(url: url)
        request.setValue(try await authorization(), forHTTPHeaderField: "Authorization")
        let (data, response) = try await http.data(for: request)
        try Self.check(response)
        return data
    }

    /// Uploads a file and returns its blob id (RFC 8620 §6.1).
    private func upload(_ file: OutgoingAttachment, session: JMAPSession) async throws -> String {
        let address = session.uploadURL.replacingOccurrences(of: "{accountId}", with: session.accountID)
        guard let url = URL(string: address) else { throw MailError.notSupported(String(localized: "This server doesn't accept uploads.")) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(file.mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue(try await authorization(), forHTTPHeaderField: "Authorization")
        let (data, response) = try await http.upload(for: request, from: file.data)
        try Self.check(response)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let blob = object["blobId"] as? String else {
            throw MailError.protocolViolation(String(localized: "The upload had no blob id."))
        }
        return blob
    }

    // MARK: Push

    /// Asks the server to report new mail to `url` (RFC 8620 §7.2). The server then posts a
    /// verification code there, which comes back to the phone and finishes it with `verifyPush`.
    public func createPushSubscription(deviceClientID: String, url: URL) async throws -> String {
        let responses = try await call([["PushSubscription/set", [
            "create": ["push": ["deviceClientId": deviceClientID, "url": url.absoluteString, "types": ["Email", "Mailbox"]]],
        ], "0"]])
        guard let created = responses.first?.arguments["created"] as? [String: Any],
              let push = created["push"] as? [String: Any], let id = push["id"] as? String else {
            throw MailError.notSupported(String(localized: "This server doesn't offer push."))
        }
        return id
    }

    public func verifyPush(_ id: String, code: String) async throws {
        _ = try await call([["PushSubscription/set", ["update": [id: ["verificationCode": code]]], "0"]])
    }

    public func deletePushSubscription(_ id: String) async throws {
        _ = try await call([["PushSubscription/set", ["destroy": [id]], "0"]])
    }

    // MARK: Requests

    func connected() async throws -> JMAPSession {
        if let session { return session }
        var request = URLRequest(url: sessionURL)
        request.setValue(try await authorization(), forHTTPHeaderField: "Authorization")
        let (data, response) = try await http.data(for: request)
        try Self.check(response)
        let session = try JMAPSession.parse(data)
        self.session = session
        if folders.isEmpty { _ = try await mailboxes() }
        return session
    }

    func call(_ calls: [[Any]], using capabilities: [String] = []) async throws -> [JMAPResponse] {
        let session = try await connected()
        var request = URLRequest(url: session.apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(try await authorization(), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail", "urn:ietf:params:jmap:submission"] + capabilities,
            "methodCalls": calls,
        ])
        let (data, response) = try await http.data(for: request)
        try Self.check(response)
        return try JMAPResponse.parse(data)
    }

    private func authorization() async throws -> String {
        let secret = try await credentials.secret(for: account)
        if case .password(let username) = account.auth {
            return "Basic " + Data("\(username):\(secret)".utf8).base64EncodedString()
        }
        return "Bearer \(secret)"
    }

    private static func check(_ response: URLResponse) throws {
        guard let status = (response as? HTTPURLResponse)?.statusCode else { return }
        if status == 401 || status == 403 { throw MailError.authenticationFailed(String(localized: "The server refused the token.")) }
        guard (200..<300).contains(status) else { throw MailError.serverRejected("HTTP \(status)") }
    }
}
