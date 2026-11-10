import Foundation
import Testing
@testable import MailCore

@Suite struct CloudSyncTests {
    let then = Date(timeIntervalSince1970: 1_800_000_000)
    let now = Date(timeIntervalSince1970: 1_800_000_600)
    func data(_ text: String) -> Data { Data(text.utf8) }

    @Test func firstSyncSendsEverythingUp() {
        let result = CloudSync.merge(current: ["a": data("1")], lastSynced: [:], remote: .init(), now: now)
        #expect(result.items == ["a": data("1")])
        #expect(result.remote.items["a"]?.updatedAt == now)
    }

    @Test func aSecondDeviceGetsTheOthersItemsAndAddsItsOwn() {
        let remote = CloudSync.Set(items: ["a": .init(data: data("1"), updatedAt: then)])
        let result = CloudSync.merge(current: ["b": data("2")], lastSynced: [:], remote: remote, now: now)
        #expect(result.items == ["a": data("1"), "b": data("2")])
    }

    @Test func changesFromElsewhereComeDownWhenNothingChangedHere() {
        let remote = CloudSync.Set(items: ["a": .init(data: data("new"), updatedAt: now)])
        let result = CloudSync.merge(current: ["a": data("old")], lastSynced: ["a": data("old")], remote: remote, now: now)
        #expect(result.items == ["a": data("new")])
    }

    @Test func aChangeHereGoesUp() {
        let remote = CloudSync.Set(items: ["a": .init(data: data("old"), updatedAt: then)])
        let result = CloudSync.merge(current: ["a": data("mine")], lastSynced: ["a": data("old")], remote: remote, now: now)
        #expect(result.items == ["a": data("mine")])
        #expect(result.remote.items["a"] == .init(data: data("mine"), updatedAt: now))
    }

    @Test func deletingHereLeavesATombstone() {
        let remote = CloudSync.Set(items: ["a": .init(data: data("1"), updatedAt: then)])
        let result = CloudSync.merge(current: [:], lastSynced: ["a": data("1")], remote: remote, now: now)
        #expect(result.items.isEmpty)
        #expect(result.remote.deleted["a"] == now)
    }

    @Test func aDeletionElsewhereRemovesItHere() {
        let remote = CloudSync.Set(deleted: ["a": now])
        let result = CloudSync.merge(current: ["a": data("1")], lastSynced: ["a": data("1")], remote: remote, now: now)
        #expect(result.items.isEmpty)
    }

    @Test func anOfflineDeviceCantBringADeletedItemBack() {
        // The other device deleted "a" after this one last saw it; this device never changed it.
        let remote = CloudSync.Set(deleted: ["a": now])
        let result = CloudSync.merge(current: ["a": data("1"), "b": data("2")], lastSynced: ["a": data("1"), "b": data("2")],
                                     remote: remote, now: now.addingTimeInterval(60))
        #expect(result.items["a"] == nil)
    }

    @Test func oldTombstonesAreDropped() {
        let remote = CloudSync.Set(deleted: ["a": then])
        let later = then.addingTimeInterval(61 * 86_400)
        let result = CloudSync.merge(current: [:], lastSynced: [:], remote: remote, now: later)
        #expect(result.remote.deleted.isEmpty)
    }

    @Test func filesRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let set = CloudSync.Set(items: ["a": .init(data: data("1"), updatedAt: then)], deleted: ["b": now])
        CloudSync.write(set, name: "mailboxes", in: folder)
        #expect(CloudSync.read("mailboxes", in: folder) == set)
        #expect(CloudSync.read("missing", in: folder) == CloudSync.Set())
    }
}
