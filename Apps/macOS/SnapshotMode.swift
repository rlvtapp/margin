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
            if ProcessInfo.processInfo.arguments.contains("-snapshot-colorblind") { model.colorBlindSafe = true }
            // -snapshot-size 1280x800: the main window at that size (points), for pictures of a known shape.
            if let size = Self.windowSize, let main = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) {
                // On a Retina screen when there is one, so a picture of the real window is sharp.
                let retina = NSScreen.screens.first { $0.backingScaleFactor >= 2 }
                let screen = (retina ?? main.screen)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1728, height: 1084)
                main.setFrame(NSRect(x: screen.minX + 20, y: screen.maxY - size.height - 20, width: size.width, height: size.height), display: true)
            }
            if ProcessInfo.processInfo.arguments.contains("-snapshot-density-compact") { model.density = .compact }
            if ProcessInfo.processInfo.arguments.contains("-snapshot-contrast") { model.increaseContrast = true }
            // -snapshot-no-next-up: the Next up column closed, as on the website's pictures.
            if ProcessInfo.processInfo.arguments.contains("-snapshot-no-next-up") { model.showsNextUp = false }
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
            if arguments.contains("-snapshot-calendar") { model.addSampleCalendar() }
            if arguments.contains("-snapshot-reactions") { model.addSampleReactions() }
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
                case "calendar":
                    model.addSampleCalendar()
                    model.go(to: .calendar)
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
            // -snapshot-reader: the conversation open over the list (a narrow window shows one or
            // the other); -snapshot-drawer: the mailbox drawer open, where there's no column.
            if arguments.contains("-snapshot-reader") { model.isReaderOpen = true }
            if arguments.contains("-snapshot-drawer") { model.isSidebarDrawerOpen = true }
            if opensPalette { model.isPaletteOpen = true }
            if opensCompose { model.startCompose() }
            // -snapshot-cc "no": with -snapshot-compose, opens Cc and Bcc with that typed in Cc,
            // to check the people suggested under it.
            if opensCompose, let index = arguments.firstIndex(of: "-snapshot-cc"), index + 1 < arguments.count {
                model.compose?.showsCc = true
                model.compose?.showsBcc = true
                model.compose?.cc = arguments[index + 1]
            }
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
                // "mailbox": the first mailbox's own settings (name, Send as, signatures).
                // "signatures": the Signatures page, with a workspace and a signature for all inboxes.
                if arguments[index + 1] == "signatures", let first = model.accounts.first {
                    model.workspaces = [Workspace(name: "Studio", colorIndex: 5, accounts: [first.id])]
                    SignatureSheetSnapshot.fillSharedSignatures(model)
                }
                // "signature": a formatted signature open in its editor.
                window.contentView = arguments[index + 1] == "mailbox"
                    ? NSHostingView(rootView: AnyView(MailboxSettingsSnapshot(model: model).frame(width: 560, height: 1300)))
                    : arguments[index + 1] == "signature"
                    ? NSHostingView(rootView: AnyView(SignatureSheetSnapshot()))
                    : NSHostingView(rootView: AnyView(MailSettingsView(model: model, startingAt: arguments[index + 1])))
                if arguments[index + 1] == "mailbox" { window.setContentSize(NSSize(width: 560, height: 1300)) }
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
            // -snapshot-onboarding <step>: the first-launch welcome on that step (0 to 4).
            // -snapshot-width <points> draws it narrower, as a sheet on a small window would be.
            if let index = arguments.firstIndex(of: "-snapshot-onboarding"), index + 1 < arguments.count {
                let width = arguments.firstIndex(of: "-snapshot-width").flatMap { $0 + 1 < arguments.count ? Double(arguments[$0 + 1]) : nil } ?? 600
                let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: width, height: 640), styleMask: [.titled, .fullSizeContentView],
                                      backing: .buffered, defer: false)
                window.titlebarAppearsTransparent = true
                // -snapshot-mailboxes <n>: the welcome as if n mailboxes had been added.
                let count = arguments.firstIndex(of: "-snapshot-mailboxes").flatMap { $0 + 1 < arguments.count ? Int(arguments[$0 + 1]) : nil } ?? 0
                let shown = ["ada@example.com", "ada.work@example.org", "team@example.net"].prefix(count).enumerated().map { index, address in
                    MailAccount(label: address, address: EmailAddress(address: address),
                                connection: .jmap(sessionURL: URL(string: "https://example.invalid")!), auth: .token, colorIndex: index)
                }
                let host = NSHostingView(rootView: OnboardingView(model: model, step: Int(arguments[index + 1]) ?? 0, shownMailboxes: shown))
                // Keep the asked-for width rather than growing to the welcome's ideal size.
                if width != 600 { host.sizingOptions = [] }
                window.contentView = host
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
            // The biggest visible window: a tooltip's little panel can be visible too.
            let window = settingsWindow
                ?? NSApp.windows.filter { $0.isVisible && $0.contentView != nil }.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            if ProcessInfo.processInfo.environment["SNAPSHOT_DEBUG"] != nil, let root = window?.contentView?.superview {
                func tables(_ view: NSView) -> [NSTableView] { (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables) }
                for table in tables(root) {
                    FileHandle.standardError.write(Data("table rows=\(table.numberOfRows) frame=\(table.frame) visible=\(table.visibleRect)\n".utf8))
                }
            }
            if ProcessInfo.processInfo.environment["SNAPSHOT_DEBUG"] != nil {
                FileHandle.standardError.write(Data("snapshot windows: \(NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible) sheet=\($0.attachedSheet != nil) frame=\($0.frame)" })\n".utf8))
            }
            // -snapshot-glass: a picture of the real window as the system draws it, Liquid Glass and
            // scrolling parts included (the drawing below can't show those). The window has to be
            // on screen for a moment; it stays behind the other windows without taking the keyboard
            // (launch it with `open -g` so the app doesn't come forward either). A row under the
            // pointer shows its hover buttons, so keep the pointer off the window's top left.
            if arguments.contains("-snapshot-glass"), let window {
                window.orderFrontRegardless()
                window.orderBack(nil)
                try? await Task.sleep(for: .seconds(1.2))
                if let image = Self.systemPicture(of: window) {
                    save(NSBitmapImageRep(cgImage: image), suffix: "")
                    NSApp.terminate(nil)
                    return
                }
                FileHandle.standardError.write(Data("snapshot: the system gave no picture of the window\n".utf8))
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

    /// The window as the window server has it, without its shadow. An app may always picture
    /// its own windows, so this needs no screen-recording permission. The call left the SDK in
    /// macOS 15 but is still in the system, so it's looked up by name.
    private static func systemPicture(of window: NSWindow) -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        let includingWindow: UInt32 = 1 << 3, ignoreFraming: UInt32 = 1 << 0, bestResolution: UInt32 = 1 << 3
        return create(.null, includingWindow, UInt32(window.windowNumber), ignoreFraming | bestResolution)?.takeRetainedValue()
    }

    /// `-snapshot-size 1280x800`, in points.
    private static var windowSize: NSSize? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-snapshot-size"), index + 1 < arguments.count else { return nil }
        let parts = arguments[index + 1].split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? NSSize(width: parts[0], height: parts[1]) : nil
    }

    /// A bitmap to draw the view into: the screen's own scale, or two pixels a point with
    /// `-snapshot-size` (so pictures are sharp whatever screen the window is on).
    @MainActor
    private func bitmap(for view: NSView) -> NSBitmapImageRep? {
        guard Self.windowSize != nil else { return view.bitmapImageRepForCachingDisplay(in: view.bounds) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = view.bounds.size
        return rep
    }

    /// Draws the view hierarchy, then paints each web view's own snapshot over its frame:
    /// WebKit draws in another process, so the cached bitmap has blanks where mail is.
    @MainActor
    private func write(_ view: NSView, suffix: String = "") async {
        guard let rep = bitmap(for: view) else { return }
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
