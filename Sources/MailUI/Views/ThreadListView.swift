import MailCore
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct ThreadListView: View {
    @Bindable var model: MailModel
    var searchFocus: FocusState<Bool>.Binding
    @State private var listWidth: CGFloat = 0
    /// Home's note margin takes about 80 points, so it only shows from this list width.
    static let marginWidth: CGFloat = 560

    var body: some View {
        VStack(spacing: 0) {
            header
            if case .some(let split) = model.split, model.layout != .spark {
                // The tabs scroll on to the column's edge; the first starts at the page's margin.
                splitTabs(split)
                    .contentMargins(.leading, model.layout.isCalm ? Space.s : Space.l, for: .scrollContent)
                    .contentMargins(.trailing, Space.s, for: .scrollContent)
                    .padding(.bottom, Space.s)
                    .calmColumn(model.layout.isCalm)
            }
            Group {
                if model.layout == .spark {
                    SparkHeader(model: model)
                } else if model.place.isHome && !model.showsMinimalHome {
                    HomeHeader(model: model, edgeInset: model.layout.isCalm ? Space.m : 0)
                }
            }
            .padding(.horizontal, model.layout.isCalm ? Space.m : 0)
            .calmColumn(model.layout.isCalm)
            // Search and the quick filters live in the window bar above (WindowBar).
            if !model.selection.isEmpty {
                SelectionBar(model: model)
                    .padding(.horizontal, Space.m)
                    .padding(.bottom, Space.s)
                    .calmColumn(model.layout.isCalm)
            }
            content
        }
        .background(Paper.panel)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { listWidth = $0 }
        .sheet(item: $model.creatingRule) { form in CreateRuleSheet(model: model, form: form) }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.s) {
                    Text(model.title)
                        .font(TypeScale.heading)
                        .foregroundStyle(Ink.primary)
                }
                Text(summary)
                    .font(TypeScale.caption)
                    .foregroundStyle(Ink.tertiary)
            }
            Spacer(minLength: Space.s)
            // New message lives in the sidebar; with the sidebar hidden, it's here instead. The
            // sidebar's own button is in the top bar.
            IconButton("arrow.clockwise", help: "Check for new mail  ⇧⌘N") { Task { await model.reload() } }
            if model.isSidebarOutOfSight {
                IconButton("square.and.pencil", help: "New message  C") { model.startCompose() }
            }
        }
        .padding(.leading, model.layout.isCalm ? Space.s : Space.l)
        .padding(.trailing, Space.s)
        .frame(height: MailLayout.topBand)
        // In the centred layouts the title and its buttons line up with the page below them,
        // instead of sitting at the far edges of the window.
        .calmColumn(model.layout.isCalm)
    }

    /// "15 conversations, 9 unread"
    private var summary: String {
        if case .search = model.place, model.isSearchingServers {
            return String(localized: "\(model.listCount) found so far · searching servers…")
        }
        // Of everything the place holds, not only the rows shown so far.
        let total = model.listCount, unread = model.listUnreadCount
        let count = total == 1 ? String(localized: "1 conversation") : String(localized: "\(total) conversations")
        return unread > 0 ? String(localized: "\(count), \(unread) unread", comment: "Conversation count, then how many are unread") : count
    }

    /// All, Important (mail from people) or Other (updates and newsletters): which part of the
    /// inbox to show, as the same Liquid Glass tabs Home and the iPhone use.
    private func splitTabs(_ current: InboxSplit?) -> some View {
        let accountID = model.place.accountID
        return ScrollView(.horizontal, showsIndicators: false) {
            GlassChipRow {
                // The picked glass's own deep tint: the text colour as a tint is near white in
                // dark mode, under white text.
                // The list swaps at once; only the chips animate (below). Animating the place
                // change animated every row and the reader too, which lagged on a full inbox.
                Button {
                    model.go(to: .inbox(account: accountID, split: nil))
                } label: {
                    GlassChip(Text("All"), symbol: current == nil ? "tray.fill" : "tray", color: Ink.primary,
                              count: model.unreadCount(account: accountID), isOn: current == nil)
                }
                .buttonStyle(.plain)
                ForEach(InboxSplit.tabs, id: \.self) { split in
                    splitTab(split, isOn: current.map { ($0 == .people) == (split == .people) } ?? false, accountID: accountID)
                }
            }
            .padding(.vertical, 4)
            .animation(Look.reduceMotion ? nil : Motion.quick, value: current)
        }
        .tip("Show part of the inbox  ⌘1–⌘3")
    }

    private func splitTab(_ split: InboxSplit, isOn: Bool, accountID: UUID?) -> some View {
        let symbol = split == .people ? "person.2" : "tray.full"
        let unread: Int = model.unreadCount(account: accountID, split: split)
        return Button {
            model.go(to: .inbox(account: accountID, split: split))
        } label: {
            GlassChip(Text(split.tabTitle), symbol: symbol + (isOn ? ".fill" : ""), color: Palette.split(split),
                      tint: Palette.deep(split), count: unread, isOn: isOn)
        }
        .buttonStyle(.plain)
    }

    // MARK: List

    @ViewBuilder
    private var content: some View {
        let threads = model.visibleThreads
        if model.place == .scheduled {
            OutboxList(model: model)
        } else if model.place == .subscriptions {
            SubscriptionsPage(model: model)
        } else if let error = model.place.accountID.flatMap({ model.loadErrors[$0] }), threads.isEmpty {
            // A refused sign-in is fixed by signing in again; anything else by trying again.
            if let id = model.place.accountID, model.needsSignIn(id), let account = model.account(id), model.canSignInAgain(account) {
                ListMessage(title: "Couldn't sign in", verbatimDetail: error, action: ("Sign in again", { model.signingInAgain = account }))
            } else if let id = model.place.accountID, model.isUnreachable(id) {
                ListMessage(title: "Couldn't load mail", detail: "Can't reach the server right now. Margin keeps trying.",
                            action: ("Try Again", { Task { await model.reload() } }))
            } else {
                ListMessage(title: "Couldn't load mail", verbatimDetail: error, action: ("Try Again", { Task { await model.reload() } }))
            }
        } else if threads.isEmpty && model.isListLoading {
            LoadingMessage()
        } else if threads.isEmpty {
            if !model.searchText.isEmpty {
                ListMessage(title: "No results", detail: "Try from:, is:unread or has:attachment.", action: nil)
            } else {
                ListMessage(title: model.split != nil ? "You're all caught up" : "Nothing here", detail: nil, action: nil)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if model.split == .some(.newsletters) {
                            NewsletterSuggestionCard(model: model)
                                .padding(.horizontal, 4)
                                .padding(.bottom, Space.s)
                        }
                        if model.showsMinimalHome {
                            MinimalHomeHeader(model: model).padding(.horizontal, Space.s).id("home-top")
                        }
                        if let sections = model.listSections(threads) {
                            ForEach(sections) { section in
                                if model.showsMinimalHome {
                                    MinimalSectionHeader(section: section).id(section.id)
                                } else {
                                    ListSectionHeader(section: section).id(section.id)
                                }
                                ForEach(section.threads) { row($0) }
                            }
                        } else {
                            ForEach(threads) { row($0) }
                        }
                        // The last row: coming on screen, it brings in the next rows, and
                        // older mail once everything loaded is shown.
                        if model.canShowMore { ListEndRow(model: model, shown: threads.count) }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, Space.l)
                    .calmColumn(model.layout.isCalm)
                }
                .onChange(of: model.selectedThreadID) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id)
                }
                .onChange(of: model.selectionEnd) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id)
                }
                .onChange(of: model.homeScrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(Motion.quick) { proxy.scrollTo(target, anchor: .top) }
                    model.homeScrollTarget = nil
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ thread: MailThread) -> some View {
        if model.showsMinimalHome {
            MinimalRow(thread: thread, isSelected: thread.id == model.selectedThreadID, note: model.marginNote(for: thread))
                .id(thread.id)
                .onTapGesture { tap(thread) }
                .contextMenu { ThreadContextMenu(model: model, thread: thread) }
                .rowSwipe(model: model, thread: thread)
        } else {
            standardRow(thread)
        }
    }

    private func standardRow(_ thread: MailThread) -> some View {
        ThreadRow(
            thread: thread,
            isSelected: model.selection.isEmpty ? thread.id == model.selectedThreadID : model.selection.contains(thread.id),
            // No mailbox badge on rows: it was a letter that didn't match the mailbox's picture,
            // and the reader's header names the mailbox.
            account: nil,
            showsRecipients: model.place.isOutgoing || model.place == .waiting(account: model.place.accountID),
            // Home already sorts by what matters, so its rows leave the label chips out.
            labels: model.place.isHome ? [] : model.labels(for: thread),
            snoozedUntil: model.snoozedUntil(thread),
            compact: model.compactRows,
            isPinned: model.isPinned(thread),
            // Home's margin: why this conversation matters now. The margin only when the list
            // has room for it; a narrow list keeps the note on the subject line.
            marginNote: model.place.isHome && listWidth >= Self.marginWidth ? .some(model.marginNote(for: thread)) : nil,
            inlineNote: model.place.isHome && listWidth < Self.marginWidth ? model.marginNote(for: thread) : nil
        )
        .id(thread.id)
        .onTapGesture { tap(thread) }
        .contextMenu { ThreadContextMenu(model: model, thread: thread) }
        .rowSwipe(model: model, thread: thread)
        .rowHoverActions(model: model, thread: thread)
    }

    /// ⌘-click adds to the selection, ⇧-click selects a range, a plain click opens.
    private func tap(_ thread: MailThread) {
        #if os(macOS)
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) { model.toggleSelection(thread.id); model.focusRequest += 1; return }
        if flags.contains(.shift) { model.extendSelection(to: thread.id); model.focusRequest += 1; return }
        #endif
        model.selection = []
        model.select(thread.id)
        if model.opensOverList { model.isReaderOpen = true }
        model.focusRequest += 1
    }

    /// In combined views each row shows which mailbox it's in.
    private var showsAccounts: Bool { model.place.isCombined && model.accounts.count > 1 }
}

