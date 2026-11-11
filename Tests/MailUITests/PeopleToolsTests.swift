import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct PeopleToolsTests {
    func model() async -> MailModel {
        let model = MailModel(environment: .preview())
        await model.reload()
        return model
    }

    func object(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test func bothAreReadingTools() async {
        let model = await model()
        let names = await MailToolbox(model: model).tools().map(\.name)
        #expect(names.contains("list_needs_you") && names.contains("find_people"))
    }

    @Test func needsYouListsHomesNotesWithoutSignInCodes() async throws {
        let model = await model()
        let toolbox = MailToolbox(model: model)
        let bank = try #require(model.inboxThreads(nil).first { $0.subject.contains("Card payment") })
        model.move(bank, toGroup: model.emailGroups.first { $0.name == EmailGroup.starters[3].name })

        let text = try await toolbox.call("list_needs_you", arguments: [:])
        let answer = try object(text)
        let list = try #require(answer["conversations"] as? [[String: Any]])
        #expect(answer["total"] as? Int == model.needYouCount)
        #expect(list.count == model.needYouCount)
        #expect(answer["summary"] as? String == model.homeSummary())

        let kinds = list.compactMap { ($0["reason"] as? [String: Any])?["kind"] as? String }
        #expect(kinds.contains("code") && kinds.contains("bill"))
        let bill = try #require(list.first { $0["id"] as? String == bank.id })
        #expect((bill["reason"] as? [String: Any])?["text"] as? String == "bill")
        #expect(bill["subject"] as? String == bank.subject)
        #expect(!(bill["people"] as? [String] ?? []).isEmpty)
        #expect(bill["unread"] is Bool && bill["date"] is String)

        // The code itself never leaves Margin.
        let kettle = try #require(model.inboxThreads(nil).first { $0.subject.contains("sign-in code") })
        let code = try #require(model.signInCode(in: kettle))
        #expect(!text.contains(code))

        // Ids work with read_conversation.
        _ = try await toolbox.call("read_conversation", arguments: ["id": .string(bank.id)])
    }

    @Test func needsYouLeavesOutHiddenMailboxes() async throws {
        let model = await model()
        let kettle = try #require(model.inboxThreads(nil).first { $0.subject.contains("sign-in code") })
        let accountID = try #require(kettle.accountID)
        var settings = model.connectionSettings
        settings.hiddenAccounts = [accountID]
        model.connectionSettings = settings
        let list = try #require(try object(try await MailToolbox(model: model).call("list_needs_you", arguments: [:]))["conversations"] as? [[String: Any]])
        #expect(!list.contains { $0["id"] as? String == kettle.id })
        #expect(list.count == model.needsYou().filter { $0.thread.accountID != accountID }.count)
    }

    @Test func findPeopleMatchesWhatTheToFieldSuggests() async throws {
        let model = await model()
        let toolbox = MailToolbox(model: model)
        let text = try await toolbox.call("find_people", arguments: ["query": .string("noor")])
        let found = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
        let suggested = model.addressBook.suggestions(for: "noor", limit: 10).map(\.address)
        #expect(!suggested.isEmpty)
        #expect(found.compactMap { $0["address"] as? String } == suggested)
        #expect(found.first?["name"] as? String == "Noor Haddad")
        #expect(found.first?["source"] as? String == "mail")
        #expect(Set(found.compactMap { $0["address"] as? String }).count == found.count)

        await #expect(throws: MCPToolError.self) { try await toolbox.call("find_people", arguments: ["query": .string("n")]) }
        let one = try await toolbox.call("find_people", arguments: ["query": .string("ma"), "limit": .number(1)])
        #expect((try JSONSerialization.jsonObject(with: Data(one.utf8)) as? [Any])?.count ?? 0 <= 1)
    }

    @Test func findPeopleLeavesOutHiddenMailboxes() async throws {
        let model = await model()
        let noor = try #require(model.inboxThreads(nil).first { $0.latest.from.address == "noor@postbox.example" })
        var settings = model.connectionSettings
        settings.hiddenAccounts = [try #require(noor.accountID)]
        model.connectionSettings = settings
        let text = try await MailToolbox(model: model).call("find_people", arguments: ["query": .string("noor")])
        #expect(!text.contains("noor@postbox.example"))
    }

    @Test func theSummaryCountsOnlyWhatItIsGiven() async {
        let model = await model()
        #expect(!model.homeSummary().isEmpty)
        let none = model.homeSummary(only: { _ in false })
        #expect(!none.contains("to write") && !none.contains("to open"))
    }
}
