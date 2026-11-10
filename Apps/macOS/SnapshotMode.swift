import AppKit
import MailCore
import MailUI
import SwiftUI
import WebKit

/// `-snapshot <file.png>` renders the main window with sample mail to a PNG and quits.
/// It draws the window's own views, so it needs no screen-recording permission.
/// Options: `-appearance light|dark`, `-snapshot-palette` (opens ⌘K), `-snapshot-compose`,
/// `-snapshot-mailbox 0`, `-snapshot-combined sent`, `-snapshot-select "subject words"`,
/// `-snapshot-pictures` (trusts every sender, so remote pictures would load).
struct SnapshotMode {
    let output: URL
    let appearance: NSAppearance.Name?
    let opensPalette: Bool
    let opensCompose: Bool
    /// `-snapshot-mailbox 0` opens the first mailbox instead of All inboxes.
    let mailbox: Int?
    /// `-snapshot-combined sent` opens that folder from every mailbox together.
    let combined: MailboxRole?
    /// `-snapshot-select "Issue 212"` opens the first conversation whose subject contains it.
    let select: String?
    /// `-snapshot-assist` asks the assistant for a summary and labels, and drafts a reply.
    let assists: Bool

    static func fromArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> SnapshotMode? {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let path = value(after: "-snapshot") else { return nil }
        let appearance: NSAppearance.Name? = switch value(after: "-appearance") {
        case "dark": .darkAqua
        case "light": .aqua
        default: nil
        }
        return SnapshotMode(
            output: URL(fileURLWithPath: path), appearance: appearance,
            opensPalette: arguments.contains("-snapshot-palette"), opensCompose: arguments.contains("-snapshot-compose"),
            mailbox: value(after: "-snapshot-mailbox").flatMap(Int.init),
            combined: value(after: "-snapshot-combined").flatMap(MailboxRole.init(rawValue:)),
            select: value(after: "-snapshot-select"),
            assists: arguments.contains("-snapshot-assist")
        )
    }

