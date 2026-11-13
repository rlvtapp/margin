import MailCore
import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

// Paper and ink: one neutral scale per appearance, ink for what matters, and no
// decorative colour. Every colour in a view comes from a role here.

extension Color {
    /// A colour that follows light and dark appearance.
    static func adaptive(_ light: UInt32, _ dark: UInt32, alpha: Double = 1, darkAlpha: Double? = nil) -> Color {
        let darkAlpha = darkAlpha ?? alpha
        #if canImport(AppKit)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(hex: dark, alpha: darkAlpha) : NSColor(hex: light, alpha: alpha)
        })
        #else
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark, alpha: darkAlpha) : UIColor(hex: light, alpha: alpha)
        })
        #endif
    }
}

#if canImport(AppKit)
extension NSColor {
    convenience init(hex: UInt32, alpha: Double) {
        self.init(srgbRed: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, alpha: alpha)
    }
}
#else
extension UIColor {
    convenience init(hex: UInt32, alpha: Double) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, alpha: alpha)
    }
}
#endif

public enum Paper {
    /// The reading surface.
    public static var ground: Color { surface(0xFFFFFF, 0x131314, white: 0xFFFFFF, developer: 0x0D1117, deep: 0x000000) }
    /// The window itself, behind the sidebar. The list and reader sit on one inset panel.
    public static var sidebar: Color { surface(0xF4F4F5, 0x0B0B0C, white: 0xFFFFFF, developer: 0x010409, deep: 0x000000) }
    /// The inset panel that holds the list and the reader.
    public static var panel: Color { surface(0xFFFFFF, 0x131314, white: 0xFFFFFF, developer: 0x0D1117, deep: 0x050505) }
    /// Date group headers in the list.
    public static let band = Color.adaptive(0x737373, 0xFFFFFF, alpha: 0.045, darkAlpha: 0.035)
    /// Menus, the command palette, compose.
    public static var popover: Color { surface(0xFFFFFF, 0x1B1B1D, white: 0xFFFFFF, developer: 0x161B22, deep: 0x111112) }
    /// The reply box.
    public static var sheet: Color { surface(0xFFFFFF, 0x18181A, white: 0xFFFFFF, developer: 0x161B22, deep: 0x0C0C0D) }
    /// Fields sit into the page.
    public static let field = Color.adaptive(0x737373, 0xFFFFFF, alpha: 0.05, darkAlpha: 0.05)

    /// White is light only and all white; Developer is dark only, in deep blue-black; Deep dark
    /// is dark only, true black (it saves power on OLED screens).
    private static func surface(_ light: UInt32, _ dark: UInt32, white: UInt32, developer: UInt32, deep: UInt32) -> Color {
        switch Look.theme {
        case .white: .adaptive(white, dark)
        case .developer: .adaptive(light, developer)
        case .deepDark: .adaptive(light, deep)
        default: .adaptive(light, dark)
        }
    }
}

public enum Fill {
    /// Hover.
    public static var one: Color { .adaptive(0x737373, 0xFFFFFF, alpha: Look.highContrast ? 0.1 : 0.06, darkAlpha: Look.highContrast ? 0.1 : 0.05) }
    /// Selected.
    public static var two: Color { .adaptive(0x737373, 0xFFFFFF, alpha: Look.highContrast ? 0.22 : 0.11, darkAlpha: Look.highContrast ? 0.2 : 0.09) }
    /// Pressed, keycaps.
    public static var three: Color { .adaptive(0x737373, 0xFFFFFF, alpha: Look.highContrast ? 0.28 : 0.16, darkAlpha: Look.highContrast ? 0.26 : 0.13) }
}

