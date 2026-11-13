import MailCore
import SwiftUI

// The moving pictures at the top of each welcome step. Each one draws its settled state
// straight away when motion is reduced, so nothing depends on an animation finishing.

// MARK: Welcome

/// The app icon with the everyday things of mail settling around it: they drift out from the
/// icon when the welcome opens, then float very gently in place.
struct WelcomeConstellation: View {
    let icon: AppIconChoice
    let iconDark: Bool
    var iconSize: CGFloat = 80
    /// Gathered closer around the icon, with a check: the "all set" picture.
    var gathered = false
    /// Without the things of mail around it: the welcome has its people band instead.
    var motes = true
    let still: Bool

    @State private var settled = false
    @State private var ripple = false

    struct Mote {
        let symbol: String
        /// Where it rests, as an angle (degrees, 0 = right) and a share of the space around the icon.
        let angle: Double
        let reach: Double
        let size: CGFloat
        let hue: Int
    }

    static let motes: [Mote] = [
        Mote(symbol: "envelope.fill", angle: 200, reach: 0.92, size: 34, hue: 0),
        Mote(symbol: "heart.fill", angle: 232, reach: 0.62, size: 28, hue: 4),
        Mote(symbol: "star.fill", angle: 270, reach: 0.8, size: 24, hue: 3),
        Mote(symbol: "bubble.left.fill", angle: 305, reach: 0.66, size: 30, hue: 1),
        Mote(symbol: "paperplane.fill", angle: 338, reach: 0.95, size: 32, hue: 5),
        Mote(symbol: "bell.fill", angle: 20, reach: 0.84, size: 28, hue: 3),
        Mote(symbol: "checkmark", angle: 58, reach: 0.68, size: 26, hue: 1),
        Mote(symbol: "at", angle: 112, reach: 0.7, size: 26, hue: 2),
        Mote(symbol: "lock.fill", angle: 148, reach: 0.82, size: 28, hue: 6),
        Mote(symbol: "calendar", angle: 185, reach: 0.5, size: 24, hue: 0),
    ]

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still || !settled || !motes)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    if motes {
                        ForEach(Array(Self.motes.enumerated()), id: \.offset) { index, mote in
                            moteView(mote, index: index, in: size, time: time)
                        }
                    }
                    iconView
                        .position(x: size.width / 2, y: size.height / 2)
                }
            }
        }
        .accessibilityHidden(true)
        .onAppear(perform: arrive)
    }

    private var iconView: some View {
        ZStack {
            // One soft ring goes out as the icon lands, like mail arriving.
            Circle()
                .strokeBorder(Palette.accent.opacity(0.35), lineWidth: 1.5)
                .frame(width: iconSize, height: iconSize)
                .scaleEffect(ripple ? 2.1 : 0.9)
                .opacity(ripple ? 0 : (still ? 0 : 0.8))
            AppIconPreview(choice: icon, dark: iconDark, size: iconSize)
                .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
                .overlay(alignment: .bottomTrailing) {
                    if gathered {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: iconSize * 0.34, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Status.done)
                            .background(Circle().fill(Paper.popover).padding(-2))
                            .offset(x: iconSize * 0.1, y: iconSize * 0.1)
                            .scaleEffect(settled || still ? 1 : 0.01)
                            .opacity(settled || still ? 1 : 0)
                            .animation(still ? nil : .spring(response: 0.4, dampingFraction: 0.5).delay(0.35), value: settled)
                    }
                }
                .scaleEffect(settled || still ? 1 : 0.3)
                .rotationEffect(.degrees(settled || still ? 0 : -12))
                .opacity(settled || still ? 1 : 0)
        }
    }

    private func moteView(_ mote: Mote, index: Int, in size: CGSize, time: TimeInterval) -> some View {
        let shown = settled || still
        let radians = mote.angle * .pi / 180
        // Gathered a little closer for the last step, but never behind the icon.
        let reach = gathered ? mote.reach * 0.86 : mote.reach
        // The space around the icon is wider than it is tall, so the ring is an ellipse.
        let spanX = max(size.width / 2 - 24, iconSize)
        let spanY = max(size.height / 2 - 18, iconSize * 0.6)
        let restX = cos(radians) * spanX * reach
        let restY = sin(radians) * spanY * reach
        let drift = still ? 0 : sin(time * 0.7 + Double(index) * 1.3) * 3
        let sway = still ? 0 : cos(time * 0.5 + Double(index) * 0.9) * 2
        let color = Palette.account(mote.hue)
        return Image(systemName: mote.symbol)
            .font(.system(size: mote.size * 0.48, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: mote.size, height: mote.size)
            .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: mote.size * 0.32, style: .continuous))
            .rotationEffect(.degrees(shown ? (Double(index % 3) - 1) * 8 : 0))
            .scaleEffect(shown ? 1 : 0.3)
            // On the last step the icon wears its own check, so the small one steps aside.
            .opacity(shown && !(gathered && mote.symbol == "checkmark") ? 1 : 0)
            .position(x: size.width / 2 + (shown ? restX + sway : 0), y: size.height / 2 + (shown ? restY + drift : 0))
            .animation(still ? nil : .spring(response: 0.55, dampingFraction: 0.58).delay(0.15 + Double(index) * 0.04), value: settled)
    }

    private func arrive() {
        guard !still, !settled else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) { settled = true }
        withAnimation(.easeOut(duration: 1.1).delay(0.12)) { ripple = true }
    }
}

