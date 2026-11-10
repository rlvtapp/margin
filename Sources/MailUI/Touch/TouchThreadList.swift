#if os(iOS)
import MailCore
import SwiftUI

/// The second column: the conversations in one place. Swipe right for Done, left for
/// Trash or Snooze; press and hold for everything else.
struct TouchThreadList: View {
    @Bindable var model: MailModel
    @State private var snoozing: MailThread?
    /// Counts swipes and taps that deserve a small tap of feedback.
    @State private var feedback = 0
    @State private var isSearching = false
    @Environment(\.barsOnSide) private var barsOnSide

    var body: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    NextEventBar(model: model).padding(.top, Space.xs)
                    if model.layout == .spark {
                        SparkHeader(model: model).padding(.horizontal, Space.m).padding(.bottom, Space.s)
                    } else if model.place.isHome {
                        // In the calm layouts the header leaves its own edge to the column; give
                        // it the same inset as the rows, as on the Mac.
                        HomeHeader(model: model).padding(.horizontal, model.layout.isCalm ? Space.m : 0)
                    }
                }
                .background(Paper.panel)
            }
            .background(Paper.panel)
            .navigationTitle(model.title)
            // The title and the count ride in the bar beside its buttons, so the list starts
            // right under it instead of below a title of its own.
            .modifier(BarSubtitle(text: summary))
            .navigationBarTitleDisplayMode(.inline)
            // Search sits behind a button, so the list gets the room; the field shows while searching.
            .modifier(TouchSearch(model: model, isOn: $isSearching))
            .toolbar {
                // Where iOS would stack them in a column on the side (the folded iPhone Duo),
                // the buttons go to the bottom instead, where a thumb reaches them.
                if barsOnSide {
                    ToolbarItemGroup(placement: .bottomBar) {
                        if model.place != .subscriptions {
                            Button { withAnimation(Motion.quick) { isSearching = true } } label: { Label("Search", systemImage: "magnifyingglass") }
                            filterMenu
                        }
                        Spacer()
                        Button { model.startCompose() } label: { Label("New message", systemImage: "square.and.pencil") }
                    }
                } else {
                    if model.place != .subscriptions {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { withAnimation(Motion.quick) { isSearching = true } } label: { Label("Search", systemImage: "magnifyingglass") }
                        }
                        ToolbarItem(placement: .topBarTrailing) { filterMenu }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { model.startCompose() } label: { Label("New message", systemImage: "square.and.pencil") }
                    }
                    if #available(iOS 26, *) {
                        statusItem.sharedBackgroundVisibility(.hidden)
                    } else {
                        statusItem
                    }
                }
            }
            .toolbar(barsOnSide || !model.statusLine(now: Date()).trimmingCharacters(in: .whitespaces).isEmpty ? .visible : .hidden, for: .bottomBar)
            .confirmationDialog("Snooze until", isPresented: Binding(get: { snoozing != nil }, set: { if !$0 { snoozing = nil } }), presenting: snoozing) { thread in
                ForEach(SnoozePreset.allCases, id: \.self) { preset in
                    let date = preset.date()
                    Button {
                        model.snooze(thread, until: date)
                    } label: {
                        Text(verbatim: "\(preset.title) · \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                    }
                }
            }
    }

    private var hasListHeader: Bool {
        !BarSubtitle.isSupported || model.split != nil || !model.quickFilters.isEmpty
    }

    /// "15 conversations, 9 unread"
    private var summary: String {
        if case .search = model.place, model.isSearchingServers {
            return String(localized: "\(model.visibleThreads.count) found so far · searching servers…")
        }
        let threads = model.visibleThreads
        let unread = threads.filter(\.isUnread).count
        let count = threads.count == 1 ? String(localized: "1 conversation") : String(localized: "\(threads.count) conversations")
        return unread > 0 ? String(localized: "\(count), \(unread) unread", comment: "Conversation count, then how many are unread") : count
    }

    /// "Updated just now" at the foot of the list, as plain text rather than a button.
    private var statusItem: some ToolbarContent {
        ToolbarItem(placement: .status) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(model.statusLine(now: context.date))
                    .font(TypeScale.caption)
                    .foregroundStyle(Ink.tertiary)
                    .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let threads = model.visibleThreads
        if model.place == .scheduled {
            OutboxList(model: model)
        } else if model.place == .subscriptions {
            SubscriptionsPage(model: model, showsTitle: true)
        } else {
            List(selection: Binding(get: { model.selectedThreadID }, set: { model.select($0) })) {
                // Home leads with what needs you, then the rest by day; other places are one list.
                let sections = model.listSections(threads) ?? [ListSection(id: "all", title: "", threads: threads)]
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                Section {
                    ForEach(section.threads) { thread in
                        row(thread)
                    }
                    // Another part of the inbox replaces the list at once; only cleared rows slide out.
                    .transaction(value: model.place) { $0.animation = nil }
                } header: {
                    VStack(alignment: .leading, spacing: 0) {
                    // Nothing to show (Home has its own header above): no empty band either.
                    if index == 0 && hasListHeader {
                    VStack(alignment: .leading, spacing: Space.s) {
                        // Before iOS 26 the bar has no subtitle, so the count stays here.
                        if !BarSubtitle.isSupported {
                            Text(summary).font(TypeScale.label).foregroundStyle(Ink.tertiary)
                                .contentTransition(.numericText())
                        }
                        if case .some(let split) = model.split { splitTabs(split) }
                        if !model.quickFilters.isEmpty { activeFilters }
                        if model.split == .some(.newsletters) { NewsletterSuggestionCard(model: model) }
                    }
                    .padding(.horizontal, Space.s)
                    .padding(.top, Space.xs)
                    .padding(.bottom, Space.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Paper.panel)
                    .listRowInsets(EdgeInsets(top: 0, leading: Space.s, bottom: 0, trailing: Space.s))
                    }
                    if !section.title.isEmpty {
                        ListSectionHeader(section: section)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    }
                    .background(Paper.panel)
                    .listRowInsets(EdgeInsets(top: 0, leading: Space.s, bottom: 0, trailing: Space.s))
                }
                .listSectionSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await model.reload() }
            .overlay { if threads.isEmpty { emptyMessage } }
            // Rows slide out when they're done, trashed or snoozed.
            .animation(Motion.present, value: threads.map(\.id))
            .sensoryFeedback(.impact(weight: .light), trigger: feedback)
        }
    }

    private func row(_ thread: MailThread) -> some View {
        ThreadRow(
            thread: thread,
            isSelected: thread.id == model.selectedThreadID,
            account: model.place.isCombined && model.accounts.count > 1 ? model.account(thread.accountID) : nil,
            showsRecipients: model.place.isOutgoing || model.place == .waiting(account: model.place.accountID),
            labels: model.place.isHome ? [] : model.labels(for: thread),
            snoozedUntil: model.snoozedUntil(thread),
            compact: model.compactRows,
            isPinned: model.isPinned(thread)
        )
        .tag(thread.id)
        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        // Which actions sit behind each swipe is set in Settings → Swipes.
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            ForEach(model.leadingSwipes.filter { $0 != .none }) { swipeButton($0, thread) }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            ForEach(model.trailingSwipes.filter { $0 != .none }) { swipeButton($0, thread) }
        }
        .contextMenu {
            Button { model.togglePin(thread) } label: {
                Label(model.isPinned(thread) ? "Unpin" : "Pin to top", systemImage: model.isPinned(thread) ? "pin.slash" : "pin")
            }
            Button { model.perform(.done, on: thread) } label: { Label("Done", systemImage: "checkmark.circle") }
            Button { model.perform(thread.isStarred ? .unstar : .star, on: thread) } label: {
                Label(thread.isStarred ? "Remove star" : "Star", systemImage: thread.isStarred ? "star.slash" : "star")
            }
            Button { model.perform(thread.isUnread ? .markRead : .markUnread, on: thread) } label: {
                Label(thread.isUnread ? "Mark read" : "Mark unread", systemImage: thread.isUnread ? "envelope.open" : "envelope.badge")
            }
            Button { snoozing = thread } label: { Label("Snooze…", systemImage: "clock") }
            Divider()
            Button(role: .destructive) { model.perform(.trash, on: thread) } label: { Label("Move to Trash", systemImage: "trash") }
        }
    }

    @ViewBuilder
    private func swipeButton(_ action: SwipeAction, _ thread: MailThread) -> some View {
        switch action {
        case .done:
            Button { act(.done, on: thread) } label: { Label("Done", systemImage: "checkmark") }.tint(Status.done)
        case .star:
            Button { act(thread.isStarred ? .unstar : .star, on: thread) } label: {
                Label(thread.isStarred ? "Unstar" : "Star", systemImage: thread.isStarred ? "star.slash.fill" : "star.fill")
            }
            .tint(Status.star)
        case .read:
            Button { act(thread.isUnread ? .markRead : .markUnread, on: thread) } label: {
                Label(thread.isUnread ? "Read" : "Unread", systemImage: thread.isUnread ? "envelope.open.fill" : "envelope.badge.fill")
            }
            .tint(Palette.split(.people))
        case .snooze:
            Button { snoozing = thread } label: { Label("Snooze", systemImage: "clock") }.tint(Ink.secondary)
        case .trash:
            Button(role: .destructive) { act(.trash, on: thread) } label: { Label("Trash", systemImage: "trash") }
        case .none:
            EmptyView()
        }
    }

    /// Done and Trash are felt through their notice (see TouchMailView); a star has none, so it taps here.
    private func act(_ action: MailAction, on thread: MailThread) {
        if action == .star || action == .unstar { feedback += 1 }
        model.perform(action, on: thread)
    }

    @ViewBuilder
    private var emptyMessage: some View {
        if let error = model.place.accountID.flatMap({ model.loadErrors[$0] }) {
            ListMessage(title: "Couldn't load mail", verbatimDetail: error, action: ("Try Again", { Task { await model.reload() } }))
        } else if model.isListLoading {
            LoadingMessage()
        } else if !model.searchText.isEmpty {
            ListMessage(title: "No results", detail: "Try from:, is:unread or has:attachment.", action: nil)
        } else if !model.quickFilters.isEmpty {
            ListMessage(title: "Nothing matches", detail: nil, action: ("Clear filters", { model.quickFilters = [] }))
        } else if model.split != nil {
            InboxZero(split: model.split ?? nil)
        } else {
            ListMessage(title: "Nothing here", detail: nil, action: nil)
        }
    }

    /// All, People, Updates and Newsletters as glass tabs a thumb can hit.
    private func splitTabs(_ current: InboxSplit?) -> some View {
        let accountID = model.place.accountID
        return ScrollView(.horizontal, showsIndicators: false) {
            GlassChipRow(spacing: Space.s) {
                Button { withAnimation(Motion.present) { model.go(to: .inbox(account: accountID, split: nil)) } } label: {
                    GlassChip(Text("All"), symbol: current == nil ? "tray.fill" : "tray", color: Ink.primary,
                              count: model.unreadCount(account: accountID), isOn: current == nil, size: .regular)
                }
                .buttonStyle(.plain)
                ForEach(InboxSplit.allCases, id: \.self) { split in
                    Button { withAnimation(Motion.present) { model.go(to: .inbox(account: accountID, split: split)) } } label: {
                        GlassChip(Text(split.title), symbol: Self.symbol(split) + (current == split ? ".fill" : ""), color: Palette.split(split),
                                  tint: Palette.deep(split), count: model.unreadCount(account: accountID, split: split),
                                  isOn: current == split, size: .regular)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
        .sensoryFeedback(.selection, trigger: current)
    }

    static func symbol(_ split: InboxSplit) -> String {
        switch split {
        case .people: "person.2"
        case .updates: "bell"
        case .newsletters: "newspaper"
        }
    }

    /// The filters that are on, each with a way to take it off.
    private var activeFilters: some View {
        GlassChipRow {
            ForEach(QuickFilter.allCases.filter { model.quickFilters.contains($0) }, id: \.self) { filter in
                Button {
                    withAnimation(Motion.quick) { _ = model.quickFilters.remove(filter) }
                } label: {
                    GlassChip(Text(filter.title), symbol: "xmark", isOn: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(filter.title) filter")
            }
        }
    }

    /// Unread, Starred and With attachments, in the filter button.
    private var filterMenu: some View {
        Menu {
            ForEach(QuickFilter.allCases, id: \.self) { filter in
                Toggle(isOn: Binding(
                    get: { model.quickFilters.contains(filter) },
                    set: { on in
                        withAnimation(Motion.quick) {
                            if on { model.quickFilters.insert(filter) } else { model.quickFilters.remove(filter) }
                        }
                    }
                )) {
                    Label(filter == .attachments ? String(localized: "With attachments") : filter.title, systemImage: Self.symbol(filter))
                }
            }
            if !model.quickFilters.isEmpty {
                Divider()
                Button("Clear filters") { withAnimation(Motion.quick) { model.quickFilters = [] } }
            }
        } label: {
            Label("Filter", systemImage: model.quickFilters.isEmpty
                  ? "line.3.horizontal.decrease"
                  : "line.3.horizontal.decrease.circle.fill")
        }
    }

    static func symbol(_ filter: QuickFilter) -> String {
        switch filter {
        case .unread: "envelope.badge"
        case .starred: "star"
        case .attachments: "paperclip"
        }
    }
}

/// When a part of the inbox is empty: a moment of calm instead of a blank list.
private struct InboxZero: View {
    let split: InboxSplit?
    @State private var appeared = false

    var body: some View {
        VStack(spacing: Space.m) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(Status.done)
                .symbolEffect(.bounce, value: appeared)
                .scaleEffect(appeared || Look.reduceMotion ? 1 : 0.6)
                .opacity(appeared ? 1 : 0)
            Text(split == nil ? "Inbox zero" : "Nothing in \(split?.title ?? "")")
                .font(TypeScale.title)
                .foregroundStyle(Ink.primary)
            Text(split == nil ? "Everything's handled. Enjoy the quiet." : "You're all caught up here.")
                .font(TypeScale.row)
                .foregroundStyle(Ink.tertiary)
        }
        .padding(Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { withAnimation(Motion.present) { appeared = true } }
        .sensoryFeedback(.success, trigger: appeared)
    }
}
/// Shows the search field only while searching; Cancel or an empty field puts it away.
private struct TouchSearch: ViewModifier {
    @Bindable var model: MailModel
    @Binding var isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content
                .searchable(text: $model.searchText, isPresented: $isOn, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
                // Return searches everything: saved mail now, then every server.
                .onSubmit(of: .search) { model.runSearch(model.searchText) }
                .onChange(of: isOn) { _, on in if !on { model.searchText = "" } }
        } else {
            content
        }
    }
}


/// The count under the bar's title, where iOS 26 has room for a subtitle.
struct BarSubtitle: ViewModifier {
    let text: String

    static var isSupported: Bool {
        if #available(iOS 26, *) { return true }
        return false
    }

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            // A firm edge under the bar: rows scrolling up don't show through behind its
            // buttons and the tabs pinned below it.
            content.navigationSubtitle(text).scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            content
        }
    }
}
#endif
