import MailCore
import SwiftUI

/// ⌘K: type to find any command, or search mail with what you typed.
struct CommandPalette: View {
    @Bindable var model: MailModel
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var commands: [MailCommand] {
        let all = MailCommand.all(for: model).filter { !$0.needsThread || model.selectedThread != nil }
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return all }
        // Best fit first: the title's start, then a word's start, then anywhere, then initials.
        let matches = all.enumerated()
            .compactMap { index, command in Self.score(command.title, trimmed).map { (command, $0, index) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
            .map(\.0)
        let search = MailCommand(id: "searchFor", title: "Search mail for “\(query)”", symbol: "magnifyingglass", keys: ["↩"], needsThread: false) { [query] model in
            model.searchText = query
        }
        // What's typed can also be something for the assistant to do ("archive last week's newsletters").
        guard model.isAssistantOn else { return matches + [search] }
        let (request, asked) = Self.agentRequest(query)
        guard !request.isEmpty else { return matches + [search] }
        let agent = MailCommand(id: "askAgent", title: "Ask Margin to “\(request)”", symbol: "sparkles", keys: [], needsThread: false) { model in
            model.askAgent(request)
        }
        return asked ? [agent] + matches + [search] : matches + [search, agent]
    }

    /// What the palette starts with for “Ask Margin to…”.
    static var agentPrefix: String {
        String(localized: "Ask Margin to ", comment: "Command palette text before a request for the assistant; keep the trailing space")
    }

    /// The request in what was typed, and whether it began with “Ask Margin to”.
    static func agentRequest(_ query: String) -> (request: String, asked: Bool) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let prefix = agentPrefix.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix(prefix.lowercased()) {
            return (String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces), true)
        }
        return (trimmed, false)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.s) {
                Image(systemName: "command").font(.system(size: Look.size(13))).foregroundStyle(Ink.tertiary)
                TextField("Type a command or search…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: Look.size(15)))
                    .focused($focused)
                    .onSubmit(runHighlighted)
            }
            .padding(.horizontal, Space.l)
            .frame(height: 50)
            Rectangle().fill(Line.hairline).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                            row(command, isHighlighted: index == highlighted)
                                .id(index)
                                .onTapGesture { run(command) }
                                .onHover { if $0 { highlighted = index } }
                        }
                    }
                    .padding(Space.s)
                }
                .frame(maxHeight: 340)
                .onChange(of: highlighted) { _, index in proxy.scrollTo(index) }
            }
        }
        .frame(width: 560)
        .background(Paper.popover, in: RoundedRectangle(cornerRadius: Radius.surface, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.surface, style: .continuous).strokeBorder(Line.edge))
        .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
        .onAppear {
            focused = true
            if !model.paletteSeed.isEmpty { query = model.paletteSeed; model.paletteSeed = "" }
        }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, commands.count - 1); return .handled }
        .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
    }

    private func row(_ command: MailCommand, isHighlighted: Bool) -> some View {
        HStack(spacing: Space.m) {
            Image(systemName: command.symbol)
                .font(.system(size: Look.size(12.5)))
                .foregroundStyle(isHighlighted ? Ink.primary : Ink.tertiary)
                .frame(width: 18)
            Text(command.title)
                .font(TypeScale.row)
                .foregroundStyle(isHighlighted ? Ink.primary : Ink.secondary)
            Spacer()
            if !command.keys.isEmpty { KeyCap(keys: command.keys) }
        }
        .padding(.horizontal, 10)
        .frame(height: Look.gap(34))
        .background(isHighlighted ? Fill.two : .clear, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .contentShape(Rectangle())
    }

    private func runHighlighted() {
        let list = commands
        guard list.indices.contains(highlighted) else { return }
        run(list[highlighted])
    }

    private func run(_ command: MailCommand) {
        close()
        command.run(model)
    }

    private func close() {
        model.isPaletteOpen = false
        model.focusRequest += 1
    }

    static func matches(_ text: String, _ query: String) -> Bool { score(text, query) != nil }

    /// How well a title fits what's typed, higher is better; nil when it doesn't. The start of
    /// the title, the start of a word, every typed word starting a word, anywhere in it, the
    /// words' initials ("md" for Mark done), and last letters in order close together ("mkd").
    /// Letters scattered across a long title don't count: they matched nearly everything.
    static func score(_ title: String, _ typed: String) -> Int? {
        let text = title.lowercased()
        let query = typed.lowercased().trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return 0 }
        if text == query { return 1000 }
        if text.hasPrefix(query) { return 900 }
        let words = text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if let index = words.firstIndex(where: { $0.hasPrefix(query) }) { return 800 - min(index, 50) }
        let parts = query.split(separator: " ").map(String.init)
        if parts.count > 1, parts.allSatisfy({ part in words.contains { $0.hasPrefix(part) } }) { return 700 }
        if query.count >= 3, text.contains(query) { return 600 }
        if query.count >= 2, !query.contains(" "), String(words.compactMap(\.first)).hasPrefix(query) { return 500 }
        // Letters in order, starting a word and close together.
        guard query.count >= 3, !query.contains(" ") else { return nil }
        let characters = Array(text)
        for start in characters.indices where characters[start] == query.first && (start == 0 || !characters[start - 1].isLetter) {
            var remaining = query.dropFirst()[...]
            var end = start
            while let next = remaining.first, end + 1 < characters.count, end - start < query.count + 4 {
                end += 1
                if characters[end] == next { remaining = remaining.dropFirst() }
            }
            if remaining.isEmpty { return 300 }
        }
        return nil
    }
}

struct ShortcutsView: View {
    let model: MailModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard shortcuts").font(TypeScale.heading).foregroundStyle(Ink.primary)
                Spacer()
                CloseKeyCap { model.isShowingShortcuts = false }
            }
            .padding(.horizontal, Space.l)
            .frame(height: Look.gap(44))
            Rectangle().fill(Line.hairline).frame(height: 1)
            ScrollView {
                VStack(spacing: 2) {
                    row(String(localized: "Command palette"), ["⌘", "K"])
                    ForEach(MailCommand.all(for: model).filter { !$0.keys.isEmpty }) { command in
                        row(command.title, command.keys)
                    }
                }
                .padding(Space.l)
            }
        }
        .frame(width: 420, height: 520)
        .background(Paper.popover)
    }

    private func row(_ title: String, _ keys: [String]) -> some View {
        HStack {
            Text(title).font(TypeScale.row).foregroundStyle(Ink.secondary)
            Spacer()
            KeyCap(keys: keys)
        }
        .frame(height: Look.gap(28))
    }
}
