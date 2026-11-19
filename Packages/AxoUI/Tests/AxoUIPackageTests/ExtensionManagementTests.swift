import AxoCore
import AxoWeb
import Foundation
import Testing
@testable import AxoUI

@MainActor
final class FakeExtensionManagement: ExtensionManaging {
    var prompt = ExtensionInstallPrompt(id: "ext", name: "Notes", version: "1.0", lines: ["See your open tabs and their addresses"], isUnpacked: true)
    var failInstall = false
    var confirmed: [String] = []
    var uninstalled: [String] = []
    /// The profiles each call was for, in order.
    var preparedProfiles: [Profile.ID] = []
    var confirmedProfiles: [Profile.ID] = []
    var uninstalledProfiles: [Profile.ID] = []
    var approved: [(String, Profile.ID)] = []
    var installed: [ExtensionSummary] = []

    struct Failure: Error, LocalizedError {
        var errorDescription: String? { "The signature doesn't match." }
    }

    func prepareInstall(from url: URL, profileID: Profile.ID) async throws -> ExtensionInstallPrompt {
        if failInstall { throw Failure() }
        preparedProfiles.append(profileID)
        return prompt
    }

    func confirmInstall(_ extensionID: String, profileID: Profile.ID) async throws {
        confirmed.append(extensionID)
        confirmedProfiles.append(profileID)
    }
    func uninstall(_ extensionID: String, profileID: Profile.ID) async throws {
        uninstalled.append(extensionID)
        uninstalledProfiles.append(profileID)
    }
    func installedExtensions(profileID: Profile.ID) async -> [ExtensionSummary] { installed }
    func setEnabled(_ enabled: Bool, extensionID: String, profileID: Profile.ID) async throws {}
    func setReachesAllRequestedSites(_ all: Bool, extensionID: String, profileID: Profile.ID) async throws {}
    func inspectBackgroundPage(_ extensionID: String, profileID: Profile.ID) async -> Bool { true }
    func approveNewAccess(_ extensionID: String, profileID: Profile.ID) async throws { approved.append((extensionID, profileID)) }
}

/// Toolbar buttons with pins kept in memory, as WebKit's bridge keeps them.
@MainActor
final class FakeExtensionToolbar: ExtensionToolbarProviding {
    var items: [ExtensionToolbarItem] = []
    let pins = ExtensionPins()
    var performed: [String] = []

    func toolbarItems(profileID: Profile.ID, tabID: AxoCore.Tab.ID?) -> [ExtensionToolbarItem] {
        ExtensionToolbarItem.arranged(items, pinnedIDs: pins.pinnedIDs(among: items.map(\.id), profileID: profileID))
    }
    func performAction(extensionID: String, profileID: Profile.ID, tabID: AxoCore.Tab.ID?) { performed.append(extensionID) }
    func setPinned(_ pinned: Bool, extensionID: String, profileID: Profile.ID) {
        pins.setPinned(pinned, extensionID: extensionID, among: items.map(\.id), profileID: profileID)
    }
    func movePinned(extensionID: String, to index: Int, profileID: Profile.ID) {
        pins.move(extensionID, to: index, among: items.map(\.id), profileID: profileID)
    }
}

/// Pinning, the toolbar's buttons, and managing each profile's extensions (#131).
@MainActor
struct ExtensionPinningTests {
    let profile = UUID()
    let other = UUID()

    private func item(_ id: String, _ label: String, pinned: Bool = true) -> ExtensionToolbarItem {
        ExtensionToolbarItem(id: id, label: label, icon: nil, badge: "", isEnabled: true, isPinned: pinned)
    }

    @Test func pinnedButtonsComeFirstInTheirOrderThenTheRestByName() {
        let items = [item("a", "Zebra"), item("b", "apple"), item("c", "Mango"), item("d", "Banana")]
        let arranged = ExtensionToolbarItem.arranged(items, pinnedIDs: ["c", "a", "gone"])
        #expect(arranged.map(\.id) == ["c", "a", "b", "d"])
        #expect(arranged.map(\.isPinned) == [true, true, false, false])
    }

