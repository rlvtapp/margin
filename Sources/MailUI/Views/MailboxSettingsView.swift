import MailCore
import SwiftUI

/// One mailbox's identity: the name people see, the other addresses it sends as, and its
/// signatures (one for new mail, optionally another for replies).
struct SignatureEditor: View {
    let model: MailModel
    let accountID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var account: MailAccount?
    @State private var newAliasAddress = ""
    @State private var newAliasName = ""
    /// Addresses that look like this mailbox's own (see `aliasSuggestions`), to add with a tap.
    @State private var suggestions: [EmailAddress] = []
    @State private var choosingPicture = false
    @State private var server = MailboxServerFields()
    @State private var serverStatus: String?
    @State private var checking = false
    @State private var makingSignature = false
    @State private var details = SignatureTools.Details()
    @State private var findingSignature = false
    @State private var signatureNote: String?

    var body: some View {
        NavigationStack {
            Form {
                if let account = Binding($account) {
                    Section {
                        TextField("Sender name", text: Binding(
                            get: { account.wrappedValue.address.name ?? "" },
                            set: { account.wrappedValue.address.name = $0.isEmpty ? nil : $0 }
                        ))
                    } footer: {
                        Text("What people see as the sender, like “Alex from Northwind”. Every address in this mailbox uses it unless you give one its own name under Send as.")
                    }

                    Section {
                        Picker("Notify me about", selection: Binding(
                            get: { model.alerts(for: accountID) },
                            set: { model.setAlerts($0, for: accountID) }
                        )) {
                            Text("Same as other mailboxes").tag(NewMailAlerts?.none)
                            ForEach(NewMailAlerts.allCases, id: \.self) { Text($0.title).tag(NewMailAlerts?.some($0)) }
                        }
                        Toggle("Show in All Inboxes", isOn: Binding(
                            get: { account.wrappedValue.inAllInboxes != false },
                            set: { account.wrappedValue.inAllInboxes = $0 ? nil : false }
                        ))
                    } header: {
                        Text("Notifications")
                    }

                    AutoReplySection(model: model, account: account.wrappedValue)

                    OutlookReactionsSection(model: model, account: account.wrappedValue)

                    Section {
                        HStack(spacing: Space.m) {
                            AccountMark(account.wrappedValue, size: 44)
                            Button("Choose Picture…") { choosingPicture = true }
                            if account.wrappedValue.picture != nil {
                                Button("Remove", role: .destructive) {
                                    model.setPicture(nil, for: accountID)
                                    account.wrappedValue.picture = nil
                                }
                            }
                        }
                    } header: {
                        Text("Picture")
                    }

                    if case .imap = account.wrappedValue.connection {
                        Section {
                            TextField("Incoming server (IMAP)", text: $server.incomingHost)
                            TextField("Port", value: $server.incomingPort, format: .number.grouping(.never))
                            TextField("Outgoing server (SMTP)", text: $server.outgoingHost)
                            TextField("Port", value: $server.outgoingPort, format: .number.grouping(.never))
                            if case .password = account.wrappedValue.auth {
                                TextField("Username", text: $server.username)
                                SecureField("New password (leave empty to keep)", text: $server.password)
                            }
                            HStack {
                                Text(verbatim: serverStatus ?? " ").font(TypeScale.label).foregroundStyle(Ink.tertiary)
                                Spacer()
                                Button(checking ? "Checking…" : "Check and Save") { checkServer(account.wrappedValue) }.disabled(checking)
                            }
                        } header: {
                            Text("Server and sign-in")
                        } footer: {
                            Text("Margin tries the new settings first. If they don't work, nothing changes.")
                        }
                    }

                    Section {
                        let senderName = account.wrappedValue.address.name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                        HStack {
                            Text(verbatim: account.wrappedValue.address.address)
                            Spacer()
                            Text(verbatim: senderName ?? "").foregroundStyle(.secondary)
                        }
                        ForEach(Array((account.wrappedValue.aliases ?? []).enumerated()), id: \.offset) { index, alias in
                            HStack {
                                Text(verbatim: alias.address).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                TextField("", text: Binding(
                                    get: { (account.wrappedValue.aliases ?? []).indices.contains(index) ? account.wrappedValue.aliases?[index].name ?? "" : "" },
                                    set: { value in
                                        guard account.wrappedValue.aliases?.indices.contains(index) == true else { return }
                                        account.wrappedValue.aliases?[index].name = value.trimmingCharacters(in: .whitespaces).isEmpty ? nil : value
                                    }
                                ), prompt: senderName.map { Text(verbatim: $0) } ?? Text("Name"))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .textFieldStyle(.plain)
                                .frame(maxWidth: 170)
                                .accessibilityLabel(Text("Name for \(alias.address)"))
                                Button(role: .destructive) { account.wrappedValue.aliases?.remove(at: index) } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove")
                            }
                        }
                        let known = Set(([account.wrappedValue.address] + (account.wrappedValue.aliases ?? [])).map { $0.address.lowercased() })
                        ForEach(suggestions.filter { !known.contains($0.address.lowercased()) }, id: \.address) { suggestion in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: suggestion.address)
                                    Text("Mail sent to it arrives here").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Add") { account.wrappedValue.aliases = (account.wrappedValue.aliases ?? []) + [suggestion] }
                                Button {
                                    model.dismissAliasSuggestion(suggestion, for: account.wrappedValue)
                                    suggestions.removeAll { $0.address == suggestion.address }
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .buttonStyle(.borderless)
                                .tip("Not mine")
                            }
                        }
                        AliasAddRow(address: $newAliasAddress, name: $newAliasName) { addAlias(to: account) }
                    } header: {
                        Text("Send as")
                    } footer: {
                        Text("Other addresses this mailbox can send from. Your provider has to allow them. Replies to mail sent to one go out from it. Leave a name empty to use the sender name.")
                    }
                    .task(id: accountID) {
                        if let current = model.account(accountID) { suggestions = await model.aliasSuggestions(for: current) }
                    }

                    Section {
                        signatureField("Default", text: Binding(
                            get: { account.wrappedValue.signature ?? "" },
                            set: { account.wrappedValue.signature = $0.isEmpty ? nil : $0 }
                        ))
                        ForEach(Array((account.wrappedValue.moreSignatures ?? []).enumerated()), id: \.offset) { index, _ in
                            VStack(alignment: .leading, spacing: Space.xs) {
                                HStack {
                                    TextField("Name", text: Binding(
                                        get: { account.wrappedValue.moreSignatures?[index].name ?? "" },
                                        set: { account.wrappedValue.moreSignatures?[index].name = $0 }
                                    ))
                                    .font(TypeScale.rowStrong)
                                    Button(role: .destructive) { account.wrappedValue.moreSignatures?.remove(at: index) } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Remove")
                                }
                                signatureEditor(Binding(
                                    get: { account.wrappedValue.moreSignatures?[index].text ?? "" },
                                    set: { account.wrappedValue.moreSignatures?[index].text = $0 }
                                ))
                            }
                        }
                        Button("Add a signature") {
                            let number = (account.wrappedValue.moreSignatures?.count ?? 0) + 2
                            account.wrappedValue.moreSignatures = (account.wrappedValue.moreSignatures ?? [])
                                + [NamedSignature(name: String(localized: "Signature \(number)"), text: "")]
                        }
                        Picker("For replies and forwards", selection: Binding(
                            get: { account.wrappedValue.replySignature ?? NamedSignature.defaultName },
                            set: { account.wrappedValue.replySignature = $0 == NamedSignature.defaultName ? nil : $0 }
                        )) {
                            Text("Default").tag(NamedSignature.defaultName)
                            ForEach(account.wrappedValue.moreSignatures ?? []) { Text(verbatim: $0.name).tag($0.name) }
                            Text("None").tag("")
                        }
                    } header: {
                        Text("Signatures")
                    } footer: {
                        Text("Pick another signature while writing from the signature menu.")
                    }

                    Section {
                        HStack {
                            Button("Make One for Me…") {
                                details.name = account.wrappedValue.address.displayName
                                makingSignature = true
                            }
                            Button(findingSignature ? "Looking…" : "Find in Sent Mail") {
                                findingSignature = true
                                Task {
                                    if let found = await model.findSignatureInSentMail(accountID) {
                                        account.wrappedValue.signature = found
                                        signatureNote = String(localized: "Found it in your sent mail.")
                                    } else {
                                        signatureNote = String(localized: "No signature showed up in enough sent messages.")
                                    }
                                    findingSignature = false
                                }
                            }
                            .disabled(findingSignature)
                        }
                        Text(verbatim: signatureNote ?? " ").font(TypeScale.label).foregroundStyle(Ink.tertiary)
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text("Formatted (HTML)").font(TypeScale.rowStrong)
                            signatureEditor(Binding(
                                get: { account.wrappedValue.signatureHTML ?? "" },
                                set: { account.wrappedValue.signatureHTML = $0.isEmpty ? nil : $0 }
                            ))
                            .font(TypeScale.label.monospaced())
                            if let html = account.wrappedValue.signatureHTML, !html.isEmpty {
                                let safe = HTMLSanitizer.sanitize(html)
                                if safe.html != html.trimmingCharacters(in: .whitespacesAndNewlines), safe.hasRemoteContent {
                                    Text("Pictures from the web in a signature often show as blocked for the people you write to.")
                                        .font(TypeScale.label).foregroundStyle(Status.danger)
                                }
                                Text("Preview").font(TypeScale.label).foregroundStyle(Ink.tertiary)
                                HTMLMessageView(html: safe, allowsRemote: true)
                                    .frame(minHeight: 60)
                            }
                        }
                    } header: {
                        Text("Signature tools")
                    } footer: {
                        Text("The formatted signature is sent in place of the default one; the plain one stays for plain-text mail.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Text(verbatim: account?.label ?? ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if var account {
                            account.moreSignatures = account.moreSignatures?.filter { !$0.name.isEmpty }
                            model.update(account)
                        }
                        dismiss()
                    }
                }
            }
        }
        .tint(Ink.primary)
        #if os(macOS)
        .frame(width: 520, height: 620)
        #endif
        .onAppear {
            account = model.account(accountID)
            if let account { server = MailboxServerFields(account) }
        }
        .sheet(isPresented: $makingSignature) { makeSignatureSheet }
        .fileImporter(isPresented: $choosingPicture, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            model.setPicture(data, for: accountID)
            account?.picture = model.account(accountID)?.picture
        }
    }

    private func signatureField(_ title: LocalizedStringKey, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title).font(TypeScale.rowStrong)
            signatureEditor(text)
        }
    }

    private func signatureEditor(_ text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(TypeScale.row)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 70)
            .padding(6)
            .background(Fill.one, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var makeSignatureSheet: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $details.name)
                TextField("Role", text: $details.role)
                TextField("Company", text: $details.company)
                TextField("Phone", text: $details.phone)
                TextField("Website", text: $details.website)
                Section("Preview") {
                    HTMLMessageView(html: HTMLSanitizer.sanitize(SignatureTools.make(details).html), allowsRemote: false).frame(minHeight: 60)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Make a signature")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { makingSignature = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use It") {
                        let made = SignatureTools.make(details)
                        account?.signature = made.text
                        account?.signatureHTML = made.html
                        makingSignature = false
                    }
                }
            }
        }
        #if os(macOS)
        .frame(width: 420, height: 480)
        #endif
    }

    private func checkServer(_ current: MailAccount) {
        guard case .imap(let incoming, let outgoing) = current.connection else { return }
        var changed = current
        changed.connection = .imap(
            incoming: ServerEndpoint(host: server.incomingHost.trimmingCharacters(in: .whitespaces), port: server.incomingPort, security: incoming.security),
            outgoing: ServerEndpoint(host: server.outgoingHost.trimmingCharacters(in: .whitespaces), port: server.outgoingPort, security: outgoing.security)
        )
        if case .password = current.auth, !server.username.isEmpty { changed.auth = .password(username: server.username) }
        checking = true
        serverStatus = nil
        Task {
            do {
                try await model.updateConnection(changed, secret: server.password.isEmpty ? nil : server.password)
                account?.connection = changed.connection
                account?.auth = changed.auth
                server.password = ""
                serverStatus = String(localized: "Connected and saved.")
            } catch {
                serverStatus = error.localizedDescription
            }
            checking = false
        }
    }

    private func addAlias(to account: Binding<MailAccount>) {
        let address = newAliasAddress.trimmingCharacters(in: .whitespaces)
        guard EmailAddress.isValid(address) else { return }
        let known = ([account.wrappedValue.address] + (account.wrappedValue.aliases ?? [])).map { $0.address.lowercased() }
        if !known.contains(address.lowercased()) {
            account.wrappedValue.aliases = (account.wrappedValue.aliases ?? []) + [EmailAddress(name: newAliasName, address: address)]
        }
        newAliasAddress = ""
        newAliasName = ""
    }
}

