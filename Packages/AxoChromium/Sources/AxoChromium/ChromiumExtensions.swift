import AppKit
import AxoCore
import AxoEngineAPI
import AxoWeb
import Foundation

/// An installed extension in the Chromium engine.
public struct ChromiumExtension: Equatable, Sendable {
    /// Chrome's extension ID.
    public var id: String
    public var name: String
    public var version: String
    public var isEnabled: Bool
    /// Loaded from a folder in developer mode.
    public var isUnpacked: Bool

    /// Creates the description of an extension.
    public init(id: String, name: String, version: String, isEnabled: Bool, isUnpacked: Bool) {
        self.id = id
        self.name = name
        self.version = version
        self.isEnabled = isEnabled
        self.isUnpacked = isUnpacked
    }
}

/// An extension's toolbar button for one page, in the Chromium engine.
public struct ChromiumToolbarButton {
    /// The extension the button belongs to.
    public var extensionID: String
    /// The button's title, for its tooltip and VoiceOver.
    public var title: String
    /// Badge text, or an empty string.
    public var badge: String
    /// The icon, or `nil` while it loads.
    public var icon: NSImage?
    /// Whether the button can be clicked on this page.
    public var isEnabled: Bool
    /// Whether clicking it opens a popup.
    public var hasPopup: Bool
}

/// A keyboard shortcut an extension declares (`commands` in its manifest), as `NSMenuItem`
/// takes it: an uppercase ``keyEquivalent`` means Shift.
public struct ChromiumExtensionCommand: Equatable {
    /// The extension the shortcut belongs to.
    public var extensionID: String
    /// `_execute_action` (click the extension's button), or a name the extension chose.
    public var name: String
    /// What the shortcut does.
    public var title: String
    /// The key.
    public var keyEquivalent: String
    /// The modifier keys besides Shift for an uppercase key.
    public var modifierFlags: NSEvent.ModifierFlags

    /// Whether this is the shortcut that clicks the extension's toolbar button.
    public var isActionCommand: Bool { name == "_execute_action" }

    /// Creates the description of a shortcut.
    public init(extensionID: String, name: String, title: String, keyEquivalent: String, modifierFlags: NSEvent.ModifierFlags) {
        self.extensionID = extensionID
        self.name = name
        self.title = title
        self.keyEquivalent = keyEquivalent
        self.modifierFlags = modifierFlags
    }
}

/// Something Chrome would ask in its own dialog, for Axo to ask in its own UI.
public struct ChromiumExtensionPrompt: Equatable {
    /// What's being asked.
    public enum Kind: Equatable {
        /// More permissions (`chrome.permissions.request`); ``details`` lists them.
        case permissions
        /// Installing an extension; ``details`` lists what it can do.
        case install
        /// Removing an extension, maybe because another extension asked.
        case uninstall(requestedBy: String?)
        /// Recording the screen, where a screen or a window may be shared.
        case screenCapture
    }

    /// The person's answer.
    public enum Answer: Equatable {
        case cancel, accept, screen, window
    }

    public var kind: Kind
    /// The extension's ID, or empty when a page asked to record the screen.
    public var extensionID: String
    /// The extension's name, or the page that asked to record the screen.
    public var extensionName: String
    /// Chrome's title for the prompt, which Axo may ignore, or empty.
    public var title: String
    /// What the extension can do, one line each.
    public var details: [String]

    /// Creates a prompt.
    public init(kind: Kind, extensionID: String, extensionName: String, title: String = "", details: [String] = []) {
        self.kind = kind
        self.extensionID = extensionID
        self.extensionName = extensionName
        self.title = title
        self.details = details
    }

    @MainActor init(_ prompt: any AXOExtensionPrompt) {
        let kind: Kind = switch prompt.kind {
        case .permissions: .permissions
        case .install: .install
        case .uninstall: .uninstall(requestedBy: prompt.requestingExtensionName)
        case .screenCapture: .screenCapture
        @unknown default: .permissions
        }
        self.init(kind: kind, extensionID: prompt.extensionIdentifier, extensionName: prompt.extensionName, title: prompt.title, details: prompt.details)
    }
}

extension ChromiumExtensionPrompt.Answer {
    var engineAnswer: AXOExtensionPromptAnswer {
        switch self {
        case .cancel: .cancel
        case .accept: .accept
        case .screen: .screen
        case .window: .window
        }
    }
}

/// An extension's side panel, open. Show ``view`` beside the page.
@MainActor
public final class ChromiumExtensionSidePanel {
    private let panel: any AXOExtensionSidePanel

    init(_ panel: any AXOExtensionSidePanel) {
        self.panel = panel
    }

    /// The extension whose panel this is.
    public var extensionID: String { panel.extensionIdentifier }
    /// The extension's name.
    public var title: String { panel.title }
    /// The view that draws the panel.
    public var view: NSView { panel.view }

    /// Called when the panel closes without Axo asking (the extension closed it, or another
    /// extension's panel opened).
    public var onClose: (() -> Void)? {
        get { panel.onClose }
        set { panel.onClose = newValue }
    }

    /// Closes the panel.
    public func close() {
        panel.close()
    }
}

/// An extension's popup, open. Show ``view`` in a popover sized to ``preferredSize``.
@MainActor
public final class ChromiumExtensionPopup {
    private let popup: any AXOExtensionPopup

