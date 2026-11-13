import AuthenticationServices
import MailCore
import SwiftUI

/// Signs in to a mailbox again when `account` is set: the provider's own sign-in page for
/// Google and Microsoft, a password prompt for the rest. Nothing else about the mailbox changes.
struct SignInAgain: ViewModifier {
    let model: MailModel
    @Binding var account: MailAccount?
    @Environment(\.webAuthenticationSession) private var webAuthentication
    @State private var asking: MailAccount?
    @State private var secret = ""
    @State private var isWorking = false
    /// What went wrong, shown in the window the button was pressed in (the app's own notices
    /// appear in the main window, which Settings covers).
    @State private var problem: String?
    /// Says so when it worked, for windows that don't show the app's notices (Settings).
    var confirms = false
    @State private var confirmed: MailAccount?

    func body(content: Content) -> some View {
        content
            .onChange(of: account?.id) { _, _ in
                guard let wanted = account else { return }
                account = nil
                guard !isWorking else { return }
                if model.signsInOnTheWeb(wanted) {
                    Task { await signInOnTheWeb(wanted) }
                } else {
                    secret = ""
                    asking = wanted
                }
            }
            .alert(Text("Sign in to \(asking?.address.address ?? "") again"),
                   isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }), presenting: asking) { account in
                SecureField(account.auth == .token ? String(localized: "Token") : String(localized: "Password"), text: $secret)
                Button("Cancel", role: .cancel) { secret = "" }
                Button("Sign In") {
                    let typed = secret
                    secret = ""
                    Task { await signIn(account, secret: typed) }
                }
            } message: { _ in
                Text("Your mail and settings stay as they are. If your provider uses app passwords, enter one of those.")
            }
            .alert(Text("Couldn't sign in"), isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(verbatim: problem ?? "")
            }
            .alert(Text("Signed in to \(confirmed?.label ?? "") again."),
                   isPresented: Binding(get: { confirmed != nil }, set: { if !$0 { confirmed = nil } })) {
                Button("OK", role: .cancel) {}
            }
    }

    private func signInOnTheWeb(_ account: MailAccount) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await model.signInAgain(account) { url, scheme in
                // A private sign-in with the mailbox's address filled in, so an account already
                // signed in to the browser can't be picked by mistake.
                try await webAuthentication.authenticate(using: url, callbackURLScheme: scheme, preferredBrowserSession: .ephemeral)
            }
            if confirms { confirmed = account }
        } catch let failure as ASWebAuthenticationSessionError where failure.code == .canceledLogin {
            return
        } catch {
            problem = error.localizedDescription
        }
    }

    private func signIn(_ account: MailAccount, secret: String) async {
        guard !secret.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await model.signInAgain(account, secret: secret)
            if confirms { confirmed = account }
        } catch {
            problem = error.localizedDescription
        }
    }
}

extension View {
    /// Setting `account` signs in to that mailbox again (see `SignInAgain`).
    func signsInAgain(model: MailModel, account: Binding<MailAccount?>, confirms: Bool = false) -> some View {
        modifier(SignInAgain(model: model, account: account, confirms: confirms))
    }
}

/// The line at the foot of the list ("Updated just now"). When a mailbox's sign-in was refused it
/// also carries the way out: Sign in again.
struct StatusLine: View {
    let model: MailModel
    var color: Color = Ink.tertiary
    @Environment(\.mailAccent) private var accent

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 6) {
                Text(model.statusLine(now: context.date))
                    .foregroundStyle(color)
                    .lineLimit(1)
                if let account = model.accountNeedingSignIn {
                    Button("Sign in again") { model.signingInAgain = account }
                        .buttonStyle(.plain)
                        .foregroundStyle(accent)
                        .fixedSize()
                        .tip(Text(verbatim: account.address.address))
                }
            }
            .font(TypeScale.caption)
        }
    }
}
