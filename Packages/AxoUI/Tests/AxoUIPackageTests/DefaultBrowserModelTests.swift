import AxoCore
import AxoWeb
import Foundation
import Testing
@testable import AxoUI

/// A default-browser setting that never touches the system.
@MainActor
final class FakeDefaultBrowser: DefaultBrowserSetting {
    var isDefault = false
    var accepts = true
    var requests = 0

    func makeDefault() async throws {
        requests += 1
        struct Declined: Error {}
        guard accepts else { throw Declined() }
        isDefault = true
    }
}

@MainActor
struct DefaultBrowserModelTests {
    let model: BrowserModel
    let fake = FakeDefaultBrowser()
    let directory: URL

    init() async throws {
        model = BrowserModel(store: try TabStore.makeInMemory(), pool: WebViewPool(makeDataStore: { _ in .nonPersistent() }))
        directory = FileManager.default.temporaryDirectory
            .appending(path: "AxoDefaultTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func page(_ name: String) throws -> URL {
        let url = directory.appending(path: "\(name).html")
        try "<title>\(name)</title>".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func statusIsUnknownWithoutASettingAndCheckedWithOne() {
        #expect(model.isDefaultBrowser == nil)
        model.defaultBrowser = fake
        #expect(model.isDefaultBrowser == false)
        fake.isDefault = true
        model.refreshDefaultBrowserStatus()
        #expect(model.isDefaultBrowser == true)
    }

    @Test func acceptingMakesAxoDefaultAndHidesTheAction() async {
        await model.start()
        model.defaultBrowser = fake
        model.showCommandBar()
        #expect(model.availableActions.contains(.makeDefaultBrowser))

        await model.makeDefaultBrowser()

        #expect(fake.requests == 1)
        #expect(model.isDefaultBrowser == true)
        #expect(!model.availableActions.contains(.makeDefaultBrowser))
        #expect(model.alertMessage == nil)
    }

    @Test func decliningChangesNothingAndShowsNoError() async {
        fake.accepts = false
        model.defaultBrowser = fake
        await model.makeDefaultBrowser()
        #expect(model.isDefaultBrowser == false)
        #expect(model.alertMessage == nil)
    }

    @Test func linksFromOtherAppsOpenInANewTab() async throws {
        await model.start()
        await model.openTab(url: try page("existing"))
        model.showCommandBar()

        await model.openExternalURL(try page("from-mail"))

        #expect(model.tabs.map { $0.url.lastPathComponent } == ["existing.html", "from-mail.html"])
        #expect(model.selectedTab?.url.lastPathComponent == "from-mail.html")
        #expect(!model.isCommandBarVisible)
    }

    @Test func linksThatArriveDuringLaunchOpenOnceReady() async throws {
        await model.openExternalURL(try page("early"))
        #expect(model.tabs.isEmpty)

        await model.start()

        #expect(model.tabs.map { $0.url.lastPathComponent } == ["early.html"])
        #expect(model.selectedTab?.url.lastPathComponent == "early.html")
    }
}
