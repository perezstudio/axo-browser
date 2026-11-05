#if os(macOS)
import AppKit
#endif
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

        #expect(await fromTab.value == nil, "No answer, so nothing is saved")
        guard case .dialog(let remaining) = model.currentPrompt?.content else { Issue.record("Expected the other tab's dialog"); return }
        #expect(remaining.message == "stay")
        model.answerDialog(.cancelled)
        _ = await fromOther.value
    }

    @Test func fileAccessQuestionsReturnTheAnswer() async throws {
        let request = FileAccessRequest(tabID: UUID(), origin: origin, kind: .edit, name: "notes.txt", isDirectory: false)
        let allowed = Task { await pool.onFileAccess!(request) }
        try await waitUntil { model.currentPrompt != nil }
        guard case .fileAccess(let shown) = model.currentPrompt?.content else { Issue.record("Expected a file access question"); return }
        #expect(shown == request)

        model.answerPermission(.allow)
        model.answerDialog(JavaScriptDialogResult(accepted: true))
        #expect(model.currentPrompt != nil, "Other answers don't answer it")
        model.answerFileAccess(true)
        #expect(await allowed.value == true)

        let refused = Task { await pool.onFileAccess!(request) }
        try await waitUntil { model.currentPrompt != nil }
        model.answerFileAccess(false)
        #expect(await refused.value == false)
    }

    @Test func aPageGoingToAnotherSiteDropsItsAccessQuestions() async throws {
        let tabID = UUID()
        let editor = PageOrigin(scheme: "https", host: "editor.example.com")
        let ask = { (kind: FileAccessRequest.Kind) in
            Task { await pool.onFileAccess!(FileAccessRequest(tabID: tabID, origin: editor, kind: kind, name: "notes.txt", isDirectory: false)) }
        }
        var editAnswers: [Bool?] = []
        Task { editAnswers.append(await ask(.edit).value) }
        try await waitUntil { model.currentPrompt != nil }
        let dangerous = ask(.dangerousFile)
        let otherTab = Task { await pool.onFileAccess!(FileAccessRequest(tabID: UUID(), origin: editor, kind: .view, name: nil, isDirectory: true)) }
        try await Task.sleep(for: .milliseconds(50))

        pool.onPageChange?(tabID, URL(string: "https://editor.example.com/other")!, "Same site")
        guard case .fileAccess(let stillShown) = model.currentPrompt?.content else { Issue.record("Expected the edit question"); return }
        #expect(stillShown.kind == .edit, "The same site keeps its question")

        pool.onPageChange?(tabID, URL(string: "https://elsewhere.example.org/")!, "Elsewhere")
        try await waitUntil { editAnswers.count == 1 }
        #expect(editAnswers == [nil], "Another site mustn't get the editor's access")
        guard case .fileAccess(let next) = model.currentPrompt?.content else { Issue.record("Expected the next question"); return }
        #expect(next.kind == .dangerousFile, "A question about the pick stays: Chrome checks it again")
        model.answerFileAccess(false)
        #expect(await dangerous.value == false)
        model.answerFileAccess(true)
        #expect(await otherTab.value == true, "Another tab's question stays")
    }

    #if os(macOS)
    @Test func closingATabDropsItsFileAccessQuestionsAndClosesItsPanels() async throws {
        let tabID = UUID()
        let panel = NSSavePanel()
        var closed: [NSSavePanel] = []
        model.openFilePanels.close = { closed.append($0) }
        model.openFilePanels.begin(panel, for: tabID)
        let question = Task { await pool.onFileAccess!(FileAccessRequest(tabID: tabID, origin: origin, kind: .view, name: "Photos", isDirectory: true)) }
        try await waitUntil { model.currentPrompt != nil }

        model.prompts.dismissAll(from: tabID)
        #expect(await question.value == nil, "No answer, so nothing is recorded")
        #expect(closed == [panel])
        #expect(model.currentPrompt == nil)
    }

    @Test func aPanelThePageGaveUpOnCloses() {
        let tabID = UUID()
        let panel = NSOpenPanel()
        var closed: [NSSavePanel] = []
        model.openFilePanels.close = { closed.append($0) }
        model.openFilePanels.begin(panel, for: tabID)

        pool.onFileSelectionDismissed?(tabID)
        #expect(closed == [panel])
    }
    #endif
}
