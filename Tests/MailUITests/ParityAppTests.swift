import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct ParityAppTests {
    func model() async -> MailModel {
        let model = MailModel(environment: .preview())
        await model.reload()
        return model
    }

    @Test func homeShowsTheInboxByGroup() async throws {
        let model = await model()
        let first = try #require(model.inboxThreads(nil).first)
        model.addLabel("Travel", to: first)
        model.go(to: .home(group: nil))
        #expect(model.title == "Home")
        #expect(model.visibleThreads.count == model.inboxThreads(nil).filter { !model.isSnoozed($0) }.count)
        model.go(to: .home(group: "Travel"))
        #expect(model.visibleThreads.map(\.id) == [first.id])
        #expect(model.homeGroups.contains { $0.group.name == "Travel" && $0.count == 1 })
        #expect(!model.greeting.isEmpty)
    }

    @Test func sortNowWithoutAnAssistantSortsOnlyClearMail() async throws {
        let model = await model()
        var off = model.assistantSettings
        off.provider = .off
        model.applyAssistant(off, apiKey: nil)
        #expect(!model.isAssistantOn)
        model.sortNow()
        while model.isSorting { try await Task.sleep(for: .milliseconds(20)) }
        // Whatever was sorted carries exactly one group label.
        for thread in model.inboxThreads(nil) {
            let groups = model.labels(for: thread).filter { label in model.emailGroups.contains { $0.name == label } }
            #expect(groups.count <= 1)
        }
    }

    @Test func groupsCanBeChanged() async {
        let model = await model()
        var groups = model.emailGroups
        groups.append(EmailGroup(name: "Climbing", detail: "Gym and trips"))
        model.emailGroups = groups
        #expect(model.emailGroups.last?.name == "Climbing")
    }

    @Test func chatViewKnowsWhatIWrote() async throws {
        let model = await model()
        let thread = try #require(model.inboxThreads(nil).first)
        let me = try #require(model.account(thread.accountID))
        var mine = thread.latest
        mine.from = me.address
        #expect(model.isMine(mine))
        #expect(!model.isMine(thread.latest) || model.accounts.contains { $0.address.address == thread.latest.from.address })
    }

    @Test func eachMailboxCanHaveItsOwnAlerts() async throws {
        let model = await model()
        let account = try #require(model.accounts.first)
        #expect(model.alerts(for: account.id) == nil)
        model.setAlerts(NewMailAlerts.none, for: account.id)
        #expect(model.alerts(for: account.id) == NewMailAlerts.none)
        model.setAlerts(nil, for: account.id)
        #expect(model.alerts(for: account.id) == nil)
    }

    @Test func themesPickTheirMode() {
        #expect(AppAppearance.white.colorScheme == .light)
        #expect(AppAppearance.developer.colorScheme == .dark)
        #expect(AppAppearance.system.colorScheme == nil)
    }

    @Test func formattedSignatureReplacesThePlainOne() {
        let plain = "\n\n-- \nLena"
        var draft = Draft(from: EmailAddress(address: "lena@example.com"), to: [], subject: "Hi", text: "Hello" + plain)
        draft = MailModel.withFormattedSignature(draft, plain: plain, html: "<b>Lena</b>")
        #expect(draft.html?.contains("<b>Lena</b>") == true)
        #expect(draft.html?.contains("Hello") == true)
        #expect(draft.text.hasSuffix(plain))
    }

    @Test func agentsChangeSoundsAndSwipes() async throws {
        let model = await model()
        var settings = model.connectionSettings
        settings.allowSettings = true
        settings.allowChanges = true
        model.connectionSettings = settings
        let toolbox = MailToolbox(model: model)
        _ = try await toolbox.call("change_settings", arguments: ["sound": .string("none"), "swipe_right": .string("snooze")])
        #expect(model.alertSound == .none)
        #expect(model.leadingSwipes.first == .snooze)
        _ = try await toolbox.call("undo_last", arguments: [:])
        #expect(model.leadingSwipes.first != .snooze)
    }
}
