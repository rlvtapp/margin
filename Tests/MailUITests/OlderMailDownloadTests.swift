import Foundation
import MailCore
import Testing
@testable import MailUI

/// The background download of older mail: it fills saved mail and never memory, carries on
/// after a quit, keeps to the chosen stretch, corrects what changed elsewhere, and makes mail
/// that was never scrolled to searchable and scrollable without a connection.
@MainActor @Suite(.serialized) struct OlderMailDownloadTests {
    /// A model on a saved-mail file of its own, with made-up mailboxes of `count` conversations.
    private func model(file: URL, count: Int, accounts: Int = 1, keep: KeepMail = .everything) -> (MailModel, [BenchmarkProvider]) {
        var environment = MailEnvironment.preview()
        environment.cache = MailCache(url: file)
        let model = MailModel(environment: environment)
        let mail = BenchmarkMail(accounts: accounts, now: Date(timeIntervalSince1970: 1_800_000_000))
        model.accounts = mail.accounts.enumerated().map { number, account in
            var copy = account
            copy.id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", number))!
            return copy
        }
        var made: [BenchmarkProvider] = []
        for (number, account) in model.accounts.enumerated() {
            let provider = BenchmarkProvider(mail: mail, number: number, count: count)
            model.providers[account.id] = provider
            model.mailboxes[account.id] = BenchmarkMail.folders
            made.append(provider)
        }
        model.keepMail = keep
        model.keepText = .off
        model.downloadPause = .zero
        return (model, made)
    }

