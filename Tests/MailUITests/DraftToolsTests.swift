import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct DraftToolsTests {
    @Test func savesADraftForReviewAndListsIt() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let thread = model.inboxThreads(nil)[0]
        let saved = try await model.runTool("save_draft", ["reply_to_id": .string(thread.id), "body": .string("Sounds good, see you then.")])
        #expect(saved.contains("Drafts"))
        let listed = try await model.runTool("list_drafts", [:])
        #expect(listed.contains("Sounds good") || listed.contains(Subject.normalized(thread.subject)))
    }

    @Test func offersTheDraftingTools() async {
        let model = MailModel(environment: .preview())
        let names = await MailToolbox(model: model).tools().map(\.name)
        #expect(names.contains("save_draft"))
        #expect(names.contains("update_draft"))
        #expect(names.contains("get_writing_style"))
    }
}

@MainActor @Suite struct TryReplyNameTests {
    @Test func findsTheNameAnEmailIsSignedWith() {
        #expect(MailModel.signedName(in: "Are you coming tonight?\n\nSam") == "Sam")
        #expect(MailModel.signedName(in: "Can we talk tomorrow?\nNoor Haddad") == "Noor Haddad")
        #expect(MailModel.signedName(in: "Let me know what you think about the plan.") == nil)
    }
}

@MainActor @Suite struct GroupToolsTests {
    @Test func sortsIntoHomeGroupsAndCanAddOne() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        model.connectionSettings.allowChanges = true
        let thread = model.inboxThreads(nil)[0]
        _ = try await model.runTool("create_group", ["name": .string("Job offers"), "detail": .string("Recruiters and job offers.")])
        #expect(model.emailGroups.contains { $0.name == "Job offers" })
        _ = try await model.runTool("sort_into_group", ["ids": .array([.string(thread.id)]), "group": .string("job offers")])
        #expect(model.group(of: thread)?.name == "Job offers")
        #expect(!model.needsSorting(thread))
        #expect(model.homeGroups.contains { $0.group.name == "Job offers" && $0.count >= 1 })
    }
}

@MainActor @Suite struct MoveToGroupTests {
    @Test func movesBetweenGroupsAndOut() async {
        let model = MailModel(environment: .preview())
        await model.reload()
        let thread = model.inboxThreads(nil)[0]
        let groups = model.emailGroups
        model.move(thread, toGroup: groups[0])
        model.move(thread, toGroup: groups[1])
        #expect(model.group(of: thread)?.name == groups[1].name)
        #expect(!model.labels(for: thread).contains { $0.caseInsensitiveCompare(groups[0].name) == .orderedSame })
        model.move(thread, toGroup: nil)
        #expect(model.group(of: thread) == nil)
        #expect(!model.needsSorting(thread))
    }
}

@MainActor @Suite struct SortingLoopTests {
    @Test func listToSortEmptiesAsAnAgentSorts() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        model.connectionSettings.allowChanges = true
        func page() async throws -> (total: Int, ids: [String]) {
            let text = try await model.runTool("list_to_sort", ["limit": .number(5)])
            let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            let ids = (object["conversations"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            return (object["total"] as? Int ?? -1, ids)
        }
        var rounds = 0
        var current = try await page()
        let start = current.total
        #expect(start > 5)
        while current.total > 0, rounds < 20 {
            let half = current.ids.count / 2
            if half > 0 {
                _ = try await model.runTool("sort_into_group", ["ids": .array(current.ids.prefix(half).map { .string($0) }), "group": .string("Newsletters")])
            }
            _ = try await model.runTool("skip_sorting", ["ids": .array(current.ids.dropFirst(half).map { .string($0) })])
            current = try await page()
            rounds += 1
        }
        #expect(current.total == 0)
        #expect(rounds <= start / 5 + 1)
    }
}