// MARK: People

/// The welcome's opening picture: rows of people (letter avatars in their colours) sliding slowly
/// past on a slight slant, the way the website's front page does it, with the app icon in front.
/// Rows sit at different depths, so nearer ones are larger, brighter and a little quicker; now
/// and then someone near the middle lifts with an unread dot, as if they just wrote. The band
/// fades out at its edges. It stands still when motion is reduced.
struct PeopleBand: View {
    let still: Bool
    @Environment(\.colorScheme) private var colorScheme
    /// When the band first appeared; each piece pops in a moment after, nearest the icon first.
    @State private var appeared = Date()

    /// Initials, one or two letters like the avatars in the list.
    private static let initials = ["AM", "J", "SK", "L", "TP", "R", "OE", "H", "CV", "B", "DG", "F", "I", "NS", "K", "PJ", "E", "MR", "G", "VB"]
    private static let perRow = 24
    /// How near each row is, top to bottom: 1 is nearest.
    private static let depths: [CGFloat] = [0.64, 0.9, 0.72, 1.0, 0.68, 0.86, 0.62]
    private static let dot: CGFloat = 48
    /// The size the initials are shaped at; they're scaled from there.
    private static let letterSize: CGFloat = 24

    /// Each initial as an outline, made once. Drawn as text, the letters shook: text is laid
    /// out and nudged onto whole pixels on its own, so as everything drifts by a fraction of a
    /// point each frame the letters wobbled against their circles. As shapes they move exactly
    /// with them.
    private static let letterShapes: [Path] = initials.map { letters in
        #if os(macOS)
        let font = NSFont.systemFont(ofSize: letterSize, weight: .semibold) as CTFont
        #else
        let font = UIFont.systemFont(ofSize: letterSize, weight: .semibold) as CTFont
        #endif
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: letters, attributes: [.init(kCTFontAttributeName as String): font]))
        let outline = CGMutablePath()
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for (glyph, position) in zip(glyphs, positions) {
                // Core Text draws upward; flip it to SwiftUI's downward y.
                var place = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: position.x, ty: position.y)
                if let shape = CTFontCreatePathForGlyph(font, glyph, &place) { outline.addPath(shape) }
            }
        }
        let box = outline.boundingBoxOfPath
        return Path(outline).offsetBy(dx: -box.midX, dy: -box.midY)
    }
    private static let rowPitch: CGFloat = 50

    var body: some View {
        // Every frame the display shows, with no cap: a cap (30 or 60 a second) lands unevenly on
        // a 120 Hz screen, so the rows moved in uneven steps and the people seemed to shake.
        TimelineView(.animation(paused: still)) { context in
            // A fixed moment when still, so the picture is the same every time.
            let time = still ? 21 : context.date.timeIntervalSinceReferenceDate
            let since = still ? 10 : max(0, context.date.timeIntervalSince(appeared))
            Canvas { canvas, size in
                draw(in: &canvas, size: size, time: time, since: since)
            }
        }
        // Fades out at all four edges.
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.16),
                                     .init(color: .black, location: 0.84), .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.12), location: 0.1),
                                     .init(color: .black.opacity(0.6), location: 0.22), .init(color: .black, location: 0.34),
                                     .init(color: .black, location: 0.7), .init(color: .black.opacity(0.5), location: 0.84),
                                     .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// What sits in each place along a row: people, drawn like Margin's avatars (their initials
    /// on a circle in their colour), with now and then a star (a VIP) or a sparkle (the assistant)
    /// between them. Nothing here is a shape the app doesn't have.
    fileprivate enum Piece { case person, star, sparkle }

    private static let pattern: [Piece] = [.person, .person, .star, .person, .person, .person, .sparkle,
                                           .person, .person, .person, .star, .person, .person, .sparkle]

    /// A springy 0 → 1 with a little overshoot, for a piece popping in: p is 0 at the start and
    /// settles by about 1.
    static func pop(_ progress: Double) -> Double {
        guard progress > 0 else { return 0 }
        guard progress < 1.4 else { return 1 }
        return 1 - exp(-4.5 * progress) * cos(2 * .pi * 1.1 * progress)
    }

    private func draw(in canvas: inout GraphicsContext, size: CGSize, time: TimeInterval, since: TimeInterval) {
        canvas.translateBy(x: size.width / 2, y: size.height / 2)
        canvas.rotate(by: .degrees(-8))
        let halfWidth = size.width * 0.62 + Self.dot
        let rows = Self.depths.count
        let top = -CGFloat(rows - 1) * Self.rowPitch / 2
        let paler = colorScheme == .dark ? 0.78 : 1.0
        let symbols: [Piece: GraphicsContext.ResolvedImage] = [
            .star: canvas.resolve(Image(systemName: "star.fill")),
            .sparkle: canvas.resolve(Image(systemName: "sparkle")),
        ]

        // Every 2.6 seconds someone near the middle lifts for a moment.
        let beat = time / 2.6
        let lifted = Int(beat.rounded(.down))
        let lift = max(0, sin(min(beat - Double(lifted), 0.5) * 2 * .pi))
        let liftedRow = 1 + (lifted * 3) % (rows - 2)

        for row in 0..<rows {
            let depth = Self.depths[row]
            let dot = Self.dot * depth
            let pitch = dot + 16 * depth
            let loop = pitch * CGFloat(Self.perRow)
            // Nearer rows come round sooner: 60 to 90-odd seconds; alternate rows the other way.
            let seconds = Double(95 - 35 * depth) + Double(row) * 3
            func offset(at moment: TimeInterval) -> CGFloat {
                let along = CGFloat((moment / seconds).truncatingRemainder(dividingBy: 1)) * loop
                return row % 2 == 1 ? -along : along
            }
            let shift = offset(at: time)
            let y = top + CGFloat(row) * Self.rowPitch
            let alpha = (0.32 + 0.6 * Double((depth - 0.6) / 0.4)) * paler
            // Dot k sits at k × pitch − shift; a full turn of `shift` moves exactly one row of
            // people, so the loop has no seam.
            var index = Int(((-halfWidth + shift) / pitch).rounded(.down))
            var x = CGFloat(index) * pitch - shift
            // The one nearest the middle of the lifted row when the beat began is the one who
            // lifts, and stays the one until the beat ends (picking again every frame let the
            // lift hop to a neighbour as the row moved on).
            var middle = Int((offset(at: Double(lifted) * 2.6) / pitch).rounded())
            while Self.pattern[(((middle % Self.perRow) + Self.perRow) % Self.perRow + row * 3) % Self.pattern.count].isSticker { middle += 1 }
            while x < halfWidth {
                let slot = ((index % Self.perRow) + Self.perRow) % Self.perRow
                let piece = Self.pattern[(slot + row * 3) % Self.pattern.count]
                // Popping in: out from the icon, nearest first, with a little bounce.
                let distance = Double(hypot(x, y))
                let wait = 0.08 + distance * 0.0013 + Double((slot * 5 + row) % 7) * 0.025
                let popped = Self.pop((since - wait) / 0.7)
                if popped <= 0.001 { x += pitch; index += 1; continue }
                let isLifted = !still && row == liftedRow && index == middle
                let scale: CGFloat = (isLifted ? 1 + 0.16 * lift : 1) * (piece == .sparkle ? 0.5 : piece.isSticker ? 0.62 : 1)
                    * CGFloat(popped)
                let size = dot * scale
                let color = piece == .star ? Status.star : piece == .sparkle ? Palette.accent : Palette.account(slot + row * 2)
                // People stay upright like real avatars; the stars and sparkles wobble a little.
                let seed = Double(slot * 13 + row * 7)
                let tilt = piece.isSticker
                    ? (seed.truncatingRemainder(dividingBy: 24) - 12) + (still ? 0 : sin(time * 0.8 + seed) * 5) + (1 - min(popped, 1)) * -30
                    : (1 - min(popped, 1)) * -12

                var layer = canvas
                layer.opacity = (isLifted ? min(1, alpha + 0.3 * lift) : alpha) * min(1, popped * 2.5)
                // Starting a little toward the icon, as if thrown out from it.
                let out = CGFloat(0.55 + 0.45 * min(popped, 1.05))
                layer.translateBy(x: x * out, y: y * out)
                layer.rotate(by: .degrees(tilt))
                let rect = CGRect(x: -size / 2, y: -size / 2, width: size, height: size)
                if let image = symbols[piece] {
                    var symbol = image
                    symbol.shading = .color(color)
                    layer.draw(symbol, in: rect)
                } else {
                    // As `Avatar` draws them: white initials, semibold, on the person's colour.
                    layer.fill(Path(ellipseIn: rect), with: .color(color))
                    var text = layer
                    let fit = size * 0.38 / Self.letterSize
                    text.scaleBy(x: fit, y: fit)
                    text.fill(Self.letterShapes[(slot * 7 + row * 3) % Self.letterShapes.count], with: .color(.white))
                }
                if isLifted && lift > 0.05 {
                    // An unread dot, like new mail from them.
                    let badge = size * 0.26
                    let spot = CGRect(x: rect.maxX - badge * 0.9, y: rect.minY - badge * 0.1, width: badge, height: badge)
                    var mark = layer
                    mark.opacity = lift
                    mark.fill(Path(ellipseIn: spot.insetBy(dx: -2, dy: -2)), with: .color(Paper.popover))
                    mark.fill(Path(ellipseIn: spot), with: .color(Palette.accent))
                }
                x += pitch
                index += 1
            }
        }
    }

}

