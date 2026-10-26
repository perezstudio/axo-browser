import AppKit
import AxoChromium
import AxoCore
import AxoExtensions
import AxoUI
import AxoWeb
import Foundation
import Observation
import SwiftUI

/// Connects Axo's toolbar and Extensions window to extensions in the Chromium engine (Phase 2 of
/// `docs/chromium-engine.md`), as ``ExtensionBridge`` does for WebKit's.
///
/// Packages (`.crx`) install through Chrome's installer after Axo's prompt; unpacked folders
/// load in developer mode. Not yet with Chromium: site access settings and inspecting
/// background pages.
@Observable
final class ChromiumExtensionBridge: ExtensionToolbarProviding, ExtensionManaging {
    @ObservationIgnored private weak var model: BrowserModel?
    @ObservationIgnored private let engine: ChromiumEngine
    /// Bumped when extensions or their buttons change, so views reading the toolbar update.
    private var revision = 0
    /// Shows an alert and calls back with the index of the button chosen. Tests replace it.
    @ObservationIgnored var presentAlert: @MainActor (PromptAlert, @escaping (Int) -> Void) -> Void = ChromiumExtensionBridge.showAlert
    /// The open popup and its popover's delegate, by extension.
    @ObservationIgnored private(set) var popups: [String: (popup: ChromiumExtensionPopup, closer: PopoverCloser)] = [:]

    init(model: BrowserModel, engine: ChromiumEngine) {
        self.model = model
        self.engine = engine
        model.extensionToolbar = self
        model.extensionManagement = self
        engine.onExtensionsChange = { [weak self] _ in self?.revision += 1 }
        // Chrome's prompts (permissions, uninstalls, what to share) are Axo's alerts.
        engine.onExtensionPrompt = { [weak self] prompt, _, answer in
            guard let self else {
                answer(.cancel)
                return
            }
            let alert = Self.alert(for: prompt)
            self.presentAlert(alert) { answer(alert.answers.indices.contains($0) ? alert.answers[$0] : .cancel) }
        }
        // Extensions' side panels show beside the page.
        engine.onExtensionSidePanelOpen = { [weak model] panel, _ in
            guard let model else {
                panel.close()
                return
            }
            panel.onClose = { [weak model] in model?.extensionSidePanelDidClose(panel.extensionID) }
            model.showExtensionSidePanel(ExtensionSidePanel(id: panel.extensionID, title: panel.title, view: panel.view) { panel.close() })
        }
        // Extensions that handle their own clicks (1Password) open their popup themselves.
        engine.onExtensionPopupRequest = { [weak self] popup, _ in self?.present(popup) }
        // Buttons appear once the engine is ready.
        let previous = engine.onStateChange
        engine.onStateChange = { [weak self] state in
            previous?(state)
            self?.revision += 1
        }
    }

    // MARK: ExtensionToolbarProviding

    func toolbarItems(profileID: Profile.ID, tabID: AxoCore.Tab.ID?) -> [ExtensionToolbarItem] {
        _ = revision
        return engine.toolbarButtons(profileID: profileID, page: page(for: tabID)).map {
            ExtensionToolbarItem(id: $0.extensionID, label: $0.title, icon: $0.icon, badge: $0.badge, isEnabled: $0.isEnabled)
        }
    }

    func performAction(extensionID: String, profileID: Profile.ID, tabID: AxoCore.Tab.ID?) {
        let page = page(for: tabID)
        Task {
            guard let popup = await engine.performExtensionAction(extensionID, profileID: profileID, page: page) else { return }
            present(popup)
        }
    }

    func shortcuts(profileID: Profile.ID) -> [ExtensionShortcut] {
        _ = revision
        let names = Dictionary(engine.extensions(profileID: profileID).map { ($0.id, $0.name) }) { first, _ in first }
        return engine.extensionCommands(profileID: profileID).compactMap { command in
            guard let shortcut = Self.shortcut(for: command) else { return nil }
            var result = shortcut
            // Named commands say what they do; say which extension they belong to as well.
            if !command.isActionCommand, let name = names[command.extensionID] {
                result.title = "\(name): \(command.title)"
            }
            return result
        }
    }

    func performShortcut(_ shortcut: ExtensionShortcut, profileID: Profile.ID, tabID: AxoCore.Tab.ID?) {
        let page = page(for: tabID)
        Task {
            guard let popup = await engine.performExtensionCommand(shortcut.name, extensionID: shortcut.extensionID, profileID: profileID, page: page) else { return }
            present(popup)
        }
    }

