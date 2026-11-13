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

@Suite struct WritingVoiceTests {
    let jan = EmailAddress(name: "Jan de Vries", address: "jan@werf.example")
    let eva = EmailAddress(name: "Eva Smit", address: "eva@werf.example")

    private func dutchProfile() -> WritingProfile {
        var profile = WritingProfile()
        let bodies = [
            "Hi Jan,\n\nTop, dank je voor het sturen. Ik kijk er morgen even naar.\n\nLaat maar weten als je nog vragen hebt.\n\nGroetjes,\nDat",
            "Hi Eva,\n\nDank je voor het snelle antwoord. Kun je de nieuwe versie sturen? Dan kijk ik er vrijdag even naar.\n\nLaat maar weten als je nog vragen hebt.\n\nGroetjes,\nDat",
            "Hi Jan,\n\nDank je voor de update. Het ziet er goed uit en ik heb geen opmerkingen meer.\n\nLaat maar weten als je nog vragen hebt.\n\nGroetjes,\nDat",
            "Hi Eva,\n\nDank je voor je bericht. Ik ben er volgende week weer en dan plannen we het samen.\n\nLaat maar weten als je nog vragen hebt.\n\nGroetjes,\nDat",
            "Hi Jan,\n\nDank je voor het overleg van vandaag. Ik zet de afspraken op een rij en stuur ze je morgen.\n\nLaat maar weten als je nog vragen hebt.\n\nGroetjes,\nDat",
        ]
        for (index, body) in bodies.enumerated() {
            profile.learn(body, to: [index.isMultiple(of: 2) ? jan : eva], id: "\(index)")
        }
        return profile
    }

    @Test func learnsSentencesAddressPhrasesAndClosings() throws {
        let profile = dutchProfile()
        let dutch = try #require(profile.languages["nl"])
        #expect(dutch.addressesFormally == false)
        #expect((dutch.typicalSentence ?? 0) >= 6 && (dutch.typicalSentence ?? 99) <= 14)
        #expect(dutch.habitualPhrases.contains { $0.contains("laat maar weten") })
        #expect(dutch.habitualClosers == ["Laat maar weten als je nog vragen hebt."])
        #expect(dutch.habitualOpeners.contains("Dank je voor"))
        // Names never become phrases.
        #expect(!dutch.phrases.keys.contains { $0.contains("jan") || $0.contains("eva") })

        let guide = try #require(profile.styleGuide(for: jan, myName: "Dat", language: "nl"))
        // Someone you've written to: as you always have.
        #expect(guide.contains("You address Jan informally (je/jij)"))
        // A stranger: formally, even though everyone else gets je…
        let stranger = EmailAddress(name: "Pieter Bakker", address: "pieter@bank.example")
        let toStranger = try #require(profile.styleGuide(for: stranger, myName: "Dat", language: "nl"))
        #expect(toStranger.contains("Address Pieter formally (u)") && !toStranger.contains("You address"))
        // …unless they write informally to you.
        let theirs = WritingProfile.formality("Hoi Dat, kun je mij jouw nummer sturen?", language: "nl")
        #expect(theirs == false)
        let mirrored = try #require(profile.styleGuide(for: stranger, myName: "Dat", language: "nl", theirs: theirs))
        #expect(mirrored.contains("reply informally (je/jij)"))
        #expect(WritingProfile.formality("Geachte heer, kunt u mij uw gegevens sturen?", language: "nl") == true)
        #expect(guide.contains("Sentences are short and plain."))
        // A ceiling, never a target to pad to; no paragraph count.
        #expect(guide.contains("usually under") && !guide.contains("Keep it about") && !guide.contains("paragraphs"))
        #expect(guide.contains("\"Laat maar weten als je nog vragen hebt.\""))
        #expect(guide.contains("Don't use exclamation marks."))
    }

