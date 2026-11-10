import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct MarginNoteTests {
    @Test func notesSayWhyAConversationMatters() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let threads = model.inboxThreads(nil)
        // The sample's sign-in code gets "code"; a newsletter gets nothing.
        let kettle = try #require(threads.first { $0.subject.contains("sign-in code") })
        #expect(model.marginNote(for: kettle)?.kind == .code)
        let weekly = try #require(threads.first { $0.subject.contains("Issue 212") })
        #expect(model.marginNote(for: weekly) == nil)
        // A bill gets "bill".
        let bank = try #require(threads.first { $0.subject.contains("Card payment") })
        model.move(bank, toGroup: model.emailGroups.first { $0.name == EmailGroup.starters[3].name })
        #expect(model.marginNote(for: bank)?.text == "bill")
        #expect(model.needYouCount >= 2)
        #expect(!model.homeDate.isEmpty)
    }
}

@Suite struct PlainTextLinksTests {
    @Test func shortensLongLinksButKeepsWhereTheyGo() {
        let long = "https://outlook.office365.com/owa/sct-15-20-9412-4-msonline-outlook-583ad.templateTenant/?itemid=AQMkADAw&exvsurl=1&path=/calendar/item"
        let text = PlainTextLinks.attributed("Open: \(long) please. See https://margin.relevate.app too.")
        let plain = String(text.characters)
        #expect(plain.contains("outlook.office365.com/owa/…"))
        #expect(plain.contains("https://margin.relevate.app"))
        #expect(!plain.contains("itemid"))
        #expect(text.runs.contains { $0.link?.absoluteString == long })
    }
}
