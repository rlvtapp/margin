import MailCore
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Settings → Connections: let AI apps reach Margin over MCP, and say what they may do.
struct ConnectionsSettingsView: View {
    @Bindable var model: MailModel
    @State private var copied: String?

    var body: some View {
        let settings = model.connectionSettings
        Form {
            SettingsHeader(.connections)
            Section {
                Toggle(isOn: binding(\.enabled)) {
                    SettingLabel("Let AI apps use Margin",
                                 detail: "Claude, ChatGPT and other apps that support MCP can search and read your mail through Margin, on this Mac only.")
                }
                if settings.enabled { status }
            }
            if settings.enabled {
                Section {
                    Toggle(isOn: binding(\.allowChanges)) {
                        SettingLabel("Allow changes",
                                     detail: "Label, archive, move, snooze, trash, folders, templates, newsletters and the outbox. Apps can undo their own last change.")
                    }
                    Toggle(isOn: binding(\.allowSettings)) {
                        SettingLabel("Allow settings changes",
                                     detail: "Appearance, layout, Undo Send, follow-up time and signatures.")
                    }
                    Toggle(isOn: binding(\.allowSending)) {
                        SettingLabel("Allow sending",
                                     detail: "Off means apps can only open a draft in Margin for you to send yourself.")
                    }
                } header: {
                    Text("What AI apps may do")
                }
                Section {
                    ForEach(model.accounts) { account in
                        Toggle(isOn: Binding(
                            get: { !model.connectionSettings.hiddenAccounts.contains(account.id) },
                            set: { visible in
                                var settings = model.connectionSettings
                                settings.hiddenAccounts.removeAll { $0 == account.id }
                                if !visible { settings.hiddenAccounts.append(account.id) }
                                model.applyConnections(settings)
                            }
                        )) {
                            HStack(spacing: Space.s) {
                                AccountMark(account, size: 18)
                                Text(account.label)
                            }
                        }
                    }
                } header: {
                    Text("Mailboxes AI apps can see")
                } footer: {
                    Text("Junk, Trash and sign-in codes are never shown to AI apps.")
                }
                #if os(macOS)
                Section {
                    MCPAddButtons(model: model)
                } header: {
                    Text("Add Margin to")
                }
                #endif
                Section {
                    snippet(
                        String(localized: "Claude Desktop, ChatGPT and other apps (add to the app's MCP servers)"),
                        """
                        {
                          "mcpServers": {
                            "margin": { "command": "\(Self.connectorPath)", "args": ["--mcp"] }
                          }
                        }
                        """
                    )
                    snippet(
                        String(localized: "Codex and the ChatGPT app (in Terminal, then restart the app)"),
                        "codex mcp add margin -- \"\(Self.connectorPath)\" --mcp"
                    )
                    snippet(
                        String(localized: "Or in ~/.codex/config.toml"),
                        """
                        [mcp_servers.margin]
                        command = "\(Self.connectorPath)"
                        args = ["--mcp"]
                        startup_timeout_sec = 30
                        """
                    )
                    snippet(
                        "Claude Code",
                        "claude mcp add --transport http margin \(model.connectionURL) --header \"Authorization: Bearer \(model.connectionToken)\""
                    )
                    Button("New token") { model.resetConnectionToken() }
                } header: {
                    #if os(macOS)
                    Text("Or add it by hand")
                    #else
                    Text("Connect an app")
                    #endif
                } footer: {
                    Text("The token in these lines lets an app read your mail. Keep it to yourself.")
                }
                if !model.connectionActivity.isEmpty {
                    Section {
                        ForEach(model.connectionActivity.prefix(6)) { entry in
                            ActivityRow(entry: entry)
                        }
                    } header: {
                        Text("Recent activity")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.startConnectionIfEnabled() }
    }

    @ViewBuilder
    private var status: some View {
        if let error = model.connectionError {
            Text(error).foregroundStyle(Status.danger)
        } else {
            Label {
                Text("Running on 127.0.0.1:\(model.connectionSettings.port)").foregroundStyle(.secondary)
            } icon: {
                Circle().fill(Color.green.opacity(0.8)).frame(width: 7, height: 7)
            }
        }
    }

    private func snippet(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(copied == title ? "Copied" : "Copy") { copy(text, title) }.buttonStyle(.borderless)
            }
            Text(verbatim: text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private func copy(_ text: String, _ title: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        copied = title
    }

    private func binding(_ keyPath: WritableKeyPath<ConnectionSettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.connectionSettings[keyPath: keyPath] }, set: { value in
            var settings = model.connectionSettings
            settings[keyPath: keyPath] = value
            model.applyConnections(settings)
        })
    }

    static var executablePath: String { Bundle.main.executablePath ?? "/Applications/Margin.app/Contents/MacOS/Margin" }

    /// The Margin other apps launch: the copy in Applications on the Mac.
    static var connectorPath: String {
        #if os(macOS)
        MCPInstaller.executable
        #else
        executablePath
        #endif
    }

    static func describe(_ tool: String) -> String {
        switch tool {
        case "list_mailboxes": String(localized: "Listed mailboxes")
        case "search_mail": String(localized: "Searched mail")
        case "read_conversation": String(localized: "Read a conversation")
        case "create_draft": String(localized: "Opened a draft")
        case "save_draft": String(localized: "Saved a draft")
        case "update_draft": String(localized: "Changed a draft")
        case "delete_draft": String(localized: "Deleted a draft")
        case "list_drafts": String(localized: "Looked at drafts")
        case "get_writing_style": String(localized: "Read your writing style")
        case "list_groups": String(localized: "Looked at your groups")
        case "list_to_sort": String(localized: "Looked at mail to sort")
        case "skip_sorting": String(localized: "Sorted mail")
        case "sort_into_group": String(localized: "Sorted mail")
        case "create_group": String(localized: "Added a group")
        case "list_rules": String(localized: "Looked at rules")
        case "preview_rule": String(localized: "Checked a rule")
        case "create_rule": String(localized: "Added a rule")
        case "update_rule": String(localized: "Changed a rule")
        case "delete_rule": String(localized: "Deleted a rule")
        case "list_needs_you": String(localized: "Looked at what needs you")
        case "find_people": String(localized: "Looked up people")
        case "archive": String(localized: "Archived mail")
        case "set_read", "set_starred": String(localized: "Changed mail")
        case "snooze": String(localized: "Snoozed mail")
        case "unsnooze": String(localized: "Brought back snoozed mail")
        case "move_to_folder": String(localized: "Moved mail")
        case "list_folders": String(localized: "Listed folders")
        case "list_labels": String(localized: "Listed labels")
        case "get_selection": String(localized: "Looked at what you have open")
        case "add_label": String(localized: "Added a label")
        case "remove_label": String(localized: "Removed a label")
        case "rename_label": String(localized: "Renamed a label")
        case "delete_label": String(localized: "Deleted a label")
        case "list_outbox": String(localized: "Looked at scheduled mail")
        case "list_templates": String(localized: "Looked at templates")
        case "list_newsletters": String(localized: "Looked at newsletters")
        case "list_waiting": String(localized: "Looked at mail waiting for a reply")
        case "read_attachment": String(localized: "Read an attachment")
        case "open_in_margin": String(localized: "Opened something in Margin")
        case "check_new_mail": String(localized: "Checked for new mail")
        case "get_settings": String(localized: "Looked at settings")
        case "trash": String(localized: "Moved mail to Trash")
        case "mark_spam": String(localized: "Moved mail to Junk")
        case "list_spam": String(localized: "Looked at Junk")
        case "not_spam": String(localized: "Took mail out of Junk")
        case "stop_waiting": String(localized: "Stopped waiting for a reply")
        case "unsubscribe": String(localized: "Unsubscribed from a newsletter")
        case "archive_newsletter": String(localized: "Archived a newsletter")
        case "create_folder", "rename_folder", "delete_folder", "hide_folder": String(localized: "Changed a folder")
        case "save_template", "update_template", "delete_template": String(localized: "Changed a template")
        case "reschedule", "cancel_scheduled": String(localized: "Changed scheduled mail")
        case "send_now": String(localized: "Sent scheduled mail")
        case "add_to_calendar": String(localized: "Added an invitation to Calendar")
        case "respond_to_invite": String(localized: "Answered an invitation")
        case "undo_last": String(localized: "Undid its last change")
        case "change_settings": String(localized: "Changed settings")
        case "set_signature": String(localized: "Changed a signature")
        case "send_email": String(localized: "Sent an email")
        default: tool
        }
    }
}
