import MailCore
import SwiftUI

/// One quiet line under the subject: how many messages, which part of the inbox, labels.
struct ReaderMetaLine: View {
    let model: MailModel
    let thread: MailThread

    var body: some View {
        let labels = model.labels(for: thread)
        let suggestions = model.labelSuggestions[thread.id] ?? []
        FlowRow(spacing: 6) {
            Text(meta).font(TypeScale.label).foregroundStyle(Ink.tertiary).frame(height: Look.gap(22))
            ForEach(labels, id: \.self) { label in
                LabelChip(text: label, style: .applied) { model.removeLabel(label, from: thread) }
            }
            ForEach(suggestions, id: \.self) { label in
                LabelChip(text: label, style: .suggested) { model.addLabel(label, to: thread) }
            }
            if model.isWorking("labels", on: thread) {
                ProgressView().controlSize(.mini).frame(height: Look.gap(22))
            }
        }
    }

    private var meta: String {
        let count = model.withoutReactions(thread).messages.count
        var parts = [count == 1 ? String(localized: "1 message") : String(localized: "\(count) messages"), thread.split.title]
        // With several mailboxes, which one this arrived in.
        if model.accounts.count > 1, let account = model.account(thread.accountID) { parts.append(account.label) }
        if thread.hasAttachments { parts.append(String(localized: "Attachments")) }
        if let until = model.snoozedUntil(thread) {
            parts.append(String(localized: "Snoozed until \(until.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"))
        }
        return parts.joined(separator: " · ")
    }
}

/// At most one suggestion, when something about this conversation calls for it.
struct ReaderSuggestion: View {
    let model: MailModel
    let thread: MailThread
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let code = model.signInCode(in: thread) {
            card {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sign-in code").font(TypeScale.label).foregroundStyle(Ink.tertiary)
                    Text(Self.spaced(code)).font(.system(size: Look.size(20), weight: .medium, design: .monospaced)).foregroundStyle(Ink.primary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Copy") { model.copy(code, announce: "Code copied") }.buttonStyle(PillButtonStyle(prominent: true))
            }
        } else if let link = model.signInLink(in: thread) {
            card {
                VStack(alignment: .leading, spacing: 2) {
                    Text(link.kind == .confirm ? "Confirmation link" : "Sign-in link").font(TypeScale.rowStrong)
                    Text(verbatim: link.url.host() ?? "").font(TypeScale.label).foregroundStyle(Ink.secondary)
                }
                Spacer()
                Button { openURL(link.url) } label: {
                    Label("Open in browser", systemImage: "arrow.up.right")
                }.buttonStyle(PillButtonStyle(prominent: true))
            }
        } else if model.place.isDraftsFolder || thread.messages.contains(where: { $0.flags.contains(.draft) }) {
            card {
                note("This is a draft you haven't sent.")
                Spacer()
                Button("Edit draft") { model.editDraft(thread) }.buttonStyle(PillButtonStyle(prominent: true))
            }
        } else if case .waiting = model.place {
            card {
                let days = Self.days(since: thread.date)
                note(days == 1 ? "No reply for a day." : "No reply for \(days) days.")
                Spacer()
                Button("Follow up") { model.followUp() }.buttonStyle(PillButtonStyle(prominent: true))
            }
        } else if model.snoozedUntil(thread) != nil {
            card {
                note("Snoozed. It comes back to the inbox by itself.")
                Spacer()
                Button("Unsnooze") { model.unsnooze(thread) }.buttonStyle(PillButtonStyle())
            }
        } else if let unsubscribe = model.unsubscribeMethod(for: thread) {
            let count = model.countFromSameSender(as: thread)
            card {
                note("A newsletter from \(thread.latest.from.displayName).")
                Spacer()
                if count > 1 {
                    Button("Archive all \(count)") { model.archiveAll(from: thread) }.buttonStyle(PillButtonStyle())
                }
                Button(Self.unsubscribeTitle(unsubscribe)) { model.unsubscribe(thread) }.buttonStyle(PillButtonStyle(prominent: true))
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: Space.s) { content() }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .background(Fill.one, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text).font(TypeScale.row).foregroundStyle(Ink.secondary).lineLimit(1)
    }

    static func spaced(_ code: String) -> String {
        guard code.count == 6 || code.count == 8 else { return code }
        let middle = code.index(code.startIndex, offsetBy: code.count / 2)
        return "\(code[..<middle]) \(code[middle...])"
    }

    static func days(since date: Date) -> Int {
        max(Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0, 1)
    }

    static func unsubscribeTitle(_ method: Unsubscribe) -> LocalizedStringKey {
        if case .web = method { return "Unsubscribe…" } // opens the sender's page
        return "Unsubscribe"
    }
}

/// Small rounded buttons for suggestions: quiet, or filled for the one that matters.
struct PillButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TypeScale.label.weight(.medium))
            .foregroundStyle(prominent ? Ink.inverse : Ink.primary)
            .padding(.horizontal, 11)
            .frame(height: Look.gap(26))
            .background(prominent ? Ink.primary : Paper.panel, in: Capsule())
            .overlay(Capsule().strokeBorder(prominent ? Color.clear : Line.edge))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// The toolbar's "…" menu: tools that apply to any conversation.
