import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct PaletteHelpTests {
    @Test func theCommandPaletteFindsHelpAndFeedback() async {
        let model = MailModel(environment: .preview())
        await model.reload()
        let all = MailCommand.all(for: model)
        let help = all.filter { CommandPalette.matches($0.title.lowercased(), "help") }.map(\.id)
        #expect(help.contains("help"))
        let feedback = all.filter { CommandPalette.matches($0.title.lowercased(), "feedback") }.map(\.id)
        #expect(feedback.contains("help") && feedback.contains("feedback"))
    }

    @Test func typingNarrowsTheListAndTheBestFitComesFirst() async {
        let model = MailModel(environment: .preview())
        await model.reload()
        let titles = MailCommand.all(for: model).map(\.title)
        func found(_ query: String) -> [String] {
            titles.enumerated().compactMap { index, title in CommandPalette.score(title, query).map { (title, $0, index) } }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }.map(\.0)
        }
        let help = found("help")
        #expect(help.first == "Help and feedback")
        #expect(help.count <= 3)   // scattered letters ("Show or hide the sidebar") no longer count
        #expect(found("new").first?.hasPrefix("New") == true)
        #expect(CommandPalette.score("Mark read or unread", "mr") != nil)      // initials
        #expect(CommandPalette.score("Mark done", "mkd") != nil)               // close letters
        #expect(CommandPalette.score("Show or hide the sidebar", "help") == nil)
        #expect(CommandPalette.score("Move to Trash", "trash")! > CommandPalette.score("Archive everything from Trashy", "rash") ?? 0)
        #expect(found("zzqx").isEmpty)
    }
}
