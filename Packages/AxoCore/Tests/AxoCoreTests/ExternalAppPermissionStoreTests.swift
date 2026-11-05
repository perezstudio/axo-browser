import Foundation
import Testing
@testable import AxoCore

struct ExternalAppPermissionStoreTests {
    let store: TabStore
    let permissions: ExternalAppPermissionStore
    let profileID: Profile.ID
    let zoom = "https://example.zoom.us"

    init() async throws {
        store = try TabStore.makeInMemory()
        profileID = try await store.bootstrap().profileID
        permissions = store.externalAppPermissions
    }

    @Test func aSiteIsAllowedPerSchemeUntilForgotten() async throws {
        #expect(try await permissions.isAllowed(scheme: "zoommtg", origin: zoom, profileID: profileID) == false)

        try await permissions.allow(scheme: "ZoomMtg", origin: zoom, profileID: profileID)
        try await permissions.allow(scheme: "mailto", origin: zoom, profileID: profileID)
        try await permissions.allow(scheme: "zoommtg", origin: zoom, profileID: profileID)
        #expect(try await permissions.isAllowed(scheme: "zoommtg", origin: zoom, profileID: profileID), "Schemes ignore case")
        #expect(try await permissions.schemes(origin: zoom, profileID: profileID) == ["mailto", "zoommtg"], "Once each, sorted")
        #expect(try await permissions.isAllowed(scheme: "slack", origin: zoom, profileID: profileID) == false)
        #expect(try await permissions.isAllowed(scheme: "zoommtg", origin: "https://other.example.com", profileID: profileID) == false)

        try await permissions.forget(scheme: "ZOOMMTG", origin: zoom, profileID: profileID)
        #expect(try await permissions.schemes(origin: zoom, profileID: profileID) == ["mailto"])
        try await permissions.reset(origin: zoom, profileID: profileID)
        #expect(try await permissions.schemes(origin: zoom, profileID: profileID).isEmpty)
    }

    @Test func profilesDontShareThem() async throws {
        let work = try await store.createProfile(name: "Work")
        try await permissions.allow(scheme: "zoommtg", origin: zoom, profileID: work.id)
        #expect(try await permissions.isAllowed(scheme: "zoommtg", origin: zoom, profileID: profileID) == false)
        #expect(try await permissions.isAllowed(scheme: "zoommtg", origin: zoom, profileID: work.id))
    }
}
