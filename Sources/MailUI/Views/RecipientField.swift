import MailCore
import SwiftUI

/// What one recipient field (To, Cc or Bcc) is holding: the people already in it, what's being
/// typed, and the suggestions for that. The field and the list of suggestions under it share one.
@MainActor @Observable
final class RecipientInput {
    var recipients: [EmailAddress] = []
    var pending = ""
    /// A badge picked out by Backspace or a click; the next Backspace removes it.
    var selected: Int?
    /// Which suggestion the arrow keys are on.
    var highlighted = 0
    /// Esc puts the suggestions away until more is typed.
    var dismissed = false
    var isFocused = false
    /// Colleagues found in the work directory for what's typed.
    var directory: [EmailAddress] = []
    /// Raised to give the field the keyboard.
    var focusRequest = 0

    /// The line as the composer stores it.
    var text: String { RecipientList.text(recipients, pending: pending) }

    func load(_ text: String) {
        let line = RecipientList.parse(text)
        recipients = line.recipients
        pending = line.pending
        selected = nil
    }

    /// People matching what's being typed: known addresses first, then the directory.
    func matches(in model: MailModel) -> [EmailAddress] {
        let typed = pending.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return [] }
        let already = Set(recipients.map { $0.address.lowercased() })
        let known = model.addressBook.suggestions(for: typed, excluding: already, limit: 6)
        let knownAddresses = Set(known.map { $0.address.lowercased() })
        let fromDirectory = typed.count >= 2
            ? directory.filter { !already.contains($0.address.lowercased()) && !knownAddresses.contains($0.address.lowercased()) }
            : []
        return Array((known + fromDirectory).prefix(8))
    }

    func add(_ person: EmailAddress) {
        recipients = RecipientList.adding([person], to: recipients)
        pending = ""
        highlighted = 0
        selected = nil
    }

    func remove(at index: Int) {
        guard recipients.indices.contains(index) else { return }
        recipients.remove(at: index)
        selected = nil
    }

    /// Turns finished addresses in what's typed into recipients. `force` also takes the last one.
    func commit(force: Bool = false) {
        let result = RecipientList.commit(pending, force: force)
        if !result.added.isEmpty { recipients = RecipientList.adding(result.added, to: recipients) }
        if result.pending != pending { pending = result.pending }
    }
}

/// A To, Cc or Bcc field: each person a badge, with room to type the next. A comma, a space
/// after an address, Return or Tab finishes one. The arrow keys move through the suggestions
/// (`RecipientMatches`, shown under the row) and Return or Tab takes the highlighted one.
/// Backspace in an empty field picks out the last badge, and again removes it.
struct RecipientField: View {
    let model: MailModel
    @Bindable var input: RecipientInput
    /// The line in the composer's state, kept as header text.
    @Binding var text: String
    /// Take the keyboard when the field appears.
    var autofocus = false

    var body: some View {
        // One arrangement whether or not anyone's in it yet, so the text field stays the same
        // view (and keeps the keyboard) when the first person is added.
        RecipientFlow {
            ForEach(Array(input.recipients.enumerated()), id: \.element.address) { index, person in
                RecipientBadge(person: person, isSelected: input.selected == index) {
                    input.remove(at: index)
                } select: {
                    input.selected = input.selected == index ? nil : index
                    input.focusRequest += 1
                }
            }
            typing
        }
        .padding(.vertical, input.recipients.isEmpty ? 0 : 6)
        .contentShape(Rectangle())
        .onTapGesture { input.focusRequest += 1 }
        .onAppear {
            if text != input.text { input.load(text) }
            if autofocus { input.focusRequest += 1 }
        }
        // Changed from outside (a template, a reply set up, a mailto link): read it in again.
        .onChange(of: text) { _, new in if new != input.text { input.load(new) } }
        .onChange(of: input.text) { _, new in if text != new { text = new } }
        .onChange(of: input.pending) { _, _ in
            input.commit()
            input.highlighted = 0
            input.dismissed = false
            if !input.pending.isEmpty { input.selected = nil }
        }
        .onChange(of: input.isFocused) { _, now in
            if !now {
                input.commit(force: true)
                input.selected = nil
            }
        }
        .task(id: input.pending) {
            let typed = input.pending.trimmingCharacters(in: .whitespaces)
            guard typed.count >= 2 else { input.directory = []; return }
            // Wait for a pause in typing before asking the directory.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = await model.searchDirectories(typed)
            if !Task.isCancelled { input.directory = found }
        }
    }

