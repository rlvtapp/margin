import MailCore
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The first launch: what Margin is, adding a mailbox (or looking around with the sample mail
/// first), how it looks, what it tells you about, AI or just mail, and a last look at what you chose. Each step
/// has a small moving picture (OnboardingScenes.swift); with Reduce Motion they simply appear.
/// Shown once; Help → Welcome to Margin opens it again.
public struct OnboardingView: View {
    @Bindable var model: MailModel
    /// Only for screenshots: mailboxes to list as added.
    private var shownMailboxes: [MailAccount] = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var step = Step.welcome
    /// Which way the last move went, so the next step comes in from that side.
    @State private var forward = true
    @State private var adding = false
    /// The relay step's fine print, folded away until asked for.
    @State private var showsRelayDetails = false
    /// Whether the step runs on below the bottom edge, so a hint can say there's more.
    @State private var moreBelow = false
    @State private var scroll = ScrollPosition(edge: .top)

    enum Step: Int, CaseIterable { case welcome, look, alerts, ai, relay, done }

    /// The steps this device shows: the relay is explained only on iPhone and iPad, and only
    /// when the build has one (a Mac keeps its own connections open).
    static func steps(for model: MailModel) -> [Step] {
        #if os(iOS)
        if model.hasPushRelay { return Step.allCases }
        #endif
        return Step.allCases.filter { $0 != .relay }
    }

    private var steps: [Step] { Self.steps(for: model) }

    public init(model: MailModel) { self.model = model }

    /// Opens on one step, counted among the steps this device shows; for screenshots, which
    /// can also show the welcome as if `shownMailboxes` had been added.
    public init(model: MailModel, step: Int, shownMailboxes: [MailAccount] = []) {
        self.model = model
        self.shownMailboxes = shownMailboxes
        let steps = Self.steps(for: model)
        _step = State(initialValue: steps.indices.contains(step) ? steps[step] : .welcome)
    }

    /// Everything appears at once, without moving, when motion is reduced here or on the device.
    private var still: Bool { model.reduceMotion || systemReduceMotion }

    public var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // Each step scrolls on its own, so a new one always starts at the top; the
                // Mac window fits them all, a phone may not.
                ScrollView {
                    page
                        #if os(macOS)
                        .padding(.horizontal, Self.pagePadding)
                        .padding(.top, Space.xl)
                        .padding(.bottom, Space.l)
                        #else
                        .frame(maxWidth: 520)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(.horizontal, Space.l)
                        .padding(.top, Space.xl)
                        .padding(.bottom, Space.l)
                        #endif
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollPosition($scroll)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentSize.height - geometry.visibleRect.maxY > 24
                } action: { _, more in
                    withAnimation(still ? nil : .easeOut(duration: 0.25)) { moreBelow = more }
                }
                .id(step)
                .transition(still ? .opacity : .step(forward: forward))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .overlay(alignment: .bottom) { if moreBelow { moreHint.transition(.opacity) } }
            // The buttons spring up last, once the welcome has landed.
            footer.rise(6, still: still)
        }
        #if os(macOS)
        // Asks for 600 × 640 but gives way: a sheet on a small window can be narrower, and then
        // every row wraps instead of running off the edges.
        .frame(minWidth: 380, idealWidth: 600, maxWidth: 600, minHeight: 440, idealHeight: 640, maxHeight: 640)
        #endif
        .background(Paper.popover)
        // Adding a mailbox comes back to the welcome, which then lists it, so a second and a
        // third can be added before going on.
        .sheet(isPresented: $adding) {
            AccountSetupView(model: model)
        }
    }

    private func goOn() { if let index = steps.firstIndex(of: step), index + 1 < steps.count { go(steps[index + 1]) } }
    private func goBack() { if let index = steps.firstIndex(of: step), index > 0 { go(steps[index - 1]) } }

    private func go(_ next: Step) {
        forward = (steps.firstIndex(of: next) ?? 0) >= (steps.firstIndex(of: step) ?? 0)
        scroll = ScrollPosition(edge: .top)
        moreBelow = false
        withAnimation(still ? nil : .spring(response: 0.5, dampingFraction: 0.9)) { step = next }
    }

    // MARK: Steps

    @ViewBuilder
    private var page: some View {
        switch step {
        case .welcome: welcome
        case .look: look
        case .alerts: alerts
        case .ai: aiChoice
        case .relay: relay
        case .done: allSet
        }
    }

    private var welcome: some View {
        VStack(spacing: Space.l) {
            // People sliding past behind the icon, across the whole width.
            ZStack {
                PeopleBand(still: still)
                    .padding(.horizontal, -Self.pagePadding)
                // A little clear space around the icon, so it sits in front of the people.
                RadialGradient(colors: [Paper.popover, Paper.popover.opacity(0)], center: .center,
                               startRadius: Self.heroIcon * 0.45, endRadius: Self.heroIcon * 1.15)
                    .frame(width: Self.heroIcon * 2.4, height: Self.heroIcon * 2.4)
                WelcomeConstellation(icon: model.appIcon, iconDark: model.appIconDark, iconSize: Self.heroIcon, motes: false, still: still)
            }
            .frame(height: Self.bandHeight)
            VStack(spacing: Space.s) {
                Text("Welcome to Margin").font(.largeTitle.weight(.semibold)).foregroundStyle(Ink.primary)
                    .multilineTextAlignment(.center)
                    .rise(0, still: still)
                Text("A calm mail app that works directly with your provider.")
                    .font(.title3).foregroundStyle(Ink.secondary).multilineTextAlignment(.center)
                    .rise(1, still: still)
            }
            if mailboxes.isEmpty {
                // Three short lines, so the picture and the headline lead.
                VStack(alignment: .leading, spacing: Space.m) {
                    point("tray.full", "Home sorts the noise", "People first; the rest sorted into groups.")
                        .rise(3, still: still)
                    point("lock", "Nothing in between", "Your mail goes straight to your provider.")
                        .rise(4, still: still)
                    point("eye.slash", "Trackers blocked", "Hidden pictures that report back are removed.")
                        .rise(5, still: still)
                }
                .frame(maxWidth: 420)
                .transition(.blur)
            } else {
                // Once one is added, the mailboxes take the lines' place: each one springs in.
                VStack(alignment: .leading, spacing: Space.s) {
                    Text("Mailboxes").font(TypeScale.rowStrong).foregroundStyle(Ink.primary)
                    VStack(spacing: 0) {
                        ForEach(mailboxes) { account in
                            if account.id != mailboxes.first?.id {
                                Rectangle().fill(Line.hairline).frame(height: 1).padding(.leading, 46)
                            }
                            mailboxRow(account)
                                .transition(still ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
                        }
                    }
                    .background(Fill.one, in: RoundedRectangle(cornerRadius: Radius.surface, style: .continuous))
                }
                .frame(maxWidth: 420)
                .transition(.blur)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(still ? nil : .spring(response: 0.45, dampingFraction: 0.75), value: mailboxes.map(\.id))
    }

    /// Real mailboxes added so far (not the sample one).
    private var mailboxes: [MailAccount] { shownMailboxes + model.accounts.filter { $0.connection != .sample } }

    private func mailboxRow(_ account: MailAccount) -> some View {
        HStack(spacing: Space.m) {
            AccountMark(account, size: 22)
            Text(verbatim: account.address.address)
                .font(TypeScale.row).foregroundStyle(Ink.primary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: Space.s)
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Status.done)
        }
        .padding(.horizontal, Space.m)
        .frame(minHeight: Look.gap(44))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(account.address.address) is connected"))
    }

    private var look: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            heading("Make it yours", "You can change all of this later in Settings.")
                .rise(0, still: still)
            LookPreview(appearance: model.appearance, layout: model.layout, inset: insetPreview,
                        icon: model.appIcon, iconDark: model.appIconDark, phone: isPhone,
                        colorBlindSafe: model.colorBlindSafe, still: still)
                .frame(maxWidth: 340)
                .frame(height: Self.previewHeight)
                .frame(maxWidth: .infinity)
                .rise(1, still: still)
            // The Settings picture tiles, small and in one row each, with the chosen name beside
            // the section's title: the whole step fits without scrolling, and the preview above
            // shows each choice large.
            VStack(alignment: .leading, spacing: Space.m) {
                section("Layout", value: layoutTitle(model.layout), order: 2) {
                    MiniChoices(options: layouts, selection: Binding(get: { model.layout }, set: { value in pick { model.layout = value } }),
                                title: layoutTitle, width: Self.miniWidth, still: still) {
                        if isPhone { PhoneLayoutPreview(layout: $0) } else { LayoutPreview(layout: $0) }
                    }
                }
                section("Appearance", value: model.appearance.title, order: 3) {
                    MiniChoices(options: AppAppearance.allCases, selection: Binding(get: { model.appearance }, set: { value in pick { model.appearance = value } }),
                                title: \.title, width: Self.miniWidth, still: still) {
                        if isPhone { PhoneThemePreview(appearance: $0) } else { ThemePreview(appearance: $0) }
                    }
                }
                // The same choice as Settings → Appearance → Colors.
                section("Colors", value: paletteTitle(model.colorBlindSafe), order: 4) {
                    MiniChoices(options: [false, true], selection: Binding(get: { model.colorBlindSafe }, set: { value in pick { model.colorBlindSafe = value } }),
                                title: paletteTitle, width: Self.miniWidth, still: still) {
                        PalettePreview(colorBlindSafe: $0)
                    }
                }
                section("App icon", value: model.appIcon.title, order: 5) {
                    // Wraps onto more lines, so the step never grows wider than the window.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.iconSize + 4, maximum: Self.iconSize + 4), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(AppIconChoice.allCases) { icon in
                            Button { pick { model.appIcon = icon } } label: {
                                AppIconPreview(choice: icon, dark: model.appIconDark, size: Self.iconSize)
                                    .padding(2)
                                    .overlay(RoundedRectangle(cornerRadius: Self.iconSize * 0.3, style: .continuous)
                                        .strokeBorder(Palette.accent, lineWidth: 2).opacity(model.appIcon == icon ? 1 : 0))
                            }
                            .buttonStyle(BounceButtonStyle(still: still))
                            .accessibilityLabel(Text(verbatim: icon.title))
                            .accessibilityAddTraits(model.appIcon == icon ? .isSelected : [])
                        }
                    }
                }
            }
        }
    }

    private var alerts: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            heading("Alerts and people", "Margin only interrupts you for what matters.")
                .rise(0, still: still)
            AlertsPreview(alerts: model.newMailAlerts, icon: model.appIcon, iconDark: model.appIconDark, still: still)
                .rise(1, still: still)
            // The same rows as Settings → Notifications.
            ChoiceList(options: [NewMailAlerts.people, .all, .vips, .none],
                       selection: Binding(get: { model.newMailAlerts }, set: { value in pick { model.newMailAlerts = value } }),
                       symbol: NotificationSettings.symbol, title: NotificationSettings.title, detail: NotificationSettings.detail)
                .rise(2, still: still)
            VStack(alignment: .leading, spacing: Space.l) {
                toggle("Suggest people from Contacts", "While you address mail. Contacts stay on this device.",
                       isOn: Binding(get: { model.usesSystemContacts }, set: { model.usesSystemContacts = $0 }))
                toggle("Sync with iCloud", "Your mailboxes and settings on all your devices. Passwords stay encrypted end to end.",
                       isOn: Binding(get: { model.syncsWithICloud }, set: { model.syncsWithICloud = $0 }))
                toggle("Copy sign-in codes when they arrive", "Ready to paste the moment the email lands.",
                       isOn: Binding(get: { model.copiesSignInCodes }, set: { model.copiesSignInCodes = $0 }))
            }
            .rise(3, still: still)
        }
    }

    /// AI, or a plain mail app: the same switch as Settings → Assistant → Use AI (`usesAI`).
    private var aiChoice: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            heading("AI, or just mail", "Margin works well either way. You can change this later in Settings → Assistant.")
                .rise(0, still: still)
            ChoiceList(options: [true, false],
                       selection: Binding(get: { model.usesAI }, set: { value in pick { model.usesAI = value } }),
                       symbol: { $0 ? "sparkles" : "envelope" },
                       title: { $0 ? String(localized: "Use AI") : String(localized: "Just mail") },
                       detail: { $0 ? Self.aiDetail : String(localized: "A plain mail app: no Ask, summaries or suggested replies, and AI apps can't connect.") })
                .rise(1, still: still)
            VStack(alignment: .leading, spacing: Space.s) {
                fact("lock", "Apple's model runs on this device. Any assistant you add later says where it runs.")
                fact("tray.2", "Either way, Home sorts your mail into groups.")
            }
            .font(TypeScale.row)
            .foregroundStyle(Ink.secondary)
            .rise(2, still: still)
        }
    }

    /// What Use AI brings on this device: Apple's model when it has one, otherwise an assistant to add.
    static var aiDetail: String {
        OnDeviceModel.isAvailable
            ? String(localized: "Ask about your mail, summaries and suggested replies, with Apple's model on this device.")
            : String(localized: "Ask about your mail, summaries and suggested replies, once you add an assistant in Settings → Assistant.")
    }

    /// iPhone and iPad: why instant alerts need Margin's relay, what it gets and never gets, and
    /// the choice to do without it. The same setting as Settings → Notifications → Instant
    /// notifications (`usesPushRelay`).
    private var relay: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            heading("Instant notifications", "Apps can't watch for mail in the background, so Margin's relay taps this device the moment something new arrives.")
                .rise(0, still: still)
            RelayPreview(on: model.usesPushRelay, icon: model.appIcon, iconDark: model.appIconDark, still: still)
                .frame(height: 176)
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity)
                .rise(1, still: still)
            VStack(alignment: .leading, spacing: Space.s) {
                fact("checkmark.shield", "It only learns that something new arrived.")
                fact("eye.slash", "It never sees your mail, who sent it or your passwords.")
            }
            .font(TypeScale.row)
            .foregroundStyle(Ink.secondary)
            .rise(2, still: still)
            toggle("Notify me instantly", "Off, Margin checks for mail every so often instead: every 15 minutes to every few hours.",
                   isOn: Binding(get: { model.usesPushRelay }, set: { value in pick { model.usesPushRelay = value } }))
                .rise(3, still: still)
            // The fine print, a tap away.
            VStack(alignment: .leading, spacing: Space.s) {
                Button {
                    withAnimation(still ? nil : .spring(response: 0.4, dampingFraction: 0.8)) { showsRelayDetails.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text("How it works")
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(showsRelayDetails ? 90 : 0))
                    }
                    .font(TypeScale.label)
                    .foregroundStyle(Ink.tertiary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showsRelayDetails {
                    VStack(alignment: .leading, spacing: Space.s) {
                        Text("Some providers send your address along; the relay keeps only a scrambled form of it.")
                        Text("Mailboxes that can't send a note always use background checks. You can change this later in Settings → Notifications.")
                    }
                    .font(.caption)
                    .foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .rise(4, still: still)
        }
    }

    /// The last step: what you chose, and the way in.
    private var allSet: some View {
        VStack(spacing: Space.l) {
            WelcomeConstellation(icon: model.appIcon, iconDark: model.appIconDark, iconSize: Self.heroIcon, gathered: true, still: still)
                .frame(height: Self.heroHeight)
                .frame(maxWidth: 480)
            VStack(spacing: Space.s) {
                Text("You're all set").font(.largeTitle.weight(.semibold)).foregroundStyle(Ink.primary)
                    .multilineTextAlignment(.center)
                    .rise(0, still: still)
                Text("Your mail is ready. Everything here can be changed later in Settings.")
                    .font(.title3).foregroundStyle(Ink.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .rise(1, still: still)
            }
            VStack(spacing: 0) {
                summary(isPhone ? "iphone" : "rectangle.split.2x1", "Layout", layoutTitle(model.layout))
                Rectangle().fill(Line.hairline).frame(height: 1).padding(.leading, 44)
                summary("circle.lefthalf.filled", "Appearance", model.appearance.title)
                Rectangle().fill(Line.hairline).frame(height: 1).padding(.leading, 44)
                summary("bell", "New mail alerts", model.newMailAlerts.title)
                Rectangle().fill(Line.hairline).frame(height: 1).padding(.leading, 44)
                summary(model.usesAI ? "sparkles" : "envelope", "AI", model.usesAI ? String(localized: "On") : String(localized: "Off"))
            }
            .background(Fill.one, in: RoundedRectangle(cornerRadius: Radius.surface, style: .continuous))
            .frame(maxWidth: 480)
            .padding(.top, Space.s)
            .rise(3, still: still)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Sizes

    #if os(macOS)
    private static var pagePadding: CGFloat { Space.xl + Space.s }
    private static let bandHeight: CGFloat = 220
    private static let heroHeight: CGFloat = 176
    private static let heroIcon: CGFloat = 80
    private static let previewHeight: CGFloat = 110
    private static let miniWidth: CGFloat = 62
    private static let iconSize: CGFloat = 34
    #else
    private static var pagePadding: CGFloat { Space.l }
    private static let bandHeight: CGFloat = 270
    private static let heroHeight: CGFloat = 230
    private static let heroIcon: CGFloat = 92
    private static let previewHeight: CGFloat = 190
    private static let miniWidth: CGFloat = 46
    private static let iconSize: CGFloat = 30
    #endif

    private var insetPreview: Bool {
        #if os(macOS)
        model.insetPanel
        #else
        false
        #endif
    }

    /// A choice that shows at once in the preview above it.
    private func pick(_ change: () -> Void) {
        withAnimation(still ? nil : .spring(response: 0.4, dampingFraction: 0.85)) { change() }
    }

    /// When a step is taller than the window: the page fades out at the bottom and a small
    /// bouncing arrow says there's more; pressing it scrolls down.
    private var moreHint: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [Paper.popover.opacity(0), Paper.popover], startPoint: .top, endPoint: .bottom)
                .frame(height: 56)
                .allowsHitTesting(false)
            Button {
                withAnimation(still ? nil : .spring(response: 0.5, dampingFraction: 0.9)) { scroll.scrollTo(edge: .bottom) }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: Look.size(13), weight: .bold))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 30, height: 30)
                    .background(Paper.panel, in: Circle())
                    .overlay(Circle().strokeBorder(Line.edge))
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                    .symbolEffect(.bounce.down, options: still ? .nonRepeating : .repeat(.periodic(delay: 1.6)), isActive: !still)
            }
            .buttonStyle(BounceButtonStyle(still: still))
            .padding(.bottom, Space.s)
            .accessibilityLabel(Text("Show more below"))
        }
    }

    // MARK: Footer

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(steps, id: \.self) { dot in
                Capsule().fill(dot == step ? Ink.primary : Ink.tertiary.opacity(0.4))
                    .frame(width: dot == step ? 18 : 6, height: 6)
            }
        }
        .animation(still ? nil : .spring(response: 0.45, dampingFraction: 0.8), value: step)
        .accessibilityHidden(true)
    }

    #if os(macOS)
    /// The dots and the two buttons on one line; when a long translation won't fit beside the
    /// dots (a narrow sheet), the buttons get the line to themselves, and failing that they stack.
    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.s) {
                dots
                Spacer(minLength: Space.m)
                footerButtons
            }
            VStack(alignment: .trailing, spacing: Space.m) {
                HStack(spacing: Space.s) { footerButtons }
                dots.frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .trailing, spacing: Space.s) {
                footerButtons
                dots.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Space.l)
    }

    /// The quiet one first, then the main one; each keeps its whole label.
    @ViewBuilder
    private var footerButtons: some View {
        switch step {
        case .welcome where !mailboxes.isEmpty:
            Button("Add Another Mailbox…") { adding = true }.buttonStyle(QuietButtonStyle()).fixedSize()
            Button("Continue") { go(.look) }.buttonStyle(InkButtonStyle()).keyboardShortcut(.defaultAction).fixedSize()
        case .welcome:
            Button("Look Around First") { go(.look) }.buttonStyle(QuietButtonStyle()).fixedSize()
            Button("Add Your Mailbox…") { adding = true }
                .buttonStyle(InkButtonStyle())
                .keyboardShortcut(.defaultAction)
                .fixedSize()
        case .look:
            Button("Back") { go(.welcome) }.buttonStyle(QuietButtonStyle()).fixedSize()
            Button("Continue") { go(.alerts) }.buttonStyle(InkButtonStyle()).keyboardShortcut(.defaultAction).fixedSize()
        case .alerts, .ai, .relay:
            Button("Back") { goBack() }.buttonStyle(QuietButtonStyle()).fixedSize()
            Button("Continue") { goOn() }.buttonStyle(InkButtonStyle()).keyboardShortcut(.defaultAction).fixedSize()
        case .done:
            Button("Back") { goBack() }.buttonStyle(QuietButtonStyle()).fixedSize()
            Button("Start Using Margin") { finish() }.buttonStyle(InkButtonStyle()).keyboardShortcut(.defaultAction).fixedSize()
        }
    }
    #else
    /// On a phone: the step dots, then the main action as a pill centred under the thumb, with
    /// Back as a round button at the left edge. The welcome has two real choices instead, so both
    /// are pills of one width, side by side when they fit and otherwise stacked with the main one on top.
    private var footer: some View {
        VStack(spacing: Space.l) {
            dots
            Group {
                if step == .welcome {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Space.s) { lookAroundButton; addMailboxButton }
                            .fixedSize()
                        VStack(spacing: Space.s) { addMailboxButton; lookAroundButton }
                            .fixedSize()
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        ZStack {
                            mainButton.padding(.horizontal, touchButtonHeight + Space.m)
                            backButton.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack(spacing: Space.s) { backButton; mainButton }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, Space.xl)
        .padding(.top, Space.m)
        .padding(.bottom, Space.s)
        .frame(maxWidth: .infinity)
        .background(Paper.popover)
    }

    /// Before a mailbox: add one, or look around with the sample mail. After: go on, or add
    /// another.
    @ViewBuilder
    private var addMailboxButton: some View {
        if mailboxes.isEmpty {
            Button("Add Your Mailbox…") { adding = true }
                .buttonStyle(OnboardingPillStyle(fills: true, still: still))
        } else {
            Button("Continue") { go(.look) }
                .buttonStyle(OnboardingPillStyle(fills: true, still: still))
        }
    }

    @ViewBuilder
    private var lookAroundButton: some View {
        if mailboxes.isEmpty {
            Button("Look Around First") { go(.look) }
                .buttonStyle(OnboardingPillStyle(prominent: false, fills: true, still: still))
        } else {
            Button("Add Another Mailbox…") { adding = true }
                .buttonStyle(OnboardingPillStyle(prominent: false, fills: true, still: still))
        }
    }

    private var mainButton: some View {
        Button {
            if step == .done { finish() } else { goOn() }
        } label: {
            HStack(spacing: Space.s) {
                step == .done ? Text("Start Using Margin") : Text("Continue")
                Image(systemName: "arrow.right").font(.system(size: Look.size(15), weight: .bold))
            }
        }
        .buttonStyle(OnboardingPillStyle(still: still))
        .frame(minWidth: 200)
        .fixedSize()
    }

    private var backButton: some View {
        Button { goBack() } label: {
            Image(systemName: "chevron.left").font(.system(size: Look.size(17), weight: .semibold))
        }
        .buttonStyle(OnboardingPillStyle(prominent: false, circle: true, still: still))
        .accessibilityLabel(Text("Back"))
    }
    #endif

    private func finish() {
        model.hasOnboarded = true
        dismiss()
    }

    // MARK: Pieces

    /// A phone (not an iPad) shows one thing at a time, so the layouts only change how the list
    /// starts; the step shows them on a phone and calls the plain list what it is.
    private var isPhone: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    private func layoutTitle(_ layout: ListLayout) -> String {
        isPhone && layout == .panels ? String(localized: "Standard") : layout.title
    }

    private var layouts: [ListLayout] {
        #if os(macOS)
        ListLayout.allCases
        #else
        [.panels, .spark, .minimal]
        #endif
    }

    private func heading(_ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title.weight(.semibold)).foregroundStyle(Ink.primary)
            Text(detail).foregroundStyle(Ink.secondary)
        }
    }

    private func paletteTitle(_ safe: Bool) -> String {
        safe ? String(localized: "Color-blind safe") : String(localized: "Standard")
    }

    /// A titled group; `value` is the choice in use, shown beside the title.
    private func section<Content: View>(_ title: LocalizedStringKey, value: String? = nil, order: Int,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(TypeScale.rowStrong).foregroundStyle(Ink.primary)
                if let value {
                    Text(verbatim: value).font(TypeScale.row).foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                        .animation(still ? nil : .easeOut(duration: 0.2), value: value)
                }
            }
            content()
        }
        .rise(order, still: still)
    }

    private func fact(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: symbol).frame(width: 22)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A switch at the trailing edge, with its name and what it means beside it.
    private func toggle(_ title: LocalizedStringKey, _ detail: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Ink.primary)
                Text(detail).font(.caption).foregroundStyle(Ink.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
    }

    private func summary(_ symbol: String, _ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Image(systemName: symbol).font(.system(size: Look.size(15))).foregroundStyle(Ink.tertiary).frame(width: 20)
            // The name and the choice side by side, or the choice under its name when it is long.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                    Text(title).font(TypeScale.row).foregroundStyle(Ink.secondary)
                    Spacer(minLength: Space.m)
                    Text(verbatim: value).font(TypeScale.rowStrong).foregroundStyle(Ink.primary).fixedSize()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(TypeScale.row).foregroundStyle(Ink.secondary)
                    Text(verbatim: value).font(TypeScale.rowStrong).foregroundStyle(Ink.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func point(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: symbol).font(.system(size: Look.size(20), weight: .light)).foregroundStyle(Ink.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(TypeScale.rowStrong).foregroundStyle(Ink.primary)
                Text(detail).font(TypeScale.row).foregroundStyle(Ink.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension MailModel {
    /// Whether the first-launch welcome has been finished.
    public var hasOnboarded: Bool {
        get { _ = contactSettingsRevision; return environment.defaults.bool(forKey: "hasOnboarded") }
        set { environment.defaults.set(newValue, forKey: "hasOnboarded"); contactSettingsRevision += 1 }
    }
}
