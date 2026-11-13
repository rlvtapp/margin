import Foundation

/// The inbox in three parts, decided on the device from standard headers. No message
/// content leaves the device to be classified.
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

    private static let automatedLocalParts = [
        "noreply", "no-reply", "no_reply", "donotreply", "do-not-reply", "notifications", "notification",
        "notify", "alerts", "alert", "mailer-daemon", "postmaster", "bounce", "bounces", "receipts",
        "billing", "security", "updates", "accounts", "service", "services", "receipt", "invoice", "invoices",
        "payments", "orders", "order", "reminders", "reminder", "bookings", "reservations", "facturen", "factuur",
        "betalingen", "herinnering", "automated", "system",
        // Not "hello@", "team@" or "support@": people answer from those.
    ]

    /// Addresses only marketing mail comes from.
    private static let marketingLocalParts = [
        "news", "newsletter", "newsletters", "nieuwsbrief", "marketing", "promo", "promos", "promotions",
        "offers", "deals", "mailing", "campaign", "campaigns",
    ]

    /// Headers that bulk-sending services add. Mail without list headers still carries these
    /// when it was sent in bulk (Gmail asks bulk senders for Feedback-ID).
    static let bulkHeaders = ["feedback-id", "x-csa-complaints", "x-mailgun-sid", "x-ses-outgoing", "x-sg-eid", "x-mc-user"]

    public static func classify(_ message: MailMessage) -> InboxSplit {
        let headers = message.listHeaders
        if headers["list-id"] != nil || headers["list-unsubscribe"] != nil {
            return .newsletters
        }
        if let precedence = headers["precedence"]?.lowercased(), ["bulk", "list"].contains(precedence) {
            return .newsletters
        }
        let local = senderLocalPart(message.from)
        if marketingLocalParts.contains(local) { return .newsletters }
        // A calendar's automatic answer ("Declined: …") isn't a person writing.
        if MeetingNotice.isNotice(subject: message.subject) { return .updates }
        // Nor is a reaction ("Jane reacted to your message"); it shows on the message it answers.
        if MailReaction.detect(message, text: message.snippet) != nil { return .updates }
        if let auto = headers["auto-submitted"]?.lowercased(), auto != "no" {
            return .updates
        }
        if automatedLocalParts.contains(local) || local.contains("noreply") || local.contains("no-reply") {
            return .updates
        }
        if bulkHeaders.contains(where: { headers[$0] != nil }) { return .updates }
        return .people
    }

    /// The sender's own local part, also behind Apple's Hide My Email, which rewrites
    /// `info@shop.example` as `info_at_shop_example_…@privaterelay.appleid.com`.
    static func senderLocalPart(_ address: EmailAddress) -> String {
        let local = address.localPart
        guard address.domain.lowercased() == "privaterelay.appleid.com", let range = local.range(of: "_at_") else { return local }
        return String(local[..<range.lowerBound])
    }
}
