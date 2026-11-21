import Foundation
import MailCore
import Observation
import Testing
import WebKit
@testable import MailUI

/// Lists worked out from the mail are kept until the mail changes, and views that showed the old
/// list are told when it does.
@MainActor @Suite(.serialized) struct DerivedTests {
    private final class Flag: @unchecked Sendable { var fired = false }

    @Test func aListIsWorkedOutOnceUntilTheMailChanges() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let first = model.inboxThreads(nil)
        let before = model.derived.merged.computations
        for _ in 0..<50 { _ = model.inboxThreads(nil); _ = model.visibleThreads; _ = model.unreadCount(account: nil) }
        #expect(model.derived.merged.computations == before)

        // Marking a conversation read changes the mail: the lists follow.
        let unread = try #require(first.first(where: { $0.isUnread }))
        let count = model.unreadCount(account: nil)
        await model.apply(.markRead, to: [unread], announce: false)
        #expect(model.unreadCount(account: nil) == count - 1)
        #expect(model.inboxThreads(nil).first { $0.id == unread.id }?.isUnread == false)
        #expect(model.derived.merged.computations == before + 1)
    }

    @Test func whatIsOnScreenFollowsThePlaceTheSearchAndTheFilters() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let everything = model.visibleThreads
        #expect(!everything.isEmpty)
        let account = try #require(model.accounts.first)
        model.go(to: .inbox(account: account.id, split: nil))
        #expect(model.visibleThreads.allSatisfy { $0.accountID == account.id })
        model.go(to: .allInboxes)
        model.quickFilters = [.unread]
        #expect(model.visibleThreads.allSatisfy { $0.isUnread })
        model.quickFilters = []
        model.searchText = "zzzz-not-in-any-mail"
        #expect(model.visibleThreads.isEmpty)
        model.searchText = ""
        #expect(model.visibleThreads.map(\.id) == everything.map(\.id))
    }

    /// A view that drew a kept list is redrawn when the list's mail changes: reading the kept
    /// value counts as depending on it.
    @Test func aViewShowingAKeptListIsToldWhenItChanges() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        _ = model.visibleThreads
        let flag = Flag()
        withObservationTracking { _ = model.visibleThreads; _ = model.selectedThread } onChange: { flag.fired = true }
        #expect(!flag.fired)
        let unread = try #require(model.inboxThreads(nil).first(where: { $0.isUnread }))
        await model.apply(.markRead, to: [unread], announce: false)
        #expect(flag.fired)
    }

    @Test func theOpenConversationFollowsTheSelection() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let threads = model.visibleThreads
        try #require(threads.count >= 2)
        model.select(threads[0].id)
        #expect(model.selectedThread?.id == threads[0].id)
        model.select(threads[1].id)
        #expect(model.selectedThread?.id == threads[1].id)
        model.select(nil)
        #expect(model.selectedThread == nil)
    }

    /// A mail view that's done is wiped and used for the next mail, instead of starting a new
    /// web process each time.
    @Test func aFinishedMailViewIsReused() async throws {
        MailWebViewPool.empty()
        let first = MailWebViewPool.take(background: 0xFFFFFF)
        MailWebViewPool.give(first)
        // Wiping what it stored takes a moment.
        for _ in 0..<100 where MailWebViewPool.reused == 0 {
            try await Task.sleep(for: .milliseconds(30))
            let next = MailWebViewPool.take(background: 0xFFFFFF)
            if next === first { break }
        }
        #expect(MailWebViewPool.reused == 1)
        MailWebViewPool.empty()
    }

    private func coordinator() -> HTMLWebCoordinator { HTMLWebCoordinator(height: .constant(0), onMailto: { _ in }) }

    /// A zoom step draws the window again. The mail on screen keeps its web view, already
    /// loaded, instead of a new white one loading it again, whichever comes first: the new
    /// page view, or the old one going away.
    @Test func aRedrawKeepsTheLoadedMail() {
        MailWebViewPool.empty()
        defer { MailWebViewPool.empty() }
        let old = coordinator(), new = coordinator(), later = coordinator()
        let view = MailWebViewPool.take(background: 0xFFFFFF, showing: "<p>Hi</p>", allowsRemote: false, for: old)
        view.shown = ("<p>Hi</p>", false)
        let window = NSView()
        window.addSubview(view)

        // The new window is made while the old one is still up.
        MailWebViewPool.redrawing()
        let taken = MailWebViewPool.take(background: 0xFFFFFF, showing: "<p>Hi</p>", allowsRemote: false, for: new)
        #expect(taken === view)
        // The old page view going away doesn't take it back.
        MailWebViewPool.release(view, by: old)
        #expect(view.owner === new)
        #expect(view.shown?.document == "<p>Hi</p>")

        // The other order: the old one goes first, the new one finds it parked.
        MailWebViewPool.release(view, by: new)
        let again = MailWebViewPool.take(background: 0xFFFFFF, showing: "<p>Hi</p>", allowsRemote: false, for: later)
        #expect(again === view)
    }

    @Test func outsideARedrawEveryPageGetsItsOwnView() {
        MailWebViewPool.empty()
        defer { MailWebViewPool.empty() }
        let first = MailWebViewPool.take(background: 0xFFFFFF, showing: "<p>Hi</p>", allowsRemote: false, for: coordinator())
        first.shown = ("<p>Hi</p>", false)
        NSView().addSubview(first)
        let second = MailWebViewPool.take(background: 0xFFFFFF, showing: "<p>Hi</p>", allowsRemote: false, for: coordinator())
        #expect(second !== first)
        // Another mail, or the same mail with pictures allowed, is never taken over.
        MailWebViewPool.redrawing()
        let other = MailWebViewPool.take(background: 0xFFFFFF, showing: "<p>Hi</p>", allowsRemote: true, for: coordinator())
        #expect(other !== first)
    }

    /// During a redraw a mail starts at the height it had on screen, not a guess.
    @Test func aRedrawStartsAtTheHeightOnScreen() {
        MailWebViewPool.empty()
        defer { MailWebViewPool.empty(); HTMLMessageView.onScreen = [:] }
        let html = HTMLSanitizer.sanitize("<p>Hi</p>")
        HTMLMessageView.onScreen[HTMLMessageView.heightKey(html.html, zoom: -1, card: false)] = 417
        MailWebViewPool.redrawing()
        let view = HTMLMessageView(html: html, allowsRemote: false, zoom: 1.3)
        #expect(view.startHeight == 417)
    }

    /// Zoomed to 150%, a page that measures 640 of its own pixels is 960 points tall.
    @Test func aZoomedPageIsMeasuredInPoints() {
        #expect(HTMLWebCoordinator.points(css: 640, pageZoom: 1.5) == 960)
        #expect(HTMLWebCoordinator.points(css: 408, pageZoom: 1) == 408)
    }

    @Test func aZoomStepStartsNearTheRightHeight() {
        let saved = HTMLMessageView.heights
        defer { HTMLMessageView.heights = saved }
        HTMLMessageView.heights[HTMLMessageView.heightKey("<p>Hi</p>", zoom: 0, card: false)] = 300
        #expect(HTMLMessageView.height(of: "<p>Hi</p>", zoom: 1.2, card: false) == 360)
        HTMLMessageView.heights[HTMLMessageView.heightKey("<p>Hi</p>", zoom: 1.2, card: false)] = 350
        #expect(HTMLMessageView.height(of: "<p>Hi</p>", zoom: 1.2, card: false) == 350)
    }

    @Test func aBigTextKeyIsStableAndTellsTextsApart() {
        let page = String(repeating: "<p>Order € 12,00 for Zoë</p>", count: 4_000)
        #expect(TextKey.of(page) == TextKey.of(page + ""))
        #expect(TextKey.of(page) != TextKey.of(page + " "))
        #expect(TextKey.of(page.replacingOccurrences(of: "12,00", with: "13,00")) != TextKey.of(page))
    }
}
