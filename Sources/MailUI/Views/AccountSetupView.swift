import AuthenticationServices
import MailCore
import SwiftUI

/// Adding an account: pick the provider (or type an address for any other), follow its few
/// steps, then sign in.
public struct AccountSetupView: View {
    let model: MailModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthentication
    @Environment(\.openURL) private var openURL

    @State private var name = ""
    @State private var address = ""
    @State private var stage: Stage = .choose
    @State private var cameFromList = false
    @State private var preset: ProviderPreset?
    @State private var connection: AccountConnection = .sample
    @State private var username = ""
    /// A custom domain at iCloud whose own address iCloud refused: now asks for the @icloud.com one.
    @State private var asksICloudAddress = false
    @State private var secret = ""
    @State private var usePassword = false
    @State private var showsServers = false
    @State private var isWorking = false
    @State private var error: String?

    enum Stage { case choose, address, signIn }

    public init(model: MailModel) { self.model = model }

    /// Opens on one provider's page; for screenshots.
    public init(model: MailModel, provider id: String) {
        self.model = model
        if let found = ProviderCatalog.preset(id: id) {
            _preset = State(initialValue: found)
            _connection = State(initialValue: found.connection)
            _cameFromList = State(initialValue: true)
            _stage = State(initialValue: .signIn)
        }
    }

