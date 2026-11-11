import MailCore
import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// The open conversation: a plain page, the newest message open and earlier ones folded to
/// one line each, and the reply box at the end.
struct ReaderView: View {
    @Bindable var model: MailModel
    /// The Mac draws its own action bar; on iPhone and iPad the actions live in the navigation bar.
    var drawsToolbar = true
    /// Shown as a back arrow in the toolbar when the reader sits over something else.
    var onBack: (() -> Void)?
    @State var addsLabel = false
    @State private var newLabel = ""

    var body: some View {
        Group {
            if model.selection.count > 1 {
                BulkActionsView(model: model)
            } else if let thread = model.selectedThread {
                VStack(spacing: 0) {
                    if drawsToolbar {
                        toolbar(thread)
                        Rectangle().fill(Line.hairline).frame(height: 1)
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                header(thread)
                                if model.showsAsChat {
                                    ChatConversationView(model: model, thread: model.conversation(thread))
                                } else {
                                let conversation = model.conversation(thread)
                                // Reactions sit on the message they answer instead of as messages.
                                let layout = model.reactionLayout(conversation)
                                ForEach(Array(layout.messages.enumerated()), id: \.element.id) { index, message in
                                    if index > 0 { Rectangle().fill(Line.hairline).frame(height: 1) }
                                    MessageView(
                                        message: message,
                                        content: model.body(of: message, in: thread),
                                        startsExpanded: message.id == layout.messages.last?.id || message.isUnread,
                                        prefersPlainText: model.prefersPlainText,
                                        trustsSender: model.trustsPictures(from: message.from),
                                        onTrustSender: { model.trustPictures(from: message.from) },
                                        onMailto: { model.startCompose(mailto: $0) },
                                        textScale: model.textScale,
                                        model: model,
                                        thread: thread,
                                        reactions: layout.reactions[message.id] ?? [],
                                        attachmentActions: AttachmentActions(
                                            open: { model.openAttachment($0, of: message, in: thread) },
                                            save: { model.saveAttachment($0, of: message, in: thread) },
                                            file: { try await model.attachmentFile($0, of: message, in: thread) }
                                        )
                                    )
                                    .id(message.id)
                                }
                                }
                                if model.reply == nil, model.isAssistantOn {
                                    ReplySuggestionsRow(model: model, thread: thread)
                                        .padding(.top, Space.l)
                                }
                                Group {
                                    // On iPhone and iPad a reply opens full screen instead.
                                    if drawsToolbar, let reply = Binding(keepingLast: $model.reply) {
                                        ReplyEditor(model: model, state: reply)
                                    } else {
                                        ReplyPrompt(model: model, thread: thread)
                                    }
                                }
                                .padding(.top, Space.l)
                                .id("reply")
                            }
                            .frame(maxWidth: 780, alignment: .leading)
                            .padding(.horizontal, drawsToolbar ? 36 : 20)
                            .padding(.top, drawsToolbar ? 28 : 8)
                            .padding(.bottom, 40)
                            .frame(maxWidth: .infinity)
                        }
                        .onAppear { proxy.scrollTo(thread.latest.id, anchor: .top) }
                        .onChange(of: thread.id) { _, _ in proxy.scrollTo(thread.latest.id, anchor: .top) }
                        // Outlook's own reactions, when they're turned on for this account.
                        .task(id: thread.id) { await model.loadOutlookReactions(for: thread) }
                        .onChange(of: model.reply != nil) { _, open in
                            if open { withAnimation(Motion.quick) { proxy.scrollTo("reply", anchor: .bottom) } }
                        }
                    }
                }
            } else if drawsToolbar, model.isAssistantOn, !model.isAsking {
                // Nothing open: the pane is for asking about your mail, ready to type into.
                AskView(model: model, inPane: true)
            } else {
                ListMessage(title: model.isLoading ? "" : "No conversation selected", detail: nil, action: nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Paper.panel)
        .onScreenForSiri(model.selectedThread)
        #if os(iOS)
        .toolbar { if !drawsToolbar, let thread = model.selectedThread, model.selection.count <= 1 { touchToolbar(thread) } }
        #endif
        .alert("Add a label", isPresented: $addsLabel) {
            TextField("Label", text: $newLabel)
            Button("Cancel", role: .cancel) { newLabel = "" }
            Button("Add") {
                if let thread = model.selectedThread { model.addLabel(newLabel, to: thread) }
                newLabel = ""
            }
        }
    }

