import AxoCore
import AxoWebTestSupport
import Foundation
import Testing
@testable import AxoWeb

/// Pages' File System Access pickers, on engines that leave their panels to Axo (Chromium): each
/// reaches the pool as a file selection request for the page's tab.
@MainActor
struct FilePanelTests {
    let engine = FakeEngine()
    let pool: WebViewPool
    let profileID = UUID()
    let tab = Tab.testTab(url: URL(string: "https://example.com/")!)
    let first = URL(filePath: "/tmp/one.txt")
    let second = URL(filePath: "/tmp/two.txt")

    init() {
        pool = WebViewPool.withFakeEngine(engine)
    }

    private func page() throws -> FakePage {
        pool.page(for: tab, profileID: profileID)
        return try #require(engine.pages.last)
    }

    @Test func aSavePickerAsksWhereToSave() async throws {
        let page = try page()
        var requests: [FileSelectionRequest] = []
        pool.onFileSelection = { requests.append($0); return [first] }
        let folder = URL(filePath: "/tmp", directoryHint: .isDirectory)

        let chosen = await page.showFilePanel(FilePanel(kind: .save, suggestedName: "notes.txt", directory: folder, allowedExtensions: ["txt", "md"]))
        #expect(chosen == [first])
        #expect(requests == [FileSelectionRequest(
            tabID: tab.id, kind: .save, allowsMultipleSelection: false, allowsDirectories: false,
            suggestedName: "notes.txt", directory: folder, allowedExtensions: ["txt", "md"]
        )])
    }

    @Test func openPickersChooseFilesOrAFolder() async throws {
        let page = try page()
        var requests: [FileSelectionRequest] = []
        pool.onFileSelection = { requests.append($0); return [first, second] }

        #expect(await page.showFilePanel(FilePanel(kind: .openFiles, allowedExtensions: ["png"])) == [first, second])
        #expect(await page.showFilePanel(FilePanel(kind: .openFile, suggestedName: "ignored")) == [first], "One file for a picker that wants one")
        #expect(await page.showFilePanel(FilePanel(kind: .folder, allowedExtensions: ["png"])) == [first])

        #expect(requests.map(\.kind) == [.open, .open, .open])
        #expect(requests.map(\.allowsMultipleSelection) == [true, false, false])
        #expect(requests.map(\.allowsFiles) == [true, true, false], "A folder picker chooses only folders")
        #expect(requests.map(\.allowsDirectories) == [false, false, true])
        #expect(requests[0].allowedExtensions == ["png"])
        #expect(requests[1].suggestedName == nil, "A name is only for saving")
        #expect(requests[2].allowedExtensions.isEmpty, "Folders have no file types")
        #expect(requests.allSatisfy { $0.tabID == tab.id })
    }

    @Test func cancellingOrNobodyToAskAnswersNothing() async throws {
        let page = try page()
        #expect(await page.showFilePanel(FilePanel(kind: .save)) == nil, "No handler: cancelled")

        pool.onFileSelection = { _ in nil }
        #expect(await page.showFilePanel(FilePanel(kind: .openFile)) == nil)
    }

    @Test func theEngineGivingUpOnAPanelReachesThePool() throws {
        let page = try page()
        var dismissed: [Tab.ID] = []
        pool.onFileSelectionDismissed = { dismissed.append($0) }

        page.dismissFilePanel()
        #expect(dismissed == [tab.id])
    }

    @Test func fileAccessQuestionsAskForThePagesTab() async throws {
        let page = try page()
        var requests: [FileAccessRequest] = []
        pool.onFileAccess = { requests.append($0); return true }
        let site = PageOrigin(scheme: "https", host: "editor.example.com")

        #expect(await page.askAboutFileAccess(FileAccessQuestion(kind: .edit, url: URL(filePath: "/tmp/notes.txt"), isDirectory: false, origin: site)) == true)
        #expect(await page.askAboutFileAccess(FileAccessQuestion(kind: .restricted, url: nil, isDirectory: true, origin: site)) == true)
        #expect(requests == [
            FileAccessRequest(tabID: tab.id, origin: site, kind: .edit, name: "notes.txt", isDirectory: false),
            FileAccessRequest(tabID: tab.id, origin: site, kind: .restricted, name: nil, isDirectory: true),
        ])
    }

    @Test func fileAccessHasNoAnswerWithNobodyToAsk() async throws {
        let page = try page()
        let site = PageOrigin(scheme: "https", host: "editor.example.com")
        let question = FileAccessQuestion(kind: .view, url: nil, isDirectory: true, origin: site)
        #expect(await page.askAboutFileAccess(question) == nil, "Not a refusal, which the engine would remember")

        pool.onFileAccess = { _ in false }
        #expect(await page.askAboutFileAccess(question) == false)
    }
}
