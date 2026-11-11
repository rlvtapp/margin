import AuthenticationServices
import MailCore
import SwiftUI

/// The reactions on one message as small chips under it ("😆 Jane", "👍 3"), and a button to
/// add yours, which sends the sender a short reply. Mac, iPhone and iPad alike.
struct ReactionStrip: View {
    let model: MailModel
    let thread: MailThread
    let message: MailMessage
    let reactions: [MailReaction]
    /// iPhone and iPad sizes.
    var touch = false

    var body: some View {
        let mine = model.myAddresses(for: thread)
        let reacted = reactions.contains { mine.contains($0.from.address.lowercased()) }
        let offers = !reacted && model.canReact(to: message, in: thread)
        if !reactions.isEmpty || offers {
            FlowRow(spacing: Space.s) {
                ForEach(MailReaction.grouped(reactions), id: \.emoji) { group in
                    chip(emoji: group.emoji, people: group.people, mine: mine)
                }
                if offers { picker }
            }
        }
    }

    private func chip(emoji: String, people: [EmailAddress], mine: Set<String>) -> some View {
        let isMine = people.contains { mine.contains($0.address.lowercased()) }
        let names = people.map { mine.contains($0.address.lowercased()) ? String(localized: "You") : $0.displayName }
        let everyone = ListFormatter.localizedString(byJoining: names)
        return HStack(spacing: 5) {
            if emoji.isEmpty {
                Image(systemName: "face.smiling").font(.system(size: touch ? 15 : 12))
            } else {
                Text(verbatim: emoji).font(.system(size: touch ? 17 : 14))
            }
            Text(verbatim: people.count == 1 ? names[0] : "\(people.count)")
                .font(touch ? .system(size: 14, weight: .medium) : TypeScale.label.weight(.medium))
                .foregroundStyle(isMine ? Ink.primary : Ink.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, touch ? 10 : 8)
        .frame(height: touch ? 32 : 24)
        .background(isMine ? Fill.two : Fill.one, in: Capsule())
        .overlay(Capsule().strokeBorder(isMine ? Line.hairline : .clear))
        .tip(Text("Reacted: \(everyone)"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: emoji.isEmpty ? everyone : "\(emoji) \(everyone)"))
    }

    private var picker: some View {
        Menu {
            Section {
                ForEach(MailReaction.Kind.allCases, id: \.self) { kind in
                    Button {
                        model.react(kind.emoji, to: message, in: thread)
                    } label: {
                        Text(verbatim: kind.emoji + "  ") + Text(kind.title)
                    }
                }
            } header: {
                Text("Sends \(message.from.displayName) a short reply")
            }
        } label: {
            Image(systemName: "face.smiling")
                .font(.system(size: touch ? 16 : 13, weight: .medium))
                .foregroundStyle(Ink.tertiary)
                .frame(width: touch ? 40 : 28, height: touch ? 32 : 24)
                .background(Fill.one, in: Capsule())
                .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        #if os(macOS)
        .menuIndicator(.hidden)
        #endif
        .fixedSize()
        .tip("React")
        .accessibilityLabel(Text("React"))
    }
}

/// "React" in a message's ⋯ menu: the same reactions as the smiley under the message.
struct ReactMenu: View {
    let model: MailModel
    let thread: MailThread
    let message: MailMessage

    var body: some View {
        Menu {
            ForEach(MailReaction.Kind.allCases, id: \.self) { kind in
                Button { model.react(kind.emoji, to: message, in: thread) } label: {
                    Text(verbatim: kind.emoji + "  ") + Text(kind.title)
                }
            }
        } label: {
            Label("React", systemImage: "face.smiling")
        }
    }
}

extension MailReaction.Kind {
    /// The name shown next to each reaction in the picker.
    var title: String {
        switch self {
        case .like: String(localized: "Like", comment: "A reaction to a message")
        case .heart: String(localized: "Love", comment: "A reaction to a message")
        case .celebrate: String(localized: "Celebrate", comment: "A reaction to a message")
        case .laugh: String(localized: "Laugh", comment: "A reaction to a message")
        case .surprised: String(localized: "Surprised", comment: "A reaction to a message")
        case .sad: String(localized: "Sad", comment: "A reaction to a message")
        }
    }
}

/// A reaction email whose message isn't in the conversation (older than what's loaded, or in
/// another folder): one line instead of Outlook's quoted copy. The text is a click away.
struct ReactionNoticeCard: View {
    let reaction: MailReaction
    /// The subject of the message reacted to.
    let subject: String
    let isMine: Bool
    let showText: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.m) {
                Group {
                    if let emoji = reaction.emoji {
                        Text(verbatim: emoji).font(.system(size: 18))
                    } else {
                        Image(systemName: "face.smiling").font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.secondary)
                    }
                }
                .frame(width: 32, height: 32)
                .background(Fill.two, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: subject.isEmpty ? String(localized: "(No subject)") : subject)
                        .font(TypeScale.rowStrong).foregroundStyle(Ink.primary).lineLimit(2)
                    Text(verbatim: line).font(TypeScale.label).foregroundStyle(Ink.tertiary)
                }
                Spacer(minLength: Space.s)
            }
            Button("Show message", action: showText)
                .buttonStyle(.plain)
                .font(TypeScale.label)
                .foregroundStyle(Ink.tertiary)
        }
        .padding(Space.m)
        .background(Fill.one, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
    }

    private var line: String {
        if reaction.isRemoval { return String(localized: "\(reaction.from.displayName) removed a reaction") }
        return isMine ? String(localized: "You reacted") : String(localized: "\(reaction.from.displayName) reacted to your message")
    }
}

/// A Microsoft account's switch for Outlook's own reactions (from colleagues on Microsoft 365),
/// read from the mailbox. Off until turned on; turning it on asks the account for reading mail.
struct OutlookReactionsSection: View {
    let model: MailModel
    let account: MailAccount
    @Environment(\.webAuthenticationSession) private var webAuthentication
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        if model.oauthProvider(of: account) == .microsoft, model.canAskForAccess(account) {
            Section {
                Toggle("Show Outlook reactions", isOn: Binding(
                    get: { model.showsOutlookReactions(account) },
                    set: { on in Task { on ? await turnOn() : await model.turnOffOutlookReactions(for: account) } }
                ))
                .disabled(working)
            } header: {
                Text("Reactions")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shows reactions from people on Microsoft 365 under your messages. Microsoft doesn't offer this to other apps, so Margin reads it from your mailbox and it may stop working. Turning it on asks to read your mail.")
                    if let problem { Text(verbatim: problem).foregroundStyle(Status.danger) }
                }
            }
        }
    }

    private func turnOn() async {
        working = true
        defer { working = false }
        do {
            try await model.turnOnOutlookReactions(for: account) { url, scheme in
                try await webAuthentication.authenticate(using: url, callbackURLScheme: scheme, preferredBrowserSession: .ephemeral)
            }
            problem = nil
            if let thread = model.selectedThread { await model.loadOutlookReactions(for: thread) }
        } catch let failure as ASWebAuthenticationSessionError where failure.code == .canceledLogin {
            return
        } catch {
            problem = error.localizedDescription
        }
    }
}
