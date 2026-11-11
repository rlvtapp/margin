import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct SampleAccountTests {
    /// With a real mailbox saved, the sample ones left over from before it don't come back.
    @Test func sampleMailboxesGoOnceThereIsARealOne() throws {
        let environment = MailEnvironment.preview()
        let real = MailAccount(label: "Work", address: EmailAddress(address: "me@example.com"),
                               connection: .imap(incoming: ServerEndpoint(host: "imap.example.com", port: 993, security: .tls),
                                                 outgoing: ServerEndpoint(host: "smtp.example.com", port: 465, security: .tls)),
                               auth: .password(username: "me@example.com"))
        try environment.accounts.save([.sample, .samplePersonal, real])
        let model = MailModel(environment: environment)
        #expect(model.accounts.map(\.id) == [real.id])
        #expect(environment.accounts.load().map(\.id) == [real.id])
    }

    /// Before any real mailbox, the samples show, so the app isn't empty.
    @Test func samplesShowBeforeSigningIn() {
        let model = MailModel(environment: .preview())
        #expect(model.accounts.allSatisfy { $0.connection == .sample })
        #expect(!model.accounts.isEmpty)
    }
}

@MainActor @Suite struct AccountOrderTests {
    /// Mailboxes can be put in any order, and it's kept.
    @Test func mailboxesCanBeReordered() throws {
        let environment = MailEnvironment.preview()
        func account(_ name: String) -> MailAccount {
            MailAccount(label: name, address: EmailAddress(address: "\(name)@example.com"),
                        connection: .imap(incoming: ServerEndpoint(host: "imap.example.com", port: 993, security: .tls),
                                          outgoing: ServerEndpoint(host: "smtp.example.com", port: 465, security: .tls)),
                        auth: .password(username: name))
        }
        let a = account("a"), b = account("b"), c = account("c")
        try environment.accounts.save([a, b, c])
        let model = MailModel(environment: environment)
        model.moveAccount(c.id, to: a.id)
        #expect(model.accounts.map(\.label) == ["c", "a", "b"])
        model.moveAccount(c.id, by: 1)
        #expect(model.accounts.map(\.label) == ["a", "c", "b"])
        #expect(!model.canMoveAccount(a.id, by: -1))
        #expect(environment.accounts.load().map(\.label) == ["a", "c", "b"])

        // A drag in a column showing only some of them keeps the others where they are.
        model.setAccountOrder([b.id, a.id])
        #expect(model.accounts.map(\.label) == ["b", "c", "a"])
    }
}
