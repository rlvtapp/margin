import MailCore
import SwiftUI

/// Settings → Rules: what happens to new mail, blocked senders and muted conversations. Every
/// rule is in one list, whether its mailbox's server keeps it (it runs while every device is off)
/// or Margin does, and one editor makes and changes them all.
struct RulesSettings: View {
    @Bindable var model: MailModel
    @State private var form = RuleForm()
    @State private var book = ServerRuleBook()
    @State private var saving = false
    @State private var problem: String?
    @State private var removing: ServerRuleRow?

    /// A server rule with its mailbox, for the list and for removing.
    struct ServerRuleRow: Identifiable, Hashable {
        var rule: ServerRule
        var account: MailAccount
        var id: String { account.id.uuidString + "|" + rule.id }
    }

    private var serverRows: [ServerRuleRow] {
        model.accounts.flatMap { account in (book.rules[account.id] ?? []).map { ServerRuleRow(rule: $0, account: account) } }
    }

    var body: some View {
        Form {
            SettingsHeader(.rules)
            Section {
                if model.mailRules.isEmpty && serverRows.isEmpty {
                    SettingsEmptyRow("No rules yet.")
                }
                ForEach(serverRows) { row in serverRow(row) }
                ForEach(model.mailRules) { rule in marginRow(rule) }
                ForEach(model.accounts) { account in
                    if case .failed(let text) = book.states[account.id] {
                        LabeledContent {
                            Button("Try Again") { Task { await book.load(account, model: model) } }.buttonStyle(.borderless)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: account.label)
                                Text(verbatim: text).font(TypeScale.caption).foregroundStyle(Status.danger)
                            }
                        }
                    } else if book.states[account.id] == .loading {
                        LabeledContent {
                            ProgressView().controlSize(.small)
                        } label: {
                            Text(verbatim: account.label).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Rules")
            } footer: {
                Text("Rules kept on the server run even when your Mac is off. Rules in Margin run on new inbox mail while it's open, before you're alerted.")
            }
            Section {
                if let suggestion = model.ruleSuggestion, form.editing == nil {
                    LabeledContent {
                        HStack(spacing: Space.s) {
                            Button("Use") { form = suggestion.form }.buttonStyle(.borderless)
                            Button("Not Now") { model.dismissRuleSuggestion() }.buttonStyle(.borderless)
                        }
                    } label: {
                        Label(suggestion.text, systemImage: "lightbulb")
                    }
                }
                RuleEditor(model: model, book: book, form: $form)
                HStack {
                    Button(saving ? "Saving…" : form.editing == nil ? "Add Rule" : "Save Rule") { Task { await save() } }
                        .disabled(saving || !form.isComplete)
                    if form.editing != nil {
                        Button("Cancel") { form = RuleForm() }
                    }
                    Spacer()
                    if form.editing == nil {
                        Menu("Start From") {
                            ForEach(MailModel.starterRules, id: \.title) { starter in
                                Button(starter.title) {
                                    var started = starter.form
                                    started.accountID = form.accountID
                                    form = started
                                }
                            }
                        }
                        .fixedSize()
                    }
                }
                if let problem {
                    Text(verbatim: problem).font(TypeScale.caption).foregroundStyle(Status.danger)
                }
            } header: {
                Text(form.editing == nil ? "New rule" : "Change rule")
            } footer: {
                Text("Or right-click a conversation and choose Create Rule… to start from its sender, domain or subject.")
            }
            Section {
                RuleActivityList(model: model)
            } header: {
                Text("Recent activity")
            } footer: {
                Text("When a rule moves new mail, Margin says so and you can undo it for a few seconds.")
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
        .task { await book.loadAll(model) }
        .confirmationDialog("Remove this rule from the server?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { row in
            Button("Remove Rule", role: .destructive) { Task { await remove(row) } }
        } message: { row in
            Text(verbatim: row.rule.title)
        }
    }

    private func serverRow(_ row: ServerRuleRow) -> some View {
        LabeledContent {
            HStack(spacing: Space.s) {
                if row.rule.isEditable {
                    Button("Edit") { form = RuleForm(server: row.rule, accountID: row.account.id) }.buttonStyle(.borderless)
                }
                Button("Remove") { removing = row }.buttonStyle(.borderless)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.xs) {
                    Text(verbatim: row.rule.title)
                    if !row.rule.isEnabled {
                        Text("Off").font(TypeScale.caption).foregroundStyle(.secondary)
                    }
                }
                Text(verbatim: MailModel.summary(of: row.rule, folders: book.folders[row.account.id] ?? []))
                    .font(TypeScale.caption).foregroundStyle(.secondary)
                place(String(localized: "On the server"), row.account.label)
                if !row.rule.isEditable {
                    Text("Made elsewhere with parts Margin can't show. Change it there, or remove it here.")
                        .font(TypeScale.caption).foregroundStyle(Ink.tertiary)
                }
            }
        }
    }

    private func marginRow(_ rule: MailRule) -> some View {
        LabeledContent {
            HStack(spacing: Space.s) {
                Button("Edit") { form = RuleForm(rule: rule) }.buttonStyle(.borderless)
                Button("Remove") {
                    model.mailRules.removeAll { $0.id == rule.id }
                    if form.editing == .margin(rule.id) { form = RuleForm() }
                }
                .buttonStyle(.borderless)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: rule.conditionTitle)
                Text(verbatim: "→ " + rule.actions.map(\.title).joined(separator: ", "))
                    .font(TypeScale.caption).foregroundStyle(.secondary)
                place(String(localized: "In Margin"), model.account(rule.accountID)?.label ?? String(localized: "All mailboxes"))
            }
        }
    }

    private func place(_ place: String, _ mailbox: String) -> some View {
        Text(verbatim: place + " · " + mailbox).font(TypeScale.caption).foregroundStyle(Ink.tertiary)
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await model.saveRule(form, book: book)
            problem = nil
            form = RuleForm(accountID: form.accountID)
        } catch {
            problem = error.localizedDescription
        }
    }

    private func remove(_ row: ServerRuleRow) async {
        do {
            try await model.deleteServerRule(row.rule, for: row.account, book: book)
            if case .server(let rule, _) = form.editing, rule.id == row.rule.id { form = RuleForm() }
        } catch {
            problem = error.localizedDescription
        }
    }
}
