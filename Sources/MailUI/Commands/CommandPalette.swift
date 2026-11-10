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
        let matches = all.filter { Self.matches($0.title.lowercased(), trimmed) }
        let search = MailCommand(id: "searchFor", title: "Search mail for “\(query)”", symbol: "magnifyingglass", keys: ["↩"], needsThread: false) { [query] model in
            model.searchText = query
        }
        return matches + [search]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.s) {
                Image(systemName: "command").font(.system(size: 13)).foregroundStyle(Ink.tertiary)
                TextField("Type a command or search…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
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
                .font(.system(size: 12.5))
                .foregroundStyle(isHighlighted ? Ink.primary : Ink.tertiary)
                .frame(width: 18)
            Text(command.title)
                .font(TypeScale.row)
                .foregroundStyle(isHighlighted ? Ink.primary : Ink.secondary)
            Spacer()
            if !command.keys.isEmpty { KeyCap(keys: command.keys) }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
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

    /// Letters in order, so "mkd" finds "Mark done".
    static func matches(_ text: String, _ query: String) -> Bool {
        if text.contains(query) { return true }
        var remaining = query[...]
        for char in text where char == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
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
            .frame(height: 44)
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
        .frame(height: 28)
    }
}
