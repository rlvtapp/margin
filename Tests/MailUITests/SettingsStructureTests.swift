import Foundation
import MailCore
import Testing
@testable import MailUI

/// Settings were regrouped: nothing may be lost on the way, and a search has to find every
/// setting by the name its page shows.
@MainActor @Suite struct SettingsStructureTests {
    /// Every setting and button of Settings, by its name, and the page it lives on.
    private static let everySetting: [(String, SettingsPage)] = {
        var all: [(String, SettingsPage)] = [
            ("Language", .general), ("Block trackers, even when pictures are loaded", .general),
            ("Keep on this device", .general), ("Open recent mail instantly", .general), ("Clear Downloaded Mail", .general),
            ("Add Mailbox…", .mailboxes), ("Sign In Again…", .mailboxes), ("Mailbox name", .mailboxes), ("Sender name", .mailboxes),
            ("Show in All Inboxes", .mailboxes), ("Send as", .mailboxes), ("Server and sign-in", .mailboxes), ("Picture", .mailboxes),
            ("Edit Workspaces…", .workspaces), ("Make Workspaces…", .workspaces),
            ("Add Address Book…", .contacts), ("CardDAV", .contacts), ("Refresh Now", .contacts),
            ("Notify me about", .notifications), ("Sound", .notifications), ("Meeting reminders", .notifications),
            ("Reminder sound", .notifications), ("Copy sign-in codes when they arrive", .signInCodes), ("VIPs", .vips),
            ("Text size", .reading), ("Show mail as", .reading), ("Plain text", .reading), ("Show conversations as a chat", .reading),
            ("Offer to translate", .reading), ("Dark mode for emails", .reading), ("Waiting for reply after", .reading),
            ("Undo send", .writing), ("Forgotten attachment reminder", .writing), ("Sent from Margin", .signatures),
            ("Add a Signature…", .signatures), ("For replies and forwards", .signatures),
            ("New template", .templates),
            ("Sort new mail as it arrives", .sorting), ("Sort Now", .sorting), ("Add Group", .sorting), ("Start Over", .sorting),
            ("Add Rule", .rules), ("Blocked senders", .rules), ("Muted conversations", .rules), ("Unmute All", .rules),
            ("Theme", .appearance), ("Accent", .appearance), ("Size", .appearance), ("Compact", .appearance), ("App icon", .appearance),
            ("Color-blind safe", .appearance), ("Increase contrast", .appearance), ("Underline links in mail", .appearance),
            ("Reduce motion", .appearance),
            ("Layout", .layout), ("One line", .layout), ("Three lines", .layout),
            ("Swipe right", .shortcuts), ("Swipe left", .shortcuts), ("Second action", .shortcuts),
            ("Use AI", .assistant), ("Add Assistant", .assistant), ("Ask and writing", .assistant), ("Quick suggestions", .assistant),
            ("Sorting into groups", .assistant), ("For actions, use", .assistant), ("Answer length", .ask),
            ("Only the mailbox in view", .ask), ("Suggested questions to start", .ask), ("Allow changes", .permissions),
            ("Allow settings changes", .permissions), ("Allow sending", .permissions),
            ("Instructions for the assistant", .writingStyle), ("Learn how I write", .writingStyle),
            ("Suggest short replies", .writingStyle), ("Your voice", .writingStyle), ("Try it", .writingStyle),
            ("Sync with iCloud", .backup), ("Export Backup…", .backupFiles), ("Include mail passwords and API keys", .backupFiles),
            ("Restore from Backup…", .restore), ("Automatic backups", .backupFiles), ("Back Up Now", .backupFiles), ("Recovery key", .backupFiles),
            ("Link Another Device…", .backup),
            ("Show Welcome", .about),
        ]
        #if os(macOS)
        all += [
            ("Email links", .general), ("Make Margin the default mail app", .general),
            ("Hide Margin from screen sharing and recordings", .general),
            ("Drop-down alerts", .notifications), ("Menu bar", .notifications), ("Unread count on the Dock icon", .notifications),
            ("Type new codes into the field you're in", .signInCodes),
            ("Hold Space to dictate", .experimental),
            ("Inset panel", .layout), ("Edge to edge", .layout), ("Account column", .layout), ("Show button names", .layout),
            ("Single-key shortcuts (E, R, J, K…)", .shortcuts), ("Start from the keys of", .shortcuts),
            ("Restore the original keys", .shortcuts), ("Buttons on hover", .shortcuts),
            ("Let AI apps use Margin", .connections), ("Mailboxes AI apps can see", .connections), ("New token", .connections),
        ]
        #endif
        return all
    }()

