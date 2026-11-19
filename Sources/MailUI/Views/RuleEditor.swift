import AuthenticationServices
import MailCore
import SwiftUI

/// The one editor for rules, as rows in a form: what to look for, what to do, which mailbox, and
/// where it runs (on the mailbox's server when it keeps rules, so it works while every device is
/// off; otherwise in Margin), with anything still missing marked in orange and the inbox mail it
/// would catch right under it. With the assistant on, the rule can be described in words first.
/// Settings → Rules and Create Rule… both use it.
struct RuleEditor: View {
    let model: MailModel
    let book: ServerRuleBook
    @Binding var form: RuleForm
    @Environment(\.webAuthenticationSession) private var webAuthentication
    @State private var words = ""
    @State private var isWriting = false
    @State private var writingError: String?
    @State private var accessProblem: String?

    private var account: MailAccount? { model.account(form.accountID) }
    private var onServer: Bool { form.place == .server }
    private var features: ServerRuleFeatures {
        form.accountID.flatMap { book.features[$0] } ?? ServerRuleFeatures()
    }
    private var serverFolders: [ServerFolder] { form.accountID.flatMap { book.folders[$0] } ?? [] }

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
        if model.accounts.count > 1 {
            Picker("Mailbox", selection: $form.accountID) {
                Text("All mailboxes").tag(UUID?.none)
                ForEach(model.accounts) { Text(verbatim: $0.label).tag(Optional($0.id)) }
            }
            .onChange(of: form.accountID) { _, _ in choosePlace() }
        }
        placeRow
            .onChange(of: book.states) { _, _ in choosePlace() }
            .onAppear(perform: choosePlace)

        TextField("From contains", text: $form.from, prompt: Text(verbatim: "newsletter@, @example.com"))
            .autocorrectionDisabled()
        TextField("To contains", text: $form.to, prompt: Text(verbatim: "team@example.com"))
            .autocorrectionDisabled()
        TextField("Subject contains", text: $form.subject, prompt: Text("Invoice"))
        if !onServer || features.hasAttachment {
            Toggle("Has an attachment", isOn: $form.hasAttachment)
        }

        Picker("Then", selection: $form.move) {
            ForEach(RuleForm.Move.allCases.filter { $0 != .archive || !onServer || features.archive }) { Text($0.title).tag($0) }
        }
        if form.move == .folder { folderRow }
        Toggle("Mark as read", isOn: $form.markRead)
        Toggle("Star", isOn: $form.star)
        TextField("Forward to", text: $form.forwardTo, prompt: Text(verbatim: "name@example.com"))
            .autocorrectionDisabled()
        TextField("Label", text: $form.label, prompt: Text("Optional"))
        TextField("Answer", text: $form.answer, prompt: Text("Thanks for your email. I'll get back to you next week."), axis: .vertical)
            .lineLimit(1...6)
        Toggle("Keep quiet (no alert)", isOn: $form.quiet)

