import AxoCore
import Foundation
import SwiftUI

/// Tab actions from a tab's context menu, the Tabs menu (for the selected tab), and the command
/// bar (#81): Duplicate, Copy Link, Move to Space, Close Other Tabs, and Close Tabs Below.
extension BrowserModel {
    /// The tab the Tabs menu's tab actions act on: the selected tab, unless a folder's row is
    /// selected (its page keeps showing, but the folder is what's highlighted).
    public var tabForTabActions: AxoCore.Tab? {
        selectedFolderID == nil ? selectedTab : nil
    }

    /// The tab's current address: its live page's, or the saved one.
    func currentURL(of tab: AxoCore.Tab) -> URL {
        pool.state(for: tab.id)?.url ?? tab.url
    }

    /// Opens a copy of the tab below it (an unpinned tab; a pinned tab's copy goes first among
    /// the unpinned ones), with its back and forward history, and selects it.
    public func duplicateTab(_ id: AxoCore.Tab.ID) async {
        guard let space, let tab = tabs.first(where: { $0.id == id }) else { return }
        // Below the tab's whole sidebar row: after the split's lowest tab in the sidebar (not its
        // last pane, which can come first), so the split's tabs stay together.
        let anchor = split(of: id).flatMap { split in panes(of: split.id).max { $0.sortKey < $1.sortKey }?.id } ?? id
        do {
            let copy = try await store.openTab(
                url: currentURL(of: tab), title: pool.state(for: id)?.title ?? tab.title,
                in: space.id, at: tab.isPinned ? .start : .after(anchor))
            // Before the page is made, so it restores the history instead of loading the URL.
            pool.copyHistory(from: id, to: copy.id)
            tabs = try await store.tabs(in: space.id)
            onTabEvent?(.opened(copy.id))
            select(copy.id)
            announce("Duplicated \(TabRow.displayTitle(for: tab))")
        } catch {
            report(error, "Axo couldn't duplicate the tab.")
        }
    }

    /// Copies the tab's address, as Copy Link does for the page showing.
    public func copyLink(of id: AxoCore.Tab.ID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let url = currentURL(of: tab)
        if let copyLink { copyLink(url) } else { copyToPasteboard(url) }
        postNotice("Link copied", placement: id == selectedTabID ? .addressBar : .page)
    }

    /// The Spaces a tab of the shown Space can move to: every other Space. One of another
    /// profile reloads the page there with that profile's website data (#81), as in Arc.
    public var spacesToMoveTabsTo: [Space] {
        guard let space else { return [] }
        // Another profile's only once its record is read, so the menu can name it.
        return spaces.filter { other in
            other.id != space.id && (other.profileID == space.profileID || allProfiles.contains { $0.id == other.profileID })
        }
    }

    /// Move to Space's choices, grouped: the profile's own Spaces first (no heading), then each
    /// other profile's under its name, in the profiles' order.
    public var moveToSpaceGroups: [MoveToSpaceGroup] {
        guard let space else { return [] }
        let targets = spacesToMoveTabsTo
        var groups: [MoveToSpaceGroup] = []
        let own = targets.filter { $0.profileID == space.profileID }
        if !own.isEmpty { groups.append(MoveToSpaceGroup(profileID: nil, profileName: nil, spaces: own)) }
        for profile in allProfiles where profile.id != space.profileID {
            let theirs = targets.filter { $0.profileID == profile.id }
            if !theirs.isEmpty { groups.append(MoveToSpaceGroup(profileID: profile.id, profileName: profile.name, spaces: theirs)) }
        }
        return groups
    }

    /// Whether Move to Space is offered for the tab: not for a tab in a split, whose row stands
    /// for the whole split (moving one pane would break it up), and not without another Space.
    public func canMoveToSpace(_ id: AxoCore.Tab.ID) -> Bool {
        split(of: id) == nil && !spacesToMoveTabsTo.isEmpty && tabs.contains { $0.id == id }
    }

    /// The tab a drop onto a Space's dot in the switcher moves there (#78): a sidebar row's tab
    /// (`tab:<id>`) that can move to that Space, never a folder, a favorite, or other text.
    func tabToMove(droppedAs items: [String], to space: Space.ID) -> AxoCore.Tab.ID? {
        guard let item = items.first.flatMap(SidebarDragPayload.item(from:)), case .tab(let id) = item,
              canMoveToSpace(id), spacesToMoveTabsTo.contains(where: { $0.id == space }) else { return nil }
        return id
    }

