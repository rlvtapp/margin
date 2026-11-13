import MailCore
import SwiftUI

/// The one chip Margin uses for tabs, filters and small facts, on the Mac and on iPhone and iPad:
/// Liquid Glass in a capsule. Picked, the glass takes a deep tint and the text turns white;
/// otherwise it's clear glass with an optional coloured icon. Before macOS and iOS 26 it falls
/// back to the flat fill the rest of the app uses.
public struct GlassChip: View {
    public enum Size { case small, regular }

    let title: Text
    /// Callers pass the filled variant for a picked chip when one exists.
    var symbol: String?
    /// The icon's colour while not picked.
    var color: Color?
    /// The glass tint while picked: a deep colour white text reads on.
    var tint: Color
    var count: Int?
    var isOn: Bool
    var size: Size

    public init(_ title: Text, symbol: String? = nil, color: Color? = nil, tint: Color = Palette.pickedGlass,
                count: Int? = nil, isOn: Bool = false, size: Size = .small) {
        self.title = title
        self.symbol = symbol
        self.color = color
        self.tint = tint
        self.count = count
        self.isOn = isOn
        self.size = size
    }

    /// One size per platform, so every chip lines up with every other: a thumb-sized chip on
    /// iPhone and iPad, a compact one on the Mac. (`size` is kept for callers; it no longer differs.)
    #if os(iOS)
    private static let height: CGFloat = 36
    private static let iconSize: CGFloat = 13
    private static var titleFont: Font { Font.system(size: Look.size(15), weight: .medium) }
    private static var countFont: Font { Font.system(size: Look.size(13), weight: .semibold).monospacedDigit() }
    private static let sidePadding: CGFloat = 13
    private static let gap: CGFloat = 6
    #else
    private static let height: CGFloat = 26
    private static let iconSize: CGFloat = 10.5
    private static var titleFont: Font { TypeScale.label.weight(.medium) }
    private static var countFont: Font { TypeScale.label.monospacedDigit() }
    private static let sidePadding: CGFloat = 10
    private static let gap: CGFloat = 4
    #endif

    public var body: some View {
        HStack(spacing: Self.gap) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: Self.iconSize, weight: .semibold))
                    .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(color ?? Ink.secondary))
            }
            title.font(Self.titleFont)
            if let count, count > 0 {
                Text(verbatim: "\(count)")
                    .font(Self.countFont)
                    .opacity(isOn ? 0.75 : 0.55)
            }
        }
        .lineLimit(1)
        .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(Ink.primary))
        .padding(.horizontal, Self.sidePadding)
        .frame(height: Self.height)
        .contentShape(Capsule())
        .glassCapsule(tint: isOn ? tint : nil)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Chips side by side, so neighbouring glass blends as one surface.
public struct GlassChipRow<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    public init(spacing: CGFloat = 6, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        if #available(macOS 26, iOS 26, *), !Look.reduceTransparency {
            GlassEffectContainer(spacing: spacing) { HStack(spacing: spacing) { content } }
        } else {
            HStack(spacing: spacing) { content }
        }
    }
}

extension Palette {
    /// A picked chip with no colour of its own (All, Unread…): dark glass in light and dark.
    public static var pickedGlass: Color { Color(white: 0.24) }

    /// A picked chip for a part of the inbox: a deep shade of its colour, the same in light and
    /// dark, so white text on it always reads.
    public static func deep(_ split: InboxSplit) -> Color {
        let hex: UInt32 = switch (split, Look.colorBlindSafe) {
        case (.people, false): 0x1D4ED8
        case (.updates, false): 0xB45309
        case (.newsletters, false): 0x6D28D9
        case (.people, true): 0x005A8C
        case (.updates, true): 0x8A5300
        case (.newsletters, true): 0x8E3F6F
        }
        return Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension View {
    /// Liquid Glass in a capsule, tinted when given a colour; a flat fill before 26.
    @ViewBuilder
    func glassCapsule(tint: Color?) -> some View {
        if #available(macOS 26, iOS 26, *), !Look.reduceTransparency {
            #if os(macOS)
            // The Mac fades glass tints in a window that isn't focused, which left white text
            // on pale grey; a solid layer of the same colour underneath keeps a picked chip dark.
            self.background { if let tint { Capsule().fill(tint) } }
                .glassEffect(tint.map { Glass.regular.tint($0).interactive() } ?? Glass.regular.interactive(), in: Capsule())
            #else
            self.glassEffect(tint.map { Glass.regular.tint($0).interactive() } ?? Glass.regular.interactive(), in: Capsule())
            #endif
        } else {
            self.background(tint ?? Fill.one, in: Capsule())
        }
    }
}