private extension PeopleBand.Piece {
    var isSticker: Bool { self != .person }
}

// MARK: Look

/// A small window drawn in the chosen appearance and layout, that changes shape as you pick.
/// A layout tile for an iPhone: the top of a phone showing how the list starts, in the same
/// quiet tones as the Settings tiles. "Side by side" has no sidebar on a phone; it's the plain list.
struct PhoneLayoutPreview: View {
    let layout: ListLayout

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 5) {
            Capsule().fill(Ink.primary.opacity(0.85)).frame(width: 18, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 1)
            switch layout {
            case .spark:
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { index in
                        Capsule().fill(index == 0 ? Ink.secondary : Ink.quaternary).frame(width: 11, height: 4)
                    }
                }
            case .minimal:
                Capsule().fill(Ink.secondary).frame(width: 22, height: 4)
                Capsule().fill(Ink.quaternary).frame(width: 32, height: 2)
            default:
                Capsule().fill(Ink.secondary).frame(width: 28, height: 5)
            }
            ForEach(0..<3, id: \.self) { index in
                HStack(spacing: 3) {
                    Circle().fill(index == 0 ? Palette.accent : Ink.quaternary).frame(width: 4, height: 4)
                    Capsule().fill(Ink.tertiary.opacity(0.6)).frame(height: 3)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .frame(width: 50, height: 60, alignment: .top)
        .background(Paper.panel, in: shape)
        .overlay(shape.strokeBorder(Ink.tertiary.opacity(0.7), lineWidth: 2))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.top, 6)
        .clipped()
        .background(Paper.sidebar)
    }
}

