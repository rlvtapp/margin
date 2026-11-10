import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct LibraryTests {
    func model() async -> MailModel {
        let model = MailModel(environment: .preview())
        await model.start()
        return model
    }

    func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    @Test func searchFindsArchivedMailOnTheServer() async throws {
        let model = await model()
        // "Offsite photos" is only in the Work archive, so only the server search finds it.
        model.runSearch("offsite")
        try await waitFor { !model.isSearchingServers }
        #expect(model.visibleThreads.map(\.subject).contains("Offsite photos"))
        #expect(model.title == "“offsite”")
    }

    @Test func searchUsesOperators() async throws {
        let model = await model()
        model.runSearch("from:noor lisbon")
        try await waitFor { !model.isSearchingServers }
        #expect(!model.visibleThreads.isEmpty)
        #expect(model.visibleThreads.allSatisfy { $0.participants.contains { $0.displayName.hasPrefix("Noor") } })
    }

    @Test func savedMailShowsBeforeServersAnswer() async throws {
        let environment = MailEnvironment.preview()
        let first = MailModel(environment: environment)
        await first.reload()
        let second = MailModel(environment: environment)
        await second.loadSavedMail()
        #expect(second.inboxThreads(nil).count == first.inboxThreads(nil).count)
    }

    @Test func foldersAndMoving() async throws {
        let model = await model()
        let work = model.accounts[0].id
        model.createFolder(named: "Projects", in: work)
        try await waitFor { model.folders(of: work).contains { $0.name == "Projects" } }
        let projects = try #require(model.folders(of: work).first { $0.name == "Projects" })

        model.go(to: .inbox(account: work, split: nil))
        let thread = try #require(model.visibleThreads.first)
        model.select(thread.id)
        model.move(to: projects)
        try await waitFor { !model.visibleThreads.contains { $0.id == thread.id } }
        await model.flushPendingChange()
        model.go(to: .mailbox(account: work, projects))
        try await waitFor { model.visibleThreads.contains { $0.subject == thread.subject } }

        model.renameFolder(projects, in: work, to: "Clients 2027")
        try await waitFor { model.folders(of: work).contains { $0.name == "Clients 2027" } }
    }

    @Test func closingAMessageKeepsADraft() async throws {
        let model = await model()
        model.startCompose()
        var state = try #require(model.compose)
        state.to = "sam@kettle.example"
        state.draft.subject = "Half-written"
        model.closeComposer(state, isReply: false)
        #expect(model.compose == nil)
        try await waitFor { model.notice?.text == "Saved to Drafts" }
        model.go(to: .combined(.drafts))
        try await waitFor { model.visibleThreads.contains { $0.subject == "Half-written" } }

        // An empty reply isn't worth keeping.
        model.go(to: .allInboxes)
        model.select(model.visibleThreads.first?.id)
        model.startReply()
        #expect(model.reply?.hasContent == false)
    }
}
