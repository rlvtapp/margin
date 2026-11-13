import MailCore
import SwiftUI

/// Whatever the rail picked: one mailbox and its folders, or all mailboxes together.
struct SidebarView: View {
    @Bindable var model: MailModel
    @State private var naming: FolderNaming?
    @State private var deleting: FolderNaming?
    @State private var folderName = ""
    @State private var showsHidden = false
    /// Folded sidebar sections, and folders opened to show the folders inside them (they
    /// start folded, so long folder trees stay out of the way).
    @AppStorage("sidebarFolded") private var foldedSections = ""
    @AppStorage("sidebarOpenFolders") private var openFolders = ""

    private var scope: UUID? { model.place.accountID }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The window buttons live in the bar above now, so the header needs no room for them.
            header
                .padding(.top, Space.m)
                .padding(.horizontal, 14)
            // Asking about your mail lives in the command palette (⌘K, or Q).
            HStack(spacing: Space.s) {
                ComposeButton { model.startCompose() }
            }
                .padding(.horizontal, 10)
                .padding(.top, Space.m)
                .padding(.bottom, Space.s)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    // The account column is hidden: its places and mailboxes are here instead.
                    if !model.showsAccountRail { SidebarMailboxes(model: model) }
                    SidebarRow(
                        title: "Inbox", symbol: "tray", count: model.unreadCount(account: scope),
                        isSelected: model.place.accountID == scope && model.split != nil
                    ) { model.go(to: .inbox(account: scope, split: nil)) }
                    SidebarRow(
                        title: "Starred", symbol: "star", count: nil,
                        isSelected: model.place == .starred(account: scope)
                    ) { model.go(to: .starred(account: scope)) }
                    if !model.vipAddresses.isEmpty {
                        SidebarRow(
                            title: "VIPs", symbol: "star.circle", count: model.vipThreads(scope).filter(\.isUnread).count,
                            isSelected: model.place == .vips(account: scope)
                        ) { model.go(to: .vips(account: scope)) }
                    }
                    SidebarRow(
                        title: "Snoozed", symbol: "clock", count: model.snoozedInInboxes(scope).count,
                        isSelected: model.place == .snoozed(account: scope)
                    ) { model.go(to: .snoozed(account: scope)) }
                    SidebarRow(
                        title: "Waiting for reply", symbol: "arrowshape.turn.up.backward.badge.clock",
                        count: scope == nil ? model.waitingCount : nil,
                        isSelected: model.place == .waiting(account: scope)
                    ) { model.go(to: .waiting(account: scope)) }
                    if !model.outbox.isEmpty {
                        SidebarRow(title: "Scheduled", symbol: "paperplane.circle", count: model.outbox.count,
                                   isSelected: model.place == .scheduled) { model.go(to: .scheduled) }
                    }
                    // Mailboxes themselves are in the rail on the left; here only their folders.
                    if let scope { folders(scope) } else { combinedFolders }
                    labelsSection
                    // Not part of any one mailbox: every newsletter, from all of them together.
                    // Home and the Calendar are in the rail on the left, so they aren't repeated here.
                    Rectangle().fill(Line.hairline).frame(height: 1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, Space.m)
                    let rarely = model.newsletterSuggestions.count
                    SidebarRow(title: "Subscriptions", symbol: "newspaper", count: rarely > 0 ? rarely : nil,
                               isSelected: model.place == .subscriptions) { model.go(to: .subscriptions) }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, Space.l)
            }
            footer
        }
        .alert(naming?.mailbox == nil ? "New folder" : "Rename folder", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $folderName)
            Button("Cancel", role: .cancel) { naming = nil }
            Button(naming?.mailbox == nil ? "Create" : "Rename") {
                if let naming, !folderName.trimmingCharacters(in: .whitespaces).isEmpty {
                    if let mailbox = naming.mailbox {
                        model.renameFolder(mailbox, in: naming.accountID, to: folderName)
                    } else {
                        model.createFolder(named: folderName, in: naming.accountID)
                    }
                }
                naming = nil
            }
        }
        .onChange(of: naming) { _, value in folderName = value?.mailbox?.name ?? "" }
        .alert("Delete “\(deleting?.mailbox?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                if let deleting, let mailbox = deleting.mailbox { model.deleteFolder(mailbox, in: deleting.accountID) }
                deleting = nil
            }
        } message: {
            Text("The folder is removed on the server. Mail that's only in it goes too.")
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            if let account = model.account(scope) {
                AccountAvatar(account: account, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.address.name ?? account.label).font(TypeScale.rowStrong).foregroundStyle(Ink.primary)
                    Text(account.address.address).font(TypeScale.caption).foregroundStyle(Ink.tertiary)
                }
                .lineLimit(1)
            } else {
                WorkspaceHeader(model: model)
            }
            Spacer(minLength: 0)
        }
    }

    /// One mailbox's folders: the standard ones first, then the person's own.
    @ViewBuilder
    private func folders(_ accountID: UUID) -> some View {
        let all = model.folders(of: accountID)
        let standard = all.filter { $0.role != .other }
        let own = model.ownFolders(of: accountID, includingHidden: showsHidden)
        let hiddenCount = model.hiddenFolders(of: accountID).count
        ForEach(standard) { folderRow($0, accountID) }
        HStack {
            foldTitle("Folders", key: "folders")
            Spacer()
            Button { naming = FolderNaming(accountID: accountID, mailbox: nil) } label: {
                Image(systemName: "plus").font(.system(size: Look.size(10), weight: .semibold)).foregroundStyle(Ink.tertiary)
            }
            .buttonStyle(.plain)
            .padding(.top, Space.l)
            .padding(.trailing, 8)
            .tip("New folder")
        }
        // Folders inside others are indented under them. Drag a folder onto another to put it
        // before that one.
        let shown = isFolded("folders") ? [] : visibleFolders(own)
        ForEach(shown, id: \.item.mailbox.id) { entry in
            let item = entry.item
            let mailbox = item.mailbox
            let hidden = model.isHidden(mailbox, in: accountID)
            folderRow(mailbox, accountID)
                .padding(.leading, CGFloat(item.depth) * 14)
                .overlay(alignment: .trailing) {
                    if entry.hasChildren {
                        Button { toggleFolder(mailbox.id) } label: {
                            Image(systemName: isOpen(mailbox.id) ? "chevron.down" : "chevron.right")
                                .font(.system(size: Look.size(9), weight: .semibold)).foregroundStyle(Ink.tertiary)
                                .frame(width: 22, height: 22).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 4)
                        .accessibilityLabel(isOpen(mailbox.id) ? "Fold" : "Unfold")
                    }
                }
                .opacity(hidden ? 0.5 : 1)
                .draggable(mailbox.id)
                .dropDestination(for: String.self) { ids, _ in
                    guard let moved = ids.first, moved != mailbox.id else { return false }
                    model.moveFolder(moved, before: mailbox.id, in: accountID)
                    return true
                }
                .contextMenu {
                    Button("Rename…") { naming = FolderNaming(accountID: accountID, mailbox: mailbox) }
                    Button(hidden ? "Show in sidebar" : "Hide from sidebar") { model.setHidden(!hidden, mailbox, in: accountID) }
                    Divider()
                    Button("Delete", role: .destructive) { deleting = FolderNaming(accountID: accountID, mailbox: mailbox) }
                }
        }
        if hiddenCount > 0 {
            Button(showsHidden ? String(localized: "Hide hidden folders") : String(localized: "\(hiddenCount) hidden")) { showsHidden.toggle() }
                .buttonStyle(.plain)
                .font(TypeScale.label)
                .foregroundStyle(Ink.tertiary)
                .padding(.horizontal, 8)
                .padding(.top, 4)
        }
        if let error = model.loadErrors[accountID], model.isUnreachable(accountID) {
            // A connection that dropped or a network that's away passes by itself: no alarm, no
            // system error text (that's in the tooltip), just what's happening and a way to hurry it.
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Can't reach the server right now. Margin keeps trying.")
                    .font(TypeScale.caption)
                    .foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .tip(Text(verbatim: error))
                Button("Try Again") {
                    if let account = model.account(accountID) { Task { await model.reload(only: account) } }
                }
                .buttonStyle(.plain)
                .font(TypeScale.caption)
                .foregroundStyle(Ink.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.top, Space.s)
        } else if let error = model.loadErrors[accountID] {
            Text(error)
                .font(TypeScale.caption)
                .foregroundStyle(Status.danger)
                .padding(.horizontal, 8)
                .padding(.top, Space.s)
                .fixedSize(horizontal: false, vertical: true)
            // The sign-in was refused: one click signs in again, and everything else stays.
            if model.needsSignIn(accountID), let account = model.account(accountID), model.canSignInAgain(account) {
                Button("Sign in again") { model.signingInAgain = account }
                    .buttonStyle(QuietButtonStyle())
                    .padding(.horizontal, 8)
                    .padding(.top, Space.xs)
            }
        }
    }

    private func folderRow(_ mailbox: Mailbox, _ accountID: UUID) -> some View {
        let place = Place.mailbox(account: accountID, mailbox)
        return SidebarRow(title: mailbox.name, symbol: Self.symbol(mailbox.role), count: nil, isSelected: model.place == place) {
            model.go(to: place)
        }
    }

    /// Drafts, Sent, Archive, Junk and Trash from every mailbox together.
    @ViewBuilder
    private var combinedFolders: some View {
        ForEach(model.combinedRoles, id: \.self) { role in
            SidebarRow(title: role.title, symbol: Self.symbol(role), count: nil, isSelected: model.place == .combined(role)) {
                model.go(to: .combined(role))
            }
        }
    }

    // MARK: Folding

    private func isFolded(_ key: String) -> Bool { foldedSections.split(separator: ",").contains(Substring(key)) }

    private func toggleSection(_ key: String) {
        var keys = Set(foldedSections.split(separator: ",").map(String.init))
        if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
        foldedSections = keys.sorted().joined(separator: ",")
    }

    private func isOpen(_ id: String) -> Bool { openFolders.split(separator: "\n").contains(Substring(id)) }

    private func toggleFolder(_ id: String) {
        var ids = Set(openFolders.split(separator: "\n").map(String.init))
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        openFolders = ids.sorted().joined(separator: "\n")
    }

    /// The folders to show: top-level ones, and those inside folders that are open.
    private func visibleFolders(_ items: [(mailbox: Mailbox, depth: Int)]) -> [(item: (mailbox: Mailbox, depth: Int), hasChildren: Bool)] {
        var result: [(item: (mailbox: Mailbox, depth: Int), hasChildren: Bool)] = []
        var openPath: [Bool] = []   // open state of each ancestor, by depth
        for (index, item) in items.enumerated() {
            openPath = Array(openPath.prefix(item.depth))
            let visible = openPath.allSatisfy { $0 }
            let hasChildren = index + 1 < items.count && items[index + 1].depth > item.depth
            if visible { result.append((item, hasChildren)) }
            openPath.append(isOpen(item.mailbox.id))
        }
        return result
    }

    /// A section title that folds its section away when clicked.
    private func foldTitle(_ text: LocalizedStringKey, key: String) -> some View {
        Button { withAnimation(Motion.quick) { toggleSection(key) } } label: {
            HStack(spacing: 4) {
                Text(text)
                Image(systemName: isFolded(key) ? "chevron.right" : "chevron.down").font(.system(size: Look.size(8), weight: .bold))
            }
            .font(TypeScale.label.weight(.medium))
            .foregroundStyle(Ink.tertiary)
            .padding(.horizontal, 8)
            .padding(.top, Space.l)
            .padding(.bottom, Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Labels, with how many conversations have each; a click shows them.
    @ViewBuilder
    private var labelsSection: some View {
        let counts = model.labelCounts
        if !counts.isEmpty {
            foldTitle("Labels", key: "labels")
            if !isFolded("labels") {
                ForEach(model.allLabels, id: \.self) { label in
                    SidebarRow(title: label, symbol: "tag.fill", count: counts[label], isSelected: model.place == .home(group: label),
                               tint: GroupStyle.color(label)) {
                        model.go(to: .home(group: label))
                    }
                    .contextMenu { LabelColorMenu(model: model, label: label) }
                }
            }
        }
    }

    private func sectionTitle(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(TypeScale.label.weight(.medium))
            .foregroundStyle(Ink.tertiary)
            .padding(.horizontal, 8)
            .padding(.top, Space.l)
            .padding(.bottom, Space.xs)
    }

    private var footer: some View {
        StatusLine(model: model, color: Ink.quaternary)
        .padding(.horizontal, 18)
        .padding(.vertical, Space.m)
    }


    static func symbol(_ role: MailboxRole) -> String {
        switch role {
        case .inbox: "tray"
        case .sent: "paperplane"
        case .drafts: "doc"
        case .archive, .all: "archivebox"
        case .trash: "trash"
        case .junk: "xmark.bin"
        case .flagged: "star"
        case .other: "folder"
        }
    }
}

/// The one obvious action in the sidebar: solid ink, so it reads first.
private struct ComposeButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                Image(systemName: "square.and.pencil").font(.system(size: Look.size(13), weight: .semibold))
                Text("New message").font(TypeScale.rowStrong).lineLimit(1).fixedSize()
                Spacer(minLength: 0)
            }
            .foregroundStyle(Ink.inverse)
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(height: Look.gap(34))
            .background(Ink.primary.opacity(isHovered ? 0.88 : 1), in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .tip("New message  ⌘N")
    }
}