    @Test func memoryPinsStartPinnedAndKeepTheirOrder() {
        let pins = ExtensionPins()
        let ids = ["a", "b", "c"]
        #expect(pins.pinnedIDs(among: ids, profileID: profile) == ["a", "b", "c"])
        #expect(pins.isPinned("b", profileID: profile))

        pins.setPinned(false, extensionID: "a", among: ids, profileID: profile)
        #expect(pins.pinnedIDs(among: ids, profileID: profile) == ["b", "c"])
        #expect(!pins.isPinned("a", profileID: profile))
        // Pinning again puts it at the end; unpinning another keeps the rest's order.
        pins.setPinned(true, extensionID: "a", among: ids, profileID: profile)
        #expect(pins.pinnedIDs(among: ids, profileID: profile) == ["b", "c", "a"])
        pins.setPinned(false, extensionID: "c", among: ids, profileID: profile)
        #expect(pins.pinnedIDs(among: ids, profileID: profile) == ["b", "a"])

        pins.move("a", to: 0, among: ids, profileID: profile)
        #expect(pins.pinnedIDs(among: ids, profileID: profile) == ["a", "b"])
        pins.move("a", to: 9, among: ids, profileID: profile)
        #expect(pins.pinnedIDs(among: ids, profileID: profile) == ["b", "a"])
        // A newly installed one starts pinned, after the others.
        #expect(pins.pinnedIDs(among: ids + ["d"], profileID: profile) == ["b", "a", "d"])
        // Each profile keeps its own.
        #expect(pins.pinnedIDs(among: ids, profileID: other) == ["a", "b", "c"])
        // A removed extension installed again starts pinned, as a new install does.
        pins.forget("c", profileID: profile)
        #expect(pins.isPinned("c", profileID: profile))
    }

    #if os(macOS)
    @Test func thePickerListsTheSpacesProfileFirst() {
        let home = Profile(id: UUID(), name: "Default"), work = Profile(id: UUID(), name: "Work"), kids = Profile(id: UUID(), name: "Kids")
        #expect(ExtensionsView.pickerOrder([home, work, kids], first: kids.id).map(\.name) == ["Kids", "Default", "Work"])
        #expect(ExtensionsView.pickerOrder([home, work], first: nil).map(\.name) == ["Default", "Work"])
    }

    @Test func onlyPinnedExtensionsGetButtonsAndTheMenuTakesOnePlace() {
        let items = [item("a", "A"), item("b", "B", pinned: false), item("c", "C"), item("d", "D"), item("e", "E", pinned: false)]
        #expect(ExtensionToolbarButtons.buttons(items, limit: nil).map(\.id) == ["a", "c", "d"])
        #expect(ExtensionToolbarButtons.shownCount(of: items, limit: nil) == 4)
        let limit = ExtensionToolbarButtons.addressBarLimit
        #expect(ExtensionToolbarButtons.buttons(items, limit: limit).map(\.id) == ["a", "c"])
        #expect(ExtensionToolbarButtons.shownCount(of: items, limit: limit) == limit)
        // Nothing pinned: only the menu.
        let unpinned = items.map { var copy = $0; copy.isPinned = false; return copy }
        #expect(ExtensionToolbarButtons.buttons(unpinned, limit: limit).isEmpty)
        #expect(ExtensionToolbarButtons.shownCount(of: unpinned, limit: limit) == 1)
        #expect(ExtensionToolbarButtons.shownCount(of: [], limit: limit) == 0)
    }
    #endif

    @Test func statesSayWhatAnExtensionIsDoing() {
        func summary(enabled: Bool = true, unpacked: Bool = false, pinned: Bool = false, error: String? = nil) -> ExtensionSummary {
            ExtensionSummary(id: "x", name: "X", version: "1", isEnabled: enabled, isUnpacked: unpacked, reachesAllRequestedSites: true, lines: [], loadError: error, isPinned: pinned)
        }
        #expect(summary().stateDescription == "On")
        #expect(summary(pinned: true).stateDescription == "On · Pinned")
        #expect(summary(enabled: false, pinned: true).stateDescription == "Off")
        #expect(summary(unpacked: true, pinned: true).stateDescription == "Unpacked · On · Pinned")
        #expect(summary(error: "No manifest").stateDescription == "Couldn’t load")
        #expect(summary(error: "No manifest").needsAttention)
        #expect(summary(error: "No manifest").attentionIsError)
        #expect(!summary().needsAttention)
        // An update waiting for new access (#130): a question, not an error.
        var waiting = summary(enabled: false, pinned: true)
        waiting.newAccess = ["Read and change your bookmarks"]
        #expect(waiting.stateDescription == "Off · Asks for more access")
        #expect(waiting.needsAttention && !waiting.attentionIsError)
        var blocked = summary(enabled: false)
        blocked.isBlocked = true
        #expect(blocked.stateDescription == "Off · Can’t be turned on")
        #expect(!blocked.needsAttention)
    }

