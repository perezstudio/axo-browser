import AppKit
import AxoChromium
import AxoCore
import AxoExtensions
import AxoUI
import AxoWeb
import Foundation
import GRDB
import Observation
import SwiftUI

/// Connects Axo's toolbar and Extensions window to extensions in the Chromium engine (Phase 2 of
/// `docs/chromium-engine.md`), as ``ExtensionBridge`` does for WebKit's.
///
/// Packages (`.crx`) install through Chrome's installer after Axo's prompt; unpacked folders
/// load in developer mode. Not yet with Chromium: site access settings and inspecting
/// background pages.
///
/// It also keeps each profile's bookmarks in the engine (`chrome.bookmarks`) in step with the
/// sidebar (``BookmarkTree``), and applies extensions' bookmark changes to it, and applies the
/// history changes the engine makes without a page visit (extensions adding visits or deleting
/// history) to Axo's history.
@Observable
final class ChromiumExtensionBridge: ExtensionToolbarProviding, ExtensionManaging {
    @ObservationIgnored private weak var model: BrowserModel?
    @ObservationIgnored private let engine: ChromiumEngine
    @ObservationIgnored private let store: TabStore
    /// Follows the profiles, and each profile's bookmark tree.
    @ObservationIgnored private var profilesTask: Task<Void, Never>?
    @ObservationIgnored private var bookmarkTasks: [Profile.ID: Task<Void, Never>] = [:]
    /// Bookmark trees to send and the engine's bookmark and history changes to apply, one after
    /// another, so a tree is never read while a change is half applied and changes apply in the
    /// order they came.
    @ObservationIgnored private var dataWork: Task<Void, Never>?
    /// Profiles whose tree is waiting in `dataWork` to be sent.
    @ObservationIgnored private var pendingBookmarkSends: Set<Profile.ID> = []
    /// Bumped when extensions or their buttons change, so views reading the toolbar update.
    private var revision = 0
    /// Shows an alert and calls back with the index of the button chosen. Tests replace it.
    @ObservationIgnored var presentAlert: @MainActor (PromptAlert, @escaping (Int) -> Void) -> Void = ChromiumExtensionBridge.showAlert
    /// The open popup and its popover's delegate, by extension.
    /// Installs the person was asked about, by prompt ID: what to install. A package is a private
    /// copy of the file the prompt described, so changing the file meanwhile changes nothing.
    @ObservationIgnored private var preparedInstalls: [String: (url: URL, isUnpacked: Bool)] = [:]
    @ObservationIgnored private(set) var popups: [String: (popup: ChromiumExtensionPopup, closer: PopoverCloser, popover: NSPopover)] = [:]

    init(model: BrowserModel, engine: ChromiumEngine, store: TabStore) {
        self.model = model
        self.engine = engine
        self.store = store
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
        engine.onExtensionSidePanelOpen = { [weak model] panel, profileID in
            guard let model else {
                panel.close()
                return
            }
            panel.onClose = { [weak model] in model?.extensionSidePanelDidClose(panel.extensionID) }
            model.showExtensionSidePanel(ExtensionSidePanel(id: panel.extensionID, title: panel.title, view: panel.view, profileID: profileID) { panel.close() })
        }
        // Extensions that handle their own clicks (1Password) open their popup themselves.
        engine.onExtensionPopupRequest = { [weak self] popup, _ in self?.present(popup) }
        // Buttons appear once the engine is ready.
        let previous = engine.onStateChange
        engine.onStateChange = { [weak self] state in
            previous?(state)
            self?.revision += 1
        }
        engine.onBookmarkChange = { [weak self] change, profileID in self?.apply(change, profileID: profileID) }
        engine.onHistoryChange = { [weak self, store] change, profileID in
            self?.enqueue { try? await Self.apply(change, to: store.history, profileID: profileID) }
        }
        profilesTask = Task { [weak self, store] in
            do {
                for try await list in store.observeProfiles() {
                    guard let self else { return }
                    followBookmarks(of: Set(list.map(\.id)))
                }
            } catch {}
        }
    }

    // MARK: History

    /// Applies a history change the engine made to Axo's history.
    static func apply(_ change: ChromiumHistoryChange, to history: HistoryStore, profileID: Profile.ID) async throws {
        switch change {
        case .visited(let url, let title, let date):
            try await history.recordVisit(to: url, title: title, profileID: profileID, at: date)
        case .deleted(let urls, let range):
            try await history.delete(urls, lastVisitedIn: range, profileID: profileID)
        case .deletedAll:
            try await history.clear(profileID: profileID)
        }
    }

    // MARK: Bookmarks

    /// Sends each profile's bookmark tree to the engine whenever it changes.
    private func followBookmarks(of profileIDs: Set<Profile.ID>) {
        for (profileID, task) in bookmarkTasks where !profileIDs.contains(profileID) {
            task.cancel()
            bookmarkTasks[profileID] = nil
        }
        for profileID in profileIDs where bookmarkTasks[profileID] == nil {
            bookmarkTasks[profileID] = Task { [weak self, store] in
                do {
                    // Each value is a signal: an older one can arrive after a newer write.
                    for try await _ in store.observeBookmarkTree(profileID: profileID) {
                        guard let self else { return }
                        scheduleBookmarkSend(profileID: profileID)
                    }
                } catch {}
            }
        }
    }

