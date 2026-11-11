import Foundation
import MailCore

/// What Margin knows about one person, for the card that opens from their name: their names and
/// addresses in your contacts, and your mail with them, all from this device.
public struct PersonSummary: Sendable {
    public var address: EmailAddress
    /// Other addresses for the same person in your contacts.
    public var otherAddresses: [String]
    public var inContacts: Bool
    /// Conversations on this device with them on it, and when the first and latest were.
    public var messageCount: Int
    public var first: Date?
    public var latest: Date?
    /// Who usually writes first: how many of those messages they sent, and how many you did.
    public var fromThem: Int
    public var fromYou: Int
    /// Their newest messages, for the card's list.
    public var recent: [MailMessage]
}

extension MailModel {
    public func personSummary(_ person: EmailAddress) async -> PersonSummary {
        let address = person.address.lowercased()
        let contact = contacts.first { $0.addresses.contains { $0.address.lowercased() == address } }
        let others = contact?.addresses.map(\.address).filter { $0.lowercased() != address } ?? []
        let history = environment.isPreview
            ? allInboxesThreads(nil).flatMap(\.messages).filter { ([$0.from] + $0.to + $0.cc).contains { $0.address.lowercased() == address } }
            : await environment.cache.history(with: address)
        let fromThem = history.filter { $0.from.address.lowercased() == address }.count
        let named = contact.flatMap { contact in contact.addresses.first { $0.address.lowercased() == address } }
        var shown = person
        if shown.name?.isEmpty != false, let name = named?.name ?? history.first(where: { $0.from.address.lowercased() == address })?.from.name {
            shown.name = name
        }
        return PersonSummary(address: shown, otherAddresses: others, inContacts: contact != nil,
                             messageCount: history.count, first: history.map(\.date).min(), latest: history.map(\.date).max(),
                             fromThem: fromThem, fromYou: history.filter { isMine($0) }.count,
                             recent: Array(history.sorted { $0.date > $1.date }.prefix(5)))
    }

    /// A new message to this person, from the mailbox you're looking at.
    public func startCompose(to person: EmailAddress) {
        var state = ComposeState(account: account(selectedThread?.accountID) ?? currentAccount)
        state.to = person.headerValue
        compose = state
    }

    /// Everything with this person, as a search.
    public func showMail(with person: EmailAddress) {
        searchText = "from:\(person.address)"
        runSearch(searchText)
    }

    public func setTrustsPictures(_ person: EmailAddress, _ trusted: Bool) {
        if trusted { trustPictures(from: person) } else {
            trustedPictureSenders.remove(person.address.lowercased())
            UserDefaults.standard.set(Array(trustedPictureSenders).sorted(), forKey: "trustedPictureSenders")
        }
    }

    // MARK: Source

    /// One message as the server keeps it, for debugging: its headers and full MIME source.
    public func rawSource(of message: MailMessage, in thread: MailThread) async throws -> String {
        guard let account = account(thread.accountID) else { throw MailError.missingCredentials }
        let data = try await provider(for: account).rawSource(of: message)
        return String(decoding: data, as: UTF8.self)
    }
}
