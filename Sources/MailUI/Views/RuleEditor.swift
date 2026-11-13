import MailCore
import SwiftUI

/// The parts of a rule, as rows in a form: what to look for, what to do, which mailbox, with
/// anything still missing marked in orange and the inbox mail it would catch right under it.
/// With the assistant on, the rule can be described in words first. Settings → Rules and Create
/// Rule… both use it.
struct RuleEditor: View {
    let model: MailModel
    @Binding var form: RuleForm
    @State private var words = ""
    @State private var isWriting = false
    @State private var writingError: String?

    var body: some View {
        if model.isAssistantOn {
            HStack(spacing: Space.s) {
                TextField("Describe a rule", text: $words, prompt: Text("Like: always star mail from my bank"))
                    .onSubmit(write)
                if isWriting {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Write Rule", action: write)
                        .disabled(words.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let writingError {
                Text(verbatim: writingError).font(TypeScale.caption).foregroundStyle(Status.danger)
            }
        }
        Picker("When", selection: $form.field) {
            ForEach(MailRule.Field.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        TextField("contains", text: $form.contains, prompt: Text("newsletter@, Invoice, …"))
            .autocorrectionDisabled()
        Picker("Then", selection: $form.choice) {
            ForEach(RuleForm.Choice.allCases) { Text($0.title).tag($0) }
        }
        if form.choice == .forward {
            TextField("Forward to", text: $form.name, prompt: Text(verbatim: "name@example.com"))
                .autocorrectionDisabled()
        } else if form.choice == .answer {
            TextField("Answer", text: $form.name, prompt: Text("Thanks for your email. I'll get back to you next week."), axis: .vertical)
                .lineLimit(2...6)
        } else if form.choice.needsName {
            HStack(spacing: Space.s) {
                TextField(form.choice == .label ? "Label" : "Folder", text: $form.name)
                let names = form.choice == .label ? model.ruleLabelNames : model.ruleFolderNames(for: form.accountID)
                if !names.isEmpty {
                    Menu {
                        ForEach(names, id: \.self) { name in Button { form.name = name } label: { Text(verbatim: name) } }
                    } label: { Image(systemName: "chevron.up.chevron.down") }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(Text("Choose"))
                }
            }
        }
        if model.accounts.count > 1 {
            Picker("Mailbox", selection: $form.accountID) {
                Text("All mailboxes").tag(UUID?.none)
                ForEach(model.accounts) { Text(verbatim: $0.label).tag(Optional($0.id)) }
            }
        }
        if form.choice.sendsMail {
            Text(form.choice == .answer
                 ? "Sends mail by itself: each sender gets the answer at most once every 4 days, and mailing lists and no-reply addresses never do."
                 : "Sends mail by itself: each new email that matches is forwarded with its formatting, never back to its sender.")
                .font(TypeScale.caption)
                .foregroundStyle(Ink.tertiary)
        }
        ForEach(missing, id: \.self) { problem in
            Label(problem, systemImage: "exclamationmark.circle")
                .font(TypeScale.caption)
                .foregroundStyle(Status.star)
        }
        RuleMatches(model: model, form: form)
    }

    /// What's left to fill in, or won't work as it is.
    private var missing: [String] {
        var problems: [String] = []
        if form.trimmedContains.isEmpty { problems.append(String(localized: "Add the text to look for")) }
        if form.choice.needsName && form.trimmedName.isEmpty {
            let problem: String = switch form.choice {
            case .label: String(localized: "Name the label")
            case .forward: String(localized: "Add the address to forward to")
            case .answer: String(localized: "Write the answer")
            default: String(localized: "Name the folder")
            }
            problems.append(problem)
        } else if form.choice == .forward && !EmailAddress.isValid(form.trimmedName) {
            problems.append(String(localized: "That isn't an email address"))
        }
        if model.ruleFolderMissing(form) { problems.append(String(localized: "No folder with this name in that mailbox")) }
        return problems
    }

    private func write() {
        let text = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isWriting else { return }
        isWriting = true
        writingError = nil
        Task {
            do {
                var written = try await model.writeRule(text)
                written.id = form.id
                written.threadID = form.threadID
                // Describing it again changes the rule being edited, not a new one.
                written.editing = form.editing
                form = written
            } catch {
                writingError = error.localizedDescription
            }
            isWriting = false
        }
    }
}

/// How much of the inbox a rule would catch now, with the first few.
struct RuleMatches: View {
    let model: MailModel
    let form: RuleForm

    var body: some View {
        if let condition = form.condition {
            let found = model.inboxMatches(condition)
            VStack(alignment: .leading, spacing: 3) {
                Text(found.isEmpty ? String(localized: "Nothing in your inbox matches it now")
                     : found.count == 1 ? String(localized: "Catches 1 conversation in your inbox now")
                     : String(localized: "Catches \(found.count) conversations in your inbox now"))
                    .font(TypeScale.caption)
                    .foregroundStyle(Ink.secondary)
                ForEach(found.prefix(3)) { thread in
                    Text(verbatim: "\(thread.latest.from.displayName) · \(thread.subject)")
                        .font(TypeScale.caption)
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// Create Rule… from a conversation: catch its sender, their domain or its subject, then say
/// what happens, seeing what it would catch before adding it.
struct CreateRuleSheet: View {
    let model: MailModel
    @State var form: RuleForm
    @State private var basis = RuleForm.Basis.sender
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Catch", selection: $basis) {
                        ForEach(RuleForm.Basis.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: basis) { _, basis in
                        guard let thread = thread else { return }
                        let picked = model.ruleForm(for: thread, basis: basis)
                        form.field = picked.field
                        form.contains = picked.contains
                    }
                    RuleEditor(model: model, form: $form)
                } header: {
                    Text("New rule")
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Rule") {
                    if model.addRule(form) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(form.rule == nil)
            }
            .padding(Space.m)
        }
        .frame(minWidth: 460, minHeight: 440)
    }

    private var thread: MailThread? {
        guard let id = form.threadID else { return nil }
        return (model.inboxThreads(nil) + model.folder + model.visibleThreads).first { $0.id == id }
    }
}

/// Settings → Rules → Recent activity: what rules did to new mail, newest first.
struct RuleActivityList: View {
    let model: MailModel

    var body: some View {
        let entries = model.ruleActivity
        if entries.isEmpty {
            SettingsEmptyRow("No rule has acted on new mail yet.")
        }
        ForEach(entries.prefix(30)) { entry in
            LabeledContent {
                if entry.undone {
                    Text("Undone").font(TypeScale.caption).foregroundStyle(Ink.tertiary)
                } else {
                    Text(entry.date, format: .relative(presentation: .named)).font(TypeScale.caption).foregroundStyle(Ink.tertiary)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: entry.subject.isEmpty ? entry.sender : entry.subject).lineLimit(1)
                    Text(verbatim: "\(entry.action) · \(entry.sender)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}
