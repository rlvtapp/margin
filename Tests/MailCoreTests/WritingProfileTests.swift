import Foundation
import Testing
@testable import MailCore

@Suite struct WritingProfileTests {
    let noor = EmailAddress(name: "Noor Haddad", address: "noor@postbox.example")
    let sam = EmailAddress(name: "Sam Okafor", address: "sam@kettle.example")

    @Test func learnsGreetingsSignOffsAndLengthPerPerson() {
        var profile = WritingProfile()
        profile.learn("Hey Noor,\n\nYes! Book it, I'll send you my half.\n\nx\nAlex", to: [noor], id: "1")
        profile.learn("Hey Noor,\n\nCan't wait. I'm in for the museum too.\n\nx", to: [noor], id: "2")
        profile.learn("Hi Sam,\n\nHere is the renewal for next year. Could you sign by Friday?\n\nBest regards,\nAlex", to: [sam], id: "3")
        // The same message twice counts once.
        let learnedAgain = profile.learn("Hey Noor,\n\nAgain.", to: [noor], id: "1")
        #expect(!learnedAgain)

        let toNoor = try! #require(profile.people["noor@postbox.example"])
        #expect(toNoor.usualGreeting == "Hey {name},")
        #expect(toNoor.usualSignOff == "x")
        #expect(toNoor.isCasual)
        #expect(profile.people["sam@kettle.example"]?.usualSignOff == "Best regards")
        #expect(profile.overall.messages == 3)

        let guide = try! #require(profile.styleGuide(for: noor, myName: "Alex"))
        #expect(guide.contains("\"Hey Noor,\""))
        #expect(guide.contains("\"x\""))
        #expect(guide.contains("to Noor Haddad"))
    }

    @Test func leavesOutQuotesAndSignature() {
        let text = """
        Sounds good, thanks!

        Alex Rivera
        Studio North

        On Tue, Noor wrote:
        > Shall we book?
        """
        let own = WritingProfile.ownWriting(text, signature: "Alex Rivera\nStudio North")
        #expect(own == "Sounds good, thanks!")
    }

    @Test func saysNothingUntilItKnowsEnough() {
        var profile = WritingProfile()
        profile.learn("Hi Sam,\n\nThanks.", to: [sam])
        #expect(profile.styleGuide(for: sam, myName: "Alex") == nil)
    }
}

@Suite struct MultilingualWritingTests {
    let noor = EmailAddress(name: "Noor Haddad", address: "noor@postbox.example")
    let jan = EmailAddress(name: "Jan de Vries", address: "jan@werk.example")

    @Test func keepsEachLanguagesHabitsApart() throws {
        var profile = WritingProfile()
        profile.learn("Hi Noor,\n\nThat works for me, I'll send the slides tonight.\n\nCheers", to: [noor], id: "e1")
        profile.learn("Hi Noor,\n\nGreat, see you on Tuesday at the office then.\n\nCheers", to: [noor], id: "e2")
        profile.learn("Hoi Jan,\n\nDat is prima, ik stuur de offerte morgen door naar jullie.\n\nGroetjes", to: [jan], id: "n1")
        profile.learn("Hoi Jan,\n\nDank je voor het snelle antwoord, we gaan ermee aan de slag.\n\nGroetjes", to: [jan], id: "n2")
        profile.learn("Hoi Jan,\n\nIk heb het contract getekend en teruggestuurd vanochtend.\n\nGroetjes", to: [jan], id: "n3")

        #expect(WritingProfile.language(of: "Dat is prima, ik stuur de offerte morgen door.") == "nl")
        #expect(profile.languages["nl"]?.messages == 3)
        #expect(profile.usualLanguage(with: jan) == "nl")

        let dutch = try #require(profile.styleGuide(for: jan, myName: "Kaan", language: "nl"))
        #expect(dutch.contains("Dutch"))
        #expect(dutch.contains("\"Hoi Jan,\""))
        #expect(!dutch.contains("Cheers"))

        // English to someone only ever written to in Dutch: no Dutch greeting borrowed.
        let english = try #require(profile.styleGuide(for: jan, myName: "Kaan", language: "en"))
        #expect(english.contains("English"))
        #expect(!english.contains("Hoi"))
        #expect(!english.contains("Groetjes"))
    }
}

@Suite struct VoiceTests {
    let noor = EmailAddress(name: "Noor Haddad", address: "noor@postbox.example")

    @Test func takesOutDashesForPeopleWhoNeverWriteThem() {
        #expect(WritingProfile.withoutDashes("I'd love to come over—sounds like fun!") == "I'd love to come over, sounds like fun!")
        #expect(WritingProfile.withoutDashes("Great — see you then.") == "Great, see you then.")
        #expect(WritingProfile.withoutDashes("Open 9–5 on weekdays.") == "Open 9–5 on weekdays.")
    }

    @Test func learnsDashesWithoutKeepingSamples() throws {
        var profile = WritingProfile()
        for index in 1...4 {
            profile.learn("Hi Noor,\n\nThanks for sending this over, I'll have a look tonight and get back to you tomorrow.\n\nBest", to: [noor], id: "m\(index)")
        }
        #expect(profile.avoidsDashes())
        let guide = try #require(profile.styleGuide(for: noor, myName: "Kaan", language: "en"))
        #expect(guide.contains("Never use an em dash"))
        // Rules only: a sample email's content would end up in unrelated replies.
        #expect(!guide.contains("I'll have a look tonight"))
    }

    @Test func noNameMeansNoPlaceholder() {
        #expect(WritingProfile.greeting("Hi {name},", name: "") == "Hi,")
        #expect(WritingProfile.greeting("Hi {name},", name: "Sam") == "Hi Sam,")
    }
}
