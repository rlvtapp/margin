import MailCore
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The first launch: what Margin is, adding a mailbox (or looking around with the sample mail
/// first), how it looks, and what it tells you about. Shown once; Help → Welcome to Margin opens
/// it again.
public struct OnboardingView: View {
    @Bindable var model: MailModel
    @Environment(\.dismiss) private var dismiss
    @State private var step = Step.welcome
    @State private var adding = false

    enum Step: Int, CaseIterable { case welcome, look, alerts }

    public init(model: MailModel) { self.model = model }

    /// Opens on one step (0, 1 or 2); for screenshots.
    public init(model: MailModel, step: Int) {
        self.model = model
        _step = State(initialValue: Step(rawValue: step) ?? .welcome)
    }

    public var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, Space.xl)
                .padding(.top, Space.xl)
            #else
            // A phone is too short for the longer steps, so they scroll above buttons that stay put.
            ScrollView {
                page
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.horizontal, Space.l)
                    .padding(.top, Space.xl)
                    .padding(.bottom, Space.l)
            }
            .scrollBounceBehavior(.basedOnSize)
            #endif
            footer
        }
        #if os(macOS)
        .frame(width: 560, height: 560)
        #endif
        .background(Paper.popover)
        .sheet(isPresented: $adding, onDismiss: {
            if model.accounts.contains(where: { $0.connection != .sample }) { step = .look }
        }) {
            AccountSetupView(model: model)
        }
    }

    // MARK: Steps

    private var page: some View {
        Group {
            switch step {
            case .welcome: welcome
            case .look: look
            case .alerts: alerts
            }
        }
        .animation(model.reduceMotion ? nil : .easeOut(duration: 0.2), value: step)
    }

    private var welcome: some View {
        VStack(spacing: Space.l) {
            AppIconPreview(choice: model.appIcon, dark: model.appIconDark, size: 84)
                .padding(.top, Space.l)
            VStack(spacing: Space.s) {
                Text("Welcome to Margin").font(.largeTitle.weight(.semibold)).foregroundStyle(Ink.primary)
                    .multilineTextAlignment(.center)
                Text("A calm mail app that works directly with your provider.")
                    .font(.title3).foregroundStyle(Ink.secondary).multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: Space.m) {
                point("tray.full", "Home sorts the noise", "People first; newsletters, receipts and updates in their own groups.")
                point("lock", "Nothing in between", "Mail goes straight between this device and your provider. No account to make, nothing tracked.")
                point("eye.slash", "Trackers blocked", "The hidden pictures that report when you open mail are taken out.")
            }
            .frame(maxWidth: 420)
            .padding(.top, Space.s)
        }
        .frame(maxWidth: .infinity)
    }

    private var look: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            heading("Make it yours", "You can change all of this later in Settings.")
            Text("Layout").font(TypeScale.rowStrong).foregroundStyle(Ink.primary)
            HStack(spacing: Space.s) {
                ForEach(layouts, id: \.self) { layout in
                    choice(selected: model.layout == layout) { model.layout = layout } label: {
                        Image(systemName: Self.symbol(layout)).font(.system(size: 24, weight: .light)).frame(height: 30)
                        Text(layout.title).font(TypeScale.label)
                    }
                }
            }
            Text("Appearance").font(TypeScale.rowStrong).foregroundStyle(Ink.primary)
            Picker("Appearance", selection: $model.appearance) {
                ForEach(AppAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            #if os(macOS)
            Text("Window").font(TypeScale.rowStrong).foregroundStyle(Ink.primary)
            Picker("Window", selection: $model.insetPanel) {
                Text("Edge to edge").tag(false)
                Text("Inset panel").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            #endif
            Text("App icon").font(TypeScale.rowStrong).foregroundStyle(Ink.primary)
            // Wraps onto more lines, so the step never grows wider than the window.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44, maximum: 44), spacing: Space.s)], alignment: .leading, spacing: Space.s) {
                ForEach(AppIconChoice.allCases) { icon in
                    Button { model.appIcon = icon } label: {
                        AppIconPreview(choice: icon, dark: model.appIconDark, size: 40)
                            .padding(2)
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Ink.primary, lineWidth: 2).opacity(model.appIcon == icon ? 1 : 0))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: icon.title))
                }
            }
        }
    }

    private var alerts: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            heading("Alerts and people", "Margin only interrupts you for what matters.")
            VStack(alignment: .leading, spacing: Space.s) {
                ForEach(NewMailAlerts.allCases, id: \.self) { option in
                    choice(selected: model.newMailAlerts == option, wide: true) { model.newMailAlerts = option } label: {
                        Text(option.title).font(TypeScale.row)
                    }
                }
            }
            Toggle(isOn: Binding(get: { model.usesSystemContacts }, set: { model.usesSystemContacts = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Suggest people from Contacts").foregroundStyle(Ink.primary)
                    Text("While you address mail. Contacts stay on this device.").font(.caption).foregroundStyle(Ink.tertiary)
                }
            }
            .toggleStyle(.switch)
            Toggle(isOn: Binding(get: { model.syncsWithICloud }, set: { model.syncsWithICloud = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sync with iCloud").foregroundStyle(Ink.primary)
                    Text("Your mailboxes and settings on all your devices. Passwords stay encrypted end to end.")
                        .font(.caption).foregroundStyle(Ink.tertiary)
                }
            }
            .toggleStyle(.switch)
            Toggle(isOn: Binding(get: { model.copiesSignInCodes }, set: { model.copiesSignInCodes = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Copy sign-in codes when they arrive").foregroundStyle(Ink.primary)
                    Text("Ready to paste the moment the email lands.").font(.caption).foregroundStyle(Ink.tertiary)
                }
            }
            .toggleStyle(.switch)
        }
    }

    // MARK: Footer

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { dot in
                Circle().fill(dot == step ? Ink.primary : Ink.tertiary.opacity(0.4)).frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }

    #if os(macOS)
    private var footer: some View {
        HStack {
            dots
            Spacer()
            switch step {
            case .welcome:
                Button("Look Around First") { step = .look }.buttonStyle(QuietButtonStyle())
                Button("Add Your Mailbox…") { adding = true }
                    .buttonStyle(InkButtonStyle())
                    .keyboardShortcut(.defaultAction)
            case .look:
                Button("Back") { step = .welcome }.buttonStyle(QuietButtonStyle())
                Button("Continue") { step = .alerts }.buttonStyle(InkButtonStyle()).keyboardShortcut(.defaultAction)
            case .alerts:
                Button("Back") { step = .look }.buttonStyle(QuietButtonStyle())
                Button("Start Using Margin") { finish() }.buttonStyle(InkButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.l)
    }
    #else
    /// On a phone: the main action full width under the thumb, the other one under it, and the
    /// step dots above. Every step has two buttons, so nothing moves between steps.
    private var footer: some View {
        VStack(spacing: Space.s) {
            dots.padding(.bottom, Space.xs)
            switch step {
            case .welcome:
                Button("Add Your Mailbox…") { adding = true }.buttonStyle(InkButtonStyle(wide: true))
                Button("Look Around First") { step = .look }.buttonStyle(QuietButtonStyle(wide: true))
            case .look:
                Button("Continue") { step = .alerts }.buttonStyle(InkButtonStyle(wide: true))
                Button("Back") { step = .welcome }.buttonStyle(QuietButtonStyle(wide: true))
            case .alerts:
                Button("Start Using Margin") { finish() }.buttonStyle(InkButtonStyle(wide: true))
                Button("Back") { step = .look }.buttonStyle(QuietButtonStyle(wide: true))
            }
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, Space.l)
        .padding(.top, Space.m)
        .padding(.bottom, Space.s)
        .frame(maxWidth: .infinity)
        .background(Paper.popover)
        .overlay(alignment: .top) { Rectangle().fill(Line.hairline).frame(height: 1) }
    }
    #endif

    private func finish() {
        model.hasOnboarded = true
        dismiss()
    }

    // MARK: Pieces

    private var layouts: [ListLayout] {
        #if os(macOS)
        ListLayout.allCases
        #else
        [.panels, .spark, .minimal]
        #endif
    }

    static func symbol(_ layout: ListLayout) -> String {
        switch layout {
        case .panels: "rectangle.split.2x1"
        case .wide: "rectangle.grid.1x2"
        case .spark: "rectangle.topthird.inset.filled"
        case .minimal: "house"
        }
    }

    private func heading(_ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title.weight(.semibold)).foregroundStyle(Ink.primary)
            Text(detail).foregroundStyle(Ink.secondary)
        }
    }

    private func point(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: symbol).font(.system(size: 20, weight: .light)).foregroundStyle(Ink.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(TypeScale.rowStrong).foregroundStyle(Ink.primary)
                Text(detail).font(TypeScale.row).foregroundStyle(Ink.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func choice<Label: View>(selected: Bool, wide: Bool = false, action: @escaping () -> Void,
                                     @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            VStack(spacing: 6) { label() }
                .frame(maxWidth: .infinity, alignment: wide ? .leading : .center)
                #if os(macOS)
                .padding(.vertical, wide ? 10 : 14)
                #else
                .padding(.vertical, wide ? 14 : 16)
                #endif
                .padding(.horizontal, Space.m)
                .foregroundStyle(selected ? Ink.primary : Ink.secondary)
                .background(Fill.one, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Ink.primary : Line.edge, lineWidth: selected ? 2 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension MailModel {
    /// Whether the first-launch welcome has been finished.
    public var hasOnboarded: Bool {
        get { _ = contactSettingsRevision; return environment.defaults.bool(forKey: "hasOnboarded") }
        set { environment.defaults.set(newValue, forKey: "hasOnboarded"); contactSettingsRevision += 1 }
    }
}
