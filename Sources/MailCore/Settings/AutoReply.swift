import Foundation

/// An out-of-office reply, kept by the mail provider so it answers even when no device is on.
public struct AutoReply: Equatable, Sendable {
    public var isOn: Bool
    /// Only between these dates, when set.
    public var start: Date?
    public var end: Date?
    public var subject: String
    public var message: String
    /// Microsoft only: also answer people outside the organization.
    public var answersOutside: Bool

    public init(isOn: Bool = false, start: Date? = nil, end: Date? = nil, subject: String = "", message: String = "",
                answersOutside: Bool = true) {
        self.isOn = isOn
        self.start = start
        self.end = end
        self.subject = subject
        self.message = message
        self.answersOutside = answersOutside
    }
}

/// Reading and changing a provider's out-of-office reply.
public protocol AutoReplyAdapter: Sendable {
    func autoReply() async throws -> AutoReply
    func setAutoReply(_ reply: AutoReply) async throws
}

// MARK: Microsoft 365 and Outlook.com

/// Graph's `mailboxSettings.automaticRepliesSetting`.
public struct MicrosoftAutoReply: AutoReplyAdapter {
    let http: BearerHTTP
    static let url = URL(string: "https://graph.microsoft.com/v1.0/me/mailboxSettings")!

    public init(accessToken: String, send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = BearerHTTP.urlSession) {
        http = BearerHTTP(token: accessToken, send: send)
    }

    public func autoReply() async throws -> AutoReply {
        var components = URLComponents(url: Self.url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "$select", value: "automaticRepliesSetting")]
        let data = try await http.data(for: try http.request(components.url!))
        struct Settings: Decodable { var automaticRepliesSetting: Replies }
        struct Replies: Decodable {
            var status: String?
            var externalAudience: String?
            var internalReplyMessage: String?
            var scheduledStartDateTime: GraphDateTime?
            var scheduledEndDateTime: GraphDateTime?
        }
        let replies = try BearerHTTP.decode(Settings.self, from: data).automaticRepliesSetting
        let scheduled = replies.status == "scheduled"
        return AutoReply(isOn: replies.status == "alwaysEnabled" || scheduled,
                         start: scheduled ? MicrosoftGraphClient.parseGraphDate(replies.scheduledStartDateTime) : nil,
                         end: scheduled ? MicrosoftGraphClient.parseGraphDate(replies.scheduledEndDateTime) : nil,
                         message: HTMLText.plain(replies.internalReplyMessage ?? ""),
                         answersOutside: replies.externalAudience != "none")
    }

    public func setAutoReply(_ reply: AutoReply) async throws {
        let html = AutoReplyText.html(reply.message)
        var setting: [String: Any] = [
            "status": !reply.isOn ? "disabled" : (reply.start != nil && reply.end != nil ? "scheduled" : "alwaysEnabled"),
            "externalAudience": reply.answersOutside ? "all" : "none",
            "internalReplyMessage": html,
            "externalReplyMessage": html,
        ]
        if let start = reply.start, let end = reply.end, reply.isOn {
            setting["scheduledStartDateTime"] = ["dateTime": MicrosoftGraphClient.graphDate(start), "timeZone": "UTC"]
            setting["scheduledEndDateTime"] = ["dateTime": MicrosoftGraphClient.graphDate(end), "timeZone": "UTC"]
        }
        _ = try await http.data(for: try http.request(Self.url, method: "PATCH", json: ["automaticRepliesSetting": setting]))
    }
}

// MARK: Gmail

/// The Gmail API's vacation responder.
public struct GmailAutoReply: AutoReplyAdapter {
    let http: BearerHTTP
    static let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/settings/vacation")!

    public init(accessToken: String, send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = BearerHTTP.urlSession) {
        http = BearerHTTP(token: accessToken, send: send)
    }

    public func autoReply() async throws -> AutoReply {
        let data = try await http.data(for: try http.request(Self.url))
        struct Vacation: Decodable {
            var enableAutoReply: Bool?
            var responseSubject: String?
            var responseBodyPlainText: String?
            var responseBodyHtml: String?
            var startTime: String?
            var endTime: String?
            var restrictToContacts: Bool?
        }
        let vacation = try BearerHTTP.decode(Vacation.self, from: data)
        func date(_ millis: String?) -> Date? { millis.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) } }
        return AutoReply(isOn: vacation.enableAutoReply ?? false, start: date(vacation.startTime), end: date(vacation.endTime),
                         subject: vacation.responseSubject ?? "",
                         message: vacation.responseBodyPlainText ?? HTMLText.plain(vacation.responseBodyHtml ?? ""),
                         answersOutside: !(vacation.restrictToContacts ?? false))
    }

    public func setAutoReply(_ reply: AutoReply) async throws {
        var body: [String: Any] = [
            "enableAutoReply": reply.isOn,
            "responseSubject": reply.subject,
            "responseBodyPlainText": reply.message,
            "responseBodyHtml": AutoReplyText.html(reply.message),
            "restrictToContacts": !reply.answersOutside,
        ]
        if let start = reply.start { body["startTime"] = String(Int64(start.timeIntervalSince1970 * 1000)) }
        if let end = reply.end { body["endTime"] = String(Int64(end.timeIntervalSince1970 * 1000)) }
        _ = try await http.data(for: try http.request(Self.url, method: "PUT", json: body))
    }
}

// MARK: JMAP

extension JMAPProvider: AutoReplyAdapter {
    static let vacationCapability = "urn:ietf:params:jmap:vacationresponse"

    /// JMAP's VacationResponse (RFC 8621 §8), a single object with the id "singleton".
    public func autoReply() async throws -> AutoReply {
        let session = try await connected()
        let responses = try await call([["VacationResponse/get", ["accountId": session.accountID, "ids": ["singleton"]], "v"]],
                                       using: [Self.vacationCapability])
        guard let object = (responses.first?.arguments["list"] as? [[String: Any]])?.first else {
            throw MailError.notSupported(String(localized: "This server doesn't offer automatic replies."))
        }
        let format = ISO8601DateFormatter()
        return AutoReply(isOn: object["isEnabled"] as? Bool ?? false,
                         start: (object["fromDate"] as? String).flatMap(format.date(from:)),
                         end: (object["toDate"] as? String).flatMap(format.date(from:)),
                         subject: object["subject"] as? String ?? "",
                         message: object["textBody"] as? String ?? HTMLText.plain(object["htmlBody"] as? String ?? ""))
    }

    public func setAutoReply(_ reply: AutoReply) async throws {
        let session = try await connected()
        let format = ISO8601DateFormatter()
        let update: [String: Any] = [
            "isEnabled": reply.isOn,
            "fromDate": reply.start.map(format.string(from:)) ?? NSNull(),
            "toDate": reply.end.map(format.string(from:)) ?? NSNull(),
            "subject": reply.subject.isEmpty ? NSNull() : reply.subject,
            "textBody": reply.message,
            "htmlBody": AutoReplyText.html(reply.message),
        ]
        let responses = try await call([["VacationResponse/set", ["accountId": session.accountID, "update": ["singleton": update]], "v"]],
                                       using: [Self.vacationCapability])
        if let failed = responses.first?.arguments["notUpdated"] as? [String: Any], !failed.isEmpty {
            throw MailError.serverRejected(String(localized: "The server didn't accept the automatic reply."))
        }
    }
}

enum AutoReplyText {
    /// The message as simple HTML, line breaks kept.
    static func html(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br>")
        return "<div>\(escaped)</div>"
    }
}
