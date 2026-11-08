import AxoCore
import SwiftUI

#if os(macOS)
import AppKit

/// The sidebar's pages of Spaces and a swipe between them as it happens (#84).
@MainActor
@Observable
final class SidebarSwipeState {
    /// The page the sidebar rests on: the shown Space's position.
    var pageIndex = 0
    /// How far the pages are moved from their resting page, following the fingers.
    var offset: CGFloat = 0
}

/// Watches two-finger horizontal swipes on the trackpad over its area of the sidebar and moves
/// the Spaces' pages with them (#84), following the scroll events point for point: the pages
/// move under the fingers, rubber-band at the first and last Space, and when the fingers lift,
/// lock onto the next page (switching to its Space) or spring back (``SpaceSwipeDrag``). A gesture
/// passes through until its first few points show it's sideways (``SwipeAxisLock``), so the tabs
/// still scroll vertically. Scroll events reach the sidebar's lists first, so this listens with a
/// local event monitor limited to its own frame, placed behind the area it covers.
struct SidebarSwipeCatcher: NSViewRepresentable {
    let model: BrowserModel
    let state: SidebarSwipeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        context.coordinator.model = model
        context.coordinator.state = state
        context.coordinator.reduceMotion = reduceMotion
    }

    static func dismantleNSView(_ view: CatcherView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, state: state)
    }

    /// An empty view whose frame is the area swipes count in; it starts listening once it's in a
    /// window.
    final class CatcherView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { coordinator?.start(in: self) } else { coordinator?.stop() }
        }

        // Never in the way of clicks or the accessibility tree.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
    }

    @MainActor
    final class Coordinator {
        var model: BrowserModel
        var state: SidebarSwipeState
        var reduceMotion = false
        private var monitor: Any?
        private weak var view: NSView?
        /// The swipe under way: from the moment it's known to be one until its momentum ends.
        private var drag: SpaceSwipeDrag?
        /// A gesture that began over this view whose direction isn't known yet: its events pass
        /// through (the tabs scroll as usual) until it's clearly sideways, when it becomes a
        /// swipe, or vertical, when it's left alone to the end.
        private var pending: (lock: SwipeAxisLock, swipe: SpaceSwipe, width: CGFloat, distance: CGFloat)?

        init(model: BrowserModel, state: SidebarSwipeState) {
            self.model = model
            self.state = state
        }

        func start(in view: NSView) {
            self.view = view
            guard monitor == nil else { return }
            // Local monitors run on the main thread, for events of this app.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { @MainActor [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            idleTimer?.cancel()
        }

        /// Follows a swipe that begins over this view, consuming its events (and the momentum
        /// after the fingers lift); passes every other event on.
        private func handle(_ event: NSEvent) -> NSEvent? {
            if var undecided = pending {
                if event.phase.contains(.changed) {
                    undecided.distance += fingerDelta(event)
                    switch undecided.lock.add(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY) {
                    case .undecided:
                        pending = undecided
                        return event
                    case .vertical:
                        pending = nil
                        return event
                    case .horizontal:
                        pending = nil
                        var started = SpaceSwipeDrag(undecided.swipe, width: undecided.width)
                        let offset = started.move(by: undecided.distance)
                        drag = started
                        if !reduceMotion { state.offset = offset }
                        finishIfIdle()
                        // The neighbors' rows are kept loaded; read them again in case something
                        // changed them.
                        Task { await model.refreshNeighborPreviews() }
                        return nil
                    }
                }
                // Lifted, or a new gesture, before it was clearly one way: it was a scroll.
                pending = nil
                return event.phase == .began ? begin(event) : event
            }
            if var current = drag {
                // The fingers lifted, however the trackpad says so: an ended or cancelled phase,
                // or (after the fingers rested, then lifted) momentum or a new gesture with no
                // ended phase first. The pages lock onto a page either way, never stopping
                // halfway.
                let lifted = event.phase.contains(.ended) || event.phase.contains(.cancelled)
                    || !event.momentumPhase.isEmpty || event.phase == .began || event.phase.isEmpty
                if !current.didLift, lifted {
                    finish(&current)
                    // The lifting event is the swipe's, unless it starts a new gesture.
                    if event.phase != .began, event.momentumPhase.isEmpty { return nil }
                }
                // After the lift, only momentum belongs to the swipe, and doesn't move it.
                // Anything else (a new gesture, fingers resting to stop a page's scrolling, a
                // plain scroll) ends it and goes on as usual.
                guard current.owns(afterLiftEventWithMomentum: !event.momentumPhase.isEmpty) else {
                    drag = nil
                    return begin(event)
                }
                if !event.momentumPhase.isEmpty {
                    if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { drag = nil }
                    return nil
                }
                if !current.didLift, event.phase.contains(.changed) {
                    let offset = current.move(by: fingerDelta(event))
                    drag = current
                    if !reduceMotion { state.offset = offset }
                    finishIfIdle()
                }
                return nil
            }
            return begin(event)
        }

        /// The wait for the fingers to move again, for ``finishIfIdle()``.
        private var idleTimer: Task<Void, Never>?

        /// Locks the pages onto a page if the fingers don't move again for a moment: a trackpad
        /// can stop reporting without saying the fingers lifted, and the pages mustn't stay
        /// stuck between two Spaces. Each movement restarts the wait.
        private func finishIfIdle() {
            idleTimer?.cancel()
            idleTimer = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self, var current = self.drag, !current.didLift else { return }
                self.finish(&current)
            }
        }

        /// The fingers lifted: lock onto the next page (switching to its Space) or spring back.
        private func finish(_ current: inout SpaceSwipeDrag) {
            let target = current.lift()
            drag = current
            if let target {
                land(at: target, from: current.swipe, width: current.width)
            } else {
                withAnimation(.spring(duration: 0.25)) { state.offset = 0 }
            }
        }

        /// Watches a trackpad gesture that begins over this view, to tell from its first few
        /// points whether it's a swipe; passes the event on either way.
        private func begin(_ event: NSEvent) -> NSEvent? {
            guard let view, let window = view.window, event.window === window,
                  view.bounds.contains(view.convert(event.locationInWindow, from: nil)),
                  let index = model.spaces.firstIndex(where: { $0.id == model.space?.id }),
                  SpaceSwipe.mayTrack(
                      isBeginning: event.phase == .began, hasPreciseDeltas: event.hasPreciseScrollingDeltas,
                      spaceCount: model.spaces.count, isLanding: isLanding)
            else { return event }
            var lock = SwipeAxisLock()
            _ = lock.add(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
            pending = (lock, SpaceSwipe(index: index, count: model.spaces.count), view.bounds.width, fingerDelta(event))
            return event
        }

        /// How far the fingers moved the content, positive to the right, whichever way the
        /// person's scrolling goes ("Natural scrolling" or not): a swipe follows the fingers.
        private func fingerDelta(_ event: NSEvent) -> CGFloat {
            event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        }

        /// Whether a swipe is landing: from the lift until its Space is shown (or isn't).
        private var isLanding = false

        /// Slides the rest of the way, so the neighboring Space's page fills the sidebar, rests
        /// the pages on it, and switches to its Space. The page is the Space's own, already
        /// drawn, so it only turns live: nothing reloads. With Reduce Motion it just switches.
        private func land(at target: Int, from swipe: SpaceSwipe, width: CGFloat) {
            let spaces = model.spaces
            guard spaces.indices.contains(target) else { return }
            let destination = spaces[target].id
            isLanding = true
            guard !reduceMotion else {
                state.pageIndex = target
                state.offset = 0
                switchSpace(to: destination)
                return
            }
            let towardNext = target > swipe.index
            withAnimation(.spring(duration: 0.25, bounce: 0)) {
                state.offset = towardNext ? -width : width
            } completion: { [self] in
                // The same spot: the pages rest on the new page, not moved from it.
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) {
                    state.pageIndex = target
                    state.offset = 0
                }
                switchSpace(to: destination)
            }
        }

        /// Shows the Space the pages landed on. If it didn't change (the Space was deleted
        /// meanwhile, or couldn't be read), the pages slide back to the shown Space's page, the
        /// only one that's live: they must never rest on a page that can't be used.
        private func switchSpace(to destination: Space.ID) {
            Task {
                await model.selectSpace(destination)
                isLanding = false
                guard let shown = SpaceSwipe.restingPage(shown: model.space?.id, in: model.spaces),
                      shown != state.pageIndex else { return }
                if reduceMotion {
                    state.pageIndex = shown
                } else {
                    withAnimation(.spring(duration: 0.25, bounce: 0)) { state.pageIndex = shown }
                }
            }
        }
    }
}
#endif
