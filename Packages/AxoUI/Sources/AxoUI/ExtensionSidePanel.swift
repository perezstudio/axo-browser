import AxoWeb
import SwiftUI

/// An extension's side panel (`chrome.sidePanel`), shown beside the page.
public struct ExtensionSidePanel: Identifiable {
    /// The extension's ID.
    public var id: String
    /// The extension's name, for the panel's header.
    public var title: String
    /// The view that draws the panel's page.
    public var view: PlatformView
    /// Closes the panel in the engine.
    public var close: @MainActor () -> Void

    /// Creates a panel.
    public init(id: String, title: String, view: PlatformView, close: @escaping @MainActor () -> Void) {
        self.id = id
        self.title = title
        self.view = view
        self.close = close
    }
}

extension BrowserModel {
    /// Shows an extension's side panel, replacing any other.
    public func showExtensionSidePanel(_ panel: ExtensionSidePanel) {
        extensionSidePanel = panel
        announce("\(panel.title) side panel opened")
    }

    /// Closes the side panel, as its close button does.
    public func closeExtensionSidePanel() {
        guard let panel = extensionSidePanel else { return }
        extensionSidePanel = nil
        panel.close()
    }

    /// Forgets a side panel the extension (or the engine) closed itself.
    public func extensionSidePanelDidClose(_ id: String) {
        guard extensionSidePanel?.id == id else { return }
        extensionSidePanel = nil
    }
}

#if os(macOS)
/// The side panel column: the extension's name, a close button, and its page.
struct ExtensionSidePanelView: View {
    let model: BrowserModel
    let panel: ExtensionSidePanel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(panel.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button {
                    model.closeExtensionSidePanel()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close Side Panel")
                .accessibilityLabel("Close Side Panel")
                .accessibilityIdentifier("closeExtensionSidePanel")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            HostedView(view: panel.view)
        }
        .frame(minWidth: 280, idealWidth: 360, maxWidth: 520)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("extensionSidePanel")
    }
}

/// Shows an engine's view that SwiftUI doesn't own, filling the space it's given.
private struct HostedView: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        mount(in: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if view.superview !== container { mount(in: container) }
    }

    private func mount(in container: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        view.frame = container.bounds
        // An autoresizing mask, like the page views (CLAUDE.md: never constraints).
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
    }
}
#endif
