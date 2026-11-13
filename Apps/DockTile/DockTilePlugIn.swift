import AppKit

/// Keeps the chosen icon colour on Margin's Dock tile while Margin isn't running.
///
/// The Dock loads this bundle from Margin.app/Contents/PlugIns into a helper process of its own,
/// when Margin's tile appears in the Dock and at login for a tile that's kept there. Margin is
/// sandboxed and that helper isn't, so the two share no files or settings. Margin says which icon
/// is chosen with a notification (`MailModel.applyAppIcon()`); the choice is remembered here, in
/// the helper's own settings, for the times Margin is closed. See docs/app-icon.md.
@MainActor
@objc(MarginDockTilePlugIn)
final class DockTilePlugIn: NSObject, @preconcurrency NSDockTilePlugIn {
    /// Margin.app: this bundle sits in its Contents/PlugIns.
    private let app = Bundle(url: Bundle(for: DockTilePlugIn.self).bundleURL
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
    private var tile: NSDockTile?
    private var observer: NSObjectProtocol?

    private var appID: String { app?.bundleIdentifier ?? "app.relevate.margin" }
    /// Where the choice is kept between logins. Not Margin's own settings: those live in its sandbox.
    private var store: UserDefaults? { UserDefaults(suiteName: appID + ".docktile") }

    func setDockTile(_ dockTile: NSDockTile?) {
        let center = DistributedNotificationCenter.default()
        if let observer { center.removeObserver(observer) }
        observer = nil
        tile = dockTile
        guard dockTile != nil else { return }

        // Margin posts the icon's name ("" for the main icon) at launch and whenever it changes.
        observer = center.addObserver(forName: Notification.Name(appID + ".dock-icon"), object: nil, queue: .main) { [weak self] note in
            let name = note.object as? String ?? ""
            MainActor.assumeIsolated { self?.choose(name) }
        }
        show(store?.string(forKey: "icon") ?? "")
        // Margin may already be open with a choice this plug-in hasn't heard about.
        center.postNotificationName(Notification.Name(appID + ".dock-icon.ask"), object: nil, userInfo: nil, deliverImmediately: true)
    }

    private func choose(_ name: String) {
        if image(named: name) == nil {
            store?.removeObject(forKey: "icon")
        } else {
            store?.set(name, forKey: "icon")
        }
        show(name)
    }

    /// Draws the named icon on the tile, or hands the tile back to the Dock, which then draws
    /// Margin's main icon in the system's current icon style.
    private func show(_ name: String) {
        guard let tile else { return }
        if let image = image(named: name) {
            let view = NSImageView(frame: NSRect(origin: .zero, size: tile.size))
            view.image = image
            view.imageScaling = .scaleProportionallyUpOrDown
            view.autoresizingMask = [.width, .height]
            tile.contentView = view
        } else if tile.contentView != nil {
            tile.contentView = nil
        } else {
            return
        }
        tile.display()
    }

    /// One of Margin's alternate icons, from the app's own asset catalogue. Any process can post
    /// the notification, so only an icon name is accepted, never a path.
    private func image(named name: String) -> NSImage? {
        guard name.hasPrefix("AppIcon-"), name.count <= 40,
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "-") }) else { return nil }
        return app?.image(forResource: name)
    }
}
