import Foundation

/// A TCP connection that reads CRLF-terminated lines and exact byte counts, for the
/// line-based mail protocols (IMAP, SMTP). Built on URLSessionStreamTask because it can
/// upgrade a plain connection to TLS in place, which STARTTLS needs, and it runs on every
/// Apple platform.
actor LineConnection {
    let endpoint: ServerEndpoint
    private let session: URLSession
    private let task: URLSessionStreamTask
    private let timeout: TimeInterval
    private var buffer: [UInt8] = []
    private var isClosed = false
    private var invalidated = false

    init(endpoint: ServerEndpoint, timeout: TimeInterval = 30) throws {
        guard endpoint.isAllowed else { throw MailError.insecureConnection }
        self.endpoint = endpoint
        self.timeout = timeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        session = URLSession(configuration: configuration)
        task = session.streamTask(withHostName: endpoint.host, port: endpoint.port)
        if endpoint.security == .tls { task.startSecureConnection() }
        task.resume()
    }

    deinit {
        if !invalidated {
            task.cancel()
            session.finishTasksAndInvalidate()
        }
    }

    /// Upgrades to TLS after a STARTTLS exchange. Anything already buffered was sent in
    /// the clear before the upgrade, so it's discarded rather than trusted.
    func startTLS() {
        buffer.removeAll()
        task.startSecureConnection()
    }

    func write(_ text: String) async throws {
        try await write(Array(text.utf8))
    }

    func write(_ bytes: [UInt8]) async throws {
        guard !isClosed else { throw MailError.connectionClosed }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let completion = StreamCompletion(continuation)
                task.write(Data(bytes), timeout: timeout) { @Sendable [session, task] error in
                    withExtendedLifetime((session, task)) {
                        if let error { completion.resume(.failure(error)) }
                        else { completion.resume(.success(())) }
                    }
                }
            }
        } catch {
            throw Self.map(error)
        }
    }

    /// One line including its line ending (CRLF, or a bare LF from lenient servers).
    func readLine(limit: Int = 1 << 20) async throws -> [UInt8] {
        var searchFrom = 0
        while true {
            if let newline = buffer[searchFrom...].firstIndex(of: 0x0A) {
                let line = Array(buffer[...newline])
                buffer.removeFirst(newline + 1)
                return line
            }
            searchFrom = buffer.count
            guard buffer.count < limit else { throw MailError.protocolViolation("A line was too long.") }
            try await fill()
        }
    }

    func readExactly(_ count: Int) async throws -> [UInt8] {
        while buffer.count < count { try await fill() }
        let bytes = Array(buffer[..<count])
        buffer.removeFirst(count)
        return bytes
    }

    func close() {
        isClosed = true
        guard !invalidated else { return }
        invalidated = true
        task.cancel()
        // Let pending callbacks drain before the session is torn down. A disconnect can
        // otherwise race connection establishment, especially just after waking the Mac.
        session.finishTasksAndInvalidate()
    }

    private func fill() async throws {
        guard !isClosed else { throw MailError.connectionClosed }
        let result: (Data?, Bool)
        do {
            result = try await withCheckedThrowingContinuation { continuation in
                let completion = StreamCompletion(continuation)
                task.readData(ofMinLength: 1, maxLength: 256 * 1024, timeout: timeout) { @Sendable [session, task] data, ended, error in
                    withExtendedLifetime((session, task)) {
                        if let error { completion.resume(.failure(error)) }
                        else { completion.resume(.success((data, ended))) }
                    }
                }
            }
        } catch {
            throw Self.map(error)
        }
        guard !isClosed else { throw MailError.connectionClosed }
        if let data = result.0, !data.isEmpty {
            buffer.append(contentsOf: data)
        } else if result.1 {
            close()
            throw MailError.connectionClosed
        }
    }

    private static func map(_ error: Error) -> MailError {
        if let mail = error as? MailError { return mail }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut { return .timedOut }
        return .connectionFailed(nsError.localizedDescription)
    }
}

/// Stream callbacks can race cancellation. Own the continuation instead of relying on the
/// Foundation async overlay, and accept only the first completion, including error replies.
final class StreamCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }

    func resume(_ result: Result<Value, Error>) {
        let next = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        next?.resume(with: result)
    }
}
