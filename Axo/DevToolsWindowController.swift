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
    /// Called once the window has closed, for whoever keeps the controller.
    var onClosed: ((DevToolsWindowController) -> Void)?
    /// Whether DevTools went away first, so closing the window doesn't close it again.
    private var devToolsEnded = false

    init(devTools: ChromiumDevToolsWindow, isTestRun: Bool) {
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
        if let name = Self.frameAutosaveName(isTestRun: isTestRun) {
            window.setFrameAutosaveName(name)
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
    }

    /// Brings the window to the front.
    func show() {
        window.makeKeyAndOrderFront(nil)
    }

    /// ⌘W closes the window (Axo's Close Tab would close the browser's tab instead); other
    /// shortcuts go to Axo's menu.
    func handleUnusedKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            window.performClose(nil)
            return true
        }
        return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
    }

    func windowWillClose(_ notification: Notification) {
        if !devToolsEnded {
            devToolsEnded = true
            devTools.close()
        }
        onClosed?(self)
    }
}
