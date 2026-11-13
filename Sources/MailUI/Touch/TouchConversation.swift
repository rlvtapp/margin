#if os(iOS)
import MailCore
import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// An open conversation on iPhone and iPad. Each message is its own card on a quieter page,
/// in reading sizes, with a clear sender line; earlier messages fold to a short preview.
/// Every action sits in the bars, where a thumb reaches it.
struct TouchConversation: View {
    @Bindable var model: MailModel
    @State private var addsLabel = false
    @State private var newLabel = ""

    var body: some View {
        Group {
            if let thread = model.selectedThread {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            header(thread)
                                .padding(.horizontal, 20)
                                .padding(.bottom, Space.m)
                            let conversation = model.conversation(thread)
                            if model.showsAsChat {
                                ChatConversationView(model: model, thread: conversation)
                            } else {
                            // Reactions sit on the message they answer instead of as messages.
                            let layout = model.reactionLayout(conversation)
                            ForEach(layout.messages) { message in
                                Rectangle().fill(Line.hairline).frame(height: 1)
                                TouchMessageCard(
                                    model: model,
                                    thread: thread,
                                    message: message,
                                    reactions: layout.reactions[message.id] ?? [],
                                    startsExpanded: message.id == layout.messages.last?.id || message.isUnread
                                )
                                .id(message.id)
                            }
                            }
                            if model.isAssistantOn {
                                ReplySuggestionsRow(model: model, thread: thread)
                                    .padding(.horizontal, 20)
                                    .padding(.top, Space.s)
                            }
                        }
                        .padding(.top, Space.xs)
                        .padding(.bottom, 96)
                        // On iPad, a comfortable line length in the middle of a wide column.
                        .frame(maxWidth: 820)
                        .frame(maxWidth: .infinity)
                    }
                    .onAppear { proxy.scrollTo(thread.latest.id, anchor: .top) }
                    // Outlook's own reactions, when they're turned on for this account.
                    .task(id: thread.id) { await model.loadOutlookReactions(for: thread) }
                }
                .toolbar { toolbar(thread) }
            } else {
                ListMessage(title: model.isLoading ? "" : "No conversation selected", detail: nil, action: nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Paper.panel)
        .onScreenForSiri(model.selectedThread)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Add a label", isPresented: $addsLabel) {
            TextField("Label", text: $newLabel)
            Button("Cancel", role: .cancel) { newLabel = "" }
            Button("Add") {
                if let thread = model.selectedThread { model.addLabel(newLabel, to: thread) }
                newLabel = ""
            }
        }
    }

    /// The subject, a row of small facts, then at most one helpful card.
    private func header(_ thread: MailThread) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(thread.subject.isEmpty ? String(localized: "(No subject)") : thread.subject)
                .font(.system(size: Look.size(28), weight: .bold))
                .tracking(-0.3)
                .foregroundStyle(Ink.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView(.horizontal, showsIndicators: false) {
                GlassChipRow {
                    GlassChip(Text(thread.split.title), symbol: TouchThreadList.symbol(thread.split), color: Palette.split(thread.split))
                    if let account = model.account(thread.accountID), model.accounts.count > 1 {
                        GlassChip(Text(verbatim: account.label), symbol: "tray", color: Palette.account(account.colorIndex))
                    }
                    if model.withoutReactions(thread).messages.count > 1 {
                        GlassChip(Text("\(model.withoutReactions(thread).messages.count) messages"), symbol: "bubble.left.and.bubble.right")
                    }
                    ForEach(model.labels(for: thread), id: \.self) { label in
                        GlassChip(Text(verbatim: label), symbol: "tag")
                    }
                }
                .padding(.vertical, 2)
            }
                ReaderSuggestion(model: model, thread: thread)
            if let found = model.invite(in: thread) {
                InviteCard(model: model, thread: thread, invite: found.invite)
            }
            if let summary = model.summaries[thread.id] {
                SummaryBlock(summary: summary, attribution: model.assistantAttribution) { model.dismissSummary(of: thread) }
                    .transition(.opacity)
            }
        }
        .padding(.top, Space.s)
        .animation(Motion.quick, value: model.summaries[thread.id])
    }

    @ToolbarContentBuilder
    private func toolbar(_ thread: MailThread) -> some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { model.toggleStar() } label: {
                Label(thread.isStarred ? "Remove star" : "Star", systemImage: thread.isStarred ? "star.fill" : "star")
                    .symbolEffect(.bounce, value: thread.isStarred)
            }
            .tint(thread.isStarred ? Status.star : Ink.primary)
            .sensoryFeedback(.impact(weight: .light), trigger: thread.isStarred)
            ReaderMoreMenu(model: model, thread: thread, addsLabel: $addsLabel)
        }
        ToolbarItemGroup(placement: .bottomBar) {
            Button { model.perform(.done) } label: { Label("Done", systemImage: "checkmark.circle") }
            Menu {
                ForEach(SnoozePreset.allCases, id: \.self) { preset in
                    let date = preset.date()
                    Button {
                        model.snooze(until: date)
                    } label: {
                        Text(verbatim: "\(preset.title) · \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                    }
                }
            } label: { Label("Snooze", systemImage: "clock") }
            Button(role: .destructive) { model.perform(.trash) } label: { Label("Trash", systemImage: "trash") }
            Spacer()
            if model.isAssistantOn {
                Button { model.summarizeSelected() } label: { Label("Summarize", systemImage: "sparkles") }
                    .disabled(model.isWorking("summary", on: thread))
            }
            Menu {
                Button { model.startReply() } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                Button { model.startReply(all: true) } label: { Label("Reply all", systemImage: "arrowshape.turn.up.left.2") }
                Button { model.startForward() } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            } primaryAction: {
                model.startReply()
            }
        }
    }

}