/// Hover fill for plain rows that aren't navigation targets.
struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRow(configuration: configuration)
    }

    private struct HoverRow: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background(isHovered || configuration.isPressed ? Fill.one : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .onHover { isHovered = $0 }
        }
    }
}

struct SidebarRow: View {
    let title: Text
    let symbol: String
    let count: Int?
    let isSelected: Bool
    /// The icon's own colour (a label's); otherwise the usual grey.
    var tint: Color? = nil
    let action: () -> Void
    @State private var isHovered = false

    /// A fixed row name from the app ("Inbox"), translated.
    init(title: LocalizedStringKey, symbol: String, count: Int?, isSelected: Bool, action: @escaping () -> Void) {
        self.init(title: Text(title), symbol: symbol, count: count, isSelected: isSelected, action: action)
    }

    /// A name that is already translated or comes from the server (a folder), shown as is.
    @_disfavoredOverload
    init(title: String, symbol: String, count: Int?, isSelected: Bool, tint: Color? = nil, action: @escaping () -> Void) {
        self.init(title: Text(verbatim: title), symbol: symbol, count: count, isSelected: isSelected, action: action)
        self.tint = tint
    }

    private init(title: Text, symbol: String, count: Int?, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.count = count
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                Image(systemName: symbol)
                    .font(.system(size: Look.size(12)))
                    .foregroundStyle(tint ?? (isSelected ? Ink.primary : Ink.tertiary))
                    .frame(width: 16)
                title
                    .font(isSelected ? TypeScale.rowStrong : TypeScale.row)
                    .foregroundStyle(isSelected ? Ink.primary : Ink.secondary)
                    .lineLimit(1)
                Spacer(minLength: Space.xs)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(TypeScale.label.monospacedDigit())
                        .foregroundStyle(Ink.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: Look.gap(28))
            .background(isSelected ? Fill.two : (isHovered ? Fill.one : .clear), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// A folder being created (no mailbox yet) or renamed.
private struct FolderNaming: Equatable {
    var accountID: UUID
    var mailbox: Mailbox?
}

/// A label's Color menu: the palette by name, with a check on the one in use, and Automatic.
struct LabelColorMenu: View {
    let model: MailModel
    let label: String

    var body: some View {
        let current = model.labelColors[label.lowercased()]
        Menu("Color") {
            Button { model.setColor(nil, forLabel: label) } label: {
                if current == nil { Label("Automatic", systemImage: "checkmark") } else { Text("Automatic") }
            }
            Divider()
            ForEach(Array(LabelColors.names.enumerated()), id: \.offset) { index, name in
                Button { model.setColor(index, forLabel: label) } label: {
                    if current == index { Label(name, systemImage: "checkmark") } else { Text(verbatim: name) }
                }
            }
        }
    }
}
