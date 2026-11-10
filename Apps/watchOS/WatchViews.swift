import SwiftUI

/// The inbox: newest first, unread marked, a sign-in code shown right in its row.
struct WatchInbox: View {
    let store: WatchStore

    var body: some View {
        Group {
            if store.mails.isEmpty {
                ContentUnavailableView("Inbox zero", systemImage: "checkmark.circle", description: Text("Mail from Margin on your iPhone shows up here."))
            } else {
                List(store.mails) { mail in
                    NavigationLink(value: mail) { WatchRow(mail: mail) }
                        .swipeActions(edge: .leading) {
                            Button { store.perform("done", on: mail) } label: { Label("Done", systemImage: "checkmark") }
                                .tint(.green)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { store.perform("trash", on: mail) } label: { Label("Trash", systemImage: "trash") }
                        }
                }
            }
        }
        .navigationTitle("Inbox")
        // A small title leaves the screen to the mail.
        .toolbarTitleDisplayMode(.inline)
        .navigationDestination(for: WatchMail.self) { mail in
            WatchMailView(store: store, mail: mail)
        }
    }
}

struct WatchRow: View {
    let mail: WatchMail

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                if mail.isUnread { Circle().fill(.blue).frame(width: 5, height: 5) }
                Text(mail.sender).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if mail.isStarred { Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(.yellow) }
            }
            if let code = mail.code {
                Text(WatchMailView.spaced(code)).font(.system(size: 20, weight: .semibold).monospacedDigit())
            } else {
                Text(mail.subject).font(.system(size: 14)).lineLimit(1)
                Text(mail.preview).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// One mail: the text, then the actions and short replies to scroll to.
struct WatchMailView: View {
    let store: WatchStore
    let mail: WatchMail
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(mail.sender).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 2)
                        Text(mail.date.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Text(mail.subject).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(2)
                }
                if let code = mail.code {
                    Text(Self.spaced(code))
                        .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
                }
                Group {
                    if let formatted = mail.formatted,
                       let rich = try? AttributedString(markdown: formatted, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                        Text(rich)
                    } else {
                        Text(mail.body)
                    }
                }
                .font(.system(size: 16))
                .tint(.blue)
                if !mail.replies.isEmpty {
                    Text("Reply").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                    ForEach(mail.replies, id: \.self) { reply in
                        Button(reply) {
                            store.reply(reply, to: mail)
                            dismiss()
                        }
                    }
                }
                HStack {
                    Button { store.perform("done", on: mail); dismiss() } label: { Image(systemName: "checkmark") }
                        .tint(.green)
                        .accessibilityLabel("Done")
                    Button { store.perform("star", on: mail) } label: { Image(systemName: mail.isStarred ? "star.fill" : "star") }
                        .tint(.yellow)
                        .accessibilityLabel("Star")
                    Button(role: .destructive) { store.perform("trash", on: mail); dismiss() } label: { Image(systemName: "trash") }
                        .accessibilityLabel("Trash")
                }
                .padding(.top, 4)
            }
        }
        .onAppear { if mail.isUnread { store.perform("read", on: mail) } }
    }

    static func spaced(_ code: String) -> String {
        code.count == 6 ? code.prefix(3) + " " + code.suffix(3) : code
    }
}