        ForEach(notes, id: \.self) { note in
            Text(verbatim: note).font(TypeScale.caption).foregroundStyle(Ink.tertiary)
        }
        ForEach(missing, id: \.self) { problem in
            Label(problem, systemImage: "exclamationmark.circle")
                .font(TypeScale.caption)
                .foregroundStyle(Status.star)
        }
        RuleMatches(model: model, form: form)
    }

    /// Where it runs: a choice when the mailbox's server keeps rules, otherwise why it's Margin.
    @ViewBuilder
    private var placeRow: some View {
        if let account {
            switch model.serverRulesSupport(account) {
            case .needsAccess:
                LabeledContent("Runs") {
                    Button("Set Up Server Rules…") { Task { await connect(account) } }
                }
                Text("Until then, it runs in Margin while it's open. On the server, rules run even when your Mac is off.")
                    .font(TypeScale.caption).foregroundStyle(Ink.tertiary)
                if let accessProblem { Text(verbatim: accessProblem).font(TypeScale.caption).foregroundStyle(Status.danger) }
            case .ready, .sieve:
                switch book.states[account.id] {
                case .loaded:
                    Picker("Runs", selection: $form.place) {
                        ForEach(RuleForm.Place.allCases) { Text($0.title).tag($0) }
                    }
                    .onChange(of: form.place) { old, new in carryFolder(from: old, to: new) }
                case .localOnly:
                    Text(verbatim: MailModel.localOnlyText).font(TypeScale.caption).foregroundStyle(Ink.tertiary)
                case .failed(let problem):
                    Text(verbatim: problem).font(TypeScale.caption).foregroundStyle(Status.danger)
                case .loading, nil:
                    LabeledContent("Runs") { ProgressView().controlSize(.small) }
                }
            case .localOnly:
                Text(verbatim: MailModel.localOnlyText).font(TypeScale.caption).foregroundStyle(Ink.tertiary)
            }
        } else {
            Text("Rules for every mailbox run in Margin while it's open. Choose one mailbox to keep a rule on its server.")
                .font(TypeScale.caption).foregroundStyle(Ink.tertiary)
        }
    }

    @ViewBuilder
    private var folderRow: some View {
        if onServer {
            Picker("Folder", selection: $form.folder) {
                ForEach(serverFolders) { Text(verbatim: $0.name).tag($0.id) }
            }
            .onAppear(perform: pickFirstFolder)
        } else {
            HStack(spacing: Space.s) {
                TextField("Folder", text: $form.folder)
                let names = model.ruleFolderNames(for: form.accountID)
                if !names.isEmpty {
                    Menu {
                        ForEach(names, id: \.self) { name in Button { form.folder = name } label: { Text(verbatim: name) } }
                    } label: { Image(systemName: "chevron.up.chevron.down") }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(Text("Choose"))
                }
            }
        }
    }

    /// A new rule goes on the server when the mailbox's server keeps rules; a rule being changed
    /// stays where it is until the person moves it.
    private func choosePlace() {
        let available = book.canKeep(form.accountID)
        if !available {
            // Only once it's known the server can't keep it; while its rules load, nothing changes.
            if form.place == .server, !book.mightKeep(form.accountID, model: model) {
                form.place = .margin
                carryFolder(from: .server, to: .margin)
            }
        } else if form.editing == nil, form.place == .margin, !form.needsMargin {
            form.place = .server
            carryFolder(from: .margin, to: .server)
        }
    }

    /// The same folder in its new place: Margin knows folders by name, the server by its id.
    private func carryFolder(from old: RuleForm.Place, to new: RuleForm.Place) {
        guard old != new, form.move == .folder else { return }
        if new == .server {
            guard !serverFolders.isEmpty else { return }
            form.folder = serverFolders.first { $0.id == form.folder || $0.name.caseInsensitiveCompare(form.folder) == .orderedSame }?.id
                ?? serverFolders.first?.id ?? ""
        } else {
            form.folder = serverFolders.first { $0.id == form.folder }?.name ?? form.folder
        }
    }

    private func pickFirstFolder() {
        // Not before the server's folders are known, or the rule's own folder would be lost.
        if onServer, form.move == .folder, !serverFolders.isEmpty, !serverFolders.contains(where: { $0.id == form.folder }) {
            form.folder = serverFolders.first?.id ?? ""
        }
    }

    /// What it's good to know: what sends mail by itself, and what a server does its own way.
    private var notes: [String] {
        var notes: [String] = []
        if onServer {
            if form.needsMargin {
                notes.append(String(localized: "A label, an answer and keeping quiet work only in Margin."))
            }
            if form.star && features.flagMarksImportant {
                notes.append(String(localized: "This server's rules can't flag mail, so the email is marked as important instead."))
            }
            if !RuleForm.trimmed(form.forwardTo).isEmpty && features.forwardNeedsVerifiedAddress {
                notes.append(String(localized: "Forwarding works only to an address your provider has already verified."))
            }
        } else {
            if !RuleForm.trimmed(form.answer).isEmpty {
                notes.append(String(localized: "Sends mail by itself: each sender gets the answer at most once every 4 days, and mailing lists and no-reply addresses never do."))
            }
            if !RuleForm.trimmed(form.forwardTo).isEmpty {
                notes.append(String(localized: "Sends mail by itself: each new email that matches is forwarded with its formatting, never back to its sender."))
            }
        }
        return notes
    }

    /// What's left to fill in, or won't work as it is.
    private var missing: [String] {
        var problems: [String] = []
        if !form.hasCondition { problems.append(String(localized: "Fill in at least one condition.")) }
        if !form.hasAction { problems.append(String(localized: "Choose at least one action.")) }
        if form.move == .folder && RuleForm.trimmed(form.folder).isEmpty { problems.append(String(localized: "Name the folder")) }
        let forward = RuleForm.trimmed(form.forwardTo)
        if !forward.isEmpty && !EmailAddress.isValid(forward) { problems.append(String(localized: "That isn't an email address")) }
        if model.ruleFolderMissing(form) { problems.append(String(localized: "No folder with this name in that mailbox")) }
        return problems
    }

    private func connect(_ account: MailAccount) async {
        do {
            try await model.requestAccess([.rules], for: account) { url, scheme in
                try await webAuthentication.authenticate(using: url, callbackURLScheme: scheme, preferredBrowserSession: .ephemeral)
            }
            accessProblem = nil
            await book.load(account, model: model)
        } catch let failure as ASWebAuthenticationSessionError where failure.code == .canceledLogin {
            return
        } catch {
            accessProblem = error.localizedDescription
        }
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
                written.place = form.editing == nil ? .margin : form.place
                if written.place == .server { written.accountID = form.accountID }
                form = written
                choosePlace()
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
    @State private var book = ServerRuleBook()
    @State private var saving = false
    @State private var problem: String?
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
                        form.from = picked.from
                        form.to = picked.to
                        form.subject = picked.subject
                    }
                    RuleEditor(model: model, book: book, form: $form)
                } header: {
                    Text("New rule")
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Add Rule") {
                    Task {
                        saving = true
                        defer { saving = false }
                        do {
                            try await model.saveRule(form, book: book)
                            dismiss()
                        } catch {
                            problem = error.localizedDescription
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || !form.isComplete)
            }
            .padding(Space.m)
            if let problem {
                Text(verbatim: problem).font(TypeScale.caption).foregroundStyle(Status.danger).padding([.horizontal, .bottom], Space.m)
            }
        }
        .frame(minWidth: 460, minHeight: 560)
        .task { if let account = model.account(form.accountID) { await book.load(account, model: model) } }
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