    init(_ popup: any AXOExtensionPopup) {
        self.popup = popup
    }

    /// The extension whose popup this is.
    public var extensionID: String { popup.extensionIdentifier }
    /// The view that draws the popup.
    public var view: NSView { popup.view }
    /// The popup page's title, for VoiceOver.
    public var title: String { popup.title }
    /// The size the popup's content wants.
    public var preferredSize: NSSize { popup.preferredSize }

    /// Called when ``preferredSize`` changes.
    public var onResize: ((NSSize) -> Void)? {
        get { popup.onResize }
        set { popup.onResize = newValue }
    }

    /// Called when the popup closes itself (`window.close()`).
    public var onClose: (() -> Void)? {
        get { popup.onClose }
        set { popup.onClose = newValue }
    }

    /// Closes the popup.
    public func close() {
        popup.close()
    }
}

/// Extensions in the Chromium engine: what Axo's Extensions window lists, its toolbar buttons,
/// and their popups. Everything is empty or does nothing until the engine is ready.
extension ChromiumEngine {
    /// A profile's installed extensions.
    public func extensions(profileID: Profile.ID) -> [ChromiumExtension] {
        guard let profile = readyProfile(profileID) else { return [] }
        return profile.extensions.map {
            ChromiumExtension(id: $0.identifier, name: $0.name, version: $0.version, isEnabled: $0.isEnabled, isUnpacked: $0.isUnpacked)
        }
    }

    /// Turns an extension on or off.
    public func setExtension(_ extensionID: String, enabled: Bool, profileID: Profile.ID) {
        readyProfile(profileID)?.setExtension(extensionID, enabled: enabled)
    }

    /// Uninstalls an extension and deletes its data.
    public func uninstallExtension(_ extensionID: String, profileID: Profile.ID) {
        readyProfile(profileID)?.uninstallExtension(extensionID)
    }

    /// Loads an unpacked extension folder into a profile, in developer mode, and returns its ID.
    public func loadUnpackedExtension(at url: URL, profileID: Profile.ID) async throws -> String {
        guard let profile = readyProfile(profileID) else { throw ChromiumEngineError.notReady }
        return try await profile.loadUnpackedExtension(at: url)
    }

    /// Installs an extension package (`.crx`) into a profile and returns its ID. Ask the person
    /// first.
    public func installPackage(at url: URL, profileID: Profile.ID) async throws -> String {
        guard let profile = readyProfile(profileID) else { throw ChromiumEngineError.notReady }
        return try await profile.installPackage(at: url)
    }

    /// The keyboard shortcuts, with keys, of a profile's enabled extensions.
    public func extensionCommands(profileID: Profile.ID) -> [ChromiumExtensionCommand] {
        guard let profile = readyProfile(profileID) else { return [] }
        return profile.extensionCommands.map {
            ChromiumExtensionCommand(
                extensionID: $0.extensionIdentifier, name: $0.name, title: $0.title,
                keyEquivalent: $0.keyEquivalent, modifierFlags: $0.modifierFlags
            )
        }
    }

    /// Runs an extension's command with `page` as the selected tab, as its shortcut would, and
    /// returns the popup it opened (for `_execute_action`), or `nil`.
    public func performExtensionCommand(_ name: String, extensionID: String, profileID: Profile.ID, page: (any EnginePage)?) async -> ChromiumExtensionPopup? {
        guard let profile = readyProfile(profileID), let enginePage = (page as? ChromiumPage)?.page else { return nil }
        let popup = await profile.performExtensionCommand(name, extension: extensionID, on: enginePage, window: engineWindow(for: profileID))
        return popup.map(ChromiumExtensionPopup.init)
    }

    /// The toolbar buttons of a profile's enabled extensions, for `page` (the selected tab's).
    public func toolbarButtons(profileID: Profile.ID, page: (any EnginePage)?) -> [ChromiumToolbarButton] {
        guard let profile = readyProfile(profileID), let enginePage = (page as? ChromiumPage)?.page else { return [] }
        return profile.extensionActions(for: enginePage).map {
            ChromiumToolbarButton(
                extensionID: $0.extensionIdentifier, title: $0.title, badge: $0.badgeText,
                icon: $0.icon, isEnabled: $0.isEnabled, hasPopup: $0.hasPopup
            )
        }
    }

    /// Clicks an extension's toolbar button with `page` as the selected tab, and returns its
    /// popup, open and loading, or `nil` when the extension handled the click itself.
    public func performExtensionAction(_ extensionID: String, profileID: Profile.ID, page: (any EnginePage)?) async -> ChromiumExtensionPopup? {
        guard let profile = readyProfile(profileID), let enginePage = (page as? ChromiumPage)?.page else { return nil }
        let popup = await profile.performExtensionAction(extensionID, on: enginePage, window: engineWindow(for: profileID))
        return popup.map(ChromiumExtensionPopup.init)
    }
}

/// Why the Chromium engine couldn't do something.
public enum ChromiumEngineError: Error, LocalizedError {
    /// The engine hasn't finished starting.
    case notReady

    public var errorDescription: String? {
        switch self {
        case .notReady: "The Chromium engine is still starting. Try again in a moment."
        }
    }
}
