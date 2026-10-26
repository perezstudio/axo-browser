#if os(macOS)
import AppKit
import SwiftUI

/// Puts its window in full screen while a page fills the screen, and back after, and reports the
/// person leaving full screen another way (the green button, Control-Command-F). A window that
/// was already full screen stays full screen.
struct PageFullscreenWindow: NSViewRepresentable {
    let isFullscreen: Bool
    let onExit: () -> Void

    func makeNSView(context: Context) -> WindowWatcher { WindowWatcher() }

    func updateNSView(_ view: WindowWatcher, context: Context) {
        view.onExit = onExit
        view.setPageFullscreen(isFullscreen)
    }

    final class WindowWatcher: NSView {
        var onExit: () -> Void = {}
        private var wantsFullscreen = false
        /// Whether Axo made the window full screen for the page, so it should undo that.
        private var enteredForPage = false
        private var observer: (any NSObjectProtocol)?

        func setPageFullscreen(_ fullscreen: Bool) {
            guard fullscreen != wantsFullscreen else { return }
            wantsFullscreen = fullscreen
            // Not during SwiftUI's view update, where AppKit doesn't change the window.
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observer.map(NotificationCenter.default.removeObserver)
            observer = window.map { window in
                NotificationCenter.default.addObserver(forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.windowWillExitFullScreen() }
                }
            }
            apply()
        }

        private func apply() {
            guard let window else { return }
            let isFullScreen = window.styleMask.contains(.fullScreen)
            if wantsFullscreen, !isFullScreen {
                enteredForPage = true
                window.toggleFullScreen(nil)
            } else if !wantsFullscreen, enteredForPage, isFullScreen {
                enteredForPage = false
                window.toggleFullScreen(nil)
            }
        }

        private func windowWillExitFullScreen() {
            enteredForPage = false
            // The person left full screen while the page filled it: the page stops too.
            if wantsFullscreen {
                wantsFullscreen = false
                onExit()
            }
        }
    }
}
#endif
