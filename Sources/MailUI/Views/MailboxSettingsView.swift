import MailCore
import SwiftUI

/// One mailbox's settings, in parts: General (its name, picture, notifications, automatic reply),
/// Sending (the name people see and the other addresses it sends as), Signatures, and Server for
/// a mailbox set up by hand.
struct SignatureEditor: View {
    let model: MailModel
    let accountID: UUID
    /// In the Settings window itself (picked in its sidebar) instead of a sheet: no size of its
    /// own, Save stays on the page and Revert puts back what was saved.
    var isEmbedded = false
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
    @State private var editing: SignatureEditing?
    /// The part of the mailbox's settings in view.
    @State private var tab: Tab = .general

    enum Tab { case general, sending, signatures, server }

    var body: some View {
        NavigationStack {
            Form {
                if let account = Binding($account) {
                    if isEmbedded {
                        // The same opening as every Settings page: the mailbox's mark, name and address.
                        Section {
                        } footer: {
                            VStack(spacing: 0) {
                                MailboxPhoto(model: model, account: account.wrappedValue, size: Look.gap(40))
                                Text(verbatim: account.wrappedValue.label)
                                    .font(.system(size: Look.size(20), weight: .bold))
                                    .foregroundStyle(Ink.primary)
                                    .padding(.top, Space.s)
                                Text(verbatim: account.wrappedValue.address.address)
                                    .font(TypeScale.label)
                                    .foregroundStyle(Ink.secondary)
                                    .padding(.top, 4)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, Space.l)
                            .padding(.bottom, Space.s)
                        }
                    }
                    // The page in parts, so no part is long: pick one here.
                    Section {
                    } footer: {
                        Picker("", selection: $tab) {
                            Text("General", tableName: "Settings").tag(Tab.general)
                            Text("Sending", tableName: "Settings").tag(Tab.sending)
                            Text("Signatures", tableName: "Settings").tag(Tab.signatures)
                            if case .imap = account.wrappedValue.connection { Text("Server", tableName: "Settings").tag(Tab.server) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 420)
                        .frame(maxWidth: .infinity)
                    }
                    if tab == .general {
                        Section {
                            TextField(String(localized: "Mailbox name", table: "Settings"), text: Binding(
                                get: { account.wrappedValue.label },
                                set: { account.wrappedValue.label = $0 }
                            ), prompt: Text(verbatim: account.wrappedValue.address.address))
                        } footer: {
                            Text("What Margin calls this mailbox, like Work or Personal. Only you see it.", tableName: "Settings")
                        }

                        Section {
                            HStack(spacing: Space.m) {
                                AccountMark(account.wrappedValue, size: 44)
                                    // Drop a picture on it to use it.
                                    .dropDestination(for: Data.self) { items, _ in
                                        guard let data = items.first else { return false }
                                        model.setPicture(data, for: accountID)
                                        account.wrappedValue.picture = model.account(accountID)?.picture
                                        return true
                                    }
                                    .help(Text("Drop a picture here, or choose one", tableName: "Settings"))
                                Button(String(localized: "Choose Picture…", table: "Settings")) { choosingPicture = true }
                                if account.wrappedValue.picture != nil {
                                    Button(String(localized: "Remove", table: "Settings"), role: .destructive) {
                                        model.setPicture(nil, for: accountID)
                                        account.wrappedValue.picture = nil
                                    }
                                }
                            }
                        } header: {
                            Text("Picture", tableName: "Settings")
                        }

                        Section {
                            Picker(String(localized: "Notify me about", table: "Settings"), selection: Binding(
                                get: { model.alerts(for: accountID) },
                                set: { model.setAlerts($0, for: accountID) }
                            )) {
                                Text("Same as other mailboxes", tableName: "Settings").tag(NewMailAlerts?.none)
                                ForEach(NewMailAlerts.allCases, id: \.self) { Text($0.title).tag(NewMailAlerts?.some($0)) }
                            }
                            Toggle(String(localized: "Show in All Inboxes", table: "Settings"), isOn: Binding(
                                get: { account.wrappedValue.inAllInboxes != false },
                                set: { account.wrappedValue.inAllInboxes = $0 ? nil : false }
                            ))
                        } header: {
                            Text("Notifications", tableName: "Settings")
                        }

                        // A shared mailbox's automatic reply is its owners' to set.
                        if account.wrappedValue.sharedMailbox == nil {
                            AutoReplySection(model: model, account: account.wrappedValue)
                        }

                        if model.canAddSharedMailbox(from: account.wrappedValue) {
                            SharedMailboxSection(model: model, account: account.wrappedValue)
                        }

                    }
                    if tab == .sending {
                        Section {
                            TextField(String(localized: "Sender name", table: "Settings"), text: Binding(
                                get: { account.wrappedValue.address.name ?? "" },
                                set: { account.wrappedValue.address.name = $0.isEmpty ? nil : $0 }
                            ))
                        } footer: {
                            Text("What people see as the sender, like “Alex from Northwind”. Every address in this mailbox uses it unless you give one its own name under Send as.", tableName: "Settings")
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
                                    ), prompt: senderName.map { Text(verbatim: $0) } ?? Text("Name", tableName: "Settings"))
                                    .labelsHidden()
                                    .multilineTextAlignment(.trailing)
                                    .textFieldStyle(.plain)
                                    .frame(maxWidth: 170)
                                    .accessibilityLabel(Text("Name for \(alias.address)", tableName: "Settings"))
                                    AliasSignatureButton(signature: Binding(
                                        get: { account.wrappedValue.aliasSignatures?[alias.address.lowercased()] ?? "" },
                                        set: { value in
                                            var all = account.wrappedValue.aliasSignatures ?? [:]
                                            all[alias.address.lowercased()] = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
                                            account.wrappedValue.aliasSignatures = all.isEmpty ? nil : all
                                        }
                                    ), choice: Binding(
                                        get: { account.wrappedValue.aliasSignatureNames?[alias.address.lowercased()] },
                                        set: { value in
                                            var all = account.wrappedValue.aliasSignatureNames ?? [:]
                                            all[alias.address.lowercased()] = value
                                            account.wrappedValue.aliasSignatureNames = all.isEmpty ? nil : all
                                        }
                                    ), names: account.wrappedValue.availableSignatures.map(\.name), address: alias.address)
                                    Button(role: .destructive) { account.wrappedValue.aliases?.remove(at: index) } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(String(localized: "Remove", table: "Settings"))
                                }
                            }
                            let known = Set(([account.wrappedValue.address] + (account.wrappedValue.aliases ?? [])).map { $0.address.lowercased() })
                            ForEach(suggestions.filter { !known.contains($0.address.lowercased()) }, id: \.address) { suggestion in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(verbatim: suggestion.address)
                                        Text("Mail sent to it arrives here", tableName: "Settings").font(TypeScale.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button(String(localized: "Add", table: "Settings")) { account.wrappedValue.aliases = (account.wrappedValue.aliases ?? []) + [suggestion] }
                                    Button {
                                        model.dismissAliasSuggestion(suggestion, for: account.wrappedValue)
                                        suggestions.removeAll { $0.address == suggestion.address }
                                    } label: {
                                        Image(systemName: "xmark")
                                    }
                                    .buttonStyle(.borderless)
                                    .tip(String(localized: "Not mine", table: "Settings"))
                                }
                            }
                            AliasAddRow(address: $newAliasAddress, name: $newAliasName) { addAlias(to: account) }
                        } header: {
                            Text("Send as", tableName: "Settings")
                        } footer: {
                            Text("Other addresses this mailbox can send from. Your provider has to allow them. Replies to mail sent to one go out from it. Leave a name empty to use the sender name.", tableName: "Settings")
                        }
                        .task(id: accountID) {
                            if let current = model.account(accountID) { suggestions = await model.aliasSuggestions(for: current) }
                        }

                    }
                    if tab == .signatures {
                        Section {
                            ForEach([account.wrappedValue.defaultSignature ?? NamedSignature(name: NamedSignature.defaultName, text: "")]
                                    + (account.wrappedValue.moreSignatures ?? [])) { signature in
                                SignatureRow(signature: signature) {
                                    editing = SignatureEditing(original: signature.name, signature: signature)
                                } remove: {
                                    remove(signature, from: account)
                                }
                            }
                            Button(String(localized: "Add a Signature…", table: "Settings")) {
                                editing = SignatureEditing(original: nil, signature: account.wrappedValue.newSignature())
                            }
                            Picker(String(localized: "For replies and forwards", table: "Settings"), selection: Binding(
                                get: { account.wrappedValue.replySignature ?? NamedSignature.defaultName },
                                set: { account.wrappedValue.replySignature = $0 == NamedSignature.defaultName ? nil : $0 }
                            )) {
                                Text("Default", tableName: "Settings").tag(NamedSignature.defaultName)
                                ForEach(account.wrappedValue.moreSignatures ?? []) { Text(verbatim: $0.name).tag($0.name) }
                                Text("None", tableName: "Settings").tag("")
                            }
                        } header: {
                            Text("Signatures", tableName: "Settings")
                        } footer: {
                            Text("Signatures can have formatting, links and pictures, and go out the way you see them. Pick another one while writing from the signature menu.", tableName: "Settings")
                        }

                        Section {
                            HStack {
                                Button(String(localized: "Make One for Me…", table: "Settings")) {
                                    details.name = account.wrappedValue.address.displayName
                                    makingSignature = true
                                }
                                Button(findingSignature ? "Looking…" : "Find in Sent Mail") {
                                    findingSignature = true
                                    Task {
                                        if let found = await model.findSignatureInSentMail(accountID) {
                                            account.wrappedValue.setSignature(NamedSignature(name: NamedSignature.defaultName, text: found))
                                            signatureNote = String(localized: "Found it in your sent mail.", table: "Settings")
                                        } else {
                                            signatureNote = String(localized: "No signature showed up in enough sent messages.", table: "Settings")
                                        }
                                        findingSignature = false
                                    }
                                }
                                .disabled(findingSignature)
                            }
                            Text(verbatim: signatureNote ?? " ").font(TypeScale.label).foregroundStyle(Ink.tertiary)
                        } header: {
                            Text("Signature tools", tableName: "Settings")
                        } footer: {
                            Text("Both fill in the default signature, to change as you like.", tableName: "Settings")
                        }
                    }
                    if tab == .server {
                        if case .imap = account.wrappedValue.connection {
                            Section {
                                TextField(String(localized: "Incoming server (IMAP)", table: "Settings"), text: $server.incomingHost)
                                TextField(String(localized: "Port", table: "Settings"), value: $server.incomingPort, format: .number.grouping(.never))
                                TextField(String(localized: "Outgoing server (SMTP)", table: "Settings"), text: $server.outgoingHost)
                                TextField(String(localized: "Port", table: "Settings"), value: $server.outgoingPort, format: .number.grouping(.never))
                                if case .password = account.wrappedValue.auth {
                                    TextField(String(localized: "Username", table: "Settings"), text: $server.username)
                                    SecureField(String(localized: "New password (leave empty to keep)", table: "Settings"), text: $server.password)
                                }
                                HStack {
                                    Text(verbatim: serverStatus ?? " ").font(TypeScale.label).foregroundStyle(Ink.tertiary)
                                    Spacer()
                                    Button(checking ? "Checking…" : "Check and Save") { checkServer(account.wrappedValue) }.disabled(checking)
                                }
                            } header: {
                                Text("Server and sign-in", tableName: "Settings")
                            } footer: {
                                Text("Margin tries the new settings first. If they don't work, nothing changes.", tableName: "Settings")
                            }
                        }

                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Text(verbatim: account?.label ?? ""))
            .toolbar {
                if !isEmbedded {
                    ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel", table: "Settings")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Save", table: "Settings")) { save(); dismiss() } }
                }
            }
            // In the Settings window: Revert and Save under the page, always there, lit once
            // something changed.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isEmbedded {
                    let changed = account != model.account(accountID)
                    HStack(spacing: Space.s) {
                        Text("Changes to this mailbox are kept when you save.", tableName: "Settings")
                            .font(TypeScale.caption).foregroundStyle(Ink.tertiary)
                        Spacer()
                        Button(String(localized: "Revert", table: "Settings")) { account = model.account(accountID) }.disabled(!changed)
                        Button(String(localized: "Save", table: "Settings")) { save() }.buttonStyle(.borderedProminent).disabled(!changed)
                            .keyboardShortcut("s", modifiers: .command)
                    }
                    .padding(.horizontal, Space.xl)
                    .padding(.vertical, Space.m)
                    .background(Paper.ground)
                    .overlay(alignment: .top) { Rectangle().fill(Line.hairline).frame(height: 1) }
                }
            }
        }
        .tint(Ink.primary)
        #if os(macOS)
        .frame(width: isEmbedded ? nil : 520, height: isEmbedded ? nil : 620)
        #endif
        .onAppear {
            account = model.account(accountID)
            if let account { server = MailboxServerFields(account) }
        }
        .sheet(isPresented: $makingSignature) { makeSignatureSheet }
        .sheet(item: $editing) { item in
            SignatureSheet(original: item.signature, isDefault: item.original == NamedSignature.defaultName,
                           takenNames: Set((account?.allSignatures ?? []).map(\.name)).subtracting([item.original ?? ""])) { saved in
                save(saved, replacing: item.original)
            }
        }
        .fileImporter(isPresented: $choosingPicture, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            model.setPicture(data, for: accountID)
            account?.picture = model.account(accountID)?.picture
        }
    }

    private func save() {
        guard var account else { return }
        account.moreSignatures = account.moreSignatures?.filter { !$0.name.isEmpty }
        model.update(account)
        if isEmbedded { self.account = model.account(accountID) }
    }

    private func save(_ saved: NamedSignature, replacing original: String?) {
        account?.saveSignature(saved, replacing: original)
    }

    private func remove(_ signature: NamedSignature, from account: Binding<MailAccount>) {
        account.wrappedValue.removeSignature(named: signature.name)
    }

    private var makeSignatureSheet: some View {
        NavigationStack {
            Form {
                TextField(String(localized: "Name", table: "Settings"), text: $details.name)
                TextField(String(localized: "Role", table: "Settings"), text: $details.role)
                TextField(String(localized: "Company", table: "Settings"), text: $details.company)
                TextField(String(localized: "Phone", table: "Settings"), text: $details.phone)
                TextField(String(localized: "Website", table: "Settings"), text: $details.website)
                Section(String(localized: "Preview", table: "Settings")) {
                    HTMLMessageView(html: HTMLSanitizer.sanitize(SignatureTools.make(details).html), allowsRemote: false).frame(minHeight: 60)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Make a signature", table: "Settings"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel", table: "Settings")) { makingSignature = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Use It", table: "Settings")) {
                        let made = SignatureTools.make(details)
                        #if canImport(AppKit)
                        let signature = SignatureText.fromHTML(made.html).map { SignatureText.signature(named: NamedSignature.defaultName, from: $0) }
                            ?? NamedSignature(name: NamedSignature.defaultName, text: made.text, html: made.html)
                        #else
                        let signature = NamedSignature(name: NamedSignature.defaultName, text: made.text, html: made.html)
                        #endif
                        account?.setSignature(signature)
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
                serverStatus = String(localized: "Connected and saved.", table: "Settings")
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
                Button(String(localized: "Add", table: "Settings"), action: add).disabled(!isValid)
            }
        }
        #else
        HStack {
            addressField
            nameField.frame(maxWidth: 170)
            Button(String(localized: "Add", table: "Settings"), action: add).disabled(!isValid)
        }
        #endif
    }

    private var addressField: some View {
        TextField("", text: $address, prompt: Text(verbatim: "sales@yourdomain.com"))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(Text("Email address", tableName: "Settings"))
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            #endif
            .onSubmit { if isValid { add() } }
    }

    private var nameField: some View {
        TextField("", text: $name, prompt: Text("Name (optional)", tableName: "Settings"))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(Text("Name (optional)", tableName: "Settings"))
            .onSubmit { if isValid { add() } }
    }
}

/// While writing: which signature goes at the end. Shown only when there's more than one.
struct SignatureMenu: View {
    let model: MailModel
    @Binding var state: ComposeState

    var body: some View {
        if let account = model.account(state.accountID), account.availableSignatures.count > 1 {
            Menu {
                ForEach(account.availableSignatures) { signature in
                    Button(signature.name == NamedSignature.defaultName ? String(localized: "Default", table: "Settings") : signature.name) {
                        state.useSignature(signature)
                    }
                }
                Divider()
                Button(String(localized: "No signature", table: "Settings")) { state.use(signature: nil) }
            } label: {
                Image(systemName: "signature")
                    .font(.system(size: Look.size(12.5)))
                    .foregroundStyle(Ink.tertiary)
                    .frame(width: 28, height: 28)
                    .accessibilityLabel(Text("Signature", tableName: "Settings"))
            }
            #if os(macOS)
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            #endif
            .tip(String(localized: "Signature", table: "Settings"))
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