    /// Runs `work` after everything already in `dataWork`.
    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = dataWork
        dataWork = Task {
            await previous?.value
            await work()
        }
    }

    /// Sends a profile's tree once the work before it is done, reading it then.
    private func scheduleBookmarkSend(profileID: Profile.ID) {
        guard pendingBookmarkSends.insert(profileID).inserted else { return }
        enqueue { [weak self] in
            guard let self else { return }
            pendingBookmarkSends.remove(profileID)
            guard let tree = try? await store.bookmarkTree(profileID: profileID) else { return }
            engine.setBookmarks(tree, profileID: profileID)
        }
    }

    /// Applies an extension's bookmark change to the sidebar, then sends the tree back, which
    /// undoes in the engine what the sidebar can't hold.
    func apply(_ change: BookmarkChange, profileID: Profile.ID) {
        enqueue { [store, weak model] in
            let spaces = (try? await store.spaces()) ?? []
            let shown = model?.space.flatMap { $0.profileID == profileID ? $0.id : nil }
            if let spaceID = shown ?? spaces.first(where: { $0.profileID == profileID })?.id {
                try? await store.applyBookmarkChange(change, profileID: profileID, currentSpaceID: spaceID)
            }
        }
        // A send already queued runs before the change; this one runs after it.
        pendingBookmarkSends.remove(profileID)
        scheduleBookmarkSend(profileID: profileID)
    }

    /// Waits for the queued bookmark and history work, for tests.
    func dataWorkFinished() async {
        await dataWork?.value
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
        // The extension's open popup, if any, goes away first: its page and its popover.
        if let previous = popups.removeValue(forKey: extensionID) {
            previous.popup.close()
            previous.popover.close()
        }
        let controller = NSViewController()
        controller.view = popup.view
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.contentSize = popup.preferredSize
        popup.onResize = { [weak popover] size in popover?.contentSize = size }
        popup.onClose = { [weak popover] in popover?.close() }
        // Only this popup's entry: a newer popup of the same extension may have replaced it.
        let closer = PopoverCloser { [weak self, weak popup] in
            guard let self, let popup, popups[extensionID]?.popup === popup else { return }
            popups.removeValue(forKey: extensionID)
            popup.close()
        }
        popover.delegate = closer
        popups[extensionID] = (popup, closer, popover)
        model?.presentExtensionPopup(popover, extensionID: extensionID)
    }

    // MARK: ExtensionManaging

    func prepareInstall(from url: URL, profileID: Profile.ID) async throws -> ExtensionInstallPrompt {
        var source = url
        if !Self.isFolder(url) {
            source = FileManager.default.temporaryDirectory.appending(path: "AxoPendingInstall-\(UUID().uuidString).crx")
            try FileManager.default.copyItem(at: url, to: source)
        }
        do {
            let preview = try InstallPreview(url: source, displayName: url, profileID: profileID)
            let id = UUID().uuidString
            preparedInstalls[id] = (source, preview.isUnpacked)
            return ExtensionInstallPrompt(
                id: id, name: preview.name, version: preview.version, lines: preview.lines, isUnpacked: preview.isUnpacked
            )
        } catch {
            if source != url { try? FileManager.default.removeItem(at: source) }
            throw error
        }
    }

    /// Installs what a prompt described, once. Anything else is refused.
    func confirmInstall(_ extensionID: String, profileID: Profile.ID) async throws {
        guard let prepared = preparedInstalls.removeValue(forKey: extensionID) else {
            throw ChromiumExtensionError.notPrepared
        }
        if prepared.isUnpacked {
            _ = try await engine.loadUnpackedExtension(at: prepared.url, profileID: profileID)
        } else {
            defer { try? FileManager.default.removeItem(at: prepared.url) }
            _ = try await engine.installPackage(at: prepared.url, profileID: profileID)
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

/// What the Chromium engine can't or won't do with extensions, said plainly.
enum ChromiumExtensionError: Error, LocalizedError {
    case siteAccessNotSupported
    /// An install that no prompt described.
    case notPrepared

    var errorDescription: String? {
        switch self {
        case .siteAccessNotSupported:
            "The Chromium engine can't change which sites an extension reaches yet."
        case .notPrepared:
            "Axo can only add an extension after showing what it can do."
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

    /// - Parameters:
    ///   - url: The package or folder to describe.
    ///   - displayName: The file the person chose, whose name stands in for a localized one.
    init(url: URL, displayName: URL, profileID: Profile.ID) throws {
        let folder: URL
        var temporary: URL?
        defer { temporary.map { try? FileManager.default.removeItem(at: $0) } }
        if ChromiumExtensionBridge.isFolder(url) {
            folder = try ExtensionInstaller(root: url.deletingLastPathComponent()).inspectUnpacked(at: url).folder
            isUnpacked = true
        } else {
            let root = FileManager.default.temporaryDirectory.appending(path: "AxoInstallPreview-\(UUID().uuidString)", directoryHint: .isDirectory)
            temporary = root
            folder = try ExtensionInstaller(root: root).install(crx: Data(contentsOf: url), for: profileID).folder
            isUnpacked = false
        }

        // The installer already checked the manifest; read what the prompt shows from it.
        let json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "manifest.json")))) as? [String: Any] ?? [:]
        let declared = json["name"] as? String ?? ""
        // Localized names ("__MSG_name__") need the extension's locales; the file name will do.
        name = declared.isEmpty || declared.hasPrefix("__MSG_") ? displayName.deletingPathExtension().lastPathComponent : declared
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
