import CoreGraphics

/// When a page's scrolling shrinks the iPhone's bar and when it brings it back (#182): down by
/// more than ``threshold`` past ``topZone`` shrinks it; up by more than ``threshold`` from the
/// furthest point down, or back within ``topZone`` of the top, grows it.
public struct ChromeCollapse: Equatable, Sendable {
    /// How far the page must scroll one way before the bar changes.
    public static let threshold: CGFloat = 40
    /// Near the top, the bar always shows in full.
    public static let topZone: CGFloat = 60

    public private(set) var isCompact = false
    /// Where the current run of scrolling one way started: the bar changes once the page has
    /// moved ``threshold`` from it.
    private var anchor: CGFloat = 0

    public init() {}

    /// Takes the page's new offset; returns whether ``isCompact`` changed.
    @discardableResult
    public mutating func scrolled(to offset: CGFloat) -> Bool {
        let was = isCompact
        if offset < Self.topZone {
            isCompact = false
            anchor = offset
        } else if isCompact {
            // Track the furthest point down; coming back up far enough shows the bar.
            if offset > anchor { anchor = offset } else if anchor - offset > Self.threshold { isCompact = false; anchor = offset }
        } else {
            if offset < anchor { anchor = offset } else if offset - anchor > Self.threshold { isCompact = true; anchor = offset }
        }
        return isCompact != was
    }

    /// Shows the bar in full now (the pill was tapped), counting from `offset`.
    public mutating func expand(at offset: CGFloat) {
        isCompact = false
        anchor = offset
    }
}