    func run(model: MailModel) {
        if let appearance { NSApp.appearance = NSAppearance(named: appearance) }
        Task { @MainActor in
            // Look settings first: changing them redraws the whole window.
            if ProcessInfo.processInfo.arguments.contains("-snapshot-plain") { model.prefersPlainText = true }
            if ProcessInfo.processInfo.arguments.contains("-snapshot-blocks") { model.usesBlockComposer = true }
            if ProcessInfo.processInfo.arguments.contains("-snapshot-colorblind") { model.colorBlindSafe = true }
            if ProcessInfo.processInfo.arguments.contains("-snapshot-contrast") { model.increaseContrast = true }
            try? await Task.sleep(for: .seconds(1.5))
            if let mailbox, model.accounts.indices.contains(mailbox) {
                model.go(to: .inbox(account: model.accounts[mailbox].id, split: nil))
            }
            if let combined { model.go(to: .combined(combined)) }
            if let select, let thread = model.visibleThreads.first(where: { $0.subject.localizedCaseInsensitiveContains(select) }) {
                model.select(thread.id)
            }
            let arguments = ProcessInfo.processInfo.arguments
            await model.findInvites()
            if arguments.contains("-snapshot-meeting") { model.addSampleMeeting() }
            if let index = arguments.firstIndex(of: "-snapshot-layout"), index + 1 < arguments.count,
               let layout = ListLayout(rawValue: arguments[index + 1]) {
                for thread in model.inboxThreads(nil) {
                    if let group = EmailSorter.ruleGroup(for: thread, groups: model.emailGroups) { model.addLabel(group.name, to: thread) }
                }
                model.layout = layout
            }
            if let index = arguments.firstIndex(of: "-snapshot-theme"), index + 1 < arguments.count,
               let theme = AppAppearance(rawValue: arguments[index + 1]) {
                model.appearance = theme
            }
            if let index = arguments.firstIndex(of: "-snapshot-place"), index + 1 < arguments.count {
                switch arguments[index + 1] {
                case "home":
                    // Sorted by the rules, so Home has tabs without waiting on a model.
                    for thread in model.inboxThreads(nil) {
                        if let group = EmailSorter.ruleGroup(for: thread, groups: model.emailGroups) { model.addLabel(group.name, to: thread) }
                    }
                    model.go(to: .home(group: nil))
                case "waiting": model.go(to: .waiting(account: nil))

                case "snoozed": model.go(to: .snoozed(account: nil))
                case "subscriptions":
                    model.go(to: .subscriptions)
                    await model.refreshNewsletterHistory()
                case "subscription":
                    model.go(to: .subscriptions)
                    await model.refreshNewsletterHistory()
                    model.openSubscriptionID = model.newsletterSuggestions.first?.id
                    if let id = model.openSubscriptionID { model.select(model.issues(of: id).first?.id) }
                default: break
                }
                try? await Task.sleep(for: .seconds(1))
                if let first = model.visibleThreads.first { model.select(first.id) }
            }
            if let index = arguments.firstIndex(of: "-snapshot-multi"), index + 1 < arguments.count, let count = Int(arguments[index + 1]) {
                model.selection = Set(model.visibleThreads.prefix(count).map(\.id))
            }
            if opensPalette { model.isPaletteOpen = true }
            if opensCompose { model.startCompose() }
            if assists {
                try? await Task.sleep(for: .seconds(1))
                model.summarizeSelected()
                model.suggestLabelsForSelected()
                model.writeReply(.draft(note: "yes, and ask which neighbourhood the flat is in"))
                // The on-device model needs a few seconds per answer.
                for _ in 0..<60 where !model.assistantWork.isEmpty { try? await Task.sleep(for: .milliseconds(500)) }
            }
            // -snapshot-ask "…": open Ask and send that question or command.
            if let index = arguments.firstIndex(of: "-snapshot-ask"), index + 1 < arguments.count {
                await model.refreshNewsletterHistory()
                model.isAsking = true
                try? await Task.sleep(for: .seconds(0.5))
                for input in arguments[index + 1].components(separatedBy: "|") { model.send(askInput: input) }
                for _ in 0..<60 where model.isWorking("ask") { try? await Task.sleep(for: .milliseconds(500)) }
            }
                        // -snapshot-suggest: wait for the suggested replies of the open conversation.
            if arguments.contains("-snapshot-suggest"), let id = model.selectedThreadID {
                for _ in 0..<80 where (model.replySuggestions[id] ?? []).isEmpty { try? await Task.sleep(for: .milliseconds(500)) }
            }
                        // Long enough for HTML mail to load and settle its height.
            try? await Task.sleep(for: .seconds(2))
            // -snapshot-settings <page>: the Settings window on that page.
            var settingsWindow: NSWindow?
            if let index = arguments.firstIndex(of: "-snapshot-settings"), index + 1 < arguments.count {
                let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 820, height: 600), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                                      backing: .buffered, defer: false)
                window.contentView = NSHostingView(rootView: MailSettingsView(model: model, startingAt: arguments[index + 1]))
                window.makeKeyAndOrderFront(nil)
                settingsWindow = window
                try? await Task.sleep(for: .seconds(1.5))
            }
            // -snapshot-click x,y: a click at that point of the window (points from the bottom
            // left), sent from inside the app, to check that something responds to the mouse.
            if let index = arguments.firstIndex(of: "-snapshot-click"), index + 1 < arguments.count, let window = settingsWindow {
                let parts = arguments[index + 1].split(separator: ",").compactMap { Double($0) }
                if parts.count == 2 {
                    NSApp.activate()
                    window.makeKeyAndOrderFront(nil)
                    try? await Task.sleep(for: .seconds(0.5))
                    let point = NSPoint(x: parts[0], y: parts[1])
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                            window.sendEvent(event)
                        }
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            // -snapshot-onboarding <step>: the first-launch welcome on that step.
            if let index = arguments.firstIndex(of: "-snapshot-onboarding"), index + 1 < arguments.count {
                let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 560, height: 560), styleMask: [.titled, .fullSizeContentView],
                                      backing: .buffered, defer: false)
                window.titlebarAppearsTransparent = true
                window.contentView = NSHostingView(rootView: OnboardingView(model: model, step: Int(arguments[index + 1]) ?? 0))
                window.makeKeyAndOrderFront(nil)
                settingsWindow = window
                try? await Task.sleep(for: .seconds(1.5))
            }
            // -snapshot-setup <provider id | list>: adding an account, on the list or one provider.
            if let index = arguments.firstIndex(of: "-snapshot-setup"), index + 1 < arguments.count {
                let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 520, height: 520), styleMask: [.titled, .fullSizeContentView],
                                      backing: .buffered, defer: false)
                window.titlebarAppearsTransparent = true
                let id = arguments[index + 1]
                window.contentView = NSHostingView(rootView: id == "list" ? AccountSetupView(model: model) : AccountSetupView(model: model, provider: id))
                window.makeKeyAndOrderFront(nil)
                settingsWindow = window
                try? await Task.sleep(for: .seconds(1.5))
            }
            // -snapshot-resize: resizes the main window step by step and prints how long each
            // relayout and redraw takes, to catch slow resizing.
            if arguments.contains("-snapshot-resize"), let main = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) {
                let start = main.frame
                var times: [Double] = []
                for step in 0..<40 {
                    var frame = start
                    frame.size.width = start.width - CGFloat(step % 20) * 25
                    let began = CACurrentMediaTime()
                    main.setFrame(frame, display: false)
                    main.contentView?.layoutSubtreeIfNeeded()
                    main.displayIfNeeded()
                    times.append((CACurrentMediaTime() - began) * 1000)
                    try? await Task.sleep(for: .milliseconds(20))
                }
                main.setFrame(start, display: true)
                let sorted = times.sorted()
                FileHandle.standardError.write(Data(String(format: "RESIZE median %.1f ms, slowest %.1f ms, over 16 ms: %d of %d\n",
                    sorted[sorted.count / 2], sorted.last ?? 0, times.filter { $0 > 16 }.count, times.count).utf8))
            }
            let window = settingsWindow ?? NSApp.windows.first { $0.isVisible && $0.attachedSheet == nil && $0.contentView != nil }
                ?? NSApp.windows.first { $0.isVisible }
            if ProcessInfo.processInfo.environment["SNAPSHOT_DEBUG"] != nil, let root = window?.contentView?.superview {
                func tables(_ view: NSView) -> [NSTableView] { (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables) }
                for table in tables(root) {
                    FileHandle.standardError.write(Data("table rows=\(table.numberOfRows) frame=\(table.frame) visible=\(table.visibleRect)\n".utf8))
                }
            }
            if ProcessInfo.processInfo.environment["SNAPSHOT_DEBUG"] != nil {
                FileHandle.standardError.write(Data("snapshot windows: \(NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible) sheet=\($0.attachedSheet != nil) frame=\($0.frame)" })\n".utf8))
            }
            if let view = window?.contentView?.superview ?? window?.contentView {
                await write(view)
                if let sheet = window?.attachedSheet?.contentView { await write(sheet, suffix: "-sheet") }
            }
            // -snapshot-hold keeps the window up so the screen itself can be captured: the
            // bitmap above can't show Liquid Glass, which is composited outside the window.
            if ProcessInfo.processInfo.arguments.contains("-snapshot-hold") {
                NSApp.activate()
                window?.makeKeyAndOrderFront(nil)
                return
            }
            NSApp.terminate(nil)
        }
    }

    /// Draws the view hierarchy, then paints each web view's own snapshot over its frame:
    /// WebKit draws in another process, so the cached bitmap has blanks where mail is.
    @MainActor
    private func write(_ view: NSView, suffix: String = "") async {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        let webViews = Self.webViews(in: view)
        if !webViews.isEmpty {
            let composed = NSImage(size: view.bounds.size)
            composed.lockFocus()
            rep.draw(in: view.bounds)
            for webView in webViews {
                // A web view left behind by a redraw has no window and never answers.
                guard webView.window != nil, let shot = await Self.shot(of: webView) else { continue }
                var frame = view.convert(webView.bounds, from: webView)
                if !view.isFlipped { /* already bottom-up */ } else { frame.origin.y = view.bounds.height - frame.maxY }
                shot.draw(in: frame)
            }
            composed.unlockFocus()
            if let tiff = composed.tiffRepresentation, let full = NSBitmapImageRep(data: tiff) {
                save(full, suffix: suffix)
                return
            }
        }
        save(rep, suffix: suffix)
    }


    private func save(_ rep: NSBitmapImageRep, suffix: String) {
        let target = suffix.isEmpty ? output : output.deletingLastPathComponent()
            .appending(path: output.deletingPathExtension().lastPathComponent + suffix + ".png")
        do { try rep.representation(using: .png, properties: [:])?.write(to: target) } catch { FileHandle.standardError.write(Data("snapshot: \(error)\n".utf8)) }
    }

    /// The web view's snapshot, or nil when WebKit doesn't answer within two seconds.
    @MainActor
    private static func shot(of webView: WKWebView) async -> NSImage? {
        await withCheckedContinuation { continuation in
            var done = false
            webView.takeSnapshot(with: nil) { image, _ in
                guard !done else { return }
                done = true
                continuation.resume(returning: image)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard !done else { return }
                done = true
                continuation.resume(returning: nil)
            }
        }
    }

    @MainActor
    private static func webViews(in view: NSView) -> [WKWebView] {
        if let webView = view as? WKWebView { return [webView] }
        return view.subviews.flatMap(webViews(in:))
    }
}