struct ReaderMoreMenu: View {
    let model: MailModel
    let thread: MailThread
    @Binding var addsLabel: Bool

    var body: some View {
        #if os(iOS)
        Menu { items } label: { Label("More", systemImage: "ellipsis") }
        #else
        Menu { items } label: {
            Image(systemName: "ellipsis").font(.system(size: Look.size(13))).foregroundStyle(Ink.tertiary).frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .tip("More")
        #endif
    }

    @ViewBuilder
    private var items: some View {
        if model.isAssistantOn {
            Button("Suggest labels") { model.suggestLabelsForSelected() }
        }
        Button("Add label…") { addsLabel = true }
        // Every message in the conversation, translated where it's written in another language.
        let ids = thread.messages.map(\.id)
        Button(model.translations.anyTranslated(ids) ? "Show Original" : "Translate") { model.translations.toggle(all: ids) }
        Toggle("Show as chat", isOn: Binding(get: { model.showsAsChat }, set: { model.showsAsChat = $0 }))
        Divider()
        let folders = thread.accountID.map { model.folders(of: $0).filter { $0.role == .other || $0.role == .archive } } ?? []
        if !folders.isEmpty {
            Menu("Move to") {
                ForEach(folders) { mailbox in Button(mailbox.name) { model.move(to: mailbox) } }
            }
        }
        if model.unsubscribeMethod(for: thread) != nil {
            Button("Unsubscribe") { model.unsubscribe(thread) }
        }
        let count = model.countFromSameSender(as: thread)
        if count > 1 {
            Button("Archive all \(count) from \(thread.latest.from.displayName)") { model.archiveAll(from: thread) }
        }
        Button("Mark unread") { model.perform(.markUnread) }
        Divider()
        Button(model.isPinned(thread) ? "Unpin" : "Pin to top") { model.togglePin(thread) }
        Button("Add to Reminders") { model.addToReminders(thread) }
        Button("Print…") { model.printSelected() }
        #if os(macOS)
        Button("Save as PDF…") { model.printSelected(asPDF: true) }
        #endif
        let sender = thread.latest.from
        Button(model.isVIP(sender) ? "Remove \(sender.displayName) from VIPs" : "Add \(sender.displayName) to VIPs") { model.toggleVIP(sender) }
        Divider()
        Button(model.isMuted(thread) ? "Unmute Conversation" : "Mute Conversation") { model.toggleMute(thread) }
        if !model.isBlocked(sender) {
            Button("Block \(sender.displayName)", role: .destructive) { model.block(sender) }
        }
    }
}
