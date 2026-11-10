import MailCore
import SwiftUI

/// Ask about your mail, as a chat: each answer cites the conversations it came from, and
/// offers to act on them once you tap. Type / for commands. Past chats are kept on this device.
struct AskView: View {
    @Bindable var model: MailModel
    @State private var question = ""
    @FocusState private var focused: Bool
    @State private var dictation = Dictation()
    @State private var attaching = false
    @State private var models: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Line.hairline).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.xl) {
                        if let chat = model.currentAskChat {
                            ForEach(chat.turns) { turn in
                                TurnView(model: model, turn: turn).id(turn.id)
                            }
                        } else {
                            empty
                        }
                        if model.isWorking("ask") {
                            HStack(spacing: Space.s) {
                                ProgressView().controlSize(.small)
                                Text("Reading your mail…").font(TypeScale.label).foregroundStyle(Ink.tertiary)
                            }
                        }
                    }
                    .padding(Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.currentAskChat?.turns.count) { _, _ in
                    withAnimation(Motion.quick) { proxy.scrollTo(model.currentAskChat?.turns.last?.id, anchor: .bottom) }
                }
            }
            commands
            input
        }
        #if os(macOS)
        .frame(width: 600, height: 560)
        #endif
        .background(Paper.popover)
        .onAppear {
            model.loadAskChatsIfNeeded()
            focused = true
        }
        .background { CancelKey { model.isAsking = false } }
    }

    private var header: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "sparkles").foregroundStyle(Ink.tertiary)
            Text(verbatim: model.currentAskChat?.title ?? String(localized: "Ask"))
                .font(TypeScale.heading)
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
            Spacer()
            modelPicker
            Menu {
                Button("New chat") { model.newAskChat() }
                if !model.askChats.isEmpty {
                    Divider()
                    ForEach(model.askChats.prefix(15)) { chat in
                        Button(chat.title) { model.openAskChat(chat) }
                    }
                }
            } label: {
                Label("Recent chats", systemImage: "clock.arrow.circlepath")
            }
            .fixedSize()
            Button("Done") { model.isAsking = false }
                .buttonStyle(QuietButtonStyle())
        }
        .padding(.horizontal, Space.l)
        .frame(height: 52)
    }

    /// Which model answers, switchable here.
    @ViewBuilder
    private var modelPicker: some View {
        let current = model.assistantSettings.model
        if !current.isEmpty || !models.isEmpty {
            Menu {
                ForEach(models, id: \.self) { name in
                    Button { model.useModel(name) } label: {
                        if name == current { Label(name, systemImage: "checkmark") } else { Text(verbatim: name) }
                    }
                }
            } label: {
                Text(verbatim: current.isEmpty ? model.assistantAttribution : current)
                    .font(TypeScale.label).foregroundStyle(Ink.tertiary).lineLimit(1)
            }
            .fixedSize()
            .task { models = await model.availableModels() }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Ask anything about your mail, or start with a command.")
                .font(TypeScale.row)
                .foregroundStyle(Ink.secondary)
            GlassChipRow {
                ForEach([AskCommand.catchup, .waiting, .cleanup], id: \.self) { command in
                    Button { model.send(askInput: "/" + command.rawValue) } label: {
                        GlassChip(Text(verbatim: "/" + command.rawValue))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("For example: “When does the Lisbon flat need paying?”")
                .font(TypeScale.label)
                .foregroundStyle(Ink.tertiary)
        }
    }

    /// While typing a slash: the commands that match.
    @ViewBuilder
    private var commands: some View {
        let matches = AskCommand.matching(question)
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(matches, id: \.self) { command in
                    Button {
                        question = ""
                        model.send(askInput: "/" + command.rawValue)
                    } label: {
                        HStack(spacing: Space.s) {
                            Text(verbatim: "/" + command.rawValue).font(TypeScale.rowStrong.monospaced()).foregroundStyle(Ink.primary)
                            Text(command.title).font(TypeScale.label).foregroundStyle(Ink.tertiary)
                            Spacer()
                        }
                        .padding(.horizontal, Space.l)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
            .overlay(alignment: .top) { Rectangle().fill(Line.hairline).frame(height: 1) }
        }
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if !model.askAttachments.isEmpty {
                GlassChipRow {
                    ForEach(model.askAttachments) { file in
                        Button { model.askAttachments.removeAll { $0.id == file.id } } label: {
                            GlassChip(Text(verbatim: "📎 \(file.name)  ✕"))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Space.m)
            }
            if let problem = dictation.problem {
                Text(verbatim: problem).font(TypeScale.label).foregroundStyle(Status.danger).padding(.horizontal, Space.m)
            }
            inputRow
        }
        .fileImporter(isPresented: $attaching, allowedContentTypes: [.pdf, .image, .plainText], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task {
                for url in urls {
                    if let file = await AskAttachment.read(url) { model.askAttachments.append(file) }
                }
            }
        }
    }

    private var inputRow: some View {
        HStack(spacing: Space.s) {
            Button { attaching = true } label: { Image(systemName: "paperclip").foregroundStyle(Ink.tertiary) }
                .buttonStyle(.plain).accessibilityLabel("Attach a picture or PDF")
            Button { dictation.toggle { question = $0 } } label: {
                Image(systemName: dictation.isListening ? "mic.fill" : "mic").foregroundStyle(dictation.isListening ? Status.danger : Ink.tertiary)
            }
            .buttonStyle(.plain).accessibilityLabel(dictation.isListening ? "Stop dictating" : "Dictate")
            TextField("Ask about your mail, or type /", text: $question)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($focused)
                .onSubmit(submit)
            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Ink.inverse)
                    .frame(width: 28, height: 28)
                    .background(question.isEmpty ? Ink.quaternary : Ink.primary, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(question.isEmpty || model.isWorking("ask"))
            .accessibilityLabel("Ask")
        }
        .padding(.horizontal, Space.m)
        .frame(height: 48)
        .background(Fill.one, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(Space.m)
    }

    private func submit() {
        dictation.stop()
        let text = question
        question = ""
        model.send(askInput: text)
    }
}

/// One question and its answer, the mail it came from, and what to do with that mail.
private struct TurnView: View {
    let model: MailModel
    let turn: AskTurn

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(verbatim: turn.question)
                .font(TypeScale.rowStrong)
                .foregroundStyle(Ink.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Fill.two, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(verbatim: turn.answer)
                .font(TypeScale.body)
                .foregroundStyle(turn.isError ? Status.danger : Ink.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !turn.sources.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(turn.sources.enumerated()), id: \.offset) { index, source in
                        let thread = source.thread
                        Button { model.showSources(turn.sources.map(\.thread), selecting: thread) } label: {
                            HStack(spacing: Space.s) {
                                Text(verbatim: "\(index + 1)").font(TypeScale.label.monospacedDigit()).foregroundStyle(Ink.tertiary).frame(width: 14)
                                Avatar(thread.latest.from, size: 18)
                                Text(verbatim: thread.subject).font(TypeScale.row).foregroundStyle(Ink.primary).lineLimit(1)
                                Spacer()
                                Text(RowDate.string(thread.date)).font(TypeScale.label).foregroundStyle(Ink.tertiary)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 30)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(HoverRowStyle())
                    }
                }
                // Changes only happen when tapped: the assistant never acts on its own.
                HStack(spacing: Space.s) {
                    Button(turn.sources.count == 1 ? String(localized: "Archive it") : String(localized: "Archive these \(turn.sources.count)")) {
                        model.archive(turn.sources)
                    }
                    .buttonStyle(QuietButtonStyle())
                    Button("Mark read") { model.markRead(turn.sources) }
                        .buttonStyle(QuietButtonStyle())
                }
            }
        }
    }
}
