import MailCore
import SwiftUI

/// Settings → Rules: what happens to new mail, blocked senders and muted conversations.
struct RulesSettings: View {
    @Bindable var model: MailModel
    @State private var form = RuleForm()

    var body: some View {
        Form {
            SettingsHeader(.rules)
            Section {
                if model.mailRules.isEmpty {
                    SettingsEmptyRow("No rules yet.")
                }
                ForEach(model.mailRules) { rule in
                    LabeledContent {
                        HStack(spacing: Space.s) {
                            Button("Edit") { form = RuleForm(rule: rule) }.buttonStyle(.borderless)
                            Button("Remove") {
                                model.mailRules.removeAll { $0.id == rule.id }
                                if form.editing == rule.id { form = RuleForm() }
                            }
                            .buttonStyle(.borderless)
                        }
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
                RuleEditor(model: model, form: $form)
                HStack {
                    Button(form.editing == nil ? "Add Rule" : "Save Rule") {
                        if model.addRule(form) {
                            form = RuleForm(accountID: form.accountID)
                        }
                    }
                    .disabled(form.rule == nil)
                    if form.editing != nil {
                        Button("Cancel") { form = RuleForm() }
                    }
                    Spacer()
                    if form.editing == nil {
                        Menu("Start From") {
                            ForEach(MailModel.starterRules, id: \.title) { starter in
                                Button(starter.title) { form = starter.form }
                            }
                        }
                        .fixedSize()
                    }
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
    }
}
