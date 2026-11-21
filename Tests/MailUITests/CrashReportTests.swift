import Foundation
import Testing
@testable import MailUI

@MainActor @Suite struct CrashReportTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "crash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ name: String, bundleID: String, in folder: URL, at date: Date) throws {
        let url = folder.appending(path: name)
        try Data((#"{"app_name":"Margin","bundleID":"\#(bundleID)","bug_type":"309"}"# + "\n{}").utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// Only Margin's own new reports are offered: not older ones, not another build's.
    @Test func findsOnlyNewReportsOfThisApp() throws {
        let dir = try folder()
        let now = Date()
        try write("Margin-old.ips", bundleID: "app.relevate.margin", in: dir, at: now.addingTimeInterval(-3600))
        try write("Margin-new.ips", bundleID: "app.relevate.margin", in: dir, at: now.addingTimeInterval(-10))
        try write("Margin-snapshot.ips", bundleID: "app.relevate.margin.snapshot", in: dir, at: now.addingTimeInterval(-5))
        let found = MailModel.crashReports(in: dir, bundleID: "app.relevate.margin", after: now.addingTimeInterval(-60))
        #expect(found.map(\.lastPathComponent) == ["Margin-new.ips"])
    }

    /// The first launch only notes the time; a later crash is offered, and sending it opens the
    /// composer to Margin's inbox with the report attached.
    @Test func offersAndSendsANewCrash() async throws {
        let dir = try folder()
        let model = MailModel(environment: .preview())
        await model.reload()
        model.environment.defaults.removeObject(forKey: MailModel.crashCheckedKey)
        model.checkForCrash(in: dir, bundleID: "app.relevate.margin", now: Date().addingTimeInterval(-30))
        #expect(model.pendingCrashReport == nil)
        try write("Margin-2026.ips", bundleID: "app.relevate.margin", in: dir, at: Date().addingTimeInterval(-10))
        model.checkForCrash(in: dir, bundleID: "app.relevate.margin")
        #expect(model.pendingCrashReport?.lastPathComponent == "Margin-2026.ips")
        model.sendCrashReport()
        #expect(model.compose?.to == "margin@mail.relevate.app")
        #expect(model.compose?.draft.attachments.map(\.filename) == ["Margin-2026.ips"])
        #expect(model.pendingCrashReport == nil)
    }
}
