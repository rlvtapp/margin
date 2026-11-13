#if os(macOS)
import AppKit
import Testing
@testable import MailUI

@MainActor @Suite struct DictationStatusPanelTests {
    @Test func repeatedVoiceStatusChangesDoNotCreateALayoutLoop() async throws {
        _ = NSApplication.shared
        let panel = DictationStatusPanel()
        defer { panel.close() }
        let originalKeyWindow = NSApp.keyWindow
        for _ in 0..<5 {
            for title in ["Preparing microphone…", "Listening…", "Finishing…", "Allow microphone access in System Settings."] {
                panel.show(title: title, hint: "Let go of Space to write · Esc to cancel", on: NSScreen.main)
                panel.updateConstraintsIfNeeded()
                panel.layoutIfNeeded()
                panel.displayIfNeeded()
                // Exercise real display cycles, where the reported exception was thrown.
                try await Task.sleep(for: .milliseconds(15))
                #expect(panel.frame.size == NSSize(width: 420, height: 84))
                #expect(panel.isVisible)
                #expect(NSApp.keyWindow === originalKeyWindow)
            }
        }
    }
}
#endif
