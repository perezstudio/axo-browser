//
//  ChromiumExtensionBridgeTests.swift
//  AxoTests
//

import AppKit
import AxoChromium
import AxoChromiumTestSupport
import AxoCore
import AxoEngineAPI
import AxoExtensions
import AxoExtensionsTestSupport
import AxoUI
import AxoWeb
import Foundation
import SwiftUI
import Testing
@testable import Axo

/// The toolbar and Extensions window on the Chromium engine, with fake engine classes.
/// Serialized because the fakes keep class-level state, like the real framework.
@MainActor
@Suite(.serialized)
struct ChromiumExtensionBridgeTests {
    let engine: ChromiumEngine
    let model: BrowserModel
    let bridge: ChromiumExtensionBridge
    let profileID: Profile.ID
    let store: TabStore

    init() async throws {
        FakeEngine.reset()
        let classes = ChromiumEngineClasses(
            engine: FakeAXOEngine.self, configuration: FakeConfiguration.self,
            profile: FakeProfile.self, page: FakePage.self, window: FakeWindow.self
        )
        engine = ChromiumEngine(classes: classes, userDataDirectory: FileManager.default.temporaryDirectory) { $0() }
        engine.start()
        store = try TabStore.makeInMemory()
        model = BrowserModel(store: store, pool: WebViewPool(engine: engine))
        model.announce = { _ in }
        await model.start()
        bridge = ChromiumExtensionBridge(model: model, engine: engine, store: store)
        profileID = try #require(model.space?.profileID)
    }

    @Test func connectsToTheToolbarAndExtensionsWindow() {
        #expect(model.extensionToolbar === bridge)
        #expect(model.extensionManagement === bridge)
    }

    @Test func toolbarButtonsAreTheSelectedTabsActions() async throws {
        await model.openTab(url: URL(string: "https://example.com/")!)
        let profile = try #require(FakeProfile.made[profileID])
        profile.actions = [FakeExtensionAction(extensionIdentifier: "abc", title: "Blocker", badgeText: "4")]

        let items = bridge.toolbarItems(profileID: profileID, tabID: model.selectedTabID)
        #expect(items == [ExtensionToolbarItem(id: "abc", label: "Blocker", icon: nil, badge: "4", isEnabled: true)])
    }

    @Test func clickingAButtonRunsItOnTheSelectedPage() async throws {
        await model.openTab(url: URL(string: "https://example.com/first")!)
        let firstID = try #require(model.selectedTabID)
        await model.openTab(url: URL(string: "https://example.com/second")!)
        model.select(firstID)
        let profile = try #require(FakeProfile.made[profileID])
        let firstPage = try #require(FakePage.made.first { $0.loads.last?.lastPathComponent == "first" })
        bridge.performAction(extensionID: "abc", profileID: profileID, tabID: model.selectedTabID)
        try await waitUntil { !profile.performed.isEmpty }
        #expect(profile.performed.first?.extensionID == "abc")
        #expect(profile.performed.first?.page === firstPage, "The selected tab's page, not the newest")
    }

