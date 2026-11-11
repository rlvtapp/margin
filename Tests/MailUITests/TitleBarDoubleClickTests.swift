import Foundation
import Testing
@testable import MailUI
#if os(macOS)
import AppKit
#endif

@Suite struct TitleBarDoubleClickTests {
    @Test func followsTheSystemSetting() {
        #expect(TitleBarDoubleClick.action(setting: "Maximize", legacyMinimize: false) == .zoom)
        #expect(TitleBarDoubleClick.action(setting: "Fill", legacyMinimize: false) == .zoom)
        #expect(TitleBarDoubleClick.action(setting: "Minimize", legacyMinimize: false) == .minimize)
        #expect(TitleBarDoubleClick.action(setting: "None", legacyMinimize: true) == .nothing)
    }

    @Test func fallsBackToTheOlderSwitchWhenUnset() {
        #expect(TitleBarDoubleClick.action(setting: nil, legacyMinimize: false) == .zoom)
        #expect(TitleBarDoubleClick.action(setting: nil, legacyMinimize: true) == .minimize)
    }

    #if os(macOS)
    /// A real double-click on the bar's empty space, on a real window, with the Mac's default
    /// setting (zoom): the window changes size.
    @MainActor @Test func aDoubleClickOnTheBarZoomsTheWindow() throws {
        let defaults = UserDefaults.standard
        guard TitleBarDoubleClick.action(setting: defaults.string(forKey: "AppleActionOnDoubleClick"),
                                         legacyMinimize: defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick")) == .zoom else { return }
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 520, height: 400),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let bar = TitleBarArea.TitleBarView(frame: NSRect(x: 0, y: 356, width: 520, height: 44))
        window.contentView?.addSubview(bar)
        window.orderFrontRegardless()
        defer { window.close() }
        let before = window.frame
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 200, y: 380), modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                    context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
        bar.mouseDown(with: click)
        #expect(window.frame != before)
        #expect(window.frame.width > before.width)
    }

    /// ⌘⌫ while writing clears the line being typed and goes no further (it used to reach the
    /// menu's Move to Trash).
    @MainActor @Test func commandBackspaceBelongsToTheText() throws {
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView?.addSubview(text)
        defer { window.close() }
        text.string = "First line\nSecond line"
        text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
        #expect(window.makeFirstResponder(text))
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                                          context: nil, characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: code))
        }
        #expect(TextEditingKeys.handle(try key(51, .command)))
        #expect(text.string == "First line\n")
        // A plain Backspace, and ⌘⌫ with nothing being edited, are left alone.
        #expect(!TextEditingKeys.handle(try key(51, [])))
        window.makeFirstResponder(nil)
        #expect(!TextEditingKeys.handle(try key(51, .command)))
    }
    #endif
}
