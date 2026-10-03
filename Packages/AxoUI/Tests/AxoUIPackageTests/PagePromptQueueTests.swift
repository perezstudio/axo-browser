import AxoCore
import AxoWeb
import Foundation
import Testing
@testable import AxoUI

@MainActor
struct PagePromptQueueTests {
    let model: BrowserModel
    let pool: WebViewPool

    init() throws {
        pool = WebViewPool(makeDataStore: { _ in .nonPersistent() })
        model = BrowserModel(store: try TabStore.makeInMemory(), pool: pool)
    }

    private let origin = PageOrigin(scheme: "https", host: "example.com")

    private func dialog(_ message: String, tab: UUID = UUID(), kind: JavaScriptDialog.Kind = .alert) -> JavaScriptDialog {
        JavaScriptDialog(tabID: tab, origin: origin, message: message, kind: kind)
    }

    @Test func dialogsWaitForAnAnswerAndShowOneAtATime() async throws {
        let first = Task { await pool.onJavaScriptDialog!(dialog("first", kind: .confirm)) }
        let second = Task { await pool.onJavaScriptDialog!(dialog("second", kind: .prompt(defaultText: "x"))) }
        try await waitUntil { model.currentPrompt != nil }
        try await Task.sleep(for: .milliseconds(50))

        guard case .dialog(let shown) = model.currentPrompt?.content else { Issue.record("Expected a dialog"); return }
        #expect(shown.message == "first", "Prompts show in arrival order")

        model.answerDialog(JavaScriptDialogResult(accepted: true))
        #expect(await first.value.accepted)
        guard case .dialog(let next) = model.currentPrompt?.content else { Issue.record("Expected the second dialog"); return }
        #expect(next.message == "second")

        model.answerDialog(JavaScriptDialogResult(accepted: true, text: "typed"))
        #expect(await second.value.text == "typed")
        #expect(model.currentPrompt == nil)
    }

    @Test func permissionRequestsReturnTheAnswer() async throws {
        let request = PermissionRequest(tabID: UUID(), origin: origin, kind: .camera)
        let answer = Task { await pool.onPermissionRequest!(request) }
        try await waitUntil { model.currentPrompt != nil }

        model.answerDialog(.cancelled)
        #expect(model.currentPrompt != nil, "A dialog answer doesn't answer a permission request")

        model.answerPermission(.allow)
        #expect(await answer.value == .allow)
        #expect(model.currentPrompt == nil)
    }

    @Test func closingATabDismissesItsPrompts() async throws {
        await model.start()
        let url = FileManager.default.temporaryDirectory.appending(path: "prompt-\(UUID().uuidString).html")
        try "<title>p</title>".write(to: url, atomically: true, encoding: .utf8)
        await model.openTab(url: url)
        let tabID = try #require(model.selectedTabID)
        let other = UUID()

        let fromTab = Task { await pool.onPermissionRequest!(PermissionRequest(tabID: tabID, origin: origin, kind: .microphone)) }
        try await waitUntil { model.currentPrompt != nil }
        let fromOther = Task { await pool.onJavaScriptDialog!(dialog("stay", tab: other)) }
        try await Task.sleep(for: .milliseconds(50))

        await model.closeTab(tabID)

        #expect(await fromTab.value == .deny)
        guard case .dialog(let remaining) = model.currentPrompt?.content else { Issue.record("Expected the other tab's dialog"); return }
        #expect(remaining.message == "stay")
        model.answerDialog(.cancelled)
        _ = await fromOther.value
    }
}
