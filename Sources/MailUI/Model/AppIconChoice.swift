import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The colours Margin's icon comes in. Each is an Icon Composer file in Apps/Shared, listed as an
/// alternate icon in the project; blue is the main one.
public enum AppIconChoice: String, CaseIterable, Identifiable, Sendable {
    case blue, green, purple, orange, pink, red, graphite, pixel, space

    public var id: String { rawValue }

    /// The colours come on a light or a dark tile; Pixel and Space are one look each.
    var hasDarkVersion: Bool { self != .pixel && self != .space }

    /// The alternate icon's name in the app, or nil for the main icon (blue, light).
    func assetName(dark: Bool) -> String? {
        let name = "AppIcon-" + rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        if dark && hasDarkVersion { return name + "-Dark" }
        return self == .blue ? nil : name
    }

    var title: String {
        switch self {
        case .blue: String(localized: "Blue")
        case .green: String(localized: "Green")
        case .purple: String(localized: "Purple")
        case .orange: String(localized: "Orange")
        case .pink: String(localized: "Pink")
        case .red: String(localized: "Red")
        case .graphite: String(localized: "Graphite")
        case .pixel: String(localized: "Pixel")
        case .space: String(localized: "Space")
        }
    }

    /// The envelope's front and flap colours, as in the icon files, for the previews.
    var colors: (front: [Color], flap: [Color]) {
        func hex(_ value: UInt32) -> Color {
            Color(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
        }
        let (f1, f2, l1, l2): (UInt32, UInt32, UInt32, UInt32) = switch self {
        case .blue: (0x4C97FF, 0x2F78F5, 0xB4D3FF, 0x8BBBFF)
        case .green: (0x3DC47E, 0x23A363, 0xB8ECCD, 0x8FDDB0)
        case .purple: (0x9B7BFF, 0x7A55F0, 0xD8CEFF, 0xBCAAFF)
        case .orange: (0xFFA94D, 0xF2851F, 0xFFDDB3, 0xFFC789)
        case .pink: (0xFF6FA8, 0xEF4A8C, 0xFFC8DE, 0xFFA5C8)
        case .red: (0xFF6B5E, 0xE5463A, 0xFFC6C0, 0xFFA39A)
        case .graphite: (0x8A8F98, 0x5E636C, 0xD5D8DD, 0xB7BBC2)
        case .space: (0xA796FF, 0x6E55E8, 0xF1EDFF, 0xCFC4FF)
        case .pixel: (0xA8AAAD, 0xA8AAAD, 0xF6F5F1, 0xF6F5F1)
        }
        return ([hex(f1), hex(f2)], [hex(l1), hex(l2)])
    }
}

extension MailModel {
    /// Puts the chosen icon on the app. On iPhone and iPad the system shows the new icon on the
    /// Home Screen (and says so once); on the Mac it shows in the Dock while Margin is open.
    public func applyAppIcon() {
        #if os(macOS)
        NSApplication.shared.applicationIconImage = NSImage(named: appIcon.assetName(dark: appIconDark) ?? "AppIcon")
        #elseif os(iOS)
        guard UIApplication.shared.supportsAlternateIcons,
              UIApplication.shared.alternateIconName != appIcon.assetName(dark: appIconDark) else { return }
        UIApplication.shared.setAlternateIconName(appIcon.assetName(dark: appIconDark))
        #endif
    }
}

/// A small drawing of the icon in one colour, for the picker.
struct AppIconPreview: View {
    let choice: AppIconChoice
    var dark = false
    var size: CGFloat = 52

    var body: some View {
        #if os(macOS)
        if let image = NSImage(named: choice.assetName(dark: dark) ?? "AppIcon") {
            // The real icon, glass and all; it has its own margin, so draw it a little larger.
            Image(nsImage: image).resizable().frame(width: size * 1.22, height: size * 1.22).frame(width: size, height: size)
        } else {
            drawing
        }
        #else
        drawing
        #endif
    }

