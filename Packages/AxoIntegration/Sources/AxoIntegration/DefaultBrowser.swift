import AppKit
import Foundation
import UniformTypeIdentifiers

/// Checks whether Axo is the default web browser, and asks macOS to make it the default.
///
/// macOS asks the person to confirm the change in its own dialog, so Axo can only request it in
/// response to something the person chose. The system calls are injected, so tests never change
/// the real default browser.
@MainActor
public struct DefaultBrowser {
    /// The URL schemes a default browser handles.
    public static let schemes = ["http", "https"]

    private let appURL: URL
    private let handlerForScheme: (String) -> URL?
    private let setHandler: (URL, String) async throws -> Void
    private let setHTMLHandler: (URL) async throws -> Void

    /// Uses `NSWorkspace` for the app at `appURL` (the running app by default).
    public init(appURL: URL = Bundle.main.bundleURL) {
        self.init(
            appURL: appURL,
            handlerForScheme: { scheme in
                URL(string: "\(scheme)://example.com").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
            },
            setHandler: { app, scheme in
                try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme)
            },
            setHTMLHandler: { app in
                try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: .html)
            }
        )
    }

    /// Uses the given system calls. For tests.
    init(
        appURL: URL,
        handlerForScheme: @escaping (String) -> URL?,
        setHandler: @escaping (URL, String) async throws -> Void,
        setHTMLHandler: @escaping (URL) async throws -> Void
    ) {
        self.appURL = appURL
        self.handlerForScheme = handlerForScheme
        self.setHandler = setHandler
        self.setHTMLHandler = setHTMLHandler
    }

    /// Whether Axo opens both http and https links.
    public var isDefault: Bool {
        Self.schemes.allSatisfy { scheme in
            handlerForScheme(scheme).map(Self.isSameApp(appURL)) ?? false
        }
    }

    /// Asks macOS to make Axo the default for http and https links and HTML files. macOS shows
    /// a confirmation dialog; this throws if the person declines or the change fails.
    public func makeDefault() async throws {
        for scheme in Self.schemes {
            try await setHandler(appURL, scheme)
        }
        // HTML files are a convenience; a browser is still the default without them.
        try? await setHTMLHandler(appURL)
    }

    /// Whether two app URLs are the same app, comparing bundle identifiers when both are
    /// bundles (a copy in another folder is still Axo) and resolved paths otherwise.
    static func isSameApp(_ app: URL) -> (URL) -> Bool {
        { other in
            if let a = Bundle(url: app)?.bundleIdentifier, let b = Bundle(url: other)?.bundleIdentifier {
                return a == b
            }
            return app.standardizedFileURL.resolvingSymlinksInPath().path == other.standardizedFileURL.resolvingSymlinksInPath().path
        }
    }
}
