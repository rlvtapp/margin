import MailCore
import SwiftUI

/// What the assistant is doing for "Sort my mail" or "Ask Margin to…": each step as it happens,
/// Stop while it works, then what it did, with Undo.
struct AgentRunCard: View {
    @Bindable var model: MailModel

    var body: some View {
        if let run = model.agentRun {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Image(systemName: "sparkles").foregroundStyle(Ink.tertiary)
                    Text(verbatim: run.request)
                        .font(TypeScale.row.weight(.semibold))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(2)
                    Spacer(minLength: Space.s)
                    Text(verbatim: run.attribution).font(.caption).foregroundStyle(Ink.tertiary)
                }
                if !run.steps.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(run.steps.suffix(run.isWorking ? 4 : 3)) { step in
                            Label {
                                // A step that failed didn't happen: struck through, with its own icon.
                                Text(verbatim: step.title).strikethrough(step.isError)
                            } icon: {
                                Image(systemName: step.isError ? "exclamationmark.circle" : "checkmark.circle")
                                    .foregroundStyle(step.isError ? Status.danger : Ink.tertiary)
                            }
                            .font(.caption)
                            .foregroundStyle(Ink.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                ForEach(run.handoffs, id: \.self) { note in
                    Label(note, systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if run.isWorking {
                    HStack(spacing: Space.s) {
                        ProgressView().controlSize(.small)
                        Text(progressText(run)).font(.caption).foregroundStyle(Ink.secondary)
                        Spacer()
                        Button("Stop") { model.stopAgent() }
                            .keyboardShortcut(.cancelAction)
                    }
                } else {
                    Text(verbatim: summary(run))
                        .font(TypeScale.row)
                        .foregroundStyle(failed(run) ? Status.danger : Ink.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if run.couldOnlyLook {
                        Text("To let the assistant make changes, turn on Allow changes in Settings → Assistant.")
                            .font(.caption)
                            .foregroundStyle(Ink.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: Space.s) {
                        Spacer()
                        if model.canUndoAgentRun {
                            Button("Undo") { Task { await model.undoAgentRun() } }
                        }
                        Button("Done") { withAnimation(Motion.quick) { model.dismissAgentRun() } }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(Space.l)
            .frame(maxWidth: 400, alignment: .leading)
            .background(Paper.popover, in: RoundedRectangle(cornerRadius: Radius.surface, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.surface, style: .continuous).strokeBorder(Line.edge))
            .shadow(color: .black.opacity(0.14), radius: 24, y: 10)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(Motion.quick, value: run.steps.count)
        }
    }

    private func progressText(_ run: AgentRun) -> String {
        if run.kind == .sort, let progress = model.sortingProgress, progress.total > 0 {
            return String(localized: "Sorted \(progress.done) of \(progress.total)")
        }
        return String(localized: "Working…")
    }

    private func failed(_ run: AgentRun) -> Bool {
        if case .failed = run.state { return true }
        return false
    }

    private func summary(_ run: AgentRun) -> String {
        switch run.state {
        case .working: return ""
        case .failed(let message): return message
        case .stopped: return String(localized: "Stopped. What's done so far stays done.")
        case .finished:
            if run.reachedLimit { return String(localized: "Stopped after \(run.steps.count) steps. Ask again to carry on.") }
            if !run.summary.isEmpty { return run.summary }
            return String(localized: "Finished after \(run.steps.count) steps.")
        }
    }
}

/// iPhone and iPad: type what Margin should do, or sort the inbox.
struct AgentPromptSheet: View {
    @Bindable var model: MailModel
    @State private var request = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Ask Margin to…", text: $request, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit(ask)
                } footer: {
                    if model.actionProvider == nil {
                        Text(verbatim: model.noActionProviderMessage)
                    } else if model.connectionSettings.allowChanges {
                        Text("It uses the tools you allow in Settings → Assistant. Undo puts back what it changed.")
                    } else {
                        Text("To let the assistant make changes, turn on Allow changes in Settings → Assistant.")
                    }
                }
                Section {
                    Button {
                        dismiss()
                        model.sortMailWithAssistant()
                    } label: {
                        Label("Sort my mail", systemImage: "wand.and.stars")
                    }
                }
            }
            .navigationTitle("Ask Margin")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ask", action: ask).disabled(request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func ask() {
        let text = request
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        dismiss()
        model.askAgent(text)
    }
}

/// Settings → Assistant: what the assistant may change. The same switches as AI apps get over
/// MCP, so there's one answer to "what may AI do with my mail".
struct AgentPermissionsSection: View {
    @Bindable var model: MailModel

    var body: some View {
        Section {
            Toggle(isOn: binding(\.allowChanges)) {
                SettingLabel("Allow changes",
                             detail: "Label, archive, move, snooze, trash, folders, templates, newsletters and the outbox. Apps can undo their own last change.")
            }
            Toggle(isOn: binding(\.allowSettings)) {
                SettingLabel("Allow settings changes",
                             detail: "Appearance, layout, Undo Send, follow-up time and signatures.")
            }
            Toggle(isOn: binding(\.allowSending)) {
                SettingLabel("Allow sending",
                             detail: "Off means apps can only open a draft in Margin for you to send yourself.")
            }
        } header: {
            Text("What the assistant may do")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ask it with “Ask Margin to…” or “Sort my mail”. The same switches apply to AI apps connected to Margin. “Sort my mail” can always sort into Home's groups.")
            }
        }
        if !model.connectionActivity.isEmpty {
            Section {
                ForEach(model.connectionActivity.prefix(6)) { ActivityRow(entry: $0) }
            } header: {
                Text("Recent activity")
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<ConnectionSettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.connectionSettings[keyPath: keyPath] }, set: { value in
            var settings = model.connectionSettings
            settings[keyPath: keyPath] = value
            model.applyConnections(settings)
        })
    }
}

/// Which assistant takes actions (Sort my mail, Ask Margin to…), and in plain words whether the
/// one for Ask and writing can; a local model can be checked.
struct ActionProviderPicker: View {
    @Bindable var model: MailModel
    @State private var isChecking = false
    @State private var checkResult: String?

    var body: some View { providerPicker }

    /// Which provider takes actions, and in plain words whether the assistant chosen above can.
    @ViewBuilder
    private var providerPicker: some View {
        let providers = model.actionProviders.sorted { a, b in
            (AssistantProvider.actionOrder.firstIndex(of: a.provider) ?? 0) < (AssistantProvider.actionOrder.firstIndex(of: b.provider) ?? 0)
        }
        let main = model.assistantSettings
        VStack(alignment: .leading, spacing: 6) {
            Picker(selection: Binding(get: { model.actionProviderChoice }, set: { model.actionProviderChoice = $0 })) {
                // Automatic is the first in the usual order: hosted, then local, then on device.
                if let first = providers.first {
                    Text("Automatic (\(first.displayName))").tag(AssistantProvider?.none)
                } else {
                    Text("Automatic").tag(AssistantProvider?.none)
                }
                ForEach(providers, id: \.provider) { settings in
                    Text(verbatim: settings.displayName).tag(Optional(settings.provider))
                }
            } label: {
                SettingLabel("For actions, use",
                             detail: "Sort my mail and Ask Margin to… use this provider. Summaries and replies stay with the assistant above.")
            }
            Group {
                if model.actionProvider == nil {
                    Text(verbatim: model.noActionProviderMessage).foregroundStyle(Status.danger)
                } else if model.canTakeActions(main) == false {
                    Text(verbatim: AssistantError.toolsUnsupported(main.displayName).localizedDescription + " "
                         + String(localized: "Actions go to \(model.actionProvider?.displayName ?? "") instead."))
                } else if model.canTakeActions(main) == nil {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Whether \(main.displayName) can take actions depends on the model.")
                        Spacer()
                        Button(isChecking ? String(localized: "Checking…") : String(localized: "Check")) { check(main) }
                            .disabled(isChecking)
                    }
                }
                if let checkResult { Text(verbatim: checkResult) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func check(_ settings: AssistantSettings) {
        isChecking = true
        checkResult = nil
        Task {
            defer { isChecking = false }
            switch await model.checkActions(settings) {
            case .success(true): checkResult = String(localized: "\(settings.displayName) can take actions.")
            case .success(false): checkResult = AssistantError.toolsUnsupported(settings.displayName).localizedDescription
            case .failure(let error): checkResult = error.localizedDescription
            }
        }
    }
}

/// One line of Recent activity: what was done, by whom when it was Margin's own assistant.
struct ActivityRow: View {
    let entry: MCPActivity

    var body: some View {
        LabeledContent {
            Text(entry.date.formatted(.relative(presentation: .named)))
        } label: {
            Text(ConnectionsSettingsView.describe(entry.tool))
            if let by = entry.by { Text(verbatim: by) }
        }
    }
}
