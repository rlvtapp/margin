import Foundation
import MailCore
import Testing
@testable import MailUI

/// Mailboxes of any size: the list shows a part and grows at its end, older mail is fetched as
/// it's scrolled to, and one conversation changing never sends anything through the others.
@MainActor @Suite struct LargeMailboxTests {
    private func thread(_ index: Int, account: UUID, unread: Bool = false, minutes: Double? = nil, from: String = "noor@example.com") -> MailThread {
        let message = MailMessage(id: "INBOX/\(index)", mailboxID: "INBOX", messageID: "<\(account.uuidString.prefix(4))-\(index)@example.com>",
                                  from: EmailAddress(name: "Noor", address: from), to: [EmailAddress(address: "me@example.com")],
                                  subject: "Subject \(index)", date: Date(timeIntervalSinceNow: -(minutes ?? Double(index)) * 60),
                                  snippet: "Preview \(index)", flags: unread ? [] : [.seen])
        return MailModel.tag(MailThread(id: "t\(index)", messages: [message]), account: account)
    }

    /// A model whose mailboxes hold made-up mail on a made-up server, `counts` conversations each.
    private func model(_ counts: [Int]) -> (MailModel, BenchmarkMail) {
        let model = MailModel(environment: .preview())
        let mail = BenchmarkMail(accounts: counts.count)
        model.accounts = mail.accounts
        for (number, account) in mail.accounts.enumerated() {
            model.providers[account.id] = BenchmarkProvider(mail: mail, number: number, count: counts[number])
        }
        return (model, mail)
    }

