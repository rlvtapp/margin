#if canImport(AppKit)
import AppKit
import Foundation
import MailCore
import Testing
import WebKit
@testable import MailUI

/// The second line behind the HTML cleaner: how an email is shown, what a click in it can do,
/// and how its attachments land on disk.
@MainActor @Suite struct AppSafetyTests {
    @Test func emailIsShownWithoutScriptsOrStorage() {
        let web = HTMLWebCoordinator.makeWebView(background: 0xFFFFFF)
        let configuration = web.configuration
        #expect(configuration.defaultWebpagePreferences.allowsContentJavaScript == false)
        #expect(configuration.preferences.javaScriptCanOpenWindowsAutomatically == false)
        #expect(configuration.websiteDataStore.isPersistent == false)
    }

    @Test func aClickInAnEmailCanOnlyOpenTheWebOrANewMessage() {
        typealias Rule = HTMLWebCoordinator
        #expect(Rule.decision(scheme: "https", isLinkClick: true) == .openInBrowser)
        #expect(Rule.decision(scheme: "HTTP", isLinkClick: true) == .openInBrowser)
        #expect(Rule.decision(scheme: "mailto", isLinkClick: true) == .compose)
        for scheme in ["data", "file", "javascript", "about", "x-apple.systempreferences", "facetime", "ssh", "vnc", "smb", "afp", nil] {
            #expect(Rule.decision(scheme: scheme, isLinkClick: true) == .ignore, "\(scheme ?? "nil")")
        }
        // The page Margin made loads; nothing else replaces it without a click.
        #expect(Rule.decision(scheme: "about", isLinkClick: false) == .load)
        #expect(Rule.decision(scheme: "data", isLinkClick: false) == .load)
        #expect(Rule.decision(scheme: "https", isLinkClick: false) == .ignore)
        #expect(Rule.decision(scheme: "file", isLinkClick: false) == .ignore)
    }

    @Test func savedAttachmentsAreMarkedAsDownloaded() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "run.command")
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: file)
        MailModel.markAsDownloaded(file)
        let properties = try file.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(properties?[kLSQuarantineAgentNameKey as String] as? String == "Margin")
    }

    @Test func signInCodesNeverReachAIApps() {
        #expect(!MailModel.hidingCode("482913", in: "Your code is 482 913 or 482-913.").contains("482"))
    }
}
#endif