/// A compact row of the Settings picture tiles: each drawn at its Settings size and scaled
/// down, with no name under it (the section shows the chosen one), so a whole choice takes one
/// short row and the step fits without scrolling. Wraps when the window is narrow.
struct MiniChoices<Value: Hashable, Preview: View>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    var width: CGFloat = 60
    let still: Bool
    @ViewBuilder let preview: (Value) -> Preview

    private var scale: CGFloat { width / 100 }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: width + 6, maximum: width + 6), spacing: Space.s)],
                  alignment: .leading, spacing: Space.s) {
            ForEach(options, id: \.self) { option in
                let isOn = option == selection
                Button { selection = option } label: {
                    preview(option)
                        .frame(width: 100, height: 64)
                        .scaleEffect(scale)
                        .frame(width: width, height: 64 * scale)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Line.edge))
                        .padding(3)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Palette.accent, lineWidth: 2).opacity(isOn ? 1 : 0))
                        .contentShape(Rectangle())
                }
                .buttonStyle(BounceButtonStyle(still: still))
                .accessibilityLabel(Text(verbatim: title(option)))
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }
}

/// A theme tile for an iPhone: the same phone top as the layout tiles, in that theme's colours
/// (half light, half dark when it follows the system).
struct PhoneThemePreview: View {
    let appearance: AppAppearance

    var body: some View {
        if appearance == .system {
            ZStack {
                tile(.light)
                tile(.dark).mask(LookPreview.DiagonalHalf())
            }
        } else {
            tile(LookPreview.colors(appearance))
        }
    }

    private func tile(_ colors: ThemePreview.Colors) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12, style: .continuous)
        return VStack(alignment: .leading, spacing: 5) {
            Capsule().fill(Color.black).frame(width: 18, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 1)
            Capsule().fill(tone(colors.text)).frame(width: 28, height: 5)
            ForEach(0..<3, id: \.self) { index in
                HStack(spacing: 3) {
                    Circle().fill(index == 0 ? tone(colors.accent) : tone(colors.text).opacity(0.5)).frame(width: 4, height: 4)
                    Capsule().fill(tone(colors.text).opacity(0.6)).frame(height: 3)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .frame(width: 50, height: 60, alignment: .top)
        .background(tone(colors.panel), in: shape)
        .overlay(shape.strokeBorder(colors.sidebar < 0x808080 ? Color.white.opacity(0.28) : tone(0x1C1C1E).opacity(0.85), lineWidth: 2))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.top, 6)
        .clipped()
        .background(tone(colors.sidebar))
    }
}

struct LookPreview: View {
    let appearance: AppAppearance
    let layout: ListLayout
    var inset = false
    let icon: AppIconChoice
    let iconDark: Bool
    /// An iPhone: the top of a phone showing the list, since there's no window or sidebar.
    var phone = false
    /// Not drawn from directly (the avatars read the palette); here so a change redraws them.
    var colorBlindSafe = false
    let still: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if phone {
                phoneScene
            } else {
                Group {
                    if appearance == .system {
                        // Half light, half dark: it follows the device.
                        ZStack {
                            window(.light)
                            window(.dark).mask(DiagonalHalf())
                        }
                    } else {
                        window(Self.colors(appearance))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Line.edge))
                .shadow(color: .black.opacity(0.10), radius: 18, y: 8)
                .padding(.trailing, 22)
                .padding(.bottom, 16)
            }

