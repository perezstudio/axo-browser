//
//  SoftwareUpdatesTests.swift
//  AxoTests
//

import AxoUI
import Foundation
import Sparkle
import Testing
@testable import Axo

/// The app's side of software updates (#180): which updater a launch gets, the feed override,
/// and Sparkle's answers and errors in Axo's terms. Nothing here starts Sparkle.
@MainActor
struct SoftwareUpdatesTests {
    @Test func testRunsGetTheStandInWhateverTheBuild() {
        for debug in [true, false] {
            for key in [true, false] {
                #expect(UpdaterKind.forLaunch(isTestRun: true, isDebugBuild: debug, hasPublicKey: key, hasLocalFeed: true) == .standIn)
            }
        }
    }

    @Test func releaseBuildsUpdateOnlyWithThePublicKey() {
        #expect(UpdaterKind.forLaunch(isTestRun: false, isDebugBuild: false, hasPublicKey: true, hasLocalFeed: false) == .sparkle)
        #expect(UpdaterKind.forLaunch(isTestRun: false, isDebugBuild: false, hasPublicKey: false, hasLocalFeed: true) == .none)
    }

    @Test func debugBuildsUpdateOnlyFromAFeedOnThisMac() {
        #expect(UpdaterKind.forLaunch(isTestRun: false, isDebugBuild: true, hasPublicKey: true, hasLocalFeed: false) == .none,
                "A development build never replaces itself with a release")
        #expect(UpdaterKind.forLaunch(isTestRun: false, isDebugBuild: true, hasPublicKey: true, hasLocalFeed: true) == .sparkle)
    }

    @Test(arguments: [
        ("http://127.0.0.1:8000/appcast.xml", true),
        ("http://localhost:8000/appcast.xml", true),
        ("https://LOCALHOST/appcast.xml", true),
        ("http://[::1]:8000/appcast.xml", true),
        ("http://127.1.2.3/appcast.xml", true),
        ("https://example.com/appcast.xml", false),
        ("http://127.0.0.1.example.com/appcast.xml", false),
        ("http://localhost.example.com/appcast.xml", false),
        ("http://127.0.0.256/appcast.xml", false),
        ("file:///tmp/appcast.xml", false),
        ("ftp://127.0.0.1/appcast.xml", false),
        ("not a url", false),
    ])
    func theFeedCanOnlyBePointedAtThisMac(value: String, allowed: Bool) {
        #expect((SparkleUpdater.feedOverride(value) != nil) == allowed)
    }

    @Test func noOverrideWithoutAValue() {
        #expect(SparkleUpdater.feedOverride(nil) == nil)
    }

    @Test func choicesMapToSparkles() {
        #expect(SparkleUserDriver.sparkleChoice(.install) == .install)
        #expect(SparkleUserDriver.sparkleChoice(.skip) == .skip)
        #expect(SparkleUserDriver.sparkleChoice(.later) == .dismiss, "Later is Sparkle's dismiss: a downloaded update installs on quit")
    }

    @Test(arguments: [
        (SparkleErrors.domain, 1002, SoftwareUpdate.Failure.couldNotCheck),
        (SparkleErrors.domain, 1000, .couldNotCheck),
        (NSURLErrorDomain, NSURLErrorNotConnectedToInternet, .couldNotCheck),
        (SparkleErrors.domain, 2001, .couldNotDownload),
        (SparkleErrors.domain, 3001, .couldNotVerify),
        (SparkleErrors.domain, 4009, .couldNotVerify),
        (SparkleErrors.domain, 4005, .couldNotInstall),
        ("SomeOtherDomain", 1, .other("Described")),
        (SparkleErrors.domain, 9999, .other("Described")),
    ])
    func errorsMapToFailures(domain: String, code: Int, failure: SoftwareUpdate.Failure) {
        #expect(SparkleErrors.failure(domain: domain, code: code, description: "Described") == failure)
    }

    @Test func sparklesErrorDomainIsTheOneItUses() {
        #expect(SparkleErrors.domain == SUSparkleErrorDomain)
    }

    @Test func runningFromTheDiskImageSaysToMoveAxo() {
        guard case .other(let message) = SparkleErrors.failure(domain: SparkleErrors.domain, code: 1003, description: "") else {
            Issue.record("Not explained"); return
        }
        #expect(message.contains("Applications"))
    }

    @Test func noUpdateReasonsFollowSparklesCodes() {
        #expect(SparkleErrors.noUpdateReason(code: Int(SPUNoUpdateFoundReason.onLatestVersion.rawValue), latestVersion: nil, minimumSystem: nil) == .onLatestVersion)
        #expect(SparkleErrors.noUpdateReason(code: Int(SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue), latestVersion: nil, minimumSystem: nil) == .newerThanLatest)
        #expect(SparkleErrors.noUpdateReason(code: Int(SPUNoUpdateFoundReason.systemIsTooOld.rawValue), latestVersion: "2.0", minimumSystem: "28.0")
                == .systemTooOld(version: "2.0", minimumSystem: "28.0"))
        #expect(SparkleErrors.noUpdateReason(code: Int(SPUNoUpdateFoundReason.systemIsTooNew.rawValue), latestVersion: "2.0", minimumSystem: nil) == .systemTooNew(version: "2.0"))
        #expect(SparkleErrors.noUpdateReason(code: Int(SPUNoUpdateFoundReason.hardwareDoesNotSupportARM64.rawValue), latestVersion: "2.0", minimumSystem: nil) == .unsupportedHardware(version: "2.0"))
        #expect(SparkleErrors.noUpdateReason(code: nil, latestVersion: nil, minimumSystem: nil) == .onLatestVersion)
    }

    @Test func theAppCarriesTheFeedAndAutomaticChecks() {
        let info = Bundle.main.infoDictionary ?? [:]
        #expect(info["SUFeedURL"] as? String == "https://perezstudio.github.io/axo-browser/appcast.xml")
        #expect(info["SUEnableAutomaticChecks"] as? Bool == true, "So Sparkle never asks with its own prompt")
    }

    @Test func theStandInNeverReachesTheNetworkAndWalksAnUpdate() async throws {
        let standIn = StandInSoftwareUpdater(offersUpdate: true)
        let update = SoftwareUpdate(currentVersion: "1.0", updater: standIn)
        standIn.update = update
        #expect(update.canCheckForUpdates)
        update.checkForUpdates()
        #expect(update.phase == .checking)
        try await waitUntil { if case .found = update.phase { true } else { false } }
        update.install()
        try await waitUntil { update.phase == .readyToInstall }
        update.install()
        #expect(update.phase == .idle)
        #expect(update.canCheckForUpdates)

        standIn.downloadInBackground()
        update.restartToUpdate()
        #expect(standIn.restartRequests == 1)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
        #expect(condition())
    }
}
