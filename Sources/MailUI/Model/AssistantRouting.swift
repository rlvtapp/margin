import Foundation
import MailCore

/// Several assistants at once, each on the jobs it suits: one for Ask, drafts and summaries (the
/// main one, `assistantSettings`), one for the quick jobs that run on their own as mail opens
/// (suggested replies, label suggestions), and one for actions (`actionProviderChoice`).
/// Every assistant set up is kept (`assistantProfiles`), so switching never loses a key.
extension MailModel {
    /// The assistant picked for quick jobs; nil is Automatic: Apple's model on this Mac when it
    /// has one (fast, free, private), else the main assistant on its cheapest, quickest model.
    public var quickProviderChoice: AssistantProvider? {
        get {
            _ = actionSettingsRevision
            return environment.defaults.string(forKey: "quickProvider").flatMap(AssistantProvider.init(rawValue:))
        }
        set {
            environment.defaults.set(newValue?.rawValue, forKey: "quickProvider")
            actionSettingsRevision += 1
        }
    }

    /// The assistant that does quick jobs now. Only while the assistant is on at all.
    public var quickAssistant: AssistantSettings? {
        guard intelligence != nil else { return nil }
        let profiles = assistantProfiles
        if let choice = quickProviderChoice, let picked = profiles[choice] { return picked }
        if let onDevice = profiles[.onDevice], OnDeviceModel.isAvailable { return onDevice }
        return assistantSettings.onQuickestModel
    }

    /// Writes suggested replies and suggests labels: the quick assistant, or the main one when
    /// the quick one can't be set up.
    var quickIntelligence: MailIntelligence? {
        guard let main = intelligence else { return nil }
        guard let settings = quickAssistant, settings != assistantSettings,
              let model = settings.makeModel(apiKey: apiKey(for: settings)) else { return main }
        return MailIntelligence(model: model)
    }

    /// The assistant picked for sorting mail into Home's groups (Sort Now, and new mail as it
    /// arrives); nil is Automatic, as for quick jobs: a conversation at a time, so a quick
    /// model on this Mac suits it best.
    public var sortProviderChoice: AssistantProvider? {
        get {
            _ = actionSettingsRevision
            return environment.defaults.string(forKey: "sortProvider").flatMap(AssistantProvider.init(rawValue:))
        }
        set {
            environment.defaults.set(newValue?.rawValue, forKey: "sortProvider")
            actionSettingsRevision += 1
        }
    }

    /// The assistant that sorts now. Only while the assistant is on at all.
    public var sortAssistant: AssistantSettings? {
        guard intelligence != nil else { return nil }
        let profiles = assistantProfiles
        if let choice = sortProviderChoice, let picked = profiles[choice] { return picked }
        if let onDevice = profiles[.onDevice], OnDeviceModel.isAvailable { return onDevice }
        return assistantSettings.onQuickestModel
    }

    /// Sorts into groups: the sorting assistant, or the main one when it can't be set up.
    var sortIntelligence: MailIntelligence? {
        guard let main = intelligence else { return nil }
        guard let settings = sortAssistant, settings != assistantSettings,
              let model = settings.makeModel(apiKey: apiKey(for: settings)) else { return main }
        return MailIntelligence(model: model)
    }

    /// Takes an assistant off the list; the main one can't be removed (pick another first).
    public func removeAssistantProfile(_ provider: AssistantProvider) {
        guard provider != assistantSettings.provider else { return }
        var saved = (environment.defaults.data(forKey: "assistantProfiles")
            .flatMap { try? JSONDecoder().decode([String: AssistantSettings].self, from: $0) }) ?? [:]
        saved[provider.rawValue] = nil
        environment.defaults.set(try? JSONEncoder().encode(saved), forKey: "assistantProfiles")
        if quickProviderChoice == provider { quickProviderChoice = nil }
        if sortProviderChoice == provider { sortProviderChoice = nil }
        if actionProviderChoice == provider { actionProviderChoice = nil }
        if provider.acceptsKey { environment.keychain.delete(key: provider.keychainKey) }
        actionSettingsRevision += 1
    }

    /// Whether an added assistant can work as set up: its tool installed, its key and model there.
    public func isReady(_ settings: AssistantSettings) -> Bool {
        settings.makeModel(apiKey: apiKey(for: settings)) != nil
    }
}

extension MailModel {
    /// Off makes Margin a plain mail app: no assistant at all (Ask, summaries, suggested
    /// replies, drafts, translation by AI, rules in words, AI sorting, actions) and no
    /// connections from AI apps. Assistants added stay saved for when it's turned back on.
    /// Sorting into Home's groups keeps working, by Margin's own rules.
    public var usesAI: Bool {
        get {
            _ = actionSettingsRevision
            return !environment.defaults.bool(forKey: "aiOff")
        }
        set {
            guard newValue != usesAI else { return }
            environment.defaults.set(!newValue, forKey: "aiOff")
            actionSettingsRevision += 1
            rebuildIntelligence()
            if newValue { startConnectionIfEnabled() } else { restartConnection() }
            if !newValue { isAsking = false }
        }
    }
}

extension MailModel {
    /// Saves an assistant to the list (and its key, if one was typed) without making it the
    /// main one, unless it already is.
    public func saveAssistantProfile(_ settings: AssistantSettings, apiKey: String?) {
        if settings.provider == assistantSettings.provider {
            applyAssistant(settings, apiKey: apiKey)
            return
        }
        if let apiKey {
            if apiKey.isEmpty {
                environment.keychain.delete(key: settings.provider.keychainKey)
            } else {
                try? environment.keychain.save(apiKey, key: settings.provider.keychainKey)
            }
        }
        rememberAssistantProfile(settings)
    }
}
