import Foundation

/// What a JMAP account looked like at the last refresh. With the state strings the server
/// gave, the next refresh asks `Mailbox/changes` and `Email/changes` (RFC 8620 §5.2) what
/// happened since, instead of fetching everything again.
struct JMAPSyncState: Sendable {
    var mailboxState: String?
    var emailState: String?
    /// Emails shown in some folder, by id.
    var emails: [String: JMAPCachedEmail] = [:]
    /// Each folder's newest conversations, by mailbox id.
    var lists: [String: JMAPFolderList] = [:]

    /// Forgets all emails, so the next refresh fetches them again.
    mutating func forgetEmails() {
        emailState = nil
        emails = [:]
        lists = [:]
    }

    /// Marks lists that show any of these mailboxes, this thread or this email as out of date.
    mutating func markStale(mailboxIDs: Set<String>, threadID: String?, emailID: String) {
        for (id, list) in lists where !list.isStale {
            let affected = mailboxIDs.contains(id) || list.threads.contains { thread in
                thread.id == threadID || thread.emailIDs.contains(emailID)
            }
            if affected { lists[id]?.isStale = true }
        }
    }
}

struct JMAPCachedEmail: Sendable {
    var message: MailMessage
    var mailboxIDs: Set<String>
    var threadID: String? { message.listHeaders["x-jmap-thread"] }

    init?(_ email: [String: Any]) {
        guard let message = JMAPEmail.message(from: email, folders: [], fallbackMailbox: "") else { return nil }
        self.message = message
        mailboxIDs = Set((email["mailboxIds"] as? [String: Bool])?.keys.map { $0 } ?? [])
    }

    /// The message as seen from one folder: it belongs to that folder when it's in it.
    func message(in mailbox: String) -> MailMessage {
        var message = message
        message.mailboxID = mailboxIDs.contains(mailbox) ? mailbox : (mailboxIDs.sorted().first ?? mailbox)
        return message
    }
}

/// A folder's newest conversations in the server's order, and the emails in each.
struct JMAPFolderList: Sendable {
    struct Thread: Sendable {
        var id: String
        var emailIDs: [String]
    }

    var threads: [Thread]
    var limit: Int
    /// Something in or around this folder changed; ask the server for the list again.
    var isStale = false
}

extension JMAPProvider {
    static let mailboxProperties = ["id", "name", "role", "unreadEmails", "parentId"]
    /// Most changes one refresh takes; more than that fetches everything again.
    static let maxChanges = 250

    // MARK: Folders

    /// `Mailbox/changes` since the last state, with the created and updated folders fetched in
    /// the same request. Starts over with `Mailbox/get` when there's no state or the server
    /// can't say what changed.
    func syncMailboxes() async throws -> [Mailbox] {
        let session = try await connected()
        let accountID = session.accountID
        if let since = sync.mailboxState, !folders.isEmpty {
            do {
                let responses = try await call([
                    ["Mailbox/changes", ["accountId": accountID, "sinceState": since, "maxChanges": Self.maxChanges], "c"],
                    ["Mailbox/get", ["accountId": accountID, "#ids": Self.reference("c", "Mailbox/changes", "/created"),
                                     "properties": Self.mailboxProperties], "n"],
                    ["Mailbox/get", ["accountId": accountID, "#ids": Self.reference("c", "Mailbox/changes", "/updated"),
                                     "properties": Self.mailboxProperties], "u"],
                ])
                if let changes = Self.response("c", in: responses), changes["hasMoreChanges"] as? Bool != true,
                   let newState = changes["newState"] as? String {
                    let destroyed = Set(changes["destroyed"] as? [String] ?? [])
                    folders.removeAll { destroyed.contains($0.id) }
                    for id in destroyed { sync.lists[id] = nil }
                    for item in Self.list("n", in: responses) + Self.list("u", in: responses) {
                        guard let folder = Self.mailbox(from: item) else { continue }
                        if let index = folders.firstIndex(where: { $0.id == folder.id }) { folders[index] = folder } else { folders.append(folder) }
                    }
                    sync.mailboxState = newState
                    return folders
                }
            } catch MailError.serverRejected {
                // cannotCalculateChanges and the like: fetch them all below.
            }
        }
        let responses = try await call([
            ["Mailbox/get", ["accountId": accountID, "properties": Self.mailboxProperties], "m"],
        ])
        folders = Self.list("m", in: responses).compactMap(Self.mailbox(from:))
        sync.mailboxState = Self.response("m", in: responses)?["state"] as? String
        return folders
    }

    static func mailbox(from item: [String: Any]) -> Mailbox? {
        guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
        // RFC 8621 roles use the same names as MailboxRole; others ("important") are plain folders.
        let role = (item["role"] as? String).flatMap(MailboxRole.init(rawValue:)) ?? .other
        return Mailbox(id: id, name: name, role: role, unreadCount: item["unreadEmails"] as? Int, parentID: item["parentId"] as? String)
    }

    // MARK: Conversations

    /// Catches up on `Email/changes`, then answers from memory when nothing touched the
    /// folder. Otherwise asks for the folder's thread ids again and fetches only the emails
    /// it doesn't already have.
    func syncThreads(in mailbox: Mailbox, limit: Int) async throws -> [MailThread] {
        let session = try await connected()
        try await catchUp(session)
        let known = sync.lists[mailbox.id]
        if let known, !known.isStale, known.limit >= limit {
            return threads(of: known, in: mailbox.id, limit: limit)
        }
        let list = try await reload(mailbox.id, limit: max(limit, known?.limit ?? 0), firstVisit: known == nil, session: session)
        return threads(of: list, in: mailbox.id, limit: limit)
    }

