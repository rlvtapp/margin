import Foundation
import MailCore

/// Sorting from AI apps into Home's groups (Customers, Bills to Pay…), the same groups Sort Now
/// uses, so what an AI app sorts shows on Home straight away. Plain labels don't: Home only
/// shows its groups.
enum GroupTools {
    static func tools(allowChanges: Bool) -> [MCPTool] {
        var tools = [
            MCPTool(name: "list_to_sort",
                    description: "The inbox conversations that still need sorting: not in a group and not looked at yet, newest first, with the total left. Sort them with sort_into_group (or skip_sorting when nothing fits) and call again until total is 0; sorted ones drop off the list.",
                    inputSchema: #"{"type":"object","properties":{"limit":{"type":"integer","minimum":1,"maximum":200,"description":"Defaults to 100."}},"additionalProperties":false}"#),
            MCPTool(name: "list_groups",
                    description: "Lists the groups Margin's Home sorts mail into, with what belongs in each and how many inbox conversations are in it. Sort with these (sort_into_group), not with labels, so the result shows on Home.",
                    inputSchema: #"{"type":"object","properties":{},"additionalProperties":false}"#),
        ]
        if allowChanges {
            tools += [
                MCPTool(name: "sort_into_group",
                        description: "Puts conversations into one of Home's groups (see list_groups). It shows on Home right away, and Margin's own sorting won't redo them.",
                        inputSchema: #"{"type":"object","properties":{"ids":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":200,"description":"Conversation ids from list_to_sort, search_mail or get_selection."},"group":{"type":"string","description":"A group name from list_groups."}},"required":["ids","group"],"additionalProperties":false}"#),
                MCPTool(name: "skip_sorting",
                        description: "Marks conversations as looked at without a group, when none fits, so list_to_sort stops returning them.",
                        inputSchema: #"{"type":"object","properties":{"ids":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":200}},"required":["ids"],"additionalProperties":false}"#),
                MCPTool(name: "create_group",
                        description: "Adds a new group to Home when none of list_groups fits. Keep names short and plural (\"Invoices\", \"Job offers\"); prefer existing groups.",
                        inputSchema: #"{"type":"object","properties":{"name":{"type":"string"},"detail":{"type":"string","description":"What belongs in it, in one sentence."}},"required":["name","detail"],"additionalProperties":false}"#),
            ]
        }
        return tools
    }
}

extension MailModel {
    /// Answers the group tools; nil for any other tool.
    func runGroupTool(_ name: String, _ arguments: [String: MCPValue]) async throws -> String? {
        switch name {
        case "list_to_sort":
            let limit = min(max(arguments["limit"]?.int ?? 100, 1), 200)
            let left = allInboxesThreads(nil).filter { isVisible($0) && needsSorting($0) }
            return json(["total": left.count, "conversations": left.prefix(limit).map(summaryJSON)] as [String: Any])
        case "skip_sorting":
            let threads = try await toolThreads(arguments)
            for thread in threads { sortingChecked[LabelStore.key(for: thread)] = Self.sortingMark(thread) }
            return "Skipped \(Self.count(threads)); they won't come back to list_to_sort."
        case "list_groups":
            let counts = Dictionary(uniqueKeysWithValues: homeGroups.map { ($0.group.name, $0.count) })
            return json(emailGroups.map { ["name": $0.name, "for": $0.detail, "conversations": counts[$0.name] ?? 0] as [String: Any] })
        case "sort_into_group":
            let threads = try await toolThreads(arguments)
            guard let wanted = arguments["group"]?.string?.trimmingCharacters(in: .whitespaces), !wanted.isEmpty else {
                throw MCPToolError("A group is needed. Use list_groups.")
            }
            guard let group = emailGroups.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) else {
                throw MCPToolError("No group “\(wanted)”. Use list_groups, or create_group when none fits.")
            }
            recordLabels()
            for thread in threads {
                // One group per conversation: moving it takes it out of any other group.
                if let current = self.group(of: thread), current.name.caseInsensitiveCompare(group.name) != .orderedSame {
                    removeLabel(current.name, from: thread)
                }
                addLabel(group.name, to: thread)
                sortingChecked[LabelStore.key(for: thread)] = Self.sortingMark(thread)
            }
            return "Put \(Self.count(threads)) in \(group.name)."
        case "create_group":
            guard let name = arguments["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name.count <= 30 else {
                throw MCPToolError("A short group name is needed.")
            }
            if let existing = emailGroups.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return "“\(existing.name)” already exists."
            }
            let detail = arguments["detail"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            emailGroups.append(EmailGroup(name: name, detail: detail))
            return "Added “\(name)” to Home."
        default:
            return nil
        }
    }
}
