import AxoCRX
import AxoCore
import AxoExtensionsTestSupport
import AxoWeb
import Foundation
import Testing
import WebKit
@testable import AxoExtensions

/// Checks against real extensions from the Chrome Web Store. The `.crx` files aren't in the repo
/// (they're GPL-licensed and large), so these run only when `AXO_REAL_EXTENSIONS` points at a
/// folder with `ubol.crx` (uBlock Origin Lite) and `bitwarden.crx` (Bitwarden). See the
/// AxoExtensions README for how to download them.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["AXO_REAL_EXTENSIONS"] != nil, "Set AXO_REAL_EXTENSIONS to run"))
struct RealExtensionTests {
    struct Sample: Sendable, CustomTestStringConvertible {
        var file: String
        var chromeID: String
        var testDescription: String { file }
    }

    nonisolated static let samples = [
        Sample(file: "ubol.crx", chromeID: "ddkjiahejlhfcafbddmgiahcphecmpfh"),
        Sample(file: "bitwarden.crx", chromeID: "nngceckbapebfimnlniiiahkandclblb"),
    ]

    private func data(for sample: Sample) throws -> Data {
        let folder = try #require(ProcessInfo.processInfo.environment["AXO_REAL_EXTENSIONS"])
        return try Data(contentsOf: URL(fileURLWithPath: folder).appending(path: sample.file))
    }

    @Test(arguments: samples)
    func webStorePackagesVerifyAndGetTheirChromeIDs(sample: Sample) throws {
        let package = try CRXPackage(try data(for: sample))
        #expect(package.extensionID == sample.chromeID)
    }

    @Test(arguments: samples)
    func webStoreExtensionsInstallAndLoad(sample: Sample) async throws {
        let store = try TabStore.makeInMemory()
        let profileID = try await store.bootstrap().profileID
        let pool = WebViewPool(makeDataStore: { _ in .nonPersistent() })
        let manager = ExtensionManager(installer: ExtensionInstaller(root: temporaryFolder()), store: store.extensions, pool: pool, persistent: false)

        progress("installing \(sample.file)")
        let record = try await manager.install(crx: try data(for: sample), for: profileID)
        progress("installed \(record.extensionID)")
        let context = try #require(manager.context(for: record.extensionID, profileID: profileID), "\(manager.loadErrors)")
        let webExtension = context.webExtension

        if webExtension.hasBackgroundContent {
            progress("loading background content")
            let outcome = await backgroundLoadOutcome(context, timeout: .seconds(20))
            progress("background: \(outcome)")
            #expect(outcome == "loaded", "Background content loads")
            try await Task.sleep(for: .seconds(2))
        }

        print("""
        REAL EXTENSION \(sample.file)
          name: \(webExtension.displayName ?? "-") \(webExtension.version ?? "-") (MV\(webExtension.manifestVersion))
          id: \(record.extensionID)
          permissions: \(webExtension.requestedPermissions.map(\.rawValue).sorted())
          optional: \(webExtension.optionalPermissions.map(\.rawValue).sorted())
          host patterns: \(webExtension.allRequestedMatchPatterns.count)
          background: \(webExtension.hasBackgroundContent), content rules: \(context.webExtension.hasContentModificationRules), injected content: \(context.hasInjectedContent)
          described: \(ExtensionManager.describe(webExtension))
          errors: \(context.errors.map(\.localizedDescription))
        """)
        #expect(record.extensionID == sample.chromeID)
    }

    /// Writes a progress line to standard error right away, so a hang shows where it stopped.
    private func progress(_ message: String) {
        FileHandle.standardError.write(Data("REAL EXTENSION PROGRESS \(message)\n".utf8))
    }

    /// Loads the background content, giving up after `timeout` instead of hanging the suite.
    private func backgroundLoadOutcome(_ context: WKWebExtensionContext, timeout: Duration) async -> String {
        var outcome: String?
        let load = Task {
            do {
                try await context.loadBackgroundContent()
                outcome = "loaded"
            } catch {
                outcome = "error: \(error.localizedDescription)"
            }
        }
        let deadline = ContinuousClock.now + timeout
        while outcome == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if outcome == nil { load.cancel() }
        return outcome ?? "timed out after \(timeout)"
    }
}