            AppIconPreview(choice: icon, dark: iconDark, size: 46)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                .id(icon)
                .transition(still ? .identity : .scale(scale: 0.6).combined(with: .opacity))
                .keyframeAnimator(initialValue: 1.0, trigger: icon) { content, scale in
                    content.scaleEffect(still ? 1 : scale, anchor: .bottom)
                } keyframes: { _ in
                    SpringKeyframe(1.14, duration: 0.18)
                    SpringKeyframe(1.0, duration: 0.35, spring: .bouncy)
                }
        }
        .animation(still ? nil : .spring(response: 0.45, dampingFraction: 0.84), value: layout)
        .animation(still ? nil : .easeInOut(duration: 0.35), value: appearance)
        .animation(still ? nil : .spring(response: 0.45, dampingFraction: 0.84), value: inset)
        .animation(still ? nil : .spring(response: 0.4, dampingFraction: 0.8), value: icon)
        .accessibilityHidden(true)
    }

    /// The top of a phone rising from the bottom edge, its screen in the chosen look.
    private var phoneScene: some View {
        GeometryReader { geometry in
            let width: CGFloat = min(200, geometry.size.width - 40)
            let shape = UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30, style: .continuous)
            Group {
                if appearance == .system {
                    ZStack {
                        phoneScreen(.light)
                        phoneScreen(.dark).mask(DiagonalHalf())
                    }
                } else {
                    phoneScreen(Self.colors(appearance))
                }
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 25, topTrailingRadius: 25, style: .continuous))
            .padding([.top, .horizontal], 5)
            .background(tone(0x1C1C1E), in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1).padding(1))
            .frame(width: width, height: geometry.size.height + 30, alignment: .top)
            .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }
        .mask(LinearGradient(stops: [.init(color: .black, location: 0.78), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .padding(.horizontal, -12)
        .clipped()
    }

    private func phoneScreen(_ colors: ThemePreview.Colors) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Capsule().fill(Color.black).frame(width: 46, height: 13)
                .frame(maxWidth: .infinity)
                .padding(.top, 7)
            switch layout {
            case .spark:
                Capsule().fill(tone(colors.text)).frame(width: 44, height: 6)
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { index in
                        Capsule().fill(index == 0 ? tone(colors.accent) : tone(colors.text).opacity(0.35)).frame(width: 26, height: 7)
                    }
                }
                .transition(.opacity)
            case .minimal:
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(tone(colors.text)).frame(width: 58, height: 8)
                    Capsule().fill(tone(colors.text).opacity(0.45)).frame(width: 84, height: 3)
                }
                .transition(.opacity)
            default:
                Capsule().fill(tone(colors.text)).frame(width: 70, height: 10)
                    .transition(.opacity)
            }
            ForEach(0..<4, id: \.self) { index in
                HStack(spacing: 5) {
                    unreadDot(index == 0, colors, size: 5)
                    avatar(index, size: 14)
                    VStack(alignment: .leading, spacing: 3) {
                        Capsule().fill(tone(colors.text)).frame(width: 46, height: 3)
                        Capsule().fill(tone(colors.text).opacity(0.5)).frame(maxWidth: 110).frame(height: 3)
                    }
                }
                .padding(.top, layout == .minimal && index == 2 ? 6 : 0)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(tone(colors.panel))
    }

    private func window(_ colors: ThemePreview.Colors) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let sidebar: CGFloat = layout == .panels || layout == .wide ? width * 0.2 : 0
            let reader: CGFloat = layout == .panels ? width * 0.42 : 0
            let gap: CGFloat = inset ? 6 : 0
            VStack(spacing: 0) {
                #if os(macOS)
                HStack(spacing: 5) {
                    ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { Circle().fill(tone($0).opacity(0.9)).frame(width: 7, height: 7) }
                    Spacer()
                }
                .padding(.horizontal, 9)
                .frame(height: Look.gap(20))
                .background(tone(colors.sidebar))
                #endif
                HStack(spacing: 0) {
                    // Sidebar
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule().fill(tone(colors.accent)).frame(width: max(sidebar - 22, 0), height: 4)
                        ForEach(0..<4, id: \.self) { _ in
                            Capsule().fill(tone(colors.text).opacity(0.6)).frame(width: max(sidebar - 18, 0), height: 3)
                        }
                    }
                    .padding(.top, 10)
                    .padding(.leading, sidebar > 0 ? 9 : 0)
                    .frame(width: sidebar, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .opacity(sidebar > 0 ? 1 : 0)
                    .clipped()

                    // The list (and the reader beside it), on the window or in an inset panel.
                    HStack(spacing: 0) {
                        list(colors)
                        Rectangle().fill(tone(colors.line)).frame(width: reader > 0 ? 1 : 0)
                        readerPane(colors)
                            .frame(width: reader)
                            .opacity(reader > 0 ? 1 : 0)
                            .clipped()
                    }
                    .background(tone(colors.panel))
                    .clipShape(RoundedRectangle(cornerRadius: inset ? 7 : 0, style: .continuous))
                    .overlay(alignment: .leading) {
                        Rectangle().fill(tone(colors.line)).frame(width: sidebar > 0 && !inset ? 1 : 0)
                    }
                    .padding(.vertical, gap)
                    .padding(.trailing, gap)
                    .padding(.leading, sidebar > 0 ? gap : 0)
                }
                .background(tone(colors.sidebar))
            }
        }
    }

    private func list(_ colors: ThemePreview.Colors) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if layout == .spark {
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { index in
                        Capsule().fill(index == 0 ? tone(colors.accent) : tone(colors.text).opacity(0.35)).frame(width: 22, height: 6)
                    }
                }
                .transition(.opacity)
            } else if layout == .minimal {
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(tone(colors.text)).frame(width: 54, height: 7)
                    Capsule().fill(tone(colors.text).opacity(0.45)).frame(width: 78, height: 3)
                }
                .transition(.opacity)
            }
            ForEach(0..<3, id: \.self) { index in
                HStack(spacing: 4) {
                    unreadDot(index == 0, colors, size: 4)
                    avatar(index, size: 11)
                    VStack(alignment: .leading, spacing: 3) {
                        Capsule().fill(tone(colors.text)).frame(width: 40, height: 3)
                        Capsule().fill(tone(colors.text).opacity(0.5)).frame(maxWidth: 90).frame(height: 3)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// As in the real list: the unread dot, then the sender's avatar in their colour.
    private func unreadDot(_ unread: Bool, _ colors: ThemePreview.Colors, size: CGFloat) -> some View {
        Circle().fill(unread ? tone(colors.accent) : .clear).frame(width: size, height: size)
    }

    private func avatar(_ index: Int, size: CGFloat) -> some View {
        Circle().fill(Palette.account([4, 1, 2, 3][index % 4])).frame(width: size, height: size)
    }

    private func readerPane(_ colors: ThemePreview.Colors) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Capsule().fill(tone(colors.text)).frame(width: 52, height: 5)
            ForEach(0..<5, id: \.self) { index in
                Capsule().fill(tone(colors.text).opacity(0.45)).frame(width: index == 4 ? 40 : 76, height: 3)
            }
        }
        .padding(10)
        .frame(width: 100, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    static func colors(_ appearance: AppAppearance) -> ThemePreview.Colors {
        switch appearance {
        case .system, .light: .light
        case .dark: .dark
        case .deepDark: .deep
        case .white: .white
        case .developer: .developer
        }
    }

    struct DiagonalHalf: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.width * 0.62, y: 0))
                path.addLine(to: CGPoint(x: rect.width, y: 0))
                path.addLine(to: CGPoint(x: rect.width, y: rect.height))
                path.addLine(to: CGPoint(x: rect.width * 0.38, y: rect.height))
                path.closeSubpath()
            }
        }
    }
}

