import Foundation
import SwiftUI

/// A brief on-screen notice for an action with no other visible result ("Link copied", "Closed
/// Example", "Moved to Work"), with Undo when the action can be undone. VoiceOver users hear the
/// same message through ``BrowserModel/announce``.
public struct Notice: Identifiable, Equatable {
    /// Where a notice shows.
    public enum Placement: Equatable, Sendable {
        /// At the bottom of the page column.
        case page
        /// In the sidebar's address bar, in place of the address, as Dia does for Copy Link;
        /// at the bottom of the page column while that bar isn't on screen.
        case addressBar
    }

    public let id = UUID()
    /// What happened, as a short sentence-case phrase.
    public let message: String
    /// Where it shows.
    public let placement: Placement
    /// Undoes the action, when it can be undone; the notice shows an Undo button.
    let undo: (@MainActor () async -> Void)?

    /// Whether the notice has an Undo button.
    public var canUndo: Bool { undo != nil }

    public static func == (lhs: Notice, rhs: Notice) -> Bool { lhs.id == rhs.id }
}

extension BrowserModel {
    /// How long a notice stays: longer when it offers Undo, so there's time to reach it.
    static func noticeDuration(canUndo: Bool) -> Duration { canUndo ? .seconds(5) : .seconds(2.5) }

    /// Shows `message` as a notice, replacing any notice showing, and announces it for VoiceOver,
    /// so the two always say the same thing. It goes away after a few seconds, unless the pointer
    /// is over it (``holdNotice(_:)``).
    func postNotice(_ message: String, placement: Notice.Placement = .page, undo: (@MainActor () async -> Void)? = nil) {
        notice = Notice(message: message, placement: placement, undo: undo)
        announce(undo == nil ? message : "\(message). Undo is available.")
        scheduleNoticeDismissal()
    }

    /// The notice at the bottom of the page column, if any: every notice, except one for the
    /// sidebar's address bar while that bar is on screen.
    public var pageNotice: Notice? {
        guard let notice else { return nil }
        if notice.placement == .addressBar, isSidebarAddressBarOnScreen, !isAddressEditedInSidebar { return nil }
        return notice
    }

    /// The notice the sidebar's address bar shows in place of the address, if any.
    public var addressBarNotice: Notice? {
        guard let notice, notice.placement == .addressBar, pageNotice == nil else { return nil }
        return notice
    }

    /// Keeps the notice `id` up while the pointer is over it (`true`), and lets it go a moment
    /// after the pointer leaves or the notice's view goes. A hold belongs to one notice: a newer
    /// notice, shown where the pointer rests, keeps its own time (macOS doesn't report the
    /// pointer leaving a view that was replaced under it).
    public func holdNotice(_ held: Bool, id: Notice.ID) {
        if held {
            heldNoticeID = id
        } else if heldNoticeID == id {
            heldNoticeID = nil
            if notice?.id == id { scheduleNoticeDismissal(after: .seconds(1.5)) }
        }
    }

    /// Runs the notice's Undo and closes it.
    public func undoNotice() async {
        guard let undo = notice?.undo else { return }
        dismissNotice()
        await undo()
    }

    /// Closes the notice now.
    public func dismissNotice() {
        noticeDismissal?.cancel()
        notice = nil
        heldNoticeID = nil
    }

    private func scheduleNoticeDismissal(after delay: Duration? = nil) {
        noticeDismissal?.cancel()
        guard let shown = notice else { return }
        let delay = delay ?? Self.noticeDuration(canUndo: shown.canUndo)
        let sleep = noticeSleep
        noticeDismissal = Task { [weak self] in
            await sleep(delay)
            guard let self, !Task.isCancelled, self.notice?.id == shown.id, self.heldNoticeID != shown.id else { return }
            self.notice = nil
        }
    }
}

#if os(macOS)
/// The notice at the bottom of the page column: a small capsule with the message and, when the
/// action can be undone, an Undo button. It never takes focus on its own (Undo is a VoiceOver
/// action, a click, or a Tab away with Full Keyboard Access), keeps itself up while the pointer is
/// over it, and fades instead of sliding with Reduce Motion. Unlike other overlays over pages it
/// takes the pointer, for Undo and the hold; it's small and brief.
struct NoticeView: View {
    let model: BrowserModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let notice = model.pageNotice {
                content(notice)
                    .id(notice.id)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.3), value: model.pageNotice?.id)
        .padding(.bottom, 18)
    }

    private func content(_ notice: Notice) -> some View {
        HStack(spacing: 10) {
            Text(notice.message)
                .lineLimit(1)
            if notice.canUndo {
                // Reachable with Full Keyboard Access (Tab), but never focused on its own.
                Button("Undo") { Task { await model.undoNotice() } }
                    .buttonStyle(.borderless)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("noticeUndoButton")
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .capsule)
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        .onHover { model.holdNotice($0, id: notice.id) }
        .onDisappear { model.holdNotice(false, id: notice.id) }
        // Contains, rather than combines, so the Undo button stays a button of its own.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(notice.message)
        .accessibilityActions {
            if notice.canUndo {
                Button("Undo") { Task { await model.undoNotice() } }
            }
        }
        .accessibilityIdentifier("notice")
    }
}
#endif
