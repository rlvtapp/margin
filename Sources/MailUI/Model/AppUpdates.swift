import Foundation

/// The Mac app's updater, as Settings sees it. Sparkle lives in the Mac app target only (the
/// packages build for iPhone and iPad too, which update through the App Store), so the app hands
/// one of these to `MailModel.updates`. It stays nil in builds without a feed (built from source,
/// forks, previews), and Settings then shows nothing about updates.
@MainActor
public protocol AppUpdates: AnyObject {
    /// Looks for a new version now and shows what it finds, including "you're up to date".
    func checkForUpdates()
    /// False while a check or an update is already under way.
    var canCheckForUpdates: Bool { get }
    /// Looks for new versions about once a day.
    var checksAutomatically: Bool { get set }
    /// Downloads new versions in the background and installs them when Margin quits.
    var installsAutomatically: Bool { get set }
}
