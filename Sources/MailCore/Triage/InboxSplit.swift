import Foundation

/// The inbox in three parts, decided on the device from standard headers, and for automated
/// mail without them, from the assistant's verdict when there is one (`MailVerdicts`).
public enum InboxSplit: String, CaseIterable, Codable, Sendable {
    /// Written by a person to you.
    case people
    /// Sent by a system: receipts, alerts, sign-in codes, notifications.
    case updates
    /// Lists and newsletters: anything with List-Id or List-Unsubscribe.
    case newsletters

    public var title: String {
        switch self {
        case .people: String(localized: "People")
        case .updates: String(localized: "Updates")
        case .newsletters: String(localized: "Newsletters")
        }
    }

    /// The inbox tab it's shown under: Important for people, Other for the rest.
    public var tabTitle: String {
        self == .people ? String(localized: "Important") : String(localized: "Other")
    }

    /// The two inbox tabs beside All, by the part each opens with.
    public static let tabs: [InboxSplit] = [.people, .updates]

    /// Headers that bulk-sending services add. Mail without list headers still carries these
    /// when it was sent in bulk (Gmail asks bulk senders for Feedback-ID).
    static let bulkHeaders = ["feedback-id", "x-csa-complaints", "x-mailgun-sid", "x-ses-outgoing", "x-sg-eid", "x-mc-user"]

    /// The list headers as they're kept in memory and saved: only what's read. `References` is
    /// already on the message, parsed; bulk-sending headers are only checked for being there,
    /// and some (SendGrid's) run to hundreds of characters on every message from that sender.
    public static func compact(_ headers: [String: String]) -> [String: String] {
        guard headers["references"] != nil || bulkHeaders.contains(where: { !(headers[$0] ?? "").isEmpty }) else { return headers }
        var kept = headers
        kept["references"] = nil
        for name in bulkHeaders where kept[name] != nil { kept[name] = "" }
        return kept
    }

    public static func classify(_ message: MailMessage) -> InboxSplit {
        let headers = message.listHeaders
        if headers["list-id"] != nil || headers["list-unsubscribe"] != nil {
            return .newsletters
        }
        if let precedence = headers["precedence"]?.lowercased(), ["bulk", "list"].contains(precedence) {
            return .newsletters
        }
        // A calendar's automatic answer or cancellation isn't a person writing.
        if message.calendarMethod == "REPLY" || message.calendarMethod == "CANCEL" { return .updates }
        // Nor is a reaction ("Jane reacted to your message"); it shows on the message it answers.
        if MailReaction.detect(message, text: message.snippet) != nil { return .updates }
        if let auto = headers["auto-submitted"]?.lowercased(), auto != "no" {
            return .updates
        }
        if bulkHeaders.contains(where: { headers[$0] != nil }) { return .updates }
        // Automated mail without those headers: only the assistant can tell (`MailVerdicts`).
        if MailVerdicts.shared[message]?.automated == true { return .updates }
        return .people
    }
}