/// The row after the last conversation while the list can still grow. When it comes on screen
/// the list shows its next rows, or asks for older mail. It's made anew whenever the list has
/// grown, so staying on screen asks again.
struct ListEndRow: View {
    let model: MailModel
    let shown: Int

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .opacity(model.isLoadingOlder ? 1 : 0)
            .frame(maxWidth: .infinity)
            .frame(height: Look.gap(28))
            .accessibilityHidden(!model.isLoadingOlder)
            .onAppear { model.listReachedEnd() }
            .id("list-end-\(shown)-\(model.listCount)")
    }
}

/// Sender and date, subject, then a line of the message.
struct ThreadRow: View {
    let thread: MailThread
    let isSelected: Bool
    var account: MailAccount?
    /// In Sent and Drafts the row names the recipients instead of you.
    var showsRecipients = false
    var labels: [String] = []
    var snoozedUntil: Date?
    var compact = false
    var isPinned = false
    /// On Home: the note in the margin (outer nil: no margin at all; inner nil: an empty margin,
    /// so rows stay lined up).
    var marginNote: MarginNote?? = nil
    /// On Home in a narrow list: the note sits on the subject line instead of in a margin.
    var inlineNote: MarginNote? = nil
    @Environment(\.mailAccent) private var accent
    @State private var isHovered = false

