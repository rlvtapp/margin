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
    @State private var showsTranslation = false
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
                            ForEach(conversation.messages) { message in
                                Rectangle().fill(Line.hairline).frame(height: 1)
                                TouchMessageCard(
                                    model: model,
                                    thread: thread,
                                    message: message,
                                    startsExpanded: message.id == conversation.latest.id || message.isUnread
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

    /// The subject, a row of small facts, then at most one helpful card.
    private func header(_ thread: MailThread) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(thread.subject.isEmpty ? String(localized: "(No subject)") : thread.subject)
                .font(.system(size: 28, weight: .bold))
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
                    if thread.messages.count > 1 {
                        GlassChip(Text("\(thread.messages.count) messages"), symbol: "bubble.left.and.bubble.right")
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
            ReaderMoreMenu(model: model, thread: thread, showsTranslation: $showsTranslation, addsLabel: $addsLabel)
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

    private var translatableText: String {
        guard let thread = model.selectedThread else { return "" }
        let latest = thread.latest
        return thread.subject + "\n\n" + (model.body(of: latest, in: thread)?.text ?? latest.snippet)
    }
}

/// One message, straight on the page and the full width of the screen. Folded: sender, time
/// and two lines of text. Open: the sender line, then the mail, in reading sizes.
private struct TouchMessageCard: View {
    let model: MailModel
    let thread: MailThread
    let message: MailMessage
    @State private var isExpanded: Bool
    @State private var loadsPicturesOnce = false
    @State private var showsOriginal: Bool?
    @State private var showsNoticeText = false

    init(model: MailModel, thread: MailThread, message: MailMessage, startsExpanded: Bool) {
        self.model = model
        self.thread = thread
        self.message = message
        _isExpanded = State(initialValue: startsExpanded)
        _loadsPicturesOnce = State(initialValue: PicturesShownOnce.contains(message.id))
    }

    private var content: MessageBody? { model.body(of: message, in: thread) }
    private var showsHTML: Bool { content?.html != nil && (showsOriginal ?? !model.prefersPlainText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            senderLine
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, isExpanded ? 12 : 16)
            if isExpanded {
                if !showsNoticeText, let notice = MeetingNotice.detect(subject: message.subject, text: content?.text ?? message.snippet) {
                    MeetingNoticeCard(notice: notice, who: message.from.displayName) { showsNoticeText = true }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                } else {
                    messageBody
                        .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var senderLine: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(message.from, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(verbatim: message.from.displayName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    Spacer(minLength: Space.s)
                    Text(RowDate.string(message.date))
                        .font(.system(size: 14))
                        .foregroundStyle(Ink.tertiary)
                        .fixedSize()
                }
                if isExpanded {
                    if !recipients.isEmpty {
                        Text(recipients)
                            .font(.system(size: 14))
                            .foregroundStyle(Ink.tertiary)
                            .lineLimit(1)
                    }
                } else {
                    Text(verbatim: preview)
                        .font(.system(size: 15))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(2)
                }
            }
            if isExpanded, content?.html != nil { optionsMenu.padding(.top, -6) }
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
                HTMLMessageView(html: safe, allowsRemote: allowsRemote, zoom: model.textScale, fillsCard: true) {
                    model.startCompose(mailto: $0)
                }
                attachments(content.attachments)
                    .padding(20)
            }
        } else if let content {
            VStack(alignment: .leading, spacing: Space.l) {
                Text(verbatim: content.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 17 * model.textScale))
                    .foregroundStyle(Ink.primary)
                    .lineSpacing(7)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                attachments(content.attachments)
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
            Image(systemName: "eye.slash").font(.system(size: 13))
            Text(trackers > 0 ? String(localized: "Pictures off · \(trackers) blocked") : String(localized: "Pictures off"))
                .lineLimit(1)
            Spacer(minLength: Space.s)
            Button("Load") { PicturesShownOnce.allow(message.id); loadsPicturesOnce = true }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Fill.two, in: Capsule())
                .buttonStyle(.plain)
        }
        .font(.system(size: 14))
        .foregroundStyle(Ink.tertiary)
    }

    private var optionsMenu: some View {
        let original = showsOriginal ?? !model.prefersPlainText
        return Menu {
            Button(original ? "Show as plain text" : "Show original layout") { showsOriginal = !original }
            if original, !model.trustsPictures(from: message.from) {
                Button("Load pictures") { PicturesShownOnce.allow(message.id); loadsPicturesOnce = true }
                Button("Always load pictures from \(message.from.displayName)") { model.trustPictures(from: message.from) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
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
