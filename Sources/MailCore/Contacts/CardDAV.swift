import Foundation

/// Reads address books from a CardDAV server (RFC 6352) with a username and password.
public struct CardDAVClient: Sendable {
    /// Sends one request and returns the body and response. Redirects should come back unfollowed.
    public typealias Send = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let serverText: String
    private let username: String
    private let password: String
    private let send: Send

    /// The server is what the person typed: a domain, a host, or a full address book URL.
    public init(server: String, username: String, password: String, send: Send? = nil) {
        self.serverText = server
        self.username = username
        self.password = password
        self.send = send ?? Self.urlSession
    }

    /// Finds the address books this account can read.
    public func addressBooks() async throws -> [URL] {
        guard let server = Self.serverURL(serverText) else {
            throw MailError.connectionFailed(String(localized: "“\(serverText)” isn't a server address."))
        }
        let starts: [URL]
        if server.path.isEmpty || server.path == "/" {
            starts = [server.appending(path: ".well-known/carddav"), server.appending(path: "/")]
        } else {
            starts = [server]
        }

        var lastError: Error?
        for start in starts {
            let resource: (url: URL, response: DAVResponse)
            do {
                let (base, responses) = try await propfind(start, depth: "0", body: Self.discoveryBody)
                guard let first = responses.first else { continue }
                resource = (base, first)
            } catch let error as MailError {
                if case .authenticationFailed = error { throw error }
                if case .insecureConnection = error { throw error }
                lastError = error
                continue
            }

            if resource.response.resourceTypes.contains("addressbook") {
                return [resource.response.href.flatMap { URL(string: $0, relativeTo: resource.url)?.absoluteURL } ?? resource.url]
            }
            if let home = resource.response.homeSet(relativeTo: resource.url) {
                return try await books(in: home)
            }
            if let principal = resource.response.principal(relativeTo: resource.url) {
                let (base, responses) = try await propfind(principal, depth: "0", body: Self.homeBody)
                if let home = responses.lazy.compactMap({ $0.homeSet(relativeTo: base) }).first {
                    return try await books(in: home)
                }
            }
            // A server without principals may still list address books under the given path.
            if start == server, let books = try? await books(in: resource.url), !books.isEmpty { return books }
        }
        throw lastError ?? MailError.notSupported(String(localized: "No address books were found on this server."))
    }

    /// Every card in one address book.
    public func contacts(in book: URL) async throws -> [Contact] {
        let (base, responses) = try await request(book, method: "REPORT", depth: "1", body: Self.queryBody)
        return Self.contacts(from: responses, base: base)
    }

    /// Every card in every address book, each contact once.
    public func allContacts() async throws -> [Contact] {
        var seen = Set<String>()
        var result: [Contact] = []
        for book in try await addressBooks() {
            for contact in try await contacts(in: book) where seen.insert(contact.id).inserted {
                result.append(contact)
            }
        }
        return result
    }

    // MARK: - Discovery steps

    private func books(in home: URL) async throws -> [URL] {
        let (base, responses) = try await propfind(home, depth: "1", body: Self.listBody)
        var books: [URL] = []
        for response in responses where response.resourceTypes.contains("addressbook") {
            guard let href = response.href, let url = URL(string: href, relativeTo: base)?.absoluteURL else { continue }
            if !books.contains(url) { books.append(url) }
        }
        return books
    }

    private func propfind(_ url: URL, depth: String, body: String) async throws -> (URL, [DAVResponse]) {
        try await request(url, method: "PROPFIND", depth: depth, body: body)
    }

    // MARK: - Requests

    /// Sends a WebDAV request, following up to five redirects, and parses the multistatus answer.
    /// Returns the URL that finally answered, for resolving relative hrefs.
    private func request(_ url: URL, method: String, depth: String, body: String) async throws -> (URL, [DAVResponse]) {
        var target = url
        for _ in 0..<6 {
            try Self.checkSecure(target)
            var request = URLRequest(url: target, timeoutInterval: 30)
            request.httpMethod = method
            request.httpBody = Data(body.utf8)
            request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue(depth, forHTTPHeaderField: "Depth")
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await send(request)
            let status = response.statusCode
            if (300..<400).contains(status), let location = response.value(forHTTPHeaderField: "Location"),
               let next = URL(string: location, relativeTo: target)?.absoluteURL {
                if target.scheme == "https", next.scheme != "https" { throw MailError.insecureConnection }
                target = next
                continue
            }
            if status == 401 {
                throw MailError.authenticationFailed(String(localized: "Check the username and password for this address book."))
            }
            guard (200..<300).contains(status) else {
                throw MailError.serverRejected(String(localized: "The address book server answered \(status) for \(target.path)."))
            }
            return (response.url ?? target, MultistatusParser.parse(data))
        }
        throw MailError.serverRejected(String(localized: "The address book server redirected too many times."))
    }