    @Test func shortcutsShowTheirKeysAsMenusDo() {
        let shortcut = ExtensionShortcut(extensionID: "x", name: "go", title: "Go", key: "u", modifiers: [.command, .shift])
        #expect(shortcut.keysDescription == "⇧⌘U")
        let all = ExtensionShortcut(extensionID: "x", name: "go", title: "Go", key: "1", modifiers: [.command, .option, .control, .shift])
        #expect(all.keysDescription == "⌃⌥⇧⌘1")
    }

    #if os(macOS)
    @Test func theWindowsSearchMatchesNamesInOrder() {
        func summary(_ name: String) -> ExtensionSummary {
            ExtensionSummary(id: name, name: name, version: "1", isEnabled: true, isUnpacked: false, reachesAllRequestedSites: true, lines: [], loadError: nil)
        }
        let all = [summary("uBlock Origin Lite"), summary("Bitwarden"), summary("Dark Reader")]
        #expect(ExtensionsView.filtered(all, query: "").map(\.name) == ["Bitwarden", "Dark Reader", "uBlock Origin Lite"])
        #expect(ExtensionsView.filtered(all, query: " dark ").map(\.name) == ["Dark Reader"])
        #expect(ExtensionsView.filtered(all, query: "zzz").isEmpty)
    }
    #endif
}

@MainActor
struct ExtensionManagementTests {
    let model: BrowserModel
    let fake = FakeExtensionManagement()
    let file = URL(fileURLWithPath: "/tmp/notes.crx")

    init() async throws {
        model = BrowserModel(store: try TabStore.makeInMemory(), pool: WebViewPool(makeDataStore: { _ in .nonPersistent() }))
        model.extensionManagement = fake
        model.extensionToolbar = toolbar
        model.announce = { [said] in said.messages.append($0) }
        await model.start()
    }

    let toolbar = FakeExtensionToolbar()
    let said = Said()

    /// What VoiceOver heard.
    @MainActor final class Said {
        var messages: [String] = []
    }

    @Test func pinningAndUnpinningChangesTheButtonsAndSaysSo() throws {
        let profileID = try #require(model.space?.profileID)
        toolbar.items = [
            ExtensionToolbarItem(id: "a", label: "Alpha", icon: nil, badge: "", isEnabled: true),
            ExtensionToolbarItem(id: "b", label: "Beta", icon: nil, badge: "", isEnabled: true),
        ]
        let revision = model.extensionsRevision
        model.setExtensionPinned(false, extensionID: "a", name: "Alpha", profileID: profileID)
        let items = toolbar.toolbarItems(profileID: profileID, tabID: nil)
        #expect(items.map(\.id) == ["b", "a"])
        #expect(items.map(\.isPinned) == [true, false])
        #expect(said.messages.last == "Unpinned Alpha from the toolbar")
        #expect(model.extensionsRevision > revision)

        model.setExtensionPinned(true, extensionID: "a", name: "Alpha", profileID: profileID)
        #expect(said.messages.last == "Pinned Alpha to the toolbar")
        model.moveExtensionButton("a", name: "Alpha", to: 0, profileID: profileID)
        #expect(toolbar.toolbarItems(profileID: profileID, tabID: nil).map(\.id) == ["a", "b"])
        #expect(said.messages.last == "Moved Alpha to position 1")
    }

    @Test func removingAnotherProfilesExtensionAsksNamingItAndRemovesItThereOnly() async throws {
        let work = try #require(await model.addProfile(named: "Work"))
        try await waitUntil { model.allProfiles.contains { $0.id == work.id } }

        model.askToRemoveExtension("ub", name: "uBlock Origin Lite", profileID: work.id)
        let removal = try #require(model.pendingExtensionRemoval)
        #expect(removal.title == "Remove “uBlock Origin Lite” from Work?")

        await model.removeExtension(removal)
        #expect(fake.uninstalled == ["ub"])
        #expect(fake.uninstalledProfiles == [work.id])
        #expect(fake.uninstalledProfiles != [model.space?.profileID])
        #expect(model.pendingExtensionRemoval == nil)
        #expect(said.messages.last == "Removed uBlock Origin Lite from Work")
    }

