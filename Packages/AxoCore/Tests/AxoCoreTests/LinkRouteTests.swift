import Foundation
import Testing
@testable import AxoCore

struct LinkRouteTests {
    let store: TabStore
    let routes: LinkRouteStore
    let home: Space

    init() async throws {
        store = try TabStore.makeInMemory()
        home = try await store.bootstrap()
        routes = store.linkRoutes
    }

    @Test(arguments: [
        ("github.com", "github.com"),
        ("  GitHub.com ", "github.com"),
        ("https://www.github.com/axo/issues", "github.com"),
        (".docs.example.com", "docs.example.com"),
        ("localhost:3000", "localhost:3000"),
        ("www.example.com/path", "example.com"),
    ])
    func domainsAreNormalized(text: String, domain: String) {
        #expect(LinkRoute.normalizedDomain(from: text) == domain)
    }

    @Test(arguments: ["", "   ", "not a domain", "exa mple.com", "https://"])
    func nonDomainsAreRejected(text: String) {
        #expect(LinkRoute.normalizedDomain(from: text) == nil)
    }

    @Test func domainRulesWinAndTheMostSpecificDomainWins() {
        let (work, docs, chat) = (UUID(), UUID(), UUID())
        let rules = [
            LinkRoute(kind: .domain, value: "example.com", spaceID: work),
            LinkRoute(kind: .domain, value: "docs.example.com", spaceID: docs),
            LinkRoute(kind: .app, value: "com.tinyspeck.slackmacgap", spaceID: chat),
        ]
        func space(_ address: String, from app: String? = nil) -> UUID? {
            LinkRoute.route(for: URL(string: address)!, from: app, in: rules)?.spaceID
        }
        #expect(space("https://example.com/a") == work)
        #expect(space("https://api.example.com/") == work, "Subdomains match")
        #expect(space("https://docs.example.com/x") == docs)
        #expect(space("https://notexample.com/") == nil, "Only whole labels match")
        #expect(space("https://swift.org/", from: "com.tinyspeck.slackmacgap") == chat)
        #expect(space("https://example.com/", from: "com.tinyspeck.slackmacgap") == work, "A domain rule beats an app rule")
        #expect(space("https://swift.org/", from: "com.apple.mail") == nil)
    }

    @Test func rulesAreSavedChangedAndDeleted() async throws {
        let work = try await store.createSpace(name: "Work", profileID: home.profileID)
        let rule = try await routes.add(.domain, value: "github.com", spaceID: home.id)
        let app = try await routes.add(.app, value: "com.apple.mail", displayName: "Mail", spaceID: home.id)
        #expect(try await routes.routes().map(\.value) == ["github.com", "com.apple.mail"])

        await #expect(throws: LinkRouteError.duplicate) {
            try await routes.add(.domain, value: "github.com", spaceID: work.id)
        }
        try await routes.setSpace(work.id, for: rule.id)
        #expect(try await routes.routes().first?.spaceID == work.id)

        try await routes.delete(app.id)
        #expect(try await routes.routes().count == 1)

        // Deleting a Space deletes its rules.
        try await store.deleteSpace(id: work.id)
        #expect(try await routes.routes().isEmpty)
    }

    @Test func rulesNeedAnExistingSpace() async throws {
        let missing = UUID()
        await #expect(throws: TabStoreError.spaceNotFound(missing)) {
            try await routes.add(.domain, value: "github.com", spaceID: missing)
        }
    }
}