/// How the person wants things to look beyond light and dark: a colour-blind-safe palette,
/// more contrast, less motion. Set once at the top of the window from settings and the
/// system's accessibility options; every token below reads it.
public enum Look {
    nonisolated(unsafe) public static var colorBlindSafe = false
    nonisolated(unsafe) public static var highContrast = false
    nonisolated(unsafe) public static var reduceMotion = false
    nonisolated(unsafe) public static var underlineLinks = false
    /// Light emails turned dark in dark mode.
    nonisolated(unsafe) public static var darkensMail = true
    /// The system's Reduce Transparency: chips use flat fills instead of Liquid Glass.
    nonisolated(unsafe) public static var reduceTransparency = false
    nonisolated(unsafe) public static var theme: AppAppearance = .system
    /// Roomy unless the person chose Compact.
    nonisolated(unsafe) public static var density: Density = .roomy

    /// A type size for the chosen density. `base` is the compact size on the Mac and the
    /// roomy size on touch screens, which were already a step up.
    public static func size(_ base: CGFloat) -> CGFloat {
        #if os(iOS)
        density == .compact ? base - 1 : base
        #else
        density == .compact ? base : base + (base >= 16 ? 2 : 1)
        #endif
    }

    /// One of two hand-picked Mac sizes; touch screens keep the first.
    public static func pick(_ compact: CGFloat, roomy: CGFloat) -> CGFloat {
        #if os(iOS)
        compact
        #else
        density == .compact ? compact : roomy
        #endif
    }

    /// A gap, padding or control size for the chosen density.
    public static func gap(_ base: CGFloat) -> CGFloat {
        #if os(iOS)
        base
        #else
        density == .compact ? base : (base * 1.25).rounded()
        #endif
    }

    /// Changes whenever any option changes, so the window can redraw everything once.
    public static var key: String { "\(colorBlindSafe)\(highContrast)\(reduceMotion)\(underlineLinks)\(darkensMail)\(reduceTransparency)\(theme.rawValue)\(density.rawValue)\(LabelColors.signature)" }
}

public enum Ink {
    public static var primary: Color { Look.highContrast ? .adaptive(0x000000, 0xFFFFFF) : .adaptive(0x1F1F1F, 0xF2F2F2) }
    public static var secondary: Color { Look.highContrast ? .adaptive(0x2E2E2E, 0xDADADA) : .adaptive(0x555555, 0xB4B4B4) }
    public static var tertiary: Color { Look.highContrast ? .adaptive(0x454545, 0xBDBDBD) : .adaptive(0x6E6E6E, 0x8A8A8A) }
    public static var quaternary: Color { Look.highContrast ? .adaptive(0x666666, 0x9A9A9A) : .adaptive(0x9A9A9A, 0x5E5E5E) }
    /// Text on an ink fill.
    public static var inverse: Color { Look.highContrast ? .adaptive(0xFFFFFF, 0x000000) : .adaptive(0xFFFFFF, 0x0E0E0F) }
}

public enum Line {
    /// Between panes and rows.
    public static var hairline: Color { .adaptive(0x000000, 0xFFFFFF, alpha: Look.highContrast ? 0.2 : 0.07, darkAlpha: Look.highContrast ? 0.22 : 0.07) }
    /// The edge of a raised surface.
    public static var edge: Color { .adaptive(0x000000, 0xFFFFFF, alpha: Look.highContrast ? 0.35 : 0.1, darkAlpha: Look.highContrast ? 0.35 : 0.09) }
}

public enum Status {
    /// Vermillion in the colour-blind-safe palette, which stays apart from green and blue.
    public static var danger: Color { Look.colorBlindSafe ? .adaptive(0xC24E00, 0xF08A4B) : .adaptive(0xC2410C, 0xF97316) }
    public static var star: Color { Look.colorBlindSafe ? .adaptive(0xB07000, 0xE69F00) : .adaptive(0xB45309, 0xF5B83D) }
    /// Done: bluish green in the colour-blind-safe palette.
    public static var done: Color { Look.colorBlindSafe ? .adaptive(0x007A5A, 0x2BB58E) : .adaptive(0x15803D, 0x22C55E) }
}

/// How much room the interface takes: Roomy is the default, Compact fits more on screen.
public enum Density: String, CaseIterable, Sendable {
    case roomy, compact
}

