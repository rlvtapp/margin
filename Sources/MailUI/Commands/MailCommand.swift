import MailCore
import SwiftUI

/// Everything the app can do, in one list: the command palette shows it, the shortcut
/// sheet documents it, and the key handler runs it. Adding a command here is enough.
struct MailCommand: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let keys: [String]
    let needsThread: Bool
    var needsAssistant = false
    let run: @MainActor (MailModel) -> Void

    init(id: String, title: String.LocalizationValue, symbol: String, keys: [String], needsThread: Bool, needsAssistant: Bool = false,
         run: @escaping @MainActor (MailModel) -> Void) {
        self.id = id
        self.title = String(localized: title)
        self.symbol = symbol
        self.keys = keys
        self.needsThread = needsThread
        self.needsAssistant = needsAssistant
        self.run = run
    }

    @MainActor static func all(for model: MailModel) -> [MailCommand] {
        var commands: [MailCommand] = [
            .init(id: "compose", title: "New message", symbol: "square.and.pencil", keys: ["C"], needsThread: false) { $0.startCompose() },
            .init(id: "meeting", title: "New meeting", symbol: "calendar.badge.plus", keys: [], needsThread: false) { $0.isNewMeetingOpen = true },
            .init(id: "reply", title: "Reply", symbol: "arrowshape.turn.up.left", keys: ["R"], needsThread: true) { $0.startReply() },
            .init(id: "replyAll", title: "Reply all", symbol: "arrowshape.turn.up.left.2", keys: ["A"], needsThread: true) { $0.startReply(all: true) },
            .init(id: "forward", title: "Forward", symbol: "arrowshape.turn.up.right", keys: ["F"], needsThread: true) { $0.startForward() },
            .init(id: "done", title: "Mark done", symbol: "checkmark", keys: ["E"], needsThread: true) { $0.perform(.done) },
            .init(id: "star", title: "Star or unstar", symbol: "star", keys: ["S"], needsThread: true) { $0.toggleStar() },
            .init(id: "read", title: "Mark read or unread", symbol: "envelope.badge", keys: ["U"], needsThread: true) { $0.toggleRead() },
            .init(id: "trash", title: "Move to Trash", symbol: "trash", keys: ["#"], needsThread: true) { $0.perform(.trash) },
            .init(id: "ask", title: "Ask about your mail", symbol: "text.bubble", keys: ["Q"], needsThread: false, needsAssistant: true) {
                $0.isAsking = true
            },
            .init(id: "agent.sort", title: "Sort my mail", symbol: "wand.and.stars", keys: [], needsThread: false, needsAssistant: true) {
                $0.sortMailWithAssistant()
            },
            .init(id: "agent.ask", title: "Ask Margin to…", symbol: "sparkles", keys: [], needsThread: false, needsAssistant: true) { model in
                #if os(macOS)
                // The palette stays open for the rest of the sentence.
                model.paletteSeed = CommandPalette.agentPrefix
                model.isPaletteOpen = true
                #else
                model.isAgentPromptOpen = true
                #endif
            },
            .init(id: "summarize", title: "Summarize conversation", symbol: "text.alignleft", keys: ["M"], needsThread: true, needsAssistant: true) {
                $0.summarizeSelected()
            },
            .init(id: "labels", title: "Suggest labels", symbol: "tag", keys: ["L"], needsThread: true, needsAssistant: true) {
                $0.suggestLabelsForSelected()
            },
            .init(id: "draft", title: "Draft a reply", symbol: "pencil.line", keys: ["D"], needsThread: true, needsAssistant: true) {
                $0.writeReply(.draft(note: nil))
            },
            .init(id: "snooze", title: "Snooze…", symbol: "clock", keys: ["H"], needsThread: true) { model in
                model.paletteSeed = String(localized: "Snooze", comment: "Palette search text; must match the start of the “Snooze: …” commands")
                model.isPaletteOpen = true
            },
            .init(id: "select", title: "Select conversation", symbol: "checkmark.circle", keys: ["X"], needsThread: true) { model in
                if let id = model.selectedThreadID { model.toggleSelection(id) }
            },
            .init(id: "followUp", title: "Follow up", symbol: "arrowshape.turn.up.right", keys: ["W"], needsThread: true) { $0.followUp() },
            .init(id: "undo", title: "Undo", symbol: "arrow.uturn.backward", keys: ["Z"], needsThread: false) { $0.undo() },
            .init(id: "next", title: "Next conversation", symbol: "arrow.down", keys: ["J"], needsThread: false) { $0.moveSelection(1) },
            .init(id: "previous", title: "Previous conversation", symbol: "arrow.up", keys: ["K"], needsThread: false) { $0.moveSelection(-1) },
            .init(id: "search", title: "Search", symbol: "magnifyingglass", keys: ["/"], needsThread: false) { $0.searchRequest += 1 },
            .init(id: "refresh", title: "Check for new mail", symbol: "arrow.clockwise", keys: ["⇧", "⌘", "N"], needsThread: false) { model in
                Task { await model.reload() }
            },
            .init(id: "inbox", title: "Go to Inbox", symbol: "tray", keys: ["⌘", "1"], needsThread: false) {
                $0.go(to: .inbox(account: $0.place.accountID, split: nil))
            },
        ]
        for (index, split) in InboxSplit.allCases.enumerated() {
            commands.append(.init(id: "go.\(split.rawValue)", title: "Go to \(split.title)", symbol: "line.3.horizontal.decrease", keys: ["⌘", "\(index + 2)"], needsThread: false) {
                $0.go(to: .inbox(account: $0.place.accountID, split: split))
            })
        }
        commands.append(.init(id: "go.starred", title: "Go to Starred", symbol: "star", keys: [], needsThread: false) {
            $0.go(to: .starred(account: $0.place.accountID))
        })
        commands.append(.init(id: "go.all", title: "Go to All inboxes", symbol: "tray.2", keys: ["⌃", "1"], needsThread: false) { $0.go(to: .allInboxes) })
        for role in model.combinedRoles {
            let title: String.LocalizationValue = model.accounts.count > 1 ? "Go to \(role.title) in all mailboxes" : "Go to \(role.title)"
            commands.append(.init(id: "go.combined.\(role.rawValue)", title: title, symbol: "tray.2", keys: [], needsThread: false) {
                $0.go(to: .combined(role))
            })
        }
        for (index, account) in model.accounts.enumerated() {
            commands.append(.init(id: "account.\(account.id)", title: "Go to \(account.label)", symbol: "tray",
                                  keys: index < 8 ? ["⌃", "\(index + 2)"] : [], needsThread: false) {
                $0.go(to: .inbox(account: account.id, split: nil))
            })
            for mailbox in model.folders(of: account.id) {
                let title: String.LocalizationValue = model.accounts.count > 1 ? "Go to \(mailbox.name) in \(account.label)" : "Go to \(mailbox.name)"
                commands.append(.init(id: "go.box.\(account.id).\(mailbox.id)", title: title, symbol: SidebarView.symbol(mailbox.role), keys: [], needsThread: false) {
                    $0.go(to: .mailbox(account: account.id, mailbox))
                })
            }
        }
        for preset in SnoozePreset.allCases {
            let date = preset.date()
            commands.append(.init(id: "snooze.\(preset.rawValue)", title: "Snooze: \(preset.title) (\(date.formatted(.dateTime.weekday(.abbreviated).hour().minute())))",
                                  symbol: "clock", keys: [], needsThread: true) { $0.snooze(until: date) })
        }
        commands.append(.init(id: "snooze.pick", title: "Snooze: Pick a date…", symbol: "calendar", keys: [], needsThread: true) {
            $0.isPickingSnoozeDate = true
        })
        commands += [
            .init(id: "go.snoozed", title: "Go to Snoozed", symbol: "clock", keys: [], needsThread: false) { $0.go(to: .snoozed(account: $0.place.accountID)) },
            .init(id: "go.waiting", title: "Go to Waiting for reply", symbol: "arrowshape.turn.up.backward.badge.clock", keys: [], needsThread: false) {
                $0.go(to: .waiting(account: $0.place.accountID))
            },
            .init(id: "go.subscriptions", title: "Go to Subscriptions", symbol: "newspaper", keys: [], needsThread: false) { $0.go(to: .subscriptions) },
            .init(id: "go.scheduled", title: "Go to Scheduled", symbol: "paperplane.circle", keys: [], needsThread: false) { $0.go(to: .scheduled) },
            .init(id: "selectAll", title: "Select all conversations", symbol: "checklist", keys: ["⌘", "A"], needsThread: false) { $0.selectAll() },
            .init(id: "filter.unread", title: "Show only unread", symbol: "circle.fill", keys: [], needsThread: false) { model in
                if model.quickFilters.contains(.unread) { model.quickFilters.remove(.unread) } else { model.quickFilters.insert(.unread) }
            },
            .init(id: "textBigger", title: "Make text bigger", symbol: "textformat.size.larger", keys: ["⌘", "+"], needsThread: false) {
                $0.textScale = min($0.textScale + 0.1, 2)
            },
            .init(id: "textSmaller", title: "Make text smaller", symbol: "textformat.size.smaller", keys: ["⌘", "−"], needsThread: false) {
                $0.textScale = max($0.textScale - 0.1, 0.8)
            },
        ]
        if let thread = model.selectedThread, let accountID = thread.accountID {
            commands.append(.init(id: "moveTo", title: "Move to…", symbol: "folder", keys: ["V"], needsThread: true) { model in
                model.paletteSeed = String(localized: "Move to", comment: "Palette search text; must match the start of the “Move to …” commands")
                model.isPaletteOpen = true
            })
            for mailbox in model.folders(of: accountID) where mailbox.role == .other || mailbox.role == .archive {
                let name = model.accounts.count > 1 ? "\(mailbox.name) (\(model.account(accountID)?.label ?? ""))" : mailbox.name
                commands.append(.init(id: "moveTo.\(mailbox.id)", title: "Move to \(name)", symbol: "folder", keys: [], needsThread: true) {
                    $0.move(to: mailbox)
                })
            }
        }
        if let thread = model.selectedThread {
            if model.unsubscribeMethod(for: thread) != nil {
                commands.append(.init(id: "unsubscribe", title: "Unsubscribe", symbol: "minus.circle", keys: [], needsThread: true) { $0.unsubscribe(thread) })
            }
            commands.append(.init(id: "archiveSender", title: "Archive everything from \(thread.latest.from.displayName)", symbol: "archivebox", keys: [], needsThread: true) {
                $0.archiveAll(from: thread)
            })
            if let code = model.signInCode(in: thread) {
                commands.append(.init(id: "copyCode", title: "Copy code \(code)", symbol: "number", keys: [], needsThread: true) {
                    $0.copy(code, announce: "Code copied")
                })
            }
        }
        for template in model.templates {
            commands.append(.init(id: "template.\(template.id)", title: "Insert template: \(template.name)", symbol: "doc.on.doc", keys: [], needsThread: false) {
                $0.insertTemplate(template)
            })
        }
        commands += [
            .init(id: "addAccount", title: "Add account", symbol: "plus", keys: [], needsThread: false) { $0.isAddingAccount = true },
            .init(id: "sidebar", title: "Show or hide the sidebar", symbol: "sidebar.left", keys: ["⌃", "⌘", "S"], needsThread: false) {
                $0.isSidebarHidden.toggle()
            },
            .init(id: "shortcuts", title: "Keyboard shortcuts", symbol: "keyboard", keys: ["?"], needsThread: false) { $0.isShowingShortcuts = true },
        ]
        return commands.filter { !$0.needsAssistant || model.isAssistantOn }
    }

    /// Single-key commands, as typed (lowercase letters, symbols as themselves).
    /// The single key a command answers to, after the person's changes.
    @MainActor func key(in model: MailModel) -> String? {
        if let changed = model.keyOverrides[id] { return changed.isEmpty ? nil : changed }
        return keys.count == 1 ? keys[0] : nil
    }

    @MainActor static func forKey(_ character: String, model: MailModel) -> MailCommand? {
        guard model.singleKeyShortcuts else { return nil }
        return all(for: model).first { $0.key(in: model)?.lowercased() == character.lowercased() }
    }
}

/// Ready-made sets of single-key shortcuts, so people can keep the keys they know.
public enum ShortcutPreset: String, CaseIterable, Identifiable, Sendable {
    case margin, gmail, superhuman, appleMail

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .margin: "Margin"
        case .gmail: "Gmail"
        case .superhuman: "Superhuman"
        case .appleMail: "Apple Mail"
        }
    }

    /// Keys that differ from Margin's own, by command id.
    var overrides: [String: String] {
        switch self {
        case .margin, .superhuman, .appleMail: [:]
        case .gmail: ["snooze": "B", "read": "I", "followUp": "", "summarize": "", "draft": ""]
        }
    }

    /// Apple Mail has no single-key shortcuts; its ⌘ keys are in the Message menu.
    var usesSingleKeys: Bool { self != .appleMail }
}
