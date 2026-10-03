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
    var installed: [ExtensionSummary] = []

    struct Failure: Error, LocalizedError {
        var errorDescription: String? { "The signature doesn't match." }
    }

    func prepareInstall(from url: URL, profileID: Profile.ID) async throws -> ExtensionInstallPrompt {
        if failInstall { throw Failure() }
        return prompt
    }

    func confirmInstall(_ extensionID: String, profileID: Profile.ID) async throws { confirmed.append(extensionID) }
    func uninstall(_ extensionID: String, profileID: Profile.ID) async throws { uninstalled.append(extensionID) }
    func installedExtensions(profileID: Profile.ID) async -> [ExtensionSummary] { installed }
    func setEnabled(_ enabled: Bool, extensionID: String, profileID: Profile.ID) async throws {}
    func setReachesAllRequestedSites(_ all: Bool, extensionID: String, profileID: Profile.ID) async throws {}
    func inspectBackgroundPage(_ extensionID: String, profileID: Profile.ID) async -> Bool { true }
}

@MainActor
struct ExtensionManagementTests {
    let model: BrowserModel
    let fake = FakeExtensionManagement()
    let file = URL(fileURLWithPath: "/tmp/notes.crx")

    init() async throws {
        model = BrowserModel(store: try TabStore.makeInMemory(), pool: WebViewPool(makeDataStore: { _ in .nonPersistent() }))
        model.extensionManagement = fake
        await model.start()
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
