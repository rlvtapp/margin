import Foundation
import Testing
@testable import MailUI

/// Which columns a window of each width gets.
@MainActor @Suite struct WindowFitTests {
    private func model(width: CGFloat, sidebarHidden: Bool = false) -> MailModel {
        let model = MailModel(environment: .preview())
        model.isSidebarHidden = sidebarHidden
        model.fit(windowWidth: width)
        return model
    }

    @Test func aWideWindowHasEveryColumn() {
        let wide = model(width: 1480)
        #expect(!wide.sidebarNeedsDrawer && !wide.isWindowNarrow && !wide.isSidebarOutOfSight)
        #expect(!wide.opensOverList)
    }

    @Test func theMailboxColumnGoesFirst() {
        // Rail + mailboxes + list and message; the first two are wider in the roomy size.
        let everything = MailLayout.railWidth + MailModel.sidebarWidth + MailModel.narrowestSplit
        #expect(!model(width: everything).sidebarNeedsDrawer)
        let narrower = model(width: everything - 16)
        #expect(narrower.sidebarNeedsDrawer && narrower.isSidebarOutOfSight)
        // The list and a message still fit side by side without it.
        #expect(!narrower.isWindowNarrow)
    }

    @Test func thenTheListAndTheMessageTakeTurns() {
        let split = MailLayout.railWidth + MailModel.narrowestSplit
        #expect(!model(width: split + 4).isWindowNarrow)
        let small = model(width: split - 36)
        #expect(small.isWindowNarrow && small.opensOverList)
        #expect(model(width: 480).isWindowNarrow)
    }

    @Test func hidingTheSidebarYourselfBuysRoom() {
        // With the column hidden by choice, the split survives further down.
        #expect(!model(width: 760, sidebarHidden: true).isWindowNarrow)
    }

    @Test func theSidebarButtonOpensTheDrawerWhenTheresNoColumn() {
        let small = model(width: 800)
        small.toggleSidebar()
        #expect(small.isSidebarDrawerOpen)
        // The setting itself isn't touched by a small window.
        #expect(!small.isSidebarHidden)
        // Made wide again, the drawer is gone and the column is back.
        small.fit(windowWidth: 1400)
        #expect(!small.isSidebarDrawerOpen && !small.isSidebarOutOfSight)
        small.toggleSidebar()
        #expect(small.isSidebarHidden)
    }
}
