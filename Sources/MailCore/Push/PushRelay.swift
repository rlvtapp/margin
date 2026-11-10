import CryptoKit
import Foundation

/// Margin's push relay (docs/push.md): it learns which phone a provider's "new mail" ping is
/// for and asks Apple to push it there. It never sees mail or credentials.
public struct PushRelay: Sendable {
    public let base: URL
    let http: BearerHTTP

    /// A device secret, or "" before the phone has registered.
    public init(base: URL, secret: String = "",
                send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = BearerHTTP.urlSession) {
        self.base = base
        http = BearerHTTP(token: secret, send: send)
    }

    public struct Device: Codable, Sendable, Equatable {
        public var device: String
        public var secret: String
    }

    public struct Subscription: Codable, Sendable, Equatable {
        public var id: String
        public var url: URL
        public var clientState: String?

        enum CodingKeys: String, CodingKey { case id, url, clientState = "client_state" }
    }

    public enum Kind: String, Codable, Sendable { case graph, gmail, jmap }

    public func register(token: Data, sandbox: Bool, topic: String) async throws -> Device {
        let body: [String: Any] = ["token": token.map { String(format: "%02x", $0) }.joined(),
                                   "environment": sandbox ? "sandbox" : "production", "topic": topic]
        let data = try await http.data(for: try http.request(base.appending(path: "v1/devices"), method: "POST", json: body))
        return try BearerHTTP.decode(Device.self, from: data)
    }

    /// `address` is only for Gmail, whose pings name the address; the relay keeps only its hash.
    public func subscribe(_ kind: Kind, account: String, address: String? = nil) async throws -> Subscription {
        var body: [String: Any] = ["kind": kind.rawValue, "account": account]
        if let address { body["address_hash"] = Self.hash(address) }
        let data = try await http.data(for: try http.request(base.appending(path: "v1/subscriptions"), method: "POST", json: body))
        return try BearerHTTP.decode(Subscription.self, from: data)
    }

    public func unsubscribe(_ id: String) async throws {
        _ = try await http.data(for: try http.request(base.appending(path: "v1/subscriptions/\(id)"), method: "DELETE"))
    }

    /// Deletes this phone from the relay, and with it every subscription it had.
    public func forget(device id: String) async throws {
        _ = try await http.data(for: try http.request(base.appending(path: "v1/devices/\(id)"), method: "DELETE"))
    }

    /// SHA-256 of the lowercased address, in hex.
    public static func hash(_ address: String) -> String {
        SHA256.hash(data: Data(address.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Asking the providers to report new mail: a Gmail watch and a Microsoft Graph subscription.
/// (JMAP's push subscription lives on `JMAPProvider`.)
public enum ProviderPush {
    /// Gmail posts to Margin's Pub/Sub topic until the returned date (about a week).
    public static func watchGmail(token: String, topic: String,
                                  send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = BearerHTTP.urlSession) async throws -> Date {
        let http = BearerHTTP(token: token, send: send)
        let body: [String: Any] = ["topicName": topic, "labelIds": ["INBOX"], "labelFilterBehavior": "include"]
        let data = try await http.data(for: try http.request(URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/watch")!,
                                                            method: "POST", json: body))
        struct Answer: Decodable { var expiration: String? }
        let millis = Double(try BearerHTTP.decode(Answer.self, from: data).expiration ?? "") ?? 0
        return millis > 0 ? Date(timeIntervalSince1970: millis / 1000) : Date().addingTimeInterval(6 * 86_400)
    }

    /// A Graph subscription to new messages in the inbox, posting to the relay's hook.
    public static func subscribeGraph(token: String, hook: URL, clientState: String, until: Date,
                                      send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = BearerHTTP.urlSession) async throws -> String {
        let http = BearerHTTP(token: token, send: send)
        let body: [String: Any] = [
            "changeType": "created", "notificationUrl": hook.absoluteString,
            "resource": "me/mailFolders('Inbox')/messages", "clientState": clientState,
            "expirationDateTime": ISO8601DateFormatter().string(from: until),
        ]
        let data = try await http.data(for: try http.request(URL(string: "\(MicrosoftGraphClient.base)/subscriptions")!, method: "POST", json: body))
        struct Answer: Decodable { var id: String }
        return try BearerHTTP.decode(Answer.self, from: data).id
    }

    public static func renewGraph(token: String, id: String, until: Date,
                                  send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = BearerHTTP.urlSession) async throws {
        let http = BearerHTTP(token: token, send: send)
        _ = try await http.data(for: try http.request(URL(string: "\(MicrosoftGraphClient.base)/subscriptions/\(id)")!, method: "PATCH",
                                                      json: ["expirationDateTime": ISO8601DateFormatter().string(from: until)]))
    }

    /// Ends a Graph subscription, so Microsoft stops reporting to the relay.
    public static func deleteGraph(token: String, id: String,
                                   send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = BearerHTTP.urlSession) async throws {
        let http = BearerHTTP(token: token, send: send)
        _ = try await http.data(for: try http.request(URL(string: "\(MicrosoftGraphClient.base)/subscriptions/\(id)")!, method: "DELETE"))
    }

    /// Stops Gmail's reports for the account.
    public static func stopGmail(token: String,
                                 send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = BearerHTTP.urlSession) async throws {
        let http = BearerHTTP(token: token, send: send)
        _ = try await http.data(for: try http.request(URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/stop")!, method: "POST"))
    }
}
