import MailCore
import SwiftUI

/// Choices in Settings that change how Margin looks, shown as small pictures of the result
/// instead of a menu of names: you see what Deep dark or Wide list means before you pick it.
struct ChoiceTiles<Value: Hashable, Preview: View>: View {
    let options: [Value]
    @Binding var selection: Value
    var minimumWidth: CGFloat = 132
    let title: (Value) -> String
    var caption: (Value) -> String? = { _ in nil }
    @ViewBuilder let preview: (Value) -> Preview

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumWidth), spacing: Space.m, alignment: .top)],
                  alignment: .leading, spacing: Space.m) {
            ForEach(options, id: \.self) { option in
                let isOn = option == selection
                Button { selection = option } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        preview(option)
                            .frame(height: 64)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Line.edge))
                            .padding(3)
                            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(Palette.accent, lineWidth: 2).opacity(isOn ? 1 : 0))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: title(option))
                                .font(TypeScale.rowStrong)
                                .foregroundStyle(Ink.primary)
                            if let caption = caption(option) {
                                Text(verbatim: caption)
                                    .font(TypeScale.caption)
                                    .foregroundStyle(Ink.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.horizontal, 3)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: title(option)))
                .accessibilityHint(Text(verbatim: caption(option) ?? ""))
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

/// A choice between a few modes, each a row with a symbol, its name and what it means, and a
/// check on the one in use: clearer than a menu when the difference needs a sentence.
struct ChoiceList<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let symbol: (Value) -> String
    let title: (Value) -> String
    let detail: (Value) -> String

    var body: some View {
        VStack(spacing: 6) {
            ForEach(options, id: \.self) { option in
                let isOn = option == selection
                Button { selection = option } label: {
                    HStack(alignment: .top, spacing: Space.m) {
                        Image(systemName: symbol(option))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(isOn ? Palette.accent : Ink.tertiary)
                            .frame(width: 22)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: title(option)).font(TypeScale.rowStrong).foregroundStyle(Ink.primary)
                            Text(verbatim: detail(option)).font(TypeScale.label).foregroundStyle(Ink.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: Space.s)
                        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 16))
                            .foregroundStyle(isOn ? Palette.accent : Ink.quaternary)
                    }
                    .padding(10)
                    .background(isOn ? Palette.accent.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isOn ? Palette.accent.opacity(0.5) : Line.edge))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: Pictures

/// A tiny window in a theme's own colours: sidebar, list rows and an accent dot.
struct ThemePreview: View {
    let appearance: AppAppearance

    var body: some View {
        switch appearance {
        case .system:
            // Half light, half dark: it follows the Mac.
            ZStack {
                MiniWindow(colors: .light)
                MiniWindow(colors: .dark).mask(
                    GeometryReader { geometry in
                        Path { path in
                            path.move(to: CGPoint(x: geometry.size.width * 0.62, y: 0))
                            path.addLine(to: CGPoint(x: geometry.size.width, y: 0))
                            path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height))
                            path.addLine(to: CGPoint(x: geometry.size.width * 0.38, y: geometry.size.height))
                            path.closeSubpath()
                        }
                    }
                )
            }
        case .light: MiniWindow(colors: .light)
        case .dark: MiniWindow(colors: .dark)
        case .deepDark: MiniWindow(colors: .deep)
        case .white: MiniWindow(colors: .white)
        case .developer: MiniWindow(colors: .developer)
        }
    }

    struct Colors {
        var sidebar: UInt32, panel: UInt32, line: UInt32, text: UInt32, accent: UInt32
        static let light = Colors(sidebar: 0xF4F4F5, panel: 0xFFFFFF, line: 0xE4E4E7, text: 0xA1A1AA, accent: 0x3B82F6)
        static let dark = Colors(sidebar: 0x0B0B0C, panel: 0x131314, line: 0x27272A, text: 0x52525B, accent: 0x60A5FA)
        static let deep = Colors(sidebar: 0x000000, panel: 0x050505, line: 0x18181B, text: 0x3F3F46, accent: 0x60A5FA)
        static let white = Colors(sidebar: 0xFFFFFF, panel: 0xFFFFFF, line: 0xEDEDED, text: 0xB4B4BB, accent: 0x3B82F6)
        static let developer = Colors(sidebar: 0x010409, panel: 0x0D1117, line: 0x21262D, text: 0x484F58, accent: 0x3FB950)
    }

    struct MiniWindow: View {
        let colors: Colors

        var body: some View {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Capsule().fill(hex(colors.accent)).frame(width: 18, height: 3)
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule().fill(hex(colors.text).opacity(0.7)).frame(width: 22, height: 3)
                    }
                }
                .padding(8)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .frame(width: 40)
                .background(hex(colors.sidebar))
                Rectangle().fill(hex(colors.line)).frame(width: 1)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(0..<3, id: \.self) { index in
                        HStack(spacing: 5) {
                            let dot: UInt32 = index == 0 ? colors.accent : colors.text
                            Circle().fill(hex(dot)).frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Capsule().fill(hex(colors.text)).frame(width: 34, height: 3)
                                Capsule().fill(hex(colors.text).opacity(0.5)).frame(width: 48, height: 3)
                            }
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(hex(colors.panel))
            }
        }
    }
}

