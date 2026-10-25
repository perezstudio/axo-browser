import AppKit
import AxoChromium
import AxoCore
import AxoUI
import AxoWeb
import Foundation
import Observation

/// Connects Axo's toolbar and Extensions window to extensions in the Chromium engine (Phase 2 of
/// `docs/chromium-engine.md`), as ``ExtensionBridge`` does for WebKit's.
///
/// Not yet with Chromium: installing `.crx` packages, site access settings, and inspecting
/// background pages. Unpacked folders install in developer mode.
@Observable
final class ChromiumExtensionBridge: ExtensionToolbarProviding, ExtensionManaging {
    @ObservationIgnored private weak var model: BrowserModel?
    @ObservationIgnored private let engine: ChromiumEngine
    /// Bumped when extensions or their buttons change, so views reading the toolbar update.
    private var revision = 0
    /// The open popup and its popover's delegate, by extension.
    @ObservationIgnored private var popups: [String: (popup: ChromiumExtensionPopup, closer: PopoverCloser)] = [:]

    init(model: BrowserModel, engine: ChromiumEngine) {
        self.model = model
        self.engine = engine
        model.extensionToolbar = self
        model.extensionManagement = self
        engine.onExtensionsChange = { [weak self] _ in self?.revision += 1 }
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
        guard url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw ChromiumExtensionError.packagesNotSupported
        }
        let manifest = try UnpackedManifest(folder: url)
        // The folder's path is the install's ID until Chrome assigns one.
        return ExtensionInstallPrompt(id: url.path, name: manifest.name, version: manifest.version, lines: [], isUnpacked: true)
    }

    func confirmInstall(_ extensionID: String, profileID: Profile.ID) async throws {
        _ = try await engine.loadUnpackedExtension(at: URL(fileURLWithPath: extensionID, isDirectory: true), profileID: profileID)
    }

    func uninstall(_ extensionID: String, profileID: Profile.ID) async throws {
        engine.uninstallExtension(extensionID, profileID: profileID)
    }

    func installedExtensions(profileID: Profile.ID) async -> [ExtensionSummary] {
        engine.extensions(profileID: profileID).map {
            // Chrome grants the sites an extension asks for when it installs.
            ExtensionSummary(
                id: $0.id, name: $0.name, version: $0.version, isEnabled: $0.isEnabled, isUnpacked: $0.isUnpacked,
                reachesAllRequestedSites: true, lines: [], loadError: nil
            )
        }
    }

    func setEnabled(_ enabled: Bool, extensionID: String, profileID: Profile.ID) async throws {
        engine.setExtension(extensionID, enabled: enabled, profileID: profileID)
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
    case packagesNotSupported
    case siteAccessNotSupported
    case unreadableManifest

    var errorDescription: String? {
        switch self {
        case .packagesNotSupported:
            "The Chromium engine can't install .crx packages yet. Choose an unpacked extension folder instead."
        case .siteAccessNotSupported:
            "The Chromium engine can't change which sites an extension reaches yet."
        case .unreadableManifest:
            "This folder has no readable manifest.json, so it isn't an extension."
        }
    }
}

/// The name and version from an unpacked extension's `manifest.json`, for the install prompt.
struct UnpackedManifest {
    var name: String
    var version: String

    init(folder: URL) throws {
        guard let data = try? Data(contentsOf: folder.appending(path: "manifest.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ChromiumExtensionError.unreadableManifest }
        let declared = json["name"] as? String ?? ""
        // Localized names ("__MSG_name__") need the extension's locales; the folder name will do.
        name = declared.isEmpty || declared.hasPrefix("__MSG_") ? folder.lastPathComponent : declared
        version = json["version"] as? String ?? ""
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
