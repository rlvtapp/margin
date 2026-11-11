import MailCore
import SwiftUI

/// Quiet actions under the subject: summarize, suggest labels. Hidden when the assistant is off.
struct ReaderAssistantActions: View {
    let model: MailModel
    let thread: MailThread

    var body: some View {
        if model.isAssistantOn {
            HStack(spacing: Space.l) {
                TextAction(
                    title: model.isWorking("summary", on: thread) ? "Summarizing…" : "Summarize",
                    symbol: "text.alignleft", key: "M", isBusy: model.isWorking("summary", on: thread)
                ) { model.summarizeSelected() }
                TextAction(
                    title: model.isWorking("labels", on: thread) ? "Finding labels…" : "Suggest labels",
                    symbol: "tag", key: "L", isBusy: model.isWorking("labels", on: thread)
                ) { model.suggestLabelsForSelected() }
            }
        }
    }
}

/// A short read of the conversation, with who wrote it.
struct SummaryBlock: View {
    let summary: ThreadSummary
    let attribution: String
    let onClose: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Summary").font(TypeScale.label.weight(.medium)).foregroundStyle(Ink.tertiary)
                Text(attribution).font(TypeScale.label).foregroundStyle(Ink.quaternary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Ink.tertiary)
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1 : 0)
                .tip("Hide summary")
            }
            Text(summary.headline)
                .font(TypeScale.body.weight(.medium))
                .foregroundStyle(Ink.primary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(summary.points, id: \.self) { point in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(Ink.quaternary).frame(width: 4, height: 4).offset(y: -3)
                    Text(point).font(TypeScale.row).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let action = summary.action {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("To do").font(TypeScale.label.weight(.medium)).foregroundStyle(Palette.accent)
                    Text(action).font(TypeScale.row).foregroundStyle(Ink.primary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }
        }
        .textSelection(.enabled)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Fill.one, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { isHovered = $0 }
    }
}

/// The conversation's labels, then suggestions to accept with one click, then "+".
struct LabelRow: View {
    let model: MailModel
    let thread: MailThread
    @State private var isAdding = false
    @State private var newLabel = ""

    var body: some View {
        let labels = model.labels(for: thread)
        let suggestions = model.labelSuggestions[thread.id] ?? []
        if !labels.isEmpty || !suggestions.isEmpty || isAdding {
            FlowRow(spacing: 6) {
                ForEach(labels, id: \.self) { label in
                    LabelChip(text: label, style: .applied) { model.removeLabel(label, from: thread) }
                }
                ForEach(suggestions, id: \.self) { label in
                    LabelChip(text: label, style: .suggested) { model.addLabel(label, to: thread) }
                }
                if isAdding {
                    TextField("Label", text: $newLabel)
                        .textFieldStyle(.plain)
                        .font(TypeScale.label)
                        .frame(width: 110, height: 22)
                        .padding(.horizontal, 8)
                        .background(Fill.one, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .onSubmit {
                            model.addLabel(newLabel, to: thread)
                            newLabel = ""
                            isAdding = false
                        }
                        .onKeyPress(.escape) { isAdding = false; return .handled }
                } else {
                    Button { isAdding = true } label: {
                        Image(systemName: "plus").font(.system(size: 9, weight: .semibold)).foregroundStyle(Ink.tertiary)
                            .frame(width: 22, height: 22)
                            .background(Fill.one, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .tip("Add a label")
                }
            }
        }
    }
}

struct LabelChip: View {
    enum Style { case applied, suggested, compact }
    let text: String
    let style: Style
    var action: () -> Void = {}
    @State private var isHovered = false

    var body: some View {
        if style == .compact {
            // Not a button: a disabled one is drawn dimmed, which made the name hard to read.
            chip.tip(Text(verbatim: text))
        } else {
            Button(action: action) { chip }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
                .tip(style == .suggested ? Text("Add this label") : Text("Remove this label"))
        }
    }

    private var chip: some View {
        HStack(spacing: 4) {
            if style == .suggested { Image(systemName: "plus").font(.system(size: 8, weight: .bold)) }
            Text(text).lineLimit(1)
            if style == .applied && isHovered { Image(systemName: "xmark").font(.system(size: 7, weight: .bold)) }
        }
        .font(style == .compact ? TypeScale.caption : TypeScale.label)
        // A label wears its colour: tinted ground, text in a deeper shade of it (AA).
        .foregroundStyle(style == .suggested ? Ink.tertiary : GroupStyle.textColor(text))
        .padding(.horizontal, style == .compact ? 5 : 8)
        .frame(height: style == .compact ? 17 : 22)
        .background(style == .suggested ? Color.clear : GroupStyle.color(text).opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            if style == .suggested {
                RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Line.edge, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
    }
}

/// Draft, Shorter, Friendlier, More formal: above the reply's Send row.
struct ReplyAssistantBar: View {
    let model: MailModel
    let hasText: Bool

    var body: some View {
        if model.isAssistantOn {
            HStack(spacing: Space.m) {
                if model.isWorking("reply") {
                    ProgressView().controlSize(.small)
                    Text("Writing \(model.assistantAttribution)…").font(TypeScale.label).foregroundStyle(Ink.tertiary)
                } else {
                    TextAction(title: hasText ? "Write from my note" : "Draft a reply", symbol: "pencil.line", key: "⌘J") {
                        model.writeReply(.draft(note: nil))
                    }
                    if hasText {
                        TextAction(title: "Shorter", symbol: nil, key: nil) { model.writeReply(.shorter) }
                        TextAction(title: "Friendlier", symbol: nil, key: nil) { model.writeReply(.friendlier) }
                        TextAction(title: "More formal", symbol: nil, key: nil) { model.writeReply(.moreFormal) }
                    }
                }
                Spacer()
            }
            .frame(height: 22)
        }
    }
}

/// A small text button with an optional icon and shortcut hint.
struct TextAction: View {
    let title: String
    let symbol: String?
    let key: String?
    var isBusy = false
    let action: () -> Void
    @State private var isHovered = false

    init(title: String.LocalizationValue, symbol: String?, key: String?, isBusy: Bool = false, action: @escaping () -> Void) {
        self.title = String(localized: title)
        self.symbol = symbol
        self.key = key
        self.isBusy = isBusy
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isBusy {
                    ProgressView().controlSize(.mini)
                } else if let symbol {
                    Image(systemName: symbol).font(.system(size: 10.5))
                }
                Text(title)
            }
            .font(TypeScale.label.weight(.medium))
            .foregroundStyle(isHovered ? Ink.primary : Ink.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .onHover { isHovered = $0 }
        .tip(key.map { "\(title)  \($0)" } ?? title) // title is already translated; the key is a glyph
    }
}

/// Lays chips out left to right and wraps.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(widest, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
