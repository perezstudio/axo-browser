import CoreFoundation
import CoreGraphics
import Foundation

/// The decisions behind swiping between Spaces on the sidebar (#84), with no AppKit, so they're
/// testable and reusable on iPad: how far the sidebar follows the fingers (rubber-banding at the
/// first and last Space) and where a finished swipe goes.
///
/// Amounts run from -1 to 1 of the sidebar's width, positive as the fingers move right. Swiping
/// left goes to the next Space and right to the previous one, following the content, as swiping
/// between pages does. Unlike the keyboard's Next and Previous Space, swipes don't wrap.
nonisolated struct SpaceSwipe: Equatable {
    /// The shown Space's position among the Spaces.
    let index: Int
    /// How many Spaces there are.
    let count: Int

    /// Whether there's a Space after the shown one.
    var canGoNext: Bool { index >= 0 && index < count - 1 }
    /// Whether there's a Space before the shown one.
    var canGoPrevious: Bool { index > 0 && index < count }

    /// The lowest amount the swipe reaches without resistance: -1 toward the next Space, or 0
    /// at the last one, where the sidebar rubber-bands instead.
    var minimumAmount: CGFloat { canGoNext ? -1 : 0 }
    /// The highest amount: 1 toward the previous Space, or 0 at the first one.
    var maximumAmount: CGFloat { canGoPrevious ? 1 : 0 }

    /// How far a swipe must go before the fingers lift for it to switch: a quarter of the way,
    /// as swiping between pages feels.
    static let switchThreshold: CGFloat = 0.25

    /// The Space a swipe whose fingers lifted at `amount` switches to, or `nil` when it didn't go
    /// far enough, went past an end, or went back.
    func target(endingAt amount: CGFloat) -> Int? {
        if amount <= -Self.switchThreshold, canGoNext { return index + 1 }
        if amount >= Self.switchThreshold, canGoPrevious { return index - 1 }
        return nil
    }

    /// How far the sidebar follows the fingers, in points, for a sidebar `width` wide: all the
    /// way, so the neighboring Space comes in under them, and resisting past an end.
    func offset(for amount: CGFloat, width: CGFloat) -> CGFloat {
        let allowed = min(max(amount, minimumAmount), maximumAmount)
        // Past an end, a little give: a sixth of the overshoot.
        let overshoot = amount - allowed
        return (allowed + overshoot / 6) * width
    }

    /// Whether a scroll that's starting may become a swipe between Spaces: from a trackpad
    /// (precise deltas, with phases), with more than one Space. Which way it goes is decided after
    /// a few points (``SwipeAxisLock``); a mouse's scroll wheel is left alone.
    ///
    /// It doesn't follow System Settings' "Swipe between pages", which is for going back and
    /// forward: inside Axo's process every way of reading it (`NSEvent.isSwipeTrackingFromScrollEventsEnabled`,
    /// the global preferences) sees it off for a while after launch, while the embedded Chromium
    /// engine starts, so swipes over the sidebar were ignored then.
    static func mayTrack(isBeginning: Bool, hasPreciseDeltas: Bool, spaceCount: Int) -> Bool {
        isBeginning && hasPreciseDeltas && spaceCount > 1
    }
}

/// Decides whether a trackpad gesture over the sidebar is a swipe between Spaces or a vertical
/// scroll of its tabs, from its first few points of movement rather than its first event (a
/// vertical scroll's first event often leans sideways). Until it decides, the gesture scrolls
/// the tabs as usual; once it's vertical, it stays a scroll to the end.
nonisolated struct SwipeAxisLock {
    /// What the gesture is, as far as it's known.
    enum Axis: Equatable { case undecided, horizontal, vertical }

    /// How far the fingers move before the gesture's direction is decided, in points.
    static let decidingDistance: CGFloat = 6
    /// How much more horizontal than vertical a gesture must be to swipe between Spaces.
    static let horizontalBias: CGFloat = 2

    private(set) var axis: Axis = .undecided
    /// The movement so far, while undecided.
    private(set) var x: CGFloat = 0
    private(set) var y: CGFloat = 0

    /// Adds movement; returns the gesture's axis, decided once the fingers have gone far enough.
    mutating func add(deltaX: CGFloat, deltaY: CGFloat) -> Axis {
        guard axis == .undecided else { return axis }
        x += deltaX
        y += deltaY
        guard hypot(x, y) >= Self.decidingDistance else { return .undecided }
        axis = abs(x) >= abs(y) * Self.horizontalBias ? .horizontal : .vertical
        return axis
    }
}

/// One swipe followed from the trackpad's scroll events (#84): the sidebar's pages move with the
/// fingers point for point, and when they lift it decides from how far they went, or from a
/// flick, and switches at most once. Momentum events after the lift belong to the swipe but
/// don't move it.
nonisolated struct SpaceSwipeDrag {
    let swipe: SpaceSwipe
    /// The sidebar's width: a full swipe's distance.
    let width: CGFloat
    /// How far the fingers have moved the pages, in points (positive toward the previous Space).
    private(set) var distance: CGFloat = 0
    /// The latest movement, in points, for telling a flick.
    private(set) var lastDelta: CGFloat = 0
    /// Whether the fingers have lifted.
    private(set) var didLift = false

    /// A movement this fast as the fingers lift switches even before a quarter of the way.
    static let flickSpeed: CGFloat = 8

    init(_ swipe: SpaceSwipe, width: CGFloat) {
        self.swipe = swipe
        self.width = max(width, 1)
    }

    /// The fingers moved the content `delta` points (positive to the right). Returns the pages'
    /// offset: under the fingers, resisting past the first and last Space.
    mutating func move(by delta: CGFloat) -> CGFloat {
        guard !didLift else { return offset }
        distance += delta
        if delta != 0 { lastDelta = delta }
        return offset
    }

    /// The pages' offset for the distance so far.
    var offset: CGFloat { swipe.offset(for: distance / width, width: width) }

    /// The fingers lifted: the Space to switch to, or `nil` to spring back. Once.
    mutating func lift() -> Int? {
        guard !didLift else { return nil }
        didLift = true
        if let target = swipe.target(endingAt: distance / width) { return target }
        // A flick in the direction the fingers went switches too.
        guard abs(lastDelta) >= Self.flickSpeed, lastDelta.sign == distance.sign, distance != 0 else { return nil }
        return swipe.target(endingAt: distance < 0 ? -1 : 1)
    }
}
