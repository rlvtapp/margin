import AuthenticationServices
import MailCore
import SwiftUI

/// A mailbox's out-of-office reply, kept by the provider so it answers while no device is on.
struct AutoReplySection: View {
    let model: MailModel
    let account: MailAccount
    @Environment(\.webAuthenticationSession) private var webAuthentication
    @State private var reply = AutoReply()
    @State private var loaded = false
    @State private var dated = false
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        Section {
            switch model.autoReplySupport(account) {
            case .unavailable:
                Text("This provider doesn't let apps set automatic replies. Use its website.").foregroundStyle(.secondary)
            case .needsAccess:
                Button("Set Up Automatic Replies…") { Task { await connect() } }
            case .ready:
                if loaded { editor } else { ProgressView().controlSize(.small).task { await load() } }
            }
        } header: {
            Text("Automatic reply")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sent by your provider while you're away, even when your devices are off.")
                if let problem { Text(verbatim: problem).foregroundStyle(Status.danger) }
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        Toggle("Reply automatically", isOn: $reply.isOn)
        if reply.isOn {
            Toggle("Only between dates", isOn: $dated)
            if dated {
                DatePicker("From", selection: Binding(get: { reply.start ?? Date() }, set: { reply.start = $0 }))
                DatePicker("Until", selection: Binding(get: { reply.end ?? Date().addingTimeInterval(7 * 86_400) }, set: { reply.end = $0 }))
            }
            if model.oauthProvider(of: account) != .microsoft {
                TextField("Subject", text: $reply.subject, prompt: Text("Out of office"))
            }
            TextEditor(text: $reply.message).frame(minHeight: 80)
            Toggle(model.oauthProvider(of: account) == .microsoft ? "Also reply outside my organization" : "Also reply to people who aren't in my contacts",
                   isOn: $reply.answersOutside)
        }
        Button(working ? "Saving…" : "Save Automatic Reply") { Task { await save() } }
            .disabled(working || (reply.isOn && reply.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
    }

    private func load() async {
        do {
            reply = try await model.autoReply(for: account)
            dated = reply.start != nil && reply.end != nil
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        loaded = true
    }

    private func save() async {
        working = true
        defer { working = false }
        var changed = reply
        if !dated { changed.start = nil; changed.end = nil } else {
            changed.start = changed.start ?? Date()
            changed.end = changed.end ?? Date().addingTimeInterval(7 * 86_400)
        }
        do {
            try await model.setAutoReply(changed, for: account)
            reply = changed
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func connect() async {
        do {
            try await model.requestAccess([.autoReply], for: account) { url, scheme in
                try await webAuthentication.authenticate(using: url, callbackURLScheme: scheme, preferredBrowserSession: .ephemeral)
            }
        } catch let failure as ASWebAuthenticationSessionError where failure.code == .canceledLogin {
            return
        } catch {
            problem = error.localizedDescription
        }
    }
}
