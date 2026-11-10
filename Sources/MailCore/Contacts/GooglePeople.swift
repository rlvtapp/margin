import Foundation

/// Contacts from a Google account through the People API: saved contacts, then "other contacts"
/// (people the account has written to). The caller signs in and passes the access token.
public struct GooglePeopleClient: Sendable {
    public static let base = URL(string: "https://people.googleapis.com/v1")!

    let http: BearerHTTP

    public init(
        accessToken: String,
        send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = BearerHTTP.urlSession
    ) {
        http = BearerHTTP(token: accessToken, send: send)
    }

    /// The account's contacts and other contacts, one entry per address.
    public func contacts() async throws -> [Contact] {
        let saved: [GooglePerson] = try await pages(
            "\(Self.base)/people/me/connections?personFields=names,emailAddresses,organizations&pageSize=1000", key: \.connections)
        let other: [GooglePerson] = try await pages(
            "\(Self.base)/otherContacts?readMask=names,emailAddresses&pageSize=1000", key: \.otherContacts)
        return Contact.mergedByEmail((saved + other).map { person in
            Contact(id: "google:\(person.resourceName)", name: person.names?.first?.displayName,
                    emails: person.emailAddresses?.compactMap(\.value) ?? [],
                    organization: person.organizations?.first?.name, source: .google)
        })
    }

    func pages(_ first: String, key: KeyPath<GooglePage, [GooglePerson]?>) async throws -> [GooglePerson] {
        var people: [GooglePerson] = []
        var token: String?
        var pageCount = 0
        repeat {
            guard var components = URLComponents(string: first) else { break }
            if let token {
                components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "pageToken", value: token)]
                components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            }
            guard let url = components.url else { break }
            let page = try BearerHTTP.decode(GooglePage.self, from: try await http.data(for: http.request(url)))
            people += page[keyPath: key] ?? []
            token = page.nextPageToken?.nilIfEmpty
            pageCount += 1
        } while token != nil && people.count < MicrosoftGraphClient.contactLimit && pageCount < 100
        return Array(people.prefix(MicrosoftGraphClient.contactLimit))
    }
}

// MARK: People API shapes

struct GooglePage: Decodable {
    var connections: [GooglePerson]?
    var otherContacts: [GooglePerson]?
    var nextPageToken: String?
}

struct GooglePerson: Decodable {
    var resourceName: String
    var names: [Name]?
    var emailAddresses: [Email]?
    var organizations: [Organization]?

    struct Name: Decodable { var displayName: String? }
    struct Email: Decodable { var value: String? }
    struct Organization: Decodable { var name: String? }
}
