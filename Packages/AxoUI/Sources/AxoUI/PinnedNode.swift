import AxoCore
import Foundation

/// One item in the pinned section's tree: a pinned tab, or a folder with its contents.
public enum PinnedNode: Identifiable, Hashable {
    case tab(AxoCore.Tab)
    case folder(Folder, children: [PinnedNode])

    /// The tab or folder this node shows.
    public var item: PinnedItem {
        switch self {
        case .tab(let tab): .tab(tab.id)
        case .folder(let folder, _): .folder(folder.id)
        }
    }

    public var id: PinnedItem { item }

    private var sortKey: String {
        switch self {
        case .tab(let tab): tab.sortKey
        case .folder(let folder, _): folder.sortKey
        }
    }

    /// Every pinned tab in `tree`, at any depth.
    static func allTabs(in tree: [PinnedNode]) -> [AxoCore.Tab] {
        tree.flatMap { node -> [AxoCore.Tab] in
            switch node {
            case .tab(let tab): [tab]
            case .folder(_, let children): allTabs(in: children)
            }
        }
    }

    /// Builds the tree: at each level, folders and pinned tabs ordered by sort key (ties by ID).
    static func tree(folders: [Folder], pinnedTabs: [AxoCore.Tab]) -> [PinnedNode] {
        let foldersByParent = Dictionary(grouping: folders, by: \.parentID)
        let tabsByFolder = Dictionary(grouping: pinnedTabs, by: \.folderID)
        let knownFolders = Set(folders.map(\.id))
        func level(_ parent: Folder.ID?, visited: Set<Folder.ID>) -> [PinnedNode] {
            var nodes: [PinnedNode] = (foldersByParent[parent] ?? [])
                .filter { !visited.contains($0.id) }
                .map { .folder($0, children: level($0.id, visited: visited.union([$0.id]))) }
            var tabs = tabsByFolder[parent] ?? []
            if parent == nil {
                // Tabs whose folder is missing (for example mid-sync) show at the top level.
                tabs += pinnedTabs.filter { $0.folderID.map { !knownFolders.contains($0) } ?? false }
            }
            nodes += tabs.map(PinnedNode.tab)
            return nodes.sorted { ($0.sortKey, $0.idString) < ($1.sortKey, $1.idString) }
        }
        return level(nil, visited: [])
    }

    /// The items directly inside `folder` (or at the top level when `nil`), in order.
    static func items(at folder: Folder.ID?, in tree: [PinnedNode]) -> [PinnedItem] {
        guard let folder else { return tree.map(\.item) }
        return children(of: folder, in: tree)?.map(\.item) ?? []
    }

    /// The contents of `folder`, or `nil` if it isn't in the tree.
    private static func children(of folder: Folder.ID, in tree: [PinnedNode]) -> [PinnedNode]? {
        for node in tree {
            guard case .folder(let candidate, let children) = node else { continue }
            if candidate.id == folder { return children }
            if let found = Self.children(of: folder, in: children) { return found }
        }
        return nil
    }

    /// Every folder in the tree with its depth and its path from the top level ("Work › Drafts"),
    /// in display order, for "Move to Folder" menus. The path is the menu item's title, because
    /// menus don't carry accessibility labels: VoiceOver reads what's on screen.
    static func flattenedFolders(_ tree: [PinnedNode], parents: [String] = []) -> [(folder: Folder, depth: Int, path: String)] {
        tree.flatMap { node -> [(folder: Folder, depth: Int, path: String)] in
            guard case .folder(let folder, let children) = node else { return [] }
            let names = parents + [folder.name]
            return [(folder, parents.count, names.joined(separator: " › "))]
                + flattenedFolders(children, parents: names)
        }
    }

    /// The IDs of a folder and everything nested in it.
    static func folderAndDescendants(_ id: Folder.ID, in tree: [PinnedNode]) -> Set<Folder.ID> {
        for node in tree {
            guard case .folder(let folder, let children) = node else { continue }
            if folder.id == id {
                return Set([id] + flattenedFolders(children).map(\.folder.id))
            }
            let found = folderAndDescendants(id, in: children)
            if !found.isEmpty { return found }
        }
        return []
    }

    private var idString: String {
        switch self {
        case .tab(let tab): tab.id.uuidString
        case .folder(let folder, _): folder.id.uuidString
        }
    }
}

/// A name the sidebar asks for.
public enum NamingRequest: Identifiable, Hashable {
    /// A new folder inside `parent` (or at the top level), optionally moving an item into it.
    case newFolder(parent: Folder.ID?, moving: PinnedItem?)
    /// A new name for a folder.
    case renameFolder(Folder)

    public var id: Self { self }
}