    static func contacts(from responses: [DAVResponse], base: URL) -> [Contact] {
        var result: [Contact] = []
        for response in responses {
            guard let href = response.href, let data = response.addressData,
                  let card = VCard.parse(data).first else { continue }
            result.append(card.contact(id: "carddav:" + href, source: .carddav))
        }
        return result
    }

    private static func checkSecure(_ url: URL) throws {
        guard url.scheme?.lowercased() != "https" else { return }
        let host = url.host()?.lowercased() ?? ""
        guard ["localhost", "127.0.0.1", "::1"].contains(host) else { throw MailError.insecureConnection }
    }

    /// Adds https:// when no scheme is given.
    static func serverURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let full = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: full), url.host() != nil else { return nil }
        return url
    }

    private static let urlSession: Send = { request in
        let (data, response) = try await URLSession.shared.data(for: request, delegate: RedirectHolder.shared)
        guard let http = response as? HTTPURLResponse else {
            throw MailError.protocolViolation(String(localized: "The answer wasn't HTTP."))
        }
        return (data, http)
    }

    // MARK: - Bodies

    private static let header = #"<?xml version="1.0" encoding="utf-8"?>"#

    static let discoveryBody = header + """
    <d:propfind xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav"><d:prop>\
    <d:resourcetype/><d:current-user-principal/><card:addressbook-home-set/>\
    </d:prop></d:propfind>
    """

    static let homeBody = header + """
    <d:propfind xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav"><d:prop>\
    <card:addressbook-home-set/>\
    </d:prop></d:propfind>
    """

    static let listBody = header + """
    <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:displayname/></d:prop></d:propfind>
    """

    /// FN is required on every card, so this filter matches all of them.
    static let queryBody = header + """
    <card:addressbook-query xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">\
    <d:prop><d:getetag/><card:address-data/></d:prop>\
    <card:filter test="anyof"><card:prop-filter name="FN"/><card:prop-filter name="EMAIL"/></card:filter>\
    </card:addressbook-query>
    """
}

/// Hands redirects back to the client so it can repeat the same method with the same sign-in.
private final class RedirectHolder: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = RedirectHolder()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

/// One `response` from a WebDAV multistatus, with the properties a successful propstat returned.
struct DAVResponse: Equatable, Sendable {
    var href: String?
    var resourceTypes: Set<String> = []
    var principalHref: String?
    var homeSetHref: String?
    var addressData: String?

    func principal(relativeTo base: URL) -> URL? {
        principalHref.flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }
    }

    func homeSet(relativeTo base: URL) -> URL? {
        homeSetHref.flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }
    }
}

/// Parses a WebDAV multistatus body by element local name.
final class MultistatusParser: NSObject, XMLParserDelegate {
    private var responses: [DAVResponse] = []
    private var current: DAVResponse?
    private var pending = DAVResponse()
    private var pendingStatus: String?
    private var stack: [String] = []
    private var text = ""

    static func parse(_ data: Data) -> [DAVResponse] {
        let delegate = MultistatusParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.responses
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = Self.localName(elementName)
        if stack.last == "resourcetype" { pending.resourceTypes.insert(name) }
        stack.append(name)
        text = ""
        switch name {
        case "response": current = DAVResponse()
        case "propstat": pending = DAVResponse(); pendingStatus = nil
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = Self.localName(elementName)
        let parent = stack.count >= 2 ? stack[stack.count - 2] : nil
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "href":
            switch parent {
            case "response": current?.href = value
            case "current-user-principal": pending.principalHref = value
            case "addressbook-home-set": pending.homeSetHref = pending.homeSetHref ?? value
            default: break
            }
        case "status" where parent == "propstat":
            pendingStatus = value
        case "address-data":
            pending.addressData = text
        case "propstat":
            if Self.isSuccess(pendingStatus), var response = current {
                response.resourceTypes.formUnion(pending.resourceTypes)
                response.principalHref = response.principalHref ?? pending.principalHref
                response.homeSetHref = response.homeSetHref ?? pending.homeSetHref
                response.addressData = response.addressData ?? pending.addressData
                current = response
            }
        case "response":
            if let current { responses.append(current) }
            current = nil
        default:
            break
        }
        text = ""
        stack.removeLast()
    }

    /// A propstat without a status line counts as success.
    private static func isSuccess(_ status: String?) -> Bool {
        guard let status else { return true }
        let parts = status.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[1]) else { return true }
        return (200..<300).contains(code)
    }

    private static func localName(_ name: String) -> String {
        (name.split(separator: ":").last.map(String.init) ?? name).lowercased()
    }
}
