import Foundation
import Network

/// MCP's Streamable HTTP transport, served on 127.0.0.1 only. Every request must carry the
/// bearer token, and browsers are turned away by the Origin check (which guards against
/// DNS rebinding). One JSON-RPC message per POST; replies are plain JSON.
public final class MCPHTTPServer: @unchecked Sendable {
    public let port: UInt16
    private let token: String
    private let server: MCPServer
    private let queue = DispatchQueue(label: "margin.mcp")
    private var listener: NWListener?

    public init(port: UInt16, token: String, server: MCPServer) {
        self.port = port
        self.token = token
        self.server = server
    }

    public func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.read(connection, buffer: Data())
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            let buffer = buffer + (data ?? Data())
            if let request = HTTPRequest(buffer) {
                Task { await self.respond(to: request, on: connection) }
            } else if complete || error != nil || buffer.count > 4 << 20 {
                connection.cancel()
            } else {
                self.read(connection, buffer: buffer)
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) async {
        let reply: (Int, Data?)
        if let origin = request.headers["origin"], !Self.isLocal(origin) {
            reply = (403, Data("Forbidden".utf8))
        } else if !Self.constantTimeEqual(request.headers["authorization"] ?? "", "Bearer \(token)") {
            reply = (401, Data("Unauthorized".utf8))
        } else if request.path.split(separator: "?").first != "/mcp" {
            reply = (404, nil)
        } else if request.method == "POST" {
            if let body = await server.handle(request.body) { reply = (200, body) } else { reply = (202, nil) }
        } else {
            reply = (405, nil) // No server-sent stream: this server never pushes.
        }
        send(reply.0, body: reply.1, on: connection)
    }

    private func send(_ status: Int, body: Data?, on connection: NWConnection) {
        let reason = [200: "OK", 202: "Accepted", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body?.count ?? 0)\r\nConnection: close\r\n"
        if status == 200 { head += "Content-Type: application/json\r\n" }
        if status == 405 { head += "Allow: POST\r\n" }
        connection.send(content: Data((head + "\r\n").utf8) + (body ?? Data()), completion: .contentProcessed { _ in connection.cancel() })
    }

    static func isLocal(_ origin: String) -> Bool {
        guard let host = URL(string: origin)?.host() else { return origin == "null" }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// A fresh random token for the Authorization header.
    public static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Just enough HTTP/1.1 to read one request: method, path, headers, Content-Length body.
struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    init?(_ data: Data) {
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let start = head.first?.split(separator: " ") ?? []
        guard start.count >= 2 else { return nil }
        method = String(start[0])
        path = String(start[1])
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        self.headers = headers
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return nil }
        body = data[bodyStart..<(bodyStart + length)]
    }
}
