import AxoWeb
import SwiftUI

extension View {
    /// Shows where the link under the pointer (or with keyboard focus) goes, at the bottom corner
    /// of this page, like Safari's status bar. `page` is the page's state.
    func linkStatus(for page: WebTabState?) -> some View {
        modifier(LinkStatus(page: page))
    }
}

/// The link status label over a page. It never takes the page's clicks, and moves to the other
/// bottom corner while the pointer is near its own, so it never hides what's under the pointer.
private struct LinkStatus: ViewModifier {
    let page: WebTabState?
    @State private var size = CGSize.zero
    @State private var pointerNearLeadingCorner = false

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self, of: \.size) { size = $0 }
            .onContinuousHover { phase in
                let near: Bool
                if case .active(let location) = phase {
                    near = LinkStatusLayout.isNearLeadingCorner(location, in: size)
                } else {
                    near = false
                }
                // Only a change redraws, not every move of the pointer.
                if near != pointerNearLeadingCorner { pointerNearLeadingCorner = near }
            }
            .overlay(alignment: pointerNearLeadingCorner ? .bottomTrailing : .bottomLeading) {
                if let link = page?.hoveredLink {
                    LinkStatusLabel(link: link)
                        .frame(maxWidth: LinkStatusLayout.maxWidth(in: size), alignment: pointerNearLeadingCorner ? .trailing : .leading)
                        .padding(LinkStatusLayout.margin)
                }
            }
    }
}

/// Where the label goes, apart from the view so it can be tested.
enum LinkStatusLayout {
    /// The space between the label and the page's edges.
    static let margin: CGFloat = 4
    /// How tall the area the label avoids the pointer in is.
    static let cornerHeight: CGFloat = 40

    /// The label's widest: half the page, as in Safari, so the other corner stays free.
    static func maxWidth(in size: CGSize) -> CGFloat {
        max(size.width / 2 - margin * 2, 0)
    }

    /// Whether `location` (in the page's coordinates, from its top leading corner) is where the
    /// label would be in the bottom leading corner, so it should move to the other one.
    static func isNearLeadingCorner(_ location: CGPoint, in size: CGSize) -> Bool {
        location.y >= size.height - cornerHeight && location.x <= size.width / 2
    }
}

/// A link's address, shortened in the middle when it's long.
private struct LinkStatusLabel: View {
    let link: URL

    var body: some View {
        Text(verbatim: link.absoluteString)
            .font(.callout)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.regularMaterial, in: .rect(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
            .allowsHitTesting(false)
            // VoiceOver reads links' addresses itself. It stays readable (not a link: nothing to
            // press) for anyone whose pointer follows the VoiceOver cursor, and for UI tests.
            // SwiftUI's `Text` gives its string as the value; a value set here came through empty.
            .accessibilityLabel("Link address")
            .accessibilityIdentifier("linkStatus")
    }
}
