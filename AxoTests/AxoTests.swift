//
//  AxoTests.swift
//  AxoTests
//
//  Created by Kevin Perez on 10/2/26.
//

import AppKit
import Foundation
import Testing
@testable import Axo

/// Unit tests for the app target. Most logic lives in the local packages and is tested there.
struct AxoTests {
    /// The app's Info.plist, from the app bundle these tests run inside.
    private var info: [String: Any] {
        Bundle.main.infoDictionary ?? [:]
    }

    @Test func registersAsABrowserForWebLinks() throws {
        let urlTypes = try #require(info["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(Set(schemes) == ["http", "https"])
        #expect(urlTypes.allSatisfy { $0["CFBundleTypeRole"] as? String == "Viewer" })
    }

    @Test func opensHTMLDocuments() throws {
        let documentTypes = try #require(info["CFBundleDocumentTypes"] as? [[String: Any]])
        let contentTypes = documentTypes.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
        #expect(contentTypes.contains("public.html"))
    }

    @Test(arguments: ["NSCameraUsageDescription", "NSMicrophoneUsageDescription", "NSLocationUsageDescription", "NSLocalNetworkUsageDescription"])
    func explainsEachPermission(key: String) {
        #expect((info[key] as? String)?.isEmpty == false)
    }

    @MainActor
    @Test func linksKnowWhichAppSentThem() throws {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kInternetEventClass),
            eventID: AEEventID(kAEGetURL),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        #expect(LinkSource.sourceBundleID(of: event) == nil, "No sender, no app")
        // macOS sets an event's sender when it's sent, so a test can't fake one; check the
        // lookup from a process ID instead.
        // The Dock is always running, and registered with macOS from login.
        let dock = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first)
        #expect(LinkSource.bundleID(ofProcess: dock.processIdentifier) == "com.apple.dock")
        #expect(LinkSource.bundleID(ofProcess: 0) == nil)
    }
}
