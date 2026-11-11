import Testing
@testable import MailUI

@MainActor @Suite struct LabelColorTests {
    /// A label keeps its colour across launches (no random hashing), and a picked one wins.
    @Test func coloursAreStableAndPickable() {
        LabelColors.chosen = [:]
        let first = LabelColors.index(for: "Clients")
        #expect(LabelColors.index(for: "clients") == first)
        #expect((0..<LabelColors.names.count).contains(first))
        LabelColors.chosen = ["clients": 6]
        #expect(LabelColors.index(for: "Clients") == 6)
        LabelColors.chosen = [:]
    }
}