    @Test func aStudiedVoiceGoesAlongWithEveryDraft() throws {
        var profile = dutchProfile()
        profile.voices["nl"] = WritingProfile.Voice(text: "- Warm but brief.", by: "Claude Code · Sonnet", emails: 5)
        let guide = try #require(profile.styleGuide(for: jan, myName: "Dat", language: "nl"))
        // The study leads, and the counted phrases give way to it.
        #expect(guide.hasPrefix("How Dat writes") && guide.contains("- Warm but brief.") && !guide.contains("Phrases Dat often uses"))
        // Starting the counting over keeps the study and who was forgotten.
        profile.forget(jan.address)
        let again = profile.startedAgain
        #expect(again.voices["nl"] != nil && again.forgotten.contains(jan.address) && again.isEmpty)
        #expect(again.version == WritingProfile.currentVersion)
    }

    @Test func profilesSavedBeforeStillLoad() throws {
        let old = #"{"overall":{"greetings":{"Hi {name},":3},"signOffs":{},"lengths":[40],"messages":3,"contractions":0,"exclamations":1,"emoji":0,"dashes":0},"languages":{},"people":{},"peopleByLanguage":{},"names":{},"learned":["a"]}"#
        let profile = try JSONDecoder().decode(WritingProfile.self, from: Data(old.utf8))
        #expect(profile.overall.messages == 3 && profile.overall.usualGreeting == "Hi {name},")
        #expect(profile.version == 0 && profile.voices.isEmpty)
    }

    @Test func theStudyAsksForStyleOnlyAndFitsTheModel() {
        let samples = Array(repeating: String(repeating: "Dank je voor het sturen. ", count: 80), count: 30)
        let request = MailIntelligence.studyRequest(samples, name: "Dat", language: "nl", budget: 6_000)
        #expect(request.prompt.count < 6_000)
        #expect(request.instructions.contains("style only") && request.instructions.contains("Dutch"))
        let cleaned = MailIntelligence.cleanedStudy("Here is the voice:\n- Short sentences.\n* Uses \"top\".\nThat's all.")
        #expect(cleaned == "- Short sentences.\n- Uses \"top\".")
        #expect(AssistantProvider.claudeCode.studyModel == "sonnet")
    }
}

@Suite struct OwnWritingTests {
    @Test func outlookQuotesAndPhoneSignaturesAreNotYours() {
        let outlook = """
        Hi JP,

        Dinsdag past voor mij prima!

        Groet,
        Kaan

        Sent from Outlook for iOS
        ________________________________
        From: Recruiting <jobs@company.example>
        Sent: Monday, November 10, 2026 10:00
        To: Kaan
        Subject: Interview

        Neem gerust contact met ons op.
        """
        let own = WritingProfile.ownWriting(outlook, signature: nil)
        #expect(own.hasSuffix("Kaan") && !own.contains("Outlook") && !own.contains("contact met ons"))

        let dutch = "Top, tot dan!\n\nVan: Mondzorg <info@zorg.example>\nVerzonden: maandag 10 november\nAan: Kaan\n\nGeachte, ..."
        #expect(WritingProfile.ownWriting(dutch, signature: nil) == "Top, tot dan!")

        let wrapped = "Sounds good.\n\nOn Tue, 11 Nov 2026 at 09:12, Noor Haddad\n<noor@postbox.example> wrote:\n> Shall we?"
        #expect(WritingProfile.ownWriting(wrapped, signature: nil) == "Sounds good.")
    }

    @Test func signsWithTheNameUnderTheSignOffNotTheMailboxName() throws {
        var profile = WritingProfile()
        let jp = EmailAddress(name: "JP", address: "jp@studio.example")
        for index in 0..<3 {
            profile.learn("Hi JP,\n\nDinsdag past voor mij prima, tot dan!\n\nGroet,\nKaan", to: [jp], id: "\(index)")
        }
        let guide = try #require(profile.styleGuide(for: jp, myName: "Dat", language: "nl"))
        #expect(guide.contains("then Kaan") && !guide.contains("Dat"))
    }
}
