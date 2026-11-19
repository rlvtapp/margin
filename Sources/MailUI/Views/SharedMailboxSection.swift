import AuthenticationServices
import MailCore
import SwiftUI

/// In a Microsoft mailbox's settings: the shared mailboxes opened with its sign-in, and a field
/// to add another by its address.
struct SharedMailboxSection: View {
    let model: MailModel
    let account: MailAccount
    @Environment(\.webAuthenticationSession) private var webAuthentication
    @State private var address = ""
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        Section {
            ForEach(model.sharedMailboxes(of: account)) { shared in
                HStack(spacing: Space.s) {
                    AccountMark(shared, size: 22)
                    Text(verbatim: shared.address.address)
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: Space.s) {
                TextField("Email address", text: $address, prompt: Text(verbatim: "team@example.com"))
                    .onSubmit { Task { await add() } }
                if working {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Add") { Task { await add() } }
                        .disabled(!EmailAddress.isValid(address.trimmingCharacters(in: .whitespaces)))
                }
            }
        } header: {
            Text("Shared mailboxes")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Mailboxes your organization lets you open, like a team address. Each shows as a mailbox of its own. You'll be asked to sign in once more.")
                if let problem { Text(verbatim: problem).foregroundStyle(Status.danger) }
            }
        }
    }

    private func add() async {
        let typed = address.trimmingCharacters(in: .whitespaces)
        guard EmailAddress.isValid(typed), !working else { return }
        working = true
        problem = nil
        defer { working = false }
        do {
            try await model.addSharedMailbox(typed, from: account) { url, scheme in
                try await webAuthentication.authenticate(using: url, callbackURLScheme: scheme, preferredBrowserSession: .ephemeral)
            }
            address = ""
        } catch let failure as ASWebAuthenticationSessionError where failure.code == .canceledLogin {
            return
        } catch {
            problem = error.localizedDescription
        }
    }
}
