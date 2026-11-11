import MailCore
import SwiftUI
import UniformTypeIdentifiers

/// The closed reply box under a conversation: one click or R opens it.
struct ReplyPrompt: View {
    let model: MailModel
    let thread: MailThread
    @State private var isHovered = false

    var body: some View {
        Button { model.startReply() } label: {
            HStack(spacing: 10) {
                if let account = model.account(thread.accountID) { Avatar(account.address, size: 20) }
                Text(replyTitle)
                    .font(TypeScale.row)
                    .foregroundStyle(Ink.tertiary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(Paper.sheet, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(isHovered ? Line.edge.opacity(1.6) : Line.edge))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    /// "Reply to Noor…": whoever wrote last, other than you.
    private var replyTitle: String {
        // Not someone who only reacted.
        let other = thread.messages.reversed().first { !model.isMine($0) && model.reaction(in: $0, of: thread) == nil }?.from
        let name = other.map { EmailAddress.firstName(of: $0) } ?? ""
        return name.isEmpty || name.contains("@") ? String(localized: "Reply…") : String(localized: "Reply to \(name)…")
    }
}

/// The open reply, inline under the conversation so the thread stays readable.
struct ReplyEditor: View {
    let model: MailModel
    @Binding var state: ComposeState
    @FocusState private var focused: Bool
    @State private var richText = RichTextController()
    @State private var toInput = RecipientInput()
    @State private var ccInput = RecipientInput()
    @State private var bccInput = RecipientInput()
    /// Cc or Bcc just opened with its button: it takes the keyboard.
    @State private var opened: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            // Who it's from, at the top where you'd check it.
            FromPicker(model: model, state: $state)
            HStack(spacing: Space.s) {
                Text("To").font(TypeScale.label).foregroundStyle(Ink.tertiary).frame(width: 26, alignment: .leading)
                RecipientField(model: model, input: toInput, text: $state.to)
                if !state.showsCc {
                    Button("Cc") { opened = "cc"; state.showsCc = true }.buttonStyle(.plain).font(TypeScale.label).foregroundStyle(Ink.tertiary)
                }
                if !state.showsBcc {
                    Button("Bcc") { opened = "bcc"; state.showsBcc = true }.buttonStyle(.plain).font(TypeScale.label).foregroundStyle(Ink.tertiary)
                }
            }
            RecipientMatches(model: model, input: toInput)
            if state.showsCc {
                HStack(spacing: Space.s) {
                    Text("Cc").font(TypeScale.label).foregroundStyle(Ink.tertiary).frame(width: 26, alignment: .leading)
                    RecipientField(model: model, input: ccInput, text: $state.cc, autofocus: opened == "cc")
                }
                RecipientMatches(model: model, input: ccInput)
            }
            if state.showsBcc {
                HStack(spacing: Space.s) {
                    Text("Bcc").font(TypeScale.label).foregroundStyle(Ink.tertiary).frame(width: 26, alignment: .leading)
                    RecipientField(model: model, input: bccInput, text: $state.bcc, autofocus: opened == "bcc")
                }
                RecipientMatches(model: model, input: bccInput)
            }
            Rectangle().fill(Line.hairline).frame(height: 1)
            // Replies use the block editor too when it's turned on (Settings → Experimental).
            if model.usesBlockComposer {
                BlockComposer(state: $state)
                    .frame(minHeight: 160)
            } else {
                RichTextEditor(text: $state.draft.text, html: $state.draft.html, controller: richText, onEscape: close)
                    .frame(minHeight: 120)
                    .focused($focused)
            }
            ComposeAttachments(state: $state)
            ReplyAssistantBar(model: model, hasText: !state.draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #if os(iOS)
            // A phone is too narrow for one row: send on the first, the rest under it.
            HStack(spacing: Space.s) {
                SendControls(model: model, state: $state, isReply: true)
                Button("Discard") { model.reply = nil }
                    .buttonStyle(.plain).font(TypeScale.label).foregroundStyle(Ink.secondary)
                Spacer(minLength: 0)
                TemplatesMenu(model: model, state: $state)
                SignatureMenu(model: model, state: $state)
                ReplyReminderMenu(state: $state)
            }
            #else
            HStack(spacing: Space.s) {
                tools
                Spacer(minLength: 0)
            }
            #endif
        }
        .padding(12)
        .background(Paper.sheet, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Line.edge))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
        .onAppear { focused = true }
        .onKeyPress(.escape) {
            close()
            return .handled
        }
        // Also while the To or Cc field has the keyboard.
        .background { CancelKey(action: close) }
        .dropDestination(for: URL.self) { urls, _ in ComposeAttachments.add(urls, to: &state) }
    }

    #if !os(iOS)
    /// Send, Discard and the writing tools, on the Mac.
    private var tools: some View {
        HStack(spacing: Space.s) {
            SendControls(model: model, state: $state, isReply: true)
            Button("Discard") { model.reply = nil; model.focusRequest += 1 }.fixedSize()
            if !model.usesBlockComposer { FormattingBar(controller: richText) }
            TemplatesMenu(model: model, state: $state)
            SignatureMenu(model: model, state: $state)
            ReplyReminderMenu(state: $state)
            Button("Draft") { model.writeReply(.draft(note: nil)) }
                .keyboardShortcut("j", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                .buttonStyle(QuietButtonStyle())
        }
        .fixedSize()
    }
    #endif

    /// Esc keeps what was written in Drafts; Discard throws it away.
    private func close() {
        model.closeComposer(state, isReply: true)
    }
}

/// A new message, in a sheet over the window: who it's from and to at the top, a large
/// subject, room to write, and one quiet bar with Send and the writing tools.
struct ComposeSheet: View {
    let model: MailModel
    @Binding var state: ComposeState
    @FocusState private var field: Field?
    @State private var richText = RichTextController()
    @State private var showsFormatting = false
    @State private var toInput = RecipientInput()
    @State private var ccInput = RecipientInput()
    @State private var bccInput = RecipientInput()
    /// Cc or Bcc just opened with its button: it takes the keyboard.
    @State private var opened: String?
    /// In the reading pane rather than a sheet: fills it, with the writing kept to a
    /// comfortable width.
    var inPane = false

    enum Field { case subject, body }

    private let inset: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The envelope: From, To and Subject as aligned lines, each with a hairline, and
            // the window's own controls on the From line.
            row {
                label("From")
                FromPicker(model: model, state: $state, showsLabel: false)
                Spacer()
                // Up into the top bar, to search or read other mail; it comes back as it was.
                Button {
                    withAnimation(Motion.quick) { model.isComposePutAway = true }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Ink.tertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .tip(Text("Put the message away to look at other mail (⇧⌘M)"))
                .accessibilityLabel(Text("Put Away"))
                CloseKeyCap { model.closeComposer(state, isReply: false) }
            }
            row {
                label("To")
                // A new message starts in To; one that already has someone starts in the text.
                RecipientField(model: model, input: toInput, text: $state.to, autofocus: state.to.isEmpty)
                if !state.showsCc {
                    Button("Cc") { opened = "cc"; state.showsCc = true }.buttonStyle(.plain).font(TypeScale.label).foregroundStyle(Ink.tertiary)
                }
                if !state.showsBcc {
                    Button("Bcc") { opened = "bcc"; state.showsBcc = true }.buttonStyle(.plain).font(TypeScale.label).foregroundStyle(Ink.tertiary)
                        .tip(Text("Hidden recipients: they get the message, nobody sees them."))
                }
            }
            RecipientMatches(model: model, input: toInput).padding(.horizontal, inset).padding(.vertical, 4)
            if state.showsCc {
                row {
                    label("Cc")
                    RecipientField(model: model, input: ccInput, text: $state.cc, autofocus: opened == "cc")
                }
                RecipientMatches(model: model, input: ccInput).padding(.horizontal, inset).padding(.vertical, 4)
            }
            if state.showsBcc {
                row {
                    label("Bcc")
                    RecipientField(model: model, input: bccInput, text: $state.bcc, autofocus: opened == "bcc")
                }
                RecipientMatches(model: model, input: bccInput).padding(.horizontal, inset).padding(.vertical, 4)
            }
            row {
                label("Subject")
                TextField("", text: $state.draft.subject).textFieldStyle(.plain).font(TypeScale.rowStrong).focused($field, equals: .subject)
            }

            Group {
                if model.usesBlockComposer {
                    BlockComposer(state: $state)
                } else {
                    RichTextEditor(text: $state.draft.text, html: $state.draft.html, controller: richText) {
                        model.closeComposer(state, isReply: false)
                    }
                    .focused($field, equals: .body)
                    .padding(.horizontal, inset - 4)
                    .padding(.top, Space.l)
                    .padding(.bottom, Space.s)
                }
            }
            .frame(maxHeight: .infinity)

            ComposeAttachments(state: $state)
                .padding(.horizontal, inset)
                .padding(.bottom, Space.s)
            if showsFormatting && !model.usesBlockComposer {
                FormattingBar(controller: richText)
                    .padding(.horizontal, inset - 6)
                    .transition(.opacity)
            }

            // Send first, the tools as quiet icons, Discard out of the way on the right.
            HStack(spacing: Space.xs) {
                SendControls(model: model, state: $state, isReply: false)
                if !model.usesBlockComposer {
                    Button { withAnimation(Motion.quick) { showsFormatting.toggle() } } label: {
                        Text(verbatim: "Aa")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(showsFormatting ? Ink.primary : Ink.tertiary)
                            .frame(width: 28, height: 28)
                            .background(showsFormatting ? Fill.two : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .tip(Text("Formatting"))
                    .accessibilityLabel(Text("Formatting"))
                }
                Group {
                    TemplatesMenu(model: model, state: $state)
                    SignatureMenu(model: model, state: $state)
                    ReplyReminderMenu(state: $state)
                }
                .labelStyle(.iconOnly)
                Spacer()
                IconButton("trash", help: "Discard") { model.compose = nil; model.focusRequest += 1 }
            }
            .padding(.leading, inset)
            .padding(.trailing, Space.m)
            .padding(.vertical, Space.m)
        }
        .frame(maxWidth: inPane ? 760 : nil)
        .frame(maxWidth: inPane ? .infinity : nil, maxHeight: inPane ? .infinity : nil)
        .frame(minWidth: inPane ? 0 : 620, idealWidth: inPane ? nil : 720, minHeight: inPane ? 0 : 500, idealHeight: inPane ? nil : 620)
        .background(inPane ? Paper.panel : Paper.popover)
        .onAppear { if !state.to.isEmpty { field = .body } }
        .background { CancelKey { model.closeComposer(state, isReply: false) } }
        .dropDestination(for: URL.self) { urls, _ in ComposeAttachments.add(urls, to: &state) }
    }

    private func label(_ text: LocalizedStringKey) -> some View {
        Text(text).font(TypeScale.label).foregroundStyle(Ink.tertiary).frame(width: 56, alignment: .leading)
    }

    /// One envelope line: at least 44 points tall (taller when its people wrap onto a second
    /// line), with a hairline under it inside the margins.
    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: Space.s) { content() }
            .padding(.leading, inset)
            .padding(.trailing, Space.m)
            .frame(minHeight: 44)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Line.hairline).frame(height: 1).padding(.leading, inset).padding(.trailing, inset)
            }
    }
}

