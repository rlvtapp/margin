import Foundation

/// Someone from an address book: the Contacts app, a Microsoft or Google account, or a CardDAV
/// server. Kept on the device for address completion and names.
public struct Contact: Codable, Hashable, Sendable, Identifiable {
    /// Unique within its source, prefixed with the source ("carddav:<href>", "microsoft:<id>").
    public var id: String
    public var name: String?
    public var emails: [String]
    public var organization: String?
    public var source: ContactSource
    /// Where the person's picture is, when their address book has one.
    public var picture: ContactPicture?
    /// The picture itself, when the address book hands it over with the contact (the Contacts
    /// app, a vCard). It's put in the picture store when contacts are refreshed and isn't kept
    /// with the contact.
    public var pictureData: Data?

    // `pictureData` is left out: pictures live in their own files, not in the contacts list.
    enum CodingKeys: String, CodingKey { case id, name, emails, organization, source, picture }

    public init(id: String, name: String?, emails: [String], organization: String? = nil, source: ContactSource,
                picture: ContactPicture? = nil, pictureData: Data? = nil) {
        self.id = id
        self.name = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.emails = emails.map { $0.trimmingCharacters(in: .whitespaces) }.filter(EmailAddress.isValid)
        self.organization = organization?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.source = source
        self.picture = picture
        self.pictureData = pictureData
    }

    /// One address per email, with the contact's name.
    public var addresses: [EmailAddress] { emails.map { EmailAddress(name: name, address: $0) } }
}

/// Where a contact's picture comes from. Always the person's own address book: the provider the
/// contact was read from, or the device. Nothing is looked up anywhere else.
public enum ContactPicture: Codable, Hashable, Sendable {
    /// Already in the picture store on this device.
    case saved
    /// A picture address the address book gave (Google's contact photos).
    case url(String)
    /// A saved Microsoft contact, by its id: read through Microsoft Graph.
    case microsoftContact(String)
    /// Someone in the Microsoft account's organization, by address: read through Microsoft Graph.
    case microsoftUser(String)
}

public enum ContactSource: String, Codable, Sendable, CaseIterable {
    /// The Contacts app on this Mac, iPhone or iPad.
    case system
    /// A Microsoft account's contacts and the people it works with (Microsoft Graph).
    case microsoft
    /// A Google account's contacts and other contacts (People API).
    case google
    /// A CardDAV address book (Fastmail, iCloud, Nextcloud, …).
    case carddav
}

/// A meeting room an organization can book, from Microsoft 365.
public struct MeetingRoom: Codable, Hashable, Sendable, Identifiable {
    public var email: String
    public var name: String
    public var capacity: Int?
    public var building: String?
    public var floor: String?

    public var id: String { email.lowercased() }

    public init(email: String, name: String, capacity: Int? = nil, building: String? = nil, floor: String? = nil) {
        self.email = email
        self.name = name
        self.capacity = capacity
        self.building = building
        self.floor = floor
    }
}

/// A stretch of time someone (or a room) is taken.
public struct BusyTime: Codable, Hashable, Sendable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public func overlaps(_ start: Date, _ end: Date) -> Bool { self.start < end && start < self.end }
}

/// A meeting to send: who, when, where, and the rooms booked for it.
public struct MeetingRequest: Hashable, Sendable {
    public var uid: String
    public var title: String
    public var start: Date
    public var end: Date
    public var location: String?
    public var notes: String
    public var organizer: EmailAddress
    public var attendees: [EmailAddress]
    public var rooms: [MeetingRoom]

    public init(uid: String = UUID().uuidString, title: String, start: Date, end: Date, location: String? = nil,
                notes: String = "", organizer: EmailAddress, attendees: [EmailAddress], rooms: [MeetingRoom] = []) {
        self.uid = uid
        self.title = title
        self.start = start
        self.end = end
        self.location = location
        self.notes = notes
        self.organizer = organizer
        self.attendees = attendees
        self.rooms = rooms
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
