import Foundation
import Testing
import WebKit
@testable import MailUI

/// Mail built to a fixed width is scaled to the room it has; mail that fits is left alone.
@MainActor
@Suite struct HTMLFitTests {
    private func page(_ body: String, width: CGFloat) async throws -> WKWebView {
        let webView = HTMLWebCoordinator.makeWebView(background: 0xFFFFFF)
        webView.frame = CGRect(x: 0, y: 0, width: width, height: 400)
        let loaded = Loaded()
        webView.navigationDelegate = loaded
        webView.loadHTMLString(HTMLMessageView.document(body, dark: false), baseURL: nil)
        await loaded.wait()
        return webView
    }

    private func number(_ script: String, in webView: WKWebView) async throws -> Double {
        let value = try await webView.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient)
        return (value as? Double) ?? Double(value as? Int ?? -1)
    }

    @Test func aFixedWidthNewsletterIsScaledToTheNarrowPane() async throws {
        let webView = try await page("<div style=\"width:600px;height:300px\">A newsletter</div>", width: 300)
        let height = try await number(HTMLWebCoordinator.fitScript, in: webView)
        let scale = try await number("parseFloat(document.body.style.zoom)", in: webView)
        #expect(abs(scale - 0.5) < 0.02)
        // Nothing is left sticking out to the right, and the height follows the smaller page.
        #expect(try await number("document.documentElement.scrollWidth", in: webView) <= 301)
        #expect(height > 100 && height < 220)
    }

    @Test func mailThatFitsIsLeftAlone() async throws {
        let webView = try await page("<p>Hello there, see you on Friday.</p>", width: 300)
        _ = try await number(HTMLWebCoordinator.fitScript, in: webView)
        #expect(try await webView.evaluateJavaScript("document.body.style.zoom", in: nil, contentWorld: .defaultClient) as? String == "")
    }

    @Test func aWiderPaneTakesTheScalingOffAgain() async throws {
        let webView = try await page("<div style=\"width:600px;height:300px\">A newsletter</div>", width: 300)
        _ = try await number(HTMLWebCoordinator.fitScript, in: webView)
        webView.frame.size.width = 700
        try await Task.sleep(for: .milliseconds(100))
        _ = try await number(HTMLWebCoordinator.fitScript, in: webView)
        #expect(try await webView.evaluateJavaScript("document.body.style.zoom", in: nil, contentWorld: .defaultClient) as? String == "")
    }

    @Test func veryWideMailStopsAtTheSmallestReadableScale() async throws {
        let webView = try await page("<div style=\"width:3000px;height:300px\">A spreadsheet</div>", width: 300)
        _ = try await number(HTMLWebCoordinator.fitScript, in: webView)
        #expect(abs(try await number("parseFloat(document.body.style.zoom)", in: webView) - HTMLWebCoordinator.smallestScale) < 0.001)
    }

    /// Mail that pins its page to the window's height (`height: 100%`, common in receipts)
    /// must still report its whole length, or it's cut off at the small box it starts in.
    @Test func mailPinnedToTheWindowHeightStillReportsItsLength() async throws {
        let mail = "<style>html, body { height: 100% !important; overflow: hidden; }</style>"
            + "<table height=\"100%\" style=\"height:100%\"><tr><td><div style=\"height:900px\">A receipt</div></td></tr></table>"
        let webView = try await page(mail, width: 600)
        webView.frame.size.height = 120
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await number(HTMLWebCoordinator.fitScript, in: webView) >= 900)
    }
}

private final class Loaded: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var done = false

    func wait() async {
        if done { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        done = true
        continuation?.resume()
        continuation = nil
    }
}
