import MailCore
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The card that opens from a person's name: who they are, your mail with them, and what you
/// can do (write, see all mail, copy the address, pictures, block). Everything comes from this
/// device.
struct PersonCard: View {
    let model: MailModel
    let person: EmailAddress
    @State private var summary: PersonSummary?
    @State private var confirmsBlock = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let shown = summary?.address ?? person
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.m) {
                Avatar(shown, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: shown.displayName).font(TypeScale.heading).foregroundStyle(Ink.primary).lineLimit(1)
                    Text(verbatim: shown.address).font(TypeScale.label).foregroundStyle(Ink.secondary).lineLimit(1)
                        .textSelection(.enabled)
                    if let summary, summary.inContacts {
                        Label("In your contacts", systemImage: "person.crop.circle.badge.checkmark")
                            .font(TypeScale.caption).foregroundStyle(Ink.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: Space.s) {
                action("square.and.pencil", "Write") { dismiss(); model.startCompose(to: shown) }
                action("tray.full", "All mail") { dismiss(); model.showMail(with: shown) }
                action("doc.on.doc", "Copy") { copy(shown.address) }
            }

            if let summary {
                if summary.messageCount > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: history(summary)).font(TypeScale.label).foregroundStyle(Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !summary.recent.isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(summary.recent, id: \.id) { message in
                                    HStack(spacing: Space.s) {
                                        Text(verbatim: message.subject.isEmpty ? String(localized: "(No subject)") : message.subject)
                                            .font(TypeScale.row).foregroundStyle(Ink.primary).lineLimit(1)
                                        Spacer(minLength: Space.s)
                                        Text(verbatim: RowDate.string(message.date))
                                            .font(TypeScale.label.monospacedDigit()).foregroundStyle(Ink.tertiary)
                                    }
                                    .padding(.vertical, 5)
                                }
                            }
                            .padding(.top, 2)
                        }
                    }
                } else {
                    Text("No mail with them on this device yet.").font(TypeScale.label).foregroundStyle(Ink.tertiary)
                }
                if !summary.otherAddresses.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Also").font(TypeScale.caption).foregroundStyle(Ink.tertiary)
                        ForEach(summary.otherAddresses, id: \.self) { other in
                            Text(verbatim: other).font(TypeScale.label).foregroundStyle(Ink.secondary).textSelection(.enabled)
                        }
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }

            Rectangle().fill(Line.hairline).frame(height: 1)
            VStack(alignment: .leading, spacing: Space.s) {
                Toggle(isOn: Binding(get: { model.trustsPictures(from: shown) }, set: { model.setTrustsPictures(shown, $0) })) {
                    Text("Always load pictures").font(TypeScale.row)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                if model.isBlocked(shown) {
                    Button("Unblock") { model.unblock(shown.address) }.buttonStyle(.plain).font(TypeScale.row).foregroundStyle(Ink.secondary)
                } else {
                    Button("Block…") { confirmsBlock = true }.buttonStyle(.plain).font(TypeScale.row).foregroundStyle(Status.danger)
                }
            }
        }
        .padding(Space.l)
        .frame(width: 320)
        .task(id: person.address) { summary = await model.personSummary(person) }
        .confirmationDialog("Block \(shown.displayName)?", isPresented: $confirmsBlock) {
            Button("Block", role: .destructive) { dismiss(); model.block(shown) }
        } message: {
            Text("Their mail in the inbox goes to Trash now, and so does new mail from them.")
        }
    }

    private func action(_ symbol: String, _ title: LocalizedStringKey, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: Look.size(14)))
                Text(title).font(TypeScale.caption)
            }
            .foregroundStyle(Ink.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Fill.one, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "12 messages since March 2025 · they wrote 7, you wrote 5"
    private func history(_ summary: PersonSummary) -> String {
        let count = summary.messageCount == 1 ? String(localized: "1 message") : String(localized: "\(summary.messageCount) messages")
        var line = count
        if let first = summary.first {
            line += " · " + String(localized: "since \(first.formatted(.dateTime.month(.wide).year()))")
        }
        if summary.fromYou > 0 {
            line += " · " + String(localized: "they wrote \(summary.fromThem), you wrote \(summary.fromYou)")
        }
        return line
    }

    private func copy(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
        model.notice = Notice(text: String(localized: "Address copied"))
    }
}

/// A message as the server keeps it: its headers, one per line, and the full source, to copy
/// or save as a .eml file. For checking what a sender's server really sent.
struct MessageSourceView: View {
    let model: MailModel
    let message: MailMessage
    let thread: MailThread
    @State private var source: String?
    @State private var failure: String?
    @State private var showsRaw = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.s) {
                Text("Message source").font(TypeScale.heading).foregroundStyle(Ink.primary)
                Picker("Show", selection: $showsRaw) {
                    Text("Headers").tag(false)
                    Text("Raw").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if let source {
                    Button("Copy") { copy(showsRaw ? source : headers(of: source)) }.buttonStyle(QuietButtonStyle())
                    ShareLink(item: EMLFile(text: source, name: fileName), preview: SharePreview(fileName)) {
                        Text("Save .eml")
                    }
                    .buttonStyle(QuietButtonStyle())
                }
                Button("Done") { dismiss() }.buttonStyle(InkButtonStyle()).keyboardShortcut(.cancelAction)
            }
            .padding(Space.l)
            Rectangle().fill(Line.hairline).frame(height: 1)
            Group {
                if let source {
                    ScrollView([.vertical, .horizontal]) {
                        Text(verbatim: showsRaw ? Self.capped(source) : headers(of: source))
                            .font(.system(size: Look.size(12), design: .monospaced))
                            .foregroundStyle(Ink.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Space.l)
                    }
                } else if let failure {
                    ListMessage(title: "Couldn't load the source", verbatimDetail: failure, action: nil)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #if os(macOS)
        .frame(minWidth: 720, idealWidth: 860, minHeight: 520, idealHeight: 640)
        #endif
        .background(Paper.popover)
        .task {
            do { source = try await model.rawSource(of: message, in: thread) } catch { failure = error.localizedDescription }
        }
    }

    private var fileName: String {
        let base = message.subject.isEmpty ? "message" : String(message.subject.prefix(60))
        return base.replacingOccurrences(of: "/", with: "-") + ".eml"
    }

    /// The header block, with folded lines kept together.
    private func headers(of source: String) -> String {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        return normalized.components(separatedBy: "\n\n").first ?? normalized
    }

    /// Very large messages (attachments) are shown up to 2 MB; Save keeps all of it.
    static func capped(_ text: String) -> String {
        let limit = 2_000_000
        guard text.utf8.count > limit else { return text }
        return String(text.prefix(limit)) + "\n\n" + String(localized: "… shortened here. Save .eml for the whole message.")
    }

    private func copy(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}

/// A message source handed to the share sheet or saved as a file.
struct EMLFile: Transferable {
    let text: String
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .init(filenameExtension: "eml") ?? .data) { file in
            let url = FileManager.default.temporaryDirectory.appending(path: file.name)
            try Data(file.text.utf8).write(to: url)
            return SentTransferredFile(url)
        }
    }
}
