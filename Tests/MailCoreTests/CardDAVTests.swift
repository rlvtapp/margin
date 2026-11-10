import Foundation
import Testing
@testable import MailCore

@Suite struct VCardTests {
    @Test func unfoldsLinesAndReadsNameEmailsAndOrganization() {
        let text = "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:abc-1\r\nFN:Noor\r\n  Haddad\r\nN:Haddad;Noor;;;\r\n"
            + "EMAIL;TYPE=work:noor@postbox.example\r\nemail;type=home:noor@home.example\r\n"
            + "ORG:Postbox\\, Ltd;Design\r\nEND:VCARD\r\n"
        let cards = VCard.parse(text)
        #expect(cards.count == 1)
        #expect(cards[0].uid == "abc-1")
        #expect(cards[0].name == "Noor Haddad")
        #expect(cards[0].emails == ["noor@postbox.example", "noor@home.example"])
        #expect(cards[0].organization == "Postbox, Ltd")
    }

    @Test func fallsBackToStructuredName() {
        let text = "BEGIN:VCARD\nVERSION:4.0\nN:Vos;Nick;;Dr.;\nEMAIL:nick@vos.example\nEND:VCARD\n"
        #expect(VCard.parse(text).first?.name == "Nick Vos")
    }

    @Test func readsGroupedEmailsAndEscapes() {
        let text = """
        BEGIN:VCARD
        VERSION:3.0
        FN:Sam\\; Kim\\nJr
        item1.EMAIL;type=INTERNET;type=pref:sam@k.example
        item1.X-ABLabel:_$!<Work>!$_
        item2.EMAIL:mailto:sam@other.example
        NOTE;LANGUAGE="en:us":A note: with colons
        END:VCARD
        """
        let card = VCard.parse(text).first
        #expect(card?.name == "Sam; Kim\nJr")
        #expect(card?.emails == ["sam@k.example", "sam@other.example"])
    }

    @Test func readsSeveralCardsInOneText() {
        let text = """
        BEGIN:VCARD
        VERSION:4.0
        FN:Alex
        EMAIL:alex@example.com
        END:VCARD
        BEGIN:VCARD
        VERSION:4.0
        FN:Bea
        EMAIL:bea@example.com
        END:VCARD
        """
        let cards = VCard.parse(text)
        #expect(cards.map(\.name) == ["Alex", "Bea"])
        #expect(cards.map(\.emails) == [["alex@example.com"], ["bea@example.com"]])
    }
}

/// Answers by method and path; anything else is a 404.
private struct FakeDAV: Sendable {
    struct Answer: Sendable {
        var status: Int
        var body: String = ""
        var headers: [String: String] = [:]
    }

    var routes: [String: Answer]

    var send: CardDAVClient.Send {
        let routes = routes
        return { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("me:secret".utf8).base64EncodedString())
            let key = "\(request.httpMethod ?? "GET") \(request.url?.path() ?? "")"
            let answer = routes[key] ?? Answer(status: 404)
            let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                           headerFields: answer.headers)!
            return (Data(answer.body.utf8), response)
        }
    }
}

private func multistatus(_ responses: String) -> String {
    #"<?xml version="1.0" encoding="utf-8"?><d:multistatus xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">"#
        + responses + "</d:multistatus>"
}

