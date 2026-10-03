//
//  AxoTests.swift
//  AxoTests
//
//  Created by Kevin Perez on 10/2/26.
//

import Foundation
import Testing

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
}
