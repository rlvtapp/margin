import MailCore
import SwiftUI
import WebKit

/// An HTML mail, shown in a locked-down WebKit view sized to its content:
/// - page scripts never run,
/// - nothing is fetched from the internet until `allowsRemote` (a content rule blocks
///   every load but `data:` and `about:`), so opening mail tells no one you read it,
/// - no cookies or storage survive (a non-persistent data store),
/// - links open in the browser instead of inside the reader.
/// In dark mode, mail that wasn't designed for dark backgrounds sits on a white sheet.
struct HTMLMessageView: View {
    let html: SafeHTML
    let allowsRemote: Bool
    var zoom: Double = 1
    /// On iPhone and iPad: the mail fills its message card, with its own side margins and a
    /// larger base size, instead of sitting on a framed sheet.
    var fillsCard = false
    var onMailto: (URL) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme
    @State private var height: CGFloat = 120

    init(html: SafeHTML, allowsRemote: Bool, zoom: Double = 1, fillsCard: Bool = false, onMailto: @escaping (URL) -> Void = { _ in }) {
        self.html = html
        self.allowsRemote = allowsRemote
        self.zoom = zoom
        self.fillsCard = fillsCard
        self.onMailto = onMailto
        // Back on a message you've read: it opens at the height it had, instead of a small
        // box that grows once the page has measured itself.
        _height = State(initialValue: Self.heights[Self.heightKey(html.html, zoom: zoom, card: fillsCard)] ?? 120)
    }

    /// Measured heights of mail shown this session, so going back to one doesn't jump.
    @MainActor static var heights: [Int: CGFloat] = [:]
    static func heightKey(_ html: String, zoom: Double, card: Bool) -> Int {
        var hasher = Hasher()
        hasher.combine(html)
        hasher.combine(zoom)
        hasher.combine(card)
        return hasher.finalize()
    }

