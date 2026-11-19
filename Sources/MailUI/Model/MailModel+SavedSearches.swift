import Foundation
import MailCore

/// A search kept in the sidebar, to run again with one click. The text is kept as typed, so
/// `older_than:7d` keeps meaning the last week.
public struct SavedSearch: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var text: String

    public init(id: UUID = UUID(), name: String, text: String) {
        self.id = id
        self.name = name
        self.text = text
    }
}

/// Saved searches, kept on this device across launches.
extension MailModel {
    static let savedSearchesKey = "savedSearches"

    public var savedSearches: [SavedSearch] {
        _ = savedSearchRevision
        guard let data = environment.defaults.data(forKey: Self.savedSearchesKey) else { return [] }
        return (try? JSONDecoder().decode([SavedSearch].self, from: data)) ?? []
    }

    private func setSavedSearches(_ searches: [SavedSearch]) {
        environment.defaults.set(try? JSONEncoder().encode(searches), forKey: Self.savedSearchesKey)
        savedSearchRevision += 1
    }

    /// The search on screen, when there is one.
    public var currentSearchText: String? {
        if case .search(let text) = place { return text }
        return nil
    }

    /// The saved search with this text, if it's kept.
    public func savedSearch(for text: String) -> SavedSearch? {
        savedSearches.first { $0.text == text }
    }

    /// Keeps a search in the sidebar, named after what was typed until it's renamed.
    @discardableResult
    public func saveSearch(_ text: String, name: String? = nil) -> SavedSearch? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let existing = savedSearch(for: trimmed) { return existing }
        let search = SavedSearch(name: name ?? trimmed, text: trimmed)
        setSavedSearches(savedSearches + [search])
        notice = Notice(text: String(localized: "Search saved"))
        return search
    }

    public func renameSavedSearch(_ id: SavedSearch.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        setSavedSearches(savedSearches.map { $0.id == id ? SavedSearch(id: $0.id, name: trimmed, text: $0.text) : $0 })
    }

    public func deleteSavedSearch(_ id: SavedSearch.ID) {
        setSavedSearches(savedSearches.filter { $0.id != id })
    }

    /// Runs a saved search, with its text in the search field.
    public func openSavedSearch(_ search: SavedSearch) {
        searchText = search.text
        runSearch(search.text)
    }
}
