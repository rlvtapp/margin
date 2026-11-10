import Foundation
import MailCore
#if canImport(AppKit)
import AppKit
import ApplicationServices
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Printing and PDFs of a conversation, hiding Margin from screen sharing, and typing sign-in
/// codes into the field you're in.
extension MailModel {
    // MARK: Print and PDF

    /// The conversation as a plain, printable page: who, when, and what was written.
    func printableHTML(_ thread: MailThread) -> String {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        var html = """
        <html><head><meta charset="utf-8"><style>
        body { font: 12px -apple-system, Helvetica, sans-serif; color: #111; margin: 0; }
        h1 { font-size: 18px; margin: 0 0 4px; } .meta { color: #666; margin-bottom: 12px; }
        .message { border-top: 1px solid #ddd; padding: 12px 0; } .from { font-weight: 600; }
        .text { white-space: pre-wrap; margin-top: 8px; } img { max-width: 100%; }
        </style></head><body><h1>\(escape(thread.subject))</h1>
        <div class="meta">\(thread.messages.count) \(thread.messages.count == 1 ? "message" : "messages")</div>
        """
        for message in thread.messages {
            let body = self.body(of: message, in: thread)
            html += "<div class=\"message\"><div class=\"from\">\(escape(message.from.headerValue))</div>"
            html += "<div class=\"meta\">\(escape(message.date.formatted(date: .long, time: .shortened)))"
            if !message.to.isEmpty { html += " · " + escape(message.to.map(\.headerValue).joined(separator: ", ")) }
            html += "</div>"
            if let rich = body?.html, !prefersPlainText {
                // Safe, and nothing fetched from the web while printing.
                html += "<div>" + HTMLSanitizer.sanitize(rich, blockTrackers: true).html
                    .replacingOccurrences(of: #"(src|srcset|background)\s*=\s*["']?https?://[^"'\s>]*["']?"#, with: "", options: .regularExpression) + "</div>"
            } else {
                html += "<div class=\"text\">\(escape(body?.text ?? message.snippet))</div>"
            }
            html += "</div>"
        }
        return html + "</body></html>"
    }

    /// Prints the open conversation; on the Mac the print panel can also save a PDF.
    public func printSelected(asPDF: Bool = false) {
        guard let thread = selectedThread else { return }
        Task {
            await loadAllBodies(of: thread)
            let html = printableHTML(thread)
            #if canImport(AppKit)
            guard let data = html.data(using: .utf8),
                  let text = NSAttributedString(html: data, options: [.characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) else { return }
            let info = NSPrintInfo.shared.copy() as! NSPrintInfo
            info.horizontalPagination = .fit
            info.isVerticallyCentered = false
            let width = info.paperSize.width - info.leftMargin - info.rightMargin
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
            view.textStorage?.setAttributedString(text)
            view.sizeToFit()
            if asPDF {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.pdf]
                panel.nameFieldStringValue = (thread.subject.isEmpty ? "Conversation" : thread.subject) + ".pdf"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                info.jobDisposition = .save
                info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
                let operation = NSPrintOperation(view: view, printInfo: info)
                operation.showsPrintPanel = false
                operation.showsProgressPanel = false
                operation.run()
                notice = Notice(text: String(localized: "Saved \(url.lastPathComponent)"))
            } else {
                NSPrintOperation(view: view, printInfo: info).run()
            }
            #elseif canImport(UIKit)
            let controller = UIPrintInteractionController.shared
            let job = UIPrintInfo(dictionary: nil)
            job.outputType = .general
            job.jobName = thread.subject
            controller.printInfo = job
            controller.printFormatter = UIMarkupTextPrintFormatter(markupText: html)
            controller.present(animated: true)
            #endif
        }
    }

    // MARK: Screen sharing

    /// Keeps Margin's windows out of screen sharing and recordings (Mac).
    public var hidesFromScreenSharing: Bool {
        get { _ = priorityRevision; return environment.defaults.bool(forKey: "hidesFromScreenSharing") }
        set {
            environment.defaults.set(newValue, forKey: "hidesFromScreenSharing")
            priorityRevision += 1
            #if canImport(AppKit)
            Self.applyScreenSharing(newValue)
            #endif
        }
    }

    #if canImport(AppKit)
    public static func applyScreenSharing(_ hidden: Bool) {
        for window in NSApp.windows { window.sharingType = hidden ? .none : .readOnly }
    }
    #endif

    // MARK: Typing codes

    /// Types a new sign-in code into the field you're in (Mac, with Accessibility permission).
    public var typesSignInCodes: Bool {
        get { _ = priorityRevision; return environment.defaults.bool(forKey: "typesSignInCodes") }
        set { environment.defaults.set(newValue, forKey: "typesSignInCodes"); priorityRevision += 1 }
    }

    /// Whether this copy of Margin may type into other apps: never from the App Sandbox.
    public static var canTypeIntoOtherApps: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil
    }

    /// Asks for Accessibility permission when it isn't there yet; true when it is.
    @discardableResult
    public static func requestTypingPermission() -> Bool {
        #if canImport(AppKit)
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
        #else
        return false
        #endif
    }

    func typeIntoFocusedField(_ code: String) {
        #if canImport(AppKit)
        guard typesSignInCodes, Self.canTypeIntoOtherApps, AXIsProcessTrusted() else { return }
        // Only into another app: typing into Margin itself would land in its own fields.
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        for character in code {
            var units = Array(String(character).utf16)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                event.post(tap: .cghidEventTap)
            }
        }
        #endif
    }
}
