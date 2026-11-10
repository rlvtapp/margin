import MailCore
import SwiftUI

/// The slim column at the far left: everything at once, then one avatar per mailbox.
/// ⌃1 is All, ⌃2… are the mailboxes in order.
struct AccountRail: View {
    @Bindable var model: MailModel

    var body: some View {
        VStack(spacing: 10) {
            #if os(macOS)
            // The window buttons are in the bar above; the rail starts just under its line.
            Color.clear.frame(height: 2)
            #else
            Color.clear.frame(height: 30) // the window buttons
            #endif
            RailButton(help: Text("All inboxes  ⌃1"), badge: model.unreadCount(account: nil), isSelected: model.place.isCombined) {
                Image(systemName: "tray.2").font(.system(size: 14))
            } action: { model.go(to: .allInboxes) }
            Rectangle().fill(Line.hairline).frame(width: 20, height: 1).padding(.vertical, 2)

            ForEach(Array(model.workspaceAccounts.enumerated()), id: \.element.id) { index, account in
                RailButton(
                    help: Text(verbatim: "\(account.label) · \(account.address.address)\(index < 8 ? "  ⌃\(index + 2)" : "")"),
                    badge: model.unreadCount(account: account.id),
                    isSelected: model.place.accountID == account.id,
                    hasError: model.loadErrors[account.id] != nil,
                    isAvatar: true
                ) {
                    AccountAvatar(account: account, size: 30)
                } action: {
                    model.go(to: .inbox(account: account.id, split: nil))
                }
            }
            RailButton(help: Text("Add a mailbox"), badge: 0, isSelected: false) {
                Image(systemName: "plus").font(.system(size: 13, weight: .medium))
            } action: { model.isAddingAccount = true }

            Spacer(minLength: 0)
            #if os(macOS)
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(Ink.tertiary)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings  ⌘,")
            .padding(.bottom, Space.m)
            #endif
        }
        .frame(width: MailLayout.railWidth)
    }
}

/// A mailbox's picture: its company's logo when its domain has one (relevate.app), otherwise
/// the first letter of its name on a disc in its colour. The name, not the person: one person
/// often has several mailboxes. A small provider mark in the corner says where the mail lives.
struct AccountAvatar: View {
    let account: MailAccount
    var size: CGFloat = 30
    var showsProvider = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let domain = account.address.domain
        Group {
            if let logo = AccountLogos.shared.image(for: domain) {
                logo
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .background(.white)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(.black.opacity(colorScheme == .dark ? 0 : 0.08)))
            } else {
                Text(account.label.first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(Palette.account(account.colorIndex), in: Circle())
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
                .frame(width: 34, height: 34)
                .background {
                    if !isAvatar {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? Fill.two : (isHovered ? Fill.one : .clear))
                    }
                }
                // Avatars show selection as a ring with a gap, like a focused control.
                .overlay {
                    if isAvatar {
                        Circle()
                            .strokeBorder(Ink.primary, lineWidth: 1.5)
                            .frame(width: 37, height: 37)
                            .opacity(isSelected ? 1 : (isHovered ? 0.25 : 0))
                    }
                }
                .overlay(alignment: .topTrailing) { badgeView }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
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
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(minWidth: 15, minHeight: 15)
                .background(accent, in: Capsule())
                .overlay(Capsule().strokeBorder(Paper.sidebar, lineWidth: 2))
                .offset(x: 5, y: -4)
        }
    }
}
