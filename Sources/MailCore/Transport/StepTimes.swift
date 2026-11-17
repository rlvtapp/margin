import Foundation

/// How long the steps of a check took (opening a connection, the sign-in token, signing in,
/// the folder list, the sync), so a slow mailbox shows where its time went. MailCore keeps no
/// log of its own: the app sets `report` (MailUI writes it to the system log) and nothing is
/// measured until it does. Never carries passwords, tokens, addresses or mail.
public enum StepTimes {
    nonisolated(unsafe) public static var report: (@Sendable (String) -> Void)?

    static var isOn: Bool { report != nil }

    static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        Int((ContinuousClock.now - start) / .milliseconds(1))
    }

    /// Notes how long each step took since the one before.
    struct Laps {
        private var last = ContinuousClock.now
        private let start = ContinuousClock.now
        private(set) var steps: [String] = []

        mutating func lap(_ name: String) {
            let now = ContinuousClock.now
            steps.append("\(name) \(Int((now - last) / .milliseconds(1))) ms")
            last = now
        }

        mutating func note(_ text: String) { steps.append(text) }

        var line: String { steps.joined(separator: ", ") + ", \(StepTimes.milliseconds(since: start)) ms in all" }
    }

    static func send(_ line: @autoclosure () -> String) {
        report?(line())
    }
}
