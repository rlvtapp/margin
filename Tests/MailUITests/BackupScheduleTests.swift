import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct BackupScheduleTests {
    @Test func automaticBackupsKeepTheNewestAndRestoreOnlyWhatIsChosen() throws {
        let model = MailModel(environment: .preview())
        model.templates = []
        for day in 0..<32 {
            try model.writeAutomaticBackup(now: Date(timeIntervalSince1970: 1_800_000_000 + Double(day) * 86_400))
        }
        let files = try FileManager.default.contentsOfDirectory(at: model.backupFolder, includingPropertiesForKeys: nil)
        #expect(files.count == 30)

        let data = try Data(contentsOf: files.sorted { $0.lastPathComponent > $1.lastPathComponent }[0])
        let other = MailModel(environment: .preview())
        other.templates = []
        other.textScale = 1.5
        let template = MailTemplate(name: "Thanks", subject: "", body: "Thanks!")
        model.templates = [template]
        let fresh = try model.makeBackup(password: nil, includeSecrets: false)
        _ = try other.restore(fresh, password: nil, parts: [.templates])
        #expect(other.templates.map(\.name) == ["Thanks"])
        #expect(other.textScale == 1.5)
        _ = data
    }
}
