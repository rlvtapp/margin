import Foundation

/// The bytes a ManageSieve session reads and writes, so tests can stand in for a server.
protocol SieveTransport: Sendable {
    func write(_ text: String) async throws
    func readLine(limit: Int) async throws -> [UInt8]
    func readExactly(_ count: Int) async throws -> [UInt8]
    func startTLS() async
    func close() async
}

extension LineConnection: SieveTransport {}

/// A ManageSieve (RFC 5804) session: signs in, then lists, reads, saves and activates scripts.
actor ManageSieveClient {
    struct Response {
        var ok: Bool
        var lines: [String]
        /// Text after OK/NO/BYE, such as the server's reason.
        var message: String
    }

    let transport: SieveTransport
    private(set) var capabilities: [String: String] = [:]

    init(transport: SieveTransport) {
        self.transport = transport
    }

    /// Sieve extensions the server runs, from its SIEVE capability.
    var extensions: Set<String> {
        Set((capabilities["SIEVE"] ?? "").lowercased().split(separator: " ").map(String.init))
    }

    /// Reads the greeting, upgrades to TLS when the connection isn't already, and signs in with
    /// SASL PLAIN.
    func open(alreadySecure: Bool, username: String, password: String) async throws {
        try await readCapabilities()
        if !alreadySecure {
            guard capabilities["STARTTLS"] != nil else { throw MailError.insecureConnection }
            try await expectOK(try await command("STARTTLS"))
            await transport.startTLS()
            // The server says its capabilities again once the connection is secure.
            try await readCapabilities()
        }
        let mechanisms = (capabilities["SASL"] ?? "").uppercased().split(separator: " ")
        guard mechanisms.contains("PLAIN") else {
            throw MailError.notSupported(String(localized: "This server's rules need a sign-in Margin doesn't support."))
        }
        let token = Data("\u{0}\(username)\u{0}\(password)".utf8).base64EncodedString()
        let reply = try await command("AUTHENTICATE \"PLAIN\" \(Self.quoted(token))")
        guard reply.ok else { throw MailError.authenticationFailed(reply.message) }
        // Some servers send capabilities again after signing in.
        if reply.lines.contains(where: { $0.hasPrefix("\"") }) { record(reply.lines) }
    }

    /// Script names, and which one runs.
    func listScripts() async throws -> (names: [String], active: String?) {
        let reply = try await command("LISTSCRIPTS")
        try await expectOK(reply)
        var names: [String] = []
        var active: String?
        for line in reply.lines {
            guard let name = Self.unquote(line) else { continue }
            names.append(name)
            if line.uppercased().hasSuffix(" ACTIVE") { active = name }
        }
        return (names, active)
    }

    func getScript(_ name: String) async throws -> String {
        let reply = try await command("GETSCRIPT \(Self.quoted(name))")
        try await expectOK(reply)
        return reply.lines.joined(separator: "\r\n")
    }

    func putScript(_ name: String, _ text: String) async throws {
        let bytes = Array(text.utf8)
        let reply = try await command("PUTSCRIPT \(Self.quoted(name)) {\(bytes.count)+}\r\n" + text)
        try await expectOK(reply)
    }

    func setActive(_ name: String) async throws {
        try await expectOK(try await command("SETACTIVE \(Self.quoted(name))"))
    }

    func logout() async {
        _ = try? await command("LOGOUT")
        await transport.close()
    }

    // MARK: Lines

    private func command(_ text: String) async throws -> Response {
        try await transport.write(text + "\r\n")
        return try await readResponse()
    }

    private func expectOK(_ reply: Response) async throws {
        guard reply.ok else { throw MailError.serverRejected(reply.message.isEmpty ? String(localized: "The server refused the rules.") : reply.message) }
    }

    private func readCapabilities() async throws {
        let reply = try await readResponse()
        guard reply.ok else { throw MailError.connectionFailed(reply.message) }
        capabilities = [:]
        record(reply.lines)
    }

    private func record(_ lines: [String]) {
        for line in lines {
            let words = Self.strings(in: line)
            guard let key = words.first else { continue }
            capabilities[key.uppercased()] = words.dropFirst().joined(separator: " ")
        }
    }

    /// Lines up to OK, NO or BYE. A literal (`{n}` at a line's end) is read as one line of text.
    private func readResponse() async throws -> Response {
        var lines: [String] = []
        while true {
            var line = String(decoding: try await transport.readLine(limit: 1 << 20), as: UTF8.self)
            // "\r\n" is one Character in Swift, so trim by scalars.
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
            if let count = Self.literalLength(line) {
                let prefix = line[..<line.lastIndex(of: "{")!].trimmingCharacters(in: .whitespaces)
                let literal = String(decoding: try await transport.readExactly(count), as: UTF8.self)
                // A literal on a status line is the server's reason.
                let upper = prefix.uppercased()
                if upper.hasPrefix("NO") || upper.hasPrefix("BYE") || upper.hasPrefix("OK") {
                    _ = try await transport.readLine(limit: 1 << 20)
                    return Response(ok: upper.hasPrefix("OK"), lines: lines, message: literal)
                }
                lines.append(literal)
                continue
            }
            let upper = line.uppercased()
            for status in ["OK", "NO", "BYE"] where upper == status || upper.hasPrefix(status + " ") {
                let rest = line.dropFirst(status.count).trimmingCharacters(in: .whitespaces)
                let message = Self.strings(in: rest).last ?? rest
                return Response(ok: status == "OK", lines: lines, message: message)
            }
            if !line.isEmpty { lines.append(line) }
        }
    }

    static func literalLength(_ line: String) -> Int? {
        guard line.hasSuffix("}"), let open = line.lastIndex(of: "{") else { return nil }
        return Int(line[line.index(after: open)..<line.index(before: line.endIndex)].replacingOccurrences(of: "+", with: ""))
    }

    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func unquote(_ line: String) -> String? {
        strings(in: line).first
    }

    /// The quoted strings in a line, in order.
    static func strings(in line: String) -> [String] {
        var found: [String] = []
        var current: String?
        var escaped = false
        for character in line {
            if var text = current {
                if escaped { text.append(character); escaped = false; current = text; continue }
                if character == "\\" { escaped = true; continue }
                if character == "\"" { found.append(text); current = nil; continue }
                text.append(character)
                current = text
            } else if character == "\"" {
                current = ""
            }
        }
        return found
    }
}

