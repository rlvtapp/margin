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
    @State var showsTranslation = false
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
                                ForEach(Array(conversation.messages.enumerated()), id: \.element.id) { index, message in
                                    if index > 0 { Rectangle().fill(Line.hairline).frame(height: 1) }
                                    MessageView(
                                        message: message,
                                        content: model.body(of: message, in: thread),
                                        startsExpanded: message.id == conversation.latest.id || message.isUnread,
                                        prefersPlainText: model.prefersPlainText,
                                        trustsSender: model.trustsPictures(from: message.from),
                                        onTrustSender: { model.trustPictures(from: message.from) },
                                        onMailto: { model.startCompose(mailto: $0) },
                                        textScale: model.textScale,
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
                        .onChange(of: model.reply != nil) { _, open in
                            if open { withAnimation(Motion.quick) { proxy.scrollTo("reply", anchor: .bottom) } }
                        }
                    }
                }
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
        #if canImport(Translation)
        .translationPresentation(isPresented: $showsTranslation, text: translatableText)
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

    private var translatableText: String {
        guard let thread = model.selectedThread else { return "" }
        let latest = thread.latest
        return thread.subject + "\n\n" + (model.body(of: latest, in: thread)?.text ?? latest.snippet)
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
            Spacer()
            // Three groups with room between them: handle it, organise it, write.
            HStack(spacing: 4) {
                IconButton("checkmark.circle", help: "Done  E") { model.perform(.done) }
                IconButton("trash", help: "Move to Trash  #") { model.perform(.trash) }
            }
            toolbarGap
            HStack(spacing: 4) {
                IconButton(thread.isStarred ? "star.fill" : "star", help: thread.isStarred ? "Remove star  S" : "Star  S") { model.toggleStar() }
                IconButton(thread.isUnread ? "envelope.open" : "envelope.badge", help: thread.isUnread ? "Mark read  U" : "Mark unread  U") { model.toggleRead() }
                SnoozeMenu(model: model)
            }
            toolbarGap
            HStack(spacing: 4) {
            if model.isAssistantOn {
                if model.isWorking("summary", on: thread) {
                    ProgressView().controlSize(.small).frame(width: 28, height: 28)
                } else {
                    IconButton("text.alignleft", help: "Summarize  M") { model.summarizeSelected() }
                }
            }
            IconButton("arrowshape.turn.up.left", help: "Reply  R") { model.startReply() }
            IconButton("arrowshape.turn.up.right", help: "Forward  F") { model.startForward() }
            ReaderMoreMenu(model: model, thread: thread, showsTranslation: $showsTranslation, addsLabel: $addsLabel)
            }
        }
        .padding(.leading, Space.s)
        .padding(.trailing, Space.m)
        .frame(height: MailLayout.topBand)
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
    @State private var isExpanded: Bool
    @State private var isHovered = false
    /// Pictures allowed for this message only.
    @State private var loadsPicturesOnce = false
    /// This message switched away from the reading preference.
    @State private var showsOriginal: Bool?
    /// A calendar's automatic notice shows as a card; this shows its text instead.
    @State private var showsNoticeText = false

    init(message: MailMessage, content: MessageBody?, startsExpanded: Bool, prefersPlainText: Bool = false, trustsSender: Bool = false,
         onTrustSender: @escaping () -> Void = {}, onMailto: @escaping (URL) -> Void = { _ in },
         textScale: Double = 1, attachmentActions: AttachmentActions? = nil) {
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
                        Avatar(message.from, size: 22)
                        Text(message.from.displayName)
                            .font(TypeScale.rowStrong)
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                            // The sender keeps its name; "to …" gives way first.
                            .layoutPriority(1)
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
                .help(message.from.address)
                if isExpanded, let content, content.html != nil { messageMenu }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: Space.m) {
                    if !showsNoticeText, let notice = MeetingNotice.detect(subject: message.subject, text: content?.text ?? message.snippet) {
                        MeetingNoticeCard(notice: notice, who: message.from.displayName) { showsNoticeText = true }
                    } else if let content, let html = content.html, showsOriginal ?? !prefersPlainText {
                        let safe = SafeHTMLCache.sanitized(html)
                        let allowsRemote = trustsSender || loadsPicturesOnce
                        if safe.hasRemoteContent && !allowsRemote {
                            RemotePicturesNote(trackers: safe.trackers, sender: message.from.displayName) { PicturesShownOnce.allow(message.id); loadsPicturesOnce = true }
                        } else if !safe.blockedTrackers.isEmpty || safe.cleanedLinks > 0 {
                            TrackersBlockedNote(safe: safe)
                        }
                        HTMLMessageView(html: safe, allowsRemote: allowsRemote, zoom: textScale, onMailto: onMailto)
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
                // Plain text lines up under the name; HTML mail gets the full width it was laid out for.
                .padding(.leading, content?.html == nil ? 32 : 0)
                .padding(.bottom, 20)
            }
        }
    }

    /// Options for one HTML message, kept out of the way in a small menu on its header line.
    private var messageMenu: some View {
        let original = showsOriginal ?? !prefersPlainText
        let blocked = content?.html.map { SafeHTMLCache.sanitized($0).hasRemoteContent } == true && !trustsSender && !loadsPicturesOnce
        return Menu {
            Button(original ? "Show as plain text" : "Show original layout") { showsOriginal = !original }
            if original && blocked {
                Divider()
                Button("Load pictures") { PicturesShownOnce.allow(message.id); loadsPicturesOnce = true }
                Button("Always load pictures from \(message.from.displayName)", action: onTrustSender)
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
        .help("Message options")
        .accessibilityLabel("Message options")
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
        .help("Loading pictures from the web tells \(sender) that you opened this.")
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
        .help(safe.blockedTrackers.joined(separator: ", "))
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
