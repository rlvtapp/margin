#if os(macOS)
import AppKit

/// Keeps the keys that edit text for the text. ⌘⌫ deletes back to the start of the line in any
/// Mac text field, but it's also the menu's shortcut for Move to Trash, and menus see a shortcut
/// before the text does: so clearing a line while writing trashed the selected conversation.
/// While the keyboard is in a text field or editor, ⌘⌫ now goes to the text and stops there.
@MainActor
public enum TextEditingKeys {
    private static var monitor: Any?

    public static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            nonisolated(unsafe) let event = event
            let taken = MainActor.assumeIsolated { handle(event) }
            return taken ? nil : event
        }
    }

    /// Whether the key was given to the text being edited instead of the menus.
    static func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // 51 is the Delete (Backspace) key.
        guard event.keyCode == 51, modifiers == .command,
              let text = event.window?.firstResponder as? NSTextView, text.isEditable else { return false }
        text.doCommand(by: #selector(NSStandardKeyBindingResponding.deleteToBeginningOfLine(_:)))
        return true
    }
}
#endif
