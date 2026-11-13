import Foundation
import Testing
@testable import MailCore

@Suite struct StreamCompletionTests {
    @Test func racingCallbacksResumeOnlyOnce() async throws {
        let value: Int = try await withCheckedThrowingContinuation { continuation in
            let completion = StreamCompletion(continuation)
            DispatchQueue.concurrentPerform(iterations: 50) { number in
                completion.resume(.success(number))
                completion.resume(.failure(MailError.connectionClosed))
            }
        }
        #expect((0..<50).contains(value))
    }

    @Test func anErrorCannotBeFollowedByASecondCompletion() async {
        await #expect(throws: MailError.connectionClosed) {
            let _: Int = try await withCheckedThrowingContinuation { continuation in
                let completion = StreamCompletion(continuation)
                completion.resume(.failure(MailError.connectionClosed))
                completion.resume(.success(42))
                completion.resume(.failure(MailError.timedOut))
            }
        }
    }

    @Test func closingAConnectionUnblocksAPendingRead() async throws {
        let server = try await FakeServer(greeting: "ready") { _ in "" }
        defer { server.hangUp(); server.stop() }
        for _ in 0..<20 {
            let connection = try LineConnection(endpoint: ServerEndpoint(host: "127.0.0.1", port: server.port, security: .plain), timeout: 2)
            #expect(String(decoding: try await connection.readLine(), as: UTF8.self) == "ready\r\n")
            let pending = Task { try await connection.readLine() }
            try await Task.sleep(for: .milliseconds(10))
            await connection.close()
            await connection.close()
            await #expect(throws: MailError.self) { _ = try await pending.value }
        }
    }

    @Test func closingWhileConnectingDoesNotLeaveCallbacksBehind() async throws {
        for _ in 0..<30 {
            let connection = try LineConnection(endpoint: ServerEndpoint(host: "127.0.0.1", port: 1, security: .plain), timeout: 2)
            let pending = Task { try await connection.readLine() }
            await connection.close()
            await #expect(throws: MailError.self) { _ = try await pending.value }
        }
    }
}
