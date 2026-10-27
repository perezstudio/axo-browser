//
//  TestHostTests.swift
//  AxoTests
//

import AxoCore
import AxoPersistence
import AxoUI
import AxoWeb
import Foundation
import GRDB
import Testing
import WebKit
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
    }

    @Test func hostingTestsSkipsSystemIntegrations() async throws {
        let store = try #require(await launchedStore())
        let model = try #require(AppEnvironment.browserModel)
        #expect(model.defaultBrowser == nil, "Nothing in a test run offers to change the default browser")
        #expect(model.locationAuthorization == nil, "Test runs never show macOS's location prompt")
        #expect(model.onSpaceChange == nil, "Test runs never remember the Space shown")
        #expect(!model.isHandoffEnabled, "Test pages never reach the person's other devices")
        #expect(!model.pool.reportsScreenTimeUsage, "Test pages never count as Screen Time usage")
        let profileID = try await store.bootstrap().profileID
        #expect(!model.pool.dataStore(for: profileID).isPersistent, "Test runs never use the person's website data")
        #expect(AppEnvironment.spotlightIndexer == nil, "Test data never reaches Spotlight")
        #expect(AppEnvironment.settings !== UserDefaults.standard, "Test runs keep their settings apart")
        let realExtensions = URL.applicationSupportDirectory.appending(path: "Axo/Extensions").standardizedFileURL.path
        #expect(!AppEnvironment.extensionsFolder.standardizedFileURL.path.hasPrefix(realExtensions))
    }

    @Test func testRunsNeverSyncWithICloud() {
        #expect(AppEnvironment.syncsWithICloud(isTestRun: false, isEntitled: true))
        #expect(!AppEnvironment.syncsWithICloud(isTestRun: true, isEntitled: true), "Even in a build signed for iCloud")
        #expect(!AppEnvironment.syncsWithICloud(isTestRun: false, isEntitled: false))
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