/// One message, straight on the page and the full width of the screen. Folded: sender, time
/// and two lines of text. Open: the sender line, then the mail, in reading sizes.
private struct TouchMessageCard: View {
    let model: MailModel
    let thread: MailThread
    let message: MailMessage
    /// Reactions to this message, shown under it.
    var reactions: [MailReaction] = []
    @State private var isExpanded: Bool
    @State private var loadsPicturesOnce = false
    @State private var showsOriginal: Bool?
    @State private var showsNoticeText = false
    @State private var showsPerson = false
    @State private var showsSource = false
    /// The earlier mail quoted under this message, unfolded with the "···" button.
    @State private var showsQuote = false

    /// Earlier mail quoted under a message is folded away behind "···", except in a forward,
    /// where the quoted part is the point.
    private var foldsQuote: Bool {
        !QuotedHistory.isForward(message.subject)
    }

    init(model: MailModel, thread: MailThread, message: MailMessage, reactions: [MailReaction] = [], startsExpanded: Bool) {
        self.model = model
        self.thread = thread
        self.message = message
        self.reactions = reactions
        _isExpanded = State(initialValue: startsExpanded)
        _loadsPicturesOnce = State(initialValue: PicturesShownOnce.contains(message.id))
    }

    private var content: MessageBody? { model.body(of: message, in: thread) }
    private var showsHTML: Bool { content?.html != nil && (showsOriginal ?? !model.prefersPlainText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            senderLine
                .sheet(isPresented: $showsPerson) {
                    ScrollView { PersonCard(model: model, person: message.from).frame(maxWidth: .infinity) }
                        .presentationDetents([.medium, .large])
                }
                .sheet(isPresented: $showsSource) {
                    NavigationStack { MessageSourceView(model: model, message: message, thread: thread) }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, isExpanded ? 12 : 16)
            if isExpanded {
                if !showsNoticeText, let reaction = model.reaction(in: message, of: thread) {
                    // A reaction whose message isn't here: one line, not Outlook's quoted copy.
                    ReactionNoticeCard(reaction: reaction, subject: MailReaction.originalSubject(message.subject),
                                       isMine: model.isMine(reaction, in: thread)) { showsNoticeText = true }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                } else if !showsNoticeText, let notice = MeetingNotice.detect(subject: message.subject, text: content?.text ?? message.snippet) {
                    MeetingNoticeCard(notice: notice, who: message.from.displayName) { showsNoticeText = true }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                } else {
                    TranslatableBody(model: model, message: message, text: content?.text, html: showsHTML ? content?.html.map { SafeHTMLCache.sanitized($0).html } : nil,
                                     textScale: model.textScale * 17 / 15, inset: 20, trimsQuote: foldsQuote && !showsQuote) {
                        messageBody
                    }
                    .transition(.opacity)
                    if model.translations.phase(of: message.id) == .translated, !showsHTML, let content, !content.attachments.isEmpty {
                        attachments(content.attachments).padding(.horizontal, 20).padding(.bottom, 16)
                    }
                }
                if model.reaction(in: message, of: thread) == nil {
                    ReactionStrip(model: model, thread: thread, message: message, reactions: reactions, touch: true)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var senderLine: some View {
        HStack(alignment: .top, spacing: 12) {
            // The picture and the name open the person's card.
            Button { showsPerson = true } label: { Avatar(message.from, size: 40) }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("About \(message.from.displayName)"))
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Button { showsPerson = true } label: {
                        Text(verbatim: message.from.displayName)
                            .font(.system(size: Look.size(17), weight: .semibold))
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: Space.s)
                    Text(RowDate.string(message.date))
                        .font(.system(size: Look.size(14)))
                        .foregroundStyle(Ink.tertiary)
                        .fixedSize()
                }
                if isExpanded {
                    if !recipients.isEmpty {
                        Text(recipients)
                            .font(.system(size: Look.size(14)))
                            .foregroundStyle(Ink.tertiary)
                            .lineLimit(1)
                    }
                } else {
                    Text(verbatim: preview)
                        .font(.system(size: Look.size(15)))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(2)
                }
            }
            if isExpanded { optionsMenu.padding(.top, -6) }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(Motion.quick) { isExpanded.toggle() } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isExpanded ? Text("Folds this message") : Text("Opens this message"))
    }

    @ViewBuilder
    private var messageBody: some View {
        if let content, let html = content.html, showsHTML {
            let safe = SafeHTMLCache.sanitized(html)
            let allowsRemote = model.trustsPictures(from: message.from) || loadsPicturesOnce
            VStack(alignment: .leading, spacing: 0) {
                if safe.hasRemoteContent && !allowsRemote {
                    picturesNote(trackers: safe.trackers)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                } else if !safe.blockedTrackers.isEmpty || safe.cleanedLinks > 0 {
                    TrackersBlockedNote(safe: safe)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                }
                // The mail fills the card: its own colors, margins and a reading size.
                let full = model.translations.shown(safe, for: message.id)
                let folded = foldsQuote ? QuotedHistory.htmlWithoutQuote(full.html) : nil
                HTMLMessageView(html: showsQuote ? full : full.replacing(html: folded), allowsRemote: allowsRemote, zoom: model.textScale, fillsCard: true) {
                    model.startCompose(mailto: $0)
                }
                if folded != nil {
                    QuoteToggle(isOpen: $showsQuote).padding(.horizontal, 20).padding(.top, 8)
                }
                attachments(content.attachments)
                    .padding(20)
                if content.isPartial == true { AttachmentsLoadingNote().padding(.horizontal, 20).padding(.bottom, 12) }
            }
        } else if let content {
            VStack(alignment: .leading, spacing: Space.l) {
                let folded = foldsQuote ? QuotedHistory.textWithoutQuote(content.text) : nil
                Text(verbatim: (showsQuote ? content.text : folded ?? content.text).trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 17 * model.textScale))
                    .foregroundStyle(Ink.primary)
                    .lineSpacing(7)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if folded != nil { QuoteToggle(isOpen: $showsQuote) }
                attachments(content.attachments)
                if content.isPartial == true { AttachmentsLoadingNote() }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, Space.xl)
        }
    }

