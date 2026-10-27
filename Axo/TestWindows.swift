//
//  TestWindows.swift
//  Axo
//

import AppKit
import SwiftUI

/// Keeps test runs' browser windows apart from the person's own.
///
/// Tests share user defaults (`com.perezstudio.Axo`) with the person's Axo, both UI tests and unit
/// tests (which host in Axo), and AppKit saves a window's frame (and its split view's column
/// widths) there under keys named after the window's ID whenever it moves or closes. Clearing the
/// window's autosave name doesn't stop that: SwiftUI saves before Axo sees the window. So in test
/// runs the browser window group gets its own ID, AppKit's saves land under test-only keys, and
/// the person's frame is never touched.
enum TestWindows {
    /// The browser window group's ID in test runs.
    static let browserWindowID = "browser-testing"

    /// Whether this launch is a test run: UI testing mode, or hosting unit tests (XCTest sets
    /// `XCTestConfigurationFilePath`).
    static func isTestRun(isUITesting: Bool, environment: [String: String]) -> Bool {
        isUITesting || environment["XCTestConfigurationFilePath"] != nil
    }

    /// The browser window group's ID: the person's (`"browser"`) or test runs' own.
    static func browserWindowID(isTestRun: Bool) -> String {
        isTestRun ? browserWindowID : "browser"
    }

    /// The keys AppKit saved for test windows in earlier runs, such as
    /// `NSWindow Frame browser-testing-AppWindow-1`.
    static func savedFrameKeys(in defaults: UserDefaults) -> [String] {
        defaults.dictionaryRepresentation().keys.filter { key in
            (key.hasPrefix("NSWindow Frame ") || key.hasPrefix("NSSplitView Subview Frames "))
                && key.contains(" \(browserWindowID)-")
        }
    }

    /// Forgets test windows' saved frames, so every test launch starts from the same window size
    /// and sidebar width. Only removes test-only keys; the person's are never touched.
    static func forgetSavedFrames(in defaults: UserDefaults) {
        for key in savedFrameKeys(in: defaults) {
            defaults.removeObject(forKey: key)
        }
    }

    /// Where a test window of `size` goes: centered in the primary display's visible area
    /// (`screenFrame`), shrunk to fit. UI tests that screenshot windows or hit-test their controls
    /// fail on other displays, which may be arranged anywhere.
    static func frame(for size: CGSize, in screenFrame: CGRect) -> CGRect {
        let width = min(size.width, screenFrame.width)
        let height = min(size.height, screenFrame.height)
        return CGRect(
            x: (screenFrame.midX - width / 2).rounded(),
            y: (screenFrame.midY - height / 2).rounded(),
            width: width,
            height: height
        )
    }
}

/// Moves the browser window onto the primary display (the one with the menu bar) once it's
/// shown. Only used in test runs.
struct TestWindowPlacer: NSViewRepresentable {
    func makeNSView(context: Context) -> PlacerView { PlacerView() }
    func updateNSView(_ view: PlacerView, context: Context) {}

    final class PlacerView: NSView {
        private var placed = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !placed, window != nil else { return }
            placed = true
            // Not during SwiftUI's view update, where AppKit may not change the window.
            DispatchQueue.main.async { [weak self] in
                guard let window = self?.window, let primary = NSScreen.screens.first else { return }
                let frame = TestWindows.frame(for: window.frame.size, in: primary.visibleFrame)
                window.setFrame(frame, display: true)
            }
        }
    }
}
