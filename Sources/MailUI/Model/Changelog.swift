import Foundation

/// What changed in each version of Margin, newest first, shown in Settings → What's New and once
/// after Margin updates (docs/changelog.md). A version is its release date, `2026.11.19`
/// (`CFBundleShortVersionString`); the build number behind it is only for the updater. Every line is in the string catalog, so the
/// notes read in the person's language. A release gets a few entries for what people will notice,
/// not every fix.
public struct ChangelogRelease: Identifiable, Sendable {
    public struct Change: Identifiable, Sendable {
        public var id: String { symbol + title }
        /// An SF Symbol for the change.
        public let symbol: String
        /// Which of the account colours its tile uses.
        public let hue: Int
        public let title: String
        public let detail: String
    }

    public var id: String { version }
    /// The version it shipped in, as `year.month.day` (`2026.11.19`); later versions have it too.
    public let version: String
    public let changes: [Change]
}

public enum Changelog {
    /// Newest first. Add a release at the top when tagging a new version.
    public static var releases: [ChangelogRelease] {
        [
            ChangelogRelease(version: "2026.11.19", changes: [
                .init(symbol: "calendar", hue: 0,
                      title: String(localized: "A full calendar"),
                      detail: String(localized: "Day, Week and Month next to your invitations, with your Mac's calendars and reminders. Make, move and delete events right there.")),
                .init(symbol: "person.2", hue: 1,
                      title: String(localized: "Compare calendars"),
                      detail: String(localized: "See when colleagues are busy or out of office, and when you're all free together.")),
                .init(symbol: "video", hue: 2,
                      title: String(localized: "Video calls and suggested times"),
                      detail: String(localized: "New meetings get a call link, and Margin suggests times that work for everyone.")),
                .init(symbol: "magnifyingglass", hue: 3,
                      title: String(localized: "Better search"),
                      detail: String(localized: "Search by sender, date or attachment, on the server too, and save searches you use often.")),
                .init(symbol: "tag", hue: 4,
                      title: String(localized: "Labels and rules"),
                      detail: String(localized: "Real labels for Gmail, and rules that keep running on your mail server when your Mac is off.")),
                .init(symbol: "paperclip", hue: 5,
                      title: String(localized: "Attachments"),
                      detail: String(localized: "Quick Look and Save All, and a clear note when a file is too big to send.")),
            ]),
        ]
    }

    /// The version running now.
    public static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// The build number: when it was built, `yyyyMMdd.HHmm`, which the updater compares.
    public static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    /// The newest notes a version has: the latest release at or before it.
    public static func release(_ version: String) -> ChangelogRelease? {
        releases.first { !isNewer($0.version, than: version) }
    }

    /// The day a version came out, written out ("19 November 2026"); nil for one that isn't a date.
    public static func date(of version: String) -> String? {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 3, parts[0] > 2000,
              let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        return date.formatted(date: .long, time: .omitted)
    }

    /// Whether `version` is later than `other`, comparing numbers part by part (0.10.0 > 0.9.2).
    public static func isNewer(_ version: String, than other: String) -> Bool {
        version.compare(other, options: .numeric) == .orderedDescending
    }
}

extension MailModel {
    static let changelogSeenKey = "changelog.seen"

    /// After an update that brings new notes, they open once. A fresh install gets the welcome
    /// instead, and either way the version is noted as seen.
    func showChangelogIfUpdated(version: String = Changelog.currentVersion) {
        guard !version.isEmpty else { return }
        let seen = environment.defaults.string(forKey: Self.changelogSeenKey)
        environment.defaults.set(version, forKey: Self.changelogSeenKey)
        guard hasOnboarded, let notes = Changelog.release(version) else { return }
        // Notes already there at the version seen last were shown then (or weren't news).
        if let seen, !Changelog.isNewer(notes.version, than: seen) { return }
        isShowingWhatsNew = true
    }
}
