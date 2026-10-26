import AxoCore
import AxoEngineAPI
import Foundation

extension ChromiumEngine {
    /// Sets the bookmarks extensions in a profile see (`chrome.bookmarks`). Call it whenever the
    /// tree changes, from launch on. The engine gets it once it's ready and the profile is in use
    /// (it has pages or extensions), so profiles nobody uses aren't loaded for it. The engine
    /// updates only what changed, and bookmarks keep their IDs.
    public func setBookmarks(_ tree: BookmarkTree, profileID: Profile.ID) {
        guard readyProfileIsAllowed(profileID) else { return }
        bookmarkTrees[profileID] = tree
        guard isFollowing(profileID) else { return }
        readyProfile(profileID)?.setBookmarks(tree)
    }
}

extension AXOProfile {
    func setBookmarks(_ tree: BookmarkTree) {
        setBookmarks(bar: tree.bar.map(EngineBookmark.init), other: tree.other.map(EngineBookmark.init))
    }
}

/// A ``BookmarkItem`` as the engine reads it.
final class EngineBookmark: NSObject, AXOBookmarkNode {
    let identifier: String
    let title: String
    let url: URL?
    let children: [any AXOBookmarkNode]

    init(_ item: BookmarkItem) {
        identifier = item.id.uuidString.lowercased()
        title = item.title
        url = item.url
        children = item.children.map(EngineBookmark.init)
    }
}

extension BookmarkChange {
    /// The engine's change in Axo's terms, or `nil` if it doesn't name a bookmark Axo could have.
    @MainActor init?(_ change: any AXOBookmarkChange) {
        guard let id = UUID(uuidString: change.identifier) else { return nil }
        let place: BookmarkPlace
        switch change.parentRoot {
        case .bar: place = .bar
        case .other: place = .other
        default:
            guard let parent = change.parentIdentifier.flatMap(UUID.init(uuidString:)) else { return nil }
            place = .inside(parent)
        }
        let kind: Kind
        switch change.kind {
        case .created: kind = .created
        case .updated: kind = .updated
        case .moved: kind = .moved
        case .removed: kind = .removed
        @unknown default: return nil
        }
        self.init(kind: kind, id: id, place: place, index: Int(change.index), title: change.title, url: change.url)
    }
}
