#if os(macOS)
import Foundation
import Testing
@testable import MailUI

@Suite struct SandboxMigrationTests {
    func home() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: "home-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    @Test func everythingTheSandboxKeptComesOverOnce() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let id = "app.example.margin"
        let container = home.appending(path: "Library/Containers/\(id)/Data/Library", directoryHint: .isDirectory)
        let oldFiles = container.appending(path: "Application Support/Margin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: oldFiles.appending(path: "Logos"), withIntermediateDirectories: true)
        try Data(#"[{"label":"Work"}]"#.utf8).write(to: oldFiles.appending(path: "accounts.json"))
        try Data("db".utf8).write(to: oldFiles.appending(path: "mail.sqlite"))
        try Data("wal".utf8).write(to: oldFiles.appending(path: "mail.sqlite-wal"))
        try Data("old logo".utf8).write(to: oldFiles.appending(path: "Logos/a.png"))
        try Data("old logo b".utf8).write(to: oldFiles.appending(path: "Logos/b.png"))
        try FileManager.default.createDirectory(at: container.appending(path: "Preferences"), withIntermediateDirectories: true)
        (["layout": "wide", "mailRules": Data("[]".utf8), "NSWindow Frame main": "x"] as NSDictionary)
            .write(to: container.appending(path: "Preferences/\(id).plist"), atomically: true)

        // A test run outside the sandbox already left a picture cache here.
        let newFiles = home.appending(path: "Library/Application Support/Margin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: newFiles.appending(path: "Logos"), withIntermediateDirectories: true)
        try Data("new logo".utf8).write(to: newFiles.appending(path: "Logos/a.png"))

        let defaults = try #require(UserDefaults(suiteName: "migration.\(UUID().uuidString)"))
        defaults.set("panels", forKey: "layout")
        let copied = SandboxMigration.run(bundleID: id, appName: "Margin", home: home, defaults: defaults)
        #expect(copied.contains("accounts.json") && copied.contains("mail.sqlite") && copied.contains("mail.sqlite-wal"))
        #expect(try String(contentsOf: newFiles.appending(path: "accounts.json"), encoding: .utf8).contains("Work"))
        #expect(try String(contentsOf: newFiles.appending(path: "Logos/a.png"), encoding: .utf8) == "new logo")   // kept
        #expect(FileManager.default.fileExists(atPath: newFiles.appending(path: "Logos/b.png").path))          // merged
        #expect(defaults.string(forKey: "layout") == "wide")                                                    // the one in use wins
        #expect(defaults.data(forKey: "mailRules") != nil)
        #expect(defaults.object(forKey: "NSWindow Frame main") == nil)                                          // the system's own stay
        #expect(FileManager.default.fileExists(atPath: oldFiles.appending(path: "accounts.json").path))         // container untouched

        // Once only: later changes in the container don't come over again.
        try Data(#"[]"#.utf8).write(to: oldFiles.appending(path: "labels.json"))
        #expect(SandboxMigration.run(bundleID: id, appName: "Margin", home: home, defaults: defaults).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: newFiles.appending(path: "labels.json").path))
    }

    @Test func aMacThatNeverSandboxedHasNothingToMove() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let defaults = try #require(UserDefaults(suiteName: "migration.\(UUID().uuidString)"))
        #expect(SandboxMigration.run(bundleID: "app.example.margin", appName: "Margin", home: home, defaults: defaults).isEmpty)
        #expect(defaults.bool(forKey: SandboxMigration.doneKey))
    }
}
#endif
