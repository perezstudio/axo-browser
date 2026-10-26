import AppKit
import AxoCore
import AxoEngineAPI
import AxoWeb
import Foundation
import Testing
@testable import AxoChromium
import AxoChromiumTestSupport

/// The engine adapter, on fake engine classes. Serialized because the fakes keep class-level
/// state, like the real framework.
@MainActor
@Suite(.serialized)
struct ChromiumEngineTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "AxoChromiumTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let profileID = UUID()
    let url = URL(string: "https://example.com/")!

    init() {
        FakeEngine.reset()
    }

    /// An engine whose scheduled blocks run when `scheduled` is drained.
    private func makeEngine(scheduled: Scheduled) -> ChromiumEngine {
        ChromiumEngine(classes: FakeEngine.classes, userDataDirectory: directory) { scheduled.blocks.append($0) }
    }

    @MainActor
    final class Scheduled {
        var blocks: [@MainActor () -> Void] = []
        func run() {
            let pending = blocks
            blocks = []
            pending.forEach { $0() }
        }
    }

    // MARK: Loading the framework

    @Test func classesAreFoundAndTheirAPIVersionChecked() throws {
        let fakes: [String: AnyClass] = [
            "AXOEngine": FakeAXOEngine.self, "AXOEngineConfiguration": FakeConfiguration.self,
            "AXOProfile": FakeProfile.self, "AXOPage": FakePage.self, "AXOWindow": FakeWindow.self,
        ]
        let found = try ChromiumFramework.classes { fakes[$0] }.get()
        #expect(ObjectIdentifier(found.page) == ObjectIdentifier(FakePage.self))

        #expect(ChromiumFramework.classes { $0 == "AXOPage" ? nil : fakes[$0] }.failure == .missingClass("AXOPage"))
        FakeAXOEngine.apiVersionOverride = ChromiumFramework.apiVersion + 1
        #expect(ChromiumFramework.classes { fakes[$0] }.failure == .apiVersionMismatch(framework: ChromiumFramework.apiVersion + 1, axo: ChromiumFramework.apiVersion))
    }

    @Test func aBundleWithoutTheFrameworkSaysSo() {
        let empty = Bundle(url: FileManager.default.temporaryDirectory)!
        #expect(ChromiumFramework.load(from: empty).failure == .notEmbedded)
    }

    // MARK: Starting

    @Test func startingRunsTheEngineOnALaterTurnWithItsDataFolder() {
        let scheduled = Scheduled()
        let engine = makeEngine(scheduled: scheduled)
        var states: [ChromiumEngine.State] = []
        engine.onStateChange = { states.append($0) }

        engine.start()
        #expect(engine.state == .starting)
        #expect(FakeAXOEngine.configurations.isEmpty, "Nothing runs until the run loop turns")

        scheduled.run()
        #expect(engine.state == .ready)
        #expect(states == [.starting, .ready])
        #expect(FakeAXOEngine.configurations.first?.userDataDirectory == directory)
        #expect(FakeAXOEngine.configurations.first?.nativeMessagingHostFolders == [], "None unless the app asks")
        #expect(FakeAXOEngine.configurations.first?.ephemeral == false)

        engine.start()
        #expect(FakeAXOEngine.configurations.count == 1, "Starting twice does nothing")
    }

    @Test func testEnginesAreEphemeral() {
        let scheduled = Scheduled()
        let engine = ChromiumEngine(
            classes: FakeEngine.classes, userDataDirectory: directory, isEphemeral: true, additionalArguments: ["--v=1"]
        ) { scheduled.blocks.append($0) }
        engine.start()
        scheduled.run()
        #expect(FakeAXOEngine.configurations.first?.ephemeral == true, "Tests use a stand-in keychain and make no background requests")
        #expect(FakeAXOEngine.configurations.first?.additionalArguments == ["--v=1"])
    }

    @Test func nativeMessagingFoldersReachTheEngine() {
        let scheduled = Scheduled()
        let folders = [URL(fileURLWithPath: "/tmp/AxoChromiumTests-hosts", isDirectory: true)]
        let engine = ChromiumEngine(classes: FakeEngine.classes, userDataDirectory: directory, nativeMessagingHostFolders: folders) {
            scheduled.blocks.append($0)
        }
        engine.start()
        scheduled.run()
        #expect(FakeAXOEngine.configurations.first?.nativeMessagingHostFolders == folders)
    }

    @Test func extensionPopupWindowsReachThePoolAndCloseWithTheirPage() throws {
        let scheduled = Scheduled()
        let engine = makeEngine(scheduled: scheduled)
        engine.start()
        scheduled.run()
        let pool = WebViewPool(engine: engine)
        var popups: [EnginePopupWindow] = []
        var closed: [Tab.ID] = []
        pool.onEnginePopupWindow = { popups.append($0) }
        pool.onEngineClosedTab = { closed.append($0) }
        let profile = try #require(engine.readyProfile(profileID) as? FakeProfile)
        let window = FakeWindow(profile: profile)
        let chromePage = FakePage(profile: profile)
        window.pages = [chromePage]

        let open = try #require(profile.onExtensionWindowOpen, "The engine handles extensions' popup windows")
        open(window, NSSize(width: 380, height: 600))
        let popup = try #require(popups.first)
        #expect(popup.size == CGSize(width: 380, height: 600))
        #expect(popup.profileID == profileID)
        let tab = Tab(spaceID: UUID(), url: url, sortKey: SortKey.initial)
        pool.adopt(popup.page, as: tab, profileID: profileID)
        #expect(pool.livePage(for: tab.id)?.view.subviews.first === chromePage.view)

        // chrome.windows.remove: Chrome closes the page, which closes the window.
        window.delegate?.window(window, didClose: chromePage)
        #expect(closed == [tab.id])
    }

    @Test func keysThePageDidNotUseGoToTheMenu() throws {
        let scheduled = Scheduled()
        let engine = makeEngine(scheduled: scheduled)
        engine.start()
        scheduled.run()
        let page = engine.makePage(profileID: profileID)
        let fake = try #require(FakePage.made.last)
        var handled: [String] = []
        let original = ChromiumPage.handleUnusedKeyEvent
        ChromiumPage.handleUnusedKeyEvent = { handled.append($0.charactersIgnoringModifiers ?? ""); return true }
        defer { ChromiumPage.handleUnusedKeyEvent = original }
        let shortcut = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
            context: nil, characters: "l", charactersIgnoringModifiers: "l", isARepeat: false, keyCode: 37
        ))

        let used = fake.delegate?.page?(fake, didNotHandleKeyEvent: shortcut)
        #expect(used == true)
        #expect(handled == ["l"], "⌘L reaches Axo's menu while the page has focus")
        withExtendedLifetime(page) {}
    }

    @Test func promptsReachTheAppAndItsAnswerReturns() throws {
        let scheduled = Scheduled()
        let engine = makeEngine(scheduled: scheduled)
        engine.start()
        scheduled.run()
        let profile = try #require(engine.readyProfile(profileID) as? FakeProfile)
        let ask = try #require(profile.onExtensionPrompt, "The engine handles Chrome's prompts")
        var answers: [AXOExtensionPromptAnswer] = []

        ask(FakeExtensionPrompt(kind: .permissions, extensionName: "Notes"), { answers.append($0) })
        #expect(answers == [.cancel], "No handler: Cancel")

        var asked: [ChromiumExtensionPrompt] = []
        engine.onExtensionPrompt = { prompt, _, answer in
            asked.append(prompt)
            answer(prompt.kind == .screenCapture ? .window : .accept)
        }
        ask(FakeExtensionPrompt(kind: .uninstall, extensionName: "Notes", requestingExtensionName: "Cleaner"), { answers.append($0) })
        ask(FakeExtensionPrompt(kind: .screenCapture, extensionName: "meet.example.com"), { answers.append($0) })
        #expect(asked.map(\.kind) == [.uninstall(requestedBy: "Cleaner"), .screenCapture])
        #expect(answers == [.cancel, .accept, .window])
    }

    @Test func windowsAreActiveWhileTheAppIs() throws {
        let scheduled = Scheduled()
        let engine = makeEngine(scheduled: scheduled)
        engine.start()
        scheduled.run()
        engine.setWindowPages([], active: nil, profileID: profileID)
        let window = try #require(FakeWindow.made.first)

        engine.setWindowsActive(true)
        #expect(window.isActive)
        engine.setWindowsActive(false)
        #expect(!window.isActive)
    }

    @Test func rightClicksBecomeAxosMenu() throws {
        let scheduled = Scheduled()
        let engine = makeEngine(scheduled: scheduled)
        engine.start()
        scheduled.run()
        let pool = WebViewPool(engine: engine)
        let tab = Tab(spaceID: UUID(), url: url, sortKey: SortKey.initial)
        pool.page(for: tab, profileID: profileID)
        let fake = try #require(FakePage.made.last)
        var menus: [(any PageContextMenu, Tab.ID)] = []
        pool.onContextMenu = { menu, tabID in
            menus.append((menu, tabID))
            return true
        }
        let engineMenu = FakeAXOContextMenu()
        engineMenu.linkURL = URL(string: "https://example.com/next")
        engineMenu.isEditable = true
        engineMenu.edits = [.copy, .paste]
        let fill = FakeAXOContextMenuItem(title: "Fill Password")
        engineMenu.extensionItems = [FakeAXOContextMenuItem(type: .submenu, title: "Passwords", children: [fill])]

        let shown = fake.delegate?.page?(fake, showContextMenu: engineMenu)
        #expect(shown == true)
        let (menu, tabID) = try #require(menus.first)
        #expect(tabID == tab.id)
        #expect(menu.linkURL == engineMenu.linkURL)
        #expect(menu.edits == [.copy, .paste])
        #expect(menu.extensionItems.first?.kind == .submenu)
        #expect(menu.extensionItems.first?.children.map(\.title) == ["Fill Password"])

        menu.perform(.pasteAndMatchStyle)
        menu.perform(try #require(menu.extensionItems.first?.children.first))
        #expect(engineMenu.performedEdits == [.pasteAndMatchStyle])
        #expect(engineMenu.performedItems.first === fill, "The engine runs its own item")
    }

    @Test func aFailedStartReportsWhy() {
        FakeAXOEngine.failure = FakeEngineError()
        let scheduled = Scheduled()
        let engine = makeEngine(scheduled: scheduled)
        engine.start()
        scheduled.run()
        #expect(engine.state == .failed("The fake engine refused to start."))
    }

    // MARK: Pages

    @Test func pagesMadeBeforeTheEngineIsReadyAttachWhenItIs() throws {
        let scheduled = Scheduled()
        let engine = makeEngine(scheduled: scheduled)
        engine.start()
        let early = try #require(engine.makePage(profileID: profileID) as? ChromiumPage)
        early.load(url)
        let closed = engine.makePage(profileID: profileID)
        closed.close()
        #expect(FakePage.made.isEmpty)
        #expect(early.isLoading, "A page waiting for the engine counts as loading")

        scheduled.run()
        #expect(FakePage.made.count == 1, "Only the page still open attaches")
        let fake = try #require(FakePage.made.first)
        #expect(fake.loads == [url], "It loads what it was asked for while waiting")
        #expect(fake.profile.identifier == profileID)
        #expect(fake.view.superview === early.view)

        _ = engine.makePage(profileID: profileID)
        #expect(FakePage.made.count == 2, "Pages made once the engine is ready attach right away")
    }

    @Test func thePoolHearsThePagesEvents() throws {
        let scheduled = Scheduled()
        let engine = makeEngine(scheduled: scheduled)
        engine.start()
        scheduled.run()
        let pool = WebViewPool(engine: engine)
        var clicks: [LinkClick] = []
        var newTabs: [URL] = []
        pool.onLinkClick = { clicks.append($0); return true }
        pool.onOpenInNewTab = { url, _ in newTabs.append(url) }
        let tab = Tab(spaceID: UUID(), url: url, sortKey: SortKey.initial)

        pool.page(for: tab, profileID: profileID)
        let fake = try #require(FakePage.made.first)
        #expect(fake.loads == [url])
        fake.canGoBack = true
        fake.navigate(to: URL(string: "https://example.com/next")!, title: "Next")
        #expect(pool.state(for: tab.id)?.title == "Next")
        #expect(pool.state(for: tab.id)?.canGoBack == true)

        let link = URL(string: "https://elsewhere.example/")!
        let delegate = try #require(fake.delegate)
        #expect(delegate.page(fake, shouldHandleLinkTo: link, modifiers: [.command, .shift]))
        #expect(clicks.first?.modifiers == [.command, .shift])
        delegate.page(fake, wantsToOpenURLInNewTab: link)
        #expect(newTabs == [link])
    }

    @Test func permissionRequestsReachThePool() async throws {
        let scheduled = Scheduled()
        let engine = makeEngine(scheduled: scheduled)
        engine.start()
        scheduled.run()
        let pool = WebViewPool(engine: engine)
        pool.onPermissionRequest = { request in request.kind == .camera ? .allow : .deny }
        pool.page(for: Tab(spaceID: UUID(), url: url, sortKey: SortKey.initial), profileID: profileID)
        let fake = try #require(FakePage.made.first)
        let delegate = try #require(fake.delegate)

        let allowed = await withCheckedContinuation { continuation in
            delegate.page(fake, requestsPermission: .camera, origin: URL(string: "https://meet.example.com")!) { continuation.resume(returning: $0) }
        }
        #expect(allowed)
    }

    @Test func downloadsReportToThePoolsList() throws {
        let scheduled = Scheduled()
        let engine = makeEngine(scheduled: scheduled)
        engine.start()
        scheduled.run()
        let pool = WebViewPool(engine: engine, downloads: DownloadManager(directory: directory))
        let tab = Tab(spaceID: UUID(), url: url, sortKey: SortKey.initial)
        pool.page(for: tab, profileID: profileID)
        let fake = try #require(FakePage.made.first)
        let download = FakeDownload(sourceURL: URL(string: "https://example.com/report.pdf"))

        fake.delegate?.page(fake, didStart: download)
        let item = try #require(pool.downloads.items.first)
        #expect(item.sourceTabID == tab.id)
        let destination = try #require(download.observer?.download(download, destinationForSuggestedFilename: "report.pdf", expectedLength: 10))
        #expect(destination.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)

        let second = FakeDownload(sourceURL: nil)
        fake.delegate?.page(fake, didStart: second)
        pool.downloads.cancel(try #require(pool.downloads.items.first))
        #expect(second.isCancelled, "Cancelling in Axo cancels Chromium's download")

        // A download outlives its tab: the engine holds its observer weakly, so Axo must keep it.
        pool.discard(tab.id)
        download.observer?.download(download, didReceiveBytes: 5, ofTotal: 10)
        #expect(item.fractionCompleted == 0.5, "Progress still arrives after the tab closed")
        download.observer?.download(download, didFailWithMessage: "The network went away.")
        #expect(item.state == .failed("The network went away."))
        #expect(download.observer == nil, "The observer goes once the download ends")
    }

    @Test func hibernatedPagesWithoutSavedHistoryReloadTheirURL() async throws {
        let scheduled = Scheduled()
        let engine = makeEngine(scheduled: scheduled)
        engine.start()
        scheduled.run()
        let pool = WebViewPool(engine: engine)
        let tab = Tab(spaceID: UUID(), url: url, sortKey: SortKey.initial)
        pool.page(for: tab, profileID: profileID)
        let first = try #require(FakePage.made.first)

        #expect(await pool.hibernate(tab.id))
        #expect(first.isClosed)
        pool.page(for: tab, profileID: profileID)
        let woken = try #require(FakePage.made.last)
        #expect(woken !== first)
        #expect(woken.loads == [url], "Chromium doesn't save history yet, so it reloads the URL")
    }

    // MARK: Windows

    @Test func windowListsSentBeforeTheEngineIsReadyApplyOnceItIs() throws {
        let scheduled = Scheduled()
        let engine = makeEngine(scheduled: scheduled)
        engine.start()
        let first = engine.makePage(profileID: profileID), second = engine.makePage(profileID: profileID)
        engine.setWindowPages([second, first], active: first, profileID: profileID)
        #expect(FakeWindow.made.isEmpty)

        scheduled.run()
        let window = try #require(FakeWindow.made.first)
        #expect(window.profile.identifier == profileID)
        let pages = FakePage.made
        #expect(window.pages.map { ObjectIdentifier($0) } == [pages[1], pages[0]].map { ObjectIdentifier($0) })
        #expect(window.activePage === pages[0])

        engine.setWindowPages([first], active: nil, profileID: profileID)
        #expect(FakeWindow.made.count == 1, "One window per profile")
        #expect(window.pages.map { ObjectIdentifier($0) } == [ObjectIdentifier(pages[0])])
    }

    @Test func tabsChromeOpensClosesAndSelectsReachThePool() throws {
        let scheduled = Scheduled()
        let engine = makeEngine(scheduled: scheduled)
        engine.start()
        scheduled.run()
        let pool = WebViewPool(engine: engine)
        let tab = Tab(spaceID: UUID(), url: url, sortKey: SortKey.initial)
        pool.page(for: tab, profileID: profileID)
        pool.setWindowTabs([tab.id], selected: tab.id, profileID: profileID)
        let window = try #require(FakeWindow.made.first)
        var opened: [EngineOpenedPage] = []
        var closed: [Tab.ID] = [], activated: [Tab.ID] = []
        pool.onEngineOpenedPage = { opened.append($0) }
        pool.onEngineClosedTab = { closed.append($0) }
        pool.onEngineActivatedTab = { activated.append($0) }

        // An extension opens a tab: Chrome made its page, and Axo adopts it.
        let chromePage = FakePage(profile: FakeProfile.made[profileID]!)
        chromePage.url = URL(string: "https://example.com/opened")
        window.delegate?.window(window, didOpen: chromePage, at: 1)
        let event = try #require(opened.first)
        #expect(event.after == tab.id)
        #expect(event.profileID == profileID)
        let adopted = Tab(id: event.tabID, spaceID: tab.spaceID, url: chromePage.url!, sortKey: SortKey.initial)
        pool.adopt(event.page, as: adopted, profileID: profileID)
        #expect(pool.livePage(for: adopted.id)?.view.subviews.first === chromePage.view, "Its view is the page Chrome made")

        window.delegate?.window(window, didActivate: chromePage)
        #expect(activated == [adopted.id])

        window.delegate?.window(window, didClose: chromePage)
        #expect(closed == [adopted.id])
        #expect(!chromePage.isClosed, "Chrome already closed it")
    }

    // MARK: Extensions

    @Test func extensionsAndButtonsComeFromTheProfile() async throws {
        let scheduled = Scheduled()
        let engine = makeEngine(scheduled: scheduled)
        let page = engine.makePage(profileID: profileID)
        #expect(engine.extensions(profileID: profileID).isEmpty, "Nothing before the engine is ready")
        #expect(engine.toolbarButtons(profileID: profileID, page: page).isEmpty)

        engine.start()
        scheduled.run()
        let profile = try #require(FakeProfile.made[profileID])
        profile.extensions = [FakeExtension(identifier: "abc", name: "Blocker", isEnabled: false)]
        profile.actions = [FakeExtensionAction(extensionIdentifier: "abc", title: "Blocker", badgeText: "3")]

        #expect(engine.extensions(profileID: profileID) == [ChromiumExtension(id: "abc", name: "Blocker", version: "1.0", isEnabled: false, isUnpacked: true)])
        let button = try #require(engine.toolbarButtons(profileID: profileID, page: page).first)
        #expect(button.extensionID == "abc" && button.title == "Blocker" && button.badge == "3" && button.hasPopup)

        engine.setExtension("abc", enabled: true, profileID: profileID)
        engine.uninstallExtension("abc", profileID: profileID)
        #expect(profile.enabledChanges.map(\.0) == ["abc"] && profile.enabledChanges.map(\.1) == [true])
        #expect(profile.uninstalled == ["abc"])
    }

    @Test func clickingAButtonReturnsItsPopup() async throws {
        let scheduled = Scheduled()
        let engine = makeEngine(scheduled: scheduled)
        engine.start()
        scheduled.run()
        let page = engine.makePage(profileID: profileID)
        let profile = try #require(FakeProfile.made[profileID])
        let fakePopup = FakeExtensionPopup(extensionIdentifier: "abc")
        profile.nextPopup = fakePopup

        let popup = try #require(await engine.performExtensionAction("abc", profileID: profileID, page: page))
        let performed = try #require(profile.performed.first)
        #expect(performed.extensionID == "abc")
        #expect(performed.page === FakePage.made.first)
        #expect(performed.window === FakeWindow.made.first, "Against the profile's engine window")
        #expect(popup.view === fakePopup.view)

        var sizes: [NSSize] = []
        var closed = false
        popup.onResize = { sizes.append($0) }
        popup.onClose = { closed = true }
        fakePopup.onResize?(NSSize(width: 220, height: 120))
        fakePopup.onClose?()
        #expect(sizes == [NSSize(width: 220, height: 120)])
        #expect(closed)
        popup.close()
        #expect(fakePopup.isClosed)

        profile.nextPopup = nil
        #expect(await engine.performExtensionAction("abc", profileID: profileID, page: page) == nil, "No popup: the extension handled the click")
    }

    @Test func extensionChangesAreReportedPerProfile() throws {
        let scheduled = Scheduled()
        let engine = makeEngine(scheduled: scheduled)
        engine.start()
        scheduled.run()
        var changed: [Profile.ID] = []
        engine.onExtensionsChange = { changed.append($0) }
        _ = engine.extensions(profileID: profileID)

        FakeProfile.made[profileID]?.onExtensionsChange?()
        #expect(changed == [profileID])
    }

    @Test func bookmarksGoToTheEngineAndExtensionsChangesComeBack() throws {
        let scheduled = Scheduled()
        let engine = makeEngine(scheduled: scheduled)
        let space = UUID(), mail = UUID(), folder = UUID()
        let tree = BookmarkTree(
            bar: [BookmarkItem(id: mail, title: "Mail", url: url)],
            other: [BookmarkItem(id: space, title: "Home", children: [BookmarkItem(id: folder, title: "Team")])]
        )
        engine.setBookmarks(tree, profileID: profileID)
        engine.start()
        scheduled.run()
        engine.setBookmarks(tree, profileID: profileID)
        #expect(FakeProfile.made[profileID] == nil, "A profile nothing uses isn't loaded for its bookmarks")

        _ = engine.extensions(profileID: profileID)
        let profile = try #require(FakeProfile.made[profileID])
        #expect(profile.bookmarkSetCount == 1, "Its bookmarks arrive once it's in use")
        engine.setBookmarks(tree, profileID: profileID)
        #expect(profile.bookmarkSetCount == 2)
        #expect(profile.bookmarkBar.map(\.identifier) == [mail.uuidString.lowercased()])
        #expect(profile.bookmarkBar.first?.url == url)
        #expect(profile.otherBookmarks.first?.title == "Home")
        #expect(profile.otherBookmarks.first?.children.first?.url == nil, "A folder")

        var changes: [BookmarkChange] = []
        engine.onBookmarkChange = { change, id in
            #expect(id == profileID)
            changes.append(change)
        }
        let made = UUID()
        profile.onBookmarkChange?(FakeBookmarkChange(kind: .created, identifier: made.uuidString.lowercased(), parentIdentifier: folder.uuidString, index: 2, title: "Wiki", url: url))
        profile.onBookmarkChange?(FakeBookmarkChange(kind: .moved, identifier: mail.uuidString, parentRoot: .bar, index: 1))
        profile.onBookmarkChange?(FakeBookmarkChange(kind: .removed, identifier: space.uuidString, parentRoot: .other))
        profile.onBookmarkChange?(FakeBookmarkChange(kind: .removed, identifier: "not-a-uuid", parentRoot: .other))
        #expect(changes == [
            BookmarkChange(kind: .created, id: made, place: .inside(folder), index: 2, title: "Wiki", url: url),
            BookmarkChange(kind: .moved, id: mail, place: .bar, index: 1, title: "", url: nil),
            BookmarkChange(kind: .removed, id: space, place: .other, index: 0, title: "", url: nil),
        ], "Changes that name nothing Axo could have are dropped")
    }

    @Test func historyChangesComeBackFromTheEngine() throws {
        let scheduled = Scheduled()
        let engine = makeEngine(scheduled: scheduled)
        engine.start()
        scheduled.run()
        var changes: [ChromiumHistoryChange] = []
        engine.onHistoryChange = { change, id in
            #expect(id == profileID)
            changes.append(change)
        }
        _ = engine.extensions(profileID: profileID)
        let profile = try #require(FakeProfile.made[profileID])
        let date = Date(timeIntervalSince1970: 1_000)
        profile.onHistoryChange?(FakeHistoryChange(kind: .visited, urls: [url], title: "Added", date: date))
        profile.onHistoryChange?(FakeHistoryChange(kind: .deleted, urls: [url]))
        profile.onHistoryChange?(FakeHistoryChange(kind: .deletedAll))
        profile.onHistoryChange?(FakeHistoryChange(kind: .deleted, urls: [url], date: date, endDate: date.addingTimeInterval(60)))
        #expect(changes == [
            .visited(url, title: "Added", at: date), .deleted([url], in: nil), .deletedAll,
            .deleted([url], in: date...date.addingTimeInterval(60)),
        ])
    }

    @Test func profileDataGoesToTheEngine() async throws {
        let scheduled = Scheduled()
        let engine = makeEngine(scheduled: scheduled)
        await engine.clearWebsiteData(for: profileID)
        #expect(FakeProfile.made.isEmpty, "Nothing to clear when the engine never runs")

        // Clearing while the engine starts waits for it.
        engine.start()
        let clearing = Task { await engine.clearWebsiteData(for: profileID) }
        await Task.yield()
        scheduled.run()
        await clearing.value
        #expect(FakeProfile.made[profileID]?.clearCount == 1)
        await #expect(throws: FakeEngineError.self) { try await engine.removeWebsiteData(for: profileID) }
    }

    @Test func aRemovedProfileIsNeverLoadedAgain() async throws {
        let scheduled = Scheduled()
        let engine = makeEngine(scheduled: scheduled)
        engine.start()
        scheduled.run()
        let tree = BookmarkTree(bar: [], other: [])
        engine.setBookmarks(tree, profileID: profileID)
        _ = engine.extensions(profileID: profileID)
        #expect(FakeProfile.made[profileID] != nil)

        FakeProfile.removalError = nil
        try await engine.removeWebsiteData(for: profileID)
        #expect(FakeProfile.removed == [profileID])

        // Late calls for the profile, such as a bookmark send already on its way.
        engine.setBookmarks(tree, profileID: profileID)
        #expect(engine.extensions(profileID: profileID).isEmpty)
        await engine.clearWebsiteData(for: profileID)
        #expect(FakeProfile.made[profileID] == nil, "It isn't created again")
    }

    @Test func historyKindsAxoDoesntKnowAreIgnored() throws {
        let scheduled = Scheduled()
        let engine = makeEngine(scheduled: scheduled)
        engine.start()
        scheduled.run()
        var changes: [ChromiumHistoryChange] = []
        engine.onHistoryChange = { change, _ in changes.append(change) }
        _ = engine.extensions(profileID: profileID)
        let profile = try #require(FakeProfile.made[profileID])
        profile.onHistoryChange?(FakeHistoryChange(kind: AXOHistoryChangeKind(rawValue: 99)!, urls: [url]))
        profile.onHistoryChange?(FakeHistoryChange(kind: .visited))
        #expect(changes.isEmpty, "Never a deletion Axo didn't understand")
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { error } else { nil }
    }
}

extension FakeEngine {
    /// The fake classes as the engine's class set.
    static var classes: ChromiumEngineClasses {
        ChromiumEngineClasses(engine: FakeAXOEngine.self, configuration: FakeConfiguration.self, profile: FakeProfile.self, page: FakePage.self, window: FakeWindow.self)
    }
}
