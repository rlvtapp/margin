import Foundation
import Testing
@testable import MailCore

@Suite struct MXLookupTests {
    /// An MX record's data: preference, then the host as labels.
    @Test func readsAnMXRecord() {
        var bytes: [UInt8] = [0, 10]
        for label in ["mx01", "mail", "icloud", "com"] { bytes.append(UInt8(label.utf8.count)); bytes += Array(label.utf8) }
        bytes.append(0)
        let record = bytes.withUnsafeBytes { MXLookup.parse($0) }
        #expect(record?.preference == 10)
        #expect(record?.host == "mx01.mail.icloud.com")
    }

    /// Custom domains are known by where their mail goes.
    @Test func knowsProvidersByMailServers() {
        #expect(ProviderCatalog.preset(forMXHosts: ["mx01.mail.icloud.com"])?.id == "icloud")
        #expect(ProviderCatalog.preset(forMXHosts: ["aspmx.l.google.com"])?.id == "google")
        #expect(ProviderCatalog.preset(forMXHosts: ["relevate-app.mail.protection.outlook.com"])?.id == "microsoft")
        #expect(ProviderCatalog.preset(forMXHosts: ["in1-smtp.messagingengine.com"])?.id == "fastmail")
        #expect(ProviderCatalog.preset(forMXHosts: ["mail.example.org"]) == nil)
    }
}
