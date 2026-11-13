import Foundation
import MailCore
import Testing
@testable import MailUI

/// At launch the open conversation shows its saved text at once, without any server.
@MainActor @Suite struct LaunchTests {
    @Test func theOpenMailShowsFromThisDeviceBeforeAnyServerAnswers() async throws {
        let environment = MailEnvironment.preview()
        // A mailbox whose server can't be reached at all.
        let account = MailAccount(label: "Work", address: EmailAddress(address: "me@example.com"),
                                  connection: .imap(incoming: ServerEndpoint(host: "127.0.0.1", port: 1, security: .plain),
                                                    outgoing: ServerEndpoint(host: "127.0.0.1", port: 1, security: .plain)),
                                  auth: .password(username: "me@example.com"))
        try environment.accounts.save([account])
        let message = MailMessage(id: "INBOX/7", mailboxID: "INBOX", from: EmailAddress(name: "Store", address: "orders@shop.example"),
                                  to: [account.address], subject: "Your order", date: Date())
        await environment.cache.saveMailboxes([Mailbox(id: "INBOX", name: "Inbox", role: .inbox)], account: account.id)
        await environment.cache.saveThreads([MailThread(id: "INBOX/7", messages: [message])], account: account.id, mailbox: "INBOX")
        await environment.cache.saveBody(MessageBody(text: "Thanks for your order."), of: message, account: account.id)

        let model = MailModel(environment: environment)
        await model.loadSavedMail()
        let thread = try #require(model.selectedThread)
        #expect(model.body(of: thread.latest, in: thread) == nil)

        // What `start()` now does straight after reading saved mail, before the sync and the servers.
        await model.loadBodies()
        #expect(model.body(of: thread.latest, in: thread)?.text == "Thanks for your order.")
    }
}
