import Foundation
import UniformTypeIdentifiers

/// Attachments come from strangers: their names can hide what they are, and some kinds run
/// code the moment they're opened. Margin opens documents and pictures, and only shows the rest.
public enum AttachmentSafety {
    /// Kinds that run something when opened: apps, installers, scripts, shortcuts to places,
    /// system settings profiles.
    static let riskyExtensions: Set<String> = [
        "app", "command", "sh", "bash", "zsh", "csh", "ksh", "fish", "tool", "terminal", "pkg", "mpkg",
        "scpt", "scptd", "applescript", "workflow", "action", "jar", "py", "pyc", "pl", "rb", "php",
        "webloc", "inetloc", "fileloc", "url", "mobileconfig", "osax", "kext", "prefpane", "saver",
        "plugin", "bundle", "xpc", "service", "definition", "shortcut", "exe", "bat", "cmd", "msi",
        "ps1", "vbs", "js", "jse", "wsf", "hta", "scr", "lnk", "dylib", "so",
    ]

    /// Whether opening it straight from mail could run code.
    public static func isRisky(filename: String) -> Bool {
        let ext = (safeFilename(filename) as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        if riskyExtensions.contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .executable) || type.conforms(to: .applicationBundle) || type.conforms(to: .script)
            || type.conforms(to: .shellScript)
    }

    /// A name that is what it says: no folders in it, no characters that flip the text's
    /// direction (so "invoice‮fdp.command" can't pass for a PDF), no invisible characters, and
    /// not hidden by a leading dot.
    public static func safeFilename(_ name: String) -> String {
        let invisible = CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}\u{FEFF}")
        var cleaned = String(String.UnicodeScalarView(name.unicodeScalars.filter {
            !invisible.contains($0) && !CharacterSet.controlCharacters.contains($0)
        }))
        cleaned = cleaned.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        return String(cleaned.prefix(200))
    }
}
