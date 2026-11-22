import MailCore
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Settings → AI Apps: let AI apps reach Margin over MCP, and say what they may do.
struct ConnectionsSettingsView: View {
    @Bindable var model: MailModel
    @State private var copied: String?

    var body: some View {
        let settings = model.connectionSettings
        Form {
            SettingsHeader(.connections)
            AIOffNotice(model: model)
            Section {
                Toggle(isOn: binding(\.enabled)) {
                    SettingLabel("Let AI apps use Margin",
                                 detail: "Claude, ChatGPT and other apps that support MCP can search and read your mail through Margin, on this Mac only.")
                }
                .disabled(!model.usesAI)
                if model.usesAI && settings.enabled { status }
                #if os(macOS)
                if settings.enabled {
                    Toggle(isOn: binding(\.answersWhileClosed)) {
                        SettingLabel("Answer while Margin is closed",
                                     detail: "AI apps can read your mail and calendar without Margin open: a small helper starts when they ask and quits after 5 quiet minutes. Off, they ask you to open Margin.")
                    }
                }
                #endif
            }
            if settings.enabled { Group {
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
                    Text("What AI apps may do", tableName: "Settings")
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
                    Text("Mailboxes AI apps can see", tableName: "Settings")
                } footer: {
                    Text("Junk, Trash and sign-in codes are never shown to AI apps.", tableName: "Settings")
                }
                #if os(macOS)
                Section {
                    MCPAddButtons(model: model)
                } header: {
                    Text("Add Margin to", tableName: "Settings")
                }
                #endif
                Section {
                    snippet(
                        String(localized: "Claude Desktop, ChatGPT and other apps (add to the app's MCP servers)", table: "Settings"),
                        """
                        {
                          "mcpServers": {
                            "margin": { "command": "\(Self.connectorPath)", "args": ["--mcp"] }
                          }
                        }
                        """
                    )
                    snippet(
                        String(localized: "Codex and the ChatGPT app (in Terminal, then restart the app)", table: "Settings"),
                        "codex mcp add margin -- \"\(Self.connectorPath)\" --mcp"
                    )
                    snippet(
                        String(localized: "Or in ~/.codex/config.toml", table: "Settings"),
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
                    Button(String(localized: "New token", table: "Settings")) { model.resetConnectionToken() }
                } header: {
                    #if os(macOS)
                    Text("Or add it by hand", tableName: "Settings")
                    #else
                    Text("Connect an app", tableName: "Settings")
                    #endif
                } footer: {
                    Text("The token in these lines lets an app read your mail. Keep it to yourself.", tableName: "Settings")
                }
                if !model.connectionActivity.isEmpty {
                    Section {
                        ForEach(model.connectionActivity.prefix(6)) { entry in
                            ActivityRow(entry: entry)
                        }
                    } header: {
                        Text("Recent activity", tableName: "Settings")
                    }
                }
            }.disabled(!model.usesAI) }
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
                Text("Running on 127.0.0.1:\(model.connectionSettings.port)", tableName: "Settings").foregroundStyle(.secondary)
            } icon: {
                Circle().fill(Color.green.opacity(0.8)).frame(width: 7, height: 7)
            }
        }
    }

    private func snippet(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: title).font(TypeScale.caption).foregroundStyle(.secondary)
                Spacer()
                Button(copied == title ? "Copied" : "Copy") { copy(text, title) }.buttonStyle(.borderless)
            }
            Text(verbatim: text)
                .font(.system(size: Look.size(11), design: .monospaced))
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
        case "list_mailboxes": String(localized: "Listed mailboxes", table: "Settings")
        case "search_mail": String(localized: "Searched mail", table: "Settings")
        case "read_conversation": String(localized: "Read a conversation", table: "Settings")
        case "create_draft": String(localized: "Opened a draft", table: "Settings")
        case "save_draft": String(localized: "Saved a draft", table: "Settings")
        case "update_draft": String(localized: "Changed a draft", table: "Settings")
        case "delete_draft": String(localized: "Deleted a draft", table: "Settings")
        case "list_drafts": String(localized: "Looked at drafts", table: "Settings")
        case "get_writing_style": String(localized: "Read your writing style", table: "Settings")
        case "list_groups": String(localized: "Looked at your groups", table: "Settings")
        case "list_to_sort": String(localized: "Looked at mail to sort", table: "Settings")
        case "skip_sorting": String(localized: "Sorted mail", table: "Settings")
        case "sort_into_group": String(localized: "Sorted mail", table: "Settings")
        case "create_group": String(localized: "Added a group", table: "Settings")
        case "list_rules": String(localized: "Looked at rules", table: "Settings")
        case "preview_rule": String(localized: "Checked a rule", table: "Settings")
        case "create_rule": String(localized: "Added a rule", table: "Settings")
        case "update_rule": String(localized: "Changed a rule", table: "Settings")
        case "delete_rule": String(localized: "Deleted a rule", table: "Settings")
        case "list_needs_you": String(localized: "Looked at what needs you", table: "Settings")
        case "find_people": String(localized: "Looked up people", table: "Settings")
        case "get_events", "get_event": String(localized: "Looked at your calendar", table: "Settings")
        case "list_calendars": String(localized: "Looked at your calendars", table: "Settings")
        case "list_reminders": String(localized: "Looked at your reminders", table: "Settings")
        case "find_free_time": String(localized: "Looked for free time", table: "Settings")
        case "get_free_busy": String(localized: "Checked when people are free", table: "Settings")
        case "suggest_meeting_times": String(localized: "Suggested meeting times", table: "Settings")
        case "create_event": String(localized: "Added an event", table: "Settings")
        case "move_event": String(localized: "Moved an event", table: "Settings")
        case "update_event": String(localized: "Changed an event", table: "Settings")
        case "delete_event": String(localized: "Deleted an event", table: "Settings")
        case "set_reminder_done": String(localized: "Changed a reminder", table: "Settings")
        case "create_reminder": String(localized: "Added a reminder", table: "Settings")
        case "archive": String(localized: "Archived mail", table: "Settings")
        case "set_read", "set_starred": String(localized: "Changed mail", table: "Settings")
        case "snooze": String(localized: "Snoozed mail", table: "Settings")
        case "unsnooze": String(localized: "Brought back snoozed mail", table: "Settings")
        case "move_to_folder": String(localized: "Moved mail", table: "Settings")
        case "list_folders": String(localized: "Listed folders", table: "Settings")
        case "list_labels": String(localized: "Listed labels", table: "Settings")
        case "get_selection": String(localized: "Looked at what you have open", table: "Settings")
        case "add_label": String(localized: "Added a label", table: "Settings")
        case "remove_label": String(localized: "Removed a label", table: "Settings")
        case "rename_label": String(localized: "Renamed a label", table: "Settings")
        case "delete_label": String(localized: "Deleted a label", table: "Settings")
        case "list_outbox": String(localized: "Looked at scheduled mail", table: "Settings")
        case "list_templates": String(localized: "Looked at templates", table: "Settings")
        case "list_newsletters": String(localized: "Looked at newsletters", table: "Settings")
        case "list_waiting": String(localized: "Looked at mail waiting for a reply", table: "Settings")
        case "read_attachment": String(localized: "Read an attachment", table: "Settings")
        case "open_in_margin": String(localized: "Opened something in Margin", table: "Settings")
        case "check_new_mail": String(localized: "Checked for new mail", table: "Settings")
        case "get_settings": String(localized: "Looked at settings", table: "Settings")
        case "trash": String(localized: "Moved mail to Trash", table: "Settings")
        case "mark_spam": String(localized: "Moved mail to Junk", table: "Settings")
        case "list_spam": String(localized: "Looked at Junk", table: "Settings")
        case "not_spam": String(localized: "Took mail out of Junk", table: "Settings")
        case "stop_waiting": String(localized: "Stopped waiting for a reply", table: "Settings")
        case "unsubscribe": String(localized: "Unsubscribed from a newsletter", table: "Settings")
        case "archive_newsletter": String(localized: "Archived a newsletter", table: "Settings")
        case "create_folder", "rename_folder", "delete_folder", "hide_folder": String(localized: "Changed a folder", table: "Settings")
        case "save_template", "update_template", "delete_template": String(localized: "Changed a template", table: "Settings")
        case "reschedule", "cancel_scheduled": String(localized: "Changed scheduled mail", table: "Settings")
        case "send_now": String(localized: "Sent scheduled mail", table: "Settings")
        case "add_to_calendar": String(localized: "Added an invitation to Calendar", table: "Settings")
        case "respond_to_invite": String(localized: "Answered an invitation", table: "Settings")
        case "undo_last": String(localized: "Undid its last change", table: "Settings")
        case "change_settings": String(localized: "Changed settings", table: "Settings")
        case "set_signature": String(localized: "Changed a signature", table: "Settings")
        case "send_email": String(localized: "Sent an email", table: "Settings")
        default: tool
        }
    }
}
