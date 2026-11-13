import MailCore
import SwiftUI

/// Ask about your mail, as a chat: each answer cites the conversations it came from, and
/// offers to act on them once you tap. Type / for commands. Past chats are kept on this device.
struct AskView: View {
    @Bindable var model: MailModel
    /// In the reading pane when no conversation is open, instead of a sheet: fills the pane
    /// and has no Done button.
    var inPane = false
    @State private var question = ""
    /// The question being answered, shown at once instead of after the answer arrives.
    @State private var pending: String?
    @FocusState private var focused: Bool
    @State private var dictation = Dictation()
    @State private var attaching = false
    /// Every ready assistant's models, for the picker in the header.
    @State private var choices: [(settings: AssistantSettings, models: [ModelChoice])] = []

    /// The chat keeps to a comfortable reading width, however wide the pane.
    private let column: CGFloat = 680

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if let chat = model.currentAskChat, !chat.turns.isEmpty {
                            ForEach(chat.turns) { turn in
                                TurnView(model: model, turn: turn).id(turn.id)
                            }
                        } else if pending == nil {
                            empty
                        }
                        if let pending, model.isWorking("ask") {
                            VStack(alignment: .leading, spacing: Space.m) {
                                QuestionBubble(text: pending)
                                AskProgressView(progress: model.askProgress)
                            }
                            .id("pending")
                        }
                    }
                    .padding(.horizontal, Space.xl)
                    .padding(.vertical, Space.xl)
                    .frame(maxWidth: column)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: model.currentAskChat?.turns.count) { _, _ in
                    pending = nil
                    withAnimation(Motion.quick) { proxy.scrollTo(model.currentAskChat?.turns.last?.id, anchor: .bottom) }
                }
                .onChange(of: pending) { _, value in
                    if value != nil { withAnimation(Motion.quick) { proxy.scrollTo("pending", anchor: .bottom) } }
                }
                // Keeps the answer in view while it's being written.
                .onChange(of: model.askProgress) { _, progress in
                    if case .writing = progress { proxy.scrollTo("pending", anchor: .bottom) }
                }
            }
            VStack(spacing: 0) {
                commands
                input
            }
            .frame(maxWidth: column)
            .frame(maxWidth: .infinity)
        }
        #if os(macOS)
        .frame(width: inPane ? nil : 640, height: inPane ? nil : 600)
        .frame(maxWidth: inPane ? .infinity : nil, maxHeight: inPane ? .infinity : nil)
        #endif
        .background(inPane ? Paper.panel : Paper.popover)
        .onAppear {
            model.loadAskChatsIfNeeded()
            // In the pane the list keeps the keyboard until you click into the question.
            if !inPane { focused = true }
        }
        .onChange(of: model.isWorking("ask")) { _, working in if !working { pending = nil } }
        .background { if !inPane { CancelKey { model.isAsking = false } } }
    }

    /// A quiet top line: the chat's title, then a new chat and earlier chats as icons.
    private var header: some View {
        HStack(spacing: Space.s) {
            Text(verbatim: model.currentAskChat?.title ?? String(localized: "Ask"))
                .font(TypeScale.heading)
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
            Spacer()
            modelPicker
            Menu {
                if model.askChats.isEmpty { Text("No earlier chats") }
                ForEach(model.askChats.prefix(15)) { chat in
                    Button(chat.title) { model.openAskChat(chat) }
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: Look.size(13))).foregroundStyle(Ink.tertiary)
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            #if os(macOS)
            .menuIndicator(.hidden)
            #endif
            .fixedSize()
            .tip("Earlier chats")
            IconButton("square.and.pencil", help: "New chat") {
                model.newAskChat()
                pending = nil
                focused = true
            }
            if !inPane {
                Button("Done") { model.isAsking = false }
                    .buttonStyle(QuietButtonStyle())
            }
        }
        .padding(.leading, Space.xl)
        .padding(.trailing, Space.m)
        .frame(height: 52)
        .overlay(alignment: .bottom) { Rectangle().fill(Line.hairline).frame(height: 1) }
    }

    /// Which assistant and model answers: every ready one you've added, each with its models,
    /// switchable here. The choice is the same one as Settings → Assistant → Ask and writing.
    @ViewBuilder
    private var modelPicker: some View {
        let current = model.assistantSettings
        Menu {
            ForEach(choices, id: \.settings.provider) { choice in
                let isCurrent = choice.settings.provider == current.provider
                if choice.models.isEmpty {
                    Button { model.useAssistant(choice.settings.provider, model: nil) } label: {
                        Label { Text(verbatim: choice.settings.provider.shortName + (isCurrent ? "  ✓" : "")) } icon: { icon(choice.settings.provider) }
                    }
                } else {
                    Section(choice.settings.provider.shortName + " · " + AssistantRow.connection(choice.settings)) {
                        ForEach(choice.models) { option in
                            Button { model.useAssistant(choice.settings.provider, model: option.id) } label: {
                                let title = option.detail.isEmpty ? option.name : "\(option.name) · \(option.detail)"
                                Label { Text(verbatim: title + (isCurrent && option.id == current.model ? "  ✓" : "")) } icon: {
                                    icon(choice.settings.provider)
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                ProviderIcon(provider: current.provider, size: 16)
                Text(verbatim: AssistantRow.label(current)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: Look.size(8), weight: .semibold))
            }
            .font(TypeScale.label).foregroundStyle(Ink.tertiary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        #if os(macOS)
        .menuIndicator(.hidden)
        #endif
        .fixedSize()
        .help(Text("Which assistant and model answers"))
        .task(id: model.assistantSettings) { choices = await model.askChoices() }
    }

    /// An assistant's icon in the menu: its app's own where it's installed.
    private func icon(_ provider: AssistantProvider) -> Image {
        #if os(macOS)
        ProviderIcon.menuIcon(provider)
        #else
        Image(systemName: AssistantRow.symbol(provider))
        #endif
    }

    /// A fresh chat: what Ask is for, and a few questions to start with.
    private var empty: some View {
        VStack(spacing: Space.l) {
            Image(systemName: "sparkles")
                .font(.system(size: Look.size(26), weight: .light))
                .foregroundStyle(Ink.tertiary)
                .padding(.top, 60)
            VStack(spacing: 6) {
                Text("Ask about your mail").font(.system(size: Look.size(22), weight: .semibold)).foregroundStyle(Ink.primary)
                Text("Your meetings, bills and conversations, answered from what's on this device.")
                    .font(TypeScale.row).foregroundStyle(Ink.secondary).multilineTextAlignment(.center)
            }
            VStack(spacing: Space.s) {
                ForEach(model.askPreferences.showsSuggestions ? starters : [], id: \.self) { text in
                    Button { send(text) } label: {
                        HStack {
                            Text(verbatim: text).font(TypeScale.row).foregroundStyle(Ink.primary)
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.system(size: Look.size(10), weight: .semibold)).foregroundStyle(Ink.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: Look.gap(40))
                        .background(Fill.one, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 420)
            Text("Type / for commands.").font(TypeScale.label).foregroundStyle(Ink.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private var starters: [String] {
        [String(localized: "What needs a reply from me?"), String(localized: "What's on my calendar this week?"),
         String(localized: "Any bills I still need to pay?"), String(localized: "What did I miss today?")]
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
                        .frame(height: Look.gap(32))
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
        HStack(alignment: .bottom, spacing: Space.s) {
            Button { attaching = true } label: {
                Image(systemName: "paperclip").font(.system(size: Look.size(13))).foregroundStyle(Ink.tertiary).frame(width: 26, height: 30)
            }
            .buttonStyle(.plain).accessibilityLabel("Attach a picture or PDF")
            TextField("Ask about your mail…", text: $question, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: Look.size(15)))
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit(submit)
                .padding(.vertical, 6)
            Button { dictation.toggle { question = $0 } } label: {
                Image(systemName: dictation.isListening ? "mic.fill" : "mic")
                    .font(.system(size: Look.size(13)))
                    .foregroundStyle(dictation.isListening ? Status.danger : Ink.tertiary)
                    .frame(width: 26, height: 30)
            }
            .buttonStyle(.plain).accessibilityLabel(dictation.isListening ? "Stop dictating" : "Dictate")
            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: Look.size(13), weight: .bold))
                    .foregroundStyle(Ink.inverse)
                    .frame(width: 30, height: 30)
                    .background(canSend ? Ink.primary : Ink.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel("Ask")
        }
        .padding(.leading, Space.s)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Paper.sheet, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(focused ? Ink.tertiary.opacity(0.6) : Line.edge))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
        .padding(.horizontal, Space.l)
        .padding(.bottom, Space.l)
        .padding(.top, Space.s)
    }

    private var canSend: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.isWorking("ask")
    }

    private func submit() {
        guard canSend else { return }
        dictation.stop()
        let text = question
        question = ""
        send(text)
    }

    private func send(_ text: String) {
        if !text.hasPrefix("/") { pending = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        model.send(askInput: text)
    }
}

/// One question and its answer, the mail it came from, and what to do with that mail.
private struct TurnView: View {
    let model: MailModel
    let turn: AskTurn

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            QuestionBubble(text: turn.question)
            if turn.isError {
                Label(turn.answer, systemImage: "exclamationmark.triangle")
                    .font(TypeScale.row)
                    .foregroundStyle(Status.danger)
            } else {
                AnswerText(text: turn.answer)
                    .textSelection(.enabled)
            }
            if !turn.sources.isEmpty { sources }
        }
    }

    /// The conversations the answer used, as small cards; acting on them is in their menu.
    private var sources: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("From your mail").font(TypeScale.label.weight(.medium)).foregroundStyle(Ink.tertiary)
                Spacer()
                Menu {
                    Button(turn.sources.count == 1 ? String(localized: "Archive it") : String(localized: "Archive these \(turn.sources.count)")) {
                        model.archive(turn.sources)
                    }
                    Button("Mark read") { model.markRead(turn.sources) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: Look.size(11), weight: .semibold)).foregroundStyle(Ink.tertiary)
                        .frame(width: 24, height: 20)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                #if os(macOS)
                .menuIndicator(.hidden)
                #endif
                .fixedSize()
                .tip("Act on these conversations")
            }
            ForEach(Array(turn.sources.enumerated()), id: \.offset) { _, source in
                let thread = source.thread
                Button { model.showSources(turn.sources.map(\.thread), selecting: thread) } label: {
                    HStack(spacing: 10) {
                        Avatar(thread.latest.from, size: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: thread.latest.from.displayName).font(TypeScale.label.weight(.semibold)).foregroundStyle(Ink.primary).lineLimit(1)
                            Text(verbatim: thread.subject.isEmpty ? String(localized: "(No subject)") : thread.subject)
                                .font(TypeScale.label).foregroundStyle(Ink.secondary).lineLimit(1)
                        }
                        Spacer(minLength: Space.s)
                        Text(RowDate.string(thread.date)).font(TypeScale.label.monospacedDigit()).foregroundStyle(Ink.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Fill.one, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 2)
    }

    /// Answers may use light Markdown (bold, lists); shown as plain text when they don't.
    static func formatted(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// What you asked, on the right, like a sent message.
private struct QuestionBubble: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: Look.size(15)))
            .foregroundStyle(Ink.inverse)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Ink.primary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .frame(maxWidth: 480, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .textSelection(.enabled)
    }
}

/// What's happening while a question is answered: a quiet line with dots while searching
/// and reading, then the answer itself as it's written.
private struct AskProgressView: View {
    let progress: AskProgress?

    var body: some View {
        switch progress {
        case .writing(let text) where !text.isEmpty:
            AnswerText(text: text)
                .frame(maxWidth: .infinity, alignment: .leading)
        default:
            HStack(spacing: Space.s) {
                ThinkingDots()
                Text(status)
                    .font(TypeScale.row)
                    .foregroundStyle(Ink.tertiary)
                    .contentTransition(.opacity)
            }
            .animation(Motion.quick, value: status)
        }
    }

    private var status: String {
        switch progress {
        case .searching, nil: String(localized: "Searching your mail…")
        case .reading(let count): count == 0 ? String(localized: "Thinking…")
            : count == 1 ? String(localized: "Reading 1 conversation…") : String(localized: "Reading \(count) conversations…")
        case .writing: String(localized: "Writing…")
        }
    }
}

/// An answer's Markdown as paragraphs and bullet rows: the bullet hangs, so wrapped lines
/// stay in line with the text, and **bold** and links work inside each line.
struct AnswerText: View {
    let text: String

    enum Block: Equatable {
        case paragraph(String)
        case bullet(String)
    }

    /// Lines starting with "- ", "* ", "• " or "1. " are bullets; other lines run together
    /// into paragraphs, which blank lines separate.
    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if let marker = ["- ", "* ", "• "].first(where: line.hasPrefix) {
                flush()
                blocks.append(.bullet(String(line.dropFirst(marker.count))))
            } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), (1...2).contains(line[..<dot].count),
                      line[line.index(after: dot)...].hasPrefix(" ") {
                flush()
                blocks.append(.bullet(String(line[line.index(dot, offsetBy: 2)...])))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let line):
                    styled(line)
                case .bullet(let line):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(Ink.tertiary).frame(width: 4, height: 4)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                        styled(line)
                    }
                    .padding(.leading, 2)
                }
            }
        }
    }

    private func styled(_ line: String) -> some View {
        Text(TurnView.formatted(line))
            .font(.system(size: Look.size(15)))
            .lineSpacing(3)
            .foregroundStyle(Ink.primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Three dots that breathe while the answer is being written; still when motion is reduced.
private struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: Look.reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Ink.tertiary)
                        .frame(width: 7, height: 7)
                        .opacity(Look.reduceMotion ? 0.6 : 0.3 + 0.7 * max(0, sin(t * 4 - Double(index) * 0.7)))
                }
            }
            .padding(.vertical, 6)
            .accessibilityLabel(Text("Reading your mail…"))
        }
    }
}
