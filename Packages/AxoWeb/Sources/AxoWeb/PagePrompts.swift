import AxoCore
import Foundation
import WebKit

/// A device or capability a page can ask to use.
public enum PermissionKind: String, Hashable, Sendable, CaseIterable {
    case camera
    case microphone
    case cameraAndMicrophone
    case location
}

/// The answer to a ``PermissionRequest``.
public enum PermissionDecision: Hashable, Sendable {
    case allow
    case deny
}

/// A page asking to use a device or capability.
public struct PermissionRequest: Hashable, Sendable {
    /// The tab whose page asked.
    public var tabID: Tab.ID
    /// The asking frame's origin, such as `https://meet.example.com`.
    public var origin: PageOrigin
    /// What the page wants to use.
    public var kind: PermissionKind

    /// Creates a request.
    public init(tabID: Tab.ID, origin: PageOrigin, kind: PermissionKind) {
        self.tabID = tabID
        self.origin = origin
        self.kind = kind
    }
}

/// A page's security origin in plain values, for display and for remembering decisions.
public struct PageOrigin: Hashable, Sendable {
    /// The scheme, such as `https`.
    public var scheme: String
    /// The host, or an empty string for origins without one (such as `file:` pages).
    public var host: String
    /// The port, or 0 for the scheme's default.
    public var port: Int

    /// Creates an origin.
    public init(scheme: String, host: String, port: Int = 0) {
        self.scheme = scheme.lowercased()
        self.host = host.lowercased()
        self.port = port
    }

    @MainActor
    init(_ origin: WKSecurityOrigin) {
        self.init(scheme: origin.protocol, host: origin.host, port: origin.port)
    }

    /// How to name the origin to people: its host (with a non-default port), or "This page".
    public var displayName: String {
        guard !host.isEmpty else { return "This page" }
        return port == 0 ? host : "\(host):\(port)"
    }
}

/// A JavaScript `alert()`, `confirm()`, or `prompt()` from a page.
public struct JavaScriptDialog: Hashable, Sendable {
    /// Which function the page called.
    public enum Kind: Hashable, Sendable {
        case alert
        case confirm
        case prompt(defaultText: String)
    }

    /// The tab whose page asked.
    public var tabID: Tab.ID
    /// The calling frame's origin, shown so a page can't pretend to be Axo or another site.
    public var origin: PageOrigin
    /// The page's message.
    public var message: String
    /// Which dialog to show.
    public var kind: Kind

    /// Creates a dialog.
    public init(tabID: Tab.ID, origin: PageOrigin, message: String, kind: Kind) {
        self.tabID = tabID
        self.origin = origin
        self.message = message
        self.kind = kind
    }
}

/// How someone answered a ``JavaScriptDialog``.
public struct JavaScriptDialogResult: Hashable, Sendable {
    /// Whether they chose OK (`true`) or Cancel (`false`).
    public var accepted: Bool
    /// The text they entered, for `prompt()`.
    public var text: String?

    /// Creates a result.
    public init(accepted: Bool, text: String? = nil) {
        self.accepted = accepted
        self.text = text
    }

    /// The result when no one answers: Cancel.
    public static let cancelled = JavaScriptDialogResult(accepted: false)
}

/// A page's file input asking for files to upload.
public struct FileSelectionRequest: Hashable, Sendable {
    /// The tab whose page asked.
    public var tabID: Tab.ID
    /// Whether more than one file may be chosen.
    public var allowsMultipleSelection: Bool
    /// Whether folders may be chosen.
    public var allowsDirectories: Bool

    /// Creates a request.
    public init(tabID: Tab.ID, allowsMultipleSelection: Bool, allowsDirectories: Bool) {
        self.tabID = tabID
        self.allowsMultipleSelection = allowsMultipleSelection
        self.allowsDirectories = allowsDirectories
    }
}
