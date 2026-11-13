#if os(iOS)
import MailCore
import SwiftUI

/// Keys for iPad with a keyboard, the same ones as Mail on the Mac. They also fill the
/// menu bar iPadOS shows at the top of the screen.
public struct TouchCommands: Commands {
    let model: MailModel

    public init(model: MailModel) {
        self.model = model
    }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") { model.startCompose() }
                .keyboardShortcut("n")
            Button("New Meeting") { model.isNewMeetingOpen = true }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }
        CommandMenu("Message") {
            Button("Reply") { model.startReply() }
                .keyboardShortcut("r")
            Button("Reply All") { model.startReply(all: true) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Forward") { model.startForward() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button("Archive") { model.perform(.done) }
                .keyboardShortcut("a", modifiers: [.command, .control])
            Button("Move to Trash") { model.perform(.trash) }
                .keyboardShortcut(.delete, modifiers: .command)
            Button("Mark as Read or Unread") { model.toggleRead() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            Button("Star") { model.toggleStar() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            Button("Next Conversation") { model.moveSelection(1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button("Previous Conversation") { model.moveSelection(-1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Divider()
            // Only with an assistant to ask: Apple Intelligence on the device, or another service.
            Button("Ask About Your Mail") { model.isAsking = true }
                .keyboardShortcut("k")
                .disabled(!model.isAssistantOn)
            Button("Sort My Mail") { model.sortMailWithAssistant() }
                .disabled(!model.isAssistantOn)
            Button("Ask Margin To…") { model.isAgentPromptOpen = true }
                .disabled(!model.isAssistantOn)
            Button("Check for New Mail") { Task { await model.reload() } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }
}
#endif