// MARK: Alerts

/// What would reach your lock screen with each alerts choice: a few banners dropping in, or
/// none and a quiet bell.
struct AlertsPreview: View {
    let alerts: NewMailAlerts
    let icon: AppIconChoice
    let iconDark: Bool
    let still: Bool

    enum Kind: Hashable { case person, code, vip, newsletter, receipt }

    private var kinds: [Kind] {
        switch alerts {
        case .all: [.person, .newsletter, .receipt]
        case .people: [.person, .code]
        case .vips: [.vip, .code]
        case .none: []
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Cascaded like cards: each newer one lies over the one before, which still shows
            // enough to tell a person from a code or a newsletter.
            ZStack(alignment: .top) {
                ForEach(Array(kinds.enumerated()), id: \.element) { index, kind in
                    let depth = CGFloat(kinds.count - 1 - index)
                    banner(kind)
                        .scaleEffect(1 - depth * 0.04, anchor: .top)
                        .offset(y: CGFloat(index) * 34)
                        .zIndex(Double(index))
                        .transition(still ? .identity : .asymmetric(
                            insertion: .move(edge: .top).combined(with: .scale(scale: 0.85, anchor: .top)).combined(with: .opacity).combined(with: .blur),
                            removal: .opacity.combined(with: .scale(scale: 0.94))))
                }
            }
            if kinds.isEmpty {
                Image(systemName: "bell.slash.fill")
                    .font(.system(size: Look.size(26), weight: .medium))
                    .foregroundStyle(Ink.tertiary)
                    .frame(width: 64, height: 64)
                    .background(Fill.one, in: Circle())
                    .padding(.top, 26)
                    .transition(still ? .identity : .scale(scale: 0.7).combined(with: .opacity))
            }
        }
        .frame(maxWidth: 360)
        .frame(height: 128, alignment: .top)
        .frame(maxWidth: .infinity)
        .animation(still ? nil : .spring(response: 0.45, dampingFraction: 0.62), value: alerts)
        .accessibilityHidden(true)
    }

