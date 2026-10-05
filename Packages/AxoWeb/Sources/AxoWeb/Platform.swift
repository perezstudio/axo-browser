#if os(macOS)
import AppKit

/// The platform's image type: `NSImage` on the Mac, `UIImage` on iPhone and iPad.
public typealias PlatformImage = NSImage
#else
import UIKit

/// The platform's image type: `NSImage` on the Mac, `UIImage` on iPhone and iPad.
public typealias PlatformImage = UIImage
#endif

/// The modifier keys held while a link was clicked, the same on every platform.
public struct LinkModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let command = LinkModifiers(rawValue: 1 << 0)
    public static let shift = LinkModifiers(rawValue: 1 << 1)
    public static let option = LinkModifiers(rawValue: 1 << 2)
    public static let control = LinkModifiers(rawValue: 1 << 3)

    #if os(macOS)
    /// The modifiers in AppKit's flags.
    public init(_ flags: NSEvent.ModifierFlags) {
        var modifiers: LinkModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        self = modifiers
    }
    #else
    /// The modifiers in UIKit's flags (from a hardware keyboard).
    public init(_ flags: UIKeyModifierFlags) {
        var modifiers: LinkModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.alternate) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        self = modifiers
    }
    #endif
}