    public var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: Space.l) {
            header
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(Space.xl)
        .frame(width: 520)
        .frame(minHeight: 420)
        .background(Paper.popover)
        .animation(model.reduceMotion ? nil : .easeOut(duration: 0.15), value: stage)
        #else
        // On a phone the page scrolls (the keyboard takes half the screen) and the buttons stay
        // at the bottom, full width; Cancel sits top right where iOS keeps it.
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    header
                    content
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.horizontal, Space.l)
                .padding(.top, Space.m)
                .padding(.bottom, Space.l)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            if stage != .choose { touchFooter }
        }
        .background(Paper.popover)
        .animation(model.reduceMotion ? nil : .easeOut(duration: 0.15), value: stage)
        #endif
    }

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .choose: providerList
        case .address: addressFields
        case .signIn: signInFields
        }
        if let error {
            Text(error).font(TypeScale.row).foregroundStyle(Status.danger).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            #if os(iOS)
            HStack {
                if stage != .choose {
                    Button { back() } label: {
                        Label("Back", systemImage: "chevron.left").labelStyle(.titleAndIcon)
                    }
                    .font(TypeScale.rowStrong)
                    .frame(minHeight: 44)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .font(TypeScale.rowStrong)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .foregroundStyle(Ink.primary)
            .buttonStyle(.plain)
            #endif
            HStack(spacing: Space.m) {
                if stage == .signIn, let preset { ProviderMark(preset: preset, size: 32) }
                Text(title).font(TypeScale.title).foregroundStyle(Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if stage == .choose {
                Text("Mail goes straight between this device and your provider. Passwords and tokens stay in this device's Keychain.")
                    .font(TypeScale.row)
                    .foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var title: LocalizedStringKey {
        switch stage {
        case .choose: "Add an account"
        case .address: "Other mail account"
        case .signIn: preset.map { "Add your \($0.name) account" } ?? "Sign in to \(domain)"
        }
    }

    private var footer: some View {
        HStack {
            if stage != .choose {
                Button("Back") { back() }.buttonStyle(QuietButtonStyle())
            }
            Spacer()
            Button("Cancel") { dismiss() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
            if stage != .choose {
                Button(primaryTitle) { Task { await primary() } }
                    .buttonStyle(InkButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || !canContinue)
            }
        }
    }

    #if os(iOS)
    private var touchFooter: some View {
        Button(primaryTitle) { Task { await primary() } }
            .buttonStyle(InkButtonStyle(wide: true))
            .disabled(isWorking || !canContinue)
            .opacity(isWorking || !canContinue ? 0.4 : 1)
            .frame(maxWidth: 560)
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.s)
            .frame(maxWidth: .infinity)
            .background(Paper.popover)
            .overlay(alignment: .top) { Rectangle().fill(Line.hairline).frame(height: 1) }
    }
    #endif

    private var providers: [ProviderPreset] {
        #if os(macOS)
        ProviderCatalog.all
        #else
        ProviderCatalog.all.filter { !$0.macOnly }
        #endif
    }

    private var providerList: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: Space.s)], spacing: Space.s) {
            ForEach(providers) { provider in
                ProviderTile(name: provider.name) {
                    ProviderMark(preset: provider, size: 28)
                } action: {
                    choose(provider)
                }
            }
            ProviderTile(name: String(localized: "Other")) {
                Image(systemName: "at")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 28, height: 28)
                    .background(Fill.one, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            } action: {
                cameFromList = false
                preset = nil
                stage = .address
            }
        }
    }

    private var addressFields: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            TextField("Your name", text: $name).fieldStyle().textContentType(.name)
            TextField("Email address", text: $address).fieldStyle()
                .emailAddressEntry()
                .onSubmit { Task { await primary() } }
            Text("Margin looks up the servers for your address. You can change them on the next step.")
                .font(TypeScale.label)
                .foregroundStyle(Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var signInFields: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if let detail = preset?.detail {
                Text(verbatim: detail).font(TypeScale.row).foregroundStyle(Ink.secondary)
            }
            VStack(alignment: .leading, spacing: Space.s) {
                TextField("Your name", text: $name).fieldStyle().textContentType(.name)
                TextField("Email address", text: $address).fieldStyle()
                    .emailAddressEntry()
            }

            if usesOAuth {
                Text("You'll sign in on \(preset?.name ?? "")'s own page. Margin never sees your password.")
                    .font(TypeScale.label)
                    .foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if preset?.acceptsPasswords == true {
                    Button("Use an app password instead") { usePassword = true }
                        .buttonStyle(.plain).font(TypeScale.label).foregroundStyle(Ink.tertiary)
                        #if os(iOS)
                        .frame(minHeight: 44)
                        #endif
                }
            } else if preset?.acceptsPasswords == false {
                Text("Sign-in with \(preset?.name ?? "") isn't set up in this copy of Margin.")
                    .font(TypeScale.row)
                    .foregroundStyle(Status.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if let preset, !preset.steps.isEmpty { SetupSteps(preset: preset) }
                if needsICloudAddress && asksICloudAddress {
                    // iCloud refused the custom-domain address: it wants the @icloud.com one.
                    TextField("Your @icloud.com address", text: $username).fieldStyle().emailAddressEntry()
                    Text("\(domain) gets its mail through iCloud. Sign in with the Apple Account's @icloud.com address; mail still goes out from \(address).")
                        .font(TypeScale.label)
                        .foregroundStyle(Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Space.s) {
                    SecureField(secretLabel, text: $secret).fieldStyle()
                        .onSubmit { Task { await primary() } }
                    if case .appPassword = preset?.signIn {
                        PasteSecret { secret = $0 }
                    }
                }
                if let note = preset?.note {
                    Text(verbatim: note).font(TypeScale.label).foregroundStyle(Ink.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }

            DisclosureGroup("Server settings", isExpanded: $showsServers) {
                VStack(alignment: .leading, spacing: Space.s) {
                    if !usesOAuth, !isToken {
                        TextField("Username", text: $username).fieldStyle().plainEntry().padding(.top, Space.s)
                    }
                    ServerFields(connection: $connection)
                }
            }
            .font(TypeScale.label)
            .foregroundStyle(Ink.secondary)
        }
    }

    // MARK: State

    private var domain: String { address.split(separator: "@").last.map(String.init) ?? "" }

    private var oauthClient: OAuthClient? {
        guard case .oauth(let provider) = preset?.signIn else { return nil }
        return model.environment.oauth.client(for: provider)
    }

    private var usesOAuth: Bool { oauthClient != nil && !usePassword }

    /// A custom domain (gillian@goud.ca) whose mail is at iCloud: Apple only accepts the Apple
    /// Account's @icloud.com address as the username.
    private var needsICloudAddress: Bool {
        preset?.id == "icloud" && !["icloud.com", "me.com", "mac.com"].contains(domain.lowercased())
    }

    private var isToken: Bool {
        if case .jmap = connection, case .token = preset?.signIn { return true }
        return false
    }

    private var primaryTitle: LocalizedStringKey {
        if isWorking { return stage == .address ? "Looking up…" : "Connecting…" }
        if stage == .address { return "Continue" }
        return usesOAuth ? "Sign in with \(preset?.name ?? "")" : "Connect"
    }

    private var hasAddress: Bool { EmailAddress.isValid(address.trimmingCharacters(in: .whitespaces)) }

    private var canContinue: Bool {
        switch stage {
        case .choose: false
        case .address: hasAddress
        case .signIn: hasAddress && (usesOAuth || (preset?.acceptsPasswords != false && !secret.isEmpty))
            && (!(needsICloudAddress && asksICloudAddress) || username.contains("@"))
        }
    }

    private var secretLabel: LocalizedStringKey {
        if isToken { return "API token" }
        if case .appPassword = preset?.signIn { return "App password" }
        if case .oauth = preset?.signIn { return "App password" }
        return "Password"
    }

    // MARK: Actions

    private func choose(_ provider: ProviderPreset) {
        cameFromList = true
        preset = provider
        connection = provider.connection
        usePassword = false
        secret = ""
        error = nil
        showsServers = false
        stage = .signIn
    }

    private func back() {
        error = nil
        stage = stage == .signIn && !cameFromList ? .address : .choose
    }

    private func primary() async {
        guard canContinue, !isWorking else { return }
        error = nil
        isWorking = true
        defer { isWorking = false }
        address = address.trimmingCharacters(in: .whitespaces)
        if stage == .address {
            switch await AutoConfig().lookup(address: address) {
            case .preset(let found):
                preset = found
                connection = found.connection
            case .discovered(let found):
                preset = nil
                connection = found
            case .notFound:
                preset = nil
                connection = AutoConfig.guess(domain: domain)
                showsServers = true
            }
            stage = .signIn
            return
        }
        do {
            var email = EmailAddress(name: name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name, address: address)
            let user = username.trimmingCharacters(in: .whitespaces).isEmpty ? address : username
            var auth: AuthMethod = isToken ? .token : .password(username: user)
            var stored = secret
            if usesOAuth, let client = oauthClient {
                let request = client.authorizationRequest(loginHint: address)
                let callback = try await webAuthentication.authenticate(
                    using: request.url, callbackURLScheme: client.callbackScheme, preferredBrowserSession: .ephemeral
                )
                let tokens = try await client.exchange(callback: callback, verifier: request.verifier, state: request.state)
                stored = String(decoding: try JSONEncoder().encode(tokens), as: UTF8.self)
                auth = .oauth(provider: client.provider, username: address)
                // The name the account goes by, unless one was typed.
                if email.name == nil { email.name = tokens.signedInName }
            }
            let account = MailAccount(label: address, address: email, connection: connection, auth: auth, providerID: preset?.id)
            try await model.add(account, secret: stored)
            dismiss()
        } catch let failure as ASWebAuthenticationSessionError where failure.code == .canceledLogin {
            return
        } catch MailError.authenticationFailed(_) where needsICloudAddress && !asksICloudAddress {
            // Tried the custom-domain address first; iCloud wants the Apple Account's @icloud.com one.
            withAnimation(Motion.quick) { asksICloudAddress = true }
            self.error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One provider in the list: its mark and name.
private struct ProviderTile<Mark: View>: View {
    let name: String
    @ViewBuilder let mark: () -> Mark
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                mark()
                Text(verbatim: name).font(TypeScale.rowStrong).foregroundStyle(Ink.primary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 50)
            .background(isHovered ? Fill.one : Paper.sheet, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Line.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(Text(verbatim: name))
    }
}

/// A provider's logo on a white tile, as people know it from their mail. The logos are the
/// single-colour marks from Simple Icons (CC0) in the app's asset catalogs, shown in each brand's
/// colour; Microsoft's four squares are drawn here, and providers without a mark get their initial.
struct ProviderMark: View {
    let preset: ProviderPreset
    let size: CGFloat

    /// Brand colours, and which providers have a logo in the asset catalogs.
    private static let brands: [String: (color: UInt32, logo: Bool)] = [
        "google": (0xEA4335, true), "icloud": (0x3693F3, true), "proton": (0x6D4AFF, true),
        "zoho": (0xE42527, true), "gmx": (0x1C449B, true), "webde": (0x1A1A1A, true),
        "yahoo": (0x6001D2, false), "fastmail": (0x0067B9, false), "aol": (0x1E64F0, false),
        "mailboxorg": (0x2D7D46, false), "posteo": (0x8C6D00, false),
    ]

    var body: some View {
        let brand = Self.brands[preset.id]
        let color = brand.map { Color(rgb: $0.color) } ?? Ink.secondary
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .fill(preset.id == "webde" ? Color(rgb: 0xFFD800) : .white)
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .strokeBorder(.black.opacity(0.08))
            if preset.id == "microsoft" {
                MicrosoftSquares().frame(width: size * 0.5, height: size * 0.5)
            } else if brand?.logo == true {
                Image("provider-\(preset.id)")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .foregroundStyle(color)
                    // Wide wordmarks get more room so they read at the same weight.
                    .frame(width: size * (["zoho", "gmx"].contains(preset.id) ? 0.78 : 0.56), height: size * 0.56)
            } else {
                Text(verbatim: String(preset.name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
            }
        }
        .frame(width: size, height: size)
        .environment(\.colorScheme, .light)
        .accessibilityHidden(true)
    }
}

/// Microsoft's logo: four squares, with the gap its sign-in branding uses.
private struct MicrosoftSquares: View {
    var body: some View {
        GeometryReader { box in
            let gap = box.size.width * 0.045
            let side = (box.size.width - gap) / 2
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color(rgb: 0xF25022)).frame(width: side, height: side)
                Rectangle().fill(Color(rgb: 0x7FBA00)).frame(width: side, height: side).offset(x: side + gap)
                Rectangle().fill(Color(rgb: 0x00A4EF)).frame(width: side, height: side).offset(y: side + gap)
                Rectangle().fill(Color(rgb: 0xFFB900)).frame(width: side, height: side).offset(x: side + gap, y: side + gap)
            }
        }
    }
}

private extension Color {
    init(rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}

/// The few things to do at the provider first, numbered, with a button to the right page.
private struct SetupSteps: View {
    let preset: ProviderPreset
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ForEach(Array(preset.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(verbatim: "\(index + 1)")
                        .font(TypeScale.label.monospacedDigit())
                        .foregroundStyle(Ink.secondary)
                        .frame(width: 18, height: 18)
                        .background(Fill.one, in: Circle())
                    Text(verbatim: step).font(TypeScale.row).foregroundStyle(Ink.primary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let url = preset.setupURL, let host = url.host() {
                if case .appPassword = preset.signIn {
                    // The shortcut: straight to the page where the password is made.
                    Button { openURL(url) } label: {
                        Label { Text("Make an app password") } icon: { Image(systemName: "arrow.up.right") }
                    }
                    .buttonStyle(InkButtonStyle())
                    .padding(.top, Space.xs)
                } else {
                    Button { openURL(url) } label: {
                        Label { Text("Open \(host)") } icon: { Image(systemName: "arrow.up.right") }
                    }
                    .buttonStyle(QuietButtonStyle())
                    .padding(.top, Space.xs)
                }
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Paper.sheet, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Line.hairline))
    }
}

/// Pastes a copied app password into the field, spaces and line breaks taken out. On iPhone the
/// system's paste button, which doesn't ask for permission; on the Mac a plain button.
private struct PasteSecret: View {
    let paste: (String) -> Void

    var body: some View {
        #if os(iOS)
        PasteButton(payloadType: String.self) { strings in
            if let text = strings.first { paste(Self.cleaned(text)) }
        }
        .labelStyle(.iconOnly)
        .buttonBorderShape(.capsule)
        #else
        Button("Paste") {
            if let text = NSPasteboard.general.string(forType: .string) { paste(Self.cleaned(text)) }
        }
        .buttonStyle(QuietButtonStyle())
        .tip("Paste the app password you copied")
        #endif
    }

    static func cleaned(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }
}

/// Host, port and security for IMAP and SMTP, or the JMAP session URL.
struct ServerFields: View {
    @Binding var connection: AccountConnection

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            switch connection {
            case .imap(let incoming, let outgoing):
                endpoint("IMAP", incoming) { connection = .imap(incoming: $0, outgoing: outgoing) }
                endpoint("SMTP", outgoing) { connection = .imap(incoming: incoming, outgoing: $0) }
            case .jmap(let url):
                TextField("Session URL", text: Binding(
                    get: { url.absoluteString },
                    set: { if let url = URL(string: $0) { connection = .jmap(sessionURL: url) } }
                )).fieldStyle()
            case .sample:
                EmptyView()
            }
        }
        .padding(.top, Space.s)
    }

    private func endpoint(_ label: String, _ value: ServerEndpoint, set: @escaping (ServerEndpoint) -> Void) -> some View {
        HStack(spacing: Space.s) {
            Text(label).font(TypeScale.label).foregroundStyle(Ink.tertiary).frame(width: 36, alignment: .leading)
            TextField("Host", text: Binding(get: { value.host }, set: { var copy = value; copy.host = $0; set(copy) })).fieldStyle().plainEntry()
            TextField("Port", value: Binding(get: { value.port }, set: { var copy = value; copy.port = $0; set(copy) }), format: .number.grouping(.never))
                .fieldStyle()
                .frame(width: 64)
            Picker("", selection: Binding(get: { value.security }, set: { var copy = value; copy.security = $0; set(copy) })) {
                Text("TLS").tag(ConnectionSecurity.tls)
                Text("STARTTLS").tag(ConnectionSecurity.startTLS)
                Text("None (this device only)").tag(ConnectionSecurity.plain)
            }
            .labelsHidden()
            .frame(width: 110)
        }
    }
}