    @Test func extensionShortcutsBecomeMenuShortcutsAndRunOnTheSelectedPage() async throws {
        await model.openTab(url: URL(string: "https://example.com/")!)
        _ = bridge.toolbarItems(profileID: profileID, tabID: model.selectedTabID)
        let profile = try #require(FakeProfile.made[profileID])
        profile.extensions = [FakeExtension(identifier: "onepassword", name: "1Password")]
        profile.extensionCommands = [
            FakeExtensionCommand(extensionIdentifier: "onepassword", name: "_execute_action", title: "1Password", keyEquivalent: "X", modifierFlags: .command),
            FakeExtensionCommand(extensionIdentifier: "onepassword", name: "lock", title: "Lock the extension", keyEquivalent: "l", modifierFlags: [.command, .option]),
        ]

        let shortcuts = bridge.shortcuts(profileID: profileID)
        #expect(shortcuts.map(\.title) == ["1Password", "1Password: Lock the extension"])
        #expect(shortcuts.first?.key == "x" && shortcuts.first?.modifiers == [.command, .shift], "An uppercase key equivalent means Shift")
        #expect(shortcuts.last?.key == "l" && shortcuts.last?.modifiers == [.command, .option])

        bridge.performShortcut(try #require(shortcuts.last), profileID: profileID, tabID: model.selectedTabID)
        try await waitUntil { !profile.performedCommands.isEmpty }
        #expect(profile.performedCommands.map(\.name) == ["lock"])
        #expect(profile.performedCommands.first?.page === FakePage.made.last, "On the selected tab's page")
    }

    @Test func theSidebarIsTheEnginesBookmarks() async throws {
        await model.openTab(url: URL(string: "https://example.com/")!)
        let profile = try #require(FakeProfile.made[profileID])
        let mail = try await store.favorites.add(url: URL(string: "https://mail.example/")!, title: "Mail", profileID: profileID)
        try await waitUntil { profile.bookmarkBar.map(\.identifier) == [mail.id.uuidString.lowercased()] }
        let spaceID = try #require(model.space?.id)
        #expect(profile.otherBookmarks.map(\.identifier) == [spaceID.uuidString.lowercased()], "Spaces are folders in the other bookmarks")
    }

    @Test func extensionsBookmarkChangesReachTheSidebarAndWhatItCantHoldIsUndone() async throws {
        await model.openTab(url: URL(string: "https://example.com/")!)
        let profile = try #require(FakeProfile.made[profileID])
        let spaceID = try #require(model.space?.id)
        let docs = UUID()
        profile.onBookmarkChange?(FakeBookmarkChange(
            kind: .created, identifier: docs.uuidString.lowercased(), parentIdentifier: spaceID.uuidString.lowercased(),
            title: "Docs", url: URL(string: "https://docs.example/")!
        ))
        try await waitUntil { profile.otherBookmarks.first?.children.map(\.identifier) == [docs.uuidString.lowercased()] }
        let tab = try #require(try await store.tab(id: docs))
        #expect(tab.isPinned && tab.title == "Docs", "A bookmark in a Space is a pinned tab")

        // The bar holds no folders. Nothing in the sidebar changes, so only the bridge sending the
        // tree back undoes it in the engine.
        let mail = try await store.favorites.add(url: URL(string: "https://mail.example/")!, title: "Mail", profileID: profileID)
        try await waitUntil { profile.bookmarkBar.count == 1 }
        await bridge.dataWorkFinished()
        let sent = profile.bookmarkSetCount
        profile.onBookmarkChange?(FakeBookmarkChange(kind: .created, identifier: UUID().uuidString, parentRoot: .bar, index: 1, title: "A folder"))
        await bridge.dataWorkFinished()
        #expect(profile.bookmarkSetCount == sent + 1, "The tree goes back after the change")
        #expect(profile.bookmarkBar.map(\.identifier) == [mail.id.uuidString.lowercased()])
        #expect(try await store.folders(in: spaceID).isEmpty)
    }

    @Test func aTreeIsNeverSentHalfwayThroughAChange() async throws {
        await model.openTab(url: URL(string: "https://example.com/")!)
        let profile = try #require(FakeProfile.made[profileID])
        let spaceID = try #require(model.space?.id)
        try await waitUntil { profile.bookmarkSetCount > 0 }
        // A sidebar change queues a send, then an extension's change arrives before it runs.
        _ = try await store.favorites.add(url: URL(string: "https://mail.example/")!, title: "Mail", profileID: profileID)
        let docs = UUID()
        profile.onBookmarkChange?(FakeBookmarkChange(
            kind: .created, identifier: docs.uuidString, parentIdentifier: spaceID.uuidString, title: "Docs", url: URL(string: "https://docs.example/")!
        ))
        await bridge.dataWorkFinished()
        #expect(profile.otherBookmarks.first?.children.map(\.identifier) == [docs.uuidString.lowercased()], "The last tree sent has the new bookmark")
    }

    @Test func extensionsHistoryChangesReachAxosHistory() async throws {
        await model.openTab(url: URL(string: "https://example.com/")!)
        let profile = try #require(FakeProfile.made[profileID])
        let history = store.history
        let added = URL(string: "https://added.example/")!
        try await history.recordVisit(to: URL(string: "https://kept.example/")!, title: "Kept", profileID: profileID, at: .distantPast)

        profile.onHistoryChange?(FakeHistoryChange(kind: .visited, urls: [added], title: "Added", date: Date()))
        try await waitUntil(async: { try await history.recent(profileID: profileID).first?.url == added })
        #expect(try await history.recent(profileID: profileID).first?.title == "Added")

        // An extension deletes the last minute: the page Axo last saw long ago keeps its history.
        let kept = URL(string: "https://kept.example/")!
        profile.onHistoryChange?(FakeHistoryChange(
            kind: .deleted, urls: [kept, added], date: Date().addingTimeInterval(-60), endDate: Date().addingTimeInterval(60)
        ))
        try await waitUntil(async: { try await history.recent(profileID: profileID).map(\.url) == [URL(string: "https://kept.example/")!] })

        profile.onHistoryChange?(FakeHistoryChange(kind: .deletedAll))
        try await waitUntil(async: { try await history.recent(profileID: profileID).isEmpty })
    }

    @Test func historyChangesApplyInTheOrderTheyCame() async throws {
        await model.openTab(url: URL(string: "https://example.com/")!)
        let profile = try #require(FakeProfile.made[profileID])
        let page = URL(string: "https://added.example/")!
        for _ in 0..<20 {
            profile.onHistoryChange?(FakeHistoryChange(kind: .visited, urls: [page], title: "Added", date: Date()))
            profile.onHistoryChange?(FakeHistoryChange(kind: .deletedAll))
        }
        profile.onHistoryChange?(FakeHistoryChange(kind: .visited, urls: [page], title: "Last", date: Date()))
        await bridge.dataWorkFinished()
        let items = try await store.history.recent(profileID: profileID)
        #expect(items.map(\.title) == ["Last"])
        #expect(items.first?.visitCount == 1, "Every earlier visit was deleted after it")
    }

    @Test func theUserScriptsSwitchIsOnlyForExtensionsThatUseThem() async throws {
        await model.openTab(url: URL(string: "https://example.com/")!)
        _ = bridge.toolbarItems(profileID: profileID, tabID: model.selectedTabID)
        let profile = try #require(FakeProfile.made[profileID])
        profile.extensions = [
            FakeExtension(identifier: "manager", name: "Script Manager", usesUserScripts: true, userScriptsAllowed: false),
            FakeExtension(identifier: "notes", name: "Notes"),
        ]

        let installed = await bridge.installedExtensions(profileID: profileID)
        #expect(installed.map(\.allowsUserScripts) == [false, nil])

        try await bridge.setAllowsUserScripts(true, extensionID: "manager", profileID: profileID)
        #expect(profile.userScriptChanges.map(\.0) == ["manager"])
        #expect(profile.userScriptChanges.map(\.1) == [true])
    }

    @Test func sidePanelsShowBesideThePageAndCloseInTheEngine() async throws {
        await model.openTab(url: URL(string: "https://example.com/")!)
        _ = bridge.toolbarItems(profileID: profileID, tabID: model.selectedTabID)
        let profile = try #require(FakeProfile.made[profileID])
        let open = try #require(profile.onExtensionSidePanelOpen)
        let panel = FakeExtensionSidePanel(extensionIdentifier: "notes", title: "Notes")

        open(panel)
        #expect(model.extensionSidePanel?.title == "Notes")
        #expect(model.extensionSidePanel?.view === panel.view)

        model.closeExtensionSidePanel()
        #expect(panel.isClosed, "The close button closes it in the engine")

        let second = FakeExtensionSidePanel(extensionIdentifier: "notes", title: "Notes")
        open(second)
        second.onClose?()
        #expect(model.extensionSidePanel == nil, "Closing it from the extension hides it")
    }

    @Test func chromesPromptsAreAxosAlerts() async throws {
        await model.openTab(url: URL(string: "https://example.com/")!)
        _ = bridge.toolbarItems(profileID: profileID, tabID: model.selectedTabID)
        let profile = try #require(FakeProfile.made[profileID])
        var shown: [ChromiumExtensionBridge.PromptAlert] = []
        // The button the person picks, set before each question.
        final class Choice { var index = 0 }
        let chosen = Choice()
        bridge.presentAlert = { alert, answer in
            shown.append(alert)
            answer(chosen.index)
        }
        let ask = try #require(profile.onExtensionPrompt)
        var answers: [AXOExtensionPromptAnswer] = []

        ask(FakeExtensionPrompt(kind: .permissions, extensionName: "Notes", details: ["Read your clipboard"]), { answers.append($0) })
        #expect(shown.last?.title == "“Notes” wants more access")
        #expect(shown.last?.message == "If you allow it, it can:\n• Read your clipboard")
        #expect(shown.last?.buttons == ["Allow", "Don’t Allow"])

        chosen.index = 1
        ask(FakeExtensionPrompt(kind: .uninstall, extensionName: "Notes", requestingExtensionName: "Cleaner"), { answers.append($0) })
        #expect(shown.last?.title == "Remove “Notes”?")
        #expect(shown.last?.message == "“Cleaner” asked to remove it. Its data in Axo is deleted too.")
        #expect(shown.last?.isDestructive == true)

        ask(FakeExtensionPrompt(kind: .screenCapture, extensionName: "meet.example.com"), { answers.append($0) })
        #expect(shown.last?.buttons == ["Entire Screen", "A Window", "Cancel"])

        #expect(answers == [.accept, .cancel, .window], "Each button gives its answer")
    }

    @Test func popupsExtensionsOpenThemselvesShowLikeClickedOnes() async throws {
        await model.openTab(url: URL(string: "https://example.com/")!)
        _ = bridge.toolbarItems(profileID: profileID, tabID: model.selectedTabID)
        let profile = try #require(FakeProfile.made[profileID])
        let popup = FakeExtensionPopup(extensionIdentifier: "onepassword")

        let request = try #require(profile.onExtensionPopupRequest, "The engine passes chrome.action.openPopup on")
        request(popup)
        #expect(Array(bridge.popups.keys) == ["onepassword"])

        // Opened again (its shortcut, or openPopup) while the first is open.
        let second = FakeExtensionPopup(extensionIdentifier: "onepassword")
        request(second)
        #expect(popup.isClosed, "The first popup's page closes")
        #expect(!second.isClosed)
        #expect(bridge.popups["onepassword"]?.popup.view === second.view, "The new one is the extension's popup")
    }

    @Test func unpackedFoldersShowWhatTheyCanDoThenLoad() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "AxoTests-Extension-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"{"manifest_version": 3, "name": "Tab Tidy", "version": "2.1", "permissions": ["tabs"], "host_permissions": ["<all_urls>"]}"#
            .write(to: folder.appending(path: "manifest.json"), atomically: true, encoding: .utf8)

        let prompt = try await bridge.prepareInstall(from: folder, profileID: profileID)
        #expect(prompt.name == "Tab Tidy" && prompt.version == "2.1" && prompt.isUnpacked)
        #expect(prompt.lines == PermissionDescriptions.lines(permissions: ["tabs"], matchPatterns: ["<all_urls>"]), "As WebKit's prompt describes them")
        #expect(!prompt.lines.isEmpty)

        try await bridge.confirmInstall(prompt.id, profileID: profileID)
        #expect(FakeProfile.made[profileID]?.loadedExtensions.map(\.standardizedFileURL.path) == [folder.standardizedFileURL.path])
    }