/// Adding an address to send from: the address, and a name of its own if it shouldn't use the
/// mailbox's sender name. Laid out like the rows above it (address left, name right).
private struct AliasAddRow: View {
    @Binding var address: String
    @Binding var name: String
    let add: () -> Void

    private var isValid: Bool { EmailAddress.isValid(address.trimmingCharacters(in: .whitespaces)) }

    var body: some View {
        #if os(iOS)
        VStack(spacing: Space.s) {
            addressField
            HStack {
                nameField
                Button("Add", action: add).disabled(!isValid)
            }
        }
        #else
        HStack {
            addressField
            nameField.frame(maxWidth: 170)
            Button("Add", action: add).disabled(!isValid)
        }
        #endif
    }

    private var addressField: some View {
        TextField("", text: $address, prompt: Text(verbatim: "sales@yourdomain.com"))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(Text("Email address"))
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            #endif
            .onSubmit { if isValid { add() } }
    }

    private var nameField: some View {
        TextField("", text: $name, prompt: Text("Name (optional)"))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(Text("Name (optional)"))
            .onSubmit { if isValid { add() } }
    }
}

/// While writing: which signature goes at the end. Shown only when there's more than one.
struct SignatureMenu: View {
    let model: MailModel
    @Binding var state: ComposeState

