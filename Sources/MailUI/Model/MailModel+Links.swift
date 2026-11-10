import Foundation
import MailCore
#if canImport(AppKit)
import AppKit
#endif

/// Links and files other apps hand to Margin: `mailto:` links from websites and other apps,
/// and device-link files from another of your devices.
extension MailModel {
    /// Opens what another app sent. Returns false when Margin doesn't handle it.
    @discardableResult
    public func open(_ url: URL) -> Bool {
        if openMessageLink(url) { return true }
        if openMarginLink(url) { return true }
        if url.scheme?.lowercased() == "mailto" {
            startCompose(mailto: url)
            return true
        }
        if url.isFileURL, url.pathExtension.lowercased() == DeviceLink.fileExtension {
            pendingDeviceLink = url
            return true
        }
        return false
    }

    #if os(macOS)
    /// Whether email links open in Margin.
    public var isDefaultMailApp: Bool {
        guard let mailto = URL(string: "mailto:"), let app = NSWorkspace.shared.urlForApplication(toOpen: mailto) else { return false }
        return app.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// Makes Margin the app that email links open in. macOS asks the person to confirm.
    public func becomeDefaultMailApp() async {
        do {
            try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "mailto")
            notice = Notice(text: String(localized: "Email links now open in Margin"))
        } catch {
            show(error)
        }
        defaultAppRevision += 1
    }
    #endif
}