/// Esc closes the surface it's in, on every platform, even while a text field has focus.
struct CancelKey: View {
    let action: () -> Void

    var body: some View {
        Button("Close", action: action)
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

/// The "esc" in a sheet's header, which also closes it when clicked.
struct CloseKeyCap: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) { KeyCap("esc") }
            .buttonStyle(.plain)
            .tip(Text("Close"))
            .accessibilityLabel(Text("Close"))
    }
}

extension Binding {
    /// Unwraps an optional binding like `Binding(_:)`, but once the value is cleared it keeps
    /// answering with the last one instead of crashing, so a sheet or editor that's closing can
    /// finish without reading a value that's gone. Writes after that are dropped.
    init?(keepingLast source: Binding<Value?>) {
        guard let first = source.wrappedValue else { return nil }
        let last = LastValue(first)
        self.init(
            get: {
                if let value = source.wrappedValue { last.value = value }
                return last.value
            },
            set: { value in
                if source.wrappedValue != nil { source.wrappedValue = value }
            }
        )
    }
}

private final class LastValue<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// Which mailbox a message goes out from, in that mailbox's colour.
struct FromPicker: View {
    let model: MailModel
    @Binding var state: ComposeState
    /// Off where the line already says "From" in its own column.
    var showsLabel = true

    var body: some View {
        let current = model.account(state.accountID)
        // Every address of every mailbox: a section per mailbox, its own address first.
        let choices = model.accounts.flatMap { account in account.sendAddresses.map { (account, $0) } }
        let current_ = state.draft.from.address.lowercased()
        Menu {
            ForEach(model.accounts) { account in
                Section(account.label) {
                    ForEach(Array(account.sendAddresses.enumerated()), id: \.offset) { _, address in
                        Button {
                            state.send(from: account, previous: model.account(state.accountID), as: address)
                        } label: {
                            if account.id == state.accountID && address.address.lowercased() == current_ {
                                Label(address.address, systemImage: "checkmark")
                            } else {
                                Text(verbatim: address.address)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if showsLabel { Text("From").foregroundStyle(Ink.tertiary) }
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Palette.account(current?.colorIndex ?? 0))
                    .frame(width: 8, height: 8)
                Text(state.draft.from.address).foregroundStyle(Ink.secondary)
                if choices.count > 1 {
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Ink.tertiary)
                }
            }
            .font(TypeScale.label)
            .lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(choices.count < 2)
    }
}

/// Send (with Undo), Send later, and Attach. Sending checks for a forgotten attachment.
struct SendControls: View {
    let model: MailModel
    @Binding var state: ComposeState
    let isReply: Bool
    @State private var warnsAboutAttachment = false
    @State private var picksFiles = false
    @State private var picksDate = false

    var body: some View {
        HStack(spacing: Space.s) {
            Button {
                if state.forgotAttachment { warnsAboutAttachment = true } else { model.queueSend(state, isReply: isReply) }
            } label: {
                HStack(spacing: 6) {
                    Text("Send")
                    #if os(macOS)
                    Text(verbatim: "⌘↩").opacity(0.6)
                    #endif
                }
            }
            .buttonStyle(InkButtonStyle())
            .keyboardShortcut(.return, modifiers: .command)
            // Never squeezed: the rest of the bar gives way first.
            .fixedSize()
            .layoutPriority(1)
            Menu {
                Button("Tomorrow · \(SnoozePreset.tomorrow.date().formatted(.dateTime.weekday(.abbreviated).hour().minute()))") {
                    model.schedule(state, at: SnoozePreset.tomorrow.date(), isReply: isReply)
                }
                Button("Monday · \(SnoozePreset.nextWeek.date().formatted(.dateTime.weekday(.abbreviated).hour().minute()))") {
                    model.schedule(state, at: SnoozePreset.nextWeek.date(), isReply: isReply)
                }
                Divider()
                Button("Pick a date…") { picksDate = true }
            } label: {
                Image(systemName: "clock").font(.system(size: 12)).foregroundStyle(Ink.secondary).frame(width: 26, height: 28)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .tip("Send later")
            IconButton("paperclip", help: "Attach files") { picksFiles = true }
        }
        .alert("Did you mean to attach a file?", isPresented: $warnsAboutAttachment) {
            Button("Attach a file") { picksFiles = true }
            Button("Send anyway") { model.queueSend(state, isReply: isReply) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The message mentions an attachment, but nothing is attached.")
        }
        .fileImporter(isPresented: $picksFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { ComposeAttachments.add(urls, to: &state) }
        }
        .sheet(isPresented: $picksDate) {
            DateChoiceSheet(title: "Send later", action: "Schedule") { date in model.schedule(state, at: date, isReply: isReply) }
        }
    }
}

/// Files attached to the message being written, each with a remove button.
struct ComposeAttachments: View {
    @Binding var state: ComposeState

    var body: some View {
        // Pictures shown inside the message aren't listed; they're in the text.
        let files = state.draft.attachments.filter { $0.contentID == nil }
        if !files.isEmpty {
            FlowRow(spacing: 6) {
                ForEach(files) { file in
                    HStack(spacing: 6) {
                        Image(systemName: AttachmentChip.symbol(file.mimeType)).font(.system(size: 11)).foregroundStyle(Ink.tertiary)
                        Text(file.filename).font(TypeScale.label).foregroundStyle(Ink.secondary).lineLimit(1)
                        Text(file.data.count.formatted(.byteCount(style: .file))).font(TypeScale.label).foregroundStyle(Ink.tertiary)
                        Button { state.draft.attachments.removeAll { $0.id == file.id } } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Ink.tertiary)
                        }
                        .buttonStyle(.plain)
                        .tip("Remove")
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(Fill.one, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
    }

    /// Reads chosen or dropped files (25 MB in total, the common provider limit).
    @discardableResult
    static func add(_ urls: [URL], to state: inout ComposeState) -> Bool {
        var total = state.draft.attachments.reduce(0) { $0 + $1.data.count }
        var added = false
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), total + data.count <= 25 * 1024 * 1024 else { continue }
            total += data.count
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            state.draft.attachments.append(OutgoingAttachment(filename: url.lastPathComponent, mimeType: type, data: data))
            added = true
        }
        return added
    }
}

/// Insert a saved template, filled in for the first recipient.
struct TemplatesMenu: View {
    let model: MailModel
    @Binding var state: ComposeState

    var body: some View {
        Menu {
            ForEach(model.templates) { template in
                Button(template.name) { model.insert(template, into: &state) }
            }
            if model.templates.isEmpty { Text("No templates yet") }
            Divider()
            Button("Save as template") { model.saveTemplate(from: state) }
        } label: {
            Image(systemName: "doc.on.doc").font(.system(size: 12.5)).foregroundStyle(Ink.tertiary).frame(width: 28, height: 28)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .tip("Templates")
    }
}