    /// A menu item's shortcut for an extension's command. `NSMenuItem` key equivalents mean Shift
    /// with an uppercase letter; SwiftUI wants the lowercase letter and Shift.
    static func shortcut(for command: ChromiumExtensionCommand) -> ExtensionShortcut? {
        guard command.keyEquivalent.count == 1, let key = command.keyEquivalent.first else { return nil }
        var modifiers: EventModifiers = []
        if command.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if command.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if command.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if command.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        var lowered = key
        if key.isUppercase, let lower = key.lowercased().first {
            lowered = lower
            modifiers.insert(.shift)
        }
        return ExtensionShortcut(extensionID: command.extensionID, name: command.name, title: command.title, key: lowered, modifiers: modifiers)
    }

    private func page(for tabID: AxoCore.Tab.ID?) -> (any EnginePage)? {
        tabID.flatMap { model?.pool.livePage(for: $0) }
    }

    /// Shows a popup under its toolbar button in a popover that follows the popup's size.
    private func present(_ popup: ChromiumExtensionPopup) {
        let extensionID = popup.extensionID
        popups.removeValue(forKey: extensionID)?.popup.close()
        let controller = NSViewController()
        controller.view = popup.view
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.contentSize = popup.preferredSize
        popup.onResize = { [weak popover] size in popover?.contentSize = size }
        popup.onClose = { [weak popover] in popover?.close() }
        let closer = PopoverCloser { [weak self] in
            self?.popups.removeValue(forKey: extensionID)?.popup.close()
        }
        popover.delegate = closer
        popups[extensionID] = (popup, closer)
        model?.presentExtensionPopup(popover, extensionID: extensionID)
    }

    // MARK: ExtensionManaging

    func prepareInstall(from url: URL, profileID: Profile.ID) async throws -> ExtensionInstallPrompt {
        let preview = try InstallPreview(url: url, profileID: profileID)
        // The file's path is the install's ID until Chrome assigns one.
        return ExtensionInstallPrompt(
            id: url.path, name: preview.name, version: preview.version, lines: preview.lines, isUnpacked: preview.isUnpacked
        )
    }

    func confirmInstall(_ extensionID: String, profileID: Profile.ID) async throws {
        let url = URL(fileURLWithPath: extensionID)
        if Self.isFolder(url) {
            _ = try await engine.loadUnpackedExtension(at: url, profileID: profileID)
        } else {
            _ = try await engine.installPackage(at: url, profileID: profileID)
        }
    }

    // MARK: Prompts

    /// An alert for one of Chrome's prompts: its text, and buttons with the answer each gives.
    struct PromptAlert: Equatable {
        var title: String
        var message: String
        var buttons: [String]
        var answers: [ChromiumExtensionPrompt.Answer]
        /// Whether the first button deletes something.
        var isDestructive = false
    }

    /// The alert for a prompt, in Axo's words.
    static func alert(for prompt: ChromiumExtensionPrompt) -> PromptAlert {
        let name = prompt.extensionName
        let list = prompt.details.map { "• \($0)" }.joined(separator: "\n")
        switch prompt.kind {
        case .permissions:
            return PromptAlert(
                title: "“\(name)” wants more access", message: list.isEmpty ? "" : "If you allow it, it can:\n\(list)",
                buttons: ["Allow", "Don’t Allow"], answers: [.accept, .cancel]
            )
        case .install:
            return PromptAlert(
                title: "Add “\(name)”?", message: list.isEmpty ? "" : "It can:\n\(list)",
                buttons: ["Add Extension", "Cancel"], answers: [.accept, .cancel]
            )
        case .uninstall(let requester):
            let reason = requester.map { "“\($0)” asked to remove it. " } ?? ""
            return PromptAlert(
                title: "Remove “\(name)”?", message: "\(reason)Its data in Axo is deleted too.",
                buttons: ["Remove", "Cancel"], answers: [.accept, .cancel], isDestructive: true
            )
        case .screenCapture:
            return PromptAlert(
                title: "Share your screen with “\(name)”?",
                message: "Choose whether to share a whole screen or one window. macOS asks which one next.",
                buttons: ["Entire Screen", "A Window", "Cancel"], answers: [.screen, .window, .cancel]
            )
        }
    }