    private func wait(_ what: () -> Bool) async {
        for _ in 0..<400 where !what() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    // MARK: The shelf

    @Test func aShelfKeepsItsCountsAsConversationsChange() {
        let account = UUID()
        var shelf = InboxShelf((0..<50).map { thread($0, account: account, unread: $0 % 5 == 0) })
        #expect(shelf.count == 50)
        #expect(shelf.unreadCount(split: nil) == 10)
        #expect(shelf.unreadCount(split: .people) == 10)
        // A read mark: one conversation touched, the count follows.
        let index = shelf.position(of: shelf.threads[10]) ?? -1
        #expect(index == 10)
        shelf.replace(at: index, with: MailModel.changed(shelf.threads[index], by: .markRead))
        #expect(shelf.unreadCount(split: nil) == 9)
        shelf.remove(at: [0, 5])   // both unread
        #expect(shelf.count == 48)
        #expect(shelf.unreadCount(split: nil) == 7)
        shelf.add([thread(60, account: account, unread: true), thread(61, account: account)])
        #expect(shelf.count == 50)
        #expect(shelf.unreadCount(split: nil) == 8)
        #expect(shelf.threads.last?.subject == "Subject 61")
        shelf.trim(to: 20)
        #expect(shelf.count == 20)
        #expect(shelf.tally(.everything, rows: 20).unread == shelf.threads.filter(\.isUnread).count)
        // Whatever order it's given in, it's kept newest first.
        let shuffled = InboxShelf((0..<30).map { thread($0, account: account) }.shuffled())
        #expect(shuffled.threads.map(\.subject) == (0..<30).map { "Subject \($0)" })
    }

    @Test func theNewestAcrossMailboxesAreFoundWithoutMergingThem() {
        let one = UUID(), two = UUID()
        let first = InboxShelf((0..<300).map { thread($0, account: one, unread: $0 % 3 == 0, minutes: Double($0) * 2) })
        let second = InboxShelf((0..<300).map { thread($0, account: two, unread: $0 % 4 == 0, minutes: Double($0) * 2 + 1) })
        let reader = ShelfReader(shelves: [first, second])
        let merged = (first.threads + second.threads).sorted { $0.date > $1.date }
        #expect(reader.newest(40).map(\.id) == merged.prefix(40).map(\.id))
        #expect(reader.merged().map(\.id) == merged.map(\.id))
        var unread = InboxShelf.Filter()
        unread.require(InboxShelf.Facts.unread)
        #expect(reader.newest(25, filter: unread).map(\.id) == merged.filter(\.isUnread).prefix(25).map(\.id))
        #expect(reader.tally(unread).count == merged.filter(\.isUnread).count)
    }

    // MARK: The list

    @Test func theListShowsAPartAndGrowsAtItsEnd() {
        let model = MailModel(environment: .preview())
        let account = model.accounts[0]
        model.setInbox((0..<650).map { thread($0, account: account.id, unread: $0 % 2 == 0) }, for: account.id)
        model.reachedOldest.insert(account.id)
        model.go(to: .inbox(account: account.id, split: nil))
        #expect(model.visibleThreads.count == MailModel.listPage)
        #expect(model.listCount == 650)
        #expect(model.listUnreadCount == 325)
        #expect(model.canShowMore)
        model.listReachedEnd()
        #expect(model.visibleThreads.count == 400)
        model.listReachedEnd(); model.listReachedEnd()
        #expect(model.visibleThreads.count == 650)
        #expect(!model.canShowMore)
        // Filters count everything too, not only the rows shown.
        model.go(to: .inbox(account: account.id, split: nil))
        model.quickFilters = [.unread]
        #expect(model.visibleThreads.count == 200)
        #expect(model.listCount == 325)
        model.quickFilters = []
        model.searchText = "Subject 64"
        // 64, 164 … 564 and 640 to 649.
        #expect(model.visibleThreads.allSatisfy { $0.subject.contains("64") })
        #expect(model.visibleThreads.first?.subject == "Subject 64")
        #expect(model.listCount == 16)
    }

    @Test func selectAllReachesPastTheRowsShown() async {
        let model = MailModel(environment: .preview())
        let account = model.accounts[0]
        model.setInbox((0..<450).map { thread($0, account: account.id) }, for: account.id)
        model.go(to: .inbox(account: account.id, split: nil))
        #expect(model.visibleThreads.count == 200)
        model.selectAll()
        #expect(model.selection.count == 450)
        #expect(model.actionTargets.count == 450)
        await model.apply(.done, to: model.actionTargets, announce: true)
        #expect(model.inboxThreads(account.id).isEmpty)
        model.undo()
        #expect(model.inboxThreads(account.id).count == 450)
    }

    @Test func steppingDownPastTheLastRowBringsTheNextOnes() {
        let model = MailModel(environment: .preview())
        let account = model.accounts[0]
        model.setInbox((0..<500).map { thread($0, account: account.id) }, for: account.id)
        model.reachedOldest.insert(account.id)
        model.go(to: .inbox(account: account.id, split: nil))
        model.select(model.visibleThreads[197].id)
        model.moveSelection(1)
        #expect(model.visibleThreads.count == 400)
        #expect(model.selectedThread?.subject == "Subject 198")
    }

    @Test func aReadMarkTouchesOneConversation() async throws {
        let model = MailModel(environment: .preview())
        for account in model.accounts {
            model.setInbox((0..<1_000).map { thread($0, account: account.id, unread: $0 % 4 == 0) }, for: account.id)
        }
        model.go(to: .allInboxes)
        _ = model.visibleThreads; _ = model.selectedThread; _ = model.needYouCount; _ = model.homeGroups
        let unread = model.unreadCount(account: nil)
        let merges = model.derived.merged.computations, indexes = model.derived.placeIndex.computations
        let groups = model.derived.homeGroups.computations
        let firstUnread = model.visibleThreads.first { $0.isUnread }
        let target = try #require(firstUnread)
        await model.apply(.markRead, to: [target], announce: false)
        #expect(model.unreadCount(account: nil) == unread - 1)
        #expect(model.unreadCount(account: target.accountID) == 249)
        #expect(model.visibleThreads.first { $0.id == target.id }?.isUnread == false)
        #expect(model.listUnreadCount == unread - 1)
        _ = model.selectedThread; _ = model.needYouCount; _ = model.homeGroups
        // Nothing that depends on which conversations there are was worked out again.
        #expect(model.derived.merged.computations == merges)
        #expect(model.derived.placeIndex.computations == indexes)
        #expect(model.derived.homeGroups.computations == groups)
        // And everything that reads the whole inbox still sees the change.
        #expect(model.inboxThreads(nil).first { $0.id == target.id }?.isUnread == false)
    }

    @Test func undoPutsBackOnlyWhatWasTakenOut() async throws {
        let model = MailModel(environment: .preview())
        let account = model.accounts[0]
        model.setInbox((0..<300).map { thread($0, account: account.id) }, for: account.id)
        model.go(to: .inbox(account: account.id, split: nil))
        let gone = model.visibleThreads[4]
        await model.apply(.done, to: [gone], announce: true)
        #expect(model.inboxThreads(account.id).count == 299)
        // Mail that arrives while Undo is still offered stays when it's used.
        model.shelves[account.id]?.add([thread(-1, account: account.id, minutes: -1)])
        model.inboxesChanged(order: true)
        model.undo()
        #expect(model.inboxThreads(account.id).count == 301)
        #expect(model.inboxThreads(account.id)[5].id == gone.id)
        #expect(model.inboxThreads(account.id)[0].subject == "Subject -1")
    }

    @Test func pinnedConversationsLeadEvenFromFarDown() {
        let model = MailModel(environment: .preview())
        let account = model.accounts[0]
        model.setInbox((0..<900).map { thread($0, account: account.id) }, for: account.id)
        model.go(to: .inbox(account: account.id, split: nil))
        let deep = model.inboxThreads(account.id)[850]
        model.togglePin(deep)
        #expect(model.visibleThreads.first?.id == deep.id)
        #expect(model.visibleThreads.count == 200)
        #expect(model.visibleThreads.filter { $0.id == deep.id }.count == 1)
        #expect(model.listCount == 900)
    }

    // MARK: Older mail

    @Test func scrollingPastWhatIsLoadedFetchesOlderMail() async throws {
        let (model, _) = model([1_000])
        await model.reload()
        let account = model.accounts[0]
        model.go(to: .inbox(account: account.id, split: nil))
        #expect(model.inboxThreads(account.id).count == 200)
        #expect(model.listCount == 200)
        #expect(model.canShowMore)
        model.listReachedEnd()
        await wait { !model.isLoadingOlder && model.inboxThreads(account.id).count == 400 }
        #expect(model.inboxThreads(account.id).count == 400)
        #expect(model.canShowMore)
        model.listReachedEnd()
        #expect(model.visibleThreads.count == 400)
        // Older mail was saved as it came, and is what shows first next time.
        let saved = await model.environment.cache.messageCount(account: account.id, mailbox: "INBOX")
        #expect(saved >= 400)
        // Leaving the list lets the older mail go: every list starts from its newest page.
        model.go(to: .starred(account: account.id))
        #expect(model.inboxThreads(account.id).count == 200)
        #expect(model.inboxLimit(account.id) == MailModel.listPage)
    }

    @Test func theEndOfASmallMailboxIsTheEnd() async throws {
        let (model, _) = model([120])
        await model.reload()
        let account = model.accounts[0]
        model.go(to: .inbox(account: account.id, split: nil))
        #expect(model.inboxThreads(account.id).count == 120)
        #expect(!model.canShowMore)
    }

    /// Mailboxes shown together are read down to where the first of them runs out of loaded
    /// mail, so that fetching its older mail adds rows at the end of the list, never in the
    /// middle.
    @Test func mailboxesTogetherAreShownDownToWhereTheFirstRunsOut() async throws {
        let (model, _) = model([1_000, 1_000])
        let busy = model.accounts[0].id, quiet = model.accounts[1].id
        // One mailbox gets mail every minute, the other every hour: 200 each are loaded.
        model.setInbox((0..<200).map { thread($0, account: busy, minutes: Double($0)) }, for: busy)
        model.setInbox((0..<200).map { thread($0, account: quiet, minutes: Double($0) * 60 + 0.5) }, for: quiet)
        model.go(to: .allInboxes)
        // The busy mailbox's 200 cover 200 minutes; the quiet one has 4 in that time.
        #expect(model.listCount == 204)
        #expect(model.visibleThreads.last?.accountID == busy)
        // Once the busy one has nothing older, the quiet one's mail below shows.
        model.reachedOldest.insert(busy)
        model.inboxesChanged(order: true)
        #expect(model.listCount == 400)
        // One mailbox by itself is never cut short.
        model.reachedOldest = []
        model.go(to: .inbox(account: quiet, split: nil))
        #expect(model.listCount == 200)
    }

    // MARK: What needs you

    @Test func whatNeedsYouIsFoundBeyondTheRowsShown() async throws {
        let model = MailModel(environment: .preview())
        let account = model.accounts[0]
        var threads = (0..<600).map { thread($0, account: account.id, from: "no-reply@shop.example") }
        // Row 450: someone you've written to wrote, and you haven't answered.
        threads[450] = thread(450, account: account.id, from: "noor@example.com")
        model.setInbox(threads, for: account.id)
        model.correspondents = ["noor@example.com"]
        model.go(to: .home(group: nil))
        #expect(model.visibleThreads.count == 200)
        #expect(model.needsYou().map(\.thread.subject) == ["Subject 450"])
        #expect(model.needYouCount == 1)
        let sections = try #require(model.listSections(model.visibleThreads))
        #expect(sections.first?.id == "home-needs")
        #expect(sections.first?.threads.map(\.subject) == ["Subject 450"])
    }

    @Test func aSignInCodeFromLongAgoNeedsNobody() {
        let model = MailModel(environment: .preview())
        let account = model.accounts[0]
        func code(_ index: Int, days: Double) -> MailThread {
            let message = MailMessage(id: "INBOX/\(index)", mailboxID: "INBOX", from: EmailAddress(address: "security@service.example"),
                                      subject: "Your verification code is 482913", date: Date(timeIntervalSinceNow: -days * 86_400), flags: [.seen])
            return MailModel.tag(MailThread(id: "c\(index)", messages: [message]), account: account.id)
        }
        model.setInbox([code(1, days: 0.01), code(2, days: 40)], for: account.id)
        #expect(model.needsYou().map(\.thread.id) == [code(1, days: 0).id])
        #expect(model.needsYou().first?.note.kind == .code)
    }

    // MARK: Small sets asked on every redraw

    @Test func snoozedAndLabelledConversationsAreKeptTrackOf() async throws {
        let model = MailModel(environment: .preview())
        let account = model.accounts[0]
        model.setInbox((0..<400).map { thread($0, account: account.id, unread: $0 % 2 == 0) }, for: account.id)
        let all = model.inboxThreads(account.id)
        model.snooze(all[300], until: Date().addingTimeInterval(3_600))
        #expect(model.snoozedInInboxes(nil).map(\.thread.id) == [all[300].id])
        #expect(model.snoozedInInboxes(account.id).count == 1)
        model.go(to: .inbox(account: account.id, split: nil))
        #expect(model.listCount == 399)
        model.go(to: .snoozed(account: nil))
        #expect(model.visibleThreads.map(\.id) == [all[300].id])
        model.addLabel("Travel", to: all[350])
        model.addLabel("Travel", to: all[351])
        #expect(model.unreadByLabel["Travel"] == 1)
        #expect(model.inboxThreads(labelled: "travel").count == 2)
        await model.apply(.markRead, to: [all[350]], announce: false)
        #expect(model.unreadByLabel["Travel"] == nil)
        model.go(to: .home(group: "Travel"))
        #expect(Set(model.visibleThreads.map(\.id)) == [all[350].id, all[351].id])
        #expect(model.countFromSameSender(as: all[0]) == 400)
    }
}
