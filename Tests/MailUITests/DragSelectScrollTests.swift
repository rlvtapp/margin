#if os(macOS)
import Foundation
import Testing
@testable import MailUI

/// Selecting by dragging: the reader scrolls only near or past its edges, faster further out.
@Suite struct DragSelectScrollTests {
    @Test func scrollsNearAndPastTheEdgesOnly() {
        // Well inside a 600-point reader: nothing.
        #expect(DragSelectScroll.step(pointer: 300, top: 0, bottom: 600) == 0)
        #expect(DragSelectScroll.step(pointer: 30, top: 0, bottom: 600) == 0)
        // Near the bottom it starts slowly, further past it goes faster, up to a limit.
        let near = DragSelectScroll.step(pointer: 595, top: 0, bottom: 600)
        let past = DragSelectScroll.step(pointer: 660, top: 0, bottom: 600)
        #expect(near > 0 && past > near)
        #expect(DragSelectScroll.step(pointer: 5_000, top: 0, bottom: 600) == DragSelectScroll.fastest)
        // And the same upwards.
        #expect(DragSelectScroll.step(pointer: 4, top: 0, bottom: 600) < 0)
        #expect(DragSelectScroll.step(pointer: -5_000, top: 0, bottom: 600) == -DragSelectScroll.fastest)
    }
}
#endif