public enum Space {
    public static var xs: CGFloat { Look.gap(4) }
    public static var s: CGFloat { Look.gap(8) }
    public static var m: CGFloat { Look.gap(12) }
    public static var l: CGFloat { Look.gap(16) }
    public static var xl: CGFloat { Look.gap(24) }
    public static var xxl: CGFloat { Look.gap(32) }
}

public enum Radius {
    public static let chip: CGFloat = 6
    public static let row: CGFloat = 8
    public static let control: CGFloat = 8
    public static let surface: CGFloat = 12
}

/// The type scale: one family, regular and medium only.
public enum TypeScale {
    #if os(iOS)
    // A step up on touch screens, read at arm's length.
    public static var title: Font { .system(size: Look.size(24), weight: .semibold) }
    public static var heading: Font { .system(size: Look.size(17), weight: .medium) }
    public static var body: Font { .system(size: Look.size(16)) }
    public static var row: Font { .system(size: Look.size(15)) }
    public static var rowStrong: Font { .system(size: Look.size(15), weight: .medium) }
    public static var label: Font { .system(size: Look.size(13)) }
    public static var caption: Font { .system(size: Look.size(12)) }
    public static var key: Font { .system(size: Look.size(11), weight: .medium) }
    #else
    public static var title: Font { .system(size: Look.size(21), weight: .medium) }
    public static var heading: Font { .system(size: Look.size(14), weight: .medium) }
    /// Message text: a size up from the interface, because this is what you read.
    public static var body: Font { .system(size: Look.size(15)) }
    public static var row: Font { .system(size: Look.size(13)) }
    public static var rowStrong: Font { .system(size: Look.size(13), weight: .medium) }
    public static var label: Font { .system(size: Look.size(12)) }
    public static var caption: Font { .system(size: Look.size(11)) }
    public static var key: Font { .system(size: Look.size(10.5), weight: .medium) }
    #endif
}

public enum Motion {
    /// Selection and small state changes: quick, no bounce. None when motion is reduced.
    public static var quick: Animation? { Look.reduceMotion ? nil : .easeOut(duration: 0.12) }
    /// Overlays appearing.
    public static var present: Animation? { Look.reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86) }
}

/// The accent the person picked (unread marks, badges), passed down the view tree.
public struct MailAccentKey: EnvironmentKey {
    public static var defaultValue: Color { Palette.accent }
}

extension EnvironmentValues {
    public var mailAccent: Color {
        get { self[MailAccentKey.self] }
        set { self[MailAccentKey.self] = newValue }
    }
}

/// Colour that carries meaning: which account, which part of the inbox, who wrote.
public enum Palette {
    /// Unread marks and the one accent of the app.
    public static var accent: Color {
        if Look.colorBlindSafe { return .adaptive(0x0072B2, 0x56B4E9) }
        return Look.theme == .developer ? .adaptive(0x1A7F37, 0x3FB950) : .adaptive(0x2F6FEB, 0x5B9BFF)
    }

    /// The Okabe–Ito palette (light, dark): told apart under red–green and blue–yellow
    /// colour blindness. Its yellow is darkened so white letters stay readable on it.
    static let safeHues: [(UInt32, UInt32)] = [
        (0x0072B2, 0x56B4E9), // blue
        (0xC27C00, 0xE69F00), // orange
        (0xB0558C, 0xCC79A7), // reddish purple
        (0x007A5E, 0x2BBF98), // bluish green
        (0xC24E00, 0xF08A4B), // vermillion
        (0x3A8FC4, 0x8FD0F2), // sky blue
        (0x8A7A00, 0xE3D53A), // yellow
        (0x5C5C5C, 0xA0A0A0), // grey
    ]

    static var hues: [(UInt32, UInt32)] { Look.colorBlindSafe ? safeHues : standardHues }