    private func banner(_ kind: Kind) -> some View {
        HStack(spacing: 10) {
            AppIconPreview(choice: icon, dark: iconDark, size: 30)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    glyph(kind)
                    Capsule().fill(Ink.primary.opacity(0.75)).frame(width: kind == .code ? 44 : 64, height: 5)
                    Spacer(minLength: 0)
                    Capsule().fill(Ink.quaternary).frame(width: 22, height: 4)
                }
                if kind == .code {
                    HStack(spacing: 3) {
                        ForEach(0..<6, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 2).fill(Palette.accent.opacity(0.7)).frame(width: 7, height: 9)
                        }
                    }
                } else {
                    Capsule().fill(Ink.tertiary.opacity(0.6)).frame(maxWidth: 170).frame(height: 4)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Paper.popover, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Line.edge))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }

    @ViewBuilder
    private func glyph(_ kind: Kind) -> some View {
        switch kind {
        case .person:
            Circle().fill(Palette.account(4)).frame(width: 12, height: 12)
        case .vip:
            Image(systemName: "star.fill").font(.system(size: Look.size(10), weight: .bold)).foregroundStyle(Status.star)
        case .code:
            Image(systemName: "key.fill").font(.system(size: Look.size(10), weight: .bold)).foregroundStyle(Palette.accent)
        case .newsletter:
            Image(systemName: "newspaper.fill").font(.system(size: Look.size(10), weight: .bold)).foregroundStyle(Ink.tertiary)
        case .receipt:
            Image(systemName: "bag.fill").font(.system(size: Look.size(10), weight: .bold)).foregroundStyle(Ink.tertiary)
        }
    }
}

// MARK: Relay

/// Two ways from your provider to this device: your mail goes straight across (with a lock), and
/// only a "new mail" nudge goes round through Margin's relay. With the relay off, that lane goes
/// quiet and the device checks on its own.
struct RelayPreview: View {
    let on: Bool
    let icon: AppIconChoice
    let iconDark: Bool
    let still: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still)) { context in
            let time = still ? 0.45 : context.date.timeIntervalSinceReferenceDate
            GeometryReader { geometry in
                let width = geometry.size.width
                let height = geometry.size.height
                let provider = CGPoint(x: 34, y: height * 0.36)
                let device = CGPoint(x: width - 34, y: height * 0.36)
                let relay = CGPoint(x: width / 2, y: height - 40)
                let arc = CGPoint(x: width / 2, y: -height * 0.18)
                ZStack {
                    // Your mail, straight across.
                    Path { path in path.move(to: provider); path.addQuadCurve(to: device, control: arc) }
                        .stroke(Ink.quaternary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    // The nudge, round through the relay.
                    Path { path in path.move(to: provider); path.addLine(to: relay); path.addLine(to: device) }
                        .stroke(Palette.accent.opacity(on ? 0.55 : 0.15), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 5]))

                    let mailPhase = (time * 0.32).truncatingRemainder(dividingBy: 1)
                    Image(systemName: "envelope.fill")
                        .font(.system(size: Look.size(11), weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Ink.secondary, in: Circle())
                        .position(Self.curve(provider, arc, device, at: mailPhase))
                        .opacity(Self.fade(mailPhase))
                    if on {
                        let nudgePhase = (time * 0.32 + 0.5).truncatingRemainder(dividingBy: 1)
                        Circle().fill(Palette.accent).frame(width: 10, height: 10)
                            .shadow(color: Palette.accent.opacity(0.5), radius: 6)
                            .position(Self.bend(provider, relay, device, at: nudgePhase))
                            .opacity(Self.fade(nudgePhase))
                    }

                    // The lock over the straight lane.
                    Label { Text("Your mail") } icon: { Image(systemName: "lock.fill") }
                        .font(TypeScale.caption.weight(.medium))
                        .foregroundStyle(Ink.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Paper.popover, in: Capsule())
                        .overlay(Capsule().strokeBorder(Line.edge))
                        .position(x: width / 2, y: height * 0.08)

                    node(Image(systemName: "tray.full.fill"), label: "Your provider").position(provider)
                    node(Image(systemName: "dot.radiowaves.left.and.right"), label: "Margin's relay", tint: on ? Palette.accent : Ink.quaternary)
                        .opacity(on ? 1 : 0.55)
                        .position(relay)
                    VStack(spacing: 6) {
                        AppIconPreview(choice: icon, dark: iconDark, size: 40)
                            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                        Text("This device").font(TypeScale.caption).foregroundStyle(Ink.tertiary).fixedSize()
                    }
                    .offset(y: 11)
                    .position(device)
                }
            }
        }
        .animation(still ? nil : .spring(response: 0.45, dampingFraction: 0.7), value: on)
        .accessibilityHidden(true)
    }

    private func node(_ image: Image, label: LocalizedStringKey, tint: Color = Ink.secondary) -> some View {
        VStack(spacing: 6) {
            image
                .font(.system(size: Look.size(17), weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(Fill.one, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Line.edge))
            Text(label).font(TypeScale.caption).foregroundStyle(Ink.tertiary).fixedSize()
        }
        .offset(y: 11)
    }

    /// In at the start, out at the end of each trip.
    static func fade(_ phase: Double) -> Double { min(1, min(phase, 1 - phase) * 8) }

    static func curve(_ start: CGPoint, _ control: CGPoint, _ end: CGPoint, at t: Double) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                       y: u * u * start.y + 2 * u * t * control.y + t * t * end.y)
    }

    static func bend(_ start: CGPoint, _ middle: CGPoint, _ end: CGPoint, at t: Double) -> CGPoint {
        if t < 0.5 {
            let k = t * 2
            return CGPoint(x: start.x + (middle.x - start.x) * k, y: start.y + (middle.y - start.y) * k)
        }
        let k = (t - 0.5) * 2
        return CGPoint(x: middle.x + (end.x - middle.x) * k, y: middle.y + (end.y - middle.y) * k)
    }
}

