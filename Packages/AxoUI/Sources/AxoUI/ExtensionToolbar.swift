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
    /// Whether clicking it opens a popup the button declares. Extensions can also open one
    /// themselves from the click (`chrome.action.openPopup`), so this isn't the only way to have one.
    public var hasPopup: Bool
    /// Whether it's pinned to the toolbar, with a button of its own; every extension is also in
    /// the Extensions menu (the puzzle piece).
    public var isPinned: Bool

    /// Creates an item.
    public init(id: String, label: String, icon: PlatformImage?, badge: String, isEnabled: Bool, hasPopup: Bool = false, isPinned: Bool = true) {
        self.isPinned = isPinned
        self.id = id
        self.label = label
        self.icon = icon
        self.badge = badge
        self.isEnabled = isEnabled
        self.hasPopup = hasPopup
    }
}

extension ExtensionToolbarItem {
    /// `items` as the toolbar shows them: the pinned ones (`pinnedIDs`, in that order) first,
    /// marked pinned, then the rest by name, marked unpinned.
    public static func arranged(_ items: [ExtensionToolbarItem], pinnedIDs: [String]) -> [ExtensionToolbarItem] {
        let order = Dictionary(pinnedIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var pinned: [ExtensionToolbarItem] = []
        var others: [ExtensionToolbarItem] = []
        for var item in items {
            item.isPinned = order[item.id] != nil
            if item.isPinned { pinned.append(item) } else { others.append(item) }
        }
        pinned.sort { order[$0.id, default: 0] < order[$1.id, default: 0] }
        others.sort { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        return pinned + others
    }
}

/// Pins kept in memory for an engine with no pinned state of its own (WebKit, which runs
/// extensions only in test runs): every extension starts pinned, as new installs do on
/// Chromium, and pins last until Axo quits.
@Observable
public final class ExtensionPins {
    /// Unpinned extensions, by profile.
    private var unpinned: [Profile.ID: Set<String>] = [:]
    /// The order of pinned extensions that were pinned again or moved, by profile; others
    /// follow in the order they're given.
    private var order: [Profile.ID: [String]] = [:]

    /// Creates empty pins: everything pinned.
    public init() {}

    /// The pinned IDs among `ids` (the installed extensions, in their own order), in toolbar order.
    public func pinnedIDs(among ids: [String], profileID: Profile.ID) -> [String] {
        let hidden = unpinned[profileID] ?? []
        let pinned = ids.filter { !hidden.contains($0) }
        let known = (order[profileID] ?? []).filter { pinned.contains($0) }
        return known + pinned.filter { !known.contains($0) }
    }

    /// Whether an extension is pinned.
    public func isPinned(_ id: String, profileID: Profile.ID) -> Bool {
        !(unpinned[profileID]?.contains(id) ?? false)
    }

    /// Pins an extension, at the end of `ids`'s pinned ones, or unpins it.
    public func setPinned(_ pinned: Bool, extensionID: String, among ids: [String], profileID: Profile.ID) {
        var shown = pinnedIDs(among: ids, profileID: profileID).filter { $0 != extensionID }
        if pinned {
            unpinned[profileID, default: []].remove(extensionID)
            shown.append(extensionID)
        } else {
            unpinned[profileID, default: []].insert(extensionID)
        }
        order[profileID] = shown
    }

    /// Forgets a removed extension, so installing it again starts pinned, as a new install does.
    public func forget(_ extensionID: String, profileID: Profile.ID) {
        unpinned[profileID]?.remove(extensionID)
        order[profileID]?.removeAll { $0 == extensionID }
    }

    /// Moves a pinned extension to `index` among the pinned ones.
    public func move(_ extensionID: String, to index: Int, among ids: [String], profileID: Profile.ID) {
        var shown = pinnedIDs(among: ids, profileID: profileID)
        guard let from = shown.firstIndex(of: extensionID) else { return }
        shown.remove(at: from)
        shown.insert(extensionID, at: min(max(index, 0), shown.count))
        order[profileID] = shown
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

extension ExtensionShortcut {
    /// Its keys as menus write them, such as "⇧⌘U".
    public var keysDescription: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + String(key).uppercased()
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
    /// The buttons for a profile's enabled extensions, for the given tab: the pinned ones first,
    /// in their order, then the rest (``ExtensionToolbarItem/arranged(_:pinnedIDs:)``). Reading
    /// this from a view must make the view update when buttons change (an `@Observable`
    /// implementation does).
    func toolbarItems(profileID: Profile.ID, tabID: AxoCore.Tab.ID?) -> [ExtensionToolbarItem]
    /// Pins an extension to the toolbar, at the end of the pinned ones, or unpins it.
    func setPinned(_ pinned: Bool, extensionID: String, profileID: Profile.ID)
    /// Moves a pinned extension to `index` among the pinned buttons.
    func movePinned(extensionID: String, to index: Int, profileID: Profile.ID)
    /// Clicks a button: the extension shows its popup or handles the click.
    func performAction(extensionID: String, profileID: Profile.ID, tabID: AxoCore.Tab.ID?)
    /// The keyboard shortcuts of a profile's extensions. Reading this from a view must make the
    /// view update when they change.
    func shortcuts(profileID: Profile.ID) -> [ExtensionShortcut]
    /// Runs a shortcut, as pressing its keys does, with the given tab as the active one.
    func performShortcut(_ shortcut: ExtensionShortcut, profileID: Profile.ID, tabID: AxoCore.Tab.ID?)
    /// Whether ``inspectPopup(extensionID:profileID:tabID:)`` works, for the buttons' menus.
    var canInspectPopups: Bool { get }
    /// Clicks a button and inspects the popup that opens, its own or one the extension opens
    /// itself, keeping the popup open while it's inspected.
    func inspectPopup(extensionID: String, profileID: Profile.ID, tabID: AxoCore.Tab.ID?)
}

extension ExtensionToolbarProviding {
    /// No popup inspector, for providers whose engine can't inspect popups.
    public var canInspectPopups: Bool { false }
    /// Does nothing, for providers whose engine can't inspect popups.
    public func inspectPopup(extensionID: String, profileID: Profile.ID, tabID: AxoCore.Tab.ID?) {}
    /// No shortcuts, for providers whose engine doesn't have them.
    public func shortcuts(profileID: Profile.ID) -> [ExtensionShortcut] { [] }
    /// Does nothing, for providers whose engine doesn't have shortcuts.
    public func performShortcut(_ shortcut: ExtensionShortcut, profileID: Profile.ID, tabID: AxoCore.Tab.ID?) {}
}
// Mac only for now; iPhone and iPad have their own chrome.
#if os(macOS)

/// The pinned extensions' buttons in the toolbar, or at the right end of the sidebar's address
/// bar, where only the first few fit (`limit`), followed by the Extensions menu (a puzzle piece)
/// that lists every extension, with a pin control for each (#131).
struct ExtensionToolbarButtons: View {
    let model: BrowserModel
    /// The most buttons shown, the Extensions menu included; `nil` shows every pinned one (the
    /// toolbar has its own overflow menu).
    var limit: Int?

    /// The buttons the sidebar's address bar has room for, the menu included.
    static let addressBarLimit = 3

    /// The pinned extensions with buttons of their own, for `limit`: the first pinned ones,
    /// leaving the last place to the Extensions menu.
    static func buttons(_ items: [ExtensionToolbarItem], limit: Int?) -> [ExtensionToolbarItem] {
        let pinned = items.filter(\.isPinned)
        guard let limit else { return pinned }
        return Array(pinned.prefix(max(limit - 1, 0)))
    }

    /// How many buttons show for `items`, the Extensions menu counted as one.
    static func shownCount(of items: [ExtensionToolbarItem], limit: Int?) -> Int {
        items.isEmpty ? 0 : buttons(items, limit: limit).count + 1
    }

    var body: some View {
        if let provider = model.extensionToolbar, let profileID = model.space?.profileID {
            let all = provider.toolbarItems(profileID: profileID, tabID: model.selectedTabID)
            let shown = Self.buttons(all, limit: limit)
            let pinned = all.filter(\.isPinned)
            ForEach(shown) { item in
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
                .contextMenu {
                    ExtensionButtonActions(model: model, provider: provider, item: item, pinned: pinned, profileID: profileID)
                }
                .accessibilityActions {
                    ExtensionButtonActions(model: model, provider: provider, item: item, pinned: pinned, profileID: profileID)
                }
            }
            if !all.isEmpty {
                ExtensionsMenu(model: model, provider: provider, items: all, profileID: profileID)
                    // Popups of extensions without a button of their own open from the menu's button.
                    .background(PopoverAnchor { view in
                        let shownIDs = Set(shown.map(\.id))
                        for item in all where !shownIDs.contains(item.id) { model.extensionAnchors[item.id] = view }
                    })
            }
        }
    }
}

/// What an extension's toolbar button offers in its context menu and to VoiceOver: Unpin, moving
/// it among the pinned buttons, Manage Extension, Remove, and Inspect Popup.
private struct ExtensionButtonActions: View {
    let model: BrowserModel
    let provider: any ExtensionToolbarProviding
    let item: ExtensionToolbarItem
    /// Every pinned extension, in order, including those past the limit.
    let pinned: [ExtensionToolbarItem]
    let profileID: Profile.ID

    var body: some View {
        if item.isEnabled && provider.canInspectPopups {
            Button("Inspect Popup") {
                provider.inspectPopup(extensionID: item.id, profileID: profileID, tabID: model.selectedTabID)
            }
        }
        Button("Unpin") {
            model.setExtensionPinned(false, extensionID: item.id, name: item.label, profileID: profileID)
        }
        if let index = pinned.firstIndex(where: { $0.id == item.id }) {
            if index > 0 {
                Button("Move Left") {
                    model.moveExtensionButton(item.id, name: item.label, to: index - 1, profileID: profileID)
                }
            }
            if index < pinned.count - 1 {
                Button("Move Right") {
                    model.moveExtensionButton(item.id, name: item.label, to: index + 1, profileID: profileID)
                }
            }
        }
        Divider()
        Button("Manage Extension…") { model.showExtensions(profileID: profileID, selecting: item.id) }
        Button("Remove…", role: .destructive) {
            model.askToRemoveExtension(item.id, name: item.label, profileID: profileID)
        }
    }
}

/// The Extensions menu (a puzzle piece, as in Chrome and Arc): every enabled extension, which
/// runs its action or opens its popup, a pin control for each, and Manage Extensions.
private struct ExtensionsMenu: View {
    let model: BrowserModel
    let provider: any ExtensionToolbarProviding
    let items: [ExtensionToolbarItem]
    let profileID: Profile.ID

    var body: some View {
        Menu {
            Section {
                ForEach(items) { item in
                    Button(item.badge.isEmpty ? item.label : "\(item.label) (\(item.badge))") {
                        provider.performAction(extensionID: item.id, profileID: profileID, tabID: model.selectedTabID)
                    }
                    .disabled(!item.isEnabled)
                }
            }
            Section("Pinned to the Toolbar") {
                ForEach(items) { item in
                    // Named for what it does: menus read an item's title, not an accessibility label.
                    Toggle("Pin \(item.label)", isOn: Binding(
                        get: { item.isPinned },
                        set: { model.setExtensionPinned($0, extensionID: item.id, name: item.label, profileID: profileID) }
                    ))
                }
            }
            Section {
                Button("Manage Extensions…") { model.showExtensions(profileID: profileID) }
            }
        } label: {
            Label("Extensions", systemImage: "puzzlepiece.extension")
                .labelStyle(.iconOnly)
        }
        // As the tab bar's folder menus: a button VoiceOver can press, named for itself.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Extensions")
        .accessibilityLabel("Extensions")
        .accessibilityIdentifier("extensionsMenuButton")
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
