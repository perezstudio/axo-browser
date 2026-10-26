#if os(macOS)
import AppKit
#endif
import AxoCore
import AxoWeb
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
    public var icon: PlatformImage?
    /// Badge text, or an empty string.
    public var badge: String
    /// Whether the button can be clicked.
    public var isEnabled: Bool

    /// Creates an item.
    public init(id: String, label: String, icon: PlatformImage?, badge: String, isEnabled: Bool) {
        self.id = id
        self.label = label
        self.icon = icon
        self.badge = badge
        self.isEnabled = isEnabled
    }
}

/// An extension's keyboard shortcut (`chrome.commands`), shown as a menu item with its keys.
public struct ExtensionShortcut: Identifiable, Equatable {
    /// The extension and command, together.
    public var id: String { "\(extensionID)/\(name)" }
    /// The extension the shortcut belongs to.
    public var extensionID: String
    /// The command's name, which the provider runs.
    public var name: String
    /// The menu item's title.
    public var title: String
    /// The key, lowercase for letters (Shift is in ``modifiers``).
    public var key: Character
    /// The modifier keys.
    public var modifiers: EventModifiers

    /// Creates a shortcut.
    public init(extensionID: String, name: String, title: String, key: Character, modifiers: EventModifiers) {
        self.extensionID = extensionID
        self.name = name
        self.title = title
        self.key = key
        self.modifiers = modifiers
    }
}

#if os(macOS)
extension ExtensionShortcut {
    /// The menu holding extensions' shortcuts, whose items don't count as Axo's own.
    static let menuTitle = "Extension Shortcuts"

    /// Whether one of Axo's own menu items in `menu` (the main menu) already uses these keys.
    /// Axo's shortcut wins: an extension's shortcut that clashes stays in the menu without them.
    func clashes(with menu: NSMenu?) -> Bool {
        guard let menu else { return false }
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        return Self.usesKeys(String(key).lowercased(), flags, in: menu)
    }

    private static func usesKeys(_ key: String, _ flags: NSEvent.ModifierFlags, in menu: NSMenu) -> Bool {
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        for item in menu.items {
            if let submenu = item.submenu {
                if item.title != menuTitle, usesKeys(key, flags, in: submenu) { return true }
                continue
            }
            guard !item.keyEquivalent.isEmpty else { continue }
            var itemFlags = item.keyEquivalentModifierMask.intersection(relevant)
            // AppKit writes Shift as an uppercase letter.
            if item.keyEquivalent != item.keyEquivalent.lowercased() { itemFlags.insert(.shift) }
            if item.keyEquivalent.lowercased() == key, itemFlags == flags { return true }
        }
        return false
    }
}
#endif

/// Supplies extension toolbar buttons and runs them. AxoExtensions provides the real
/// implementation; the app connects them.
@MainActor
public protocol ExtensionToolbarProviding: AnyObject {
    /// The buttons for a profile's extensions, for the given tab. Reading this from a view must
    /// make the view update when buttons change (an `@Observable` implementation does).
    func toolbarItems(profileID: Profile.ID, tabID: AxoCore.Tab.ID?) -> [ExtensionToolbarItem]
    /// Clicks a button: the extension shows its popup or handles the click.
    func performAction(extensionID: String, profileID: Profile.ID, tabID: AxoCore.Tab.ID?)
    /// The keyboard shortcuts of a profile's extensions. Reading this from a view must make the
    /// view update when they change.
    func shortcuts(profileID: Profile.ID) -> [ExtensionShortcut]
    /// Runs a shortcut, as pressing its keys does, with the given tab as the active one.
    func performShortcut(_ shortcut: ExtensionShortcut, profileID: Profile.ID, tabID: AxoCore.Tab.ID?)
}

extension ExtensionToolbarProviding {
    /// No shortcuts, for providers whose engine doesn't have them.
    public func shortcuts(profileID: Profile.ID) -> [ExtensionShortcut] { [] }
    /// Does nothing, for providers whose engine doesn't have shortcuts.
    public func performShortcut(_ shortcut: ExtensionShortcut, profileID: Profile.ID, tabID: AxoCore.Tab.ID?) {}
}
// Mac only for now; iPhone and iPad have their own chrome.
#if os(macOS)

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
                Image(platformImage: icon).resizable().frame(width: 16, height: 16)
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
#endif
