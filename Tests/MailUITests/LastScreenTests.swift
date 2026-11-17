import Foundation
import MailCore
import Testing
@testable import MailUI

/// Margin opens on the screen it was closed on: folders, inbox and the open mail with its text
/// are there when the model is made, before saved mail or any server is read.
private actor QuietProvider: MailProvider {
    func mailboxes() async throws -> [Mailbox] { [] }
    func threads(in mailbox: Mailbox, limit: Int) async throws -> [MailThread] { [] }
    func body(of message: MailMessage) async throws -> MessageBody { MessageBody(text: "") }
    func perform(_ action: MailAction, on threads: [MailThread]) async throws {}
    func send(_ draft: Draft) async throws {}
    func saveDraft(_ draft: Draft) async throws {}
    func attachmentData(_ attachment: AttachmentInfo, of message: MailMessage) async throws -> Data { Data() }
    func disconnect() async {}
}

@MainActor @Suite struct LastScreenTests {
    func environment(_ folder: URL) -> MailEnvironment {
        MailEnvironment(appName: "Margin", accounts: AccountStore(fileURL: folder.appending(path: "accounts.json")),
                        keychain: Keychain(service: "margin.last-screen-test"), oauth: OAuthClientRegistry(googleClientID: nil, microsoftClientID: nil),
                        labels: LabelStore(fileURL: folder.appending(path: "labels.json")),
                        defaults: UserDefaults(suiteName: "margin.last-screen.\(UUID().uuidString)")!, folder: folder)
    }

    func account(_ address: String) -> MailAccount {
        MailAccount(label: address, address: EmailAddress(address: address),
                    connection: .imap(incoming: ServerEndpoint(host: "imap.example.com", port: 993, security: .tls),
                                      outgoing: ServerEndpoint(host: "smtp.example.com", port: 465, security: .tls)),
                    auth: .password(username: address))
    }

    @Test func theNextLaunchOpensOnTheLastScreen() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "margin-last-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let me = account("me@example.com")
        try environment(folder).accounts.save([me])

        let before = MailModel(environment: environment(folder))
        let folders = [Mailbox(id: "INBOX", name: "Inbox", role: .inbox), Mailbox(id: "Sent", name: "Sent", role: .sent),
                       Mailbox(id: "Trash", name: "Trash", role: .trash)]
        before.mailboxes[me.id] = folders
        var mail = MailMessage(id: "INBOX/7", mailboxID: "INBOX", messageID: "<seven@example.com>",
                               from: EmailAddress(address: "sam@example.com"), subject: "Plans", date: Date(timeIntervalSince1970: 100))
        mail.snippet = "Shall we?"
        var reply = MailMessage(id: "Sent/3", mailboxID: "Sent", messageID: "<three@example.com>", from: me.address,
                                subject: "Re: Plans", date: Date(timeIntervalSince1970: 200))
        reply.inReplyTo = "<seven@example.com>"
        let thread = MailModel.tag(MailThread(id: "t7", messages: [mail]), account: me.id)
        before.shelves[me.id] = InboxShelf([thread])
        before.sentMail[me.id] = [reply]
        before.selectedThreadID = thread.id
        before.bodies[MailModel.bodyKey(me.id, mail.id)] = MessageBody(text: "Shall we go on Friday?")
        before.bodies[MailModel.bodyKey(me.id, reply.id)] = MessageBody(text: "Friday works.")
        let screen = try #require(before.lastScreen())
        try JSONEncoder().encode(screen).write(to: before.lastScreenFile)

        // The next launch: nothing read from saved mail or a server yet.
        let after = MailModel(environment: environment(folder))
        #expect(after.mailboxes[me.id] == folders)
        #expect(after.inboxThreads(me.id).map(\.id) == [thread.id])
        #expect(after.selectedThreadID == thread.id)
        let open = try #require(after.selectedThread)
        #expect(after.conversation(open).messages.map(\.id) == ["INBOX/7", "Sent/3"])
        #expect(after.body(of: mail, in: open)?.text == "Shall we go on Friday?")
        #expect(after.body(of: reply, in: open)?.text == "Friday works.")
    }

    @Test func aRemovedMailboxIsntBroughtBack() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "margin-last-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let kept = account("kept@example.com"), gone = account("gone@example.com")
        try environment(folder).accounts.save([kept, gone])
        let before = MailModel(environment: environment(folder))
        for account in [kept, gone] {
            before.mailboxes[account.id] = [Mailbox(id: "INBOX", name: "Inbox", role: .inbox)]
            before.shelves[account.id] = InboxShelf([])
        }
        try JSONEncoder().encode(try #require(before.lastScreen())).write(to: before.lastScreenFile)
        try environment(folder).accounts.save([kept])
        let after = MailModel(environment: environment(folder))
        #expect(after.mailboxes[kept.id] != nil)
        #expect(after.mailboxes[gone.id] == nil)
    }

    /// A read mark made here reaches saved mail at once, and at launch saved mail doesn't
    /// replace the inbox the last screen brought back: the unread count went 393, 396, 393.
    @Test func countsDontJumpAtLaunch() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "margin-last-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let me = account("me@example.com")
        try environment(folder).accounts.save([me])
        let inbox = Mailbox(id: "INBOX", name: "Inbox", role: .inbox)
        let mail = MailMessage(id: "INBOX/1", mailboxID: "INBOX", messageID: "<one@example.com>",
                               from: EmailAddress(address: "sam@example.com"), subject: "Hi", date: Date(timeIntervalSince1970: 100))
        let thread = MailThread(id: "t1", messages: [mail])

        let before = MailModel(environment: environment(folder))
        await before.environment.cache.saveMailboxes([inbox], account: me.id)
        await before.environment.cache.saveThreads([thread], account: me.id, mailbox: "INBOX", limit: 200)
        before.mailboxes[me.id] = [inbox]
        before.shelves[me.id] = InboxShelf([MailModel.tag(thread, account: me.id)])
        before.providers[me.id] = QuietProvider()
        await before.apply(.markRead, to: [MailModel.tag(thread, account: me.id)], announce: false)
        let saved = await before.environment.cache.threads(account: me.id, mailbox: "INBOX", limit: 200, bodies: false)
        #expect(saved.first?.isUnread == false)
        #expect(before.unreadCount(account: nil) == 0)

        // Saved mail says unread again (as if written before the change): the last screen wins.
        await before.environment.cache.saveThreads([thread], account: me.id, mailbox: "INBOX", limit: 200)
        try JSONEncoder().encode(try #require(before.lastScreen())).write(to: before.lastScreenFile)
        let after = MailModel(environment: environment(folder))
        #expect(after.unreadCount(account: nil) == 0)
        await after.loadSavedMail()
        #expect(after.unreadCount(account: nil) == 0)
    }
}
