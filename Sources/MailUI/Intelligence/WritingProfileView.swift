import MailCore
import SwiftUI

/// Settings → Writing Style: what Margin has learned about how you write, overall
/// and per person, with a way to forget someone or start over.
struct WritingProfileView: View {
    @Bindable var model: MailModel
    @State private var tryText = ""
    @State private var trySender = ""
    @State private var tryNote = ""
    @State private var tryResult: (reply: String, about: String, instructions: String)?
    @State private var tryError: String?
    @State private var isTrying = false
    @State private var isStudying = false
    @State private var studyError: String?

    /// Sections for a Settings form: the switches, then what was learned.
    var body: some View {
        let profile = model.writingProfile
        Section {
            Toggle(isOn: Binding(get: { model.learnsWriting }, set: { model.learnsWriting = $0 })) {
                SettingLabel("Learn how I write",
                             detail: "Margin learns from the emails you send, on this device, and drafts replies the same way. Nothing is sent anywhere to learn it.")
            }
            Toggle(isOn: Binding(get: { model.suggestsReplies }, set: { model.suggestsReplies = $0 })) {
                SettingLabel("Suggest short replies",
                             detail: "Three quick answers under mail from people. Tap one to write it out.")
            }
        } header: {
            Text("Your writing", tableName: "Settings")
        }
        // Read from disk the first time something needs it; this page needs it at once.
        .onAppear { model.loadWritingProfileIfNeeded() }
        // With an assistant to study with; while AI is off, with the one that would, so the
        // section doesn't vanish with the switch.
        if model.learnsWriting && (model.isAssistantOn || (!model.usesAI && model.assistantSettings.provider != .off)) { voiceSection(profile) }
        if model.learnsWriting {
            Section {
                if profile.isEmpty {
                    SettingsEmptyRow(model.isLearningWriting ? "Reading your sent mail…" : "Nothing learned yet.")
                } else {
                    habits(profile.overall, title: Text("Usually", tableName: "Settings"))
                    if profile.languages.count > 1 {
                        LabeledContent("Languages") {
                            Text(verbatim: profile.languages.sorted { $0.value.messages > $1.value.messages }
                                .map { "\(Locale.current.localizedString(forLanguageCode: $0.key) ?? $0.key) · \($0.value.messages)" }
                                .joined(separator: ", "))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !profile.frequentPeople.isEmpty {
                        Text("With people you write to most", tableName: "Settings").font(TypeScale.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    ForEach(Array(profile.frequentPeople.prefix(8)), id: \.address) { person in
                        LabeledContent {
                            Button(String(localized: "Forget", table: "Settings")) { model.forgetWriting(to: person.address) }
                        } label: {
                            habits(person.habits, title: Text(verbatim: person.name))
                        }
                    }
                }
                HStack {
                    Button(profile.isEmpty ? "Learn from sent mail" : "Learn from new sent mail") {
                        Task { await model.learnFromSentMail() }
                    }
                    .disabled(model.isLearningWriting)
                    if !profile.isEmpty {
                        Button(String(localized: "Start over", table: "Settings")) { model.resetWritingProfile() }
                    }
                }
            }
            tryItSection
        }
    }

    /// What the assistant found when it read your sent mail, and the button to have it read again.
    @ViewBuilder
    private func voiceSection(_ profile: WritingProfile) -> some View {
        let voices = profile.voices.sorted { $0.value.emails > $1.value.emails }
        let assistant = AssistantRow.label(model.studyAssistant ?? model.assistantSettings)
        Section {
            if voices.isEmpty {
                SettingsEmptyRow(isStudying ? "Reading your sent mail…" : "Not studied yet. Margin's own learning below already shapes drafts; a study adds how you sound.")
            }
            ForEach(voices, id: \.key) { language, voice in
                VStack(alignment: .leading, spacing: 6) {
                    if voices.count > 1 {
                        Text(verbatim: Locale.current.localizedString(forLanguageCode: language) ?? language)
                            .font(TypeScale.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Text(verbatim: voice.text)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Studied by \(voice.by) from \(voice.emails) emails, \(voice.date.formatted(date: .abbreviated, time: .omitted)).", tableName: "Settings")
                        .font(TypeScale.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            HStack {
                Button(isStudying ? String(localized: "Studying…", table: "Settings") : voices.isEmpty ? String(localized: "Study My Writing", table: "Settings") : String(localized: "Study Again", table: "Settings")) {
                    isStudying = true
                    studyError = nil
                    Task {
                        defer { isStudying = false }
                        do { try await model.studyWriting() } catch { studyError = error.localizedDescription }
                    }
                }
                .disabled(isStudying)
                if !voices.isEmpty && !isStudying {
                    Button(String(localized: "Forget", table: "Settings")) { model.forgetStudiedVoice() }
                }
                if isStudying { ProgressView().controlSize(.small) }
            }
            if let studyError {
                Text(verbatim: studyError).font(TypeScale.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Your voice", tableName: "Settings")
        } footer: {
            Text("\(assistant) reads up to 40 of your recent sent emails per language, once, and describes how you write: tone, sentence length, words you use. Only the description is kept, and every draft follows it.", tableName: "Settings")
        }
    }

    /// Paste an email and see the reply Margin would write as you.
    @ViewBuilder
    private var tryItSection: some View {
        Section {
            TextField(String(localized: "From (name or address, optional)", table: "Settings"), text: $trySender)
            TextField(String(localized: "Paste an email to answer", table: "Settings"), text: $tryText, axis: .vertical)
                .lineLimit(4...10)
            TextField(String(localized: "What should the reply say? (optional)", table: "Settings"), text: $tryNote)
            HStack {
                Button(isTrying ? "Writing…" : "Write my reply") {
                    isTrying = true
                    tryError = nil
                    Task {
                        defer { isTrying = false }
                        do { tryResult = try await model.tryReply(to: tryText, from: trySender, note: tryNote) } catch {
                            tryError = error.localizedDescription
                        }
                    }
                }
                .disabled(isTrying || tryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.isAssistantOn)
                if !model.isAssistantOn {
                    Text("Turn on the assistant to try this.", tableName: "Settings").font(TypeScale.caption).foregroundStyle(.secondary)
                }
            }
            if let tryError {
                Text(verbatim: tryError).font(TypeScale.caption).foregroundStyle(.red)
            }
            if let tryResult {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: tryResult.reply).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: tryResult.about).font(TypeScale.caption).foregroundStyle(.secondary)
                    DisclosureGroup(String(localized: "What Margin told the assistant", table: "Settings")) {
                        Text(verbatim: tryResult.instructions)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(TypeScale.caption)
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Try it", tableName: "Settings")
        } footer: {
            Text("Nothing is sent or saved. The reply uses the assistant you chose, in the email's language.", tableName: "Settings")
        }
    }

    /// "Hi {name}, · Cheers · about 40 words · casual · 23 emails"
    private func habits(_ habits: WritingProfile.Habits, title: Text) -> some View {
        var parts: [String] = []
        if let greeting = habits.usualGreeting { parts.append("“\(greeting.replacingOccurrences(of: "{name}", with: "…"))”") }
        if let signOff = habits.usualSignOff { parts.append("“\(signOff)”") }
        if let length = habits.typicalLength { parts.append(String(localized: "about \(length) words", table: "Settings")) }
        if let sentence = habits.typicalSentence { parts.append(String(localized: "sentences of about \(sentence) words", table: "Settings")) }
        if let formal = habits.addressesFormally { parts.append(formal ? String(localized: "formal", table: "Settings") : String(localized: "informal", table: "Settings")) }
        // Formal or informal address says it better where a language has it.
        if habits.addressesFormally == nil { parts.append(habits.isCasual ? String(localized: "casual", table: "Settings") : String(localized: "polished", table: "Settings")) }
        parts.append(habits.messages == 1 ? String(localized: "1 email", table: "Settings") : String(localized: "\(habits.messages) emails", table: "Settings"))
        return VStack(alignment: .leading, spacing: 2) {
            title
            Text(verbatim: parts.joined(separator: " · "))
                .font(TypeScale.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
