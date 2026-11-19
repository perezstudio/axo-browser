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

    @Test func notificationAndClipboardAnswersAreListedForTheEngine() async throws {
        let news = "https://news.example.com"
        let other = try await store.createProfile(name: "Work")
        try await permissions.setDecision(.allow, for: [.notifications], origin: news, profileID: profileID)
        try await permissions.setDecision(.deny, for: [.clipboard, .camera], origin: meet, profileID: other.id)

        let listed = try await permissions.all([.notifications, .clipboard])
        #expect(Set(listed.map { "\($0.kind.rawValue) \($0.origin) \($0.decision.rawValue)" }) == [
            "notifications \(news) allow",
            "clipboard \(meet) deny",
        ], "Every profile's, and only the kinds asked for")
        #expect(listed.first { $0.kind == .clipboard }?.profileID == other.id)
    }

    @Test func aNewerVersionsKindsDontHideTheOthers() async throws {
        try await permissions.setDecision(.allow, for: [.camera], origin: meet, profileID: profileID)
        try await store.database.writer.write { db in
            try db.execute(sql: "INSERT INTO sitePermission (profileID, origin, kind, decision, updatedAt) VALUES (?, ?, 'midi', 'allow', ?)",
                           arguments: [profileID, meet, Date()])
        }
        #expect(try await permissions.decisions(origin: meet, profileID: profileID) == [.camera: .allow])
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

    /// Settings' Website Permissions pane (#133): every site's answer for a kind, removing them
    /// all, and defaults, each profile its own.
    @Test func eachKindListsItsSitesAndCanBeClearedInOneProfile() async throws {
        let news = "https://news.example.com"
        let other = try await store.createProfile(name: "Work")
        try await permissions.setDecision(.allow, for: [.camera], origin: news, profileID: profileID)
        try await permissions.setDecision(.deny, for: [.camera, .microphone], origin: meet, profileID: profileID)
        try await permissions.setDecision(.allow, for: [.camera], origin: meet, profileID: other.id)

        let camera = try await permissions.permissions(.camera, profileID: profileID)
        #expect(camera.map(\.origin) == [meet, news], "By origin, this profile's only")
        #expect(camera.map(\.decision) == [.deny, .allow])

        let removed = try await permissions.removeAll(.camera, profileID: profileID)
        #expect(Set(removed) == [meet, news])
        #expect(try await permissions.permissions(.camera, profileID: profileID).isEmpty)
        #expect(try await permissions.decision(.microphone, origin: meet, profileID: profileID) == .deny, "Other kinds stay")
        #expect(try await permissions.decision(.camera, origin: meet, profileID: other.id) == .allow, "Other profiles stay")
    }

    @Test func defaultsArePerProfileAndKindAndAskWithoutOne() async throws {
        let other = try await store.createProfile(name: "Work")
        #expect(try await permissions.defaults(profileID: profileID).isEmpty, "Ask by default")

        try await permissions.setDefault(.deny, for: .camera, profileID: profileID)
        try await permissions.setDefault(.allow, for: .notifications, profileID: profileID)
        try await permissions.setDefault(.deny, for: .camera, profileID: profileID)
        #expect(try await permissions.defaults(profileID: profileID) == [.camera: .deny, .notifications: .allow])
        #expect(try await permissions.defaults(profileID: other.id).isEmpty)
        let lasting = try await permissions.allDefaults([.notifications, .clipboard])
        #expect(lasting.count == 1 && lasting.first?.kind == .notifications && lasting.first?.profileID == profileID)

        try await permissions.setDefault(nil, for: .camera, profileID: profileID)
        #expect(try await permissions.defaults(profileID: profileID) == [.notifications: .allow])
    }

    @Test func thePaneSeesEveryChange() async throws {
        var changes = permissions.observe(profileID: profileID).makeAsyncIterator()
        #expect(try await changes.next() == SitePermissionSnapshot(answers: [], defaults: [:]))
        try await permissions.setDefault(.deny, for: .location, profileID: profileID)
        var snapshot = try await changes.next()
        while snapshot?.defaults.isEmpty == true { snapshot = try await changes.next() }
        #expect(snapshot?.defaults == [.location: .deny])
        try await permissions.setDecision(.allow, for: [.location], origin: meet, profileID: profileID)
        snapshot = try await changes.next()
        while snapshot?.answers.isEmpty == true { snapshot = try await changes.next() }
        #expect(snapshot?.answers.map(\.origin) == [meet])
    }
}
