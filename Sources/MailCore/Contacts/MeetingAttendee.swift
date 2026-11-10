import Foundation

/// Someone (or a room) invited to a meeting, and how they answered.
public struct MeetingAttendee: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case required, optional, room
    }

    public var address: EmailAddress
    public var kind: Kind
    /// Nil until they answer.
    public var response: CalendarInvite.Response?

    public var id: String { address.address.lowercased() }

    public init(address: EmailAddress, kind: Kind = .required, response: CalendarInvite.Response? = nil) {
        self.address = address
        self.kind = kind
        self.response = response
    }
}

extension [MeetingAttendee] {
    /// How many said yes, maybe and no, and how many haven't answered; rooms aren't counted.
    public var tally: (yes: Int, maybe: Int, no: Int, waiting: Int) {
        let people = filter { $0.kind != .room }
        return (people.filter { $0.response == .accepted }.count, people.filter { $0.response == .tentative }.count,
                people.filter { $0.response == .declined }.count, people.filter { $0.response == nil }.count)
    }

    /// The list with newer answers laid over it, matched by address.
    public func updating(with answers: [MeetingAttendee]) -> [MeetingAttendee] {
        var list = self
        for answer in answers {
            if let index = list.firstIndex(where: { $0.id == answer.id }) {
                if let response = answer.response { list[index].response = response }
                if list[index].address.name == nil { list[index].address.name = answer.address.name }
            } else {
                list.append(answer)
            }
        }
        return list
    }
}