    private var matches: [EmailAddress] { input.dismissed ? [] : input.matches(in: model) }

    /// Backspace with nothing typed: picks out the last person, and the next one removes them.
    private func backspaceOnEmpty() -> Bool {
        guard input.pending.isEmpty, !input.recipients.isEmpty else { return false }
        if let selected = input.selected {
            input.remove(at: selected)
        } else {
            input.selected = input.recipients.count - 1
        }
        return true
    }

    private var typing: some View {
        RecipientTextInput(input: input) { key in
            switch key {
            case .backspace:
                return backspaceOnEmpty()
            case .down:
                return move(1)
            case .up:
                return move(-1)
            case .enter:
                take()
                return true
            case .tab:
                // Tab takes the highlighted person; with nothing to take it moves on as usual.
                guard !matches.isEmpty else { input.commit(force: true); return false }
                take()
                return true
            case .escape:
                guard !matches.isEmpty else { return false }
                input.dismissed = true
                return true
            }
        }
        .frame(height: Look.gap(24))
    }

    private func move(_ step: Int) -> Bool {
        let count = matches.count
        guard count > 0 else { return false }
        input.highlighted = min(max(input.highlighted + step, 0), count - 1)
        return true
    }

    /// The highlighted suggestion if there is one, otherwise the address as typed.
    private func take() {
        let found = matches
        if found.indices.contains(input.highlighted) {
            input.add(found[input.highlighted])
        } else {
            input.commit(force: true)
        }
    }
}

/// Badges in rows, wrapping, with the last view (where the next person is typed) taking what's
/// left of its row, or a row of its own when too little is left.
private struct RecipientFlow: Layout {
    var spacing: CGFloat = 5
    var rowHeight: CGFloat = 24
    /// The least room worth typing in.
    var minimumInput: CGFloat = 110

    private func frames(in width: CGFloat, subviews: Subviews) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0
        for (index, view) in subviews.enumerated() {
            if index == subviews.count - 1 {
                if x > 0, width - x < minimumInput { x = 0; y += rowHeight + spacing }
                frames.append(CGRect(x: x, y: y, width: max(width - x, 0), height: rowHeight))
            } else {
                let size = view.sizeThatFits(.unspecified)
                let fitted = min(size.width, width)
                if x > 0, x + fitted > width { x = 0; y += rowHeight + spacing }
                frames.append(CGRect(x: x, y: y, width: fitted, height: rowHeight))
                x += fitted + spacing
            }
        }
        return frames
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let last = frames(in: width, subviews: subviews).last
        return CGSize(width: width, height: (last?.maxY ?? rowHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, frames(in: bounds.width, subviews: subviews)) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.midY), anchor: .leading,
                       proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}

/// The keys a recipient field acts on beyond plain typing.
enum RecipientKey { case backspace, down, up, enter, tab, escape }

#if os(macOS)
/// Where the next recipient is typed: the system's own text field, so Backspace, the arrow
/// keys, Return, Tab and Esc arrive as commands the field can act on. (SwiftUI's text field keeps
/// those to itself, and doesn't say when Backspace is pressed with nothing typed.)
private struct RecipientTextInput: NSViewRepresentable {
    @Bindable var input: RecipientInput
    /// Returns whether the key was used; one that wasn't does what it normally does.
    let onKey: (RecipientKey) -> Bool

    final class Field: NSTextField {
        var onFocus: () -> Void = {}

        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became { onFocus() }
            return became
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(input: input) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = NSColor(Ink.primary)
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.onFocus = { [input] in input.isFocused = true }
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.onKey = onKey
        if field.stringValue != input.pending { field.stringValue = input.pending }
        if context.coordinator.focusSeen != input.focusRequest {
            context.coordinator.focusSeen = input.focusRequest
            // Once the view is in its window.
            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window, field.currentEditor() == nil else { return }
                window.makeFirstResponder(field)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let input: RecipientInput
        var onKey: (RecipientKey) -> Bool = { _ in false }
        var focusSeen = 0

        init(input: RecipientInput) { self.input = input }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if input.pending != field.stringValue { input.pending = field.stringValue }
            // A finished address becomes a badge at once, and the field shows what's left.
            input.commit()
            if field.stringValue != input.pending { field.stringValue = input.pending }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            input.isFocused = false
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let used = switch selector {
            case #selector(NSResponder.deleteBackward(_:)): textView.string.isEmpty ? onKey(.backspace) : false
            case #selector(NSResponder.moveDown(_:)): onKey(.down)
            case #selector(NSResponder.moveUp(_:)): onKey(.up)
            case #selector(NSResponder.insertNewline(_:)): onKey(.enter)
            case #selector(NSResponder.insertTab(_:)): onKey(.tab)
            case #selector(NSResponder.cancelOperation(_:)): onKey(.escape)
            default: false
            }
            // Taking someone empties what was typed.
            if textView.string != input.pending { textView.string = input.pending }
            return used
        }
    }
}
#else
/// Where the next recipient is typed: the system's own text field, which says when Backspace is
/// pressed with nothing typed (the on-screen keyboard has no key presses to listen for).
private struct RecipientTextInput: UIViewRepresentable {
    @Bindable var input: RecipientInput
    let onKey: (RecipientKey) -> Bool

