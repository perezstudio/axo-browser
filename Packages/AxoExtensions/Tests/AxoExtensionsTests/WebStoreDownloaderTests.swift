import AxoCRX
import AxoCore
import AxoExtensionsTestSupport
import AxoWeb
import Foundation
import Testing
@testable import AxoExtensions

/// The Chrome Web Store download, with a fake fetch: tests never use the network.
struct WebStoreDownloaderTests {
    private static func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://clients2.google.com/")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    @Test func downloadURLsUseChromesUpdateService() throws {
        let url = try #require(WebStoreDownloader.downloadURL(for: "ddkjiahejlhfcafbddmgiahcphecmpfh"))
        #expect(url.host() == "clients2.google.com" && url.path() == "/service/update2/crx")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "acceptformat" }?.value == "crx3")
        #expect(items.first { $0.name == "x" }?.value == "id=ddkjiahejlhfcafbddmgiahcphecmpfh&uc")
        #expect(WebStoreDownloader.downloadURL(for: "../etc") == nil)
        #expect(WebStoreDownloader.downloadURL(for: "ZZKJIAHEJLHFCAFBDDMGIAHCPHECMPFH") == nil)
    }

    @Test func aMatchingSignedPackageDownloads() async throws {
        let crx = try CRXBuilder().build(zip: sampleExtensionZip(name: "Packed"))
        let id = try CRXPackage(crx).extensionID
        let downloader = WebStoreDownloader { _ in (crx, Self.response(200)) }
        #expect(try await downloader.download(id) == crx)
    }

    @Test func anotherExtensionOrAFailedDownloadIsRefused() async throws {
        let crx = try CRXBuilder().build(zip: sampleExtensionZip(name: "Packed"))
        let other = String(repeating: "a", count: 32)
        await #expect(throws: WebStoreError.unexpectedExtension(requested: other, received: try CRXPackage(crx).extensionID)) {
            try await WebStoreDownloader { _ in (crx, Self.response(200)) }.download(other)
        }
        await #expect(throws: WebStoreError.downloadFailed(status: 404)) {
            try await WebStoreDownloader { _ in (Data(), Self.response(404)) }.download(other)
        }
        await #expect(throws: WebStoreError.invalidExtensionID("nope")) {
            try await WebStoreDownloader { _ in Issue.record("Fetched an invalid ID"); return (Data(), Self.response(200)) }.download("nope")
        }
        await #expect(throws: (any Error).self, "Not a CRX at all") {
            try await WebStoreDownloader { _ in (Data("<html>".utf8), Self.response(200)) }.download(other)
        }
    }

    @Test @MainActor func theManagerPreparesAStoreInstall() async throws {
        let store = try TabStore.makeInMemory()
        let profileID = try await store.bootstrap().profileID
        let manager = ExtensionManager(installer: ExtensionInstaller(root: temporaryFolder()), store: store.extensions,
                                       pool: WebViewPool(makeDataStore: { _ in .nonPersistent() }), persistent: false)
        let crx = try CRXBuilder().build(zip: sampleExtensionZip(name: "From the Store"))
        let id = try CRXPackage(crx).extensionID
        manager.webStore = WebStoreDownloader { _ in (crx, Self.response(200)) }

        let summary = try await manager.prepareWebStoreInstall(id, for: profileID)
        #expect(summary.extensionID == id && summary.name == "From the Store" && !summary.isUnpacked)
        #expect(try await store.extensions.record(id, profileID: profileID)?.isEnabled == false, "Saved turned off until confirmed")
    }
}