// MARK: Motion pieces

/// Out of focus and faded: the welcome's steps blur into one another rather than slide.
struct Defocus: ViewModifier {
    let amount: Double
    var shift: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .blur(radius: 10 * amount)
            .opacity(1 - amount)
            .offset(x: shift.width * amount, y: shift.height * amount)
    }
}

extension AnyTransition {
    static var blur: AnyTransition { .modifier(active: Defocus(amount: 1), identity: Defocus(amount: 0)) }

    /// The next step comes into focus from the side it lies on; the last one just goes soft.
    static func step(forward: Bool) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(active: Defocus(amount: 1, shift: CGSize(width: forward ? 28 : -28, height: 0)),
                                 identity: Defocus(amount: 0, shift: CGSize(width: forward ? 28 : -28, height: 0))),
            removal: .modifier(active: Defocus(amount: 1, shift: CGSize(width: 0, height: -6)), identity: Defocus(amount: 0))
        )
    }
}

/// Lines of a step that rise into place one after another when the step appears.
struct Rise: ViewModifier {
    let order: Int
    let still: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown || still ? 1 : 0)
            .offset(y: shown || still ? 0 : 14)
            .scaleEffect(shown || still ? 1 : 0.94)
            .blur(radius: shown || still ? 0 : 3)
            .onAppear {
                guard !still else { return }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.68).delay(0.12 + Double(order) * 0.06)) { shown = true }
            }
    }
}

extension View {
    func rise(_ order: Int, still: Bool) -> some View { modifier(Rise(order: order, still: still)) }
}

/// A colour from a hex value, for the fixed colours of the pictures.
fileprivate func tone(_ value: Int) -> Color {
    Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
}

fileprivate func tone(_ value: UInt32) -> Color { tone(Int(value)) }

/// A choice that gives a little under the finger and springs back.
struct BounceButtonStyle: ButtonStyle {
    let still: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !still ? 0.95 : 1)
            .animation(still ? nil : .spring(response: 0.3, dampingFraction: 0.5), value: configuration.isPressed)
    }
}

/// The onboarding's own buttons on a phone: a pill that hugs its label (never the full width),
/// ink for the step's main action and a soft fill for the other, with a springy press.
/// `circle` makes an icon-only round button the same height, for Back.
struct OnboardingPillStyle: ButtonStyle {
    var prominent = true
    var circle = false
    /// Takes the width it's offered, so stacked pills come out the same width.
    var fills = false
    let still: Bool

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(TypeScale.rowStrong.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .foregroundStyle(prominent ? Ink.inverse : Ink.primary)
            .padding(.horizontal, circle ? 0 : 26)
            .frame(maxWidth: fills ? .infinity : nil)
            .frame(width: circle ? touchButtonHeight : nil, height: touchButtonHeight)
            .background {
                Capsule(style: .continuous)
                    .fill(prominent ? AnyShapeStyle(Ink.primary) : AnyShapeStyle(pressed ? Fill.three : Fill.one))
                    .overlay {
                        if !prominent { Capsule(style: .continuous).strokeBorder(Line.hairline) }
                    }
                    .shadow(color: prominent ? Color.black.opacity(pressed ? 0.08 : 0.18) : .clear,
                            radius: pressed ? 3 : 10, y: pressed ? 1 : 5)
            }
            .contentShape(Capsule(style: .continuous))
            .scaleEffect(pressed && !still ? 0.94 : 1)
            .animation(still ? nil : .spring(response: 0.28, dampingFraction: 0.55), value: pressed)
    }
}
