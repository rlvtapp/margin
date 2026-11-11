import AuthenticationServices
import MailCore
import SwiftUI

/// Settings → Contacts: the Contacts app, Microsoft and Google accounts, and CardDAV address books.
struct ContactsSettings: View {
    @Bindable var model: MailModel
    @Environment(\.webAuthenticationSession) private var webAuthentication
    @State private var addingBook = false
    @State private var problem: String?

    private var oauthAccounts: [MailAccount] { model.accounts.filter { model.oauthProvider(of: $0) != nil } }

    var body: some View {
        Form {
            SettingsHeader(.contacts)
            Section {
                Toggle(isOn: Binding(get: { model.usesSystemContacts }, set: { model.usesSystemContacts = $0 })) {
                    #if os(macOS)
                    SettingLabel("Contacts on this Mac", detail: "Includes iCloud, Google and Exchange accounts added in System Settings.")
                    #else
                    SettingLabel("Contacts on this device", detail: "Includes iCloud, Google and Exchange accounts added in Settings.")
                    #endif
                }
                if let issue = model.contactProblems["system"] {
                    Text(verbatim: issue).font(.caption).foregroundStyle(Status.danger)
                } else if model.usesSystemContacts {
                    count(model.contactCount(.system))
                }
            }
            if !oauthAccounts.isEmpty {
                Section {
                    ForEach(oauthAccounts) { account in accountRow(account) }
                } header: {
                    Text("Accounts")
                } footer: {
                    Text("Connecting an account also sends meetings from New Meeting through its calendar, with rooms. Microsoft 365 adds the people you work with.")
                }
            }
            Section {
                ForEach(model.cardDAVBooks) { book in
                    LabeledContent {
                        Button("Remove") { model.removeCardDAVBook(book.id) }.buttonStyle(.borderless)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: book.username)
                            Text(verbatim: model.contactProblems["carddav.\(book.id.uuidString)"] ?? book.server)
                                .font(.caption)
                                .foregroundStyle(model.contactProblems["carddav.\(book.id.uuidString)"] == nil ? Color.secondary : Status.danger)
                        }
                    }
                }
                Button("Add Address Book…") { addingBook = true }
            } header: {
                Text("CardDAV")
            } footer: {
                Text("For Fastmail, iCloud, Nextcloud and other servers. Use an app password where the provider offers one.")
            }
            Section {
                LabeledContent {
                    Button(model.isRefreshingContacts ? "Refreshing…" : "Refresh Now") { Task { await model.refreshContacts() } }
                        .disabled(model.isRefreshingContacts)
                } label: {
                    Text("\(model.contacts.count) contacts")
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Contacts stay on this device and are only used to suggest people while you write.")
                    if let problem { Text(verbatim: problem).foregroundStyle(Status.danger) }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $addingBook) { CardDAVSetup(model: model) }
    }

    private func count(_ number: Int) -> some View {
        Text("\(number) contacts").font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func accountRow(_ account: MailAccount) -> some View {
        let connected = model.apiAccess[account.id]?.contains(.contacts) == true
        let issue = model.contactProblems["account.\(account.id.uuidString)"]
        LabeledContent {
            if connected {
                Button("Disconnect") { model.removeAccess(for: account) }.buttonStyle(.borderless)
            } else if model.canAskForAccess(account) {
                Button("Connect…") { Task { await connect(account) } }
            } else {
                Text("Not available in this build").foregroundStyle(.tertiary)
            }
        } label: {
            HStack(spacing: Space.s) {
                AccountMark(account, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: account.address.address)
                    if let issue {
                        Text(verbatim: issue).font(.caption).foregroundStyle(Status.danger)
                    } else if connected {
                        let source: ContactSource = model.oauthProvider(of: account) == .google ? .google : .microsoft
                        count(model.contacts.filter { $0.source == source }.count)
                    }
                }
            }
        }
    }

    private func connect(_ account: MailAccount) async {
        // Contacts and the calendar together, so meetings work too. Rooms are asked for
        // separately, since some organizations need an admin for them.
        let wanted: Set<APIAccess> = [.contacts, .calendar]
        do {
            try await model.requestAccess(wanted, for: account) { url, scheme in
                // A private sign-in with the mailbox's address filled in, so an account already signed in
                // to the browser can't be picked by mistake.
                try await webAuthentication.authenticate(using: url, callbackURLScheme: scheme, preferredBrowserSession: .ephemeral)
            }
            problem = nil
        } catch let failure as ASWebAuthenticationSessionError where failure.code == .canceledLogin {
            return
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// Adding a CardDAV address book: server, username and password, checked before it's kept.
private struct CardDAVSetup: View {
    let model: MailModel
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var checking = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server", text: $server, prompt: Text(verbatim: "carddav.fastmail.com"))
                        .autocorrectionDisabled()
                    TextField("Username", text: $username, prompt: Text("Usually your email address"))
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password, prompt: Text("App password"))
                } footer: {
                    if let problem { Text(verbatim: problem).foregroundStyle(Status.danger) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Address Book")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(checking ? "Checking…" : "Add") { Task { await add() } }
                        .disabled(checking || server.isEmpty || username.isEmpty || password.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 260)
        #endif
    }

    private func add() async {
        checking = true
        defer { checking = false }
        do {
            try await model.addCardDAVBook(server: server.trimmingCharacters(in: .whitespaces),
                                           username: username.trimmingCharacters(in: .whitespaces), password: password)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}
