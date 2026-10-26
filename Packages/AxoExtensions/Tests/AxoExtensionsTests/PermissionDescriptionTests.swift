import Testing
@testable import AxoExtensions

struct PermissionDescriptionTests {
    @Test(arguments: ["<all_urls>", "*://*/*", "https://*/*"])
    func allSitesPatternsSayAllWebsites(pattern: String) {
        #expect(PermissionDescriptions.lines(permissions: [], matchPatterns: [pattern]) == ["Read and change your data on all websites"])
    }

    @Test func specificSitesAreNamedUpToThree() {
        #expect(PermissionDescriptions.siteLine(for: ["*://*.github.com/*", "https://example.com/*"])
            == "Read and change your data on example.com, github.com")
        #expect(PermissionDescriptions.siteLine(for: ["*://a.com/*", "*://b.com/*", "*://c.com/*", "*://d.com/*", "*://e.com/*"])
            == "Read and change your data on a.com, b.com, c.com and 2 more")
        #expect(PermissionDescriptions.siteLine(for: []) == nil)
    }

    @Test func significantPermissionsComeFirstAndQuietOnesAreLeftOut() {
        let lines = PermissionDescriptions.lines(permissions: ["storage", "alarms", "tabs", "nativeMessaging"], matchPatterns: [])
        #expect(lines == ["Talk to apps installed on this Mac", "See your open tabs and their addresses"])
    }

    @Test func chromeOnlyPermissionsAreDescribed() {
        let lines = PermissionDescriptions.lines(permissions: ["history", "debugger", "bookmarks"], matchPatterns: ["<all_urls>"])
        #expect(lines == [
            "Read and change your data on all websites",
            "Control your tabs with developer tools, including what they load and send",
            "Read and change your browsing history",
            "Read and change your favorites and pinned tabs",
        ])
    }

    @Test func permissionsWithoutADescriptionAreStillListed() {
        let lines = PermissionDescriptions.lines(permissions: ["storage", "someNewAPI", "anotherAPI"], matchPatterns: [])
        #expect(lines == ["Use “anotherAPI”", "Use “someNewAPI”"], "A prompt never hides a permission")
    }
}
