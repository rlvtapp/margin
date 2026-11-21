import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct AccountErrorTests {
    /// With more than one mailbox, an error from one of them says which.
    @Test func aRefusedSignInNamesItsMailbox() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let account = try #require(model.accounts.first)
        try #require(model.accounts.count > 1)
        model.show(MailError.authenticationFailed("Sign in again."), account: account.id)
        let text = try #require(model.notice?.text)
        #expect(text.hasPrefix(account.label.isEmpty ? account.address.address : account.label))
        #expect(text.contains("Sign in again."))
    }
}
