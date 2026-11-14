import SwiftUI

#if os(macOS)
/// The soft shadow the page casts on the sidebar along their shared edge, so the page reads as a
/// layer above the sidebar and its Space theme (#67). It's a plain gradient in the sidebar's
/// trailing strip: no offscreen shadow pass, so scrolling and resizing cost nothing extra, and it
/// never takes hits (Chromium ignores mouse moves over a page whose window's hit test lands on
/// another view).
struct PageEdgeShadow: View {
    /// The sidebar's appearance: the Space theme's, since this is drawn inside it.
    @Environment(\.colorScheme) private var colorScheme

    /// How far the shadow reaches into the sidebar, in points.
    static let width: CGFloat = 10

    var body: some View {
        // Darker over a dark sidebar, where a light shadow wouldn't show.
        let isDark = colorScheme == .dark
        LinearGradient(
            colors: [.black.opacity(0), .black.opacity(isDark ? 0.32 : 0.10)],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        // Down to the window's bottom, but not up into the toolbar, which runs across the
        // window on macOS 27 (a stripe there would also darken the toolbar's tint).
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Draws ``PageEdgeShadow`` along the view's trailing edge.
    func pageEdgeShadow() -> some View {
        overlay(alignment: .trailing) { PageEdgeShadow() }
    }
}
#endif
