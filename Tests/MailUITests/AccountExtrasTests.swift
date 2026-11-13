import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct AccountExtrasTests {
    func account() -> MailAccount {
        let me = EmailAddress(name: "Kaan", address: "kaan@example.com")
        var account = MailAccount(label: "Work", address: me,
                                  connection: .imap(incoming: ServerEndpoint(host: "imap.example.com", port: 993, security: .tls),
                                                    outgoing: ServerEndpoint(host: "smtp.example.com", port: 465, security: .tls)),
                                  auth: .password(username: me.address))
        account.signature = "Kaan"
        account.aliases = [EmailAddress(address: "sales@example.com"), EmailAddress(address: "help@example.com")]
        account.aliasSignatures = ["sales@example.com": "The sales team"]
        return account
    }

    @Test func aSendAsAddressBringsItsOwnSignature() {
        let account = account()
        #expect(account.signature(sendingAs: EmailAddress(address: "SALES@example.com"), forReply: false) == "The sales team")
        #expect(account.signature(sendingAs: EmailAddress(address: "help@example.com"), forReply: false) == "Kaan")

        var state = ComposeState(account: account)
        #expect(state.draft.text.hasSuffix("Kaan"))
        state.draft.text = "Hello" + state.draft.text
        state.send(from: account, previous: account, as: EmailAddress(address: "sales@example.com"))
        #expect(state.draft.text == "Hello\n\nThe sales team")
        state.send(from: account, previous: account, as: EmailAddress(address: "help@example.com"))
        #expect(state.draft.text == "Hello\n\nKaan")

        // A reply that starts from the alias starts with its signature.
        let reply = ComposeState(account: account, draft: Draft(from: EmailAddress(address: "sales@example.com")), isReply: true)
        #expect(reply.draft.text.hasSuffix("The sales team"))
    }

    @Test func oldSavedAccountsStillLoad() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(account())) as! [String: Any]
        json["aliasSignatures"] = nil
        let decoded = try JSONDecoder().decode(MailAccount.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.aliasSignatures == nil && decoded.label == "Work")
    }
}
