import MailCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The slim column at the far left: everything at once, then one avatar per mailbox.
/// ⌃1 is All, ⌃2… are the mailboxes in order.
struct AccountRail: View {
    @Bindable var model: MailModel
    /// The mailbox being dragged to a new place, and how far the pointer has moved.
    @State private var dragging: UUID?
    @State private var dragStart = 0
    /// The place it's in now, so each new place gets one tap.
    @State private var dragTarget = 0
    /// The column's order while dragging: only the column moves until you let go, then the
    /// new order is saved.
    @State private var order: [UUID]?

    private var shown: [MailAccount] {
        let accounts = model.workspaceAccounts
        guard let order else { return accounts }
        return order.compactMap { id in accounts.first { $0.id == id } }
    }
    /// One place in the column: a 34-point button and the 10 points between them.
    private let step: CGFloat = 44

    private func begin(_ account: MailAccount, at index: Int) {
        dragging = account.id
        dragStart = index
        dragTarget = index
        order = model.workspaceAccounts.map(\.id)
    }

    /// The pointer is a whole number of places from where it started: put the mailbox there,
    /// with a tap on the trackpad.
    private func moved(_ account: MailAccount, places: Int) {
        guard var current = order, let from = current.firstIndex(of: account.id) else { return }
        let target = min(max(dragStart + places, 0), current.count - 1)
        guard target != dragTarget else { return }
        dragTarget = target
        #if os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .drawCompleted)
        #endif
        current.move(fromOffsets: IndexSet(integer: from), toOffset: target > from ? target + 1 : target)
        withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) { order = current }
    }

    private func endDrag() {
        if let order { model.setAccountOrder(order) }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { dragging = nil }
        order = nil
    }

    var body: some View {
        VStack(spacing: 10) {
            #if os(macOS)
            // The window buttons are in the bar above; the rail starts just under its line.
            Color.clear.frame(height: 2)
            #else
            Color.clear.frame(height: 30) // the window buttons
            #endif
            RailButton(help: Text("All inboxes  ⌃1"), badge: model.unreadCount(account: nil), isSelected: model.place.isCombined) {
                Image(systemName: "tray.2").font(.system(size: Look.size(14)))
            } action: { model.go(to: .allInboxes) }
            // Places across every mailbox, a click away: what needs you, what you're waiting
            // on, and what's snoozed.
            RailButton(help: Text("Home"), badge: model.needYouCount, isSelected: model.place.isHome) {
                Image(systemName: "house").font(.system(size: Look.size(14)))
            } action: { model.go(to: .home(group: nil)) }
            RailButton(help: Text("Waiting for reply"), badge: model.waitingCount,
                       isSelected: model.place == .waiting(account: nil)) {
                Image(systemName: "hourglass").font(.system(size: Look.size(14)))
            } action: { model.go(to: .waiting(account: nil)) }
            RailButton(help: Text("Snoozed"), badge: 0, isSelected: model.place == .snoozed(account: nil)) {
                Image(systemName: "clock").font(.system(size: Look.size(14)))
            } action: { model.go(to: .snoozed(account: nil)) }
            RailButton(help: Text("Calendar"), badge: 0, isSelected: model.place == .calendar) {
                Image(systemName: "calendar").font(.system(size: Look.size(14)))
            } action: { model.go(to: .calendar) }
            Rectangle().fill(Line.hairline).frame(width: 20, height: 1).padding(.vertical, 2)

            // More mailboxes than fit: the column scrolls, and Add a mailbox stays in view below.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, account in
                        RailMailbox(
                            account: account,
                            help: Text(verbatim: "\(account.label) · \(account.address.address)\(index < 8 ? "  ⌃\(index + 2)" : "")"),
                            badge: model.unreadCount(account: account.id),
                            isSelected: model.place.accountID == account.id,
                            // A red dot is for trouble that needs you; a dropped connection mends itself.
                            hasError: model.loadErrors[account.id] != nil && !model.isUnreachable(account.id),
                            isDragging: dragging == account.id,
                            shift: dragging == account.id ? CGFloat(dragTarget - dragStart) * step : 0,
                            step: step,
                            open: { model.go(to: .inbox(account: account.id, split: nil)) },
                            begin: { begin(account, at: index) },
                            moved: { places in moved(account, places: places) },
                            end: endDrag
                        )
                        .zIndex(dragging == account.id ? 1 : 0)
                        .contextMenu {
                            Button("Move Up") { withAnimation(Motion.quick) { model.moveAccount(account.id, by: -1) } }
                                .disabled(!model.canMoveAccount(account.id, by: -1))
                            Button("Move Down") { withAnimation(Motion.quick) { model.moveAccount(account.id, by: 1) } }
                                .disabled(!model.canMoveAccount(account.id, by: 1))
                            if model.canSignInAgain(account) {
                                Divider()
                                Button("Sign In Again…") { model.signingInAgain = account }
                            }
                        }
                    }
                }
                // The whole rail's width, with room above the first: the scroll view clips to
                // its content, and unread counts sit past each picture's top-right corner.
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
                .padding(.bottom, 2)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: CGFloat(shown.count) * step + 8)
            RailButton(help: Text("Add a mailbox"), badge: 0, isSelected: false) {
                Image(systemName: "plus").font(.system(size: Look.size(13), weight: .medium))
            } action: { model.isAddingAccount = true }

            Spacer(minLength: 0)
            #if os(macOS)
            // Help, above Settings: it opens beside the mail.
            RailButton(help: Text("Help and feedback"), badge: 0, isSelected: model.isShowingHelp) {
                Image(systemName: "questionmark.circle").font(.system(size: Look.size(14)))
            } action: { model.isShowingHelp.toggle() }
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: Look.size(14)))
                    .foregroundStyle(Ink.tertiary)
                    .frame(width: Look.pick(34, roomy: 40), height: Look.pick(34, roomy: 40))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tip("Settings  ⌘,", side: .right)
            .padding(.bottom, Space.m)
            #endif
        }
        .frame(width: MailLayout.railWidth)
    }
}