    /// The icon redrawn from its shapes: the tile and the envelope (in blocks, for Pixel).
    @ViewBuilder
    private var drawing: some View {
        if choice == .pixel {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                    .fill(Color(red: 0.95, green: 0.94, blue: 0.92))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
                PixelEnvelope()
                    .frame(width: size * 810 / 1024, height: size * 540 / 1024)
                    .offset(x: size * 27 / 1024, y: size * 37 / 1024)
            }
            .frame(width: size, height: size)
        } else {
            smoothDrawing
        }
    }

    private var smoothDrawing: some View {
        let colors = choice.colors
        let unit = size / 1024
        let tile: [Color] = switch choice {
        case _ where dark && choice.hasDarkVersion: [Color(white: 0.2), Color(white: 0.1)]
        case .space: [Color(red: 0.13, green: 0.10, blue: 0.32), Color(red: 0.03, green: 0.03, blue: 0.10)]
        case .pixel: [Color(red: 0.95, green: 0.94, blue: 0.92), Color(red: 0.90, green: 0.89, blue: 0.87)]
        default: [Color(white: 0.99), Color(white: 0.93)]
        }
        return ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(colors: tile, startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
            RoundedRectangle(cornerRadius: 76 * unit, style: .continuous)
                .fill(LinearGradient(colors: colors.front, startPoint: .top, endPoint: .bottom))
                .frame(width: 700 * unit, height: 450 * unit)
                .offset(y: (522 - 512) * unit)
            EnvelopeFlap()
                .fill(LinearGradient(colors: colors.flap, startPoint: .top, endPoint: .bottom))
                .frame(width: 700 * unit, height: 330 * unit)
                .offset(y: (462 - 512) * unit)
        }
        .frame(width: size, height: size)
    }
}

/// The envelope's flap: rounded across the top, folding to a soft point.
private struct EnvelopeFlap: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height, r = w * 0.064
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: rect.origin)
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.2))
        path.addLine(to: CGPoint(x: rect.midX + w * 0.07, y: rect.maxY - h * 0.06))
        path.addQuadCurve(to: CGPoint(x: rect.midX - w * 0.07, y: rect.maxY - h * 0.06), control: CGPoint(x: rect.midX, y: rect.maxY + h * 0.02))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.2))
        path.closeSubpath()
        return path
    }
}

/// Pixel's envelope, block for block as in its icon file: a 14 × 9 grid in Relevate's soft
/// grays, with the flap's V, a shaded bottom row and a soft shadow one block down and right.
private struct PixelEnvelope: View {
    var body: some View {
        Canvas { context, size in
            let cols = 14, rows = 9
            // The canvas holds one more block each way, for the shadow.
            let cell = CGSize(width: size.width / CGFloat(cols + 1), height: size.height / CGFloat(rows + 1))
            func color(_ hex: UInt32) -> Color {
                Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
            }
            let corners: Set<[Int]> = [[0, 0], [cols - 1, 0], [0, rows - 1], [cols - 1, rows - 1]]
            func inside(_ c: Int, _ r: Int) -> Bool { c >= 0 && r >= 0 && c < cols && r < rows && !corners.contains([c, r]) }
            func fill(_ c: Int, _ r: Int, _ hex: UInt32) {
                let rect = CGRect(x: CGFloat(c) * cell.width, y: CGFloat(r) * cell.height, width: cell.width + 0.5, height: cell.height + 0.5)
                context.fill(Path(rect), with: .color(color(hex)))
            }
            for r in 0...rows {
                for c in 0...cols where !inside(c, r) && inside(c - 1, r - 1) { fill(c, r, 0xD9D7D0) }
            }
            for r in 0..<rows {
                for c in 0..<cols where inside(c, r) {
                    let edge = !inside(c + 1, r) || !inside(c - 1, r) || !inside(c, r + 1) || !inside(c, r - 1)
                    var hex: UInt32 = edge ? 0x71757B : r == rows - 2 ? 0x9A9CA0 : 0xA8AAAD
                    if !edge, (1...6).contains(r), c >= r, c <= cols - 1 - r {
                        hex = (r == 6 || c == r || c == cols - 1 - r) ? 0x71757B : 0xF6F5F1
                    }
                    fill(c, r, hex)
                }
            }
        }
    }
}
