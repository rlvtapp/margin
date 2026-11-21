import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct AICoreTests {
    private func model(allowChanges: Bool) async -> MailModel {
        let model = MailModel(environment: .preview())
        await model.reload()
        var settings = ConnectionSettings()
        settings.enabled = true
        settings.allowChanges = allowChanges
        settings.allowSending = true
        settings.allowSettings = true
        model.connectionSettings = settings
        return model
    }

    /// While Margin is closed: everything that reads, and the calendar's changes when changes
    /// are allowed; never mail changes, sending, settings, or what needs Margin on screen.
    @Test func offersReadingAndTheCalendar() async {
        let names = Set(await CoreToolbox(model: await model(allowChanges: true)).tools().map(\.name))
        #expect(names.contains("search_mail") && names.contains("read_conversation") && names.contains("get_events"))
        #expect(names.contains("create_event"))
        #expect(!names.contains("archive") && !names.contains("send_email") && !names.contains("create_draft") && !names.contains("get_selection"))
        let readOnly = Set(await CoreToolbox(model: await model(allowChanges: false)).tools().map(\.name))
        #expect(!readOnly.contains("create_event"))
        #expect(readOnly.contains("get_events"))
    }

    /// A mail change asks for Margin to be opened instead of happening.
    @Test func mailChangesWaitForMargin() async {
        let toolbox = CoreToolbox(model: await model(allowChanges: true))
        await #expect(throws: MCPToolError.self) { try await toolbox.call("archive", arguments: ["ids": .array([.string("x")])]) }
        let mailboxes = try? await toolbox.call("list_mailboxes", arguments: [:])
        #expect(mailboxes?.isEmpty == false)
    }
}