    /// Applies every email change since the last state to what's in memory. A flag change
    /// is applied in place; new, removed and moved emails mark the folders they touch.
    private func catchUp(_ session: JMAPSession) async throws {
        guard let since = sync.emailState else { return }
        let accountID = session.accountID
        let responses: [JMAPResponse]
        do {
            responses = try await call([
                ["Email/changes", ["accountId": accountID, "sinceState": since, "maxChanges": Self.maxChanges], "c"],
                ["Email/get", ["accountId": accountID, "#ids": Self.reference("c", "Email/changes", "/created"),
                               "properties": JMAPEmail.listProperties], "n"],
                ["Email/get", ["accountId": accountID, "#ids": Self.reference("c", "Email/changes", "/updated"),
                               "properties": JMAPEmail.listProperties], "u"],
            ])
        } catch MailError.serverRejected {
            // cannotCalculateChanges (the state is too old) and the like: start over.
            sync.forgetEmails()
            return
        }
        guard let changes = Self.response("c", in: responses), changes["hasMoreChanges"] as? Bool != true,
              let newState = changes["newState"] as? String else {
            sync.forgetEmails()
            return
        }
        for id in changes["destroyed"] as? [String] ?? [] {
            let old = sync.emails.removeValue(forKey: id)
            sync.markStale(mailboxIDs: old?.mailboxIDs ?? [], threadID: old?.threadID, emailID: id)
        }
        for item in Self.list("n", in: responses) + Self.list("u", in: responses) {
            guard let email = JMAPCachedEmail(item) else { continue }
            let id = email.message.id
            let old = sync.emails[id]
            sync.emails[id] = email
            // Same folders and thread: only keywords changed, and the list still holds.
            if let old, old.mailboxIDs == email.mailboxIDs, old.threadID == email.threadID { continue }
            sync.markStale(mailboxIDs: email.mailboxIDs.union(old?.mailboxIDs ?? []), threadID: email.threadID, emailID: id)
        }
        sync.emailState = newState
    }

    /// Asks for the folder's newest thread ids and their email ids. A first visit fetches
    /// the emails in the same request; later ones fetch only emails not already in memory.
    private func reload(_ mailboxID: String, limit: Int, firstVisit: Bool, session: JMAPSession) async throws -> JMAPFolderList {
        let accountID = session.accountID
        var calls: [[Any]] = [
            ["Email/query", [
                "accountId": accountID, "filter": ["inMailbox": mailboxID],
                "sort": [["property": "receivedAt", "isAscending": false]],
                "collapseThreads": true, "limit": limit,
            ], "q"],
            ["Email/get", ["accountId": accountID, "#ids": Self.reference("q", "Email/query", "/ids"), "properties": ["threadId"]], "t"],
            ["Thread/get", ["accountId": accountID, "#ids": Self.reference("t", "Email/get", "/list/*/threadId")], "th"],
        ]
        if firstVisit {
            calls.append(["Email/get", [
                "accountId": accountID,
                "#ids": Self.reference("th", "Thread/get", "/list/*/emailIds"),
                "properties": JMAPEmail.listProperties,
            ], "e"])
        }
        let responses = try await call(calls)
        // Changes are counted from the state the ids were read at.
        if sync.emailState == nil { sync.emailState = Self.response("t", in: responses)?["state"] as? String }
        for item in Self.list("e", in: responses) {
            if let email = JMAPCachedEmail(item) { sync.emails[email.message.id] = email }
        }

        var order: [String] = []
        for item in Self.list("t", in: responses) {
            if let thread = item["threadId"] as? String, !order.contains(thread) { order.append(thread) }
        }
        var emailIDs: [String: [String]] = [:]
        for item in Self.list("th", in: responses) {
            if let id = item["id"] as? String { emailIDs[id] = item["emailIds"] as? [String] ?? [] }
        }
        let list = JMAPFolderList(threads: order.map { JMAPFolderList.Thread(id: $0, emailIDs: emailIDs[$0] ?? []) }, limit: limit)

        let missing = list.threads.flatMap(\.emailIDs).filter { sync.emails[$0] == nil }
        if !missing.isEmpty {
            let fetched = try await call([["Email/get", ["accountId": accountID, "ids": missing, "properties": JMAPEmail.listProperties], "e"]])
            for item in Self.list("e", in: fetched) {
                if let email = JMAPCachedEmail(item) { sync.emails[email.message.id] = email }
            }
        }
        sync.lists[mailboxID] = list
        // Keep only emails some folder shows.
        let shown = Set(sync.lists.values.flatMap { $0.threads.flatMap(\.emailIDs) })
        sync.emails = sync.emails.filter { shown.contains($0.key) }
        return list
    }

    private func threads(of list: JMAPFolderList, in mailboxID: String, limit: Int) -> [MailThread] {
        list.threads.prefix(max(0, limit)).compactMap { thread -> MailThread? in
            let messages = thread.emailIDs.compactMap { sync.emails[$0]?.message(in: mailboxID) }
            return messages.isEmpty ? nil : MailThread(id: thread.id, messages: messages)
        }.sorted { $0.date > $1.date }
    }

    // MARK: Responses

    static func reference(_ callID: String, _ name: String, _ path: String) -> [String: String] {
        ["resultOf": callID, "name": name, "path": path]
    }

    static func response(_ callID: String, in responses: [JMAPResponse]) -> [String: Any]? {
        responses.first { $0.callID == callID }?.arguments
    }

    static func list(_ callID: String, in responses: [JMAPResponse]) -> [[String: Any]] {
        response(callID, in: responses)?["list"] as? [[String: Any]] ?? []
    }
}
