import Foundation
import Testing
@testable import AxoCore

struct SitePermissionStoreTests {
    let store: TabStore
    let permissions: SitePermissionStore
    let profileID: Profile.ID
    let meet = "https://meet.example.com"

    init() async throws {
        store = try TabStore.makeInMemory()
        profileID = try await store.bootstrap().profileID
        permissions = store.sitePermissions
    }

    @Test func answersAreSavedPerKindAndCanBeChanged() async throws {
        #expect(try await permissions.decision(.camera, origin: meet, profileID: profileID) == nil)

        try await permissions.setDecision(.allow, for: [.camera, .microphone], origin: meet, profileID: profileID)
        #expect(try await permissions.decision(.camera, origin: meet, profileID: profileID) == .allow)
        #expect(try await permissions.decisions(origin: meet, profileID: profileID) == [.camera: .allow, .microphone: .allow])

        try await permissions.setDecision(.deny, for: [.camera], origin: meet, profileID: profileID)
        try await permissions.setDecision(nil, for: [.microphone], origin: meet, profileID: profileID)
        #expect(try await permissions.decisions(origin: meet, profileID: profileID) == [.camera: .deny], "nil means ask again")
    }

    @Test func answersBelongToOneSiteAndProfile() async throws {
        let other = try await store.createProfile(name: "Work")
        try await permissions.setDecision(.allow, for: [.location], origin: meet, profileID: profileID)

        #expect(try await permissions.decision(.location, origin: meet, profileID: other.id) == nil)
        #expect(try await permissions.decision(.location, origin: "https://meet.example.com:8443", profileID: profileID) == nil)
    }

    @Test func resettingASiteForgetsEverything() async throws {
        try await permissions.setDecision(.deny, for: Set(SitePermission.Kind.allCases), origin: meet, profileID: profileID)
        try await permissions.setDecision(.allow, for: [.camera], origin: "https://other.example.com", profileID: profileID)
        try await permissions.reset(origin: meet, profileID: profileID)

        #expect(try await permissions.decisions(origin: meet, profileID: profileID).isEmpty)
        #expect(try await permissions.decisions(origin: "https://other.example.com", profileID: profileID) == [.camera: .allow])
    }
}