    var body: some View {
        let lightMail = colorScheme == .dark && !html.supportsDarkMode
        // Light mail in dark mode: turned dark when it has no pictures (text, lists, simple
        // layouts); designed mail with pictures, or with the setting off, sits on a white sheet.
        let flips = lightMail && Look.darkensMail && !html.hasPictures
        let onSheet = lightMail && !flips
        let dark = colorScheme == .dark && html.supportsDarkMode
        HTMLWebView(
            document: Self.document(html.html, dark: dark, flips: flips, touch: fillsCard),
            allowsRemote: allowsRemote,
            zoom: zoom,
            background: dark || flips ? Self.darkGround : Self.lightGround,
            height: $height,
            onMailto: onMailto
        )
        .frame(height: height)
        .onChange(of: height) { _, measured in
            if Self.heights.count > 500 { Self.heights.removeAll() }
            Self.heights[Self.heightKey(html.html, zoom: zoom, card: fillsCard)] = measured
        }
        .padding(fillsCard ? 0 : (onSheet ? 16 : 0))
        .background(onSheet && !fillsCard ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Dark mode for light mail without pictures: the page's colours turned around, hue kept so
    /// blue stays blue. Mail with pictures never gets this (see `SafeHTML.hasPictures`).
    static let flipStyle = """
    html { filter: invert(1) hue-rotate(180deg); }
    """

    static let lightGround: UInt32 = 0xFFFFFF
    /// Matches the reader behind the mail: true black in Deep dark.
    static var darkGround: UInt32 { Look.theme == .deepDark ? 0x000000 : 0x131314 }

    /// Wraps the mail in a page with a sensible base style. Mail styles still win; this only
    /// fills gaps (fonts, image widths) so unstyled HTML reads like the rest of the app.
    static func document(_ body: String, dark: Bool, flips: Bool = false, touch: Bool = false) -> String {
        // A flipped page is drawn light and turned around whole, so its ground is the opposite
        // of the dark ground it ends up as.
        let ground = String(format: "#%06X", dark ? darkGround : flips ? (0xFFFFFF - darkGround) : lightGround)
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root { color-scheme: \(dark ? "dark" : "light"); }
          html, body { margin: 0; padding: 0; background: \(ground); }
          body { font: 14px/1.55 -apple-system, system-ui, sans-serif; color: \(dark ? "#EDEDED" : "#1F1F1F");
                 overflow-wrap: anywhere; -webkit-text-size-adjust: 100%; }
          img { max-width: 100% !important; height: auto; }
          table { max-width: 100% !important; }
          pre { white-space: pre-wrap; }
          \(touch ? "body { font-size: 17px; padding: 4px 20px 20px; }" : "")
          a { color: \(dark ? "#5B9BFF" : "#2F6FEB"); }
          \(Look.underlineLinks ? "a { text-decoration: underline !important; }" : "")
          \(flips ? Self.flipStyle : "")
          blockquote { margin: 0 0 0 4px; padding-left: 12px; border-left: 2px solid rgba(127,127,127,.35); color: rgba(127,127,127,1); }
        </style></head><body>\(body)</body></html>
        """
    }
}

/// The rule that keeps remote content out, compiled once.
@MainActor
enum RemoteContentRules {
    private static var compiled: WKContentRuleList?

    static func blockRemote() async -> WKContentRuleList? {
        if let compiled { return compiled }
        let json = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^blob:"},"action":{"type":"ignore-previous-rules"}}]
        """
        compiled = try? await WKContentRuleListStore.default()
            .compileContentRuleList(forIdentifier: "margin.block-remote-content.v2", encodedContentRuleList: json)
        return compiled
    }
}

final class HTMLWebCoordinator: NSObject, WKNavigationDelegate {
    var height: Binding<CGFloat>
    var onMailto: (URL) -> Void
    var loaded: (document: String, allowsRemote: Bool)?
    private var generation = 0

    init(height: Binding<CGFloat>, onMailto: @escaping (URL) -> Void) {
        self.height = height
        self.onMailto = onMailto
    }

    /// Loads only when the mail or the remote setting changed. Remote content stays blocked
    /// unless the rule list could be installed; if it can't, the HTML isn't shown at all.
    @MainActor
    func load(_ document: String, allowsRemote: Bool, in webView: WKWebView) {
        guard loaded?.document != document || loaded?.allowsRemote != allowsRemote else { return }
        loaded = (document, allowsRemote)
        generation += 1
        let current = generation
        Task { @MainActor in
            let controller = webView.configuration.userContentController
            controller.removeAllContentRuleLists()
            if !allowsRemote {
                guard let rules = await RemoteContentRules.blockRemote() else { return }
                controller.add(rules)
            }
            guard current == self.generation else { return }
            webView.loadHTMLString(document, baseURL: nil)
        }
    }

    @MainActor
    func measure(_ webView: WKWebView) {
        // Runs in the app's own script world; the mail's scripts stay off.
        webView.evaluateJavaScript("Math.ceil(document.documentElement.getBoundingClientRect().height)", in: nil, in: .defaultClient) { [weak self] result in
            guard let self, case .success(let value) = result, let number = value as? Double, number > 0 else { return }
            guard abs(self.height.wrappedValue - number) > 1 else { return }
            // A short ease instead of a jump when the mail reflows to a new width.
            withAnimation(Look.reduceMotion ? nil : .easeOut(duration: 0.15)) { self.height.wrappedValue = number }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if url.scheme == "about" || url.scheme == "data" { return .allow }
        guard action.navigationType == .linkActivated else { return .cancel }
        await MainActor.run {
            switch url.scheme?.lowercased() {
            case "http", "https": Self.openInBrowser(url)
            case "mailto": onMailto(url)
            default: break
            }
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            measure(webView)
            // Data images and late layout can change the height once more.
            try? await Task.sleep(for: .milliseconds(250))
            measure(webView)
        }
    }

    @MainActor
    static func openInBrowser(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    @MainActor
    static func makeWebView(background: UInt32) -> MailWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.suppressesIncrementalRendering = true
        let webView = MailWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = false
        #if os(macOS)
        webView.allowsMagnification = false
        webView.underPageBackgroundColor = NSColor(hex: background, alpha: 1)
        #else
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        #endif
        return webView
    }
}

#if os(macOS)
/// Hands scrolling to the reader around it, and re-measures when its width changes.
final class MailWebView: WKWebView {
    var onWidthChange: (() -> Void)?
    /// Pending re-measure: while a window is being resized the width changes every frame, and
    /// measuring each time re-lays out the whole reader. It waits until the width settles.
    private var settle: DispatchWorkItem?

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        settle?.cancel()
        onWidthChange?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        guard widthChanged else { return }
        settle?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onWidthChange?() }
        settle = work
        // During a window resize, wait for the width to settle; otherwise (a column let go,
        // the sidebar shown) measure on the next turn, so the height follows at once.
        if inLiveResize {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}

struct HTMLWebView: NSViewRepresentable {
    let document: String
    let allowsRemote: Bool
    let zoom: Double
    let background: UInt32
    @Binding var height: CGFloat
    let onMailto: (URL) -> Void

    func makeCoordinator() -> HTMLWebCoordinator { HTMLWebCoordinator(height: $height, onMailto: onMailto) }

    func makeNSView(context: Context) -> MailWebView {
        let webView = HTMLWebCoordinator.makeWebView(background: background)
        webView.navigationDelegate = context.coordinator
        webView.onWidthChange = { [weak webView, coordinator = context.coordinator] in
            guard let webView else { return }
            coordinator.measure(webView)
        }
        return webView
    }

    func updateNSView(_ webView: MailWebView, context: Context) {
        context.coordinator.height = $height
        context.coordinator.onMailto = onMailto
        webView.underPageBackgroundColor = NSColor(hex: background, alpha: 1)
        if abs(webView.pageZoom - zoom) > 0.01 {
            webView.pageZoom = zoom
            context.coordinator.measure(webView)
        }
        context.coordinator.load(document, allowsRemote: allowsRemote, in: webView)
    }
}
#else
final class MailWebView: WKWebView {}

struct HTMLWebView: UIViewRepresentable {
    let document: String
    let allowsRemote: Bool
    let zoom: Double
    let background: UInt32
    @Binding var height: CGFloat
    let onMailto: (URL) -> Void

    func makeCoordinator() -> HTMLWebCoordinator { HTMLWebCoordinator(height: $height, onMailto: onMailto) }

    func makeUIView(context: Context) -> MailWebView {
        let webView = HTMLWebCoordinator.makeWebView(background: background)
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ webView: MailWebView, context: Context) {
        context.coordinator.height = $height
        context.coordinator.onMailto = onMailto
        if abs(webView.pageZoom - zoom) > 0.01 { webView.pageZoom = zoom }
        context.coordinator.load(document, allowsRemote: allowsRemote, in: webView)
    }
}
#endif

/// Pictures you chose to load for one message ("Load pictures" without trusting the sender).
/// Kept for the session, so going back to the message shows them again.
@MainActor enum PicturesShownOnce {
    private static var ids: Set<String> = []
    static func contains(_ id: String) -> Bool { ids.contains(id) }
    static func allow(_ id: String) { ids.insert(id) }
}
