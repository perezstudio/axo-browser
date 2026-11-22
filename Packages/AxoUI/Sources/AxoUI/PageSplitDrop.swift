import CoreGraphics

/// Where a sidebar row dragged over the page would land (#78): beside the page on the left or
/// the right, in a split with the selected tab.
enum PageSplitDropSide: Equatable {
    case leading, trailing

    /// The side for a point `x` across a page `width` wide: its outer thirds, or nothing in the
    /// middle, where a drop does nothing.
    static func side(at x: CGFloat, width: CGFloat) -> PageSplitDropSide? {
        guard width > 0 else { return nil }
        if x < width / 3 { return .leading }
        if x > width * 2 / 3 { return .trailing }
        return nil
    }
}

#if os(macOS)
import AppKit
import AxoCore
import SwiftUI

/// Lets a sidebar row dropped on the page's left or right third make a split with the selected
/// tab (#78), showing which side it will take while it's over the page. Drawn over the page
/// column; it takes no clicks or pointer moves (its view's hit test finds nothing), only drags,
/// so the page keeps its clicks and its hovered links.
struct PageSplitDrop: View {
    let model: BrowserModel
    @State private var side: PageSplitDropSide?

    var body: some View {
        ZStack {
            DropCatcher(model: model, side: $side)
            if let side {
                // Where the dropped tab will show: the half it takes.
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.18))
                        .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2)
                        .frame(width: proxy.size.width / 2 - 12)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: side == .leading ? .leading : .trailing)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
                .accessibilityHidden(true)
            }
        }
        .animation(.easeOut(duration: 0.15), value: side)
    }

    /// The AppKit view that takes the drag.
    private struct DropCatcher: NSViewRepresentable {
        let model: BrowserModel
        @Binding var side: PageSplitDropSide?

        func makeNSView(context: Context) -> CatcherView {
            CatcherView()
        }

        func updateNSView(_ view: CatcherView, context: Context) {
            view.model = model
            view.onSideChange = { side = $0 }
        }
    }

    /// Takes a sidebar row's drag, and hands every other drag to the view under it (the page),
    /// call for call. AppKit picks a drop target by dragged type, not by hit test, so without
    /// that the page would lose its own text, link, and file drops while the catcher is over it.
    final class CatcherView: NSView {
        var model: BrowserModel?
        var onSideChange: (PageSplitDropSide?) -> Void = { _ in }
        /// The view under the catcher that's taking the current drag, when it isn't a row's.
        private var passThrough: NSView?

        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes([.string])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("Not made from a coder") }

        // Clicks, scrolls, and pointer moves go to the page under it; only drags come here.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// The payload of a drag from Axo's sidebar or Favorites (``SidebarDragPayload``), or nil
        /// for any other drag (a link, text, or a file).
        private func payload(_ info: any NSDraggingInfo) -> String? {
            guard let text = info.draggingPasteboard.string(forType: .string),
                  SidebarDragPayload.item(from: text) != nil || SidebarDragPayload.favorite(from: text) != nil
            else { return nil }
            return text
        }

        /// Whether a drag is a sidebar tab row's that can make a split now.
        private func isRow(_ info: any NSDraggingInfo) -> Bool {
            guard let model, let text = payload(info) else { return false }
            return model.tabToSplit(droppedAs: text) != nil
        }

        /// The view under the catcher at the drag's point that takes drags: the page.
        private func viewBeneath(_ info: any NSDraggingInfo) -> NSView? {
            guard let content = window?.contentView else { return nil }
            var view = content.hitTest(content.convert(info.draggingLocation, from: nil))
            // The page's innermost view may not take drags; its nearest ancestor that does.
            while let candidate = view, candidate !== content {
                if !candidate.registeredDraggedTypes.isEmpty { return candidate }
                view = candidate.superview
            }
            return nil
        }

        private func side(for info: any NSDraggingInfo) -> PageSplitDropSide? {
            guard isRow(info) else { return nil }
            let point = convert(info.draggingLocation, from: nil)
            return PageSplitDropSide.side(at: point.x, width: bounds.width)
        }

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            // Every drag from the sidebar or Favorites stays here, so one that can't make a split
            // (a folder, a favorite, the selected tab, the middle third) does nothing, rather than
            // reaching the page as the address it carries for other apps and loading it (#78).
            guard payload(sender) != nil else {
                passThrough = viewBeneath(sender)
                return passThrough?.draggingEntered(sender) ?? []
            }
            passThrough = nil
            let side = side(for: sender)
            onSideChange(side)
            return side == nil ? [] : .move
        }

        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            if let passThrough { return passThrough.draggingUpdated(sender) }
            let side = side(for: sender)
            onSideChange(side)
            return side == nil ? [] : .move
        }

        override func draggingExited(_ sender: (any NSDraggingInfo)?) {
            passThrough?.draggingExited(sender)
            passThrough = nil
            onSideChange(nil)
        }

        override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            if let passThrough { return passThrough.prepareForDragOperation(sender) }
            return side(for: sender) != nil
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            if let passThrough { return passThrough.performDragOperation(sender) }
            let side = side(for: sender)
            onSideChange(nil)
            guard let model, let side, let text = payload(sender) else { return false }
            Task { await model.splitWithDroppedTab(text, leading: side == .leading) }
            return true
        }

        override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
            passThrough?.concludeDragOperation(sender)
        }

        override func draggingEnded(_ sender: any NSDraggingInfo) {
            passThrough?.draggingEnded(sender)
            passThrough = nil
            onSideChange(nil)
        }

        override func wantsPeriodicDraggingUpdates() -> Bool {
            passThrough?.wantsPeriodicDraggingUpdates() ?? true
        }
    }
}
#endif
