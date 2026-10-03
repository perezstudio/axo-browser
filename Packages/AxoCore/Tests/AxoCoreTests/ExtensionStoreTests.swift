import Foundation
import Testing
@testable import AxoCore

struct ExtensionStoreTests {
    let store: TabStore
    let profileID: Profile.ID

    init() async throws {
        store = try TabStore.makeInMemory()
        profileID = try await store.bootstrap().profileID
    }

    private func record(_ id: String, name: String, version: String = "1.0") -> WebExtensionRecord {
        WebExtensionRecord(profileID: profileID, extensionID: id, name: name, version: version, folderPath: "/tmp/\(id)", isUnpacked: false)
    }

    @Test func savedExtensionsListByNameAndKeepTheirStateOnUpdate() async throws {
        let extensions = store.extensions
        try await extensions.save(record("b", name: "uBlock"))
        try await extensions.save(record("a", name: "Bitwarden"))
        try await extensions.setEnabled(false, extensionID: "b", profileID: profileID)

        try await extensions.save(record("b", name: "uBlock", version: "2.0"))

        let listed = try await extensions.extensions(for: profileID)
        #expect(listed.map(\.name) == ["Bitwarden", "uBlock"])
        #expect(listed.last?.version == "2.0")
        #expect(listed.last?.isEnabled == false, "Updating doesn't turn a disabled extension back on")
    }

    @Test func removingAndProfileIsolation() async throws {
        let extensions = store.extensions
        try await extensions.save(record("a", name: "One"))
        let other = try await store.createProfile(name: "Work")

        #expect(try await extensions.extensions(for: other.id).isEmpty)
        #expect(try await extensions.record("a", profileID: profileID)?.folder.path == "/tmp/a")

        try await extensions.remove("a", profileID: profileID)
        #expect(try await extensions.record("a", profileID: profileID) == nil)
    }

    @Test func siteAccessAndApprovalsPersistAndSurviveUpdates() async throws {
        let extensions = store.extensions
        try await extensions.save(record("a", name: "One"))
        try await extensions.setSiteAccess(.click, extensionID: "a", profileID: profileID)
        try await extensions.addGrantedOptional(["cookies", "*://*.example.com/*"], extensionID: "a", profileID: profileID)
        try await extensions.addGrantedOptional(["cookies"], extensionID: "a", profileID: profileID)

        try await extensions.save(record("a", name: "One", version: "2.0"))

        let saved = try #require(try await extensions.record("a", profileID: profileID))
        #expect(saved.version == "2.0")
        #expect(saved.siteAccess == .click)
        #expect(saved.grantedOptional == ["*://*.example.com/*", "cookies"])
    }
}
