//
//  ChromiumSupportTests.swift
//  AxoTests
//

import Foundation
import Testing
@testable import Axo

/// The Chromium engine's debug setting.
@MainActor
struct ChromiumSupportTests {
    let settings: UserDefaults
    let suiteName = "AxoTests.ChromiumSupport.\(UUID().uuidString)"

    init() {
        settings = UserDefaults(suiteName: suiteName)!
    }

    @Test func theSettingTurnsTheEngineOn() {
        #expect(!ChromiumSupport.isRequested(in: settings, isUITesting: false, environment: [:]), "Off by default")
        settings.set(true, forKey: ChromiumSupport.settingKey)
        #expect(ChromiumSupport.isRequested(in: settings, isUITesting: false, environment: [:]))
        settings.removePersistentDomain(forName: suiteName)
    }

    @Test func uiTestsUseChromiumOnlyWhenTheyOptIn() {
        settings.set(true, forKey: ChromiumSupport.settingKey)
        #expect(!ChromiumSupport.isRequested(in: settings, isUITesting: true, environment: [:]), "The person's setting never reaches UI tests")
        #expect(ChromiumSupport.isRequested(in: settings, isUITesting: true, environment: [ChromiumSupport.uiTestingKey: "1"]))
        settings.removePersistentDomain(forName: suiteName)
    }

    @Test func testsRunOnWebKit() {
        // Unit tests launch Axo without the setting, so no engine loads.
        #expect(ChromiumSupport.classes == nil)
    }
}
