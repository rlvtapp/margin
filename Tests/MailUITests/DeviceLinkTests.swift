import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct DeviceLinkTests {
    @Test func anotherDeviceGetsEverythingWithTheCode() async throws {
        let mac = MailModel(environment: .preview())
        await mac.reload()
        mac.templates.append(MailTemplate(name: "Linked template", subject: "", body: "Hi"))
        mac.saveTemplates()
        let (file, code) = try mac.makeDeviceLink()
        #expect(file.pathExtension == DeviceLink.fileExtension)

        let phone = MailModel(environment: .preview())
        await phone.reload()
        #expect(phone.open(file))
        #expect(phone.pendingDeviceLink == file)
        #expect(throws: BackupBox.Failure.wrongPassword) { try phone.acceptDeviceLink(code: "AAAA-BBBB") }
        _ = try phone.acceptDeviceLink(code: code.lowercased())
        #expect(phone.templates.contains { $0.name == "Linked template" })
        #expect(phone.pendingDeviceLink == nil)

        // And the restore can be undone.
        #expect(phone.canUndoRestore)
        phone.undoRestore()
        #expect(!phone.templates.contains { $0.name == "Linked template" })
    }

    @Test func emailLinksOpenANewMessage() async {
        let model = MailModel(environment: .preview())
        await model.reload()
        #expect(model.open(URL(string: "mailto:noor@example.com?subject=Lisbon&body=Are%20you%20in%3F&cc=sam@example.com")!))
        #expect(model.compose?.to == "noor@example.com")
        #expect(model.compose?.draft.subject == "Lisbon")
        #expect(model.compose?.draft.text.hasPrefix("Are you in?") == true)
        #expect(model.compose?.cc == "sam@example.com")
        #expect(!model.open(URL(string: "https://example.com")!))
    }

    @Test func recoveryKeyJoinsPasswordBackups() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let key = model.makeBackupRecoveryKey()
        defer { model.removeBackupRecoveryKey() }
        let data = try model.makeBackup(password: "pw", includeSecrets: false)
        _ = try model.restore(data, password: key)
    }
}
