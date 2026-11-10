import MailCore
import SwiftUI

/// Settings → Rules: what happens to new mail, blocked senders and muted conversations.
struct RulesSettings: View {
    @Bindable var model: MailModel
    @State private var field = MailRule.Field.from
    @State private var contains = ""
    @State private var action = ActionChoice.archive
    @State private var name = ""
    @State private var accountID: UUID?

    enum ActionChoice: String, CaseIterable, Identifiable {
        case archive, trash, markRead, star, label, move
        var id: String { rawValue }
        var title: String {
            switch self {
            case .archive: String(localized: "Archive")
            case .trash: String(localized: "Move to Trash")
            case .markRead: String(localized: "Mark as read")
            case .star: String(localized: "Star")
            case .label: String(localized: "Label…")
            case .move: String(localized: "Move to folder…")
            }
        }
    }

    var body: some View {
        Form {
            SettingsHeader(.rules)
            Section {
                if model.mailRules.isEmpty {
                    SettingsEmptyRow("No rules yet.")
                }
                ForEach(model.mailRules) { rule in
                    LabeledContent {
                        Button("Remove") { model.mailRules.removeAll { $0.id == rule.id } }.buttonStyle(.borderless)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(rule.field.title) contains “\(rule.contains)”")
                            Text(verbatim: "→ " + rule.action.title + (model.account(rule.accountID).map { " · " + $0.label } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Rules")
            } footer: {
                Text("Rules apply to new mail in the inbox while Margin is open, before you're alerted.")
            }
            Section {
                Picker("When", selection: $field) {
                    ForEach(MailRule.Field.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                TextField("contains", text: $contains, prompt: Text("newsletter@, Invoice, …"))
                    .autocorrectionDisabled()
                Picker("Then", selection: $action) {
                    ForEach(ActionChoice.allCases) { Text($0.title).tag($0) }
                }
                if action == .label || action == .move {
                    TextField(action == .label ? "Label" : "Folder", text: $name)
                }
                if model.accounts.count > 1 {
                    Picker("Mailbox", selection: $accountID) {
                        Text("All mailboxes").tag(UUID?.none)
                        ForEach(model.accounts) { Text(verbatim: $0.label).tag(Optional($0.id)) }
                    }
                }
                Button("Add Rule") { add() }
                    .disabled(contains.trimmingCharacters(in: .whitespaces).isEmpty
                              || ((action == .label || action == .move) && name.trimmingCharacters(in: .whitespaces).isEmpty))
            } header: {
                Text("New rule")
            }
            Section {
                if model.blockedSenders.isEmpty {
                    SettingsEmptyRow("Block someone from a conversation's … menu.")
                }
                ForEach(model.blockedSenders.sorted(), id: \.self) { address in
                    LabeledContent {
                        Button("Unblock") { model.unblock(address) }.buttonStyle(.borderless)
                    } label: { Text(verbatim: address) }
                }
            } header: {
                Text("Blocked senders")
            } footer: {
                Text("Their mail goes straight to Trash.")
            }
            Section {
                LabeledContent {
                    Button("Unmute All") { model.mutedThreads = [] }.disabled(model.mutedThreads.isEmpty)
                } label: {
                    Text("\(model.mutedThreads.count) muted conversations")
                }
            } header: {
                Text("Muted conversations")
            } footer: {
                Text("Replies to a muted conversation are archived and marked read. Mute one from its … menu.")
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let chosen: MailRule.Action = switch action {
        case .archive: .archive
        case .trash: .trash
        case .markRead: .markRead
        case .star: .star
        case .label: .label(trimmed)
        case .move: .move(trimmed)
        }
        model.mailRules.append(MailRule(field: field, contains: contains.trimmingCharacters(in: .whitespaces), action: chosen, accountID: accountID))
        contains = ""
        name = ""
    }
}