// MARK: Rules over ManageSieve

/// Rules in the server's running Sieve script, edited in place so rules made elsewhere keep
/// running. With no script running yet, Margin starts one of its own.
public struct ManageSieveRules: ServerRulesAdapter {
    static let ownScript = "margin"
    let connect: @Sendable () async throws -> ManageSieveClient
    let mailboxes: [ServerFolder]
    let trashFolder: String
    let archiveFolder: String?

    /// `mailboxes` and `trashFolder` are IMAP names (modified UTF-7); Sieve names folders in UTF-8.
    public init(endpoint: ServerEndpoint, username: String, password: String, mailboxes: [ServerFolder], trashFolder: String,
                archiveFolder: String? = nil) {
        self.mailboxes = mailboxes.map { ServerFolder(id: ModifiedUTF7.decode($0.id), name: $0.name) }
        self.trashFolder = ModifiedUTF7.decode(trashFolder)
        self.archiveFolder = archiveFolder.map(ModifiedUTF7.decode)
        connect = {
            // ManageSieve listens on its own port and secures the connection with STARTTLS.
            let plain = ServerEndpoint(host: endpoint.host, port: endpoint.port, security: endpoint.security == .tls ? .tls : .startTLS)
            let connection = try LineConnection(endpoint: plain, timeout: 15)
            let client = ManageSieveClient(transport: connection)
            try await client.open(alreadySecure: plain.security == .tls, username: username, password: password)
            return client
        }
    }

    init(mailboxes: [ServerFolder], trashFolder: String, archiveFolder: String? = nil,
         connect: @escaping @Sendable () async throws -> ManageSieveClient) {
        self.mailboxes = mailboxes
        self.trashFolder = trashFolder
        self.archiveFolder = archiveFolder
        self.connect = connect
    }

    /// Where ManageSieve usually is for an IMAP server: the same host, port 4190.
    public static func endpoint(for imap: ServerEndpoint) -> ServerEndpoint {
        ServerEndpoint(host: imap.host, port: 4190, security: imap.security == .plain ? .plain : .startTLS)
    }

    public func features() async throws -> ServerRuleFeatures {
        ServerRuleFeatures(archive: archiveFolder != nil, canDisable: true)
    }

    public func rules() async throws -> [ServerRule] {
        try await session { client in try await read(client).script.rules }
    }

    public func folders() async throws -> [ServerFolder] { mailboxes }

    public func save(_ rule: ServerRule) async throws -> ServerRule {
        try await session { client in
            var (name, script) = try await read(client)
            script.put(rule)
            try await write(script, as: name, client: client)
            return script.rules.first { $0.id == rule.id } ?? script.rules.last ?? rule
        }
    }

    public func delete(_ rule: ServerRule) async throws {
        try await session { client in
            var (name, script) = try await read(client)
            script.remove(id: rule.id)
            try await write(script, as: name, client: client)
        }
    }

    private func session<T: Sendable>(_ work: (ManageSieveClient) async throws -> T) async throws -> T {
        let client = try await connect()
        do {
            let result = try await work(client)
            await client.logout()
            return result
        } catch {
            await client.logout()
            throw error
        }
    }

    /// The running script, or a new one of Margin's own.
    private func read(_ client: ManageSieveClient) async throws -> (name: String, script: SieveScript) {
        let list = try await client.listScripts()
        guard let active = list.active else { return (Self.ownScript, SieveScript()) }
        return (active, SieveScript(parsing: try await client.getScript(active), trashFolder: trashFolder, archiveFolder: archiveFolder))
    }

    private func write(_ script: SieveScript, as name: String, client: ManageSieveClient) async throws {
        let text = script.text(options: SieveScript.Options(extensions: await client.extensions, trashFolder: trashFolder, archiveFolder: archiveFolder))
        try await client.putScript(name, text)
        // PUTSCRIPT to the running script takes effect at once; a new one has to be switched on.
        let active = try await client.listScripts().active
        if active != name { try await client.setActive(name) }
    }
}
