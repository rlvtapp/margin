import Foundation

/// Microsoft 365 suggests meeting times itself: `POST /me/findMeetingTimes`, which weighs
/// everyone's calendar and the organizer's working hours. Work and school accounts only, with
/// Calendars.Read.Shared; anything else fails, and Margin works the times out itself.
extension MicrosoftGraphClient: MeetingTimeFinding {
    public func meetingTimes(with attendees: [EmailAddress], length: TimeInterval, from: Date, to: Date,
                             limit: Int = 5) async throws -> [SuggestedTime] {
        guard !attendees.isEmpty, length > 0, to > from else { return [] }
        let body: [String: Any] = [
            "attendees": attendees.map { ["type": "required", "emailAddress": Self.address($0.address, name: $0.name)] },
            "timeConstraint": [
                "activityDomain": "work",
                "timeSlots": [["start": ["dateTime": Self.graphDate(from), "timeZone": "UTC"],
                               "end": ["dateTime": Self.graphDate(to), "timeZone": "UTC"]]],
            ],
            "meetingDuration": "PT\(max(Int((length / 60).rounded()), 1))M",
            "isOrganizerOptional": false,
            // Everyone free: someone who can't be seen counts as half, so such times are left
            // to the suggestions worked out here, which say who couldn't be seen.
            "minimumAttendeePercentage": 100,
            "maxCandidates": max(limit, 1) * 4,
        ]
        var request = try http.request(URL(string: "\(Self.base)/me/findMeetingTimes")!, method: "POST", json: body)
        request.setValue("outlook.timezone=\"UTC\"", forHTTPHeaderField: "Prefer")
        let result = try BearerHTTP.decode(GraphMeetingTimes.self, from: try await http.data(for: request))
        return Self.suggestions(result, attendees: attendees)
    }

    /// Each suggestion with who's free, busy or unknown then, soonest first.
    static func suggestions(_ result: GraphMeetingTimes, attendees: [EmailAddress]) -> [SuggestedTime] {
        let named = Dictionary(attendees.map { ($0.address.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        return (result.meetingTimeSuggestions ?? []).compactMap { suggestion -> SuggestedTime? in
            guard let start = parseGraphDate(suggestion.meetingTimeSlot?.start),
                  let end = parseGraphDate(suggestion.meetingTimeSlot?.end), start < end else { return nil }
            var time = SuggestedTime(start: start, end: end, fromCalendar: true)
            for item in suggestion.attendeeAvailability ?? [] {
                guard let address = item.attendee?.emailAddress?.address else { continue }
                let person = named[address.lowercased()] ?? EmailAddress(address: address)
                switch item.availability?.lowercased() {
                case "free", "workingelsewhere": time.free.append(person)
                case "unknown", nil: time.unknown.append(person)
                default: time.busy.append(person)
                }
            }
            return time
        }
        .sorted { $0.start < $1.start }
    }
}

struct GraphMeetingTimes: Decodable {
    var emptySuggestionsReason: String?
    var meetingTimeSuggestions: [Suggestion]?

    struct Suggestion: Decodable {
        var confidence: Double?
        var organizerAvailability: String?
        var attendeeAvailability: [Availability]?
        var meetingTimeSlot: Slot?
    }

    struct Availability: Decodable {
        var availability: String?
        var attendee: Attendee?
    }

    struct Attendee: Decodable { var emailAddress: GraphAddress? }

    struct Slot: Decodable {
        var start: GraphDateTime?
        var end: GraphDateTime?
    }
}