    private func file() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "margin-older-\(UUID().uuidString)/mail.sqlite")
    }

    private func messages(_ count: Int) -> Int {
        let mail = BenchmarkMail(accounts: 1)
        return (0..<count).reduce(0) { $0 + mail.thread($1, mailbox: 0).messages.count }
    }

    private func runAll(_ model: MailModel, now: Date = Date(timeIntervalSince1970: 1_800_000_000)) async -> Int {
        var steps = 0
        while await model.downloadStep(now: now), steps < 10_000 { steps += 1 }
        return steps
    }

    @Test func fillsSavedMailAndCarriesOnAfterAQuit() async {
        let url = file()
        let (first, providers) = model(file: url, count: 1_000)
        let inbox = BenchmarkMail.folders[0]
        for _ in 0..<3 { _ = await first.downloadStep() }
        let position = await first.environment.cache.downloadProgress(account: first.accounts[0].id, mailbox: inbox.id)?.position
        #expect(position != nil)
        #expect(await providers[0].pagesAsked == 3)
        // Nothing of it went into memory.
        #expect(first.shelves.isEmpty)

        // Started again on the same file: it goes on from there, not from the newest.
        let (second, again) = model(file: url, count: 1_000)
        _ = await runAll(second)
        let total = messages(1_000)
        #expect(await second.environment.cache.messageCount(account: second.accounts[0].id, mailbox: inbox.id) == total)
        let pages = await again[0].pagesAsked
        #expect(pages == (total + MailModel.downloadPage - 1) / MailModel.downloadPage - 3 || pages <= total / MailModel.downloadPage)
        #expect(await second.environment.cache.downloadProgress(account: second.accounts[0].id, mailbox: inbox.id)?.done == KeepMail.everything.rawValue)
        // Done: the next step has nothing left but checks, then nothing at all.
        #expect(await second.downloadStep(now: Date(timeIntervalSince1970: 1_800_000_000)) == false)
    }

    @Test func keepsToTheChosenStretchAndOffDoesNothing() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (off, _) = model(file: file(), count: 400, keep: .off)
        #expect(await off.downloadStep(now: now) == false)
        #expect(await off.environment.cache.messageCount() == 0)

        // The made-up mail goes back about 4.6 days for 400 conversations; asking from two
        // days short of three months on keeps only its newest two days or so.
        let later = Calendar.current.date(byAdding: .month, value: 3, to: now)!.addingTimeInterval(-2 * 86_400)
        let (some, _) = model(file: file(), count: 400, keep: .threeMonths)
        _ = await runAll(some, now: later)
        let cutoff = KeepMail.threeMonths.cutoff(now: later)!
        let saved = await some.environment.cache.threads(account: some.accounts[0].id, mailbox: "INBOX", limit: 5_000, bodies: false)
        let count = saved.reduce(0) { $0 + $1.messages.count }
        #expect(count > 0 && count < messages(400))
        #expect(saved.allSatisfy { $0.messages.allSatisfy { $0.date >= cutoff } })
        // A longer stretch picks up where the shorter one stopped.
        some.keepMail = .everything
        _ = await runAll(some, now: later)
        #expect(await some.environment.cache.messageCount(account: some.accounts[0].id, mailbox: "INBOX") == messages(400))
    }

    @Test func savesTheTextOfRecentMailAheadOfTime() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (model, _) = model(file: file(), count: 300)
        _ = await runAll(model, now: now)
        let cache = model.environment.cache
        #expect(await cache.textCount() == 0)
        // Two weeks of text: the made-up mail is all newer than that, so every text comes,
        // eight at a time, and then there's nothing left to ask.
        model.keepText = .twoWeeks
        var steps = 0
        while await model.downloadTexts(now: now), steps < 1_000 { steps += 1 }
        let total = messages(300)
        #expect(await cache.textCount() == total)
        #expect(steps == (total + MailModel.textBatch - 1) / MailModel.textBatch)
        #expect(await model.downloadTexts(now: now) == false)
        // Off asks for nothing, and mail older than the stretch keeps its text on the server.
        let (off, _) = self.model(file: file(), count: 50)
        _ = await runAll(off, now: now)
        #expect(await off.downloadTexts(now: now) == false)
        off.keepText = .twoWeeks
        #expect(await off.downloadTexts(now: now.addingTimeInterval(40 * 86_400)) == false)
        #expect(await off.environment.cache.textCount() == 0)
    }

    @Test func correctsMailChangedElsewhere() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (model, providers) = model(file: file(), count: 300)
        _ = await runAll(model, now: now)
        let account = model.accounts[0].id
        let cache = model.environment.cache
        let unread = try #require(await cache.message(id: "INBOX/2400", account: account))
        #expect(unread.isUnread)
        // Read on another device, and one deleted there.
        try await providers[0].perform(.markRead, on: [MailThread(id: "INBOX/2400", messages: [unread])])
        try await providers[0].perform(.trash, on: [MailThread(id: "INBOX/2600", messages: [])])
        #expect(await cache.message(id: "INBOX/2600", account: account) != nil)
        // An hour later (this server counts changes) the saved copies follow.
        _ = await runAll(model, now: now.addingTimeInterval(MailModel.checkWithChanges + 1))
        #expect(await cache.message(id: "INBOX/2400", account: account)?.isUnread == false)
        #expect(await cache.message(id: "INBOX/2600", account: account) == nil)
    }

    @Test func searchFindsMailThatWasNeverScrolledTo() async {
        let (model, _) = model(file: file(), count: 1_000)
        _ = await runAll(model)
        // Conversation 952 is far below the newest page; only the download saved it.
        model.runSearch("week 952")
        for _ in 0..<400 where !model.folder.contains(where: { $0.subject.contains("Plans for week 952") }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.folder.contains { $0.subject.contains("Plans for week 952") })

        await model.clearDownloadedMail()
        #expect(await model.environment.cache.messageCount() <= 500)
        #expect(model.savedMailUsage != nil)
    }

    @Test func savedMailAloneKeepsScrollingWhenTheServerIsUnreachable() async {
        let (model, _) = model(file: file(), count: 1_000)
        _ = await runAll(model)
        let account = model.accounts[0].id
        await model.environment.cache.saveMailboxes(BenchmarkMail.folders, account: account)
        model.providers[account] = Unreachable()
        await model.loadSavedMail()
        model.go(to: .inbox(account: account, split: nil))
        #expect(model.listCount == MailModel.listPage)
        for _ in 0..<3 {
            model.listWindow = model.listCount
            model.listReachedEnd()
            for _ in 0..<400 where model.isLoadingOlder { try? await Task.sleep(for: .milliseconds(5)) }
        }
        // Three pages more from saved mail alone (a few conversations join across page edges).
        #expect(model.listCount > MailModel.listPage * 3 + 150)
        #expect(model.canShowMore)
    }

    /// Fills 20,000 messages as fast as it goes and says how long that took, what it takes on
    /// disk, and the longest the main thread was kept from other work meanwhile.
    @Test func measuresFillingTwentyThousand() async {
        let url = file()
        let (model, _) = model(file: url, count: 12_200)
        let total = messages(12_200)
        let before = await model.environment.cache.usage().bytes
        var longest: Double = 0
        let ticker = Task { @MainActor in
            var last = CFAbsoluteTimeGetCurrent()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1))
                let now = CFAbsoluteTimeGetCurrent()
                longest = max(longest, now - last)
                last = now
            }
        }
        let clock = ContinuousClock()
        let took = await clock.measure { _ = await runAll(model) }
        ticker.cancel()
        let usage = await model.environment.cache.usage()
        let perThousand = Double(usage.bytes - before) / Double(usage.messages) * 1_000 / 1_024
        let seconds = Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18
        let report = String(format: "older mail download: %d messages in %.1f s (no pause between pages), %.0f KB per 1,000 messages, longest main-thread wait %.1f ms",
                            usage.messages, seconds, perThousand, longest * 1_000)
        print(report)
        try? report.write(to: url.deletingLastPathComponent().deletingLastPathComponent().appending(path: "margin-older-mail-measure.txt"), atomically: true, encoding: .utf8)
        #expect(usage.messages == total)
        #expect(longest < 0.1)
    }
}

/// A server that can't be reached.
private actor Unreachable: MailProvider {
    func mailboxes() async throws -> [Mailbox] { throw MailError.connectionFailed("offline") }
    func threads(in mailbox: Mailbox, limit: Int) async throws -> [MailThread] { throw MailError.connectionFailed("offline") }
    func body(of message: MailMessage) async throws -> MessageBody { throw MailError.connectionFailed("offline") }
    func perform(_ action: MailAction, on threads: [MailThread]) async throws { throw MailError.connectionFailed("offline") }
    func send(_ draft: Draft) async throws { throw MailError.connectionFailed("offline") }
    func disconnect() async {}
}
