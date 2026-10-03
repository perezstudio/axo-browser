import AxoCore
import Foundation

/// Finds other browsers' data on this Mac and imports it into Axo.
///
/// - **Arc:** each Space with its pinned tabs and folders, plus (optionally) favorites, open
///   tabs, and history. Spaces on Arc's default profile use the current Axo profile. Each other
///   Arc profile gets a new Axo profile, so Spaces stay separated as they were in Arc.
/// - **Chrome:** one profile's bookmarks, as pinned tabs in an "Imported from Chrome" folder in
///   the current Space, and its history, in the current profile.
///
/// Cookies, logins, and passwords aren't imported.
public struct BrowserImporter: Sendable {
    /// A browser to import from.
    public enum Source: Hashable, Sendable, Identifiable {
        /// Arc.
        case arc
        /// One Google Chrome profile.
        case chrome(ChromiumProfile)

        public var id: String {
            switch self {
            case .arc: "arc"
            case .chrome(let profile): "chrome:\(profile.directory)"
            }
        }
    }

    /// What to import.
    public struct Parts: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// Arc's Spaces with their pinned tabs and folders.
        public static let spaces = Parts(rawValue: 1 << 0)
        /// Arc's favorites, in a Favorites folder in the first imported Space.
        public static let favorites = Parts(rawValue: 1 << 1)
        /// Arc's unpinned tabs.
        public static let openTabs = Parts(rawValue: 1 << 2)
        /// Chrome's bookmarks.
        public static let bookmarks = Parts(rawValue: 1 << 3)
        /// Browsing history.
        public static let history = Parts(rawValue: 1 << 4)

