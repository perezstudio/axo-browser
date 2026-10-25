//
//  ChromiumSupportTests.swift
//  AxoTests
//

import Foundation
import Security
import Testing
@testable import Axo

/// The Mac's Chromium engine: when it's used, and what Axo declares for it.
@MainActor
struct ChromiumSupportTests {
    @Test func macLaunchesAlwaysRunOnChromium() {
        #expect(ChromiumSupport.isRequired(isUITesting: false, environment: [:]), "No setting and no WebKit fallback")
    }

    @Test func testRunsUseWebKitUnlessTheyOptIn() {
        #expect(!ChromiumSupport.isRequired(isUITesting: false, environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]), "Unit tests host in Axo and never start the engine")
        #expect(!ChromiumSupport.isRequired(isUITesting: true, environment: [:]))
        #expect(ChromiumSupport.isRequired(isUITesting: true, environment: [ChromiumSupport.uiTestingKey: "1"]))
    }

    @Test func unitTestsRunOnWebKit() {
        #expect(ChromiumSupport.classes == nil)
    }

    @Test func theLaunchFailureSaysWhyAndWhatToDo() {
        let message = ChromiumSupport.launchFailureMessage(reason: "The Chromium engine isn't in this build of Axo.")
        #expect(message.hasPrefix("The Chromium engine isn't in this build of Axo."))
        #expect(message.contains("Reinstall Axo"))
    }

    /// Chromium runs in Axo's process, so macOS kills Axo when the engine reaches a device whose
    /// usage description is missing (it checks Bluetooth at startup). These are the keys Chrome
    /// declares beyond the ones WebKit needed.
    @Test func infoPlistDescribesEveryDeviceChromiumUses() {
        for key in [
            "NSBluetoothAlwaysUsageDescription", "NSBluetoothPeripheralUsageDescription", "NSAudioCaptureUsageDescription",
            "NSWebBrowserPublicKeyCredentialUsageDescription", "NSCameraUsageDescription", "NSMicrophoneUsageDescription",
            "NSLocationUsageDescription", "NSLocalNetworkUsageDescription",
        ] {
            let description = Bundle.main.object(forInfoDictionaryKey: key) as? String
            #expect(description?.isEmpty == false, "\(key) is missing")
        }
    }

    /// Axo is signed with Chrome's app entitlements (`chrome/app/app-entitlements.plist`).
    @Test func axoHasChromesAppEntitlements() throws {
        let task = try #require(SecTaskCreateFromSelf(nil))
        for key in [
            "com.apple.security.device.audio-input", "com.apple.security.device.bluetooth", "com.apple.security.device.camera",
            "com.apple.security.device.print", "com.apple.security.device.usb", "com.apple.security.personal-information.location",
            "com.apple.security.personal-information.photos-library",
        ] {
            let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil) as? Bool
            #expect(value == true, "\(key) is missing")
        }
    }
}
