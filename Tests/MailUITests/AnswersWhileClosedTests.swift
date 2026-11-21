import Foundation
import Testing
@testable import MailUI

/// Settings → AI Apps → Answer while Margin is closed: on unless turned off, also for settings
/// saved before the switch existed, and remembered when turned off.
@Suite struct AnswersWhileClosedTests {
    @Test func isOnByDefault() throws {
        #expect(ConnectionSettings().answersWhileClosed)
        let older = try JSONDecoder().decode(ConnectionSettings.self, from: Data(#"{"enabled":true,"allowChanges":true}"#.utf8))
        #expect(older.answersWhileClosed)
        #expect(older.enabled)
    }

    @Test func offIsRemembered() throws {
        var settings = ConnectionSettings()
        settings.enabled = true
        settings.answersWhileClosed = false
        let again = try JSONDecoder().decode(ConnectionSettings.self, from: JSONEncoder().encode(settings))
        #expect(again == settings)
        #expect(!again.answersWhileClosed)
    }
}