    private func toolbar(_ thread: MailThread) -> some View {
        HStack(spacing: 2) {
            if let onBack {
                IconButton("chevron.left", help: "Back") { onBack() }
            } else if model.layout.opensOverList {
                IconButton("chevron.left", help: "Back to the list  Esc") { model.isReaderOpen = false }
            }
            HStack(spacing: 6) {
                if let account = model.account(thread.accountID), model.accounts.count > 1 {
                    AccountMark(account, size: 14)
                    Text(account.label).foregroundStyle(Ink.tertiary)
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Ink.quaternary)
                }
                Text(model.split != nil ? thread.split.title : model.title).foregroundStyle(Ink.tertiary)
            }
            .font(TypeScale.row)
            .padding(.leading, Space.s)
            Spacer(minLength: Space.s)
            // With names when they fit (Settings → Appearance), otherwise icons with tooltips.
            if model.buttonNames {
                ViewThatFits(in: .horizontal) {
                    actions(thread).environment(\.toolbarLabels, true)
                    actions(thread).environment(\.toolbarLabels, false)
                }
            } else {
                actions(thread).environment(\.toolbarLabels, false)
            }
        }
        .padding(.leading, Space.s)
        .padding(.trailing, Space.m)
        .frame(height: MailLayout.topBand)
    }

    /// Three groups with room between them: handle it, organise it, write.
    private func actions(_ thread: MailThread) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                ToolbarButton("checkmark.circle", title: "Done", help: "Done  E") { model.perform(.done) }
                ToolbarButton("trash", title: "Trash", help: "Move to Trash  #") { model.perform(.trash) }
            }
            toolbarGap
            HStack(spacing: 4) {
                ToolbarButton(thread.isStarred ? "star.fill" : "star", title: thread.isStarred ? "Unstar" : "Star",
                              help: thread.isStarred ? "Remove star  S" : "Star  S") { model.toggleStar() }
                ToolbarButton(thread.isUnread ? "envelope.open" : "envelope.badge", title: thread.isUnread ? "Read" : "Unread",
                              help: thread.isUnread ? "Mark read  U" : "Mark unread  U") { model.toggleRead() }
                SnoozeMenu(model: model)
            }
            toolbarGap
            HStack(spacing: 4) {
                if model.isAssistantOn {
                    if model.isWorking("summary", on: thread) {
                        ProgressView().controlSize(.small).frame(width: 28, height: 28)
                    } else {
                        ToolbarButton("text.alignleft", title: "Summarize", help: "Summarize  M") { model.summarizeSelected() }
                    }
                }
                ToolbarButton("arrowshape.turn.up.left", title: "Reply", help: "Reply  R") { model.startReply() }
                ToolbarButton("arrowshape.turn.up.left.2", title: "Reply all", help: "Reply all  A") { model.startReply(all: true) }
                ToolbarButton("arrowshape.turn.up.right", title: "Forward", help: "Forward  F") { model.startForward() }
                ReaderMoreMenu(model: model, thread: thread, addsLabel: $addsLabel)
            }
        }
        .fixedSize()
    }

    private var toolbarGap: some View {
        Rectangle().fill(Line.hairline).frame(width: 1, height: 16).padding(.horizontal, 10)
    }

    private func header(_ thread: MailThread) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(thread.subject.isEmpty ? String(localized: "(No subject)") : thread.subject)
                .font(TypeScale.title)
                .foregroundStyle(Ink.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            ReaderMetaLine(model: model, thread: thread)
            ReaderSuggestion(model: model, thread: thread)
                .padding(.top, 8)
            if let found = model.invite(in: thread) {
                InviteCard(model: model, thread: thread, invite: found.invite)
                    .padding(.top, 6)
            }
            if let summary = model.summaries[thread.id] {
                SummaryBlock(summary: summary, attribution: model.assistantAttribution) { model.dismissSummary(of: thread) }
                    .padding(.top, 6)
                    .transition(.opacity)
            }
        }
        .padding(.bottom, Space.l)
        .animation(Motion.quick, value: model.summaries[thread.id])
    }
}

