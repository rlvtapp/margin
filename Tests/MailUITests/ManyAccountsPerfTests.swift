import Foundation
import MailCore
import Testing
@testable import MailUI

/// Six full mailboxes at once: what every redraw and every refresh costs on the main thread.
@MainActor @Suite struct ManyAccountsPerfTests {
    private func model(accounts count: Int = 6, threads: Int = 200) async throws -> MailModel {
        let environment = MailEnvironment.preview()
        let accounts = (0..<count).map { index in
            MailAccount(label: "Mailbox \(index)", address: EmailAddress(address: "me\(index)@example\(index).com"),
                        connection: .imap(incoming: ServerEndpoint(host: "127.0.0.1", port: 1, security: .plain),
                                          outgoing: ServerEndpoint(host: "127.0.0.1", port: 1, security: .plain)),
                        auth: .password(username: "me\(index)"))
        }
        try environment.accounts.save(accounts)
        let model = MailModel(environment: environment)
        let senders = (0..<300).map { EmailAddress(name: "Person \($0)", address: "person\($0)@company\($0 % 40).example") }
        let inbox = Mailbox(id: "INBOX", name: "Inbox", role: .inbox)
        for account in model.accounts {
            model.mailboxes[account.id] = [inbox, Mailbox(id: "Sent", name: "Sent", role: .sent)]
            model.inboxes[account.id] = (0..<threads).map { index in
                let headers: [String: String] = index % 3 == 0 ? ["list-unsubscribe": "<mailto:leave@list.example>", "list-id": "<list\(index % 50).example>"] : [:]
                let messages = (0..<(index % 5 == 0 ? 4 : 1)).map { part in
                    MailMessage(id: "INBOX/\(index * 10 + part)", mailboxID: "INBOX", from: senders[(index + part) % senders.count],
                                to: [account.address], subject: "Subject \(index)", date: Date(timeIntervalSinceNow: Double(-index * 600 + part)),
                                snippet: "A preview of message \(index) with some words in it", flags: index % 4 == 0 ? [] : [.seen], listHeaders: headers)
                }
                return MailModel.tag(MailThread(id: "t\(index)", messages: messages), account: account.id)
            }
            model.sentMail[account.id] = (0..<200).map { index in
                MailMessage(id: "Sent/\(index)", mailboxID: "Sent", messageID: "sent-\(index)@example", from: account.address,
                            to: [senders[index % 300]], subject: "Re: Subject \(index * 3)", date: Date(timeIntervalSinceNow: Double(-index * 500)))
            }
        }
        return model
    }

    private func time(_ label: String, runs: Int = 10, _ work: () -> Void) -> Double {
        work()
        let clock = ContinuousClock()
        let elapsed = clock.measure { for _ in 0..<runs { work() } }
        let ms = Double(elapsed.components.attoseconds) / 1e15 / Double(runs) + Double(elapsed.components.seconds) * 1000 / Double(runs)
        print(String(format: "PERF6 %-40@ %8.2f ms", label as NSString, ms))
        return ms
    }

    @Test func redrawAndRefreshWorkWithSixMailboxes() async throws {
        let model = try await model()
        let all = model.allInboxesThreads(nil)
        #expect(all.count == 1200)
        var worst = 0.0
        func note(_ ms: Double) { worst = max(worst, ms) }
        note(time("visibleThreads") { _ = model.visibleThreads })
        note(time("listSections(visibleThreads)") { _ = model.listSections(model.visibleThreads) })
        note(time("rail: unread per mailbox + all") {
            _ = model.unreadCount(account: nil)
            for account in model.workspaceAccounts { _ = model.unreadCount(account: account.id) }
        })
        note(time("rail: needYouCount + waitingCount") { _ = model.needYouCount; _ = model.waitingCount })
        note(time("sidebar: snoozed + vip counts") {
            _ = model.inboxThreads(nil).filter { model.isSnoozed($0) }.count
            _ = model.vipThreads(nil).filter(\.isUnread).count
        })
        note(time("statusLine") { _ = model.statusLine(now: Date()) })
        note(time("selectedThread") {
            model.selectedThreadID = all.last?.id
            _ = model.selectedThread
        })
        note(time("homeSections") { _ = model.homeSections(all) })
        note(time("applyInboxRules") { model.applyInboxRules() })
        note(time("notifyAboutNewMail") { model.notifyAboutNewMail() })
        note(time("askFacts") { _ = model.askFacts() })
        print(String(format: "PERF6 worst %.2f ms", worst))
    }

    /// The account column asks what needs you on every redraw. With many labelled conversations
    /// that used to walk through every label once per conversation.
    @Test func needsYouStaysCheapWithManyLabels() async throws {
        let model = try await model()
        let all = model.allInboxesThreads(nil)
        for (index, thread) in all.enumerated() where index % 2 == 0 { model.addLabel("Label \(index % 12)", to: thread) }
        #expect(model.labelStore.labelsByThread.count >= 500)
        let before = model.labelStore.revision
        model.addLabel("Extra", to: all[1])
        #expect(model.labelStore.revision > before)
        let ms = time("needYouCount, 600 labelled") { _ = model.needYouCount }
        #expect(ms < 16, "needYouCount takes \(ms) ms with six mailboxes and 600 labelled conversations")
        // A new label still changes the answer's cache.
        let count = model.needYouCount
        model.addLabel(MailModel.billsGroupName, to: all[3])
        _ = model.needYouCount
        #expect(model.needYouCount >= count)
    }
}

@Suite struct TakingTurnsTests {
    /// With several mailboxes, the Sent folders are read one at a time, longest ago first,
    /// instead of all at once.
    @Test func sentFoldersAreCheckedOneAtATime() {
        let a = UUID(), b = UUID(), c = UUID()
        let now = Date()
        // Never checked comes first.
        #expect(MailModel.dueForSentCheck([a, b, c], lastChecked: [a: now, b: now], now: now) == c)
        // Then whichever was checked longest ago, once two minutes have passed.
        let checked = [a: now.addingTimeInterval(-300), b: now.addingTimeInterval(-200), c: now.addingTimeInterval(-10)]
        #expect(MailModel.dueForSentCheck([a, b, c], lastChecked: checked, now: now) == a)
        // Nobody due: nothing is fetched.
        let fresh = [a: now.addingTimeInterval(-60), b: now.addingTimeInterval(-30), c: now]
        #expect(MailModel.dueForSentCheck([a, b, c], lastChecked: fresh, now: now) == nil)
        #expect(MailModel.dueForSentCheck([], lastChecked: [:], now: now) == nil)
    }
}
