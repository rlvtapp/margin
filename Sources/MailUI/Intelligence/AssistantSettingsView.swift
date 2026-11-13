import MailCore
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Settings → Assistant: the assistants you've added, each a row with how it connects, its
/// model and whether it's ready (the form to change one opens right under it), then who does
/// what: Ask and writing, quick suggestions, actions.
struct AssistantSettingsView: View {
    @Bindable var model: MailModel
    /// The assistant being added or changed, while `editing` names it. Never optional: closing
    /// the form while its fields were still being drawn crashed on a binding to nothing.
    @State private var draft = AssistantSettings(provider: .off)
    @State private var editing: AssistantProvider?
    @State private var apiKey = ""
    @State private var models: [ModelChoice] = []
    @State private var status: String?
    @State private var isChecking = false
    /// Claude Code and ChatGPT's Codex, when this Mac has them; looked for once, off the main thread.
    @State private var installedTools: Set<AssistantProvider> = []

    init(model: MailModel) {
        self.model = model
    }

    private var added: [AssistantSettings] {
        let profiles = model.assistantProfiles
        return AssistantProvider.allCases.compactMap { profiles[$0] }
    }

    var body: some View {
        Form {
            SettingsHeader(.assistant)
            Section {
                Toggle(isOn: $model.usesAI) {
                    SettingLabel("Use AI",
                                 detail: "Off makes Margin a plain mail app: no Ask, summaries, suggested replies, AI drafts or AI apps. Home still sorts mail by Margin's own rules.")
                }
            }
            if model.usesAI { assistants }
        }
        .formStyle(.grouped)
        .task {
            #if os(macOS)
            let found = await Task.detached {
                AssistantProvider.allCases.filter { $0.usesCommandLine && $0.isAvailableHere }
            }.value
            installedTools = Set(found)
            #endif
        }
    }

    /// Everything about the assistants, shown while AI is on.
    @ViewBuilder
    private var assistants: some View {
            Section {
                if added.isEmpty && editing == nil {
                    SettingsEmptyRow("No assistant yet. Add one to summarize, write and answer questions about your mail.")
                }
                ForEach(added, id: \.provider) { settings in
                    AssistantRow(settings: settings, model: model, isOpen: editing == settings.provider,
                                 open: { edit(settings) }, remove: { model.removeAssistantProfile(settings.provider) })
                    if editing == settings.provider { editor }
                }
                // A new one being added, under the list.
                if let editing, !added.contains(where: { $0.provider == editing }) {
                    AssistantRow(settings: draft, model: model, isOpen: true, isNew: true, open: {}, remove: {})
                    editor
                }
                addMenu
            } header: {
                Text("Your assistants")
            } footer: {
                Text("Add as many as you like; each keeps its own key and model. New ones start on their fastest, cheapest model, which is plenty for mail.")
            }
            if !added.isEmpty { roles }
            if model.isAssistantOn {
                AskSettingsSection(model: model)
                AgentPermissionsSection(model: model)
            }
            WritingProfileView(model: model)
    }

    // MARK: Adding

