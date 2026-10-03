import AxoCore
import Foundation
import Testing
import WebKit
@testable import AxoWeb

@MainActor
struct PagePromptTests {
    let pages: TestPages
    let pool = WebViewPool.forTesting()
    let profileID = UUID()

    init() throws {
        pages = try TestPages()
    }

    private func loadedTab(_ title: String = "Prompts", body: String = "") async throws -> (Tab, WKWebView) {
        let tab = Tab.testTab(url: try pages.page(title, body: body))
        let webView = pool.webView(for: tab, profileID: profileID)
        try await waitUntil("page \(title)") {
            pool.state(for: tab.id).map { !$0.isLoading && $0.title == title } ?? false
        }
        return (tab, webView)
    }

    private func run(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await webView.callAsyncJavaScript(script, contentWorld: .page)
    }

    // MARK: JavaScript dialogs

    @Test func alertsReachTheHandlerWithTheirOrigin() async throws {
        let (tab, webView) = try await loadedTab()
        var dialogs: [JavaScriptDialog] = []
        pool.onJavaScriptDialog = { dialogs.append($0); return JavaScriptDialogResult(accepted: true) }

        _ = try await run("alert('Saved!')", in: webView)

        #expect(dialogs.count == 1)
        #expect(dialogs.first?.message == "Saved!")
        #expect(dialogs.first?.kind == .alert)
        #expect(dialogs.first?.tabID == tab.id)
        #expect(dialogs.first?.origin.scheme == "file")
    }

    @Test func confirmReturnsTheAnswer() async throws {
        let (_, webView) = try await loadedTab()
        pool.onJavaScriptDialog = { dialog in JavaScriptDialogResult(accepted: dialog.message == "Delete?") }

        #expect(try await run("return confirm('Delete?')", in: webView) as? Bool == true)
        #expect(try await run("return confirm('Something else?')", in: webView) as? Bool == false)
    }

    @Test func promptReturnsTheTextOrNullWhenCancelled() async throws {
        let (_, webView) = try await loadedTab()
        var defaults: [String] = []
        pool.onJavaScriptDialog = { dialog in
            if case .prompt(let defaultText) = dialog.kind { defaults.append(defaultText) }
            return dialog.message == "Name?" ? JavaScriptDialogResult(accepted: true, text: "Axo") : .cancelled
        }

        #expect(try await run("return prompt('Name?', 'Your name')", in: webView) as? String == "Axo")
        #expect(try await run("return prompt('Other?') === null", in: webView) as? Bool == true)
        #expect(defaults == ["Your name", ""])
    }

    @Test func withoutAHandlerDialogsAreCancelled() async throws {
        let (_, webView) = try await loadedTab()
        #expect(try await run("return confirm('Sure?')", in: webView) as? Bool == false)
        #expect(try await run("return prompt('Name?') === null", in: webView) as? Bool == true)
    }

    // MARK: File uploads

    @Test func fileInputsGetTheChosenFiles() async throws {
        let (tab, webView) = try await loadedTab(body: "<input id='file' type='file' multiple>")
        let upload = pages.directory.appending(path: "upload.txt")
        try "hello".write(to: upload, atomically: true, encoding: .utf8)
        var requests: [FileSelectionRequest] = []
        pool.onFileSelection = { requests.append($0); return [upload] }

        _ = try await run("document.getElementById('file').click()", in: webView)
        try await waitUntil("file chosen") { !requests.isEmpty }
        let name = try await waitForValue {
            try await self.run("return document.getElementById('file').files[0]?.name ?? ''", in: webView) as? String
        }

        #expect(name == "upload.txt")
        #expect(requests.first?.allowsMultipleSelection == true)
        #expect(requests.first?.tabID == tab.id)
    }

    // MARK: Permissions

