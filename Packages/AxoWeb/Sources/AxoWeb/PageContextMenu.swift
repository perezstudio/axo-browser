import Foundation

/// A right-click in a page, for Axo's own menu: what it hit, extensions' items for it, and the
/// actions the menu can run on the page. Engines that draw their own menu (WebKit) don't send
/// these.
@MainActor
public protocol PageContextMenu: AnyObject {
    /// The link clicked, if any, and its text.
    var linkURL: URL? { get }
    var linkText: String { get }
    /// The media clicked, and its source (an image's URL, say).
    var media: PageContextMenuMedia { get }
    var sourceURL: URL? { get }
    /// Whether an image's pixels are loaded, so it can be copied.
    var hasImageContents: Bool { get }
    /// The selected text, or empty.
    var selectionText: String { get }
    /// Whether the click was in a text field or editable content, and which edits apply.
    var isEditable: Bool { get }
    var edits: PageEdits { get }
    /// A misspelled word clicked, and the spelling checker's suggestions for it.
    var misspelledWord: String { get }
    var suggestions: [String] { get }
    /// Where the click was, in the page view's coordinates with the origin at its top left.
    var location: CGPoint { get }
    /// Extensions' items for this click, grouped by extension.
    var extensionItems: [PageContextMenuItem] { get }

    func perform(_ edit: PageEdit)
    func replaceMisspelling(with word: String)
    /// Copies the clicked image.
    func copyImage()
    /// Downloads a link's target or an image, as the page would.
    func download(_ url: URL)
    /// Shows the selection's definition (Look Up).
    func lookUpSelection()
    /// Runs an extension's item.
    func perform(_ item: PageContextMenuItem)
    /// Tells the page the menu closed, and which link it followed, if any. Call it once.
    func closed(followingLink url: URL?)
}

/// What a right-click hit, when it's media.
public enum PageContextMenuMedia: Sendable {
    case none, image, video, audio, canvas, other
}

/// The editing commands that apply where the right-click was.
public struct PageEdits: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let undo = PageEdits(rawValue: 1 << 0)
    public static let redo = PageEdits(rawValue: 1 << 1)
    public static let cut = PageEdits(rawValue: 1 << 2)
    public static let copy = PageEdits(rawValue: 1 << 3)
    public static let paste = PageEdits(rawValue: 1 << 4)
    public static let delete = PageEdits(rawValue: 1 << 5)
    public static let selectAll = PageEdits(rawValue: 1 << 6)
}

/// An editing command, for ``PageContextMenu/perform(_:)-(PageEdit)``.
public enum PageEdit: Sendable {
    case undo, redo, cut, copy, paste, pasteAndMatchStyle, delete, selectAll
}

/// An extension's context menu item (`chrome.contextMenus`). Pass it back to
/// ``PageContextMenu/perform(_:)-(PageContextMenuItem)`` to run it.
@MainActor
public final class PageContextMenuItem {
    /// What kind of item it is.
    public enum Kind: Sendable {
        case command, checkbox, radio, separator, submenu
    }

    public let kind: Kind
    public let title: String
    public let isEnabled: Bool
    public let isChecked: Bool
    /// A submenu's items.
    public let children: [PageContextMenuItem]
    /// The engine's own item, for running it.
    public let engineItem: AnyObject?

    /// Creates an item.
    public init(kind: Kind, title: String, isEnabled: Bool = true, isChecked: Bool = false, children: [PageContextMenuItem] = [], engineItem: AnyObject? = nil) {
        self.kind = kind
        self.title = title
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.children = children
        self.engineItem = engineItem
    }
}
