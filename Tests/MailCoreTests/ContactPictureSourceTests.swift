import Foundation
import Testing
@testable import MailCore

/// Where each address book says a person's picture is.
@Suite struct ContactPictureSourceTests {
    @Test func googleGivesItsOwnPhotosButNotTheMadeUpOnes() async throws {
        let api = GraphFakeAPI()
        api.on("/people/me/connections", #"""
        {"connections":[
          {"resourceName":"people/1","names":[{"displayName":"Noor Haddad"}],"emailAddresses":[{"value":"noor@postbox.example"}],
           "photos":[{"url":"https://lh3.googleusercontent.com/a/noor=s100"}]},
          {"resourceName":"people/2","names":[{"displayName":"Sam Lee"}],"emailAddresses":[{"value":"sam@k.example"}],
           "photos":[{"url":"https://lh3.googleusercontent.com/a/letter=s100","default":true}]}]}
        """#)
        api.on("/otherContacts", #"{"otherContacts":[]}"#)
        let contacts = try await GooglePeopleClient(accessToken: "t", send: api.send).contacts()
        #expect(contacts[0].picture == .url("https://lh3.googleusercontent.com/a/noor=s100"))
        #expect(contacts[1].picture == nil)
        // Photos are asked for with the rest.
        #expect(api.urls().allSatisfy { $0.contains("photos") })
    }

    @Test func microsoftContactsAndColleaguesSayWhereTheirPictureIs() async throws {
        let api = GraphFakeAPI()
        api.on("/me/contacts", #"{"value":[{"id":"c1","displayName":"Noor","emailAddresses":[{"address":"noor@postbox.example"}]}]}"#)
        api.on("/me/people", #"{"value":[{"id":"p2","displayName":"Nick","scoredEmailAddresses":[{"address":"nick@vos.example"}]}]}"#)
        let contacts = try await MicrosoftGraphClient(accessToken: "t", send: api.send).contacts()
        #expect(contacts[0].picture == .microsoftContact("c1"))
        #expect(contacts[1].picture == .microsoftUser("nick@vos.example"))
    }

    @Test func microsoftPicturesComeThroughGraphAndMissingOnesAreNil() async throws {
        let api = GraphFakeAPI()
        api.on("/me/contacts/c1/photo/$value", "JPEGBYTES")
        let client = MicrosoftGraphClient(accessToken: "t", send: api.send)
        #expect(try await client.picture(.microsoftContact("c1")) == Data("JPEGBYTES".utf8))
        // No photo, or a personal account with no directory: nothing, not an error.
        #expect(try await client.picture(.microsoftUser("nick@vos.example")) == nil)
        #expect(api.urls().last?.contains("/users/nick@vos.example/photo/$value") == true)
        #expect(try await client.picture(.url("https://example.com/a.jpg")) == nil)
    }

    @Test func vCardsCarryTheirPictureEitherWay() {
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02])
        let base64 = bytes.base64EncodedString()
        let three = VCard.parse("BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Noor\r\nEMAIL:noor@postbox.example\r\nPHOTO;ENCODING=b;TYPE=JPEG:\(base64)\r\nEND:VCARD\r\n")
        #expect(three.first?.photo == bytes)
        let four = VCard.parse("BEGIN:VCARD\nVERSION:4.0\nFN:Sam\nEMAIL:sam@k.example\nPHOTO:data:image/jpeg;base64,\(base64)\nEND:VCARD\n")
        #expect(four.first?.photo == bytes)
        let linked = VCard.parse("BEGIN:VCARD\nVERSION:4.0\nFN:Nick\nEMAIL:nick@vos.example\nPHOTO;VALUE=uri:https://cards.example/nick.jpg\nEND:VCARD\n")
        #expect(linked.first?.photo == nil)
        #expect(linked.first?.contact(id: "carddav:1", source: .carddav).picture == .url("https://cards.example/nick.jpg"))
        #expect(three.first?.contact(id: "carddav:2", source: .carddav).pictureData == bytes)
    }

    @Test func theContactsListKeepsTheNoteNotThePicture() throws {
        let contact = Contact(id: "system:1", name: "Noor", emails: ["noor@postbox.example"], source: .system,
                              picture: .saved, pictureData: Data(repeating: 7, count: 4000))
        let stored = try JSONEncoder().encode([contact])
        #expect(stored.count < 300)
        let back = try JSONDecoder().decode([Contact].self, from: stored)
        #expect(back.first?.picture == .saved)
        #expect(back.first?.pictureData == nil)
        // A list saved before pictures existed still reads.
        let old = Data(#"[{"id":"google:1","name":"Sam","emails":["sam@k.example"],"source":"google"}]"#.utf8)
        #expect(try JSONDecoder().decode([Contact].self, from: old).first?.picture == nil)
    }
}