    private var addMenu: some View {
        let have = Set(added.map(\.provider))
        func can(_ provider: AssistantProvider) -> Bool {
            !have.contains(provider) && (!provider.usesCommandLine || installedTools.contains(provider))
                && (provider != .onDevice || OnDeviceModel.isAvailable)
        }
        let here = [AssistantProvider.onDevice, .claudeCode, .codex, .ollama, .lmStudio].filter(can)
        let keyed = [AssistantProvider.claude, .chatGPT, .gemini, .grok, .custom].filter(can)
        return Menu {
            if !here.isEmpty {
                Section("On this Mac") {
                    ForEach(here, id: \.self) { provider in
                        Button { edit(AssistantSettings(provider: provider)) } label: {
                            Label(provider.shortName, systemImage: AssistantRow.symbol(provider))
                        }
                    }
                }
            }
            if !keyed.isEmpty {
                Section("With an API key") {
                    ForEach(keyed, id: \.self) { provider in
                        Button { edit(AssistantSettings(provider: provider)) } label: {
                            Label(provider.shortName, systemImage: AssistantRow.symbol(provider))
                        }
                    }
                }
            }
        } label: {
            Label("Add Assistant", systemImage: "plus.circle.fill")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .disabled(here.isEmpty && keyed.isEmpty)
    }

    // MARK: Who does what

    private var roles: some View {
        let ready = added.filter(model.isReady)
        return Section {
            Picker(selection: Binding(get: { model.assistantSettings.provider }, set: { provider in
                let settings = model.assistantProfiles[provider] ?? AssistantSettings(provider: provider)
                model.applyAssistant(settings, apiKey: nil)
            })) {
                Text("Off").tag(AssistantProvider.off)
                ForEach(ready, id: \.provider) { Text(verbatim: AssistantRow.label($0)).tag($0.provider) }
                if model.assistantSettings.provider != .off && !ready.contains(where: { $0.provider == model.assistantSettings.provider }) {
                    Text(verbatim: AssistantRow.label(model.assistantSettings)).tag(model.assistantSettings.provider)
                }
            } label: {
                SettingLabel("Ask and writing", detail: "Answers in Ask, drafts, summaries, rules in your words and translations.")
            }
            Picker(selection: Binding(get: { model.quickProviderChoice }, set: { model.quickProviderChoice = $0 })) {
                Text("Automatic (\(model.quickAssistant.map(AssistantRow.label) ?? String(localized: "Off")))").tag(AssistantProvider?.none)
                ForEach(ready, id: \.provider) { Text(verbatim: AssistantRow.label($0)).tag(Optional($0.provider)) }
            } label: {
                SettingLabel("Quick suggestions", detail: "The reply bubbles under a message and label ideas. Automatic uses Apple's model on this Mac when it has one (fast, free and private), else the cheapest model of the assistant above.")
            }
            Picker(selection: Binding(get: { model.sortProviderChoice }, set: { model.sortProviderChoice = $0 })) {
                Text("Automatic (\(model.sortAssistant.map(AssistantRow.label) ?? String(localized: "Off")))").tag(AssistantProvider?.none)
                ForEach(ready, id: \.provider) { Text(verbatim: AssistantRow.label($0)).tag(Optional($0.provider)) }
            } label: {
                SettingLabel("Sorting into groups", detail: "Sort Now, and new mail as it arrives, one conversation at a time. Automatic uses Apple's model on this Mac when it has one, else the cheapest model of the assistant above.")
            }
            ActionProviderPicker(model: model)
        } header: {
            Text("Who does what")
        }
    }

    // MARK: Changing one

    private func edit(_ settings: AssistantSettings) {
        if editing == settings.provider { editing = nil; return }
        draft = settings
        editing = settings.provider
        apiKey = ""
        status = nil
        models = Self.knownModels(settings.provider)
        if settings.provider.hasServerURL || (settings.provider.needsKey && model.savedAPIKey(for: settings.provider) != nil) {
            Task { await loadModels() }
        }
    }

    /// Models known without asking a server: Claude Code's, and the ones the ChatGPT app lists.
    static func knownModels(_ provider: AssistantProvider) -> [ModelChoice] {
        #if os(macOS)
        switch provider {
        case .claudeCode: return CommandLineTool.claude.models()
        case .codex: return CommandLineTool.codex.models()
        default: return []
        }
        #else
        return []
        #endif
    }

    /// The fields for the assistant being added or changed, right under its row.
    @ViewBuilder
    private var editor: some View {
        let provider = draft.provider
        Group {
            if provider.hasServerURL {
                LabeledContent {
                    TextField("Server", text: $draft.baseURL,
                              prompt: Text(verbatim: provider.defaultBaseURL.isEmpty ? "https://…/v1" : provider.defaultBaseURL))
                        .labelsHidden()
                } label: { SettingLabel("Server") }
            }
            if provider.acceptsKey {
                LabeledContent {
                    SecureField("API key", text: $apiKey,
                                prompt: Text(model.savedAPIKey(for: provider) == nil ? "Paste your key" : "Saved in Keychain"))
                        .labelsHidden()
                } label: {
                    SettingLabel(provider.needsKey ? "API key" : "API key (optional)")
                }
            }
            if provider != .onDevice && provider != .off { modelPicker }
            LabeledContent {
                HStack(spacing: Space.s) {
                    Button("Cancel") { editing = nil }
                    Button(added.contains(where: { $0.provider == provider }) ? "Save" : "Add") { save() }
                        .buttonStyle(.borderedProminent)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    if let status { Text(verbatim: status).foregroundStyle(.secondary) }
                    Text(provider.privacyNote).font(.caption).foregroundStyle(.secondary)
                    if provider == .onDevice, let reason = OnDeviceModel.unavailableReason {
                        Text(reason).font(.caption).foregroundStyle(Status.danger)
                    }
                }
            }
        }
        .padding(.leading, 28)
    }

    /// A list to pick from: what the provider offers, the quickest first where that's known.
    /// A name can still be typed for a server that doesn't list its models.
    @ViewBuilder
    private var modelPicker: some View {
        let choices = models.contains(where: { $0.id == draft.model }) || draft.model.isEmpty
            ? models : [ModelChoice(id: draft.model, name: draft.model)] + models
        LabeledContent {
            HStack(spacing: Space.s) {
                if choices.isEmpty {
                    TextField("Model name", text: $draft.model,
                              prompt: Text(draft.provider == .codex ? "Its default model" : "Model name")).labelsHidden()
                } else {
                    Picker("Model", selection: $draft.model) {
                        if draft.provider == .codex { Text("Its default model").tag("") }
                        ForEach(choices) { choice in
                            Text(verbatim: choice.detail.isEmpty ? choice.name : "\(choice.name) · \(choice.detail)").tag(choice.id)
                        }
                    }
                    .labelsHidden()
                }
                if draft.provider.hasServerURL || draft.provider.needsKey {
                    Button { Task { await loadModels() } } label: {
                        Image(systemName: isChecking ? "hourglass" : "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isChecking)
                    .help(Text("Load models"))
                }
            }
        } label: { SettingLabel("Model") }
    }

    private func save() {
        let settings = draft
        // The first one added becomes the main one, so the assistant turns on.
        if model.assistantSettings.provider == .off {
            model.applyAssistant(settings, apiKey: apiKey.isEmpty ? nil : apiKey)
        } else {
            model.saveAssistantProfile(settings, apiKey: apiKey.isEmpty ? nil : apiKey)
        }
        apiKey = ""
        if model.isReady(settings) {
            editing = nil
            status = nil
        } else {
            status = String(localized: "Saved, but something's missing: a key, a server or a model.")
        }
    }

    /// Asks the provider which models this key or server offers.
    private func loadModels() async {
        guard editing != nil else { return }
        let provider = draft.provider
        isChecking = true
        defer { isChecking = false }
        let key = apiKey.isEmpty ? model.savedAPIKey(for: provider) : apiKey
        do {
            let ids: [String]
            switch provider {
            case .claude:
                guard let key else { status = String(localized: "Add your API key first."); return }
                ids = try await AnthropicModel.availableModels(apiKey: key)
            case .chatGPT, .gemini, .grok, .ollama, .lmStudio, .custom:
                guard let url = URL(string: draft.baseURL) else { status = String(localized: "Check the server address."); return }
                if provider.needsKey && key == nil { status = String(localized: "Add your API key first."); return }
                ids = try await OpenAICompatibleModel.availableModels(baseURL: url, apiKey: key)
            default:
                return
            }
            models = Self.quickestFirst(ids)
            if draft.model.isEmpty, let first = models.first { draft.model = first.id }
            status = nil
        } catch {
            status = provider.hasServerURL && provider != .custom
                ? String(localized: "Couldn't reach \(provider.name). Is it running?")
                : error.localizedDescription
        }
    }

    /// Model ids with the small, quick ones first (haiku, mini, flash, lite, small…): those suit mail.
    static func quickestFirst(_ ids: [String]) -> [ModelChoice] {
        let quick = ["haiku", "mini", "nano", "flash", "lite", "small", "fast", "luna"]
        func isQuick(_ id: String) -> Bool { quick.contains { id.lowercased().contains($0) } }
        return (ids.filter(isQuick) + ids.filter { !isQuick($0) }).map { id in
            ModelChoice(id: id, name: id, detail: isQuick(id) ? String(localized: "Quick and cheap") : "")
        }
    }
}

/// One assistant in the list: what it is, how it connects, its model, whether it's ready, what
/// it's used for, and a menu to change or remove it.
struct AssistantRow: View {
    let settings: AssistantSettings
    let model: MailModel
    let isOpen: Bool
    var isNew = false
    let open: () -> Void
    let remove: () -> Void

    var body: some View {
        let provider = settings.provider
        let ready = isNew || model.isReady(settings)
        HStack(spacing: Space.m) {
            ProviderIcon(provider: provider, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: provider.shortName).font(.system(size: 13, weight: .semibold))
                Text(verbatim: Self.subtitle(settings)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: Space.s)
            if !ready {
                Label("Needs setup", systemImage: "exclamationmark.circle.fill")
                    .font(.caption).foregroundStyle(Status.star)
            }
            ForEach(roles, id: \.self) { role in
                Text(role).font(.caption2.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Fill.two, in: Capsule()).foregroundStyle(.secondary)
            }
            if !isNew {
                Menu {
                    Button(isOpen ? "Close" : "Change…", action: open)
                    if ready && model.assistantSettings.provider != provider {
                        Button("Use for Ask and Writing") { model.applyAssistant(settings, apiKey: nil) }
                    }
                    if ready && model.quickAssistant?.provider != provider {
                        Button("Use for Quick Suggestions") { model.quickProviderChoice = provider }
                    }
                    if ready && model.sortAssistant?.provider != provider {
                        Button("Use for Sorting") { model.sortProviderChoice = provider }
                    }
                    Divider()
                    Button("Remove", role: .destructive, action: remove)
                        .disabled(model.assistantSettings.provider == provider)
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }

    /// What it's used for, as small tags.
    private var roles: [String] {
        var roles: [String] = []
        if model.assistantSettings.provider == settings.provider { roles.append(String(localized: "Ask and writing")) }
        if model.quickAssistant?.provider == settings.provider { roles.append(String(localized: "Quick")) }
        if model.sortAssistant?.provider == settings.provider { roles.append(String(localized: "Sorting")) }
        if model.actionProvider?.provider == settings.provider { roles.append(String(localized: "Actions")) }
        return roles
    }

    /// "Your subscription · Haiku", "API key · claude-haiku-5-5", "On this Mac · free and private".
    static func subtitle(_ settings: AssistantSettings) -> String {
        let how = connection(settings)
        guard settings.provider != .onDevice else { return how }
        return [how, modelName(settings)].compactMap { $0 }.joined(separator: " · ")
    }

    /// How it connects: "Your subscription", "API key", "On this computer"…
    static func connection(_ settings: AssistantSettings) -> String {
        switch settings.provider {
        case .onDevice: String(localized: "On this Mac · free and private")
        case .claudeCode, .codex: String(localized: "Your subscription")
        case .ollama, .lmStudio: String(localized: "On this computer")
        case .custom: URL(string: settings.baseURL)?.host() ?? String(localized: "Your server")
        default: String(localized: "API key")
        }
    }

    /// "Claude Code · Haiku", for the pickers.
    static func label(_ settings: AssistantSettings) -> String {
        [settings.provider.shortName, modelName(settings)].compactMap { $0 }.joined(separator: " · ")
    }

    static func modelName(_ settings: AssistantSettings) -> String? {
        if settings.provider == .onDevice { return nil }
        let known = AssistantSettingsView.knownModels(settings.provider)
        if let match = known.first(where: { $0.id == settings.model }) { return match.name }
        if settings.model.isEmpty { return settings.provider == .codex ? String(localized: "Its default model") : nil }
        return settings.model
    }

    static func symbol(_ provider: AssistantProvider) -> String {
        switch provider {
        case .onDevice: "apple.logo"
        case .claudeCode, .codex: "person.crop.circle.badge.checkmark"
        case .ollama, .lmStudio: "desktopcomputer"
        case .custom: "server.rack"
        case .off: "power"
        default: "key.fill"
        }
    }

    static func tint(_ provider: AssistantProvider) -> Color {
        switch provider {
        case .onDevice: Color(white: 0.2)
        case .claudeCode, .claude: Color(red: 0.80, green: 0.47, blue: 0.33)
        case .codex, .chatGPT: Color(red: 0.06, green: 0.55, blue: 0.45)
        case .gemini: Color(red: 0.26, green: 0.47, blue: 0.95)
        case .grok: Color(white: 0.35)
        case .ollama, .lmStudio: Color(red: 0.45, green: 0.40, blue: 0.85)
        default: Color.gray
        }
    }
}

/// Settings → Assistant → Ask: how answers come out, and what they draw on. Shown only with an
/// assistant to ask.
struct AskSettingsSection: View {
    let model: MailModel

    var body: some View {
        let preferences = Binding(get: { model.askPreferences }, set: { model.askPreferences = $0 })
        Section {
            Picker("Answer length", selection: preferences.length) {
                ForEach(AskPreferences.Length.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            TextField("Your instructions", text: preferences.instructions, prompt: Text("Like: answer in Dutch, and leave newsletters out"), axis: .vertical)
                .lineLimit(2...5)
            Toggle("Only the mailbox in view", isOn: preferences.onlyMailboxInView)
            Toggle("Suggested questions to start", isOn: preferences.showsSuggestions)
        } header: {
            Text("Ask")
        } footer: {
            Text("Ask answers from your mail on this device. With “Only the mailbox in view”, it looks in the mailbox you have open instead of all of them.")
        }
    }
}

/// An assistant's icon: the Claude or ChatGPT app's own icon when that app is on this Mac (asked
/// of macOS, so Margin ships no one else's artwork), else a symbol on its colour.
struct ProviderIcon: View {
    let provider: AssistantProvider
    var size: CGFloat = 28

    var body: some View {
        #if os(macOS)
        if let icon = Self.appIcon(provider) {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            symbol
        }
        #else
        symbol
        #endif
    }

    private var symbol: some View {
        Image(systemName: AssistantRow.symbol(provider))
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(AssistantRow.tint(provider), in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
    }

    #if os(macOS)
    /// The installed app that goes with a provider, newest first.
    static func appIDs(_ provider: AssistantProvider) -> [String] {
        switch provider {
        case .claude, .claudeCode: ["com.anthropic.claudefordesktop"]
        case .chatGPT, .codex: ["com.openai.codex", "com.openai.chat"]
        default: []
        }
    }

    /// A small copy for menus, which draw images at their own size.
    static func menuIcon(_ provider: AssistantProvider) -> Image {
        if let icon = appIcon(provider) {
            let small = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                icon.draw(in: rect)
                return true
            }
            return Image(nsImage: small)
        }
        return Image(systemName: AssistantRow.symbol(provider))
    }

    private static let cache = IconCache()

    static func appIcon(_ provider: AssistantProvider) -> NSImage? {
        if let known = cache.get(provider) { return known }
        let icon = appIDs(provider).lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache.set(provider, icon)
        return icon
    }

    private final class IconCache: @unchecked Sendable {
        private let lock = NSLock()
        private var icons: [AssistantProvider: NSImage?] = [:]
        func get(_ provider: AssistantProvider) -> NSImage?? { lock.withLock { icons[provider] } }
        func set(_ provider: AssistantProvider, _ icon: NSImage?) { lock.withLock { icons[provider] = .some(icon) } }
    }
    #endif
}
