import Foundation
import Testing
@testable import AxoUI

@MainActor
struct LinkStatusTests {
    let page = CGSize(width: 1000, height: 600)

    @Test func theLabelTakesAtMostHalfThePage() {
        #expect(LinkStatusLayout.maxWidth(in: page) == 492)
        #expect(LinkStatusLayout.maxWidth(in: .zero) == 0)
    }

    @Test func itMovesOnlyWhenThePointerIsInItsCorner() {
        // Where the label sits: the bottom of the leading half.
        #expect(LinkStatusLayout.isNearLeadingCorner(CGPoint(x: 10, y: 590), in: page))
        #expect(LinkStatusLayout.isNearLeadingCorner(CGPoint(x: 500, y: 560), in: page))
        // Above it, or in the trailing half.
        #expect(!LinkStatusLayout.isNearLeadingCorner(CGPoint(x: 10, y: 559), in: page))
        #expect(!LinkStatusLayout.isNearLeadingCorner(CGPoint(x: 501, y: 590), in: page))
        #expect(!LinkStatusLayout.isNearLeadingCorner(CGPoint(x: 300, y: 300), in: page))
    }
}
