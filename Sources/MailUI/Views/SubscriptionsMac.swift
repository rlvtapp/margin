#if os(macOS)
import MailCore
import SwiftUI

/// Subscriptions on the Mac, in the same frame as mail: newsletters in the list column, the
/// chosen one (or one of its emails) in the panel beside it.
struct SubscriptionsColumns: View {
    @Bindable var model: MailModel
    var listWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            SubscriptionsColumn(model: model)
                .frame(width: listWidth)
            Rectangle().fill(Line.hairline).frame(width: 1)
            SubscriptionPanel(model: model)
        }
        .task {
            await model.refreshNewsletterHistory()
            if model.openSubscriptionID == nil {
                model.openSubscriptionID = (model.newsletterSuggestions.first ?? model.newsletterSenders.first)?.id
            }
        }
    }
}

/// The list column: the same header band, chips and rows as the mail list.
private struct SubscriptionsColumn: View {
    @Bindable var model: MailModel
    @State private var showsAll = false
    @State private var confirmsAll = false

    var body: some View {
        let senders = model.newsletterSenders.filter { $0.received >= 2 }
        let rarely = model.newsletterSuggestions
        let showing = showsAll || rarely.isEmpty ? senders : rarely
        VStack(spacing: 0) {
            header(senders)
            if !rarely.isEmpty {
                HStack {
                    GlassChipRow {
                        chip("Rarely opened", count: rarely.count, isOn: !showsAll) { showsAll = false }
                        chip("All", count: senders.count, isOn: showsAll) { showsAll = true }
                    }
                    Spacer()
                }
                .padding(.horizontal, Space.m)
                .padding(.bottom, Space.s)
            }
            if senders.isEmpty {
                ListMessage(title: "No newsletters yet", detail: "Lists you get show up here once a few issues have arrived.", action: nil)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(showing) { sender in
                            SubscriptionRow(
                                sender: sender,
                                account: model.accounts.count > 1 ? model.account(sender.latest.accountID) : nil,
                                isSelected: model.openSubscriptionID == sender.id
                            ) {
                                model.select(nil)
                                model.openSubscriptionID = sender.id
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, Space.l)
                    .animation(Motion.quick, value: showing.map(\.id))
                }
            }
            if !showsAll, rarely.count > 1 {
                footer(rarely)
            }
        }
        .background(Paper.panel)
        .confirmationDialog(String(localized: "Unsubscribe from \(rarely.count) newsletters?"), isPresented: $confirmsAll, titleVisibility: .visible) {
            Button(String(localized: "Unsubscribe from all \(rarely.count)"), role: .destructive) {
                withAnimation(Motion.quick) { rarely.forEach(model.unsubscribe(from:)) }
            }
        } message: {
            Text("Each list is told you're leaving, and their issues are cleared from your inbox.")
        }
    }

    /// "Subscriptions" and one line of numbers, in the mail list's header band.
    private func header(_ senders: [NewsletterSender]) -> some View {
        let issues = senders.reduce(0) { $0 + $1.received }
        let opened = senders.reduce(0) { $0 + $1.opened }
        return HStack(spacing: Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Subscriptions").font(TypeScale.heading).foregroundStyle(Ink.primary)
                Text("You get \(senders.count) newsletters · you opened \(opened) of \(issues) emails")
                    .font(TypeScale.caption)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.s)
            IconButton("sidebar.left", help: model.isSidebarHidden ? "Show sidebar  ⌃⌘S" : "Hide sidebar  ⌃⌘S") { model.isSidebarHidden.toggle() }
        }
        .padding(.leading, Space.l)
        .padding(.trailing, Space.s)
        .frame(height: MailLayout.topBand)
    }

    private func chip(_ title: LocalizedStringKey, count: Int, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button { withAnimation(Motion.quick) { action() } } label: {
            GlassChip(Text(title), count: count, isOn: isOn)
        }
        .buttonStyle(.plain)
    }

    /// A quiet way to leave every rarely opened list at once.
    private func footer(_ rarely: [NewsletterSender]) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(Line.hairline).frame(height: 1)
            HStack {
                Text(rarely.count == 1 ? String(localized: "1 newsletter you rarely open") : String(localized: "\(rarely.count) newsletters you rarely open"))
                    .font(TypeScale.label)
                    .foregroundStyle(Ink.tertiary)
                Spacer()
                Button(String(localized: "Unsubscribe from all \(rarely.count)")) { confirmsAll = true }
                    .buttonStyle(QuietButtonStyle())
            }
            .padding(.horizontal, Space.l)
            .frame(height: 44)
        }
    }
}

