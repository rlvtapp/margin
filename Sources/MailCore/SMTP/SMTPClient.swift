import Foundation

/// An ESMTP submission session (RFC 6409): implicit TLS on 465 or STARTTLS on 587.
actor SMTPClient {
    private let connection: LineConnection
    private var extensions: Set<String> = []
    private var authMechanisms: Set<String> = []

    init(endpoint: ServerEndpoint) throws {
        connection = try LineConnection(endpoint: endpoint)
    }

    func open(security: ConnectionSecurity) async throws {
        try expect(try await reply(), 220)
        try await hello()
        if security == .startTLS {
            guard extensions.contains("STARTTLS") else {
                throw MailError.connectionFailed(String(localized: "The server doesn't offer STARTTLS."))
            }
            try expect(try await command("STARTTLS"), 220)
            await connection.startTLS()
            try await hello() // capabilities change after TLS (RFC 3207 §4.2)
        }
    }

    func authenticate(username: String, password: String) async throws {
        if authMechanisms.contains("PLAIN") || authMechanisms.isEmpty {
            let response = try await command("AUTH PLAIN \(SASL.plain(username: username, password: password))")
            try expectAuth(response)
        } else if authMechanisms.contains("LOGIN") {
            try expect(try await command("AUTH LOGIN"), 334)
            try expect(try await command(Data(username.utf8).base64EncodedString()), 334)
            try expectAuth(try await command(Data(password.utf8).base64EncodedString()))
        } else {
            throw MailError.authenticationFailed(String(localized: "The server offers no password sign-in."))
        }
    }

    func authenticate(username: String, accessToken: String) async throws {
        let usesBearer = authMechanisms.contains("OAUTHBEARER") && !authMechanisms.contains("XOAUTH2")
        let line = usesBearer
            ? "AUTH OAUTHBEARER \(SASL.oauthBearer(username: username, accessToken: accessToken))"
            : "AUTH XOAUTH2 \(SASL.xoauth2(username: username, accessToken: accessToken))"
        var response = try await command(line)
        if response.code == 334 {
            // The server sent an error challenge; an empty line ends the exchange.
            response = try await command("")
        }
        try expectAuth(response)
    }

    func send(from sender: String, to recipients: [String], message: [UInt8]) async throws {
        guard !recipients.isEmpty else { throw MailError.invalidAddress("") }
        for address in [sender] + recipients where address.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "<" || $0 == ">" }) {
            throw MailError.invalidAddress(address)
        }
        let utf8 = extensions.contains("SMTPUTF8") && (sender + recipients.joined()).unicodeScalars.contains { !$0.isASCII }
        try expect(try await command("MAIL FROM:<\(sender)>\(utf8 ? " SMTPUTF8" : "")"), 250)
        for recipient in recipients {
            let response = try await command("RCPT TO:<\(recipient)>")
            guard response.code == 250 || response.code == 251 else {
                throw MailError.serverRejected("\(recipient): \(response.text)")
            }
        }
        try expect(try await command("DATA"), 354)
        try await connection.write(Self.dotStuffed(message) + Array(".\r\n".utf8))
        try expect(try await reply(), 250)
    }

    func quit() async {
        _ = try? await command("QUIT")
        await connection.close()
    }

    // MARK: Protocol

    struct Reply: Sendable {
        var code: Int
        var lines: [String]
        var text: String { lines.joined(separator: " ") }
    }

    private func hello() async throws {
        let response = try await command("EHLO \(Self.clientName)")
        try expect(response, 250)
        extensions = []
        authMechanisms = []
        for line in response.lines.dropFirst() {
            let words = line.uppercased().split(separator: " ").map(String.init)
            guard let keyword = words.first else { continue }
            extensions.insert(keyword)
            if keyword == "AUTH" { authMechanisms = Set(words.dropFirst()) }
        }
    }

    private func command(_ line: String) async throws -> Reply {
        try await connection.write(line + "\r\n")
        return try await reply()
    }

    /// Reads a possibly multi-line reply (`250-…` lines then `250 …`).
    private func reply() async throws -> Reply {
        var lines: [String] = []
        while true {
            let raw = String(decoding: try await connection.readLine(limit: 64 * 1024), as: UTF8.self)
                .trimmingCharacters(in: .newlines)
            guard raw.count >= 3, let code = Int(raw.prefix(3)) else {
                throw MailError.protocolViolation("Malformed SMTP reply.")
            }
            lines.append(raw.count > 4 ? String(raw.dropFirst(4)) : "")
            if raw.count == 3 || raw[raw.index(raw.startIndex, offsetBy: 3)] == " " {
                return Reply(code: code, lines: lines)
            }
        }
    }

    private func expect(_ reply: Reply, _ code: Int) throws {
        guard reply.code == code else { throw MailError.serverRejected("\(reply.code) \(reply.text)") }
    }

    private func expectAuth(_ reply: Reply) throws {
        guard reply.code == 235 else { throw MailError.authenticationFailed("\(reply.code) \(reply.text)") }
    }

    /// Lines that start with "." get another "." (RFC 5321 §4.5.2); ends with CRLF.
    static func dotStuffed(_ message: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(message.count + 64)
        var atLineStart = true
        for byte in message {
            if atLineStart && byte == UInt8(ascii: ".") { out.append(UInt8(ascii: ".")) }
            out.append(byte)
            atLineStart = byte == 0x0A
        }
        if !out.suffix(2).elementsEqual([0x0D, 0x0A]) { out += [0x0D, 0x0A] }
        return out
    }

    static let clientName = "localhost"
}