/// A sketch of a list layout, in the current theme's colours.
struct LayoutPreview: View {
    let layout: ListLayout

    var body: some View {
        HStack(spacing: 0) {
            switch layout {
            case .panels:
                column(width: 22, sidebar: true)
                divider
                rows(lines: 4).frame(width: 44)
                divider
                reader
            case .wide:
                column(width: 22, sidebar: true)
                divider
                rows(lines: 4)
            case .spark:
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { index in
                            Capsule().fill(index == 0 ? Ink.secondary : Ink.quaternary).frame(width: 16, height: 5)
                        }
                    }
                    rows(lines: 3)
                }
                .padding(.top, 6)
                .frame(maxWidth: 80)
                .frame(maxWidth: .infinity)
            case .minimal:
                VStack(alignment: .leading, spacing: 5) {
                    Capsule().fill(Ink.secondary).frame(width: 36, height: 5)
                    Capsule().fill(Ink.quaternary).frame(width: 52, height: 3)
                    rows(lines: 3)
                }
                .padding(.top, 8)
                .frame(maxWidth: 72)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Paper.panel)
    }

    private var divider: some View { Rectangle().fill(Line.hairline).frame(width: 1) }

    private func column(width: CGFloat, sidebar: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(0..<4, id: \.self) { _ in Capsule().fill(Ink.quaternary).frame(width: width - 8, height: 3) }
        }
        .padding(5)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Paper.sidebar)
    }

    private func rows(lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<lines, id: \.self) { index in
                HStack(spacing: 4) {
                    Circle().fill(index == 0 ? Palette.accent : Ink.quaternary).frame(width: 5, height: 5)
                    Capsule().fill(Ink.tertiary.opacity(0.6)).frame(height: 3)
                }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var reader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Capsule().fill(Ink.secondary).frame(width: 30, height: 4)
            ForEach(0..<4, id: \.self) { index in
                Capsule().fill(Ink.quaternary).frame(width: index == 3 ? 22 : 40, height: 3)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Three-line rows against one-line rows.
struct RowsPreview: View {
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 9) {
            ForEach(0..<(compact ? 5 : 3), id: \.self) { index in
                if compact {
                    HStack(spacing: 4) {
                        Circle().fill(index == 0 ? Palette.accent : Ink.quaternary).frame(width: 4, height: 4)
                        Capsule().fill(Ink.secondary.opacity(0.7)).frame(width: 20, height: 3)
                        Capsule().fill(Ink.tertiary.opacity(0.5)).frame(height: 3)
                    }
                } else {
                    HStack(alignment: .top, spacing: 5) {
                        Circle().fill(index == 0 ? Palette.accent : Ink.quaternary).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Capsule().fill(Ink.secondary.opacity(0.7)).frame(width: 26, height: 3)
                            Capsule().fill(Ink.tertiary.opacity(0.6)).frame(width: 52, height: 3)
                            Capsule().fill(Ink.tertiary.opacity(0.35)).frame(width: 44, height: 3)
                        }
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Paper.panel)
    }
}

/// The list and reader on the window, or in a rounded panel with a margin.
struct WindowStylePreview: View {
    let inset: Bool

    var body: some View {
        HStack(spacing: inset ? 4 : 0) {
            Rectangle().fill(Paper.sidebar).frame(width: 22)
            if !inset { Rectangle().fill(Line.hairline).frame(width: 1) }
            Rectangle().fill(Paper.panel)
                .clipShape(RoundedRectangle(cornerRadius: inset ? 5 : 0, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: inset ? 5 : 0, style: .continuous).strokeBorder(Line.edge).opacity(inset ? 1 : 0))
                .padding([.top, .bottom, .trailing], inset ? 5 : 0)
        }
        .background(Paper.sidebar)
    }
}

/// The standard colours against the colour-blind-safe set.
struct PalettePreview: View {
    let colorBlindSafe: Bool

    var body: some View {
        let colors: [UInt32] = colorBlindSafe
            ? [0x0072B2, 0xE69F00, 0x009E73, 0xCC79A7, 0x56B4E9, 0xD55E00]
            : [0x3B82F6, 0x22C55E, 0xEF4444, 0xA855F7, 0xF59E0B, 0x14B8A6]
        HStack(spacing: 5) {
            ForEach(colors, id: \.self) { color in
                Circle().fill(hex(color)).frame(width: 12, height: 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Paper.panel)
    }
}

/// A colour from a hex value, for the fixed colours in these pictures.
fileprivate func hex(_ value: UInt32) -> Color {
    Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
}