@Suite struct CardDAVTests {
    @Test func discoversAddressBooksFromTheDomain() async throws {
        let dav = FakeDAV(routes: [
            "PROPFIND /.well-known/carddav": .init(status: 301, headers: ["Location": "/dav/"]),
            "PROPFIND /dav/": .init(status: 207, body: multistatus("""
                <d:response><d:href>/dav/</d:href><d:propstat><d:prop>
                <d:current-user-principal><d:href>/dav/principals/me/</d:href></d:current-user-principal>
                </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
                <d:propstat><d:prop><card:addressbook-home-set/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>
                </d:response>
                """)),
            "PROPFIND /dav/principals/me/": .init(status: 207, body: multistatus("""
                <d:response><d:href>/dav/principals/me/</d:href><d:propstat><d:prop>
                <card:addressbook-home-set><d:href>https://cards.example/home/me/</d:href></card:addressbook-home-set>
                </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
                """)),
            "PROPFIND /home/me/": .init(status: 207, body: multistatus("""
                <d:response><d:href>/home/me/</d:href><d:propstat><d:prop>
                <d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
                <d:response><d:href>default/</d:href><d:propstat><d:prop>
                <d:resourcetype><d:collection/><card:addressbook/></d:resourcetype><d:displayname>Contacts</d:displayname>
                </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
                <d:response><d:href>/home/me/work/</d:href><d:propstat><d:prop>
                <d:resourcetype><d:collection/><C:addressbook xmlns:C="urn:ietf:params:xml:ns:carddav"/></d:resourcetype>
                </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
                """)),
        ])
        let client = CardDAVClient(server: "cards.example", username: "me", password: "secret", send: dav.send)
        let books = try await client.addressBooks()
        #expect(books.map(\.absoluteString) == ["https://cards.example/home/me/default/", "https://cards.example/home/me/work/"])
    }

    @Test func returnsTheGivenURLWhenItIsAnAddressBook() async throws {
        let dav = FakeDAV(routes: [
            "PROPFIND /books/main/": .init(status: 207, body: multistatus("""
                <d:response><d:href>/books/main/</d:href><d:propstat><d:prop>
                <d:resourcetype><d:collection/><card:addressbook/></d:resourcetype>
                </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
                """)),
        ])
        let client = CardDAVClient(server: "https://cards.example/books/main/", username: "me", password: "secret", send: dav.send)
        #expect(try await client.addressBooks().map(\.absoluteString) == ["https://cards.example/books/main/"])
    }

    @Test func readsCardsFromAnAddressBookQuery() async throws {
        let dav = FakeDAV(routes: [
            "REPORT /home/me/default/": .init(status: 207, body: multistatus("""
                <d:response><d:href>/home/me/default/noor.vcf</d:href><d:propstat><d:prop>
                <d:getetag>"1"</d:getetag>
                <card:address-data>BEGIN:VCARD&#13;
                VERSION:3.0&#13;
                FN:Noor Haddad&#13;
                EMAIL;TYPE=work:noor@postbox.example&#13;
                ORG:Postbox;Design&#13;
                END:VCARD&#13;
                </card:address-data></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
                <d:response><d:href>/home/me/default/nick.vcf</d:href><d:propstat><d:prop>
                <d:getetag>"2"</d:getetag>
                <card:address-data><![CDATA[BEGIN:VCARD
                VERSION:4.0
                N:Vos;Nick;;;
                EMAIL:nick@vos.example
                END:VCARD]]></card:address-data></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
                """)),
        ])
        let client = CardDAVClient(server: "https://cards.example", username: "me", password: "secret", send: dav.send)
        let contacts = try await client.contacts(in: URL(string: "https://cards.example/home/me/default/")!)
        #expect(contacts == [
            Contact(id: "carddav:/home/me/default/noor.vcf", name: "Noor Haddad", emails: ["noor@postbox.example"],
                    organization: "Postbox", source: .carddav),
            Contact(id: "carddav:/home/me/default/nick.vcf", name: "Nick Vos", emails: ["nick@vos.example"], source: .carddav),
        ])
    }

    @Test func refusedSignInIsAnAuthenticationError() async throws {
        let dav = FakeDAV(routes: [
            "PROPFIND /.well-known/carddav": .init(status: 401),
        ])
        let client = CardDAVClient(server: "cards.example", username: "me", password: "secret", send: dav.send)
        await #expect {
            try await client.addressBooks()
        } throws: { error in
            if case .authenticationFailed = error as? MailError { return true }
            return false
        }
    }

    @Test func refusesPlainHTTPToOtherHosts() async throws {
        let client = CardDAVClient(server: "http://cards.example/books/", username: "me", password: "secret",
                                       send: FakeDAV(routes: [:]).send)
        await #expect(throws: MailError.insecureConnection) { try await client.addressBooks() }
    }
}
