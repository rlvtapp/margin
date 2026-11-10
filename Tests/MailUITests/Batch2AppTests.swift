import Foundation
import MailCore
import Testing
@testable import MailUI

/// Answers from a script, for testing what the app sends and shows.
struct ScriptedModel: MailLanguageModel {
    var attribution: String { "by script" }
    var transcriptBudget: Int { 4000 }
    func summary(_ request: ModelRequest) async throws -> ThreadSummary { ThreadSummary(headline: "x", points: [], action: nil) }
    func labels(_ request: ModelRequest) async throws -> [String] { [] }
    func reply(_ request: ModelRequest) async throws -> String { "" }
    func answer(_ request: ModelRequest) async throws -> MailAnswer {
        // Cite the conversation that mentions Lisbon.
        let blocks = request.prompt.components(separatedBy: "=====")
        let index = blocks.firstIndex { $0.contains("Lisbon") }.map { $0 + 1 } ?? 1
        return MailAnswer(text: "Noor booked a flat by the river.", sources: [index, 99])
    }
}

@MainActor @Suite struct Batch2AppTests {
    func model() async -> MailModel {
        let model = MailModel(environment: .preview())
        await model.start()
        return model
    }

    func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    @Test func asksAboutMailAndCitesSources() async throws {
        let model = await model()
        model.intelligence = MailIntelligence(model: ScriptedModel())
        model.ask("Where is the Lisbon flat?")
        try await waitFor { model.askAnswer != nil }
        #expect(model.askAnswer?.text == "Noor booked a flat by the river.")
        #expect(model.askSources.count == 1)
        #expect(model.askSources.first?.subject.contains("Lisbon") == true)
    }

    @Test func invitationsShowAndAnswer() async throws {
        let model = await model()
        let thread = try #require(model.inboxThreads(nil).first { $0.subject == "Invitation: Quarterly planning" })
        model.select(thread.id)
        try await waitFor { model.invite(in: thread) != nil }
        let invite = try #require(model.invite(in: thread)?.invite)
        #expect(invite.joinURL?.host() == "meet.google.com")
        #expect(invite.location == "Harbor office, room 3")
        model.respond(to: invite, in: thread, with: .accepted)
        try await waitFor { model.rsvps[invite.uid] == .accepted }
    }

    @Test func connectionsHideMailboxesAndCodes() async throws {
        let model = await model()
        var settings = model.connectionSettings
        settings.hiddenAccounts = [model.accounts[1].id]
        model.connectionSettings = settings
        let toolbox = MailToolbox(model: model)
        let mailboxes = try await toolbox.call("list_mailboxes", arguments: [:])
        #expect(mailboxes.contains("Work") && !mailboxes.contains("Personal"))
        let lisbon = try await toolbox.call("search_mail", arguments: ["query": .string("lisbon")])
        #expect(((try JSONSerialization.jsonObject(with: Data(lisbon.utf8)) as? [String: Any])?["total"] as? Int) == 0)

        let found = try await toolbox.call("search_mail", arguments: ["query": .string("sign-in code")])
        let id = try #require(((try JSONSerialization.jsonObject(with: Data(found.utf8)) as? [String: Any])?["conversations"] as? [[String: Any]])?.first?["id"] as? String)
        let read = try await toolbox.call("read_conversation", arguments: ["id": .string(id)])
        #expect(!read.contains("482 913") && !read.contains("482913"))
        #expect(read.contains("[sign-in code hidden]"))
    }

    @Test func changedKeysAndSingleKeySwitch() async throws {
        let model = await model()
        #expect(MailCommand.forKey("e", model: model)?.id == "done")
        model.keyOverrides = ["done": "Y"]
        #expect(MailCommand.forKey("y", model: model)?.id == "done")
        #expect(MailCommand.forKey("e", model: model)?.id != "done")
        model.singleKeyShortcuts = false
        #expect(MailCommand.forKey("y", model: model) == nil)
    }

    @Test func backupRestoresIntoAnotherMac() async throws {
        let first = await model()
        first.updateTemplate(MailTemplate(name: "Follow-up", body: "Any news?"))
        first.accentIndex = 4
        first.compactRows = true
        let thread = try #require(first.inboxThreads(nil).first)
        first.addLabel("Travel", to: thread)
        let file = try first.makeBackup(password: "pw", includeSecrets: true)

        let second = await model()
        #expect(second.accentIndex == 0)
        let message = try second.restore(file, password: "pw")
        #expect(message.hasPrefix("Backup restored"))
        #expect(second.templates.contains { $0.name == "Follow-up" })
        #expect(second.accentIndex == 4)
        #expect(second.compactRows)
        #expect(second.labels(for: thread) == ["Travel"])
        #expect(throws: BackupBox.Failure.wrongPassword) { try second.restore(file, password: "nope") }
    }
}