    var body: some View {
        // A row can ask for sender, preview and count several times. Filter reaction notices
        // once per redraw rather than rescanning every message for each label while scrolling.
        let listed = MailReaction.withoutReactions(thread)
        let names = senders(in: listed)
        if let marginNote {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                MarginNoteLabel(note: marginNote)
                if compact { compactBody(listed, senders: names) } else { fullBody(listed, senders: names) }
            }
        } else if compact { compactBody(listed, senders: names) } else { fullBody(listed, senders: names) }
    }

    /// One line: sender, subject and preview, date.
    private func compactBody(_ listed: MailThread, senders: String) -> some View {
        let unread = thread.isUnread
        return HStack(spacing: 10) {
            Circle().fill(unread ? accent : .clear).frame(width: 6, height: 6)
            Text(senders)
                .font(unread ? TypeScale.rowStrong : TypeScale.row)
                .foregroundStyle(unread ? Ink.primary : Ink.secondary)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)
            Text("\(Text(thread.subject.isEmpty ? String(localized: "(No subject)") : thread.subject).foregroundStyle(unread ? Ink.primary : Ink.secondary))  \(Text(listed.latest.snippet).foregroundStyle(Ink.tertiary))")
                .font(TypeScale.row)
                .lineLimit(1)
            Spacer(minLength: Space.s)
            if isPinned { Image(systemName: "pin.fill").font(.system(size: Look.size(9))).foregroundStyle(Ink.tertiary) }
            if thread.isStarred { Image(systemName: "star.fill").font(.system(size: Look.size(10))).foregroundStyle(Status.star) }
            if let account { AccountMark(account, size: 12) }
            Text(snoozedUntil.map { $0.formatted(.dateTime.weekday(.abbreviated).hour().minute()) } ?? RowDate.string(thread.date))
                .font(TypeScale.label.monospacedDigit())
                .foregroundStyle(snoozedUntil == nil ? Ink.tertiary : Status.star)
        }
        .padding(.horizontal, 10)
        .frame(height: Look.gap(34))
        .background(isSelected ? Fill.two : (isHovered ? Fill.one : .clear), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
    }

    private func fullBody(_ listed: MailThread, senders: String) -> some View {
        let latest = listed.latest
        let unread = thread.isUnread
        return HStack(alignment: .top, spacing: 10) {
            Avatar(showsRecipients ? (latest.to.first ?? latest.from) : latest.from, size: Look.gap(28))
                .overlay(alignment: .topLeading) {
                    if unread {
                        Circle().fill(accent).frame(width: 10, height: 10)
                            .overlay(Circle().strokeBorder(Paper.panel, lineWidth: 2))
                            .offset(x: -3, y: -2)
                    }
                }
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(senders)
                        .font(unread ? TypeScale.rowStrong : TypeScale.row)
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    if listed.messages.count > 1 {
                        Text("\(listed.messages.count)").font(TypeScale.label.monospacedDigit()).foregroundStyle(Ink.tertiary)
                    }
                    Spacer(minLength: Space.xs)
                    if thread.hasAttachments {
                        Image(systemName: "paperclip").font(.system(size: Look.size(10.5))).foregroundStyle(Ink.tertiary)
                    }
                    if isPinned {
                        Image(systemName: "pin.fill").font(.system(size: Look.size(9))).foregroundStyle(Ink.tertiary).accessibilityLabel("Pinned")
                    }
                    if thread.isStarred {
                        Image(systemName: "star.fill").font(.system(size: Look.size(10))).foregroundStyle(Status.star)
                    }
                    if let snoozedUntil {
                        Label(snoozedUntil.formatted(.dateTime.weekday(.abbreviated).hour().minute()), systemImage: "clock")
                            .font(TypeScale.label.monospacedDigit())
                            .foregroundStyle(Status.star)
                    } else {
                        Text(RowDate.string(thread.date))
                            .font(TypeScale.label.monospacedDigit())
                            .foregroundStyle(Ink.tertiary)
                    }
                }
                HStack(spacing: 6) {
                    Text(thread.subject.isEmpty ? String(localized: "(No subject)") : thread.subject)
                        .font(unread ? TypeScale.rowStrong : TypeScale.row)
                        .foregroundStyle(unread ? Ink.primary : Ink.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let inlineNote {
                        Text(verbatim: inlineNote.text)
                            .font(TypeScale.label.weight(.medium).monospacedDigit())
                            .foregroundStyle(MarginNoteLabel.color(inlineNote.kind))
                            .lineLimit(1)
                            .fixedSize()
                    } else {
                        ForEach(labels.prefix(2), id: \.self) { LabelChip(text: $0, style: .compact) }
                    }
                    if let account { AccountMark(account, size: 12).tip(account.label) }
                }
                // No preview (some mail is only pictures): no empty line either.
                if !latest.snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(latest.snippet)
                        .font(TypeScale.row)
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        // A little tighter on a phone, where every row counts.
        #if os(iOS)
        .padding(.vertical, 7)
        #else
        .padding(.vertical, Look.gap(9))
        #endif
        .background(isSelected ? Fill.two : (isHovered ? Fill.one : .clear), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// One name, or the first names of everyone who wrote (or, in Sent, who it went to).
    private func senders(in listed: MailThread) -> String {
        if showsRecipients {
            let names = thread.latest.to.map(\.displayName)
            return names.isEmpty ? String(localized: "No recipients") : String(localized: "To \(names.joined(separator: ", "))")
        }
        let people = listed.participants
        guard people.count > 1 else { return people.first?.displayName ?? "" }
        return people.map { $0.displayName.split(separator: " ").first.map(String.init) ?? $0.displayName }
            .joined(separator: ", ")
    }
}

/// The list while its mail is still on the way, so it never reads as empty.
struct LoadingMessage: View {
    var body: some View {
        VStack(spacing: Space.s) {
            ProgressView().controlSize(.small)
            Text("Downloading mail…").font(TypeScale.row).foregroundStyle(Ink.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ListMessage: View {
    let title: LocalizedStringKey
    let detail: Text?
    let action: (LocalizedStringKey, () -> Void)?

    init(title: LocalizedStringKey, detail: LocalizedStringKey?, action: (LocalizedStringKey, () -> Void)?) {
        self.title = title
        self.detail = detail.map { Text($0) }
        self.action = action
    }

    /// Detail text that is already written for the person, such as an error message.
    init(title: LocalizedStringKey, verbatimDetail: String, action: (LocalizedStringKey, () -> Void)?) {
        self.title = title
        self.detail = Text(verbatim: verbatimDetail)
        self.action = action
    }

    var body: some View {
        VStack(spacing: Space.s) {
            Text(title).font(TypeScale.rowStrong).foregroundStyle(Ink.secondary)
            if let detail {
                detail.font(TypeScale.row).foregroundStyle(Ink.tertiary).multilineTextAlignment(.center)
            }
            if let action {
                Button(action.0, action: action.1).buttonStyle(QuietButtonStyle()).padding(.top, Space.xs)
            }
        }
        .padding(Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Unread / Starred / Attachments, toggled over the list.
/// Unread, Starred and Attachments as small toggles at the end of the search field.
struct QuickFilterToggles: View {
    @Bindable var model: MailModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(QuickFilter.allCases, id: \.self) { filter in
                let isOn = model.quickFilters.contains(filter)
                Button {
                    withAnimation(Motion.quick) {
                        if isOn { model.quickFilters.remove(filter) } else { model.quickFilters.insert(filter) }
                    }
                } label: {
                    Image(systemName: isOn ? filter.symbol + ".fill" : filter.symbol)
                        .font(.system(size: Look.size(11), weight: .medium))
                        .foregroundStyle(isOn ? Ink.inverse : Ink.tertiary)
                        .frame(width: 24, height: 22)
                        .background(isOn ? Ink.primary : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tip(Text(filter.title))
                .accessibilityLabel(Text(filter.title))
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }
}

/// "3 selected · Clear", shown while conversations are selected.
struct SelectionBar: View {
    @Bindable var model: MailModel

    var body: some View {
        HStack(spacing: 6) {
            Text("\(model.selection.count) selected").font(TypeScale.label).foregroundStyle(Ink.tertiary)
            Button("Clear") { model.selection = [] }.buttonStyle(.plain).font(TypeScale.label.weight(.medium))
            Spacer()
        }
    }
}

/// Messages waiting to be sent later.
struct OutboxList: View {
    let model: MailModel

    var body: some View {
        if model.outbox.isEmpty {
            ListMessage(title: "Nothing scheduled", detail: "Use Send later in a message to schedule it.", action: nil)
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.outbox) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("To \(item.draft.to.map(\.displayName).joined(separator: ", "))")
                                    .font(TypeScale.rowStrong).foregroundStyle(Ink.primary).lineLimit(1)
                                Spacer()
                                if item.waitsForConnection {
                                    Label("Waiting for a connection", systemImage: "wifi.slash")
                                        .font(TypeScale.label).foregroundStyle(Ink.tertiary)
                                } else {
                                    Label(item.sendAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()), systemImage: "clock")
                                        .font(TypeScale.label).foregroundStyle(Ink.tertiary)
                                }
                            }
                            Text(item.draft.subject.isEmpty ? String(localized: "(No subject)") : item.draft.subject).font(TypeScale.row).foregroundStyle(Ink.secondary).lineLimit(1)
                            HStack(spacing: Space.m) {
                                TextAction(title: "Send now", symbol: "paperplane", key: nil) { model.sendScheduledNow(item.id) }
                                TextAction(title: "Edit", symbol: "pencil", key: nil) { model.editScheduled(item.id) }
                                TextAction(title: "Cancel", symbol: "xmark", key: nil) { model.cancelScheduled(item.id) }
                            }
                            .padding(.top, 2)
                        }
                        .padding(10)
                        .background(Fill.one, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .padding(.horizontal, 6)
            }
        }
    }
}

/// Right-click on a conversation: answer it, handle it, file it.
struct ThreadContextMenu: View {
    let model: MailModel
    let thread: MailThread

    var body: some View {
        Button { open { model.startReply() } } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
        if thread.participants.count > 2 {
            Button { open { model.startReply(all: true) } } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }
        }
        Button { open { model.startForward() } } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
        Divider()
        Button { model.perform(.done, on: thread) } label: { Label("Done", systemImage: "checkmark.circle") }
        Button { model.perform(thread.isUnread ? .markRead : .markUnread, on: thread) } label: {
            Label(thread.isUnread ? "Mark read" : "Mark unread", systemImage: thread.isUnread ? "envelope.open" : "envelope.badge")
        }
        Button { model.perform(thread.isStarred ? .unstar : .star, on: thread) } label: {
            Label(thread.isStarred ? "Remove star" : "Star", systemImage: thread.isStarred ? "star.slash" : "star")
        }
        Button { model.togglePin(thread) } label: {
            Label(model.isPinned(thread) ? "Unpin" : "Pin to top", systemImage: model.isPinned(thread) ? "pin.slash" : "pin")
        }
        Menu {
            ForEach(SnoozePreset.allCases, id: \.self) { preset in
                Button(preset.title) { model.snooze(thread, until: preset.date()) }
            }
        } label: { Label("Snooze", systemImage: "clock") }
        Divider()
        Menu {
            let current = model.group(of: thread)
            ForEach(model.emailGroups) { group in
                Button { model.move(thread, toGroup: group) } label: {
                    if current?.name == group.name { Label(group.name, systemImage: "checkmark") } else { Text(verbatim: group.name) }
                }
            }
            if current != nil {
                Divider()
                Button("Not in a group") { model.move(thread, toGroup: nil) }
            }
        } label: { Label("Move to group", systemImage: "square.grid.2x2") }
        if model.unsubscribeMethod(for: thread) != nil {
            Button { model.unsubscribe(thread) } label: { Label("Unsubscribe", systemImage: "xmark.circle") }
        }
        Button { model.startRule(for: thread) } label: { Label("Create Rule…", systemImage: "line.3.horizontal.decrease.circle") }
        Divider()
        Button(role: .destructive) { model.perform(.trash, on: thread) } label: { Label("Move to Trash", systemImage: "trash") }
    }

    /// Opens the conversation, then writes in it.
    private func open(_ write: @escaping () -> Void) {
        model.selection = []
        model.select(thread.id)
        if model.opensOverList { model.isReaderOpen = true }
        write()
    }
}

/// The note in Home's left margin, right-aligned against a thin rule, like a note pencilled
/// beside a line. Empty notes keep the margin so rows line up.
struct MarginNoteLabel: View {
    let note: MarginNote?
    static let width: CGFloat = 72

    var body: some View {
        Text(verbatim: note?.text ?? " ")
            .font(TypeScale.label.weight(.medium).monospacedDigit())
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(width: Self.width, alignment: .trailing)
            .padding(.trailing, 10)
            .overlay(alignment: .trailing) { Rectangle().fill(Line.hairline).frame(width: 1).padding(.vertical, -10) }
            .accessibilityHidden(note == nil)
    }

    private var color: Color { note.map { Self.color($0.kind) } ?? .clear }

    static func color(_ kind: MarginNote.Kind) -> Color {
        switch kind {
        case .reply: Palette.accent
        case .meeting: Status.done
        case .bill: Status.star
        case .code: Ink.secondary
        }
    }
}
