import Foundation
import Testing
@testable import AxoCore

struct SiteCustomizationTests {
    let store: SiteCustomizationStore

    init() throws {
        store = try TabStore.makeInMemory().siteCustomizations
    }

    @Test func theMostSpecificEnabledDomainApplies() {
        let all = [
            SiteCustomization(domain: "example.com", css: "a"),
            SiteCustomization(domain: "docs.example.com", css: "b"),
            SiteCustomization(domain: "off.example.com", css: "c", isEnabled: false),
        ]
        #expect(SiteCustomization.best(forHost: "example.com", in: all)?.css == "a")
        #expect(SiteCustomization.best(forHost: "WWW.example.com", in: all)?.css == "a", "Subdomains count")
        #expect(SiteCustomization.best(forHost: "api.docs.example.com", in: all)?.css == "b")
        #expect(SiteCustomization.best(forHost: "off.example.com", in: all)?.css == "a", "A turned-off one is skipped")
        #expect(SiteCustomization.best(forHost: "notexample.com", in: all) == nil)
    }

    @Test func customizationsAreSavedEditedTurnedOffAndDeleted() async throws {
        let saved = try await store.save(SiteCustomization(domain: "https://www.Example.com/news", css: "body { color: red }"))
        #expect(saved.domain == "example.com")

        var edited = saved
        edited.js = "console.log('hi')"
        try await store.save(edited)
        #expect(try await store.all().map(\.js) == ["console.log('hi')"])

        try await store.setEnabled(false, id: saved.id)
        #expect(try await store.all().first?.isEnabled == false)

        try await store.delete(saved.id)
        #expect(try await store.all().isEmpty)
    }

    @Test func domainsMustBeValidAndUnique() async throws {
        await #expect(throws: SiteCustomizationError.invalidDomain("not a domain")) {
            try await store.save(SiteCustomization(domain: "not a domain"))
        }
        try await store.save(SiteCustomization(domain: "example.com"))
        await #expect(throws: SiteCustomizationError.duplicate("example.com")) {
            try await store.save(SiteCustomization(domain: "www.example.com"))
        }
    }
}