    @ViewBuilder
    private func attachments(_ files: [AttachmentInfo]) -> some View {
        if !files.isEmpty {
            FlowRow(spacing: Space.s) {
                ForEach(files, id: \.self) { file in
                    AttachmentChip(file: file, actions: AttachmentActions(
                        open: { model.openAttachment($0, of: message, in: thread) },
                        save: { model.saveAttachment($0, of: message, in: thread) },
                        file: { try await model.attachmentFile($0, of: message, in: thread) }
                    ))
                }
            }
        }
    }

    /// "Pictures off · 1 blocked        Load"
    private func picturesNote(trackers: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash").font(.system(size: Look.size(13)))
            Text(trackers > 0 ? String(localized: "Pictures off · \(trackers) blocked") : String(localized: "Pictures off"))
                .lineLimit(1)
            Spacer(minLength: Space.s)
            Button("Load") { PicturesShownOnce.allow(message.id); loadsPicturesOnce = true }
                .font(.system(size: Look.size(14), weight: .semibold))
                .foregroundStyle(Ink.primary)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Fill.two, in: Capsule())
                .buttonStyle(.plain)
        }
        .font(.system(size: Look.size(14)))
        .foregroundStyle(Ink.tertiary)
    }

    private var optionsMenu: some View {
        let original = showsOriginal ?? !model.prefersPlainText
        return Menu {
            if content?.html != nil {
                Button(original ? "Show as plain text" : "Show original layout") { showsOriginal = !original }
                if original, !model.trustsPictures(from: message.from) {
                    Button("Load pictures") { PicturesShownOnce.allow(message.id); loadsPicturesOnce = true }
                    Button("Always load pictures from \(message.from.displayName)") { model.trustPictures(from: message.from) }
                }
                Divider()
            }
            Button { model.startReply(to: message) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
            Button { model.startReply(to: message, all: true) } label: { Label("Reply all", systemImage: "arrowshape.turn.up.left.2") }
            Button { model.startForward(message) } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
            Divider()
            if model.translations.language(of: message.id) != nil {
                Button(model.translations.phase(of: message.id) == .translated ? "Show Original" : "Translate") { model.translations.toggle(message.id) }
                Divider()
            }
            if model.canReact(to: message, in: thread) {
                ReactMenu(model: model, thread: thread, message: message)
                Divider()
            }
            Button("About \(message.from.displayName)") { showsPerson = true }
            Button("Show Source") { showsSource = true }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: Look.size(16), weight: .semibold))
                .foregroundStyle(Ink.tertiary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Message options")
    }

    private var recipients: String {
        let names = (message.to + message.cc).map(\.displayName)
        return names.isEmpty ? "" : String(localized: "to \(names.joined(separator: ", "))")
    }

    private var preview: String {
        message.snippet.isEmpty ? (content.map { HTMLText.snippet($0.text) } ?? "") : message.snippet
    }
}
#endif
