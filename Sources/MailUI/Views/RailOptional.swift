import MailCore
import SwiftUI

extension MailModel {
    /// The account column at the far left. Off, its places and mailboxes move into the sidebar.
    public var showsAccountRail: Bool {
        get { _ = alertRevision; return environment.defaults.object(forKey: "showsAccountRail") as? Bool ?? true }
        set {
            guard newValue != showsAccountRail else { return }
            environment.defaults.set(newValue, forKey: "showsAccountRail")
            alertRevision += 1
        }
    }
}

/// With the account column hidden: what it held, at the top of the sidebar. All inboxes,
/// Home, the Calendar and each mailbox, folding away with one click.
struct SidebarMailboxes: View {
    @Bindable var model: MailModel
    @AppStorage("sidebarMailboxesFolded") private var folded = false

    var body: some View {
        SidebarRow(title: "All inboxes", symbol: "tray.2", count: model.unreadCount(account: nil), isSelected: model.place.isCombined) {
            model.go(to: .allInboxes)
        }
        SidebarRow(title: "Home", symbol: "house", count: model.needYouCount > 0 ? model.needYouCount : nil, isSelected: model.place.isHome) {
            model.go(to: .home(group: nil))
        }
        SidebarRow(title: "Calendar", symbol: "calendar", count: nil, isSelected: model.place == .calendar) { model.go(to: .calendar) }
        Button { withAnimation(Motion.quick) { folded.toggle() } } label: {
            HStack(spacing: 4) {
                Text("Mailboxes")
                Image(systemName: folded ? "chevron.right" : "chevron.down").font(.system(size: Look.size(8), weight: .semibold))
                Spacer(minLength: 0)
            }
            .font(TypeScale.label.weight(.medium))
            .foregroundStyle(Ink.tertiary)
            .padding(.horizontal, 8)
            .padding(.top, Space.m)
            .padding(.bottom, Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if !folded {
            ForEach(model.workspaceAccounts) { account in
                Button { model.go(to: .inbox(account: account.id, split: nil)) } label: {
                    HStack(spacing: Space.s) {
                        AccountAvatar(account: account, size: 18, showsProvider: false)
                        Text(verbatim: account.label).lineLimit(1)
                        Spacer(minLength: 0)
                        let unread = model.unreadCount(account: account.id)
                        if unread > 0 { Text(verbatim: "\(unread)").font(TypeScale.label.monospacedDigit()).foregroundStyle(Ink.tertiary) }
                    }
                    .font(TypeScale.row)
                    .foregroundStyle(model.place.accountID == account.id ? Ink.primary : Ink.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: Look.gap(28))
                    .background(model.place.accountID == account.id ? Fill.two : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button { model.isAddingAccount = true } label: {
                Label("Add a mailbox", systemImage: "plus")
                    .font(TypeScale.row)
                    .foregroundStyle(Ink.tertiary)
                    .padding(.horizontal, 8)
                    .frame(height: Look.gap(28))
            }
            .buttonStyle(.plain)
        }
        Rectangle().fill(Line.hairline).frame(height: 1)
            .padding(.horizontal, 8)
            .padding(.vertical, Space.m)
    }
}
