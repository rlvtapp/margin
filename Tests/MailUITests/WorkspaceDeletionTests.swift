import Foundation
import MailCore
import SwiftUI
import Testing
@testable import MailUI

/// Deleting workspaces: the one in view, the last one left, and a name field that is still
/// writing to a workspace after it was deleted (which used to stop the app).
@MainActor @Suite struct WorkspaceDeletionTests {
    /// The editor's list before Save, held the way its `@State` holds it.
    @MainActor final class Draft {
        var workspaces: [Workspace]
        init(_ workspaces: [Workspace]) { self.workspaces = workspaces }
        var binding: Binding<[Workspace]> { Binding(get: { self.workspaces }, set: { self.workspaces = $0 }) }
    }

    func model() async -> MailModel {
        let model = MailModel(environment: .preview())
        await model.reload()
        return model
    }

    @Test func aFieldStillEditingADeletedWorkspaceChangesNothing() {
        let draft = Draft([Workspace(name: "Work", colorIndex: 1, accounts: []),
                           Workspace(name: "Personal", colorIndex: 4, accounts: [])])
        let work = draft.binding.item(draft.workspaces[0])
        let personal = draft.binding.item(draft.workspaces[1])

        // While it's there, the field edits the workspace in the list.
        personal.wrappedValue.name = "Home"
        #expect(draft.workspaces.map(\.name) == ["Work", "Home"])

        // Deleting the last in the list is what stopped the app: its field read the list at a
        // place that was gone.
        let deleted = personal.wrappedValue.id
        draft.workspaces.removeAll { $0.id == deleted }
        #expect(personal.wrappedValue.name == "Personal")
        personal.wrappedValue.name = "Still typing"
        personal.wrappedValue.accounts = [UUID()]
        #expect(draft.workspaces.map(\.name) == ["Work"])
        #expect(draft.workspaces[0].accounts.isEmpty)

        // The others still follow the list after it shifted.
        work.wrappedValue.colorIndex = 7
        #expect(draft.workspaces[0].colorIndex == 7)

        // And the last one left.
        draft.workspaces.removeAll()
        #expect(work.wrappedValue.name == "Work")
        work.wrappedValue.name = "Gone"
        #expect(draft.workspaces.isEmpty)
    }

    @Test func deletingAnEarlierWorkspaceLeavesTheRestEditable() {
        let draft = Draft((1...3).map { Workspace(name: "Workspace \($0)", colorIndex: $0, accounts: []) })
        let fields = draft.workspaces.map { draft.binding.item($0) }
        draft.workspaces.removeFirst()
        fields[2].wrappedValue.name = "Third"
        fields[0].wrappedValue.name = "First"
        #expect(draft.workspaces.map(\.name) == ["Workspace 2", "Third"])
    }

    @Test func deletingTheWorkspaceInViewShowsEveryMailbox() async throws {
        let model = await model()
        try #require(model.accounts.count >= 2)
        model.addWorkspace(named: "Work")
        model.addWorkspace(named: "Personal")
        var all = model.workspaces
        all[0].accounts = [model.accounts[0].id]
        all[1].accounts = [model.accounts[1].id]
        model.workspaces = all
        let personal = all[1]

        model.switchWorkspace(to: personal.id)
        #expect(model.workspaceAccounts.map(\.id) == [model.accounts[1].id])

        // The editor's Save, with the workspace in view deleted while its name field is open.
        let draft = Draft(model.workspaces)
        let field = draft.binding.item(personal)
        draft.workspaces.removeAll { $0.id == personal.id }
        field.wrappedValue.name = "Personal mail"
        model.workspaces = draft.workspaces

        #expect(model.workspaces.map(\.name) == ["Work"])
        #expect(model.currentWorkspaceID == nil)
        #expect(model.currentWorkspace == nil)
        #expect(model.workspaceAccounts.map(\.id) == model.accounts.map(\.id))
        #expect(model.unreadCount(in: personal) >= 0)
        _ = model.visibleThreads
    }

    @Test func deletingTheLastWorkspaceLeavesNone() async throws {
        let model = await model()
        try #require(!model.accounts.isEmpty)
        model.addWorkspace(named: "Work")
        var all = model.workspaces
        all[0].accounts = [model.accounts[0].id]
        model.workspaces = all
        let work = all[0]
        model.switchWorkspace(to: work.id)
        let thread = try #require(model.inboxThreads(model.accounts[0].id).first)

        let draft = Draft(model.workspaces)
        let field = draft.binding.item(work)
        draft.workspaces.removeAll { $0.id == work.id }
        field.wrappedValue.name = "Still typing"
        model.workspaces = draft.workspaces

        #expect(model.workspaces.isEmpty)
        #expect(model.currentWorkspaceID == nil)
        #expect(model.workspaceAccounts.count == model.accounts.count)
        #expect(!model.isInOtherWorkspace(thread))
        _ = model.visibleThreads

        // Switching to one that's gone shows every mailbox instead of nothing.
        model.switchWorkspace(to: work.id)
        #expect(model.currentWorkspace == nil)
        #expect(model.workspaceAccounts.count == model.accounts.count)
    }

    /// A mailbox whose workspace was deleted (or that was never put in one) stays in the account
    /// column in every workspace, instead of dropping out of sight. Nothing is removed.
    @Test func aMailboxInNoWorkspaceShowsInEveryOne() async throws {
        let model = await model()
        let accounts = model.accounts
        try #require(accounts.count >= 2)
        let personal = Workspace(name: "Personal", colorIndex: 1, accounts: [accounts[0].id])
        let work = Workspace(name: "Work", colorIndex: 4, accounts: [accounts[1].id])
        model.workspaces = [personal, work]
        model.switchWorkspace(to: personal.id)
        #expect(model.workspaceAccounts.map(\.id) == [accounts[0].id])

        // Work is deleted while Personal is in view: Personal stays, and Work's mailbox shows in it.
        model.workspaces = [personal]
        #expect(model.currentWorkspaceID == personal.id)
        #expect(model.workspaceAccounts.map(\.id) == accounts.map(\.id))
        #expect(model.accounts.count == accounts.count)
        let thread = try #require(model.inboxThreads(accounts[1].id).first)
        #expect(!model.isInOtherWorkspace(thread))
    }
}
