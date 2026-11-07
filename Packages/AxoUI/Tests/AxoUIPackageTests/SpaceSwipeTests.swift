import CoreGraphics
import Testing
@testable import AxoUI

/// The decisions behind swiping between Spaces on the sidebar (#84).
struct SpaceSwipeTests {
    @Test func swipingLeftGoesToTheNextSpaceAndRightToThePrevious() {
        let middle = SpaceSwipe(index: 1, count: 3)
        #expect(middle.target(endingAt: -1) == 2, "Fingers left: the next Space, as content moves")
        #expect(middle.target(endingAt: 1) == 0, "Fingers right: the previous Space")
    }

    @Test func aQuarterOfTheWayIsEnoughAndLessStays() {
        let middle = SpaceSwipe(index: 1, count: 3)
        #expect(middle.target(endingAt: -0.25) == 2, "A quarter of the way switches")
        #expect(middle.target(endingAt: 0.4) == 0)
        #expect(middle.target(endingAt: -0.2) == nil, "Less springs back")
        #expect(middle.target(endingAt: 0) == nil, "Cancelled, or went back")
    }

    @Test func theEndsRubberBandInsteadOfWrapping() {
        let first = SpaceSwipe(index: 0, count: 3)
        #expect(first.target(endingAt: 1) == nil, "Nothing before the first Space")
        #expect(first.maximumAmount == 0)
        let last = SpaceSwipe(index: 2, count: 3)
        #expect(last.target(endingAt: -1) == nil, "Nothing after the last: no wrapping around")
        #expect(last.minimumAmount == 0)
    }

    @Test func thePagesFollowAndResistPastAnEnd() {
        let first = SpaceSwipe(index: 0, count: 2)
        #expect(first.offset(for: -1, width: 200) == -200, "All the way: the next Space fills the sidebar")
        #expect(first.offset(for: -0.5, width: 200) == -100, "Under the fingers")
        #expect(first.offset(for: 0.6, width: 200) == 20, "Past the first Space: a sixth of the way")
    }

    @Test func onlyTrackpadGesturesMayBeSwipes() {
        func may(began: Bool = true, precise: Bool = true, spaces: Int = 2) -> Bool {
            SpaceSwipe.mayTrack(isBeginning: began, hasPreciseDeltas: precise, spaceCount: spaces)
        }
        #expect(may())
        #expect(!may(began: false), "Only as a gesture starts")
        #expect(!may(precise: false), "A mouse's scroll wheel")
        #expect(!may(spaces: 1), "Nowhere to go")
    }

    @Test func aVerticalScrollThatStartsSidewaysStaysAScroll() {
        // A vertical scroll's first event often leans sideways; that alone mustn't make a swipe.
        var lock = SwipeAxisLock()
        #expect(lock.add(deltaX: 2, deltaY: 1) == .undecided, "Too little to tell")
        #expect(lock.add(deltaX: 0, deltaY: 6) == .vertical)
        #expect(lock.add(deltaX: 40, deltaY: 0) == .vertical, "Decided: stays a scroll to the end")
    }

    @Test func aClearlySidewaysGestureIsASwipe() {
        var lock = SwipeAxisLock()
        #expect(lock.add(deltaX: -3, deltaY: 1) == .undecided)
        #expect(lock.add(deltaX: -6, deltaY: 1) == .horizontal)
        #expect(lock.add(deltaX: 0, deltaY: 30) == .horizontal, "Decided: vertical movement doesn't undo it")
    }

    @Test func aDiagonalGestureIsAScroll() {
        var lock = SwipeAxisLock()
        #expect(lock.add(deltaX: 6, deltaY: 4) == .vertical, "Not twice as sideways as up or down")
    }

    @Test func thePagesFollowTheFingersPointForPoint() {
        var drag = SpaceSwipeDrag(SpaceSwipe(index: 1, count: 3), width: 200)
        #expect(drag.move(by: -30) == -30)
        #expect(drag.move(by: -50) == -80, "Under the fingers")
        #expect(drag.move(by: 20) == -60)
    }

    @Test func liftingPastAQuarterLocksOntoTheNextPageOnce() {
        var drag = SpaceSwipeDrag(SpaceSwipe(index: 1, count: 3), width: 200)
        _ = drag.move(by: -60)
        _ = drag.move(by: -1)
        #expect(drag.lift() == 2)
        #expect(drag.lift() == nil, "Once, however long its momentum lasts")
        #expect(drag.move(by: -100) == drag.offset, "Momentum doesn't move it")
    }

    @Test func liftingShortSpringsBackUnlessItsAFlick() {
        var short = SpaceSwipeDrag(SpaceSwipe(index: 1, count: 3), width: 200)
        _ = short.move(by: 20)
        _ = short.move(by: 2)
        #expect(short.lift() == nil, "Barely moved")

        var flick = SpaceSwipeDrag(SpaceSwipe(index: 1, count: 3), width: 200)
        _ = flick.move(by: 10)
        _ = flick.move(by: 15)
        #expect(flick.lift() == 0, "A flick toward the previous Space")
    }

    @Test func takenBackBeforeLiftingStays() {
        var drag = SpaceSwipeDrag(SpaceSwipe(index: 1, count: 3), width: 200)
        _ = drag.move(by: -150)
        _ = drag.move(by: 140)
        _ = drag.move(by: 4) // the fingers came back, slowly
        #expect(drag.lift() == nil)
    }

    @Test func theEndsResistAndDontSwitch() {
        var drag = SpaceSwipeDrag(SpaceSwipe(index: 0, count: 2), width: 200)
        #expect(drag.move(by: 120) == 20, "Past the first Space: a sixth of the way")
        #expect(drag.lift() == nil)
    }
}
