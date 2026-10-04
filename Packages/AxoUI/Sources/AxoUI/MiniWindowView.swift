import AppKit
import AxoCore
import AxoWeb
import SwiftUI

/// The AppKit window that shows a mini window. One controller per mini window.
@MainActor
final class MiniWindowController: NSObject, NSWindowDelegate {
    /// The open mini windows, by ID.
    private static var controllers: [MiniWindow.ID: MiniWindowController] = [:]

    private let id: MiniWindow.ID
    private weak var model: BrowserModel?
    let window: NSWindow
    /// Set when the page moved to a tab, so closing the window doesn't discard it.
    private var isDismissing = false

    private init(mini: MiniWindow, model: BrowserModel) {
        id = mini.id
        self.model = model
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.isReleasedWhenClosed = false
        window.title = mini.tab.url.host() ?? mini.tab.url.absoluteString
        window.tabbingMode = .disallowed
        window.setAccessibilityIdentifier("miniWindow")
        window.delegate = self
        window.contentView = NSHostingView(rootView: MiniWindowView(model: model, mini: mini) { [weak window] title in
            window?.title = title
        })
    }

    /// Opens a window for `mini` in front, a little offset from the last one.
    static func show(_ mini: MiniWindow, model: BrowserModel) {
        let controller = MiniWindowController(mini: mini, model: model)
        controllers[mini.id] = controller
        if let last = controllers.values.first(where: { $0 !== controller })?.window {
            controller.window.setFrameTopLeftPoint(controller.window.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        } else {
            controller.window.center()
        }
        controller.window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Closes a mini window whose page moved to a tab, keeping the page.
    static func dismiss(_ id: MiniWindow.ID) {
        guard let controller = controllers[id] else { return }
        controller.isDismissing = true
        controller.window.close()
        // Bring the browser window forward, where the page now is.
        let mainWindow = NSApp.windows.first { window in
            window.isVisible && window.canBecomeMain && !controllers.values.contains { $0.window === window }
        }
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if !isDismissing { model?.closeMiniWindow(id) }
        Self.controllers[id] = nil
    }
}

/// A mini window's content: the page, with a bar to open it in Axo's main window.
struct MiniWindowView: View {
    let model: BrowserModel
    let mini: MiniWindow
    let setTitle: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                Button("Open in Axo") { Task { await model.openMiniWindowInAxo(mini.id) } }
                    .keyboardShortcut("o")
                    .help("Open as a tab in Axo's window (⌘O)")
                    .accessibilityIdentifier("miniOpenInAxoButton")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            WebViewHost(tab: mini.tab, profileID: mini.profileID, pool: model.pool)
                .overlay(alignment: .top) {
                    if let page = model.miniWindowPage(mini.id), page.isLoading {
                        ProgressView(value: page.estimatedProgress)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                            .accessibilityLabel("Loading")
                    }
                }
        }
        .frame(minWidth: 420, minHeight: 300)
        .onChange(of: title, initial: true) { setTitle(title) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("miniWindowContent")
    }

    /// The page's title, or its host while it loads.
    private var title: String {
        let page = model.miniWindowPage(mini.id)
        if let pageTitle = page?.title, !pageTitle.isEmpty { return pageTitle }
        let url = page?.url ?? mini.tab.url
        return url.host() ?? url.absoluteString
    }
}
