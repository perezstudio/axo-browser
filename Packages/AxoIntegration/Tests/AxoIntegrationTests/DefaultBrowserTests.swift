import Foundation
import Testing
@testable import AxoIntegration

@MainActor
struct DefaultBrowserTests {
    let axo = URL(fileURLWithPath: "/Applications/Axo.app")
    let safari = URL(fileURLWithPath: "/Applications/Safari.app")

    @Test func isDefaultOnlyWhenAxoHandlesBothSchemes() {
        func browser(http: URL?, https: URL?) -> DefaultBrowser {
            DefaultBrowser(
                appURL: axo,
                handlerForScheme: { $0 == "http" ? http : https },
                setHandler: { _, _ in Issue.record("Checking must not change anything") },
                setHTMLHandler: { _ in Issue.record("Checking must not change anything") }
            )
        }
        #expect(browser(http: axo, https: axo).isDefault)
        #expect(!browser(http: axo, https: safari).isDefault)
        #expect(!browser(http: safari, https: safari).isDefault)
        #expect(!browser(http: nil, https: nil).isDefault)
    }

    @Test func makingAxoDefaultSetsBothSchemesAndHTML() async throws {
        var schemes: [String] = []
        var html = 0
        let browser = DefaultBrowser(
            appURL: axo,
            handlerForScheme: { _ in nil },
            setHandler: { app, scheme in
                #expect(app == self.axo)
                schemes.append(scheme)
            },
            setHTMLHandler: { _ in html += 1 }
        )

        try await browser.makeDefault()

        #expect(schemes == ["http", "https"])
        #expect(html == 1)
    }

    @Test func aDeclinedChangeThrows() async {
        struct Declined: Error {}
        let browser = DefaultBrowser(
            appURL: axo,
            handlerForScheme: { _ in nil },
            setHandler: { _, _ in throw Declined() },
            setHTMLHandler: { _ in }
        )
        await #expect(throws: Declined.self) { try await browser.makeDefault() }
    }

    @Test func htmlFailuresDoNotUndoTheBrowserChange() async throws {
        struct NoHTML: Error {}
        let browser = DefaultBrowser(
            appURL: axo,
            handlerForScheme: { _ in nil },
            setHandler: { _, _ in },
            setHTMLHandler: { _ in throw NoHTML() }
        )
        try await browser.makeDefault()
    }

    @Test func sameAppComparesResolvedPathsForNonBundles() {
        let same = DefaultBrowser.isSameApp(URL(fileURLWithPath: "/tmp/Axo.app/"))
        #expect(same(URL(fileURLWithPath: "/tmp/./Axo.app")))
        #expect(!same(URL(fileURLWithPath: "/tmp/Other.app")))
    }
}
