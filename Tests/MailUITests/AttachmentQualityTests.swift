import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct AttachmentQualityTests {
    /// Files that don't fit are named, not dropped without a word; the rest are attached.
    @Test func tooBigFilesAreNamed() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "attach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let small = folder.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: small)
        let big = folder.appending(path: "film.mov")
        try Data(count: ComposeAttachments.sizeLimit + 1).write(to: big)
        let missing = folder.appending(path: "gone.pdf")

        var state = ComposeState(account: MailAccount.sample)
        #expect(ComposeAttachments.add([small, big, missing], to: &state))
        #expect(state.draft.attachments.map(\.filename) == ["notes.txt"])
        let problem = try #require(state.attachmentProblem)
        #expect(problem.contains("film.mov"))
        #expect(problem.contains("gone.pdf"))

        ComposeAttachments.add([small], to: &state)
        #expect(state.attachmentProblem == nil)
    }

    /// Save All never overwrites: a taken name gets a number, as Finder does.
    @Test func freeNames() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(MailModel.freeName(for: "report.pdf", in: folder).lastPathComponent == "report.pdf")
        try Data().write(to: folder.appending(path: "report.pdf"))
        #expect(MailModel.freeName(for: "report.pdf", in: folder).lastPathComponent == "report 2.pdf")
        try Data().write(to: folder.appending(path: "report 2.pdf"))
        #expect(MailModel.freeName(for: "report.pdf", in: folder).lastPathComponent == "report 3.pdf")
        try Data().write(to: folder.appending(path: "README"))
        #expect(MailModel.freeName(for: "README", in: folder).lastPathComponent == "README 2")
    }
}
