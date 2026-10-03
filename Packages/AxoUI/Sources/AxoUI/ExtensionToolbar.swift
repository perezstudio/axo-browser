import AppKit
import AxoCore
import SwiftUI

/// A browser event extensions hear about (`chrome.tabs.on…`).
public enum TabEvent: Equatable, Sendable {
    case opened(AxoCore.Tab.ID)
    case closed(AxoCore.Tab.ID)
    case activated(AxoCore.Tab.ID?, previous: AxoCore.Tab.ID?)
    case changed(AxoCore.Tab.ID)
    case spaceChanged
}

/// One extension's toolbar button.
public struct ExtensionToolbarItem: Identifiable, Equatable {
    /// The extension ID.
    public var id: String
    /// The button's title, used for its help tag and VoiceOver.
    public var label: String
    /// The icon.
    public var icon: NSImage?
    /// Badge text, or an empty string.
    public var badge: String
    /// Whether the button can be clicked.
    public var isEnabled: Bool

    /// Creates an item.
    public init(id: String, label: String, icon: NSImage?, badge: String, isEnabled: Bool) {
        self.id = id
        self.label = label
        self.icon = icon
        self.badge = badge
        self.isEnabled = isEnabled
    }
}

/// Supplies extension toolbar buttons and runs them. AxoExtensions provides the real
/// implementation; the app connects them.
@MainActor
public protocol ExtensionToolbarProviding: AnyObject {
    /// The buttons for a profile's extensions, for the given tab. Reading this from a view must
    /// make the view update when buttons change (an `@Observable` implementation does).
    func toolbarItems(profileID: Profile.ID, tabID: AxoCore.Tab.ID?) -> [ExtensionToolbarItem]
    /// Clicks a button: the extension shows its popup or handles the click.
    func performAction(extensionID: String, profileID: Profile.ID, tabID: AxoCore.Tab.ID?)
}

/// The extension buttons in the toolbar.
struct ExtensionToolbarButtons: View {
    let model: BrowserModel

    var body: some View {
        if let provider = model.extensionToolbar, let profileID = model.space?.profileID {
            let items = provider.toolbarItems(profileID: profileID, tabID: model.selectedTabID)
            ForEach(items) { item in
                Button {
                    provider.performAction(extensionID: item.id, profileID: profileID, tabID: model.selectedTabID)
                } label: {
                    ExtensionIcon(item: item)
                }
                .disabled(!item.isEnabled)
                .help(item.label)
                .accessibilityLabel(item.badge.isEmpty ? item.label : "\(item.label), \(item.badge)")
                .accessibilityIdentifier("extensionButton")
                .background(PopoverAnchor { model.extensionAnchors[item.id] = $0 })
            }
        }
    }
}

/// An extension's icon, with its badge in the corner.
private struct ExtensionIcon: View {
    let item: ExtensionToolbarItem

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let icon = item.icon {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: "puzzlepiece.extension")
            }
            if !item.badge.isEmpty {
                Text(item.badge)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 2)
                    .background(.red, in: .capsule)
                    .offset(x: 5, y: 4)
            }
        }
        .frame(width: 20, height: 20)
    }
}

/// Reports the AppKit view behind a SwiftUI view, so an `NSPopover` can be shown from it.
struct PopoverAnchor: NSViewRepresentable {
    let onView: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        onView(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        onView(view)
    }
}