    @Test func answersAreRememberedPerProfileOriginAndKind() async {
        var asked = 0
        pool.onPermissionRequest = { _ in asked += 1; return .allow }
        let meet = PageOrigin(scheme: "https", host: "meet.example.com")
        let other = PageOrigin(scheme: "https", host: "other.example.com")
        let tab = UUID(), secondProfile = UUID()

        #expect(await pool.decidePermission(.camera, origin: meet, tabID: tab, profileID: profileID) == .allow)
        #expect(await pool.decidePermission(.camera, origin: meet, tabID: tab, profileID: profileID) == .allow)
        #expect(asked == 1, "The second request uses the remembered answer")

        _ = await pool.decidePermission(.microphone, origin: meet, tabID: tab, profileID: profileID)
        _ = await pool.decidePermission(.camera, origin: other, tabID: tab, profileID: profileID)
        _ = await pool.decidePermission(.camera, origin: meet, tabID: tab, profileID: secondProfile)
        #expect(asked == 4, "Kind, origin, and profile each need their own answer")
        #expect(pool.rememberedPermission(.camera, origin: meet, profileID: profileID) == .allow)

        pool.forgetPermissionDecisions()
        #expect(pool.rememberedPermission(.camera, origin: meet, profileID: profileID) == nil)
    }

    @Test func aPermissionStoreKeepsAnswersInsteadOfMemory() async {
        let store = FakePermissionStore()
        pool.permissionStore = store
        var asked = 0
        pool.onPermissionRequest = { _ in asked += 1; return .deny }
        let meet = PageOrigin(scheme: "https", host: "meet.example.com")

        #expect(await pool.decidePermission(.camera, origin: meet, tabID: UUID(), profileID: profileID) == .deny)
        #expect(store.saved[meet.serialized + "/camera"] == .deny, "The answer is saved in the store")
        #expect(pool.rememberedPermission(.camera, origin: meet, profileID: profileID) == nil, "Not in memory")

        store.saved[meet.serialized + "/camera"] = .allow
        #expect(await pool.decidePermission(.camera, origin: meet, tabID: UUID(), profileID: profileID) == .allow)
        #expect(asked == 1, "A saved answer is used without asking")

        store.saved.removeAll()
        _ = await pool.decidePermission(.camera, origin: meet, tabID: UUID(), profileID: profileID)
        #expect(asked == 2, "Forgetting a saved answer asks again")
    }

    @Test func originsComeFromWebURLs() throws {
        #expect(PageOrigin(url: URL(string: "https://Meet.Example.com/room?x=1")!)?.serialized == "https://meet.example.com")
        #expect(PageOrigin(url: URL(string: "https://example.com:443/")!)?.serialized == "https://example.com")
        #expect(PageOrigin(url: URL(string: "http://localhost:3000/")!)?.serialized == "http://localhost:3000")
        #expect(PageOrigin(url: URL(string: "file:///tmp/page.html")!) == nil)
        #expect(PageOrigin(url: URL(string: "about:blank")!) == nil)
    }

    @Test func withoutAHandlerPermissionsAreDeniedAndNotRemembered() async {
        let origin = PageOrigin(scheme: "https", host: "example.com")
        #expect(await pool.decidePermission(.location, origin: origin, tabID: UUID(), profileID: profileID) == .deny)
        #expect(pool.rememberedPermission(.location, origin: origin, profileID: profileID) == nil)
    }

    @Test func originsNameThemselvesForPeople() {
        #expect(PageOrigin(scheme: "HTTPS", host: "Meet.Example.com").displayName == "meet.example.com")
        #expect(PageOrigin(scheme: "http", host: "localhost", port: 3000).displayName == "localhost:3000")
        #expect(PageOrigin(scheme: "file", host: "").displayName == "This page")
    }
}

/// Polls an async value until it's non-nil and non-empty, or fails after 10 seconds.
@MainActor
func waitForValue(_ value: () async throws -> String?) async throws -> String {
    let deadline = ContinuousClock.now + .seconds(10)
    while true {
        if let result = try await value(), !result.isEmpty { return result }
        guard ContinuousClock.now < deadline else { throw TimeoutError(description: "Timed out waiting for value") }
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// A permission store that keeps answers in a dictionary keyed by "origin/kind".
@MainActor
final class FakePermissionStore: PermissionDecisionStore {
    var saved: [String: PermissionDecision] = [:]

    func savedDecision(for kind: PermissionKind, origin: PageOrigin, profileID: Profile.ID) async -> PermissionDecision? {
        saved[origin.serialized + "/" + kind.rawValue]
    }

    func saveDecision(_ decision: PermissionDecision, for kind: PermissionKind, origin: PageOrigin, profileID: Profile.ID) async {
        saved[origin.serialized + "/" + kind.rawValue] = decision
    }
}