    @Test func aSearchFindsEverySettingOnItsPage() {
        for (name, page) in Self.everySetting {
            let found = SettingsPage.groups(matching: name).flatMap(\.pages)
            #expect(found.contains(page), "“\(name)” should be found on \(page.rawValue)")
            #expect(page.hits(for: name).contains(name), "“\(name)” should be listed under \(page.rawValue)")
        }
    }

    @Test func aSearchIgnoresCaseAndAccentsAndFindsWordsInTheMiddle() {
        #expect(SettingsPage.writing.matches("UNDO"))
        #expect(SettingsPage.general.hits(for: "instantly") == ["Open recent mail instantly"])
        #expect(SettingsPage.groups(matching: "no such setting anywhere").isEmpty)
        // Words are found from their start, so "ai" doesn't find every "mail" and "email".
        #expect(!SettingsPage.mailboxes.matches("ai") && !SettingsPage.general.matches("ai") && !SettingsPage.notifications.matches("ai"))
        #expect(SettingsPage.groups(matching: "ai").flatMap(\.pages) == SettingsPage.groups.first { $0.id == "ai" }?.pages)
        #expect(SettingsPage.holds("收件箱整理", "整理"))
        #expect(SettingsPage.groups(matching: "").flatMap(\.pages) == SettingsPage.groups.flatMap(\.pages))
    }

    @Test func everyPageIsInOneGroupAndSaysWhatIsOnIt() {
        let listed = SettingsPage.groups.flatMap(\.pages)
        #expect(Set(listed) == Set(SettingsPage.available) && listed.count == SettingsPage.available.count)
        for page in SettingsPage.available {
            #expect(!page.title.isEmpty && !page.blurb.isEmpty && !page.settings.isEmpty)
        }
    }

    @Test func theSidebarHasNamedGroupsAndOnlySplitPagesAreFolded() {
        #expect(SettingsPage.groups.map(\.id) == ["margin", "mail", "look", "ai", "data"])
        #expect(SettingsPage.groups.first?.title == nil && SettingsPage.groups.dropFirst().allSatisfy { $0.title != nil })
        // Pages of their own stand in their group; only a page split off a long one is under it.
        for page in [SettingsPage.workspaces, .contacts, .signatures, .templates, .layout, .shortcuts, .writingStyle] {
            #expect(page.parent == nil, "\(page.rawValue)")
        }
        #expect(SettingsPage.vips.parent == .notifications && SettingsPage.signInCodes.parent == .notifications)
        #expect(SettingsPage.restore.parent == .backup && SettingsPage.backupFiles.parent == .backup)
        #expect(SettingsPage.ask.parent == .assistant && SettingsPage.permissions.parent == .assistant)
        // A split page comes right after the page it came from, in the same group.
        for group in SettingsPage.groups {
            for page in group.pages where page.parent != nil {
                let row = try? #require(page.parent)
                #expect(row.map(group.pages.contains) == true)
            }
        }
        // What goes under your signature is set where signatures are.
        #expect(SettingsPage.signatures.hits(for: "sent from") == ["Sent from Margin"] && !SettingsPage.writing.matches("sent from"))
    }

    @Test func lookingForAWayToTurnAIOffLeadsToTheSwitch() {
        for words in ["ai", "turn off ai", "disable ai", "assistant", "Use AI"] {
            #expect(SettingsPage.groups(matching: words).flatMap(\.pages).contains(.assistant), "“\(words)”")
        }
        // Everything AI sits together, under its own name.
        let ai = SettingsPage.groups.first { $0.id == "ai" }
        #expect(ai?.title == "AI" && ai?.pages.first == .assistant && ai?.pages.contains(.writingStyle) == true)
    }

