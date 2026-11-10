import MailCore
import SwiftUI

/// Settings → Assistant → Your writing: what Margin has learned about how you write, overall
/// and per person, with a way to forget someone or start over.
struct WritingProfileView: View {
    @Bindable var model: MailModel
    @State private var tryText = ""
    @State private var trySender = ""
    @State private var tryNote = ""
    @State private var tryResult: (reply: String, about: String, instructions: String)?
    @State private var tryError: String?
    @State private var isTrying = false

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
            Text("Your writing")
        }
        if model.learnsWriting {
            Section {
                if profile.isEmpty {
                    SettingsEmptyRow(model.isLearningWriting ? "Reading your sent mail…" : "Nothing learned yet.")
                } else {
                    habits(profile.overall, title: Text("Usually"))
                    if profile.languages.count > 1 {
                        LabeledContent("Languages") {
                            Text(verbatim: profile.languages.sorted { $0.value.messages > $1.value.messages }
                                .map { "\(Locale.current.localizedString(forLanguageCode: $0.key) ?? $0.key) · \($0.value.messages)" }
                                .joined(separator: ", "))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !profile.frequentPeople.isEmpty {
                        Text("With people you write to most").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    ForEach(Array(profile.frequentPeople.prefix(8)), id: \.address) { person in
                        LabeledContent {
                            Button("Forget") { model.forgetWriting(to: person.address) }
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
                        Button("Start over") { model.resetWritingProfile() }
                    }
                }
            }
            tryItSection
        }
    }

    /// Paste an email and see the reply Margin would write as you.
    @ViewBuilder
    private var tryItSection: some View {
        Section {
            TextField("From (name or address, optional)", text: $trySender)
            TextField("Paste an email to answer", text: $tryText, axis: .vertical)
                .lineLimit(4...10)
            TextField("What should the reply say? (optional)", text: $tryNote)
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
                    Text("Turn on the assistant to try this.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let tryError {
                Text(verbatim: tryError).font(.caption).foregroundStyle(.red)
            }
            if let tryResult {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: tryResult.reply).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: tryResult.about).font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("What Margin told the assistant") {
                        Text(verbatim: tryResult.instructions)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.caption)
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Try it")
        } footer: {
            Text("Nothing is sent or saved. The reply uses the assistant you chose, in the email's language.")
        }
    }

    /// "Hi {name}, · Cheers · about 40 words · casual · 23 emails"
    private func habits(_ habits: WritingProfile.Habits, title: Text) -> some View {
        var parts: [String] = []
        if let greeting = habits.usualGreeting { parts.append("“\(greeting.replacingOccurrences(of: "{name}", with: "…"))”") }
        if let signOff = habits.usualSignOff { parts.append("“\(signOff)”") }
        if let length = habits.typicalLength { parts.append(String(localized: "about \(length) words")) }
        parts.append(habits.isCasual ? String(localized: "casual") : String(localized: "polished"))
        parts.append(habits.messages == 1 ? String(localized: "1 email") : String(localized: "\(habits.messages) emails"))
        return VStack(alignment: .leading, spacing: 2) {
            title
            Text(verbatim: parts.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