    /// Account colours, in the order new accounts receive them.
    static let standardHues: [(UInt32, UInt32)] = [
        (0x2F6FEB, 0x5B9BFF), // blue
        (0x0E9F6E, 0x34D399), // green
        (0x7C5CF0, 0xA78BFA), // violet
        (0xE07B00, 0xFBBF24), // amber
        (0xDB2777, 0xF472B6), // pink
        (0x0891B2, 0x22D3EE), // cyan
        (0xDC2626, 0xF87171), // red
        (0x4D7C0F, 0xA3E635), // lime
    ]

    public static func account(_ index: Int) -> Color {
        let hue = hues[((index % hues.count) + hues.count) % hues.count]
        return Color.adaptive(hue.0, hue.1)
    }

    /// Text in a label's colour, on that colour's light tint: the hue darkened (light) or
    /// lightened (dark) just enough to reach 4.7:1, so small label text passes WCAG AA, also
    /// on a selected row.
    public static func accountText(_ index: Int) -> Color {
        let hue = hues[((index % hues.count) + hues.count) % hues.count]
        return Color.adaptive(Contrast.readable(hue.0, on: 0xEBEBEB, toward: 0x000000),
                              Contrast.readable(hue.1, on: 0x333333, toward: 0xFFFFFF))
    }

    public static func split(_ split: InboxSplit) -> Color {
        if Look.colorBlindSafe {
            return switch split {
            case .people: .adaptive(0x0072B2, 0x56B4E9)
            case .updates: .adaptive(0xC27C00, 0xE69F00)
            case .newsletters: .adaptive(0xB0558C, 0xCC79A7)
            }
        }
        return switch split {
        case .people: Color.adaptive(0x2F6FEB, 0x5B9BFF)
        case .updates: Color.adaptive(0xE07B00, 0xFBBF24)
        case .newsletters: Color.adaptive(0x7C5CF0, 0xA78BFA)
        }
    }

    /// Muted avatar colours: the same in both appearances, readable under white initials.
    static var people: [UInt32] {
        Look.colorBlindSafe
            ? [0x0068A3, 0xA85300, 0x96487A, 0x006E55, 0x7D6400, 0x2F78A8, 0x555555, 0x6B52A3]
            : [0x5B6FD6, 0x3F8F78, 0x8462C9, 0xB7783A, 0xB45482, 0x3A8AA3, 0xB05B52, 0x6C7A3A]
    }

    /// A steady colour per person, so the same sender always looks the same.
    public static func person(_ address: String) -> Color {
        var hash: UInt32 = 5381
        for byte in address.lowercased().utf8 { hash = (hash &* 33) &+ UInt32(byte) }
        let hex = people[Int(hash % UInt32(people.count))]
        return Color.adaptive(hex, hex)
    }
}

/// WCAG contrast arithmetic for picking readable text shades.
enum Contrast {
    /// Relative luminance of a 0xRRGGBB colour.
    static func luminance(_ rgb: (Double, Double, Double)) -> Double {
        func channel(_ value: Double) -> Double {
            let c = value / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb.0) + 0.7152 * channel(rgb.1) + 0.0722 * channel(rgb.2)
    }

    static func ratio(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func components(_ hex: UInt32) -> (Double, Double, Double) {
        (Double((hex >> 16) & 0xFF), Double((hex >> 8) & 0xFF), Double(hex & 0xFF))
    }

    static func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> (Double, Double, Double) {
        (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
    }

    /// `hex` moved toward `target` until it reads at `minimum` on its own 14% tint over `background`.
    static func readable(_ hex: UInt32, on background: UInt32, toward target: UInt32, minimum: Double = 4.7) -> UInt32 {
        let base = components(hex), ground = components(background), end = components(target)
        let chip = mix(ground, base, 0.14)
        for step in 0...100 {
            let shade = mix(base, end, Double(step) / 100)
            let rounded = (shade.0.rounded(), shade.1.rounded(), shade.2.rounded())
            if ratio(rounded, chip) >= minimum {
                return UInt32(rounded.0) << 16 | UInt32(rounded.1) << 8 | UInt32(rounded.2)
            }
        }
        return target
    }
}
