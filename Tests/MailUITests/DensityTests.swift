import Foundation
import Testing
@testable import MailUI

@MainActor
@Suite(.serialized) struct DensityTests {
    @Test func roomyIsTheDefaultAndCompactIsRemembered() {
        let environment = MailEnvironment.preview()
        let model = MailModel(environment: environment)
        #expect(model.density == .roomy)
        model.density = .compact
        #expect(MailModel(environment: environment).density == .compact)
    }

    @Test func roomyIsBiggerThanCompactOnTheMac() {
        let before = Look.density
        defer { Look.density = before }
        Look.density = .compact
        let compact = (Look.size(13), Look.gap(8), Look.pick(52, roomy: 60))
        Look.density = .roomy
        let roomy = (Look.size(13), Look.gap(8), Look.pick(52, roomy: 60))
        #if os(macOS)
        #expect(compact == (13, 8, 52))
        #expect(roomy == (14, 10, 60))
        #endif
        #expect(Look.key.contains("roomy"))
    }
}