/// One message. Folded, it's a single line; open, it's the full text with no frame.
struct MessageView: View {
    let message: MailMessage
    let content: MessageBody?
    let prefersPlainText: Bool
    let trustsSender: Bool
    let onTrustSender: () -> Void
    let onMailto: (URL) -> Void
    var textScale: Double = 1
    var attachmentActions: AttachmentActions?
    /// For the person card on the sender's name and the message's source.
    var model: MailModel?
    var thread: MailThread?
    /// Reactions to this message, shown under it.
    var reactions: [MailReaction] = []
    @State private var showsPerson = false
    @State private var showsSource = false
    @State private var isExpanded: Bool
    @State private var isHovered = false
    @State private var actionsHovered = false
    /// Pictures allowed for this message only.
    @State private var loadsPicturesOnce = false
    /// This message switched away from the reading preference.
    @State private var showsOriginal: Bool?
    /// A calendar's automatic notice shows as a card; this shows its text instead.
    @State private var showsNoticeText = false

    init(message: MailMessage, content: MessageBody?, startsExpanded: Bool, prefersPlainText: Bool = false, trustsSender: Bool = false,
         onTrustSender: @escaping () -> Void = {}, onMailto: @escaping (URL) -> Void = { _ in },
         textScale: Double = 1, model: MailModel? = nil, thread: MailThread? = nil, reactions: [MailReaction] = [],
         attachmentActions: AttachmentActions? = nil) {
        self.model = model
        self.thread = thread
        self.reactions = reactions
        self.textScale = textScale
        self.attachmentActions = attachmentActions
        self.message = message
        self.content = content
        self.prefersPlainText = prefersPlainText
        self.trustsSender = trustsSender
        self.onTrustSender = onTrustSender
        self.onMailto = onMailto
        _isExpanded = State(initialValue: startsExpanded)
        _loadsPicturesOnce = State(initialValue: PicturesShownOnce.contains(message.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Button {
                    withAnimation(Motion.quick) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        // The sender's picture and name open their card, as in other mail apps.
                        Button { if model != nil { showsPerson = true } else { withAnimation(Motion.quick) { isExpanded.toggle() } } } label: {
                            HStack(spacing: 10) {
                                Avatar(message.from, size: 22)
                                Text(message.from.displayName)
                                    .font(TypeScale.rowStrong)
                                    .foregroundStyle(Ink.primary)
                                    .lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        // The sender keeps its name; "to …" gives way first.
                        .layoutPriority(1)
                        .popover(isPresented: $showsPerson, arrowEdge: .bottom) {
                            if let model { PersonCard(model: model, person: message.from) }
                        }
                        if isExpanded {
                            Text(recipients)
                                .font(TypeScale.label)
                                .foregroundStyle(Ink.tertiary)
                                .lineLimit(1)
                        } else {
                            Text(preview)
                                .font(TypeScale.row)
                                .foregroundStyle(Ink.tertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: Space.s)
                        Text(RowDate.long(message.date))
                            .font(TypeScale.label)
                            .foregroundStyle(Ink.tertiary)
                            .fixedSize()
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 8)
                    .background(isHovered && !isExpanded ? Fill.one : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
                .padding(.leading, -8)
                .tip(message.from.address)
                // Next to the time: answer or pass on this very message, however old it is. On a
                // folded message they show when it's pointed at; their room is always kept.
                if let model, thread != nil {
                    MessageActions(model: model, message: message)
                        .opacity(isExpanded || isHovered || actionsHovered ? 1 : 0)
                        .onHover { actionsHovered = $0 }
                }
                if isExpanded { messageMenu }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: Space.m) {
                    TranslatableBody(model: model, message: message, text: content?.text, html: shownHTML?.html, textScale: textScale) {
                        messageBody
                    }
                    if showsTranslation, shownHTML == nil, let content, !content.attachments.isEmpty { attachments(content.attachments) }
                    if let model, let thread, model.reaction(in: message, of: thread) == nil {
                        ReactionStrip(model: model, thread: thread, message: message, reactions: reactions)
                    }
                }
                // Plain text lines up under the name; HTML mail gets the full width it was laid out for.
                .padding(.leading, shownHTML == nil ? 32 : 0)
                .padding(.bottom, 20)
            }
        }
    }

    private var showsTranslation: Bool { model?.translations.phase(of: message.id) == .translated }

    /// The HTML this message shows (sanitized), when it's shown in its own layout.
    private var shownHTML: SafeHTML? {
        guard let content, let html = content.html, showsOriginal ?? !prefersPlainText else { return nil }
        if !showsNoticeText, model.flatMap({ model in thread.flatMap { model.reaction(in: message, of: $0) } }) != nil { return nil }
        if !showsNoticeText, MeetingNotice.detect(subject: message.subject, text: content.text) != nil { return nil }
        return SafeHTMLCache.sanitized(html)
    }

    /// The message as it came: a reaction or meeting notice as a card, the HTML, or its text.
    @ViewBuilder
    private var messageBody: some View {
        if !showsNoticeText, let model, let thread, let reaction = model.reaction(in: message, of: thread) {
            // A reaction whose message isn't here: one line, not Outlook's quoted copy.
            ReactionNoticeCard(reaction: reaction, subject: MailReaction.originalSubject(message.subject),
                               isMine: model.isMine(reaction, in: thread)) { showsNoticeText = true }
        } else if !showsNoticeText, let notice = MeetingNotice.detect(subject: message.subject, text: content?.text ?? message.snippet) {
            MeetingNoticeCard(notice: notice, who: message.from.displayName) { showsNoticeText = true }
        } else if let content, let html = content.html, showsOriginal ?? !prefersPlainText {
            let safe = SafeHTMLCache.sanitized(html)
            let allowsRemote = trustsSender || loadsPicturesOnce
            if safe.hasRemoteContent && !allowsRemote {
                RemotePicturesNote(trackers: safe.trackers, sender: message.from.displayName) { PicturesShownOnce.allow(message.id); loadsPicturesOnce = true }
            } else if !safe.blockedTrackers.isEmpty || safe.cleanedLinks > 0 {
                TrackersBlockedNote(safe: safe)
            }
            HTMLMessageView(html: model?.translations.shown(safe, for: message.id) ?? safe, allowsRemote: allowsRemote, zoom: textScale, onMailto: onMailto)
            if !content.attachments.isEmpty { attachments(content.attachments) }
        } else if let content {
            Text(PlainTextLinks.attributed(content.text))
                .font(.system(size: 15 * textScale))
                .foregroundStyle(Ink.primary)
                .lineSpacing(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !content.attachments.isEmpty { attachments(content.attachments) }
        } else {
            Text("Loading…").font(TypeScale.body).foregroundStyle(Ink.tertiary)
        }
    }

    /// Options for one HTML message, kept out of the way in a small menu on its header line.
    private var messageMenu: some View {
        let original = showsOriginal ?? !prefersPlainText
        let blocked = content?.html.map { SafeHTMLCache.sanitized($0).hasRemoteContent } == true && !trustsSender && !loadsPicturesOnce
        return Menu {
            if content?.html != nil {
                Button(original ? "Show as plain text" : "Show original layout") { showsOriginal = !original }
                if original && blocked {
                    Divider()
                    Button("Load pictures") { PicturesShownOnce.allow(message.id); loadsPicturesOnce = true }
                    Button("Always load pictures from \(message.from.displayName)", action: onTrustSender)
                }
                Divider()
            }
            if let model, thread != nil {
                Button("Reply") { model.startReply(to: message) }
                Button("Reply all") { model.startReply(to: message, all: true) }
                Button("Forward") { model.startForward(message) }
                Divider()
            }
            if let model, model.translations.language(of: message.id) != nil {
                Button(showsTranslation ? "Show Original" : "Translate") { model.translations.toggle(message.id) }
                Divider()
            }
            if let model, let thread, model.canReact(to: message, in: thread) {
                ReactMenu(model: model, thread: thread, message: message)
                Divider()
            }
            if model != nil {
                Button("About \(message.from.displayName)") { showsPerson = true }
                // Headers and the full MIME source, for checking what a server really sent.
                Button("Show Source") { showsSource = true }
                    .keyboardShortcut("u", modifiers: [.command, .option])
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Ink.tertiary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        #if os(macOS)
        .menuIndicator(.hidden)
        #endif
        .fixedSize()
        .tip("Message options")
        .accessibilityLabel("Message options")
        .sheet(isPresented: $showsSource) {
            if let model, let thread { MessageSourceView(model: model, message: message, thread: thread) }
        }
    }

    private var recipients: String {
        let names = (message.to + message.cc).map(\.displayName)
        return names.isEmpty ? "" : String(localized: "to \(names.joined(separator: ", "))", comment: "Recipients under a message header")
    }

    private var preview: String {
        message.snippet.isEmpty ? (content.map { HTMLText.snippet($0.text) } ?? "") : message.snippet
    }

    private func attachments(_ files: [AttachmentInfo]) -> some View {
        FlowRow(spacing: Space.s) {
            ForEach(files, id: \.self) { file in
                AttachmentChip(file: file, actions: attachmentActions)
            }
        }
    }
}

/// Reply, reply all and forward for one message of a conversation, as three small buttons.
struct MessageActions: View {
    let model: MailModel
    let message: MailMessage

    var body: some View {
        HStack(spacing: 0) {
            button("arrowshape.turn.up.left", "Reply") { model.startReply(to: message) }
            button("arrowshape.turn.up.left.2", "Reply all") { model.startReply(to: message, all: true) }
            button("arrowshape.turn.up.right", "Forward") { model.startForward(message) }
        }
    }

    private func button(_ symbol: String, _ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Ink.tertiary)
                .frame(width: 26, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tip(title)
        .accessibilityLabel(Text(title))
    }
}

/// Shown above HTML mail that wants pictures from the web: one quiet line, no box.
/// "Always for this sender" is in the message's "…" menu.
private struct RemotePicturesNote: View {
    let trackers: Int
    let sender: String
    let onLoad: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye.slash").font(.system(size: 11))
            status.lineLimit(1)
            Text(verbatim: "·").foregroundStyle(Ink.quaternary)
            Button("Load", action: onLoad)
                .buttonStyle(.plain)
                .fontWeight(.medium)
                .foregroundStyle(Ink.primary)
        }
        .font(TypeScale.label)
        .foregroundStyle(Ink.tertiary)
        .tip("Loading pictures from the web tells \(sender) that you opened this.")
    }

    private var status: Text {
        switch trackers {
        case 0: Text("Pictures off")
        case 1: Text("Pictures off · 1 tracker blocked")
        default: Text("Pictures off · \(trackers) trackers blocked")
        }
    }
}

/// With pictures on: what tracker blocking still took out, by name.
struct TrackersBlockedNote: View {
    let safe: SafeHTML

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.raised").font(.system(size: 11))
            Text(summary).lineLimit(1)
        }
        .font(TypeScale.label)
        .foregroundStyle(Ink.tertiary)
        .tip(safe.blockedTrackers.joined(separator: ", "))
    }

    private var summary: String {
        var parts: [String] = []
        if !safe.blockedTrackers.isEmpty {
            let names = safe.blockedTrackers.prefix(2).joined(separator: ", ") + (safe.blockedTrackers.count > 2 ? "…" : "")
            parts.append(String(localized: "Trackers blocked: \(names)"))
        }
        if safe.cleanedLinks > 0 {
            parts.append(safe.cleanedLinks == 1 ? String(localized: "1 link untracked") : String(localized: "\(safe.cleanedLinks) links untracked"))
        }
        return parts.joined(separator: " · ")
    }
}

/// Sanitizing is a few regex passes over the whole mail; do it once per message, not per frame.
@MainActor
enum SafeHTMLCache {
    private static var cache: [Int: SafeHTML] = [:]
    /// Set from the person's setting (on unless they turned it off).
    nonisolated(unsafe) static var blocksTrackers = true

    static func sanitized(_ html: String) -> SafeHTML {
        var hasher = Hasher()
        hasher.combine(html)
        hasher.combine(blocksTrackers)
        let key = hasher.finalize()
        if let hit = cache[key] { return hit }
        let safe = HTMLSanitizer.sanitize(html, blockTrackers: blocksTrackers)
        if cache.count > 200 { cache.removeAll() }
        cache[key] = safe
        return safe
    }
}
