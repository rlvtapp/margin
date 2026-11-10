import Foundation

/// Finds server settings for an address, using open conventions in this order:
/// 1. the built-in catalog,
/// 2. JMAP discovery on the domain (`/.well-known/jmap`, RFC 8620 §2.2),
/// 3. the domain's own autoconfig file (the Thunderbird format),
/// 4. the public ISP database, asked about the domain only, never the address.
public struct AutoConfig: Sendable {
    public enum Result: Sendable, Equatable {
        case preset(ProviderPreset)
        case discovered(AccountConnection)
        case notFound
    }

    private let http: URLSession

    public init(http: URLSession = .shared) { self.http = http }

    public func lookup(address: String) async -> Result {
        guard let domain = address.split(separator: "@").last.map({ String($0).lowercased() }), domain.contains(".") else {
            return .notFound
        }
        if let preset = ProviderCatalog.preset(forDomain: domain) { return .preset(preset) }
        if let jmap = await jmapSession(domain: domain) { return .discovered(.jmap(sessionURL: jmap)) }
        let sources = [
            "https://autoconfig.\(domain)/mail/config-v1.1.xml",
            "https://\(domain)/.well-known/autoconfig/mail/config-v1.1.xml",
            "https://autoconfig.thunderbird.net/v1.1/\(domain)",
        ]
        for source in sources {
            guard let url = URL(string: source), let data = await fetch(url),
                  let connection = AutoConfigXML.parse(data) else { continue }
            return .discovered(connection)
        }
        return .notFound
    }

    /// The usual guess when nothing is published: imap.domain and smtp.domain.
    public static func guess(domain: String) -> AccountConnection {
        .imap(
            incoming: ServerEndpoint(host: "imap.\(domain)", port: 993, security: .tls),
            outgoing: ServerEndpoint(host: "smtp.\(domain)", port: 465, security: .tls)
        )
    }

    private func jmapSession(domain: String) async -> URL? {
        guard let url = URL(string: "https://\(domain)/.well-known/jmap") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.httpMethod = "GET"
        guard let (_, response) = try? await http.data(for: request), let http = response as? HTTPURLResponse else { return nil }
        // An unauthenticated request gets 401 from a real JMAP server; redirects are followed.
        guard http.statusCode == 401 || http.statusCode == 200 else { return nil }
        return http.url ?? url
    }

    private func fetch(_ url: URL) async -> Data? {
        let request = URLRequest(url: url, timeoutInterval: 6)
        guard let (data, response) = try? await http.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}

/// Reads `clientConfig` XML: the first IMAP incoming server and the first SMTP outgoing one.
enum AutoConfigXML {
    static func parse(_ data: Data) -> AccountConnection? {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), let imap = delegate.imap, let smtp = delegate.smtp else { return nil }
        return .imap(incoming: imap, outgoing: smtp)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var imap: ServerEndpoint?
        var smtp: ServerEndpoint?
        private var kind: String?
        private var fields: [String: String] = [:]
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            if name == "incomingServer" || name == "outgoingServer" {
                kind = attributes["type"]
                fields = [:]
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "hostname", "port", "socketType": fields[name] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            case "incomingServer" where kind == "imap" && imap == nil: imap = endpoint()
            case "outgoingServer" where kind == "smtp" && smtp == nil: smtp = endpoint()
            default: break
            }
        }

        private func endpoint() -> ServerEndpoint? {
            guard let host = fields["hostname"], let port = fields["port"].flatMap(Int.init) else { return nil }
            let security: ConnectionSecurity = switch fields["socketType"]?.uppercased() {
            case "SSL": .tls
            case "STARTTLS": .startTLS
            default: .plain
            }
            let endpoint = ServerEndpoint(host: host, port: port, security: security)
            // Never accept a published plain-text server.
            return endpoint.isAllowed ? endpoint : nil
        }
    }
}
