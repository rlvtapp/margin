import MailCore
import SwiftUI

/// Settings → Assistant: which model, its key or server, and where mail goes.
struct AssistantSettingsView: View {
    @Bindable var model: MailModel
    @State private var draft: AssistantSettings
    @State private var apiKey = ""
    @State private var models: [String] = []
    @State private var status: String?
    @State private var isChecking = false

    init(model: MailModel) {
        self.model = model
        _draft = State(initialValue: model.assistantSettings)
    }

    var body: some View {
        Form {
            SettingsHeader(.assistant)
            Section {
                Picker(selection: Binding(get: { draft.provider }, set: choose)) {
                    ForEach(AssistantProvider.allCases, id: \.self) { provider in
                        Text(provider.title).tag(provider)
                    }
                } label: { SettingLabel("Assistant") }
                if draft.provider.hasServerURL {
                    LabeledContent {
                        TextField("Server", text: $draft.baseURL,
                                  prompt: Text(verbatim: draft.provider.defaultBaseURL.isEmpty ? "https://…/v1" : draft.provider.defaultBaseURL))
                            .labelsHidden()
                    } label: { SettingLabel("Server") }
                }
                if draft.provider.acceptsKey {
                    LabeledContent {
                        SecureField("API key", text: $apiKey,
                                    prompt: Text(model.savedAPIKey(for: draft.provider) == nil ? "Paste your key" : "Saved in Keychain"))
                            .labelsHidden()
                    } label: {
                        SettingLabel(draft.provider.needsKey ? "API key" : "API key (optional)")
                    }
                }
                if draft.provider != .off && draft.provider != .onDevice {
                    LabeledContent {
                        HStack(spacing: Space.s) {
                            if models.isEmpty {
                                TextField("Model name", text: $draft.model).labelsHidden()
                            } else {
                                Picker("Model", selection: $draft.model) {
                                    ForEach(models.contains(draft.model) || draft.model.isEmpty ? models : [draft.model] + models, id: \.self) { Text($0).tag($0) }
                                }
                                .labelsHidden()
                            }
                            Button(isChecking ? "Loading…" : "Load models") { Task { await loadModels() } }
                                .disabled(isChecking)
                        }
                    } label: { SettingLabel("Model") }
                }
                LabeledContent {
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(draft == model.assistantSettings && apiKey.isEmpty)
                } label: {
                    Text(verbatim: status ?? "").foregroundStyle(.secondary)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.provider.privacyNote)
                    if draft.provider == .onDevice, let reason = OnDeviceModel.unavailableReason {
                        Text(reason).foregroundStyle(Status.danger)
                    }
                }
            }
            if model.isAssistantOn { AgentPermissionsSection(model: model) }
            WritingProfileView(model: model)
        }
        .formStyle(.grouped)
        .onAppear { if draft.provider.hasServerURL || draft.provider.needsKey { Task { await loadModels() } } }
    }

    private func choose(_ provider: AssistantProvider) {
        let saved = model.assistantSettings
        draft = saved.provider == provider ? saved : AssistantSettings(provider: provider)
        apiKey = ""
        models = []
        status = nil
        if provider.hasServerURL { Task { await loadModels() } }
    }

    private func save() {
        model.applyAssistant(draft, apiKey: apiKey.isEmpty ? nil : apiKey)
        apiKey = ""
        status = model.isAssistantOn || draft.provider == .off
            ? String(localized: "Saved.")
            : String(localized: "Saved, but something's missing: a key, a server or a model.")
    }

    /// Asks the provider which models this key or server offers.
    private func loadModels() async {
        isChecking = true
        defer { isChecking = false }
        let key = apiKey.isEmpty ? model.savedAPIKey(for: draft.provider) : apiKey
        do {
            switch draft.provider {
            case .claude:
                guard let key else { status = String(localized: "Add your API key first."); return }
                models = try await AnthropicModel.availableModels(apiKey: key)
            case .chatGPT, .gemini, .grok, .ollama, .lmStudio, .custom:
                guard let url = URL(string: draft.baseURL) else { status = String(localized: "Check the server address."); return }
                if draft.provider.needsKey && key == nil { status = String(localized: "Add your API key first."); return }
                models = try await OpenAICompatibleModel.availableModels(baseURL: url, apiKey: key)
            default:
                return
            }
            if draft.model.isEmpty, let first = models.first { draft.model = first }
            status = switch models.count {
            case 0: String(localized: "No models found.")
            case 1: String(localized: "1 model available.")
            default: String(localized: "\(models.count) models available.")
            }
        } catch {
            status = draft.provider.hasServerURL && !(draft.provider == .custom)
                ? String(localized: "Couldn't reach \(draft.provider.title). Is it running?")
                : error.localizedDescription
        }
    }
}