/// A mailbox's picture: its company's logo when its domain has one (relevate.app), otherwise
/// the first letter of its name on a rounded square in its colour. The name, not the person: one person
/// often has several mailboxes. A small provider mark in the corner says where the mail lives.
struct AccountAvatar: View {
    let account: MailAccount
    var size: CGFloat = 30
    var showsProvider = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let domain = account.address.domain
        // A rounded square, like the small mailbox mark (`AccountMark`): people are circles,
        // mailboxes aren't people.
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        Group {
            if let logo = AccountLogos.shared.image(for: domain) {
                logo
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .background(.white)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(.black.opacity(colorScheme == .dark ? 0 : 0.08)))
            } else {
                Text(account.label.first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(Palette.account(account.colorIndex), in: shape)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if showsProvider, size >= 24, let provider = ProviderCatalog.preset(for: account) {
                ProviderMark(preset: provider, size: (size * 0.48).rounded())
                    .padding(1.5)
                    .background(Paper.sidebar, in: RoundedRectangle(cornerRadius: size * 0.16, style: .continuous))
                    .offset(x: size * 0.14, y: size * 0.14)
                    .accessibilityHidden(true)
            }
        }
        .task(id: domain) { await AccountLogos.shared.load(domain) }
    }
}

/// Company logos for mailboxes on their own domain, read from disk or looked up once.
@MainActor @Observable final class AccountLogos {
    static let shared = AccountLogos()

    private var images: [String: Image] = [:]
    @ObservationIgnored private let source = DomainLogos(
        folder: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "Margin/Logos", directoryHint: .isDirectory)
    )

    func image(for domain: String) -> Image? { images[domain.lowercased()] }

    func load(_ domain: String) async {
        let key = domain.lowercased()
        guard images[key] == nil, DomainLogos.isCompanyDomain(key), let data = await source.logo(for: key) else { return }
        #if os(macOS)
        if let image = NSImage(data: data) { images[key] = Image(nsImage: image) }
        #else
        if let image = UIImage(data: data) { images[key] = Image(uiImage: image) }
        #endif
    }
}

private struct RailButton<Face: View>: View {
    let help: Text
    let badge: Int
    let isSelected: Bool
    var hasError = false
    var isAvatar = false
    @ViewBuilder let face: Face
    let action: () -> Void
    @Environment(\.mailAccent) private var accent
    @State private var isHovered = false

