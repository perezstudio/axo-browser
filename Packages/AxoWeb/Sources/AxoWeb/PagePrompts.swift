import AxoCore
import Foundation

/// A device or capability a page can ask to use.
public enum PermissionKind: String, Hashable, Sendable, CaseIterable {
    case camera
    case microphone
    case cameraAndMicrophone
    case location
    /// Showing notifications.
    case notifications
    /// Reading what the person copied.
    case clipboard

    /// Whether the engine keeps an answer itself (Chromium, for notifications and the clipboard,
    /// which pages read without asking), so Axo's site settings must keep the engine's copy in
    /// step (``WebViewPool/setLastingPermission(_:origin:decision:profileID:)``). Other kinds are
    /// asked about each time, and Axo answers from its settings.
    public var lastsInEngine: Bool {
        self == .notifications || self == .clipboard
    }
}

/// A site's saved answer for a kind the engine keeps itself (``PermissionKind/lastsInEngine``).
public struct LastingPermission: Hashable, Sendable {
    public var kind: PermissionKind
    public var origin: PageOrigin
    public var decision: PermissionDecision

    /// Creates a site's answer for a kind.
    public init(kind: PermissionKind, origin: PageOrigin, decision: PermissionDecision) {
        self.kind = kind
        self.origin = origin
        self.decision = decision
    }
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

    /// The origin of a web page's URL, or `nil` for URLs that aren't http or https. A port that
    /// is the scheme's default counts as no port, matching `WKSecurityOrigin`.
    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty else { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        let port = url.port.map { $0 == defaultPort ? 0 : $0 } ?? 0
        self.init(scheme: scheme, host: host, port: port)
    }

    /// The origin as text, such as `https://meet.example.com` or `http://localhost:3000`, for
    /// saving decisions.
    public var serialized: String {
        // An IPv6 address keeps its brackets, as in a URL.
        let host = host.contains(":") ? "[\(host)]" : host
        return port == 0 ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(port)"
    }

    /// How to name the origin to people: its host (with a non-default port), or "This page".
    public var displayName: String {
        guard !host.isEmpty else { return "This page" }
        return port == 0 ? host : "\(host):\(port)"
    }
}

/// Saves the person's permission answers beyond this launch. The app provides one backed by the
/// database; without one, the pool remembers answers until Axo quits.
@MainActor
public protocol PermissionDecisionStore: AnyObject {
    /// The saved answer for a kind on a site in a profile, or `nil` to ask.
    func savedDecision(for kind: PermissionKind, origin: PageOrigin, profileID: Profile.ID) async -> PermissionDecision?
    /// Saves the person's answer.
    func saveDecision(_ decision: PermissionDecision, for kind: PermissionKind, origin: PageOrigin, profileID: Profile.ID) async
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

/// A page asking for files: its file input (`<input type="file">`), or, on engines that leave
/// them to Axo, a File System Access picker (`showOpenFilePicker`, `showDirectoryPicker`, and
/// `showSaveFilePicker`).
public struct FileSelectionRequest: Hashable, Sendable {
    /// Whether the page wants files to read, or where to save one.
    public enum Kind: Hashable, Sendable {
        /// Existing files or folders.
        case open
        /// Where to save a new file, or a file to replace.
        case save
    }

    /// The tab whose page asked.
    public var tabID: Tab.ID
    /// Open or save.
    public var kind: Kind
    /// Whether more than one file may be chosen.
    public var allowsMultipleSelection: Bool
    /// Whether folders may be chosen.
    public var allowsDirectories: Bool
    /// Whether files may be chosen; `false` for a picker that wants only a folder.
    public var allowsFiles: Bool
    /// The name to save as.
    public var suggestedName: String?
    /// The folder to start in, or `nil` for the panel's own choice.
    public var directory: URL?
    /// The file extensions (without dots) the page accepts, or empty for any file.
    public var allowedExtensions: [String]

