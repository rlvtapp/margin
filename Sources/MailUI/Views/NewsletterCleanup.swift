import MailCore
import SwiftUI

/// One line at the top of Newsletters when some lists go unread; it opens Subscriptions.
/// "2 newsletters you rarely open   Review ›"
struct NewsletterSuggestionCard: View {
    @Bindable var model: MailModel

    var body: some View {
        let count = model.newsletterSuggestions.count
        if count > 0 {
            Button { model.go(to: .subscriptions) } label: {
                HStack(spacing: Space.s) {
                    Image(systemName: "newspaper")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.split(.newsletters))
                    Text(count == 1 ? String(localized: "1 newsletter you rarely open") : String(localized: "\(count) newsletters you rarely open"))
                        .font(TypeScale.rowStrong)
                        .foregroundStyle(Ink.primary)
                    Spacer(minLength: Space.s)
                    Text("Review")
                        .font(TypeScale.label.weight(.medium))
                        .foregroundStyle(Ink.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Ink.tertiary)
                }
                .padding(.horizontal, Space.m)
                .frame(minHeight: 40)
                .background(Fill.one, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// Subscriptions: every newsletter from every mailbox in one list. A short summary on top, then
/// the lists you rarely open (or all of them), each with its open rate as a ring around the
/// sender. Swipe right to keep a list, left to leave it.
struct SubscriptionsPage: View {
    @Bindable var model: MailModel
    /// iPhone and iPad draw the page title here; the Mac's list header already has it.
    var showsTitle = false
    /// The Mac: this is the list column, and the chosen newsletter opens in the panel beside it.
    var picksForPanel = false
    @State private var showsAll = false
    @State private var confirmsAll = false

    var body: some View {
        let senders = model.newsletterSenders.filter { $0.received >= 2 }
        let rarely = model.newsletterSuggestions
        let showing = showsAll || rarely.isEmpty ? senders : rarely
        Group {
            if senders.isEmpty {
                ListMessage(title: "No newsletters yet", detail: "Lists you get show up here once a few issues have arrived.", action: nil)
            } else {
                List {
                    Section {
                        summary(senders)
                            .listRowInsets(EdgeInsets(top: 0, leading: Space.l, bottom: Space.m, trailing: Space.l))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        if !rarely.isEmpty {
                            HStack {
                                GlassChipRow(spacing: Space.s) {
                                    tab("Rarely opened", count: rarely.count, isOn: !showsAll) { showsAll = false }
                                    tab("All", count: senders.count, isOn: showsAll) { showsAll = true }
                                }
                                Spacer()
                            }
                            .listRowInsets(EdgeInsets(top: 0, leading: Space.l - 4, bottom: Space.s, trailing: Space.l))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    }
                    Section {
                        ForEach(showing) { sender in
                            row(sender, suggested: rarely.contains { $0.id == sender.id })
                        }
                    }
                    if !showsAll, rarely.count > 1 {
                        Section {
                            Button(role: .destructive) { confirmsAll = true } label: {
                                Text(String(localized: "Unsubscribe from all \(rarely.count)"))
                                    .font(TypeScale.rowStrong)
                                    .foregroundStyle(Status.danger)
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: Space.m, leading: Space.l, bottom: Space.l, trailing: Space.l))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .animation(Motion.quick, value: showing.map(\.id))
                .confirmationDialog(String(localized: "Unsubscribe from \(rarely.count) newsletters?"), isPresented: $confirmsAll, titleVisibility: .visible) {
                    Button(String(localized: "Unsubscribe from all \(rarely.count)"), role: .destructive) {
                        withAnimation(Motion.quick) { rarely.forEach(model.unsubscribe(from:)) }
                    }
                } message: {
                    Text("Each list is told you're leaving, and their issues are cleared from your inbox.")
                }
            }
        }
        .background(Paper.panel)
        .task {
            await model.refreshNewsletterHistory()
            // The panel beside the list shows something from the start.
            if picksForPanel, model.openSubscriptionID == nil {
                model.openSubscriptionID = (model.newsletterSuggestions.first ?? model.newsletterSenders.first)?.id
            }
        }
        .sheet(item: Binding(get: { picksForPanel ? nil : model.openSubscriptionID.map(OpenedList.init) },
                             set: { model.openSubscriptionID = $0?.id })) { list in
            SubscriptionSheet(model: model, listID: list.id)
        }
    }

    /// A tab as text: the chosen one sits on a filled capsule.
    private func tab(_ title: LocalizedStringKey, count: Int, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button { withAnimation(Motion.quick) { action() } } label: {
            GlassChip(Text(title), count: count, isOn: isOn, size: .regular)
        }
        .buttonStyle(.plain)
    }

    /// The title and one line of numbers: how many lists, how many issues, how much was opened.
    private func summary(_ senders: [NewsletterSender]) -> some View {
        let issues = senders.reduce(0) { $0 + $1.received }
        let opened = senders.reduce(0) { $0 + $1.opened }
        return VStack(alignment: .leading, spacing: 4) {
            if showsTitle {
                Text("Subscriptions").font(TypeScale.title).foregroundStyle(Ink.primary)
            }
            Text("You get \(senders.count) newsletters · you opened \(opened) of \(issues) emails")
                .font(TypeScale.label.monospacedDigit())
                .foregroundStyle(Ink.tertiary)
        }
    }

    /// The sender with its open rate as a ring, what it adds up to, and one clear action.
    private func row(_ sender: NewsletterSender, suggested: Bool) -> some View {
        let canLeave = model.unsubscribeMethod(for: sender.latest) != nil
        return HStack(spacing: Space.m) {
            OpenRateRing(rate: sender.openRate) {
                Avatar(EmailAddress(name: sender.name, address: sender.address), size: 36)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: sender.name)
                        .font(TypeScale.rowStrong)
                        .foregroundStyle(Ink.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let account = model.account(sender.latest.accountID), model.accounts.count > 1 {
                        AccountMark(account, size: 12)
                    }
                }
                // The last issue's date only when there's room for it.
                ViewThatFits(in: .horizontal) {
                    Text(String(localized: "You opened \(sender.opened) of \(sender.received) · last \(RowDate.string(sender.lastReceived))"))
                    Text("You opened \(sender.opened) of \(sender.received)")
                }
                .font(TypeScale.label.monospacedDigit())
                .foregroundStyle(Ink.tertiary)
                .lineLimit(1)
            }
            Spacer(minLength: Space.s)
            if suggested && !picksForPanel {
                Button("Keep") { withAnimation(Motion.quick) { model.keep(sender) } }
                    .buttonStyle(.plain)
                    .font(TypeScale.label.weight(.medium))
                    .foregroundStyle(Ink.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: 30)
                    .fixedSize()
            }
            if canLeave && !picksForPanel {
                Button("Unsubscribe") { withAnimation(Motion.quick) { model.unsubscribe(from: sender) } }
                    .buttonStyle(.plain)
                    .font(TypeScale.label.weight(.semibold))
                    .foregroundStyle(suggested ? Ink.inverse : Ink.primary)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(suggested ? Ink.primary : Fill.two, in: Capsule())
                    .fixedSize()
            }
        }
        .contentShape(Rectangle())
        // Tapping the sender lists its issues, to see what they were.
        .onTapGesture {
            model.select(nil)
            model.openSubscriptionID = sender.id
        }
        .contextMenu {
            if canLeave {
                Button(role: .destructive) { model.unsubscribe(from: sender) } label: { Label("Unsubscribe", systemImage: "xmark.circle") }
            }
            if suggested {
                Button { model.keep(sender) } label: { Label("Keep", systemImage: "checkmark.circle") }
            }
            Button { model.openSubscriptionID = sender.id } label: { Label("Show emails", systemImage: "tray.full") }
        }
        .padding(.vertical, 6)
        .listRowInsets(EdgeInsets(top: 0, leading: Space.l, bottom: 0, trailing: Space.l))
        .listRowBackground(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(picksForPanel && model.openSubscriptionID == sender.id ? Fill.two : .clear)
                .padding(.horizontal, 6)
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if canLeave {
                Button(role: .destructive) { model.unsubscribe(from: sender) } label: { Label("Unsubscribe", systemImage: "xmark.circle") }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if suggested {
                Button { model.keep(sender) } label: { Label("Keep", systemImage: "checkmark.circle") }
                    .tint(Status.done)
            }
        }
    }
}

/// The avatar with a ring around it showing how much of the list was opened.
private struct OpenRateRing<Content: View>: View {
    let rate: Double
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(4)
            .overlay {
                Circle().stroke(Fill.two, lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(0.03, rate))
                    .stroke(rate <= 0.2 ? Status.danger : Status.done, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityHidden(true)
    }
}

/// Picks between two button styles at runtime.
private struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}


private struct OpenedList: Identifiable { let id: String }

/// One newsletter in a sheet: how much you opened and the two choices on top, then every
/// email it sent. Tapping one reads it right here.
struct SubscriptionSheet: View {
    @Bindable var model: MailModel
    let listID: String
    @Environment(\.dismiss) private var dismiss

    private var sender: NewsletterSender? { model.newsletterSenders.first { $0.id == listID } }

    var body: some View {
        #if os(macOS)
        macBody
        #else
        touchBody
        #endif
    }

    #if os(macOS)
    /// The Mac: who it is and the two choices on top; the emails on the left, the open one beside.
    private var macBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.m) {
                if let sender {
                    Avatar(EmailAddress(name: sender.name, address: sender.address), size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: sender.name).font(TypeScale.heading).foregroundStyle(Ink.primary)
                        Text("You opened \(sender.opened) of \(sender.received)")
                            .font(TypeScale.label)
                            .foregroundStyle(sender.isRarelyRead ? Status.danger : Ink.tertiary)
                    }
                    Spacer()
                    if model.newsletterSuggestions.contains(where: { $0.id == sender.id }) {
                        Button("Keep") { model.keep(sender) }.buttonStyle(QuietButtonStyle())
                    }
                    if model.unsubscribeMethod(for: sender.latest) != nil {
                        Button("Unsubscribe") {
                            model.unsubscribe(from: sender)
                            dismiss()
                        }
                        .buttonStyle(InkButtonStyle())
                    }
                } else {
                    Spacer()
                }
                Button("Done") { dismiss() }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Space.l)
            .frame(height: 64)
            Rectangle().fill(Line.hairline).frame(height: 1)
            HStack(spacing: 0) {
                List(selection: Binding(get: { model.selectedThreadID }, set: { model.select($0) })) {
                    ForEach(model.issues(of: listID)) { thread in
                        issueRow(thread).tag(thread.id)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(width: 300)
                Rectangle().fill(Line.hairline).frame(width: 1)
                ReaderView(model: model)
            }
        }
        .frame(minWidth: 900, idealWidth: 1040, minHeight: 600, idealHeight: 720)
        .background(Paper.panel)
        .onAppear { model.select(model.issues(of: listID).first?.id) }
        .onDisappear { model.select(nil) }
    }
    #endif

    private func issueRow(_ thread: MailThread) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: thread.subject)
                    .font(thread.isUnread ? TypeScale.rowStrong : TypeScale.row)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                Spacer(minLength: Space.s)
                Text(RowDate.string(thread.date))
                    .font(TypeScale.label.monospacedDigit())
                    .foregroundStyle(Ink.tertiary)
            }
            Text(verbatim: thread.latest.snippet)
                .font(TypeScale.label)
                .foregroundStyle(Ink.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }

    private var touchBody: some View {
        NavigationStack {
            List {
                if let sender {
                    header(sender)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                ForEach(model.issues(of: listID)) { thread in
                    NavigationLink(value: thread.id) { issueRow(thread) }
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Paper.panel)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .navigationDestination(for: String.self) { id in
                reader
                    .onAppear { model.select(id) }
            }
        }
        .tint(Ink.primary)
        .onDisappear { model.select(nil) }
    }

    @ViewBuilder
    private var reader: some View {
        #if os(iOS)
        TouchConversation(model: model)
        #else
        ReaderView(model: model)
        #endif
    }

    private func header(_ sender: NewsletterSender) -> some View {
        let suggested = model.newsletterSuggestions.contains { $0.id == sender.id }
        return VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.m) {
                Avatar(EmailAddress(name: sender.name, address: sender.address), size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: sender.name).font(TypeScale.heading).foregroundStyle(Ink.primary)
                    Text("You opened \(sender.opened) of \(sender.received)")
                        .font(TypeScale.label)
                        .foregroundStyle(sender.isRarelyRead ? Status.danger : Ink.tertiary)
                }
            }
            HStack(spacing: Space.s) {
                if model.unsubscribeMethod(for: sender.latest) != nil {
                    Button("Unsubscribe") {
                        model.unsubscribe(from: sender)
                        dismiss()
                    }
                    .buttonStyle(InkButtonStyle())
                }
                if suggested {
                    Button("Keep") { model.keep(sender) }
                        .buttonStyle(QuietButtonStyle())
                }
            }
        }
        .padding(.vertical, Space.s)
    }
}

