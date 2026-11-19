import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct SavedSearchTests {
    func environment(defaults: UserDefaults) -> MailEnvironment {
        let folder = FileManager.default.temporaryDirectory.appending(path: "margin-saved-search-\(UUID().uuidString)", directoryHint: .isDirectory)
        return MailEnvironment(appName: "Margin", accounts: AccountStore(fileURL: folder.appending(path: "accounts.json")),
                               keychain: Keychain(service: "margin.saved-search-test"), oauth: OAuthClientRegistry(googleClientID: nil, microsoftClientID: nil),
                               labels: LabelStore(fileURL: folder.appending(path: "labels.json")),
                               defaults: defaults, folder: folder)
    }

    /// Saved, renamed and deleted, and still there for the next launch.
    @Test func keepsRenamesAndDeletes() throws {
        let defaults = try #require(UserDefaults(suiteName: "margin.saved-search.\(UUID().uuidString)"))
        let model = MailModel(environment: environment(defaults: defaults))
        let saved = try #require(model.saveSearch("  from:maya has:attachment "))
        #expect(saved.name == "from:maya has:attachment")
        #expect(saved.text == "from:maya has:attachment")
        // The same search isn't kept twice; an empty one not at all.
        #expect(model.saveSearch("from:maya has:attachment")?.id == saved.id)
        #expect(model.saveSearch("   ") == nil)
        model.saveSearch("is:unread older_than:7d")
        model.renameSavedSearch(saved.id, to: "Maya's files")
        model.renameSavedSearch(saved.id, to: "  ")

        let next = MailModel(environment: environment(defaults: defaults))
        #expect(next.savedSearches.map(\.name) == ["Maya's files", "is:unread older_than:7d"])
        #expect(next.savedSearch(for: "from:maya has:attachment")?.id == saved.id)

        next.deleteSavedSearch(saved.id)
        #expect(next.savedSearches.map(\.text) == ["is:unread older_than:7d"])
    }

    @Test func opensASavedSearch() throws {
        let defaults = try #require(UserDefaults(suiteName: "margin.saved-search.\(UUID().uuidString)"))
        let model = MailModel(environment: environment(defaults: defaults))
        let saved = try #require(model.saveSearch("from:maya"))
        model.openSavedSearch(saved)
        #expect(model.searchText == "from:maya")
        #expect(model.place == .search("from:maya"))
        #expect(model.currentSearchText == "from:maya")
    }
}
