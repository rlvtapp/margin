import Foundation
import MailCore

/// What needs the person (Home's "Needs you": the conversations with a margin note) and who's
/// who for addressing mail (what the To field suggests), for AI apps. Both only read.
enum PeopleTools {
    static func tools() -> [MCPTool] {
        [
            MCPTool(name: "list_needs_you",
                    description: "Home's \"Needs you\" list: inbox conversations that need the person now, newest first, each with why (kind reply, meeting, bill or code, and the short note Home shows, like \"reply owed\", \"owed 3d\" or \"at 14:00\"), plus Home's one-line summary. Ids work with read_conversation. Sign-in codes are never included, only that there is one.",
                    inputSchema: #"{"type":"object","properties":{"limit":{"type":"integer","minimum":1,"maximum":200,"description":"Defaults to 50."}},"additionalProperties":false}"#),
            MCPTool(name: "find_people",
                    description: "Finds people by name or the start of an address, for addressing mail: the same suggestions as Margin's To field (people in the person's mail, their address books, older saved mail including Sent, and work directories). Each has a name, address and where it was found.",
                    inputSchema: #"{"type":"object","properties":{"query":{"type":"string","minLength":2,"description":"At least 2 characters of a name or address."},"limit":{"type":"integer","minimum":1,"maximum":20,"description":"Defaults to 10."}},"required":["query"],"additionalProperties":false}"#),
        ]
    }
}

/// Where someone was found for `find_people`.
enum PersonSource: String {
    /// In conversations Margin has loaded.
    case mail
    /// In an address book: the Contacts app, a connected account or CardDAV.
    case contacts
    /// On older mail saved on the device, in any folder (Sent included).
    case savedMail = "saved_mail"
    /// A work directory.
    case directory
}

extension MailModel {
    /// Answers the people tools; nil for any other tool.
    func runPeopleTool(_ name: String, _ arguments: [String: MCPValue]) async throws -> String? {
        switch name {
        case "list_needs_you":
            let limit = min(max(arguments["limit"]?.int ?? 50, 1), 200)
            let now = Date()
            let items = needsYou(now: now, only: isVisible)
            return json([
                "summary": homeSummary(now: now, only: isVisible),
                "total": items.count,
                "conversations": items.prefix(limit).map { needsYouJSON($0.thread, $0.note) },
            ] as [String: Any])
        case "find_people":
            let query = (arguments["query"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard query.count >= 2 else { throw MCPToolError("“query” needs at least 2 characters of a name or address.") }
            let limit = min(max(arguments["limit"]?.int ?? 10, 1), 20)
            return json(await findPeople(query, limit: limit).map { found -> [String: Any] in
                var item: [String: Any] = ["address": found.person.address, "source": found.source.rawValue]
                if let name = found.person.name, !name.isEmpty { item["name"] = name }
                return item
            })
        default:
            return nil
        }
    }

    private func needsYouJSON(_ thread: MailThread, _ note: MarginNote) -> [String: Any] {
        let kind = switch note.kind {
        case .reply: "reply"
        case .meeting: "meeting"
        case .bill: "bill"
        case .code: "code"
        }
        let mine = Set(accounts.flatMap(\.sendAddresses).map { $0.address.lowercased() })
        var seen = Set<String>()
        let people = thread.messages.flatMap { [$0.from] + $0.to + $0.cc }
            .filter { !mine.contains($0.address.lowercased()) && seen.insert($0.address.lowercased()).inserted }
            .prefix(10)
            .map(\.headerValue)
        return [
            "id": thread.id,
            "mailbox": account(thread.accountID)?.label ?? "",
            "subject": thread.subject,
            "people": Array(people),
            "date": ISO8601DateFormatter().string(from: thread.date),
            "unread": thread.isUnread,
            "reason": ["kind": kind, "text": note.text],
        ]
    }

    /// The To field's suggestions for `query`, then saved mail and work directories, without
    /// repeats and without mailboxes hidden from AI apps.
    func findPeople(_ query: String, limit: Int) async -> [(person: EmailAddress, source: PersonSource)] {
        let hidden = !connectionSettings.hiddenAccounts.isEmpty
        let book = hidden
            ? AddressBook(threads: (inboxThreads(nil) + folder + newsletterHistory).filter(isVisible),
                          me: Set(accounts.flatMap(\.sendAddresses).map { $0.address.lowercased() }),
                          contacts: contacts.flatMap(\.addresses))
            : addressBook
        let inContacts = Set(contacts.flatMap(\.emails).map { $0.lowercased() })
        var found: [(person: EmailAddress, source: PersonSource)] = book.suggestions(for: query, limit: limit).map { person in
            (person, inContacts.contains(person.address.lowercased()) ? .contacts : .mail)
        }
        if found.count < limit {
            var seen = Set(found.map { $0.person.address.lowercased() })
            for more in await searchDirectories(query, in: visibleAccounts) where seen.insert(more.person.address.lowercased()).inserted {
                found.append(more)
            }
        }
        return Array(found.prefix(limit))
    }
}