    @Test func allowingAnUpdatesNewAccessTurnsItOnAndSaysSo() async throws {
        let profileID = try #require(model.space?.profileID)
        let revision = model.extensionsRevision
        await model.approveNewAccess("ub", name: "uBlock Origin Lite", profileID: profileID)
        #expect(fake.approved.map(\.0) == ["ub"] && fake.approved.map(\.1) == [profileID])
        #expect(said.messages.last == "Turned on uBlock Origin Lite with its new access")
        #expect(model.extensionsRevision > revision)
    }

    @Test func removingFromAProfileThatWentSaysSoAndRemovesNothing() async throws {
        model.askToRemoveExtension("ub", name: "uBlock Origin Lite", profileID: UUID())
        let removal = try #require(model.pendingExtensionRemoval)
        await model.removeExtension(removal)
        #expect(fake.uninstalled.isEmpty)
        #expect(model.alertMessage == "Axo couldn't remove uBlock Origin Lite. Its profile was deleted.")
        #expect(!said.messages.contains { $0.hasPrefix("Removed") })
    }

    @Test func theWindowOpensOnAProfileAndInstallsThere() async throws {
        let work = try #require(await model.addProfile(named: "Work"))
        try await waitUntil { model.allProfiles.contains { $0.id == work.id } }

        model.showExtensions(profileID: work.id, selecting: "ub")
        #expect(model.isShowingExtensions)
        #expect(model.shownExtensionsProfileID == work.id)
        #expect(model.extensionsSelection == "ub")

        await model.prepareExtensionInstall(from: file)
        await model.confirmExtensionInstall()
        #expect(fake.preparedProfiles == [work.id])
        #expect(fake.confirmedProfiles == [work.id])
    }

    @Test func theWindowShowsTheSpacesProfileByDefault() async throws {
        model.showExtensions()
        #expect(model.shownExtensionsProfileID == model.space?.profileID)
        // A profile that's gone falls back to the Space's.
        model.extensionsProfileID = UUID()
        #expect(model.shownExtensionsProfileID == model.space?.profileID)
    }

    @Test func installingShowsThePromptAndAddingConfirms() async {
        await model.prepareExtensionInstall(from: file)
        #expect(model.pendingExtensionInstall == fake.prompt)

        await model.confirmExtensionInstall()

        #expect(fake.confirmed == ["ext"])
        #expect(model.pendingExtensionInstall == nil)
        #expect(fake.uninstalled.isEmpty)
    }

    @Test func cancellingThePromptRemovesTheExtension() async {
        await model.prepareExtensionInstall(from: file)
        await model.cancelExtensionInstall()
        #expect(fake.uninstalled == ["ext"])
        #expect(fake.confirmed.isEmpty)
    }

    @Test func installErrorsAreShownPlainly() async {
        fake.failInstall = true
        await model.prepareExtensionInstall(from: file)
        #expect(model.pendingExtensionInstall == nil)
        #expect(model.alertMessage == "Axo couldn't install this extension. The signature doesn't match.")
    }

    @Test func extensionPermissionRequestsQueueWithPagePrompts() async throws {
        let request = ExtensionPermissionPrompt(extensionName: "Notes", lines: ["Read and change cookies for websites it can reach"])
        let answer = Task { await model.askExtensionPermission(request) }
        try await waitUntil { model.currentPrompt != nil }
        guard case .extensionPermission(let shown) = model.currentPrompt?.content else { Issue.record("Expected an extension prompt"); return }
        #expect(shown == request)
        #expect(model.currentPrompt?.tabID == nil)

        model.answerPermission(.allow)
        #expect(await answer.value)
    }

    @Test func declinedExtensionRequestsReturnFalse() async throws {
        let answer = Task { await model.askExtensionPermission(ExtensionPermissionPrompt(extensionName: "Notes", lines: [])) }
        try await waitUntil { model.currentPrompt != nil }
        model.answerPermission(.deny)
        #expect(await answer.value == false)
    }
}