    @Test func pagesThatMovedAreStillReachedByTheirOldNames() {
        #expect(SettingsPage(named: "experimental") == .experimental)
        #expect(SettingsPage(named: "connections") == .connections && SettingsPage(named: "rules") == .rules)
        #expect(SettingsPage(named: "nowhere") == nil)
        #expect(SettingsPage.experimental.matches("dictate") && SettingsPage(named: "ai") == .assistant)
    }
}

/// The one switch for everything AI: off, nothing AI shows, runs or connects.
@MainActor @Suite struct AISwitchTests {
    private func modelWithAnAssistant() async -> MailModel {
        let model = MailModel(environment: .preview())
        await model.reload()
        model.applyAssistant(AssistantSettings(provider: .ollama, model: "llama"), apiKey: nil)
        return model
    }

    @Test func offMeansNoAssistantOfAnyKind() async {
        let model = await modelWithAnAssistant()
        #expect(model.isAssistantOn && model.quickIntelligence != nil && model.sortIntelligence != nil)
        model.usesAI = false
        #expect(!model.isAssistantOn && !model.canAskAgent)
        #expect(model.intelligence == nil && model.quickIntelligence == nil && model.sortIntelligence == nil)
        #expect(model.quickAssistant == nil && model.sortAssistant == nil && model.actionProviders.isEmpty && model.actionProvider == nil)
        #expect(model.assistantAttribution.isEmpty)
        model.usesAI = true
    }

    @Test func offHidesEveryAICommandAndAsk() async {
        let model = await modelWithAnAssistant()
        let withAI = MailCommand.all(for: model)
        #expect(withAI.contains { $0.needsAssistant })
        model.usesAI = false
        #expect(!MailCommand.all(for: model).contains { $0.needsAssistant })
        // A question typed into search is a search again, not a question for the assistant.
        #expect(!model.offersAsk(for: "what did Ada say about the invoice?"))
        model.usesAI = true
    }

    @Test func offRunsNothingThatWasAskedFor() async throws {
        let model = await modelWithAnAssistant()
        model.usesAI = false
        let thread = try #require(model.visibleThreads.first)
        model.select(thread.id)
        model.summarizeSelected()
        model.suggestLabelsForSelected()
        #expect(!model.isWorking("summary", on: thread) && model.summaries[thread.id] == nil)
        await model.suggestReplies(for: thread)
        #expect((model.replySuggestions[thread.id] ?? []).isEmpty)
        #expect(model.isAsking == false)
        model.usesAI = true
    }

    @Test func offStopsWorkInFlightAndKeepsAIAppsOut() async {
        let model = await modelWithAnAssistant()
        model.isAsking = true
        var connections = model.connectionSettings
        connections.enabled = true
        model.usesAI = false
        #expect(!model.isAsking && !model.isSorting)
        // Turning connections on, or asking for a new token, starts nothing while AI is off.
        model.applyConnections(connections)
        model.startConnectionIfEnabled()
        #expect(model.mcpServer == nil)
        connections.enabled = false
        model.applyConnections(connections)
        model.usesAI = true
    }

    @Test func offDoesNotLearnFromMailYouSend() async throws {
        let model = await modelWithAnAssistant()
        let account = try #require(model.accounts.first)
        model.learnsWriting = true
        model.usesAI = false
        let before = model.writingProfile.overall.messages
        var draft = Draft(from: account.address, to: [EmailAddress(address: "ada@example.com")])
        draft.text = "Hi Ada,\n\nThe flat by the river is free in May, shall I book it for the two of us?\n\nThanks"
        model.learnWriting(from: draft, account: account)
        #expect(model.writingProfile.overall.messages == before)
        model.usesAI = true
    }

    @Test func theChoiceAndTheAssistantsSurviveTheSwitch() async {
        let model = await modelWithAnAssistant()
        model.usesAI = false
        // Setting up an assistant while it's off doesn't turn AI back on behind the switch.
        model.applyAssistant(AssistantSettings(provider: .ollama, model: "llama"), apiKey: nil)
        #expect(!model.isAssistantOn && model.assistantSettings.provider == .ollama)
        model.usesAI = true
        #expect(model.isAssistantOn && model.assistantProfiles[.ollama] != nil)
    }
}
