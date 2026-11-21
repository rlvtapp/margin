import Foundation
import SwiftUI
import Testing
@testable import MailUI

/// The app's size: the system's text size unless one is picked by hand, which overrides it
/// until ⌘0.
@MainActor
@Suite(.serialized) struct AppScaleTests {
    @Test func theSystemsTextSizeBecomesAFactor() {
        #expect(AppScale.system(.large) == 1)
        #expect(AppScale.system(.xSmall) < 1)
        #expect(AppScale.system(.xxxLarge) > AppScale.system(.xLarge))
        // The biggest accessibility sizes stop where the layout still holds.
        #expect(AppScale.system(.accessibility5) == AppScale.range.upperBound)
        for size in DynamicTypeSize.allCases { #expect(AppScale.range.contains(AppScale.system(size))) }
    }

    @Test func aPickedSizeMapsBackToTheNearestSystemSize() {
        #expect(AppScale.typeSize(for: 1) == .large)
        #expect(AppScale.typeSize(for: 1.3) == .xxxLarge)
        #expect(AppScale.typeSize(for: 0.8) == .xSmall)
    }

    @Test func stepsStayInRange() {
        #expect(AppScale.clamp(3) == AppScale.range.upperBound)
        #expect(AppScale.clamp(0.1) == AppScale.range.lowerBound)
        #expect(AppScale.clamp(1.1500001) == 1.2)
    }

    @Test func zoomingOverridesTheSystemAndActualSizeFollowsItAgain() {
        let before = Look.scale
        defer { Look.scale = before }
        let environment = MailEnvironment.preview()
        let model = MailModel(environment: environment)
        #expect(model.appScaleOverride == nil)

        // From the system's size (here 120%), one step up.
        Look.scale = 1.2
        model.zoomApp(1)
        #expect(model.appScaleOverride == 1.3)
        model.zoomApp(-1)
        model.zoomApp(-1)
        #expect(model.appScaleOverride == 1.1)
        // Remembered, and it wins over the system's size.
        #expect(MailModel(environment: environment).appScaleOverride == 1.1)
        #expect(Look.applyScale(model, systemTypeSize: .accessibility3) == 1.1)

        model.zoomApp(0)
        #expect(model.appScaleOverride == nil)
        #expect(MailModel(environment: environment).appScaleOverride == nil)
        #expect(Look.applyScale(model, systemTypeSize: .xxLarge) == CGFloat(AppScale.system(.xxLarge)))
    }

    @Test func zoomingStopsAtTheEnds() {
        let before = Look.scale
        defer { Look.scale = before }
        let model = MailModel(environment: .preview())
        model.appScaleOverride = AppScale.range.upperBound
        model.zoomApp(1)
        #expect(model.appScaleOverride == AppScale.range.upperBound)
        model.appScaleOverride = AppScale.range.lowerBound
        model.zoomApp(-1)
        #expect(model.appScaleOverride == AppScale.range.lowerBound)
    }

    @Test func typeGapsAndFixedSizesGrowTogether() {
        let before = (Look.scale, Look.density)
        defer { (Look.scale, Look.density) = before }
        Look.density = .compact
        Look.scale = 1
        let normal = (Look.size(13), Look.gap(8), Look.pick(52, roomy: 60), Look.scaled(44))
        let key = Look.key
        Look.scale = 1.5
        #expect(Look.size(13) == normal.0 * 1.5)
        #expect(Look.gap(8) == (normal.1 * 1.5).rounded())
        #expect(Look.pick(52, roomy: 60) == (normal.2 * 1.5).rounded())
        #expect(Look.scaled(44) == 66)
        // The window redraws when it changes.
        #expect(Look.key != key)
        // Windows grow less, so Settings still fits a laptop screen.
        #expect(Look.window(900, roomy: 980) < 900 * 1.5)
    }

    @Test func itTravelsWithABackup() {
        #expect(MailModel.backedUpSettings.contains("appScale"))
    }
}
