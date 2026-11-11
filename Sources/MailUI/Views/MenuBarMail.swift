#if os(macOS)
import AppKit
import MailCore
import SwiftUI

extension MailModel {
    /// Shows Margin in the menu bar: sign-in codes and links, and the latest mail.
    public var showsMenuBarItem: Bool {
        get { _ = alertRevision; return environment.defaults.object(forKey: "showsMenuBarItem") as? Bool ?? true }
        set {
            // SwiftUI sets this again on every update; only a real change may touch anything,
            // or each set would start another update.
            guard newValue != showsMenuBarItem else { return }
            environment.defaults.set(newValue, forKey: "showsMenuBarItem")
            alertRevision += 1
        }
    }

    /// Conversations from the last 15 minutes with a sign-in code or link.
    var recentSignIns: [MailThread] {
        let since = Date().addingTimeInterval(-15 * 60)
        return inboxThreads(nil).filter { $0.date > since && (signInCode(in: $0) != nil || signInLink(in: $0) != nil) }
    }
}

/// Margin in the menu bar: codes and sign-in links from the last 15 minutes, one click each, and
/// the newest unread mail with a quick reply.
public struct MenuBarMail: View {
    let model: MailModel
    @State private var replyingTo: MailThread.ID?
    @State private var text = ""
    @Environment(\.openURL) private var openURL

    public init(model: MailModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            let signIns = model.recentSignIns
            if !signIns.isEmpty {
                section("Sign-in")
                ForEach(signIns) { thread in signInRow(thread) }
            }
            section("Unread")
            let unread = model.inboxThreads(nil).filter { $0.isUnread && !model.isSnoozed($0) }.prefix(6)
            if unread.isEmpty {
                Text("You're all caught up").font(TypeScale.row).foregroundStyle(Ink.tertiary).padding(.horizontal, Space.s)
            }
            ForEach(Array(unread)) { thread in mailRow(thread) }
            Divider()
            HStack {
                Button("Open Margin") { NSApp.activate(); NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }
                Spacer()
                Button("New Message") { NSApp.activate(); model.startCompose() }
            }
            .buttonStyle(.borderless)
            .font(TypeScale.label)
            .padding(.horizontal, Space.s)
        }
        .padding(.vertical, Space.m)
        .padding(.horizontal, Space.xs)
        .frame(width: 360)
        .task { await model.reload() }
    }

    private func section(_ title: LocalizedStringKey) -> some View {
        Text(title).font(TypeScale.label.weight(.medium)).foregroundStyle(Ink.tertiary).padding(.horizontal, Space.s)
    }

    @ViewBuilder
    private func signInRow(_ thread: MailThread) -> some View {
        HStack(spacing: Space.s) {
            Avatar(thread.latest.from, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: thread.latest.from.displayName).font(TypeScale.rowStrong).lineLimit(1)
                Text(RowDate.string(thread.date)).font(TypeScale.caption).foregroundStyle(Ink.tertiary)
            }
            Spacer()
            if let code = model.signInCode(in: thread) {
                Button { MailModel.putOnPasteboard(code) } label: {
                    Text(verbatim: ReaderSuggestion.spaced(code)).font(TypeScale.rowStrong.monospacedDigit())
                }
                .buttonStyle(.bordered)
                .tip("Copy")
            } else if let link = model.signInLink(in: thread) {
                Button(link.kind == .confirm ? String(localized: "Confirm") : String(localized: "Sign In")) { openURL(link.url) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, Space.s)
    }

    @ViewBuilder
    private func mailRow(_ thread: MailThread) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                NSApp.activate()
                model.reveal(thread.id)
            } label: {
                HStack(alignment: .top, spacing: Space.s) {
                    Avatar(thread.latest.from, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text(verbatim: thread.latest.from.displayName).font(TypeScale.rowStrong).lineLimit(1)
                            Spacer()
                            Text(RowDate.string(thread.date)).font(TypeScale.caption).foregroundStyle(Ink.tertiary)
                        }
                        Text(verbatim: thread.subject).font(TypeScale.label).lineLimit(1)
                        Text(verbatim: thread.latest.snippet).font(TypeScale.caption).foregroundStyle(Ink.tertiary).lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if replyingTo == thread.id {
                HStack {
                    TextField("Quick reply", text: $text).textFieldStyle(.roundedBorder).onSubmit { send(thread) }
                    Button("Send") { send(thread) }.disabled(text.isEmpty)
                }
            } else {
                HStack {
                    Spacer()
                    Button("Reply") { replyingTo = thread.id; text = "" }.buttonStyle(.borderless).font(TypeScale.caption)
                }
            }
        }
        .padding(.horizontal, Space.s)
    }

    private func send(_ thread: MailThread) {
        let reply = text
        Task {
            if await model.quickReply(to: thread.id, text: reply) { replyingTo = nil; text = "" }
        }
    }
}
#endif
