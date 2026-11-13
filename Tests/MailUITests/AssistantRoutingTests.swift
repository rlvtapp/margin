import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct AssistantRoutingTests {
    @Test func severalAssistantsEachOnTheirOwnJobs() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        model.applyAssistant(AssistantSettings(provider: .ollama, model: "llama"), apiKey: nil)
        model.saveAssistantProfile(AssistantSettings(provider: .lmStudio, model: "qwen"), apiKey: nil)
        // Adding one keeps the main assistant as it was.
        #expect(model.assistantSettings.provider == .ollama)
        #expect(model.assistantProfiles[.lmStudio]?.model == "qwen")

        model.quickProviderChoice = .lmStudio
        #expect(model.quickAssistant?.provider == .lmStudio)
        #expect(model.quickIntelligence?.model.attribution != model.intelligence?.model.attribution)

        // Removing it puts the quick jobs back on Automatic; the main one can't be removed.
        model.removeAssistantProfile(.lmStudio)
        #expect(model.assistantProfiles[.lmStudio] == nil && model.quickProviderChoice == nil)
        model.removeAssistantProfile(.ollama)
        #expect(model.assistantSettings.provider == .ollama && model.assistantProfiles[.ollama] != nil)
    }

    @Test func withoutApplesModelAutomaticTakesTheCheapestModel() async {
        let model = MailModel(environment: .preview())
        model.applyAssistant(AssistantSettings(provider: .claude, model: "claude-opus-5-5"), apiKey: "test-key")
        // No on-device assistant added here: quick jobs and sorting fall back to the main one,
        // on its cheapest model, while Ask keeps the model picked for it.
        if model.assistantProfiles[.onDevice] == nil {
            #expect(model.quickAssistant?.provider == .claude && model.quickAssistant?.model == "claude-haiku-5-5")
            #expect(model.sortAssistant?.model == "claude-haiku-5-5")
        }
        #expect(model.assistantSettings.model == "claude-opus-5-5")
        #expect(AssistantSettings(provider: .claudeCode, model: "opus").onQuickestModel.model == "haiku")
        // Where the cheapest model isn't known without asking a server, the model stays.
        #expect(AssistantSettings(provider: .ollama, model: "llama").onQuickestModel.model == "llama")
    }

    @Test func turningAIOffMakesAPlainMailApp() async {
        let model = MailModel(environment: .preview())
        await model.reload()
        model.applyAssistant(AssistantSettings(provider: .ollama, model: "llama"), apiKey: nil)
        #expect(model.usesAI && model.isAssistantOn)

        model.isAsking = true
        model.usesAI = false
        #expect(!model.isAssistantOn && !model.isAsking && !model.canAskAgent)
        #expect(model.quickIntelligence == nil && model.sortIntelligence == nil && model.actionProviders.isEmpty)
        // Picking an assistant while it's off doesn't turn AI back on behind the switch.
        model.applyAssistant(AssistantSettings(provider: .ollama, model: "llama"), apiKey: nil)
        #expect(!model.isAssistantOn)
        // AI apps can't connect either.
        model.connectionSettings.enabled = true
        model.startConnectionIfEnabled()
        #expect(model.mcpServer == nil)
        model.connectionSettings.enabled = false

        // The assistants added are still there when it's turned back on.
        model.usesAI = true
        #expect(model.isAssistantOn && model.assistantSettings.provider == .ollama)
    }

    @Test func withTheAssistantOffNothingRuns() async {
        let model = MailModel(environment: .preview())
        model.applyAssistant(AssistantSettings(provider: .off), apiKey: nil)
        #expect(model.quickAssistant == nil && model.quickIntelligence == nil)
    }
}

@MainActor @Suite struct ModelListTests {
    @Test func aServersModelsListTheQuickOnesFirst() {
        let list = AssistantSettingsView.quickestFirst(["gpt-big", "claude-opus-5-5", "gpt-mini", "claude-haiku-5-5", "gemini-flash"])
        #expect(list.prefix(3).map(\.id) == ["gpt-mini", "claude-haiku-5-5", "gemini-flash"])
        #expect(list.first?.detail.isEmpty == false)
        #expect(AssistantRow.subtitle(AssistantSettings(provider: .claudeCode, model: "haiku")).hasSuffix("Haiku"))
        #expect(AssistantRow.label(AssistantSettings(provider: .claudeCode, model: "haiku")) == "Claude Code · Haiku")
    }
}

@MainActor @Suite struct AskModelPickerTests {
    @Test func askCanSwitchToAnyAddedAssistantAndModel() async {
        let model = MailModel(environment: .preview())
        await model.reload()
        model.applyAssistant(AssistantSettings(provider: .ollama, model: "llama"), apiKey: nil)
        model.saveAssistantProfile(AssistantSettings(provider: .lmStudio, baseURL: "http://127.0.0.1:9/v1"), apiKey: nil)
        var lm = AssistantSettings(provider: .lmStudio, baseURL: "http://127.0.0.1:9/v1")
        lm.model = "qwen"
        model.saveAssistantProfile(lm, apiKey: nil)

        let choices = await model.askChoices()
        #expect(choices.contains { $0.settings.provider == .ollama } && choices.contains { $0.settings.provider == .lmStudio })
        // No server to ask here: its own model is still offered.
        #expect(choices.first { $0.settings.provider == .lmStudio }?.models.map(\.id) == ["qwen"])

        model.useAssistant(.lmStudio, model: "qwen-small")
        #expect(model.assistantSettings.provider == .lmStudio && model.assistantSettings.model == "qwen-small")
        #expect(model.assistantSettings.baseURL == "http://127.0.0.1:9/v1")   // the rest of its setup kept
        #expect(model.assistantProfiles[.ollama]?.model == "llama")              // the other one still there
    }
}
