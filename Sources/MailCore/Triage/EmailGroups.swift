import Foundation

/// A group the inbox is sorted into, like Bills to Pay or Travel. Sorting gives each
/// conversation its group as a label.
public struct EmailGroup: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    /// What belongs here, in plain words, for the assistant.
    public var detail: String

    public init(name: String, detail: String) {
        self.name = name
        self.detail = detail
    }

    public static var starters: [EmailGroup] {
        [
            EmailGroup(name: String(localized: "People"), detail: "Personal mail from friends, family and people the person knows."),
            EmailGroup(name: String(localized: "Team"), detail: "Colleagues and coworkers, internal work mail."),
            EmailGroup(name: String(localized: "Customers"), detail: "Customers and clients writing about the person's business."),
            EmailGroup(name: String(localized: "Bills to Pay"), detail: "Invoices, payment requests and bills still to pay."),
            EmailGroup(name: String(localized: "Receipts"), detail: "Receipts and payment confirmations for things already paid."),
            EmailGroup(name: String(localized: "Orders"), detail: "Order confirmations, shipping and delivery updates."),
            EmailGroup(name: String(localized: "Travel"), detail: "Flights, trains, hotels, bookings and itineraries."),
            EmailGroup(name: String(localized: "Meetings"), detail: "Invitations, scheduling and meeting notes."),
            EmailGroup(name: String(localized: "Documents"), detail: "Contracts, forms and documents to read or sign."),
            EmailGroup(name: String(localized: "Services"), detail: "Account notices from apps and services: security, settings, policy changes."),
            EmailGroup(name: String(localized: "Newsletters"), detail: "Newsletters and mailing lists the person subscribed to."),
            EmailGroup(name: String(localized: "Promotions"), detail: "Sales, offers and marketing."),
        ]
    }
}

/// Sorting without an assistant: only what standard headers say, so nothing lands in the
/// wrong group. Mailing lists go to Newsletters; everything else waits for an assistant.
public enum EmailSorter {
    public static func ruleGroup(for thread: MailThread, groups: [EmailGroup]) -> EmailGroup? {
        guard InboxSplit.classify(thread.latest) == .newsletters else { return nil }
        return groups.first { $0.name == EmailGroup.starters[10].name }
    }
}
