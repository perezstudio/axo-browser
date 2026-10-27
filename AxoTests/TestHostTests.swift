//
//  TestHostTests.swift
//  AxoTests
//

import AxoCore
import AxoPersistence
import AxoUI
import Foundation
import GRDB
import Testing
@testable import Axo

/// These tests host in Axo, which launches the browser before they run. That launch must never
/// touch the person's real data, as in UI testing mode.
@MainActor
struct TestHostTests {
    @Test func uiTestingAndHostedUnitTestsAreTestRuns() {
        #expect(!AppEnvironment.isTestRun(isUITesting: false, environment: [:]))
        #expect(AppEnvironment.isTestRun(isUITesting: true, environment: [:]))
        #expect(AppEnvironment.isTestRun(isUITesting: false, environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]))
        #expect(AppEnvironment.isTestRun, "These tests host in Axo")
    }

    @Test func hostingTestsNeverOpensTheOnDiskDatabase() async throws {
        let store = try #require(await launchedStore(), "The test host launched the browser")
        let path = store.database.writer.path
        #expect(path == ":memory:", "Opened \(path)")
        #expect(path != AppEnvironment.databaseURL.path)
    }

    @Test func hostingTestsSkipsSystemIntegrations() async throws {
        try #require(await launchedStore() != nil)
        #expect(AppEnvironment.spotlightIndexer == nil, "Test data never reaches Spotlight")
        #expect(AppEnvironment.iCloudSync?.status == .unavailable, "Test runs never sync")
        #expect(AppEnvironment.settings !== UserDefaults.standard, "Test runs keep their settings apart")
        let realExtensions = URL.applicationSupportDirectory.appending(path: "Axo/Extensions").standardizedFileURL.path
        #expect(!AppEnvironment.extensionsFolder.standardizedFileURL.path.hasPrefix(realExtensions))
    }

    /// The store the app opened at launch. SwiftUI makes the model while the app launches, so
    /// this waits for it rather than assume it's there.
    private func launchedStore() async -> TabStore? {
        let deadline = Date.now.addingTimeInterval(10)
        while AppEnvironment.store == nil, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return AppEnvironment.store
    }
}