    @Test func packagesAreCheckedBeforeThePromptAndInstallThroughTheEngine() async throws {
        _ = bridge.toolbarItems(profileID: profileID, tabID: nil)
        let folder = FileManager.default.temporaryDirectory.appending(path: "AxoTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bogus = folder.appending(path: "bogus.crx")
        try Data("not a package".utf8).write(to: bogus)
        await #expect(throws: (any Error).self, "A file that isn't a signed CRX3 package never reaches the prompt") {
            try await bridge.prepareInstall(from: bogus, profileID: profileID)
        }
        await #expect(throws: ChromiumExtensionError.self, "Nothing installs without a prompt describing it") {
            try await bridge.confirmInstall(bogus.path, profileID: profileID)
        }

        let package = folder.appending(path: "Notes.crx")
        let packageData = try CRXBuilder().build(zip: sampleExtensionZip(name: "Notes"))
        try packageData.write(to: package)
        let prompt = try await bridge.prepareInstall(from: package, profileID: profileID)
        #expect(prompt.name == "Notes")
        // The file changes while the prompt is open.
        try Data("something else".utf8).write(to: package)
        try await bridge.confirmInstall(prompt.id, profileID: profileID)

        let installed = try #require(FakeProfile.made[profileID]?.installedPackages.first)
        #expect(installed != package, "Chrome's installer gets Axo's copy of what the prompt described")
        #expect(FakeProfile.made[profileID]?.installedPackageData == [packageData], "Exactly the package the prompt described")
        #expect(!FileManager.default.fileExists(atPath: installed.path), "The copy is deleted afterwards")
        await #expect(throws: ChromiumExtensionError.self, "A prompt installs once") {
            try await bridge.confirmInstall(prompt.id, profileID: profileID)
        }
    }

    @Test func installedExtensionsListAndToggle() async throws {
        let profile = try #require(FakeProfile.made[profileID])
        profile.extensions = [FakeExtension(identifier: "abc", name: "Blocker", isEnabled: false)]

        let listed = await bridge.installedExtensions(profileID: profileID)
        #expect(listed.map(\.id) == ["abc"] && listed.first?.isEnabled == false && listed.first?.isUnpacked == true)

        try await bridge.setEnabled(true, extensionID: "abc", profileID: profileID)
        try await bridge.uninstall("abc", profileID: profileID)
        #expect(profile.enabledChanges.first?.0 == "abc" && profile.enabledChanges.first?.1 == true)
        #expect(profile.uninstalled == ["abc"])
        await #expect(throws: ChromiumExtensionError.self) {
            try await bridge.setReachesAllRequestedSites(false, extensionID: "abc", profileID: profileID)
        }
    }
}

/// A wait that ran out of time, naming where it was.
private struct WaitTimedOut: Error, CustomStringConvertible {
    let location: SourceLocation
    var description: String { "Waited five seconds at \(location) and the condition never held." }
}

/// Waits up to five seconds for `condition`.
@MainActor
private func waitUntil(async condition: () async throws -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw WaitTimedOut(location: sourceLocation) }
        try await Task.sleep(for: .milliseconds(20))
    }
}

private func waitUntil(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw WaitTimedOut(location: sourceLocation) }
        try await Task.sleep(for: .milliseconds(20))
    }
}
