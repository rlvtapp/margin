import Foundation
import Testing
@testable import MailUI

@Suite struct LabelContrastTests {
    /// Every label colour's text passes WCAG AA (4.5:1) on its own tint, on a plain row and a
    /// selected one, in light and dark, also in the colour-blind-safe palette.
    @Test func labelTextPassesAA() {
        for hues in [Palette.standardHues, Palette.safeHues] {
            for (light, dark) in hues {
                for (base, ground, end) in [(light, UInt32(0xFFFFFF), UInt32(0x000000)), (light, 0xEBEBEB, 0x000000),
                                            (dark, 0x1E1E1E, 0xFFFFFF), (dark, 0x333333, 0xFFFFFF)] {
                    let ink = Contrast.components(Contrast.readable(base, on: end == 0 ? 0xEBEBEB : 0x333333, toward: end))
                    let chip = Contrast.mix(Contrast.components(ground), Contrast.components(base), 0.14)
                    #expect(Contrast.ratio(ink, chip) >= 4.5, "0x\(String(base, radix: 16)) on 0x\(String(ground, radix: 16))")
                }
            }
        }
    }
}