    /// Shows an alert as a sheet on Axo's window, or on its own when there's no window.
    static func showAlert(_ prompt: PromptAlert, answer: @escaping (Int) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        for button in prompt.buttons { alert.addButton(withTitle: button) }
        alert.buttons.first?.hasDestructiveAction = prompt.isDestructive
        // NSAlert numbers its buttons from .alertFirstButtonReturn.
        let index = { (response: NSApplication.ModalResponse) in response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue }
        if let window = NSApp.mainWindow ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window) { answer(index($0)) }
        } else {
            answer(index(alert.runModal()))
        }
    }

    static func isFolder(_ url: URL) -> Bool {
        url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    func uninstall(_ extensionID: String, profileID: Profile.ID) async throws {
        engine.uninstallExtension(extensionID, profileID: profileID)
    }

    func installedExtensions(profileID: Profile.ID) async -> [ExtensionSummary] {
        engine.extensions(profileID: profileID).map {
            // Chrome grants the sites an extension asks for when it installs.
            ExtensionSummary(
                id: $0.id, name: $0.name, version: $0.version, isEnabled: $0.isEnabled, isUnpacked: $0.isUnpacked,
                reachesAllRequestedSites: true, lines: [], loadError: nil,
                allowsUserScripts: $0.usesUserScripts ? $0.userScriptsAllowed : nil
            )
        }
    }

    func setEnabled(_ enabled: Bool, extensionID: String, profileID: Profile.ID) async throws {
        engine.setExtension(extensionID, enabled: enabled, profileID: profileID)
    }

    func setAllowsUserScripts(_ allowed: Bool, extensionID: String, profileID: Profile.ID) async throws {
        engine.setUserScriptsAllowed(allowed, extensionID: extensionID, profileID: profileID)
    }

    func setReachesAllRequestedSites(_ all: Bool, extensionID: String, profileID: Profile.ID) async throws {
        throw ChromiumExtensionError.siteAccessNotSupported
    }

    func inspectBackgroundPage(_ extensionID: String, profileID: Profile.ID) async -> Bool {
        false
    }
}

/// What the Chromium engine can't do with extensions yet, said plainly.
enum ChromiumExtensionError: Error, LocalizedError {
    case siteAccessNotSupported

    var errorDescription: String? {
        switch self {
        case .siteAccessNotSupported:
            "The Chromium engine can't change which sites an extension reaches yet."
        }
    }
}

/// What the install prompt shows for a package or folder: its name, version, and what it can do.
///
/// A package is checked the way the WebKit installer checks it (its CRX3 signature, and a safe
/// unpack into a temporary folder that's deleted afterwards); Chrome's installer checks it again
/// when it installs. Permissions are described with ``PermissionDescriptions``, as in WebKit's
/// prompt.
struct InstallPreview {
    var name: String
    var version: String
    var lines: [String]
    var isUnpacked: Bool

    init(url: URL, profileID: Profile.ID) throws {
        let folder: URL
        var temporary: URL?
        if ChromiumExtensionBridge.isFolder(url) {
            folder = try ExtensionInstaller(root: url.deletingLastPathComponent()).inspectUnpacked(at: url).folder
            isUnpacked = true
        } else {
            let root = FileManager.default.temporaryDirectory.appending(path: "AxoInstallPreview-\(UUID().uuidString)", directoryHint: .isDirectory)
            temporary = root
            folder = try ExtensionInstaller(root: root).install(crx: Data(contentsOf: url), for: profileID).folder
            isUnpacked = false
        }
        defer { temporary.map { try? FileManager.default.removeItem(at: $0) } }

        // The installer already checked the manifest; read what the prompt shows from it.
        let json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "manifest.json")))) as? [String: Any] ?? [:]
        let declared = json["name"] as? String ?? ""
        // Localized names ("__MSG_name__") need the extension's locales; the file name will do.
        name = declared.isEmpty || declared.hasPrefix("__MSG_") ? url.deletingPathExtension().lastPathComponent : declared
        version = json["version"] as? String ?? ""
        let permissions = json["permissions"] as? [String] ?? []
        let contentScriptMatches = (json["content_scripts"] as? [[String: Any]] ?? []).flatMap { $0["matches"] as? [String] ?? [] }
        let hosts = (json["host_permissions"] as? [String] ?? []) + contentScriptMatches
        lines = PermissionDescriptions.lines(permissions: permissions, matchPatterns: hosts)
    }
}

/// Runs a closure when a popover closes, so the popup inside it closes too.
final class PopoverCloser: NSObject, NSPopoverDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func popoverDidClose(_ notification: Notification) {
        onClose()
    }
}
