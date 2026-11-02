//
//  DevToolsWindowController.swift
//  Axo
//

import AppKit
import AxoChromium

/// Shows Chromium's DevTools in a window of its own (undocked from a page, or for a worker),
/// titled as DevTools titles itself. Closing the window closes DevTools; DevTools docking again
/// or its page closing closes the window. ⌘W closes it; other shortcuts DevTools doesn't use go
/// to Axo's menu.
@MainActor
final class DevToolsWindowController: NSObject, NSWindowDelegate {
    /// The autosave name for the window's frame. Test runs save none, so they never change the
    /// person's saved frame (Axo's user defaults are shared with UI tests).
    static func frameAutosaveName(isTestRun: Bool) -> String? {
        isTestRun ? nil : "AxoDevToolsWindow"
    }

    let devTools: ChromiumDevToolsWindow
    let window: NSWindow
    /// Where shortcuts DevTools and the window don't use go: Axo's menu.
    var performMenuKey: (NSEvent) -> Bool = { NSApp.mainMenu?.performKeyEquivalent(with: $0) ?? false }
    /// Called once the window has closed, for whoever keeps the controller.
    var onClosed: ((DevToolsWindowController) -> Void)?
    /// Whether DevTools went away first, so closing the window doesn't close it again.
    private var devToolsEnded = false

    /// - Parameters:
    ///   - devTools: The DevTools to show.
    ///   - isTestRun: Test runs don't save the window's frame.
    ///   - cascadingFrom: Another DevTools window open now, to place this one below and right of.
    ///     The frame's autosave name belongs to one window at a time, so a second one cascades.
    init(devTools: ChromiumDevToolsWindow, isTestRun: Bool, cascadingFrom other: NSWindow? = nil) {
        self.devTools = devTools
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.isReleasedWhenClosed = false
        window.title = devTools.title
        window.minSize = NSSize(width: 400, height: 300)
        window.delegate = self
        let view = devTools.view
        view.frame = window.contentView?.bounds ?? .zero
        view.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(view)
        window.center()
        let restored = Self.frameAutosaveName(isTestRun: isTestRun).map { window.setFrameAutosaveName($0) } ?? false
        if !restored, let other {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: other.frame.minX, y: other.frame.maxY)))
        }
        devTools.onTitleChange = { [weak self] in
            guard let self else { return }
            window.title = self.devTools.title
        }
        devTools.onClose = { [weak self] in
            self?.devToolsEnded = true
            self?.window.close()
        }
        devTools.onUnusedKeyEvent = { [weak self] event in
            self?.handleUnusedKey(event) ?? false
        }
        devTools.onActivate = { [weak self] in
            self?.window.makeKeyAndOrderFront(nil)
        }
    }

    /// Brings the window to the front, with DevTools taking the keyboard.
    func show() {
        window.makeKeyAndOrderFront(nil)
        devTools.focus()
    }

    /// ⌘W closes the window (Axo's Close Tab would close the browser's tab instead); other
    /// shortcuts go to Axo's menu.
    func handleUnusedKey(_ event: NSEvent) -> Bool {
        // Only the modifier keys: Caps Lock and the like don't change what ⌘W means.
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            window.performClose(nil)
            return true
        }
        return performMenuKey(event)
    }

    func windowWillClose(_ notification: Notification) {
        if !devToolsEnded {
            devToolsEnded = true
            devTools.close()
        }
        onClosed?(self)
    }
}
