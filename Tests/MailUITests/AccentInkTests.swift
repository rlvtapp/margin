import Testing
@testable import MailUI

@Suite struct AccentInkTests {
    /// Whatever accent is picked, text on it reads: at least 3:1 (large or bold text), in light and dark.
    @Test func textOnEveryAccentReads() {
        for hues in [Palette.standardHues, Palette.safeHues] {
            for (light, dark) in hues {
                for hex in [light, dark] {
                    let colour = Contrast.components(hex)
                    let white = Contrast.ratio(colour, (255, 255, 255)), ink = Contrast.ratio(colour, (17, 17, 17))
                    let chosen = white >= 3.2 || white >= ink ? white : ink
                    #expect(chosen >= 3, "0x\(String(hex, radix: 16)) only reaches \(chosen)")
                }
            }
        }
    }
}