    final class Field: UITextField {
        var onBackspaceWhenEmpty: () -> Void = {}

        override func deleteBackward() {
            if (text ?? "").isEmpty { onBackspaceWhenEmpty() }
            super.deleteBackward()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(input: input) }

    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.font = .systemFont(ofSize: 15)
        field.textColor = UIColor(Ink.primary)
        field.keyboardType = .emailAddress
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.returnKeyType = .next
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: Field, context: Context) {
        context.coordinator.onKey = onKey
        field.onBackspaceWhenEmpty = { [coordinator = context.coordinator] in _ = coordinator.onKey(.backspace) }
        if field.text != input.pending { field.text = input.pending }
        if context.coordinator.focusSeen != input.focusRequest {
            context.coordinator.focusSeen = input.focusRequest
            DispatchQueue.main.async { [weak field] in field?.becomeFirstResponder() }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        let input: RecipientInput
        var onKey: (RecipientKey) -> Bool = { _ in false }
        var focusSeen = 0

        init(input: RecipientInput) { self.input = input }

        @objc func changed(_ field: UITextField) {
            let text = field.text ?? ""
            if input.pending != text { input.pending = text }
            input.commit()
            if field.text != input.pending { field.text = input.pending }
        }

        func textFieldDidBeginEditing(_ field: UITextField) { input.isFocused = true }
        func textFieldDidEndEditing(_ field: UITextField) { input.isFocused = false }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            _ = onKey(.enter)
            if field.text != input.pending { field.text = input.pending }
            return false
        }
    }
}
#endif

/// One person in a recipient field: their picture and name, the address on hover, and a small
/// cross to take them out.
private struct RecipientBadge: View {
    let person: EmailAddress
    let isSelected: Bool
    let remove: () -> Void
    let select: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 5) {
            Avatar(person, size: 16)
            Text(verbatim: person.displayName)
                .font(TypeScale.label.weight(.medium))
                .foregroundStyle(isSelected ? Paper.panel : Ink.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: Look.size(7.5), weight: .bold))
                    .foregroundStyle(isSelected ? Paper.panel : Ink.tertiary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Remove"))
            #if os(macOS)
            // Always there, so the badge keeps its width; seen when pointed at or picked out.
            .opacity(hovered || isSelected ? 1 : 0.45)
            #endif
        }
        .padding(.leading, 4)
        .padding(.trailing, 4)
        .frame(height: Look.gap(24))
        .frame(maxWidth: 260)
        .background(isSelected ? Ink.primary : Fill.one, in: Capsule())
        .contentShape(Capsule())
        .onTapGesture(perform: select)
        .onHover { hovered = $0 }
        .tip(person.address)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: person.name.map { "\($0), \(person.address)" } ?? person.address))
    }
}

/// Under a recipient row: the people matching what's being typed in it. The arrow keys move the
/// highlight; a click, Return or Tab takes one.
struct RecipientMatches: View {
    let model: MailModel
    @Bindable var input: RecipientInput

    var body: some View {
        let matches = input.isFocused && !input.dismissed ? input.matches(in: model) : []
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(matches.enumerated()), id: \.element.address) { index, person in
                    Button { input.add(person) } label: {
                        HStack(spacing: Space.s) {
                            Avatar(person, size: 22)
                            Text(verbatim: person.displayName).font(TypeScale.rowStrong).foregroundStyle(Ink.primary)
                            Text(verbatim: person.address).font(TypeScale.label).foregroundStyle(Ink.tertiary)
                            Spacer(minLength: 0)
                        }
                        .lineLimit(1)
                        .padding(.horizontal, Space.s)
                        .frame(height: Look.gap(34))
                        .background(index == input.highlighted ? Fill.one : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { if $0 { input.highlighted = index } }
                }
            }
            .padding(4)
            .background(Paper.popover, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Line.edge))
            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        }
    }
}