    /// Moves a tab to another Space; it leaves any folder. In the profile's own Spaces it keeps its
    /// live page; in another profile's, its page closes first (it holds the old profile's website
    /// data, hard rule 6), and it loads its address again there with that profile's, without its
    /// back and forward history. If it was selected, the tab next to it is selected.
    public func moveTab(_ id: AxoCore.Tab.ID, toSpace target: Space.ID) async {
        guard let space, canMoveToSpace(id), let destination = spacesToMoveTabsTo.first(where: { $0.id == target }),
              var tab = tabs.first(where: { $0.id == id }) else { return }
        let order = visibleTabOrder
        let selectedTabIDBeforeMove = selectedTabID
        let changesProfile = destination.profileID != space.profileID
        // The neighbor first, so nothing shows the tab (and makes its page again with the old
        // profile) while it moves to another profile.
        if changesProfile, selectedTabID == id {
            select(Self.neighbor(of: id, in: order, among: order.filter { $0 != id }))
        }
        do {
            if changesProfile {
                // The address it's on now, which its new page loads.
                let current = currentURL(of: tab)
                if current != tab.url {
                    let title = pool.state(for: id)?.title ?? tab.title
                    try await store.updateTab(id: id, url: current, title: title)
                    tab.url = current
                    tab.title = title
                }
            }
            if changesProfile {
                // Its page holds the old profile's data: closed before the move, so nothing can
                // show it in the new profile's Space.
                if fullscreenTabID == id { exitPageFullscreen() }
                prompts.dismissAll(from: id)
                pool.discard(id)
            }
            try await store.moveTab(id: id, toSpace: destination.id, acrossProfiles: changesProfile)
            tabs = try await store.tabs(in: space.id)
            // The neighbor is selected at once, so the engine's window, sent with `tabs`, never
            // goes without a selection while the sidebar's records are read.
            if selectedTabID == id {
                select(Self.neighbor(of: id, in: order, among: visibleTabOrder))
            }
            try await refreshSidebar()
        } catch {
            report(error, "Axo couldn't move the tab.")
            return
        }
        // Its new Space's page in the sidebar shows it, for a swipe there (#84).
        await refreshPreview(of: destination.id)
        // Gone from this Space's window, as for a closed tab (the WebKit extension bridge).
        onTabEvent?(.closed(id))
        let wasSelected = selectedTabIDBeforeMove == id
        let profileNote = changesProfile ? allProfiles.first { $0.id == destination.profileID }.map { " in the \($0.name) profile" } ?? "" : ""
        postNotice("Moved \(TabRow.displayTitle(for: tab)) to \(destination.name)\(profileNote)") { [weak self] in
            await self?.returnMovedTab(tab, from: destination.id, select: wasSelected)
        }
    }

    /// Undo of Move to Space (#78): puts the tab back in this Space where it was (its folder and
    /// place), and selects it again if it was selected. Notices go when the Space changes, so this
    /// runs only while its old Space is shown; a tab that moved on since stays where it is.
    func returnMovedTab(_ tab: AxoCore.Tab, from destination: Space.ID, select: Bool) async {
        guard let space, space.id == tab.spaceID else { return }
        do {
            // From another profile's Space, any page it got there is closed first, as for the move.
            let fromAnotherProfile = spaces.first { $0.id == destination }.map { $0.profileID != space.profileID } ?? false
            if fromAnotherProfile { pool.discard(tab.id) }
            let returned = try await store.returnTab(id: tab.id, from: destination, to: space.id, folder: tab.folderID,
                                                     sortKey: tab.sortKey, wasPinned: tab.isPinned, acrossProfiles: fromAnotherProfile)
            // The Space may have changed meanwhile: then its own reads show the tab, and this
            // one's sidebar and selection are left alone.
            guard returned, self.space?.id == space.id else { return }
            tabs = try await store.tabs(in: space.id)
            onTabEvent?(.opened(tab.id))
            try await refreshSidebar()
            if select, self.space?.id == space.id { self.select(tab.id) }
        } catch {
            report(error, "Axo couldn't move the tab back.")
            return
        }
        await refreshPreview(of: destination)
        announce("Moved \(TabRow.displayTitle(for: tab)) back")
    }

    /// The unpinned sidebar rows, in order, each as its tabs: one tab, or a split's panes.
    private var unpinnedRows: [[AxoCore.Tab.ID]] {
        unpinnedTabs.filter { !isSplitFollower($0) }.map { paneIDs(alongside: $0.id) }
    }