    var body: some View {
        if let account = model.account(state.accountID), account.allSignatures.count > 1 {
            Menu {
                ForEach(account.allSignatures) { signature in
                    Button(signature.name == NamedSignature.defaultName ? String(localized: "Default") : signature.name) {
                        state.use(signature: signature.text)
                    }
                }
                Divider()
                Button("No signature") { state.use(signature: nil) }
            } label: {
                Image(systemName: "signature")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Ink.tertiary)
                    .frame(width: 28, height: 28)
                    .accessibilityLabel(Text("Signature"))
            }
            #if os(macOS)
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            #endif
            .tip("Signature")
        }
    }
}

/// The editable parts of an IMAP mailbox's connection.
private struct MailboxServerFields {
    var incomingHost = ""
    var incomingPort = 993
    var outgoingHost = ""
    var outgoingPort = 465
    var username = ""
    var password = ""

    init() {}

    init(_ account: MailAccount) {
        if case .imap(let incoming, let outgoing) = account.connection {
            incomingHost = incoming.host; incomingPort = incoming.port
            outgoingHost = outgoing.host; outgoingPort = outgoing.port
        }
        if case .password(let name) = account.auth { username = name }
    }
}

/// The first mailbox's settings on their own, for screenshots.
public struct MailboxSettingsSnapshot: View {
    let model: MailModel
    public init(model: MailModel) { self.model = model }

    public var body: some View {
        if let id = model.accounts.first?.id { SignatureEditor(model: model, accountID: id) }
    }
}
