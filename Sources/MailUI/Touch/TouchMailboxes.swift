#if os(iOS)
import MailCore
import SwiftUI

/// The first column, drawn like the Mac's rail and sidebar: a row of mailboxes at the top
/// (all of them together, then each one), and under it the places and folders of the one
/// picked.
struct TouchMailboxes: View {
    @Bindable var model: MailModel
    @Binding var isShowingSettings: Bool
    /// iPhone: one column at a time. iPad: the list sits beside this column. (A column's own
    /// size class is compact either way, so the whole window's is passed in.)
    var isStacked = true
    /// Which mailbox the folders below belong to; nil is all of them together.
    @State private var scope: UUID?
    /// Kept here rather than read from the model: on iPhone, going back clears the selection,
    /// and tapping the same place again has to count as a change to open it.
    @State private var selected: Place?

    var body: some View {
        List(selection: Binding(get: { selected }, set: { place in
            selected = place
            if let place { model.go(to: place) }
        })) {
            rail
                .listRowInsets(EdgeInsets(top: Space.s, leading: Space.l, bottom: Space.s, trailing: Space.l))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .selectionDisabled()
            header
                .listRowInsets(EdgeInsets(top: Space.m, leading: Space.l, bottom: Space.s, trailing: Space.l))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .selectionDisabled()
            row(String(localized: "Inbox"), symbol: "tray", count: model.unreadCount(account: scope), place: .inbox(account: scope, split: nil))
            row(String(localized: "Starred"), symbol: "star", count: nil, place: .starred(account: scope))
            if !model.vipAddresses.isEmpty {
                row(String(localized: "VIPs"), symbol: "star.circle", count: model.vipThreads(scope).filter(\.isUnread).count, place: .vips(account: scope))
            }
            row(String(localized: "Snoozed"), symbol: "clock", count: model.snoozedInInboxes(scope).count,
                place: .snoozed(account: scope))
            row(String(localized: "Waiting for reply"), symbol: "arrowshape.turn.up.backward.badge.clock",
                count: scope == nil ? model.waitingCount : nil, place: .waiting(account: scope))
            if !model.outbox.isEmpty {
                row(String(localized: "Scheduled"), symbol: "paperplane.circle", count: model.outbox.count, place: .scheduled)
            }
            if let scope {
                let folders = model.folders(of: scope).filter { $0.role != .inbox }
                let standard = folders.filter { $0.role != .other }
                let own = model.ownFolders(of: scope)
                ForEach(standard) { row($0.name, symbol: SidebarView.symbol($0.role), count: nil, place: .mailbox(account: scope, $0)) }
                if !own.isEmpty {
                    sectionTitle("Folders")
                    ForEach(own, id: \.mailbox.id) { item in
                        row(item.mailbox.name, symbol: SidebarView.symbol(item.mailbox.role), count: nil,
                            place: .mailbox(account: scope, item.mailbox), depth: item.depth)
                    }
                }
            } else {
                ForEach(model.combinedRoles, id: \.self) { role in
                    row(role.title, symbol: SidebarView.symbol(role), count: nil, place: .combined(role))
                }
            }
            if !model.allLabels.isEmpty {
                sectionTitle("Labels")
                let counts = model.labelCounts
                ForEach(model.allLabels, id: \.self) { label in
                    row(label, symbol: "tag", count: counts[label], place: .home(group: label))
                }
            }
            // Not part of any one mailbox: every newsletter, from all of them together.
            Rectangle().fill(Line.hairline).frame(height: 1)
                .listRowInsets(EdgeInsets(top: Space.m, leading: Space.l + 4, bottom: Space.m, trailing: Space.l + 4))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .selectionDisabled()
            row(String(localized: "Home"), symbol: "house", count: nil, place: .home(group: nil))
            row(String(localized: "Calendar"), symbol: "calendar", count: nil, place: .calendar)
            let rarely = model.newsletterSuggestions.count
            row(String(localized: "Subscriptions"), symbol: "newspaper", count: rarely > 0 ? rarely : nil, place: .subscriptions)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Paper.sidebar)
        .environment(\.defaultMinListRowHeight, 40)
        .navigationTitle("Mailboxes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The title is the header in the list; the bar keeps only its buttons.
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
            ToolbarItem(placement: .topBarLeading) {
                Button { isShowingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
            }
            // On iPad the list beside this column already has these.
            if isStacked {
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
        // The status line ("Updated 10 minutes ago") sits in the bottom bar; with nothing to say,
        // no empty bar is left behind.
        .toolbar(model.statusLine(now: Date()).trimmingCharacters(in: .whitespaces).isEmpty ? .hidden : .visible, for: .bottomBar)
        .onAppear {
            scope = model.place.accountID
            // On iPad, highlight where the list is. Not on iPhone: a selection there opens the list again.
            if selected == nil, !isStacked { selected = Self.normalized(model.place) }
        }
    }

    /// All mailboxes, then each one, as round marks; the picked one has a ring.
    private var rail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.m) {
                railButton(isOn: scope == nil, label: String(localized: "All inboxes")) {
                    Image(systemName: "tray.2")
                        .font(.system(size: Look.size(15)))
                        .foregroundStyle(Ink.secondary)
                        .frame(width: 38, height: 38)
                        .background(Fill.two, in: Circle())
                } action: { pick(nil) }
                ForEach(model.workspaceAccounts) { account in
                    railButton(isOn: scope == account.id, label: account.label) {
                        AccountAvatar(account: account, size: 38)
                    } action: { pick(account.id) }
                    .contextMenu {
                        Button { withAnimation(Motion.quick) { model.moveAccount(account.id, by: -1) } } label: {
                            Label("Move Up", systemImage: "arrow.up")
                        }
                        .disabled(!model.canMoveAccount(account.id, by: -1))
                        Button { withAnimation(Motion.quick) { model.moveAccount(account.id, by: 1) } } label: {
                            Label("Move Down", systemImage: "arrow.down")
                        }
                        .disabled(!model.canMoveAccount(account.id, by: 1))
                    }
                }
                Button { model.isAddingAccount = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: Look.size(14), weight: .medium))
                        .foregroundStyle(Ink.tertiary)
                        .frame(width: 38, height: 38)
                        .overlay(Circle().strokeBorder(Line.edge, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add mailbox")
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
        }
    }

    private func railButton<Mark: View>(isOn: Bool, label: String, @ViewBuilder mark: () -> Mark, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            mark()
                .overlay(Circle().strokeBorder(Ink.primary, lineWidth: 2).padding(-4).opacity(isOn ? 1 : 0))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// Whose folders these are, as on the Mac sidebar.
    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let account = model.account(scope) {
                Text(account.address.name ?? account.label).font(TypeScale.title).foregroundStyle(Ink.primary)
                Text(account.address.address).font(TypeScale.label).foregroundStyle(Ink.tertiary)
            } else {
                // The workspace in view, opening the workspace menu.
                WorkspaceHeader(model: model)
            }
        }
        .lineLimit(1)
    }

    /// `title` is already translated, or a folder name from the server.
    private func row(_ title: String, symbol: String, count: Int?, place: Place, depth: Int = 0) -> some View {
        let isOn = selected == place
        return HStack(spacing: Space.m) {
            Image(systemName: symbol)
                .font(.system(size: Look.size(15)))
                .foregroundStyle(isOn ? Ink.primary : Ink.tertiary)
                .frame(width: 22)
            Text(title)
                .font(isOn ? TypeScale.rowStrong : TypeScale.row)
                .foregroundStyle(isOn ? Ink.primary : Ink.secondary)
                .lineLimit(1)
            Spacer(minLength: Space.xs)
            if let count, count > 0 {
                Text("\(count)").font(TypeScale.label.monospacedDigit()).foregroundStyle(Ink.tertiary)
            }
        }
        .tag(place)
        .listRowInsets(EdgeInsets(top: 0, leading: Space.l + 4 + CGFloat(depth) * 18, bottom: 0, trailing: Space.l + 4))
        .listRowSeparator(.hidden)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isOn ? Fill.two : .clear)
                .padding(.horizontal, Space.s)
        )
    }

    private func sectionTitle(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(TypeScale.label.weight(.medium))
            .foregroundStyle(Ink.tertiary)
            .listRowInsets(EdgeInsets(top: Space.l, leading: Space.l + 4, bottom: Space.xs, trailing: Space.l))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .selectionDisabled()
    }

    private var statusItem: some ToolbarContent {
        ToolbarItem(placement: .status) {
            StatusLine(model: model).fixedSize()
        }
    }

    private func pick(_ account: UUID?) {
        withAnimation(Motion.quick) { scope = account }
    }

    /// The inbox row stands for every part of the inbox.
    static func normalized(_ place: Place) -> Place {
        if case .inbox(let account, _) = place { return .inbox(account: account, split: nil) }
        return place
    }
}
#endif