    /// The unpinned tabs that Close Other Tabs closes: every other unpinned row's. None for a
    /// pinned tab or a favorite, which these actions aren't for.
    func otherUnpinnedTabs(than id: AxoCore.Tab.ID) -> [AxoCore.Tab.ID] {
        let rows = unpinnedRows
        guard rows.contains(where: { $0.contains(id) }) else { return [] }
        return rows.filter { !$0.contains(id) }.flatMap(\.self)
    }

    /// The unpinned tabs that Close Tabs Below closes: the rows after `id`'s in the sidebar.
    func unpinnedTabs(below id: AxoCore.Tab.ID) -> [AxoCore.Tab.ID] {
        let rows = unpinnedRows
        guard let row = rows.firstIndex(where: { $0.contains(id) }) else { return [] }
        return rows[(row + 1)...].flatMap(\.self)
    }

    /// `id` and, if it's in a split, the split's other panes.
    private func paneIDs(alongside id: AxoCore.Tab.ID) -> [AxoCore.Tab.ID] {
        guard let split = split(of: id) else { return [id] }
        return panes(of: split.id).map(\.id)
    }

    /// Closes every other unpinned row (`id`'s split stays together). Pinned tabs stay; each
    /// closed tab can come back with Reopen Closed Tab or from the archive.
    public func closeOtherTabs(than id: AxoCore.Tab.ID) async {
        await closeTabs(otherUnpinnedTabs(than: id), keeping: id)
    }

    /// Closes the unpinned rows below `id`'s in the sidebar.
    public func closeTabs(below id: AxoCore.Tab.ID) async {
        await closeTabs(unpinnedTabs(below: id), keeping: id)
    }

    /// Closes several unpinned tabs at once: one write, one announcement.
    private func closeTabs(_ ids: [AxoCore.Tab.ID], keeping id: AxoCore.Tab.ID) async {
        guard let space, !ids.isEmpty else { return }
        logger.notice("Closing \(ids.count, privacy: .public) tabs at the person's request")
        if selectedTabID.map(ids.contains) ?? false { select(id) }
        for closing in ids {
            prompts.dismissAll(from: closing)
            pool.discard(closing)
        }
        do {
            try await store.archiveTabs(ids: ids, at: now())
            tabs = try await store.tabs(in: space.id)
        } catch {
            report(error, "Axo couldn't close the tabs.")
            return
        }
        ids.forEach { onTabEvent?(.closed($0)) }
        let spaceID = space.id
        postNotice(ids.count == 1 ? "Closed 1 tab" : "Closed \(ids.count) tabs") { [weak self] in
            // As for one closed tab: only in the Space they left, and only the ones still
            // archived there. They come back in their order, at the end, each a tab of its own.
            guard let self, self.space?.id == spaceID else { return }
            let archived = Set(await self.archivedTabs().map(\.id))
            await self.restoreTabs(ids.filter(archived.contains))
        }
    }

    /// Restores archived tabs of the shown Space in the order given, each at the end, keeping
    /// the selection (Undo for closing several tabs).
    func restoreTabs(_ ids: [AxoCore.Tab.ID]) async {
        guard let space, !ids.isEmpty else { return }
        do {
            for id in ids { try await store.restoreTab(id: id, at: now()) }
            tabs = try await store.tabs(in: space.id)
        } catch {
            report(error, "Axo couldn't reopen the tabs.")
            return
        }
        ids.forEach { onTabEvent?(.opened($0)) }
        announce(ids.count == 1 ? "Reopened 1 tab" : "Reopened \(ids.count) tabs")
    }
}

/// A group of Move to Space's choices: the profile's own Spaces (`profileName` nil), or another
/// profile's, whose tabs reload there.
public struct MoveToSpaceGroup: Identifiable, Sendable {
    /// The other profile, or `nil` for the profile's own Spaces.
    public var profileID: Profile.ID?
    public var profileName: String?
    public var spaces: [Space]
    /// By profile, since two profiles can share a name.
    public var id: Profile.ID? { profileID }
}


/// Move to Space's items: the profile's own Spaces, then each other profile's in a section under
/// its name. Moving to another profile's Space reloads the tab there.
struct MoveToSpaceItems: View {
    let model: BrowserModel
    let tabID: AxoCore.Tab.ID

    var body: some View {
        ForEach(model.moveToSpaceGroups) { group in
            if let profile = group.profileName {
                Section(profile) { buttons(group.spaces) }
            } else {
                buttons(group.spaces)
            }
        }
    }

    private func buttons(_ spaces: [Space]) -> some View {
        ForEach(spaces) { space in
            Button(space.name) { Task { await model.moveTab(tabID, toSpace: space.id) } }
        }
    }
}
