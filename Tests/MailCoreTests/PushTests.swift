import Foundation
import Testing
@testable import MailCore

@Suite struct PushTests {
    @Test func registersTheDeviceWithItsTokenInHex() async throws {
        let api = GraphFakeAPI()
        api.on("v1/devices", status: 201, #"{"device": "d1", "secret": "s1"}"#)
        let device = try await PushRelay(base: URL(string: "https://relay.example")!, send: api.send)
            .register(token: Data([0xAB, 0x01]), sandbox: true, topic: "dev.margin.Margin")
        #expect(device == .init(device: "d1", secret: "s1"))
        let body = try #require(api.json(of: "v1/devices"))
        #expect(body["token"] as? String == "ab01")
        #expect(body["environment"] as? String == "sandbox")
    }

    @Test func gmailSubscriptionsSendOnlyTheAddressHash() async throws {
        let api = GraphFakeAPI()
        api.on("v1/subscriptions", status: 201, #"{"id": "s1", "url": "https://relay.example/v1/hooks/gmail"}"#)
        let relay = PushRelay(base: URL(string: "https://relay.example")!, secret: "secret", send: api.send)
        let made = try await relay.subscribe(.gmail, account: "a1", address: "Maya@Example.com")
        #expect(made.id == "s1")
        let body = try #require(api.json(of: "v1/subscriptions"))
        #expect(body["address_hash"] as? String == PushRelay.hash("maya@example.com"))
        #expect(!String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self).contains("maya"))
        #expect(api.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    @Test func graphSubscriptionPointsAtTheRelayWithItsClientState() async throws {
        let api = GraphFakeAPI()
        api.on("/subscriptions", status: 201, #"{"id": "g1"}"#)
        let id = try await ProviderPush.subscribeGraph(token: "t", hook: URL(string: "https://relay.example/v1/hooks/graph/s1")!,
                                                       clientState: "cs", until: Date(timeIntervalSince1970: 1_800_000_000), send: api.send)
        #expect(id == "g1")
        let body = try #require(api.json(of: "/subscriptions"))
        #expect(body["notificationUrl"] as? String == "https://relay.example/v1/hooks/graph/s1")
        #expect(body["clientState"] as? String == "cs")
        #expect(body["changeType"] as? String == "created")
    }

    @Test func gmailWatchReturnsWhenItLapses() async throws {
        let api = GraphFakeAPI()
        api.on("users/me/watch", #"{"historyId": "1", "expiration": "1800000000000"}"#)
        let until = try await ProviderPush.watchGmail(token: "t", topic: "projects/p/topics/margin", send: api.send)
        #expect(until == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(api.json(of: "users/me/watch")?["topicName"] as? String == "projects/p/topics/margin")
    }
}

@Suite struct PushRelayForgetTests {
    @Test func forgettingTheDeviceDeletesIt() async throws {
        let api = GraphFakeAPI()
        api.on("v1/devices/d1", status: 204, "")
        try await PushRelay(base: URL(string: "https://relay.example")!, secret: "s1", send: api.send).forget(device: "d1")
        let request = try #require(api.requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/v1/devices/d1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer s1")
    }
}
