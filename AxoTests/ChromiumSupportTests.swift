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

    @Test func nativeMessagingUsesChromesHostFoldersOutsideUITests() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        #expect(ChromiumSupport.nativeMessagingHostFolders(isUITesting: false, home: home).map(\.path) == [
            "/Users/someone/Library/Application Support/Google/Chrome/NativeMessagingHosts",
            "/Library/Google/Chrome/NativeMessagingHosts",
        ])
        #expect(ChromiumSupport.nativeMessagingHostFolders(isUITesting: true, home: home).isEmpty, "UI tests never start real hosts")
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

    private static let chromeEntitlements = [
        "com.apple.security.device.audio-input", "com.apple.security.device.bluetooth", "com.apple.security.device.camera",
        "com.apple.security.device.print", "com.apple.security.device.usb", "com.apple.security.personal-information.location",
        "com.apple.security.personal-information.photos-library",
    ]

    /// Axo is signed with Chrome's app entitlements (`chrome/app/app-entitlements.plist`).
    @Test func axoHasChromesAppEntitlements() throws {
        let task = try #require(SecTaskCreateFromSelf(nil))
        for key in Self.chromeEntitlements {
            let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil) as? Bool
            #expect(value == true, "\(key) is missing")
        }
    }

    /// Release builds (signed with `Axo-Release.entitlements`) have them too, and otherwise match
    /// Debug's file except for iCloud and push notifications. The test host is a Debug build, so
    /// this reads the files themselves.
    @Test func bothEntitlementsFilesMatch() throws {
        let folder = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Axo")
        func keys(_ name: String) throws -> [String: Any] {
            let data = try Data(contentsOf: folder.appending(path: name))
            return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        }
        let debug = try keys("Axo.entitlements"), release = try keys("Axo-Release.entitlements")
        for key in Self.chromeEntitlements {
            #expect(release[key] as? Bool == true, "Release is missing \(key)")
        }
        let releaseOnly: Set<String> = [
            "com.apple.developer.icloud-container-identifiers", "com.apple.developer.icloud-services",
            "com.apple.developer.aps-environment", "aps-environment",
        ]
        #expect(Set(release.keys).subtracting(releaseOnly) == Set(debug.keys), "The other keys are the same")
    }

    @Test func uiTestsUseOneTemporaryEngineFolder() {
        let testing = ChromiumSupport.userDataDirectory(isUITesting: true)
        #expect(testing == ChromiumSupport.userDataDirectory(isUITesting: true), "The same folder each launch, emptied first")
        #expect(testing.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(ChromiumSupport.userDataDirectory(isUITesting: false).path.hasSuffix("Axo/Chromium"))
    }
}