/// A newsletter in the list: its open rate as a ring around the sender, the name and what it
/// adds up to. Selected and hovered rows look like mail rows.
private struct SubscriptionRow: View {
    let sender: NewsletterSender
    let account: MailAccount?
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RateRing(rate: sender.openRate) {
                    Avatar(EmailAddress(name: sender.name, address: sender.address), size: 26)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(verbatim: sender.name)
                            .font(TypeScale.rowStrong)
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                        Spacer(minLength: Space.xs)
                        if let account { AccountMark(account, size: 12) }
                    }
                    Text("You opened \(sender.opened) of \(sender.received)")
                        .font(TypeScale.label.monospacedDigit())
                        .foregroundStyle(sender.isRarelyRead ? Status.danger : Ink.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(isSelected ? Fill.two : (isHovered ? Fill.one : .clear), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The panel beside the list: a toolbar band like the reader's with the choices, then the
/// newsletter and every email it sent. Clicking an email reads it here.
struct SubscriptionPanel: View {
    @Bindable var model: MailModel
    @Environment(\.mailAccent) private var accent

    var body: some View {
        if let id = model.openSubscriptionID, let sender = model.newsletterSenders.first(where: { $0.id == id }) {
            if let thread = model.selectedThread, model.issues(of: id).contains(where: { $0.id == thread.id }) {
                ReaderView(model: model, onBack: { model.select(nil) })
            } else {
                VStack(spacing: 0) {
                    toolbar(sender)
                    Rectangle().fill(Line.hairline).frame(height: 1)
                    overview(sender)
                }
                .background(Paper.panel)
            }
        } else {
            ListMessage(title: "Pick a newsletter", detail: "Its emails show up here.", action: nil)
                .background(Paper.panel)
        }
    }

    private func toolbar(_ sender: NewsletterSender) -> some View {
        let suggested = model.newsletterSuggestions.contains { $0.id == sender.id }
        return HStack(spacing: Space.s) {
            HStack(spacing: 6) {
                if let account = model.account(sender.latest.accountID), model.accounts.count > 1 {
                    AccountMark(account, size: 14)
                    Text(account.label).foregroundStyle(Ink.tertiary)
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Ink.quaternary)
                }
                Text("Subscriptions").foregroundStyle(Ink.tertiary)
            }
            .font(TypeScale.row)
            .padding(.leading, Space.s)
            Spacer()
            if suggested {
                Button("Keep") { model.keep(sender) }.buttonStyle(QuietButtonStyle())
            }
            if model.unsubscribeMethod(for: sender.latest) != nil {
                Button("Unsubscribe") { model.unsubscribe(from: sender) }.buttonStyle(InkButtonStyle())
            }
        }
        .padding(.horizontal, Space.l)
        .frame(height: MailLayout.topBand)
    }

    private func overview(_ sender: NewsletterSender) -> some View {
        let issues = model.issues(of: sender.id)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Space.m) {
                    Avatar(EmailAddress(name: sender.name, address: sender.address), size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: sender.name)
                            .font(TypeScale.title)
                            .foregroundStyle(Ink.primary)
                        Text("\(Text(verbatim: sender.address)) · \(Text("You opened \(sender.opened) of \(sender.received)").foregroundStyle(sender.isRarelyRead ? Status.danger : Ink.tertiary))")
                            .font(TypeScale.label)
                            .foregroundStyle(Ink.tertiary)
                    }
                }
                .padding(.bottom, Space.xl)
                VStack(spacing: 2) {
                    ForEach(issues) { thread in
                        IssueRow(thread: thread, accent: accent) { model.select(thread.id) }
                    }
                }
                .padding(.horizontal, -10)
            }
            .frame(maxWidth: 780, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
    }
}

/// One email of a newsletter, like a mail row without the sender: subject and date, a line
/// of it, and the accent dot while unread.
private struct IssueRow: View {
    let thread: MailThread
    let accent: Color
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(thread.isUnread ? accent : .clear)
                    .frame(width: 7, height: 7)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: thread.subject)
                            .font(thread.isUnread ? TypeScale.rowStrong : TypeScale.row)
                            .foregroundStyle(thread.isUnread ? Ink.primary : Ink.secondary)
                            .lineLimit(1)
                        Spacer(minLength: Space.m)
                        Text(RowDate.string(thread.date))
                            .font(TypeScale.label.monospacedDigit())
                            .foregroundStyle(Ink.tertiary)
                    }
                    Text(verbatim: thread.latest.snippet)
                        .font(TypeScale.row)
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(isHovered ? Fill.one : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// The avatar with a thin ring showing how much of the list was opened.
private struct RateRing<Content: View>: View {
    let rate: Double
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(3)
            .overlay {
                Circle().stroke(Fill.two, lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(0.03, rate))
                    .stroke(rate <= 0.2 ? Status.danger : Status.done, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .accessibilityHidden(true)
    }
}
#endif
