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

    /// The number of columns for `count` favorites in a grid `width` points wide.
    public static func columns(count: Int, width: CGFloat) -> Int {
        guard count > 0 else { return 0 }
        let fitting = max(1, Int((width + spacing) / (minimumTileWidth + spacing)))
        return min(count, maximumColumns, fitting)
    }
}
