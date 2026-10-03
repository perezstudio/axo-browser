import AxoCore
import Foundation

/// Arc's sidebar, read from its `StorableSidebar.json`: Spaces with their pinned and other tabs,
/// and each Arc profile's favorites.
///
/// Arc stores lists as alternating IDs and objects (`["id", {…}, "id", {…}]`). Items are tabs,
/// folders (`list`), split views (whose tabs are flattened), and the containers that hold each
/// Space's pinned and unpinned sections. Unknown item kinds are skipped, so a format change
/// loses those items rather than the whole import.
public struct ArcSidebar: Sendable, Equatable {
    /// An Arc profile. Spaces in one profile share cookies and logins in Arc.
    public enum Profile: Hashable, Sendable {
        /// Arc's default profile.
        case `default`
        /// A profile Arc created, by its folder name under `User Data` (such as `Profile 1`).
        case custom(directory: String)

        /// The profile's folder under Arc's `User Data` folder.
        public var directory: String {
            switch self {
            case .default: "Default"
            case .custom(let directory): directory
            }
        }
    }

    /// One Arc Space.
    public struct Space: Sendable, Equatable {
        /// The Space's name.
        public var name: String
        /// The Arc profile the Space uses.
        public var profile: Profile
        /// Pinned tabs and folders, in order.
        public var pinned: [ImportedItem]
        /// The other tabs, in order.
        public var unpinned: [ImportedItem]
    }

    /// The Spaces, in Arc's order.
    public var spaces: [Space]
    /// The favorites (Arc's "Top Apps") for each profile that has any, in order.
    public var favorites: [Profile: [ImportedItem]]

    /// Reads Arc's `StorableSidebar.json`.
    ///
    /// - Parameter url: Where the data came from, for error messages.
    /// - Throws: ``ImportError/unrecognizedFormat(_:)`` if it isn't Arc's sidebar format.
    public init(data: Data, from url: URL) throws {
        let root = try ImportError.jsonObject(data, from: url)
        guard let containers = (root["sidebar"] as? [String: Any])?["containers"] as? [Any],
              let container = containers.lazy.compactMap({ $0 as? [String: Any] }).first(where: { $0["spaces"] != nil && $0["items"] != nil }),
              let spaceList = container["spaces"] as? [Any],
              let itemList = container["items"] as? [Any]
        else { throw ImportError.unrecognizedFormat(url) }

        var items: [String: [String: Any]] = [:]
        for case let item as [String: Any] in itemList {
            if let id = item["id"] as? String { items[id] = item }
        }
        let reader = ItemReader(items: items)

        spaces = spaceList.compactMap { entry -> Space? in
            guard let space = entry as? [String: Any] else { return nil }
            let sections = Self.sections(space["containerIDs"] as? [Any] ?? [])
            return Space(
                name: (space["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Arc Space",
                profile: Self.profile(space["profile"]),
                pinned: sections["pinned"].map(reader.children) ?? [],
                unpinned: sections["unpinned"].map(reader.children) ?? []
            )
        }

        var favorites: [Profile: [ImportedItem]] = [:]
        let topApps = container["topAppsContainerIDs"] as? [Any] ?? []
        for index in stride(from: 0, to: topApps.count - 1, by: 2) {
            guard let containerID = topApps[index + 1] as? String else { continue }
            let children = reader.children(of: containerID)
            if !children.isEmpty { favorites[Self.profile(topApps[index]), default: []] += children }
        }
        self.favorites = favorites
    }

    /// Reads `["pinned", id, "unpinned", id]` into a dictionary.
    private static func sections(_ list: [Any]) -> [String: String] {
        var sections: [String: String] = [:]
        for index in stride(from: 0, to: list.count - 1, by: 2) {
            if let name = list[index] as? String, let id = list[index + 1] as? String { sections[name] = id }
        }
        return sections
    }

    /// Reads `{"default": true}` or `{"custom": {"_0": {"directoryBasename": "Profile 1"}}}`.
    private static func profile(_ value: Any?) -> Profile {
        guard let custom = (value as? [String: Any])?["custom"] as? [String: Any],
              let directory = (custom["_0"] as? [String: Any])?["directoryBasename"] as? String,
              !directory.isEmpty
        else { return .default }
        return .custom(directory: directory)
    }

    /// Turns Arc's items into ``ImportedItem``s.
    private struct ItemReader {
        let items: [String: [String: Any]]

        func children(of id: String) -> [ImportedItem] {
            children(of: id, depth: 0)
        }

        private func children(of id: String, depth: Int) -> [ImportedItem] {
            // Arc's data is a tree; the depth limit only guards against a malformed cycle.
            guard depth < 64, let ids = items[id]?["childrenIds"] as? [String] else { return [] }
            return ids.flatMap { item(id: $0, depth: depth + 1) }
        }

        private func item(id: String, depth: Int) -> [ImportedItem] {
            guard let item = items[id], let data = item["data"] as? [String: Any] else { return [] }
            let customTitle = (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let tab = data["tab"] as? [String: Any] {
                guard let address = tab["savedURL"] as? String, let url = URL(string: address), url.scheme != nil else { return [] }
                return [.tab(title: customTitle ?? tab["savedTitle"] as? String ?? "", url: url)]
            }
            if data["list"] != nil {
                return [.folder(name: customTitle ?? "Folder", children: children(of: id, depth: depth))]
            }
            if data["splitView"] != nil {
                return children(of: id, depth: depth)
            }
            return []
        }
    }
}
