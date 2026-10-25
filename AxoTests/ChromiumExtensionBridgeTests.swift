//
//  ChromiumExtensionBridgeTests.swift
//  AxoTests
//

import AppKit
import AxoChromium
import AxoChromiumTestSupport
import AxoCore
import AxoExtensions
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

    init() async throws {
        FakeEngine.reset()
        let classes = ChromiumEngineClasses(
            engine: FakeAXOEngine.self, configuration: FakeConfiguration.self,
            profile: FakeProfile.self, page: FakePage.self, window: FakeWindow.self
        )
        engine = ChromiumEngine(classes: classes, userDataDirectory: FileManager.default.temporaryDirectory) { $0() }
        engine.start()
        model = BrowserModel(store: try TabStore.makeInMemory(), pool: WebViewPool(engine: engine))
        model.announce = { _ in }
        await model.start()
        bridge = ChromiumExtensionBridge(model: model, engine: engine)
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
        await model.openTab(url: URL(string: "https://example.com/")!)
        let profile = try #require(FakeProfile.made[profileID])
        bridge.performAction(extensionID: "abc", profileID: profileID, tabID: model.selectedTabID)
        try await waitUntil { !profile.performed.isEmpty }
        #expect(profile.performed.first?.extensionID == "abc")
        #expect(profile.performed.first?.page === FakePage.made.last)
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

    @Test func popupsExtensionsOpenThemselvesShowLikeClickedOnes() async throws {
        await model.openTab(url: URL(string: "https://example.com/")!)
        _ = bridge.toolbarItems(profileID: profileID, tabID: model.selectedTabID)
        let profile = try #require(FakeProfile.made[profileID])
        let popup = FakeExtensionPopup(extensionIdentifier: "onepassword")

        let request = try #require(profile.onExtensionPopupRequest, "The engine passes chrome.action.openPopup on")
        request(popup)
        #expect(Array(bridge.popups.keys) == ["onepassword"])
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
        let bogus = FileManager.default.temporaryDirectory.appending(path: "AxoTests-\(UUID().uuidString).crx")
        try Data("not a package".utf8).write(to: bogus)
        await #expect(throws: (any Error).self, "A file that isn't a signed CRX3 package never reaches the prompt") {
            try await bridge.prepareInstall(from: bogus, profileID: profileID)
        }

        try await bridge.confirmInstall(bogus.path, profileID: profileID)
        #expect(FakeProfile.made[profileID]?.installedPackages.map(\.path) == [bogus.path], "Confirmed packages go to Chrome's installer")
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

/// Waits up to five seconds for `condition`.
@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(20))
    }
}