        /// Everything.
        public static let all: Parts = [.spaces, .favorites, .openTabs, .bookmarks, .history]
    }

    /// How much there is to import, or how much was imported.
    public struct Counts: Hashable, Sendable {
        public var spaces = 0
        public var pinnedTabs = 0
        public var favorites = 0
        public var openTabs = 0
        public var bookmarks = 0
        public var historyPages = 0

        /// Creates counts, all zero by default.
        public init(spaces: Int = 0, pinnedTabs: Int = 0, favorites: Int = 0, openTabs: Int = 0, bookmarks: Int = 0, historyPages: Int = 0) {
            self.spaces = spaces
            self.pinnedTabs = pinnedTabs
            self.favorites = favorites
            self.openTabs = openTabs
            self.bookmarks = bookmarks
            self.historyPages = historyPages
        }
    }

    /// The name of the folder that holds Arc's favorites.
    public static let favoritesFolderName = "Favorites"
    /// The name of the folder that holds Chrome's bookmarks.
    public static let chromeFolderName = "Imported from Chrome"

    private let store: TabStore
    private let applicationSupport: URL

    /// Creates an importer that writes to `store`.
    ///
    /// - Parameter applicationSupport: The folder holding browsers' data, the user's
    ///   `~/Library/Application Support` by default. Tests pass a folder of fixtures.
    public init(store: TabStore, applicationSupport: URL = .applicationSupportDirectory) {
        self.store = store
        self.applicationSupport = applicationSupport
    }

    private var arcFolder: URL { applicationSupport.appending(path: "Arc", directoryHint: .isDirectory) }
    private var arcSidebarFile: URL { arcFolder.appending(path: "StorableSidebar.json") }
    private var arcUserData: URL { arcFolder.appending(path: "User Data", directoryHint: .isDirectory) }
    private var chromeFolder: URL { applicationSupport.appending(path: "Google/Chrome", directoryHint: .isDirectory) }

    // MARK: Finding browsers

    /// The browsers with data on this Mac: Arc, then each Chrome profile.
    ///
    /// If Chrome is installed but its profile list can't be read (macOS asks before letting Axo
    /// read another app's data), its default profile is offered, and reading it reports the error.
    public func availableSources() -> [Source] {
        let manager = FileManager.default
        var sources: [Source] = []
        if manager.fileExists(atPath: arcSidebarFile.path) { sources.append(.arc) }
        if manager.fileExists(atPath: chromeFolder.path) {
            let profiles = (try? ChromiumProfile.profiles(inLocalState: chromeFolder.appending(path: "Local State"))) ?? []
            let offered = profiles.isEmpty ? [ChromiumProfile(directory: "Default", name: "Default")] : profiles
            sources += offered.map(Source.chrome)
        }
        return sources
    }

    // MARK: Previewing

    /// Counts what importing everything from `source` would bring over, without changing anything.
    ///
    /// - Throws: ``ImportError`` if the browser's data can't be read.
    public func preview(_ source: Source) async throws -> Counts {
        switch source {
        case .arc:
            let sidebar = try readArcSidebar()
            var counts = Counts(
                spaces: sidebar.spaces.count,
                pinnedTabs: sidebar.spaces.reduce(0) { $0 + $1.pinned.reduce(0) { $0 + $1.tabCount } },
                favorites: sidebar.favorites.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.tabCount } },
                openTabs: sidebar.spaces.reduce(0) { $0 + $1.unpinned.reduce(0) { $0 + $1.tabCount } }
            )
            for profile in Set(sidebar.spaces.map(\.profile)) {
                counts.historyPages += try optional { try ChromiumHistory.pageCount(at: arcHistoryFile(for: profile)) } ?? 0
            }
            return counts
        case .chrome(let profile):
            return Counts(
                bookmarks: try readChromeBookmarks(profile)?.tabCount ?? 0,
                historyPages: try optional { try ChromiumHistory.pageCount(at: chromeFolder.appending(path: "\(profile.directory)/History")) } ?? 0
            )
        }
    }

    // MARK: Importing

    /// Imports from `source`.
    ///
    /// - Parameters:
    ///   - parts: What to bring over. Parts that don't apply to the source are ignored. Arc's
    ///     favorites and open tabs need ``Parts/spaces``.
    ///   - currentSpace: The Space the window shows. Chrome's bookmarks go here, and its history
    ///     and the history of Arc's default profile go to its profile.
    /// - Returns: What was imported.
    /// - Throws: ``ImportError`` if the browser's data can't be read, or a ``TabStoreError``.
    ///   Spaces, pinned tabs, and history are each written in one transaction.
    @discardableResult
    public func importData(from source: Source, parts: Parts, currentSpace: Space) async throws -> Counts {
        switch source {
        case .arc: try await importArc(parts: parts, currentSpace: currentSpace)
        case .chrome(let profile): try await importChrome(profile, parts: parts, currentSpace: currentSpace)
        }
    }

    private func importArc(parts: Parts, currentSpace: Space) async throws -> Counts {
        guard parts.contains(.spaces) else { return Counts() }
        let sidebar = try readArcSidebar()
        guard !sidebar.spaces.isEmpty else { return Counts() }

        // One Axo profile per Arc profile. Arc's default profile is the current one.
        let names = (try? ChromiumProfile.profiles(inLocalState: arcUserData.appending(path: "Local State"))) ?? []
        var profileIDs: [ArcSidebar.Profile: Profile.ID] = [.default: currentSpace.profileID]
        var createdProfiles: [Profile.ID] = []
        for case .custom(let directory) in sidebar.spaces.map(\.profile) where profileIDs[.custom(directory: directory)] == nil {
            let name = names.first { $0.directory == directory }?.name ?? directory
            let profile = try await store.createProfile(name: "Arc \(name)")
            profileIDs[.custom(directory: directory)] = profile.id
            createdProfiles.append(profile.id)
        }

        // Each profile's favorites go first in that profile's first Space, or the first Space.
        var favoritesBySpace: [Int: [ImportedItem]] = [:]
        var counts = Counts()
        if parts.contains(.favorites) {
            for (profile, favorites) in sidebar.favorites {
                let index = sidebar.spaces.firstIndex { $0.profile == profile } ?? 0
                favoritesBySpace[index, default: []] += favorites
                counts.favorites += favorites.reduce(0) { $0 + $1.tabCount }
            }
        }

        let spaces = sidebar.spaces.enumerated().map { index, space in
            let favorites = favoritesBySpace[index].map { [ImportedItem.folder(name: Self.favoritesFolderName, children: $0)] } ?? []
            return ImportedSpace(
                name: space.name,
                profileID: profileIDs[space.profile]!,
                pinned: favorites + space.pinned,
                unpinned: parts.contains(.openTabs) ? space.unpinned : []
            )
        }
        do {
            try await store.importSpaces(spaces)
        } catch {
            for id in createdProfiles { try? await store.deleteProfile(id: id) }
            throw error
        }
        counts.spaces = spaces.count
        counts.pinnedTabs = sidebar.spaces.reduce(0) { $0 + $1.pinned.reduce(0) { $0 + $1.tabCount } }
        counts.openTabs = spaces.reduce(0) { $0 + $1.unpinned.reduce(0) { $0 + $1.tabCount } }

        if parts.contains(.history) {
            for (profile, profileID) in profileIDs where sidebar.spaces.contains(where: { $0.profile == profile }) {
                let pages = try optional { try ChromiumHistory.pages(at: arcHistoryFile(for: profile)) } ?? []
                counts.historyPages += try await store.history.importItems(pages, profileID: profileID)
            }
        }
        return counts
    }

    private func importChrome(_ profile: ChromiumProfile, parts: Parts, currentSpace: Space) async throws -> Counts {
        var counts = Counts()
        if parts.contains(.bookmarks), let folder = try readChromeBookmarks(profile) {
            try await store.importPinned([folder], into: currentSpace.id)
            counts.bookmarks = folder.tabCount
        }
        if parts.contains(.history) {
            let file = chromeFolder.appending(path: "\(profile.directory)/History")
            let pages = try optional { try ChromiumHistory.pages(at: file) } ?? []
            counts.historyPages = try await store.history.importItems(pages, profileID: currentSpace.profileID)
        }
        return counts
    }

    // MARK: Reading

    private func readArcSidebar() throws -> ArcSidebar {
        try ArcSidebar(data: try ImportError.read(arcSidebarFile), from: arcSidebarFile)
    }

    private func arcHistoryFile(for profile: ArcSidebar.Profile) -> URL {
        arcUserData.appending(path: "\(profile.directory)/History")
    }

    private func readChromeBookmarks(_ profile: ChromiumProfile) throws -> ImportedItem? {
        let file = chromeFolder.appending(path: "\(profile.directory)/Bookmarks")
        guard let data = try optional({ try ImportError.read(file) }) else { return nil }
        return try ChromeBookmarks.folder(named: Self.chromeFolderName, from: data, url: file)
    }

    /// Runs `read`, treating a missing file as nothing to import. Other errors are thrown.
    private func optional<T>(_ read: () throws -> T) throws -> T? {
        do {
            return try read()
        } catch ImportError.notFound {
            return nil
        }
    }
}
