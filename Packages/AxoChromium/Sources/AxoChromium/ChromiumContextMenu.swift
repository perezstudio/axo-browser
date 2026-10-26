import AxoEngineAPI
import AxoWeb
import Foundation

/// A right-click in a Chromium page, for Axo's own menu: the engine's `AXOContextMenu` as AxoWeb's
/// engine-neutral ``PageContextMenu``.
@MainActor
final class ChromiumContextMenu: PageContextMenu {
    private let menu: any AXOContextMenu

    init(_ menu: any AXOContextMenu) {
        self.menu = menu
        extensionItems = menu.extensionItems.map(Self.item)
    }

    let extensionItems: [PageContextMenuItem]

    var linkURL: URL? { menu.linkURL }
    var linkText: String { menu.linkText }
    var sourceURL: URL? { menu.sourceURL }
    var hasImageContents: Bool { menu.hasImageContents }
    var selectionText: String { menu.selectionText }
    var isEditable: Bool { menu.isEditable }
    var misspelledWord: String { menu.misspelledWord }
    var suggestions: [String] { menu.suggestions }
    var location: CGPoint { menu.location }

    var media: PageContextMenuMedia {
        switch menu.media {
        case .none: .none
        case .image: .image
        case .video: .video
        case .audio: .audio
        case .canvas: .canvas
        default: .other
        }
    }

    var edits: PageEdits {
        let edits = menu.edits
        var result: PageEdits = []
        if edits.contains(.undo) { result.insert(.undo) }
        if edits.contains(.redo) { result.insert(.redo) }
        if edits.contains(.cut) { result.insert(.cut) }
        if edits.contains(.copy) { result.insert(.copy) }
        if edits.contains(.paste) { result.insert(.paste) }
        if edits.contains(.delete) { result.insert(.delete) }
        if edits.contains(.selectAll) { result.insert(.selectAll) }
        return result
    }

    func perform(_ edit: PageEdit) {
        let engineEdit: AXOContextMenuEdit = switch edit {
        case .undo: .undo
        case .redo: .redo
        case .cut: .cut
        case .copy: .copy
        case .paste: .paste
        case .pasteAndMatchStyle: .pasteAndMatchStyle
        case .delete: .delete
        case .selectAll: .selectAll
        }
        menu.perform(engineEdit)
    }

    func replaceMisspelling(with word: String) { menu.replaceMisspelling(with: word) }
    func copyImage() { menu.copyImage() }
    func download(_ url: URL) { menu.download(url) }
    func lookUpSelection() { menu.lookUpSelection() }
    func closed(followingLink url: URL?) { menu.closed(followingLink: url) }

    func perform(_ item: PageContextMenuItem) {
        guard let engineItem = item.engineItem as? any AXOContextMenuItem else { return }
        menu.performExtensionItem(engineItem)
    }

    private static func item(_ item: any AXOContextMenuItem) -> PageContextMenuItem {
        let kind: PageContextMenuItem.Kind = switch item.type {
        case .checkbox: .checkbox
        case .radio: .radio
        case .separator: .separator
        case .submenu: .submenu
        default: .command
        }
        return PageContextMenuItem(
            kind: kind, title: item.title, isEnabled: item.isEnabled, isChecked: item.isChecked,
            children: item.children.map(Self.item), engineItem: item
        )
    }
}
