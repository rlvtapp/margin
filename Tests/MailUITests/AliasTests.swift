import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct AliasTests {
    func environment() -> MailEnvironment {
        let folder = FileManager.default.temporaryDirectory.appending(path: "margin-alias-\(UUID().uuidString)", directoryHint: .isDirectory)
        return MailEnvironment(appName: "Margin", accounts: AccountStore(fileURL: folder.appending(path: "accounts.json")),
                               keychain: Keychain(service: "margin.alias-test"), oauth: OAuthClientRegistry(googleClientID: nil, microsoftClientID: nil),
                               labels: LabelStore(fileURL: folder.appending(path: "labels.json")),
                               defaults: UserDefaults(suiteName: "margin.alias.\(UUID().uuidString)")!, folder: folder)
    }

    /// The provider's aliases are added once: one you remove doesn't come back.
    @Test func providerAliasesAreAddedOnce() throws {
        let env = environment()
        let me = EmailAddress(name: "Kaan", address: "kaan@example.com")
        let account = MailAccount(label: "Work", address: me,
                                  connection: .imap(incoming: ServerEndpoint(host: "imap.example.com", port: 993, security: .tls),
                                                    outgoing: ServerEndpoint(host: "smtp.example.com", port: 465, security: .tls)),
                                  auth: .password(username: me.address))
        try env.accounts.save([account])
        let model = MailModel(environment: env)
        model.addAliases([EmailAddress(address: "hello@example.com")], to: account)
        #expect(model.accounts[0].aliases?.map(\.address) == ["hello@example.com"])
        #expect(env.accounts.load()[0].aliases?.map(\.address) == ["hello@example.com"])

        model.accounts[0].aliases = []
        model.addAliases([EmailAddress(address: "hello@example.com")], to: account)
        #expect(model.accounts[0].aliases?.isEmpty == true)
    }

    /// Aliases guessed from Sent mail before are taken out once; ones added by hand stay.
    @Test func guessedAliasesAreRemovedOnce() throws {
        let env = environment()
        let me = EmailAddress(name: "Kaan", address: "kaan@example.com")
        var account = MailAccount(label: "Work", address: me,
                                  connection: .imap(incoming: ServerEndpoint(host: "imap.example.com", port: 993, security: .tls),
                                                    outgoing: ServerEndpoint(host: "smtp.example.com", port: 465, security: .tls)),
                                  auth: .password(username: me.address))
        account.aliases = [EmailAddress(address: "guessed@example.com"), EmailAddress(address: "mine@example.com")]
        try env.accounts.save([account])
        env.defaults.set(["guessed@example.com"], forKey: "aliasesOffered.\(account.id.uuidString)")
        let model = MailModel(environment: env)
        model.pruneLearnedAliases()
        #expect(model.accounts[0].aliases?.map(\.address) == ["mine@example.com"])
    }

    /// Notices and robots never count as somewhere you send from.
    @Test func automatedAddressesAreNotAliases() {
        for robot in ["drive-shares-dm-noreply@google.com", "c_lafes83@group.calendar.google.com", "calendar-noreply@google.com",
                      "postmaster@relevate.app", "no-reply@example.com"] {
            #expect(MailModel.isAutomated(robot), "\(robot)")
        }
        for person in ["kaan@goud-it.nl", "kaantjuhh@hotmail.com", "kaan.mol@outlook.com"] {
            #expect(!MailModel.isAutomated(person), "\(person)")
        }
    }

    /// Personal mail sent to another address that lands in this mailbox, twice: suggested.
    /// Newsletters, robots and one-offs aren't.
    @Test func suggestsAddressesMailArrivesFor() async throws {
        let env = environment()
        let me = EmailAddress(address: "kaan@outlook.example")
        let account = MailAccount(label: "Outlook", address: me,
                                  connection: .imap(incoming: ServerEndpoint(host: "imap.example.com", port: 993, security: .tls),
                                                    outgoing: ServerEndpoint(host: "smtp.example.com", port: 465, security: .tls)),
                                  auth: .password(username: me.address))
        try env.accounts.save([account])
        let model = MailModel(environment: env)
        model.mailboxes[account.id] = [Mailbox(id: "INBOX", name: "Inbox", role: .inbox)]
        let alias = EmailAddress(address: "old@hotmail.example")
        let friend = EmailAddress(name: "Noor", address: "noor@friends.example")
        let messages = [
            MailMessage(id: "1", mailboxID: "INBOX", messageID: "1@x", from: friend, to: [alias], subject: "Hi", date: Date()),
            MailMessage(id: "2", mailboxID: "INBOX", messageID: "2@x", from: friend, to: [alias], subject: "Again", date: Date()),
            MailMessage(id: "3", mailboxID: "INBOX", messageID: "3@x", from: friend, to: [me], subject: "Direct", date: Date()),
            MailMessage(id: "4", mailboxID: "INBOX", messageID: "4@x", from: EmailAddress(address: "news@shop.example"),
                        to: [EmailAddress(address: "list@shop.example")], subject: "Sale", date: Date(),
                        listHeaders: ["List-Unsubscribe": "<mailto:x>"]),
            MailMessage(id: "5", mailboxID: "INBOX", messageID: "5@x", from: friend, to: [EmailAddress(address: "once@other.example")], subject: "One", date: Date()),
        ]
        await env.cache.saveThreads(messages.map { MailThread(id: $0.id, messages: [$0]) }, account: account.id, mailbox: "INBOX")
        let suggested = await model.aliasSuggestions(for: account)
        #expect(suggested.map(\.address) == ["old@hotmail.example"])
        model.dismissAliasSuggestion(alias, for: account)
        #expect(await model.aliasSuggestions(for: account).isEmpty)
    }

    /// An empty sender name takes the one Sent mail goes out under; a typed one stays.
    @Test func senderNameComesFromSentMail() throws {
        let env = environment()
        let me = EmailAddress(address: "kaan@example.com")
        let account = MailAccount(label: "Work", address: me,
                                  connection: .imap(incoming: ServerEndpoint(host: "imap.example.com", port: 993, security: .tls),
                                                    outgoing: ServerEndpoint(host: "smtp.example.com", port: 465, security: .tls)),
                                  auth: .password(username: me.address))
        try env.accounts.save([account])
        let model = MailModel(environment: env)
        let sent = ["1", "2"].map {
            MailMessage(id: $0, mailboxID: "Sent", messageID: "\($0)@x", from: EmailAddress(name: "Kaan Mol", address: "kaan@example.com"),
                        to: [], subject: "S", date: Date())
        }
        model.learnSenderName(from: sent, account: account)
        #expect(model.accounts[0].address.name == "Kaan Mol")
        model.accounts[0].address.name = "Kaan"
        model.learnSenderName(from: sent, account: model.accounts[0])
        #expect(model.accounts[0].address.name == "Kaan")
    }

    /// Provider and company names aren't people's names; real ones are.
    @Test func placeholderNames() {
        #expect(MailModel.isPlaceholderName("Gmail", for: "kaantjehh@gmail.com"))
        #expect(MailModel.isPlaceholderName("iCloud", for: "kaanmol@icloud.com"))
        #expect(MailModel.isPlaceholderName("Relevate", for: "kaan@relevate.app"))
        #expect(MailModel.isPlaceholderName(nil, for: "kaan@relevate.app"))
        #expect(!MailModel.isPlaceholderName("Kaan", for: "kaanmol@outlook.com"))
        #expect(!MailModel.isPlaceholderName("Kaan Mollaoglu", for: "kaan@relevate.app"))
    }

    /// Mail from an alias without a name goes out under the mailbox's name, never a placeholder.
    @Test func aliasesSendWithTheMailboxName() throws {
        let env = environment()
        var account = MailAccount(label: "Outlook", address: EmailAddress(name: "Kaan", address: "kaanmol@outlook.example"),
                                  connection: .imap(incoming: ServerEndpoint(host: "imap.example.com", port: 993, security: .tls),
                                                    outgoing: ServerEndpoint(host: "smtp.example.com", port: 465, security: .tls)),
                                  auth: .password(username: "kaanmol@outlook.example"))
        try env.accounts.save([account])
        let model = MailModel(environment: env)
        let draft = Draft(from: EmailAddress(address: "kaantjuhh@outlook.example"), to: [], subject: "Hi", text: "Hi")
        #expect(model.withSenderName(draft, account: account).from.name == "Kaan")
        let named = Draft(from: EmailAddress(name: "Sales", address: "sales@outlook.example"), to: [], subject: "Hi", text: "Hi")
        #expect(model.withSenderName(named, account: account).from.name == "Sales")
        account.address.name = "iCloud"
        try env.accounts.save([account])
        let other = MailModel(environment: env)
        #expect(other.withSenderName(draft, account: account).from.name == nil)
    }
}
