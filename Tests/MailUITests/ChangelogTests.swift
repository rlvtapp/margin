import Foundation
import Testing
@testable import MailUI

@MainActor @Suite struct ChangelogTests {
    private func model() -> MailModel {
        let model = MailModel(environment: .preview())
        model.hasOnboarded = true
        return model
    }

    /// Releases are newest first, each with something to say, and versions compare as numbers.
    @Test func releases() {
        let versions = Changelog.releases.map(\.version)
        #expect(!versions.isEmpty)
        #expect(Set(versions).count == versions.count)
        #expect(Changelog.releases.allSatisfy { !$0.changes.isEmpty })
        for (newer, older) in zip(versions, versions.dropFirst()) {
            #expect(Changelog.isNewer(newer, than: older))
        }
        #expect(Changelog.isNewer("0.10.0", than: "0.9.2"))
        #expect(!Changelog.isNewer("0.1.0", than: "0.1.0"))
    }

    /// After an update the notes open once; the same version again, a downgrade, or a fresh
    /// install (which gets the welcome) don't open them.
    @Test func opensOnceAfterAnUpdate() throws {
        let version = try #require(Changelog.releases.first?.version)
        let updated = model()
        updated.environment.defaults.set("0.0.1", forKey: MailModel.changelogSeenKey)
        updated.showChangelogIfUpdated(version: version)
        #expect(updated.isShowingWhatsNew)

        updated.isShowingWhatsNew = false
        updated.showChangelogIfUpdated(version: version)
        #expect(!updated.isShowingWhatsNew)

        let downgraded = model()
        downgraded.environment.defaults.set("9999.1.1", forKey: MailModel.changelogSeenKey)
        downgraded.showChangelogIfUpdated(version: version)
        #expect(!downgraded.isShowingWhatsNew)

        let fresh = MailModel(environment: .preview())
        fresh.hasOnboarded = false
        fresh.environment.defaults.removeObject(forKey: MailModel.changelogSeenKey)
        fresh.showChangelogIfUpdated(version: version)
        #expect(!fresh.isShowingWhatsNew)
        #expect(fresh.environment.defaults.string(forKey: MailModel.changelogSeenKey) == version)
    }

    /// A version without notes opens nothing.
    @Test func noNotesNoSheet() {
        let model = model()
        model.environment.defaults.set("0.0.1", forKey: MailModel.changelogSeenKey)
        model.showChangelogIfUpdated(version: "0.0.2")
        #expect(!model.isShowingWhatsNew)
    }

    /// Every build after the notes has them, but a build with no new notes since the one seen
    /// last opens nothing.
    @Test func laterBuildsWithoutNewNotesStayQuiet() throws {
        let notes = try #require(Changelog.releases.first)
        #expect(Changelog.release(notes.version + ".1")?.version == notes.version)
        let model = model()
        model.environment.defaults.set(notes.version, forKey: MailModel.changelogSeenKey)
        model.showChangelogIfUpdated(version: "9999.1.1")
        #expect(!model.isShowingWhatsNew)
    }

    /// A version is a day: it reads as a date, and later days count as newer.
    @Test func versionsAreDays() {
        #expect(Changelog.date(of: "2026.11.19")?.contains("2026") == true)
        #expect(Changelog.date(of: "0.1.0") == nil)
        #expect(Changelog.isNewer("2026.12.1", than: "2026.11.30"))
        #expect(Changelog.isNewer("2026.11.19.1", than: "2026.11.19"))
    }
}
