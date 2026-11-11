import Testing
@testable import MailCore

@Suite struct RecipientListTests {
    @Test func readsALineIntoRecipients() {
        let line = RecipientList.parse("Maya Lind <maya@example.com>, sam@example.com, \"Okafor, Sam\" <so@example.com>, ")
        #expect(line.recipients.map(\.address) == ["maya@example.com", "sam@example.com", "so@example.com"])
        #expect(line.recipients[2].name == "Okafor, Sam")
        #expect(line.pending.isEmpty)
    }

    @Test func keepsWhatIsStillBeingTyped() {
        let line = RecipientList.parse("maya@example.com, no")
        #expect(line.recipients.map(\.address) == ["maya@example.com"])
        #expect(line.pending == "no")
    }

    @Test func writesBackWellFormedText() {
        let people = [EmailAddress(name: "Okafor, Sam", address: "so@example.com"), EmailAddress(address: "maya@example.com")]
        let text = RecipientList.text(people, pending: " no ")
        #expect(text == "\"Okafor, Sam\" <so@example.com>, maya@example.com, no")
        // What's written reads back the same.
        #expect(RecipientList.parse(text).recipients == people)
        #expect(EmailAddress.parseList(RecipientList.text(people)) == people)
    }

    @Test func aCommaOrSpaceFinishesAnAddress() {
        #expect(RecipientList.commit("sam@example.com,").added.map(\.address) == ["sam@example.com"])
        #expect(RecipientList.commit("sam@example.com ").added.map(\.address) == ["sam@example.com"])
        #expect(RecipientList.commit("sam@example.com; maya@example.com; no").added.count == 2)
        #expect(RecipientList.commit("sam@example.com; maya@example.com; no").pending == "no")
    }

    @Test func typingANameIsLeftAlone() {
        let typing = RecipientList.commit("Sam Oka")
        #expect(typing.added.isEmpty)
        #expect(typing.pending == "Sam Oka")
        // Not an address yet: a comma doesn't lose it.
        #expect(RecipientList.commit("sam,").pending == "sam")
        #expect(RecipientList.commit("sam@example").added.isEmpty)
    }

    @Test func returnTakesTheLastPiece() {
        let done = RecipientList.commit("Sam <sam@example.com>", force: true)
        #expect(done.added == [EmailAddress(name: "Sam", address: "sam@example.com")])
        #expect(done.pending.isEmpty)
        #expect(RecipientList.commit("sam", force: true).pending == "sam")
    }

    @Test func nobodyIsAddedTwice() {
        let people = RecipientList.adding([EmailAddress(address: "SAM@example.com"), EmailAddress(address: "maya@example.com")],
                                          to: [EmailAddress(name: "Sam", address: "sam@example.com")])
        #expect(people.map(\.address) == ["sam@example.com", "maya@example.com"])
    }
}
