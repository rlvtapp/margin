#if os(macOS)
import Foundation
import Testing
@testable import MailUI

@Suite struct RelaunchTests {
    /// Restart reopens Margin only after this copy has gone, never beside it.
    @Test func reopensOnlyAfterTheOldCopyQuits() async throws {
        let old = Process()
        old.executableURL = URL(fileURLWithPath: "/bin/sleep")
        old.arguments = ["30"]
        try old.run()

        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("relaunch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        // `touch` stands in for opening Margin: the file appears when Margin would open.
        let helper = Relaunch.helper(waitingFor: old.processIdentifier, reopening: marker.path, opener: "/usr/bin/touch")
        try helper.run()

        try await Task.sleep(for: .milliseconds(250))
        #expect(old.isRunning)
        #expect(!FileManager.default.fileExists(atPath: marker.path), "opened while the old copy was still running")

        old.terminate()
        old.waitUntilExit()
        helper.waitUntilExit()
        #expect(helper.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    /// It opens Margin in place (no second-instance flag), so the Dock icon it was pinned to is used.
    @Test func opensTheBundleItselfWithNoExtraFlags() {
        let helper = Relaunch.helper(waitingFor: 42, reopening: "/Applications/Margin.app")
        #expect(helper.executableURL?.path == "/bin/sh")
        #expect(Array(helper.arguments?.suffix(3) ?? []) == ["42", "/usr/bin/open", "/Applications/Margin.app"])
        #expect(!(helper.arguments ?? []).contains("-n"))
    }

    /// Quitting goes ahead after the limit even when the work never finishes.
    @MainActor @Test func quitsAfterTheLimitWhenWorkHangs() async throws {
        var calls = 0
        let start = ContinuousClock.now
        // The work would take two minutes; the bound is loose because other tests share the main actor.
        Relaunch.finish({ try? await Task.sleep(for: .seconds(120)) }, atMost: .milliseconds(100)) { calls += 1 }
        while calls == 0, ContinuousClock.now - start < .seconds(60) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(calls == 1)
        #expect(ContinuousClock.now - start < .seconds(60))
    }

    /// Fast work ends the wait at once, and quitting is answered exactly once.
    @MainActor @Test func answersOnceWhenWorkIsQuick() async throws {
        var calls = 0
        var timedOut = false
        Relaunch.finish({}, atMost: .seconds(30)) { calls += 1 }
        Relaunch.finish({ try? await Task.sleep(for: .seconds(120)) }, atMost: .milliseconds(50)) { timedOut = true }
        let start = ContinuousClock.now
        while !timedOut, ContinuousClock.now - start < .seconds(60) { try await Task.sleep(for: .milliseconds(20)) }
        // The quick one answered long before its 30-second limit, and only once since.
        #expect(calls == 1)
        try await Task.sleep(for: .milliseconds(200))
        #expect(calls == 1)
    }
}
#endif
