import Foundation
import MailCore
import Testing
@testable import MailUI

/// Signing in again replaces only the saved sign-in: the mailbox and everything in it stays.
@MainActor @Suite struct SignInAgainTests {
    private struct Refused: Error {}

    private func setUp(auth: AuthMethod = .password(username: "me@example.com")) throws -> (MailModel, MailEnvironment, MailAccount) {
        let environment = MailEnvironment.preview()
        let account = MailAccount(label: "Work", address: EmailAddress(address: "me@example.com"),
                                  connection: .imap(incoming: ServerEndpoint(host: "imap.example.com", port: 993, security: .tls),
                                                    outgoing: ServerEndpoint(host: "smtp.example.com", port: 465, security: .tls)),
                                  auth: auth)
        try environment.accounts.save([account])
        let kind = if case .oauth = auth { "oauth" } else { "password" }
        try environment.keychain.save("old", account: account.id, kind: kind)
        let model = MailModel(environment: environment)
        model.loadErrors[account.id] = "Sign-in was refused."
        model.signInRefused.insert(account.id)
        return (model, environment, account)
    }

    @Test func aRefusedSignInIsOfferedAgain() throws {
        let (model, _, account) = try setUp()
        #expect(model.needsSignIn(account.id))
        #expect(model.accountNeedingSignIn?.id == account.id)
        #expect(!model.signsInOnTheWeb(account))
    }

    @Test func aNetworkFailureIsNotASignInProblem() {
        #expect(!MailModel.isSignInRefusal(URLError(.notConnectedToInternet)))
        #expect(!MailModel.isSignInRefusal(MailError.timedOut))
        #expect(MailModel.isSignInRefusal(MailError.authenticationFailed("AADSTS70000")))
        #expect(MailModel.isSignInRefusal(MailError.missingCredentials))
    }

    @Test func aNewPasswordThatWorksIsKeptAndTheMailboxStays() async throws {
        let (model, environment, account) = try setUp()
        try await model.useSignIn("new", for: account) { _ in }
        #expect(environment.keychain.read(account: account.id, kind: "password") == "new")
        #expect(model.accounts.map(\.id) == [account.id])
        #expect(environment.accounts.load().map(\.id) == [account.id])
        #expect(!model.signInRefused.contains(account.id))
        #expect(model.accountNeedingSignIn == nil)
    }

    @Test func aPasswordThatDoesntWorkPutsTheOldOneBack() async throws {
        let (model, environment, account) = try setUp()
        await #expect(throws: Refused.self) {
            try await model.useSignIn("wrong", for: account) { _ in throw Refused() }
        }
        #expect(environment.keychain.read(account: account.id, kind: "password") == "old")
        #expect(model.needsSignIn(account.id))
        #expect(model.accounts.map(\.id) == [account.id])
    }

    @Test func aNewProviderSignInIsKeptWhenTheServerJustCouldntBeReached() async throws {
        let (model, environment, account) = try setUp(auth: .oauth(provider: .microsoft, username: "me@example.com"))
        #expect(model.signsInOnTheWeb(account))
        await #expect(throws: MailError.self) {
            try await model.useSignIn("fresh tokens", for: account) { _ in throw MailError.timedOut }
        }
        // The new sign-in is good and the old one is spent; going back would help no one.
        #expect(environment.keychain.read(account: account.id, kind: "oauth") == "fresh tokens")
    }

    /// Another account was chosen on the provider's page: the mail server refuses it for this
    /// mailbox, the old sign-in is put back, and the message says who signed in.
    @Test func signingInAsSomeoneElseKeepsNothingAndSaysWho() async throws {
        let (model, environment, account) = try setUp(auth: .oauth(provider: .microsoft, username: "me@example.com"))
        do {
            try await model.useSignIn("someone else's tokens", for: account, signedInAs: "other@example.com") { _ in
                throw MailError.authenticationFailed("AUTHENTICATE failed.")
            }
            Issue.record("A refused sign-in should fail.")
        } catch {
            #expect(error.localizedDescription.contains("other@example.com"))
        }
        #expect(environment.keychain.read(account: account.id, kind: "oauth") == "old")
    }

    /// A provider often signs people in under a name that isn't the mailbox's address (an alias,
    /// a work sign-in name on another domain). When the mail server takes the sign-in for this
    /// mailbox, that's the proof, and it's kept.
    @Test func aSignInNameThatDiffersFromTheAddressIsFine() async throws {
        let (model, environment, account) = try setUp(auth: .oauth(provider: .microsoft, username: "me@example.com"))
        try await model.useSignIn("fresh tokens", for: account, signedInAs: "me@company.onmicrosoft.example") { _ in }
        #expect(environment.keychain.read(account: account.id, kind: "oauth") == "fresh tokens")
        #expect(!model.needsSignIn(account.id))
    }

    @Test func sampleMailboxesHaveNothingToSignInTo() {
        let model = MailModel(environment: .preview())
        #expect(model.accounts.allSatisfy { !model.canSignInAgain($0) })
        #expect(model.accountNeedingSignIn == nil)
    }
}
