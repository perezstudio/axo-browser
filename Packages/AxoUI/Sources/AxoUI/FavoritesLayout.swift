import CoreGraphics

/// How the favorites grid lays out, like Arc: one column per favorite up to four, then rows of
/// four, with fewer columns when the sidebar is too narrow for them.
nonisolated public enum FavoritesLayout {
    /// The most columns the grid uses.
    public static let maximumColumns = 4
    /// The narrowest a tile gets.
    public static let minimumTileWidth: CGFloat = 44
    /// The space between tiles.
    public static let spacing: CGFloat = 6
    /// A tile's height, which the sidebar's address bar shares so the two line up, as in Arc.
    public static let tileHeight: CGFloat = 40
    /// A tile's corner radius, which the sidebar's address bar shares too.
    public static let tileCornerRadius: CGFloat = 10

    /// The number of columns for `count` favorites in a grid `width` points wide. A width that
    /// isn't a finite size yet (a layout pass that measures with an unbounded width) gets the
    /// most columns.
    public static func columns(count: Int, width: CGFloat) -> Int {
        guard count > 0 else { return 0 }
        guard width.isFinite else { return min(count, maximumColumns) }
        // Capped before converting, so a huge width can't overflow Int.
        let fits = min((max(width, 0) + spacing) / (minimumTileWidth + spacing), CGFloat(maximumColumns))
        let fitting = max(1, Int(fits))
        return min(count, maximumColumns, fitting)
    }
}
