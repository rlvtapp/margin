#if canImport(AppKit)
import AppKit
import SwiftUI
import Testing
@testable import MailUI
import MailCore

@MainActor @Suite struct RenderSettingsShot {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MARGIN_SHOT"] != nil))
    func assistantPage() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        model.applyAssistant(AssistantSettings(provider: .claudeCode, model: "haiku"), apiKey: nil)
        model.saveAssistantProfile(AssistantSettings(provider: .codex), apiKey: nil)
        model.saveAssistantProfile(AssistantSettings(provider: .ollama, model: "llama3.2"), apiKey: nil)
        let view = AssistantSettingsView(model: model).frame(width: 640, height: 1400)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 1400), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: ProcessInfo.processInfo.environment["MARGIN_SHOT"] == "dark" ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded() }
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let out = ProcessInfo.processInfo.environment["MARGIN_SHOT_PATH"] ?? "/tmp/assistant.png"
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        window.close()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MARGIN_SHOT"] != nil))
    func formattingBar() async throws {
        let view = FormattingBar(controller: RichTextController()).padding(8).background(Paper.panel)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded() }
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let out = (ProcessInfo.processInfo.environment["MARGIN_SHOT_PATH"] ?? "/tmp/assistant.png").replacingOccurrences(of: ".png", with: "-bar.png")
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        window.close()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MARGIN_SHOT"] != nil))
    func composer() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        model.startCompose()
        var state = try #require(model.compose)
        state.to = "jp@studio.example"
        state.draft.subject = "Interview"
        let view = ComposeSheet(model: model, state: .constant(state)).frame(width: 720, height: 520)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        for _ in 0..<15 { try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded() }
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let out = (ProcessInfo.processInfo.environment["MARGIN_SHOT_PATH"] ?? "/tmp/assistant.png").replacingOccurrences(of: ".png", with: "-compose.png")
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        window.close()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MARGIN_SHOT"] != nil))
    func accountRail() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        if let first = model.accounts.first { model.go(to: .inbox(account: first.id, split: nil)) }
        let view = AccountRail(model: model).frame(height: 560).background(Paper.sidebar)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: MailLayout.railWidth, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        for _ in 0..<15 { try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded() }
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let out = (ProcessInfo.processInfo.environment["MARGIN_SHOT_PATH"] ?? "/tmp/assistant.png").replacingOccurrences(of: ".png", with: "-rail.png")
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        window.close()
    }
}
#endif