    /// Creates a request.
    public init(
        tabID: Tab.ID,
        kind: Kind = .open,
        allowsMultipleSelection: Bool,
        allowsDirectories: Bool,
        allowsFiles: Bool = true,
        suggestedName: String? = nil,
        directory: URL? = nil,
        allowedExtensions: [String] = []
    ) {
        self.tabID = tabID
        self.kind = kind
        self.allowsMultipleSelection = allowsMultipleSelection
        self.allowsDirectories = allowsDirectories
        self.allowsFiles = allowsFiles
        self.suggestedName = suggestedName
        self.directory = directory
        self.allowedExtensions = allowedExtensions
    }

    /// The request for a page's File System Access picker in tab `tabID`.
    public init(tabID: Tab.ID, panel: FilePanel) {
        self.init(
            tabID: tabID,
            kind: panel.kind == .save ? .save : .open,
            allowsMultipleSelection: panel.kind == .openFiles,
            allowsDirectories: panel.kind == .folder,
            allowsFiles: panel.kind != .folder,
            suggestedName: panel.kind == .save ? panel.suggestedName : nil,
            directory: panel.directory,
            allowedExtensions: panel.kind == .folder ? [] : panel.allowedExtensions
        )
    }
}

/// A page's File System Access picker (`showOpenFilePicker`, `showDirectoryPicker`, or
/// `showSaveFilePicker`), as an engine that leaves the panel to Axo reports it. WebKit has no such
/// pickers.
public struct FilePanel: Hashable, Sendable {
    /// What the picker chooses.
    public enum Kind: Hashable, Sendable {
        /// One existing file.
        case openFile
        /// One or more existing files.
        case openFiles
        /// A folder.
        case folder
        /// Where to save a file.
        case save
    }

    /// What the picker chooses.
    public var kind: Kind
    /// The name to save as.
    public var suggestedName: String?
    /// The folder to start in.
    public var directory: URL?
    /// The file extensions (without dots) the page accepts, or empty for any file.
    public var allowedExtensions: [String]

    /// Creates a picker request.
    public init(kind: Kind, suggestedName: String? = nil, directory: URL? = nil, allowedExtensions: [String] = []) {
        self.kind = kind
        self.suggestedName = suggestedName
        self.directory = directory
        self.allowedExtensions = allowedExtensions
    }
}

/// A File System Access question for the person, from a page with a handle to a file or folder,
/// or about a choice in one of its pickers, for engines that ask Axo (Chromium).
public struct FileAccessRequest: Hashable, Sendable {
    /// What the page wants, or what's wrong with what the person chose.
    public enum Kind: Hashable, Sendable {
        /// Viewing a file, or the files in a folder. Allowing it answers `true`.
        case view
        /// Saving changes to a file, or to the files in a folder. Allowing it answers `true`.
        case edit
        /// Viewing and editing the files in a folder. Allowing it answers `true`.
        case viewAndEdit
        /// The person chose a file or folder pages can't have, because it holds system files.
        /// Choosing another answers `true`, cancelling `false`.
        case restricted
        /// The page is about to save a file of a type that can harm the Mac. Saving it anyway
        /// answers `true`.
        case dangerousFile
    }

    /// The tab whose page asked.
    public var tabID: Tab.ID
    /// The asking site.
    public var origin: PageOrigin
    /// What the question is about.
    public var kind: Kind
    /// The file or folder's name, or `nil` when there's none to give (``Kind/restricted``).
    public var name: String?
    /// Whether it's about a folder rather than a file.
    public var isDirectory: Bool

    /// Creates a request.
    public init(tabID: Tab.ID, origin: PageOrigin, kind: Kind, name: String?, isDirectory: Bool) {
        self.tabID = tabID
        self.origin = origin
        self.kind = kind
        self.name = name
        self.isDirectory = isDirectory
    }
}

/// A File System Access question as an engine reports it, before it's tied to a tab.
public struct FileAccessQuestion: Hashable, Sendable {
    /// What the question is about.
    public var kind: FileAccessRequest.Kind
    /// The file or folder, or `nil` when there's none to name.
    public var url: URL?
    /// Whether it's about a folder rather than a file.
    public var isDirectory: Bool
    /// The asking site.
    public var origin: PageOrigin

    /// Creates a question.
    public init(kind: FileAccessRequest.Kind, url: URL?, isDirectory: Bool, origin: PageOrigin) {
        self.kind = kind
        self.url = url
        self.isDirectory = isDirectory
        self.origin = origin
    }
}
