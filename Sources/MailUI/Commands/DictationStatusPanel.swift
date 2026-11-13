#if os(macOS)
import AppKit

/// A fixed-size HUD avoids SwiftUI hosting-view sizing feeding back into NSPanel layout.
@MainActor
final class DictationStatusPanel: NSPanel {
    private let titleLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")

    init() {
        let size = NSSize(width: 420, height: 84)
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        level = .floating
        ignoresMouseEvents = true
        let surface = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        surface.material = .hudWindow
        surface.blendingMode = .behindWindow
        surface.state = .active
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 18
        surface.layer?.masksToBounds = true
        let image = NSImageView(frame: NSRect(x: 20, y: 25, width: 26, height: 34))
        image.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
        image.contentTintColor = .systemRed
        surface.addSubview(image)
        titleLabel.frame = NSRect(x: 62, y: 43, width: 338, height: 22)
        titleLabel.font = .boldSystemFont(ofSize: 14)
        hintLabel.frame = NSRect(x: 62, y: 20, width: 338, height: 20)
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor
        for label in [titleLabel, hintLabel] {
            label.lineBreakMode = .byTruncatingTail
            surface.addSubview(label)
        }
        contentView = surface
    }

    func show(title: String, hint: String, on screen: NSScreen?) {
        titleLabel.stringValue = title
        hintLabel.stringValue = hint
        if let screen {
            setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - frame.width / 2,
                                   y: screen.visibleFrame.minY + 80))
        }
        orderFrontRegardless()
    }
}
#endif