    init(help: Text, badge: Int, isSelected: Bool, hasError: Bool = false, isAvatar: Bool = false,
         @ViewBuilder face: () -> Face, action: @escaping () -> Void) {
        self.help = help
        self.badge = badge
        self.isSelected = isSelected
        self.hasError = hasError
        self.isAvatar = isAvatar
        self.face = face()
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            face
                .foregroundStyle(isSelected ? Ink.primary : Ink.tertiary)
                .frame(width: Look.pick(34, roomy: 40), height: Look.pick(34, roomy: 40))
                .background {
                    if !isAvatar {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? Fill.two : (isHovered ? Fill.one : .clear))
                    }
                }
                .overlay(alignment: .topTrailing) { badgeView }
                // The mailbox in view is marked with a short bar at the rail's own edge, clear
                // of the picture, its unread count and its provider mark (a ring around the
                // picture ran through both). Pointing at another shows a shorter, fainter one.
                .overlay(alignment: .leading) {
                    if isAvatar {
                        UnevenRoundedRectangle(bottomTrailingRadius: 2, topTrailingRadius: 2, style: .continuous)
                            .fill(Ink.primary)
                            .frame(width: 3, height: isSelected ? 22 : 10)
                            .opacity(isSelected ? 1 : (isHovered ? 0.3 : 0))
                            .offset(x: -(MailLayout.railWidth - Look.pick(34, roomy: 40)) / 2)
                            .animation(Look.reduceMotion ? nil : Motion.quick, value: isSelected)
                            .animation(Look.reduceMotion ? nil : Motion.quick, value: isHovered)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tip(help, side: .right)
        .accessibilityLabel(help)
        .accessibilityValue(badge > 0 ? "\(badge) unread" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var badgeView: some View {
        if hasError {
            Circle().fill(Status.danger).frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(Paper.sidebar, lineWidth: 2))
                .offset(x: 1, y: -1)
        } else if badge > 99 {
            // "99+" would cover half the avatar and only says "lots"; the sidebar has the count.
            Circle().fill(accent).frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(Paper.sidebar, lineWidth: 2))
                .offset(x: 2, y: -1)
        } else if badge > 0 {
            Text(verbatim: "\(badge)")
                .font(.system(size: Look.size(9), weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(minWidth: 15, minHeight: 15)
                .background(accent, in: Capsule())
                .overlay(Capsule().strokeBorder(Paper.sidebar, lineWidth: 2))
                .offset(x: 5, y: -4)
        }
    }
}

/// One mailbox in the column. While it's dragged it follows the pointer by itself (only this
/// view redraws as the pointer moves); the column reorders only when it crosses into a new place.
private struct RailMailbox: View {
    let account: MailAccount
    let help: Text
    let badge: Int
    let isSelected: Bool
    let hasError: Bool
    let isDragging: Bool
    /// How far its place in the column has moved since the drag began.
    let shift: CGFloat
    let step: CGFloat
    let open: () -> Void
    let begin: () -> Void
    let moved: (Int) -> Void
    let end: () -> Void
    @State private var dragY: CGFloat = 0
    @State private var places = 0

    var body: some View {
        RailButton(help: help, badge: badge, isSelected: isSelected, hasError: hasError, isAvatar: true,
                   face: { AccountAvatar(account: account, size: Look.pick(30, roomy: 36)) }, action: open)
            .scaleEffect(isDragging ? 1.1 : 1)
            .shadow(color: .black.opacity(isDragging ? 0.18 : 0), radius: 8, y: 3)
            .offset(y: isDragging ? dragY - shift : 0)
            // In hand it follows the pointer exactly; the others glide out of the way.
            .transaction { if isDragging { $0.animation = nil } }
            .highPriorityGesture(
                // Measured against the window, not this view, which moves as it's dragged.
                DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { value in
                        if !isDragging { begin() }
                        dragY = value.translation.height
                        let now = Int((dragY / step).rounded())
                        if now != places {
                            places = now
                            moved(now)
                        }
                    }
                    .onEnded { _ in
                        end()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { dragY = 0 }
                        places = 0
                    }
            )
    }
}
