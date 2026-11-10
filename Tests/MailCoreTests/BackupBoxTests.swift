import Foundation
import Testing
@testable import MailCore

@Suite struct BackupBoxTests {
    let contents = Data("everything Margin keeps".utf8)

    @Test func eitherThePasswordOrTheRecoveryKeyOpensIt() throws {
        let key = BackupBox.makeRecoveryKey()
        let sealed = try BackupBox.seal(contents, password: "correct horse", recoveryKey: key)
        #expect(try BackupBox.open(sealed, password: "correct horse") == contents)
        #expect(try BackupBox.open(sealed, password: key) == contents)
        // However it's typed.
        #expect(try BackupBox.open(sealed, password: key.lowercased().replacingOccurrences(of: "-", with: " ")) == contents)
        #expect(throws: BackupBox.Failure.wrongPassword) { try BackupBox.open(sealed, password: "wrong") }
        #expect(throws: BackupBox.Failure.needsPassword) { try BackupBox.open(sealed, password: nil) }
        #expect(!String(decoding: sealed, as: UTF8.self).contains("everything"))
    }

    @Test func withoutASecretItIsPlain() throws {
        let sealed = try BackupBox.seal(contents, password: nil)
        #expect(!BackupBox.isEncrypted(sealed))
        #expect(try BackupBox.open(sealed, password: nil) == contents)
    }

    @Test func keysAndCodesAreReadable() {
        let key = BackupBox.makeRecoveryKey()
        #expect(key.split(separator: "-").count == 6 && key.split(separator: "-").allSatisfy { $0.count == 4 })
        #expect(!key.contains { "0O1IL".contains($0) })
        let code = BackupBox.makeLinkCode()
        #expect(code.count == 9 && BackupBox.normalized(code).count == 8)
        #expect(BackupBox.makeLinkCode() != code)
    }
}
