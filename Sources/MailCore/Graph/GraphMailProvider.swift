import Foundation

/// Mail through Microsoft Graph, for Microsoft 365 and Outlook.com: many organizations turn
/// IMAP off, Graph stays on. JSON over HTTPS, straight to Microsoft, with the account's sign-in.
///
/// Folders come from `mailFolders` (and their `childFolders`); a folder's mail from its newest
/// messages, then `messages/delta`, so a refresh asks only what changed. Bodies are read as the
/// message itself (`$value`), so invitations, inline pictures and attachments come out exactly as
/// over IMAP. Ids are immutable (`Prefer: IdType="ImmutableId"`), so they survive moves.
///
/// A shared mailbox is the same with `/users/{address}` in place of `/me`.
public actor GraphMailProvider: MailProvider {
    /// The most one upload may carry; bigger files go up in parts (an upload session).
    static let smallAttachment = 3 * 1024 * 1024
    /// Each part of an upload session: a multiple of 320 KiB, as Graph asks.
    static let uploadChunk = 320 * 1024 * 10

    private let account: MailAccount
    private let credentials: any CredentialSource
    private let transport: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    /// "me", or "users/{address}" for a shared mailbox.
    let root: String
    var folders: [Mailbox] = []
    /// Each folder's newest mail and where its changes continue from, by folder id.
    var lists: [String: GraphFolderList] = [:]

    public init(account: MailAccount, credentials: any CredentialSource,
                send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = BearerHTTP.urlSession) throws {
        guard case .graph(let shared) = account.connection else {
            throw MailError.notSupported(String(localized: "Not a Microsoft account."))
        }
        self.account = account
        self.credentials = credentials
        self.transport = send
        if let shared {
            guard EmailAddress.isValid(shared) else { throw MailError.invalidAddress(shared) }
            root = "users/" + (shared.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? shared)
        } else {
            root = "me"
        }
    }

    // MARK: Folders

    public func mailboxes() async throws -> [Mailbox] {
        let fields = "id,displayName,parentFolderId,unreadItemCount,childFolderCount"
        var all: [GraphFolder] = try await pages(url("\(root)/mailFolders", ["$top": "250", "$select": fields]))
        var waiting = all.filter { ($0.childFolderCount ?? 0) > 0 }.map(\.id)
        while let parent = waiting.popLast(), all.count < 2000 {
            let children: [GraphFolder] = try await pages(url("\(root)/mailFolders/\(Self.path(parent))/childFolders",
                                                             ["$top": "250", "$select": fields]))
            all += children
            waiting += children.filter { ($0.childFolderCount ?? 0) > 0 }.map(\.id)
        }
        let roles = try await wellKnownFolders()
        let ids = Set(all.map(\.id))
        folders = all.map { folder in
            Mailbox(id: folder.id, name: folder.displayName ?? "", role: roles[folder.id] ?? .other,
                    unreadCount: folder.unreadItemCount,
                    parentID: folder.parentFolderId.flatMap { ids.contains($0) ? $0 : nil })
        }
        return folders
    }

    /// The ids of the folders Graph knows by name (Inbox, Sent Items…), in one batch.
    private func wellKnownFolders() async throws -> [String: MailboxRole] {
        let names: [(String, MailboxRole)] = [
            ("inbox", .inbox), ("sentitems", .sent), ("drafts", .drafts), ("archive", .archive),
            ("deleteditems", .trash), ("junkemail", .junk),
        ]
        let answers = try await batch(names.map {
            GraphBatchItem(id: $0.0, method: "GET", url: "/\(root)/mailFolders/\($0.0)?$select=id")
        })
        struct Found: Decodable { var id: String }
        var roles: [String: MailboxRole] = [:]
        for (name, role) in names {
            // A mailbox without an archive answers 404 for it: that folder just isn't there.
            guard let answer = answers[name], (200..<300).contains(answer.status),
                  let found = try? JSONDecoder().decode(Found.self, from: answer.body) else { continue }
            roles[found.id] = role
        }
        return roles
    }

    private func folderID(_ role: MailboxRole, wellKnown: String) -> String {
        folders.first { $0.role == role }?.id ?? wellKnown
    }

    public func createMailbox(named name: String) async throws {
        _ = try await data(request(url("\(root)/mailFolders"), method: "POST", json: ["displayName": name]))
        _ = try await mailboxes()
    }

    public func renameMailbox(_ mailbox: Mailbox, to name: String) async throws {
        _ = try await data(request(url("\(root)/mailFolders/\(Self.path(mailbox.id))"), method: "PATCH", json: ["displayName": name]))
        _ = try await mailboxes()
    }

    public func deleteMailbox(_ mailbox: Mailbox) async throws {
        _ = try await data(request(url("\(root)/mailFolders/\(Self.path(mailbox.id))"), method: "DELETE"))
        lists[mailbox.id] = nil
        _ = try await mailboxes()
    }

    // MARK: Conversations

    /// The folder's newest conversations. The first time it lists the newest messages and starts
    /// a delta query from the oldest of them; after that only the changes are fetched.
    public func threads(in mailbox: Mailbox, limit: Int) async throws -> [MailThread] {
        var list: GraphFolderList
        if let known = lists[mailbox.id], known.deltaLink != nil, known.limit >= limit {
            list = known
            do {
                try await catchUp(&list, in: mailbox, from: known.deltaLink!)
            } catch GraphSyncError.expired {
                list = try await freshList(of: mailbox, limit: limit)
            }
        } else {
            list = try await freshList(of: mailbox, limit: limit)
        }
        Self.trim(&list)
        lists[mailbox.id] = list
        return Self.threads(from: Array(list.messages.values), limit: limit)
    }

    private func freshList(of mailbox: Mailbox, limit: Int) async throws -> GraphFolderList {
        let folder = "\(root)/mailFolders/\(Self.path(mailbox.id))"
        let page: GraphPage<GraphMessage> = try decode(try await data(request(url("\(folder)/messages", [
            "$top": String(limit), "$orderby": "receivedDateTime desc", "$select": GraphMessage.listFields,
        ]))))
        var list = GraphFolderList(limit: limit)
        for item in page.value { list.messages[item.id] = item.message(in: mailbox.id) }
        var query = ["$select": GraphMessage.deltaFields]
        // Changes to the mail shown, and anything newer; older mail is paged in separately.
        if page.value.count >= limit, let oldest = page.value.compactMap(\.receivedDateTime).min() {
            query["$filter"] = "receivedDateTime ge \(oldest)"
        }
        try await catchUp(&list, in: mailbox, from: url("\(folder)/messages/delta", query).absoluteString)
        return list
    }

    /// Follows a delta query to its end: removed messages go, changed ones take their new flags,
    /// new ones are read whole.
    private func catchUp(_ list: inout GraphFolderList, in mailbox: Mailbox, from start: String) async throws {
        guard let first = URL(string: start), Self.isGraph(first) else { throw GraphSyncError.expired }
        var next: URL? = first
        var added: [String] = []
        var pageCount = 0
        while let link = next, pageCount < 100 {
            pageCount += 1
            let page: GraphDeltaPage = try decode(try await data(request(link, prefer: ["odata.maxpagesize=200"])))
            for item in page.value {
                if item.removed != nil {
                    list.messages[item.id] = nil
                    added.removeAll { $0 == item.id }
                } else if var known = list.messages[item.id] {
                    item.update(&known)
                    list.messages[item.id] = known
                } else if !added.contains(item.id) {
                    added.append(item.id)
                }
            }
            if let delta = page.deltaLink { list.deltaLink = delta; break }
            next = page.nextLink.flatMap(URL.init(string:)).flatMap { Self.isGraph($0) ? $0 : nil }
        }
        for message in try await messages(withIDs: added, in: mailbox.id) {
            list.messages[message.id] = message
        }
    }

    /// Messages read whole by id, in batches; ones that are gone are left out.
    private func messages(withIDs ids: [String], in mailboxID: String) async throws -> [MailMessage] {
        guard !ids.isEmpty else { return [] }
        let answers = try await batch(ids.map {
            GraphBatchItem(id: $0, method: "GET", url: "/\(root)/messages/\(Self.path($0))?$select=\(GraphMessage.listFields)")
        })
        return ids.compactMap { id in
            guard let answer = answers[id], (200..<300).contains(answer.status),
                  let item = try? JSONDecoder().decode(GraphMessage.self, from: answer.body) else { return nil }
            return item.message(in: mailboxID)
        }
    }

    /// Keeps the newest mail of a folder, twice what's shown, so the list doesn't grow for ever.
    static func trim(_ list: inout GraphFolderList) {
        let keep = max(list.limit * 2, 100)
        guard list.messages.count > keep else { return }
        let newest = list.messages.values.sorted { $0.date > $1.date }.prefix(keep)
        list.messages = Dictionary(uniqueKeysWithValues: newest.map { ($0.id, $0) })
    }

    /// The newest `limit` messages, as conversations, newest first.
    static func threads(from messages: [MailMessage], limit: Int) -> [MailThread] {
        let newest = messages.sorted { $0.date > $1.date }.prefix(limit)
        let grouped = Dictionary(grouping: newest) { $0.threadID ?? $0.id }
        return grouped.map { MailThread(id: $0.key, messages: $0.value) }.sorted { $0.date > $1.date }
    }

    public func olderMessages(in mailbox: Mailbox, after position: String?, limit: Int) async throws -> OlderMailPage {
        let link: URL
        if let position, let next = URL(string: position), Self.isGraph(next) {
            link = next
        } else {
            link = url("\(root)/mailFolders/\(Self.path(mailbox.id))/messages", [
                "$top": String(limit), "$orderby": "receivedDateTime desc", "$select": GraphMessage.listFields,
            ])
        }
        let page: GraphPage<GraphMessage> = try decode(try await data(request(link)))
        return OlderMailPage(messages: page.value.map { $0.message(in: mailbox.id) }, next: page.nextLink)
    }

    /// Mail matching a typed search, operators included (see `SearchQuery`): words, `from:`,
    /// `to:`, `subject:`, `has:attachment` and dates go to Graph as KQL in `$search`; `in:` looks
    /// in that folder. Graph can't put `$filter` beside `$search`, so unread and starred filter
    /// the results here, or go as `$filter` when nothing else was typed.
    public func search(_ text: String, limit: Int) async throws -> [MailThread] {
        let query = SearchQuery(text)
        guard !query.isEmpty else { return [] }
        if folders.isEmpty, query.mailbox != nil { _ = try await mailboxes() }
        let folder = query.mailbox(in: folders)
        let path = folder.map { "\(root)/mailFolders/\(Self.path($0.id))/messages" } ?? "\(root)/messages"
        guard let parameters = Self.searchParameters(query, limit: limit) else { return [] }
        let page: GraphPage<GraphMessage> = try decode(try await data(request(url(path, parameters))))
        let messages = page.value.map { $0.message(in: folder?.id ?? "") }.filter { message in
            (query.isUnread.map { message.isUnread == $0 } ?? true) && (query.isStarred.map { message.isStarred == $0 } ?? true)
        }
        return Self.threads(from: messages, limit: limit)
    }

    /// The query string for a search; nil when nothing in it can be asked of Graph.
    static func searchParameters(_ query: SearchQuery, limit: Int, timeZone: TimeZone = .current) -> [String: String]? {
        // Quotes would end Graph's quoted $search; a phrase becomes its words.
        let clean = { (value: String) in value.replacingOccurrences(of: "\"", with: " ").split(whereSeparator: \.isWhitespace).map(String.init) }
        var terms = query.words.flatMap(clean)
        for (field, values) in [("from", query.from), ("to", query.to), ("subject", query.subject)] {
            terms += values.flatMap(clean).map { "\(field):\($0)" }
        }
        if query.hasAttachment { terms.append("hasAttachments:true") }
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = timeZone
        day.dateFormat = "yyyy-MM-dd"
        if let after = query.after { terms.append("received>=\(day.string(from: after))") }
        if let before = query.before { terms.append("received<\(day.string(from: before))") }
        if !terms.isEmpty {
            return ["$search": "\"\(terms.joined(separator: " "))\"", "$top": String(limit), "$select": GraphMessage.listFields]
        }
        var filters: [String] = []
        if let unread = query.isUnread { filters.append("isRead eq \(!unread)") }
        if let starred = query.isStarred { filters.append("flag/flagStatus \(starred ? "eq" : "ne") 'flagged'") }
        guard !filters.isEmpty || query.mailbox != nil else { return nil }
        var parameters = ["$top": String(limit), "$select": GraphMessage.listFields]
        if filters.isEmpty { parameters["$orderby"] = "receivedDateTime desc" } else { parameters["$filter"] = filters.joined(separator: " and ") }
        return parameters
    }

    // MARK: Reading

    /// The message as it was sent, parsed like IMAP's: text, pictures, files and invitations.
    public func body(of message: MailMessage) async throws -> MessageBody {
        MIMEMessage.parse([UInt8](try await rawSource(of: message))).body
    }

    public func rawSource(of message: MailMessage) async throws -> Data {
        try await data(request(url("\(root)/messages/\(Self.path(message.id))/$value")))
    }

    /// The readable text of several messages, without their files, in batches. One with files
    /// (or pictures shown inside it) is marked partial, so opening it reads it whole.
    public func readableBodies(of messages: [MailMessage]) async throws -> [String: MessageBody] {
        guard !messages.isEmpty else { return [:] }
        let answers = try await batch(messages.map {
            GraphBatchItem(id: $0.id, method: "GET", url: "/\(root)/messages/\(Self.path($0.id))?$select=body,hasAttachments")
        })
        var found: [String: MessageBody] = [:]
        for message in messages {
            guard let answer = answers[message.id], (200..<300).contains(answer.status),
                  let item = try? JSONDecoder().decode(GraphMessage.self, from: answer.body) else { continue }
            found[message.id] = Self.readableBody(item)
        }
        return found
    }

    static func readableBody(_ item: GraphMessage) -> MessageBody {
        let content = item.body?.content ?? ""
        let isHTML = item.body?.contentType?.lowercased() == "html"
        var body = MessageBody(text: isHTML ? HTMLText.plain(content) : content, html: isHTML ? content : nil)
        if item.hasAttachments == true || content.range(of: "cid:", options: .caseInsensitive) != nil { body.isPartial = true }
        return body
    }

    // MARK: Changes

    public func perform(_ action: MailAction, on threads: [MailThread]) async throws {
        let trash = folders.first { $0.role == .trash }?.id
        var items: [GraphBatchItem] = []
        for message in threads.flatMap(\.messages) {
            let path = "/\(root)/messages/\(Self.path(message.id))"
            let move = { (target: String) in GraphBatchItem(id: message.id, method: "POST", url: path + "/move", body: ["destinationId": target]) }
            let patch = { (body: [String: any Sendable]) in GraphBatchItem(id: message.id, method: "PATCH", url: path, body: body) }
            switch action {
            case .markRead: items.append(patch(["isRead": true]))
            case .markUnread: items.append(patch(["isRead": false]))
            case .star: items.append(patch(["flag": ["flagStatus": "flagged"]]))
            case .unstar: items.append(patch(["flag": ["flagStatus": "notFlagged"]]))
            case .done: items.append(move(folderID(.archive, wellKnown: "archive")))
            case .moveToInbox, .notJunk: items.append(move(folderID(.inbox, wellKnown: "inbox")))
            case .junk: items.append(move(folderID(.junk, wellKnown: "junkemail")))
            case .move(let target): items.append(move(target))
            case .trash:
                // Already in Deleted Items: deleting it again removes it for good, as Outlook does.
                if let trash, message.mailboxID == trash {
                    items.append(GraphBatchItem(id: message.id, method: "DELETE", url: path))
                } else {
                    items.append(move(folderID(.trash, wellKnown: "deleteditems")))
                }
            }
        }
        let answers = try await batch(items)
        let failed = answers.values.filter { !(200..<300).contains($0.status) }.count
        applyLocally(action, to: Set(threads.flatMap(\.messages).map(\.id)))
        if failed > 0 { throw MailError.serverRejected(String(localized: "\(failed) message(s) couldn't be changed.")) }
    }

    /// What was just done, in the lists kept, so they agree before the next delta says so.
    private func applyLocally(_ action: MailAction, to ids: Set<String>) {
        for (folder, var list) in lists {
            for id in ids where list.messages[id] != nil {
                switch action {
                case .markRead: list.messages[id]?.flags.insert(.seen)
                case .markUnread: list.messages[id]?.flags.remove(.seen)
                case .star: list.messages[id]?.flags.insert(.flagged)
                case .unstar: list.messages[id]?.flags.remove(.flagged)
                default: list.messages[id] = nil
                }
            }
            lists[folder] = list
        }
    }

    /// Outlook's categories on a message.
    public static func categories(of message: MailMessage) -> [String] {
        message.labels ?? []
    }

    /// Gives every message of the threads exactly these categories.
    public func setCategories(_ categories: [String], on threads: [MailThread]) async throws {
        try await writeCategories(threads.flatMap(\.messages).map { ($0.id, categories) })
    }

    /// Adds a category to every message of the threads, or takes it off (Outlook's categories
    /// are this mailbox's labels; see `MailMessage.labels`).
    public func changeLabel(_ label: String, adding: Bool, on threads: [MailThread]) async throws {
        let changes = threads.flatMap(\.messages).map { message -> (String, [String]) in
            // What's kept here may be newer than the thread that was shown.
            let known = lists.values.lazy.compactMap { $0.messages[message.id]?.labels }.first ?? message.labels ?? []
            var categories = known.filter { $0.caseInsensitiveCompare(label) != .orderedSame }
            if adding { categories.append(label) }
            return (message.id, categories)
        }
        try await writeCategories(changes)
    }

    private func writeCategories(_ changes: [(id: String, categories: [String])]) async throws {
        let answers = try await batch(changes.map {
            GraphBatchItem(id: $0.id, method: "PATCH", url: "/\(root)/messages/\(Self.path($0.id))", body: ["categories": $0.categories])
        })
        let failed = answers.values.filter { !(200..<300).contains($0.status) }.count
        for (folder, var list) in lists {
            for change in changes where list.messages[change.id] != nil && (200..<300).contains(answers[change.id]?.status ?? 0) {
                list.messages[change.id]?.labels = change.categories
            }
            lists[folder] = list
        }
        if failed > 0 { throw MailError.serverRejected(String(localized: "\(failed) message(s) couldn't be changed.")) }
    }

    // MARK: Sending

    /// Replies go through `createReply`, so Outlook keeps them in their conversation; new mail
    /// through `sendMail`, or a draft that's sent when its files are too big for one request.
    /// Invitation answers and reactions go as the MIME message itself, since only it has room
    /// for their parts.
    public func send(_ draft: Draft) async throws {
        if draft.calendar != nil || draft.reaction != nil {
            let mime = Data(MessageBuilder.build(draft))
            var sending = try await request(url("\(root)/sendMail"), method: "POST")
            sending.setValue("text/plain", forHTTPHeaderField: "Content-Type")
            sending.httpBody = Data(mime.base64EncodedString().utf8)
            _ = try await data(sending)
            return
        }
        if let replyTo = draft.inReplyTo, let original = try await messageID(forInternetID: replyTo) {
            let created: GraphMessage = try decode(try await data(request(
                url("\(root)/messages/\(Self.path(original))/createReply"), method: "POST", json: [String: Any]())))
            try await fill(created.id, with: draft)
            _ = try await data(request(url("\(root)/messages/\(Self.path(created.id))/send"), method: "POST"))
            return
        }
        let size = draft.attachments.reduce(0) { $0 + $1.data.count }
        if size <= Self.smallAttachment {
            var message = messageJSON(draft)
            if !draft.attachments.isEmpty { message["attachments"] = draft.attachments.map(Self.attachmentJSON) }
            _ = try await data(request(url("\(root)/sendMail"), method: "POST", json: ["message": message, "saveToSentItems": true]))
            return
        }
        let id = try await createDraft(draft)
        _ = try await data(request(url("\(root)/messages/\(Self.path(id))/send"), method: "POST"))
    }

    /// Files the message in Drafts.
    public func saveDraft(_ draft: Draft) async throws {
        _ = try await createDraft(draft)
    }

    /// A new message in Drafts, with its files; returns its id.
    private func createDraft(_ draft: Draft) async throws -> String {
        let created: GraphMessage = try decode(try await data(request(url("\(root)/messages"), method: "POST", json: messageJSON(draft))))
        try await attach(draft.attachments, to: created.id)
        return created.id
    }

    /// Puts what was written into a draft Graph made (a reply), files and all.
    private func fill(_ id: String, with draft: Draft) async throws {
        _ = try await data(request(url("\(root)/messages/\(Self.path(id))"), method: "PATCH", json: messageJSON(draft)))
        try await attach(draft.attachments, to: id)
    }

    private func attach(_ files: [OutgoingAttachment], to id: String) async throws {
        for file in files {
            if file.data.count <= Self.smallAttachment {
                _ = try await data(request(url("\(root)/messages/\(Self.path(id))/attachments"), method: "POST", json: Self.attachmentJSON(file)))
            } else {
                try await upload(file, to: id)
            }
        }
    }

    /// A big file goes up in parts through an upload session. The upload address carries its
    /// own permission, so the parts are sent without the account's token.
    private func upload(_ file: OutgoingAttachment, to id: String) async throws {
        var item: [String: Any] = ["attachmentType": "file", "name": file.filename, "size": file.data.count, "contentType": file.mimeType]
        if let contentID = file.contentID { item["isInline"] = true; item["contentId"] = contentID }
        struct Session: Decodable { var uploadUrl: String }
        let session: Session = try decode(try await data(request(
            url("\(root)/messages/\(Self.path(id))/attachments/createUploadSession"), method: "POST", json: ["AttachmentItem": item])))
        guard let target = URL(string: session.uploadUrl), target.scheme == "https" else {
            throw MailError.protocolViolation(String(localized: "Bad upload address."))
        }
        var start = 0
        while start < file.data.count {
            let end = min(start + Self.uploadChunk, file.data.count)
            var part = URLRequest(url: target)
            part.httpMethod = "PUT"
            part.setValue("bytes \(start)-\(end - 1)/\(file.data.count)", forHTTPHeaderField: "Content-Range")
            part.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            part.httpBody = file.data.subdata(in: start..<end)
            _ = try await data(part)
            start = end
        }
    }

    func messageJSON(_ draft: Draft) -> [String: Any] {
        var message: [String: Any] = [
            "subject": draft.subject,
            "body": ["contentType": draft.html == nil ? "Text" : "HTML", "content": draft.html ?? draft.text],
            "toRecipients": draft.to.map(GraphMailRecipient.json),
            "ccRecipients": draft.cc.map(GraphMailRecipient.json),
            "bccRecipients": draft.bcc.map(GraphMailRecipient.json),
        ]
        // Always say who it's from. Without it Microsoft uses the mailbox's primary address,
        // which on Outlook.com can be another alias than the one this mailbox was added with
        // (added as you@outlook.com, sent as you@hotmail.com).
        message["from"] = GraphMailRecipient.json(draft.from)
        return message
    }

    static func attachmentJSON(_ file: OutgoingAttachment) -> [String: Any] {
        var json: [String: Any] = [
            "@odata.type": "#microsoft.graph.fileAttachment", "name": file.filename,
            "contentType": file.mimeType, "contentBytes": file.data.base64EncodedString(),
        ]
        if let contentID = file.contentID { json["isInline"] = true; json["contentId"] = contentID }
        return json
    }

    /// The Graph id of the message with this Message-ID, when it's in the mailbox.
    private func messageID(forInternetID internetID: String) async throws -> String? {
        var bare = internetID.trimmingCharacters(in: .whitespaces)
        if !bare.hasPrefix("<") { bare = "<\(bare)>" }
        let quoted = bare.replacingOccurrences(of: "'", with: "''")
        let page: GraphPage<GraphMessage> = try decode(try await data(request(url("\(root)/messages", [
            "$filter": "internetMessageId eq '\(quoted)'", "$select": "id", "$top": "1",
        ]))))
        return page.value.first?.id
    }

    public func disconnect() async {}

    // MARK: Requests

    func url(_ path: String, _ query: [String: String] = [:]) -> URL {
        // Ids in the path are already escaped (`path(_:)`), so the address is put together as text.
        var components = URLComponents(string: MicrosoftGraphClient.base.absoluteString + "/" + path)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            // "+" means a space to Graph; keep it as itself.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return components.url!
    }

    /// A folder or message id as one piece of a path.
    static func path(_ id: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
    }

    /// Only Graph itself is followed: a next or delta link pointing elsewhere is ignored.
    static func isGraph(_ url: URL) -> Bool {
        url.scheme == "https" && url.host() == MicrosoftGraphClient.base.host()
    }

    func request(_ url: URL, method: String = "GET", json: Any? = nil, prefer: [String] = []) async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(try await credentials.secret(for: account))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue((["IdType=\"ImmutableId\""] + prefer).joined(separator: ", "), forHTTPHeaderField: "Prefer")
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// The body of a successful answer. Throttling is waited out once, as Graph asks.
    func data(_ request: URLRequest) async throws -> Data {
        var (data, response) = try await transport(request)
        if [429, 503, 504].contains(response.statusCode) {
            let wait = min(Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2, 10)
            try await Task.sleep(for: .seconds(wait))
            (data, response) = try await transport(request)
        }
        try check(data, response)
        return data
    }

    private func check(_ data: Data, _ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200..<300: return
        case 401: throw MailError.authenticationFailed(String(localized: "Sign in to this account again."))
        case 403 where account.sharedMailbox != nil:
            throw MailError.serverRejected(String(localized: "You don't have access to this shared mailbox."))
        case 404 where account.sharedMailbox != nil && folders.isEmpty:
            throw MailError.serverRejected(String(localized: "There's no mailbox at this address, or it isn't shared with you."))
        case 403: throw MailError.authenticationFailed(String(localized: "This account didn't allow Margin access."))
        // The delta link is too old: start the folder over.
        case 410: throw GraphSyncError.expired
        default:
            let message = (try? JSONDecoder().decode(BearerHTTP.ErrorBody.self, from: data))?.error.message
            if response.statusCode == 400, message?.lowercased().contains("sync") == true { throw GraphSyncError.expired }
            throw MailError.serverRejected(message ?? "HTTP \(response.statusCode)")
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        try BearerHTTP.decode(T.self, from: data)
    }

    /// Every page of a list, following `@odata.nextLink`.
    private func pages<T: Decodable>(_ first: URL) async throws -> [T] {
        var all: [T] = []
        var next: URL? = first
        var count = 0
        while let link = next, count < 50 {
            let page: GraphPage<T> = try decode(try await data(request(link)))
            all += page.value
            next = page.nextLink.flatMap(URL.init(string:)).flatMap { Self.isGraph($0) ? $0 : nil }
            count += 1
        }
        return all
    }

    /// Sends requests 20 at a time (Graph's JSON batching) and returns each answer by its id.
    func batch(_ items: [GraphBatchItem]) async throws -> [String: (status: Int, body: Data)] {
        var answers: [String: (status: Int, body: Data)] = [:]
        var start = 0
        while start < items.count {
            let chunk = items[start..<min(start + 20, items.count)]
            start += 20
            let requests: [[String: Any]] = chunk.map { item in
                var entry: [String: Any] = ["id": item.id, "method": item.method, "url": item.url]
                var headers = ["Prefer": "IdType=\"ImmutableId\""]
                if let body = item.body {
                    entry["body"] = body
                    headers["Content-Type"] = "application/json"
                }
                entry["headers"] = headers
                return entry
            }
            let data = try await data(request(url("$batch"), method: "POST", json: ["requests": requests]))
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let responses = object["responses"] as? [[String: Any]] else {
                throw MailError.protocolViolation(String(localized: "The answer couldn't be read."))
            }
            for response in responses {
                guard let id = response["id"] as? String else { continue }
                let status = response["status"] as? Int ?? 500
                let body = response["body"].flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
                answers[id] = (status, body)
            }
        }
        return answers
    }
}

enum GraphSyncError: Error {
    /// The delta link can't be used any more; the folder is listed afresh.
    case expired
}
