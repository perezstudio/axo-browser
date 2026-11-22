import AxoCore
import SwiftUI
import UniformTypeIdentifiers

/// A list of rows a sidebar drag can land in (#77): the pinned section's top level or one of its
/// folders, or the tabs section.
nonisolated public enum SidebarCollection: Hashable, Sendable {
    case pinned(Folder.ID?)
    case tabs
}

extension BrowserModel {
    /// Moves rows where a drag put them (#77): into a level of the pinned section (pinning tabs)
    /// or the tabs section (unpinning them), before `target` or at the end. A split moves as one,
    /// a folder can't go into itself, and folders stay in the pinned section. Each moved row gets
    /// a sort key between its new neighbours, so one row changes per row moved.
    public func moveSidebarItems(_ items: [PinnedItem], to collection: SidebarCollection, before target: PinnedItem?) async {
        // One drop at a time, in order: each computes its place from the sidebar the one before
        // left (two quick drops raced, and a moved anchor failed the second).
        let previous = sidebarMoveTask
        let task = Task { [weak self] in
            await previous?.value
            await self?.applySidebarMove(items, to: collection, before: target)
        }
        sidebarMoveTask = task
        await task.value
    }

    private func applySidebarMove(_ items: [PinnedItem], to collection: SidebarCollection, before target: PinnedItem?) async {
        guard space != nil else { return }
        do {
            switch collection {
            case .pinned(let folder):
                try await movePinned(items, into: folder, before: target)
            case .tabs:
                try await moveToTabsSection(items, before: target)
            }
            try await refreshSidebar()
        } catch {
            report(error, "Axo couldn't move that.")
        }
    }

    /// A row dropped on Favorites (#77): its tab becomes a favorite, keeping its ID (and page),
    /// placed before `favorite` or at the end. Folders don't become favorites.
    public func dropTabOnFavorites(_ tabID: AxoCore.Tab.ID, before favorite: Favorite.ID?) async {
        // A split's row stands for all its panes; one tab of it can't become a favorite by drag.
        guard tabs.contains(where: { $0.id == tabID }), split(of: tabID) == nil else { return }
        await addToFavorites(tabID)
        guard favorites.contains(where: { $0.id == tabID }) else { return }
        let others = favorites.filter { $0.id != tabID }
        let anchor: Favorite.ID? = if let favorite, let index = others.firstIndex(where: { $0.id == favorite }) {
            index == 0 ? nil : others[index - 1].id
        } else {
            others.last?.id
        }
        await moveFavorite(tabID, after: anchor)
    }

    /// A favorite dropped in the sidebar (#77): it becomes a pinned tab (or, in the tabs section,
    /// a tab) at the drop point, keeping its ID, so its page carries over.
    public func moveFavoriteToSidebar(_ id: Favorite.ID, to collection: SidebarCollection, before target: PinnedItem?) async {
        guard favorites.contains(where: { $0.id == id }) else { return }
        // Straight into its section, so it's never a synced pinned tab on its way to the tabs.
        await moveFavoriteToPinned(id, pinned: collection != .tabs)
        guard tabs.contains(where: { $0.id == id }) else { return }
        await moveSidebarItems([.tab(id)], to: collection, before: target)
    }

    /// The rows to move, once each: a split moves by its row's tab alone, since the store keeps
    /// a split's other panes right after the pane it moves (moving each pane flipped the split's
    /// order and wrote every pane again per pane).
    private func expanded(_ items: [PinnedItem]) -> [PinnedItem] {
        var result: [PinnedItem] = []
        for item in items where !result.contains(item) {
            if case .tab(let id) = item, let split = split(of: id),
               result.contains(where: { if case .tab(let other) = $0 { self.split(of: other)?.id == split.id } else { false } }) {
                continue
            }
            result.append(item)
        }
        return result
    }

    /// The item to put a row after so it lands after `item`'s row: for a split's row, its last
    /// pane in sidebar order, so nothing lands between the panes.
    func anchorAfterRow(_ item: PinnedItem) -> PinnedItem {
        guard case .tab(let id) = item, let split = split(of: id) else { return item }
        let paneIDs = Set(panes(of: split.id).map(\.id))
        return tabs.last { paneIDs.contains($0.id) }.map { .tab($0.id) } ?? item
    }

    private func movePinned(_ items: [PinnedItem], into folder: Folder.ID?, before target: PinnedItem?) async throws {
        // A folder can't go into itself or a folder inside it.
        if let folder {
            for case .folder(let moving) in items where PinnedNode.folderAndDescendants(moving, in: pinnedTree).contains(folder) {
                return
            }
        }
        let moving = expanded(items)
        let level = PinnedNode.items(at: folder, in: pinnedTree).filter { !moving.contains($0) }
        var anchor: PinnedItem? = if let target, let index = level.firstIndex(of: target) {
            index == 0 ? nil : anchorAfterRow(level[index - 1])
        } else {
            level.last.map(anchorAfterRow)
        }
        for item in moving {
            try await store.movePinnedItem(item, into: folder, after: anchor)
            anchor = item
        }
    }

    private func moveToTabsSection(_ items: [PinnedItem], before target: PinnedItem?) async throws {
        // Folders belong to the pinned section.
        let moving = expanded(items).compactMap { item -> AxoCore.Tab.ID? in
            if case .tab(let id) = item { return id }
            return nil
        }
        guard !moving.isEmpty else { return }
        for id in moving where tabs.first(where: { $0.id == id })?.isPinned == true {
            try await store.setPinned(false, tabID: id)
        }
        let section = unpinnedTabs.map(\.id).filter { !moving.contains($0) }
        var position: TabPosition = if case .tab(let targetID) = target, let index = section.firstIndex(of: targetID) {
            index == 0 ? .start : .after(section[index - 1])
        } else {
            .end
        }
        for id in moving {
            try await store.moveTab(id: id, to: position)
            position = .after(id)
        }
    }
}

/// What a sidebar row's or favorite's drag carries to Axo's drop targets (Favorites, a folder,
/// a section, a Space's dot, the page's edges), as text: `tab:<id>`, `folder:<id>`, or
/// `favorite:<id>`.
enum SidebarDragPayload {
    /// The text a row's drag carries.
    static func text(for item: PinnedItem) -> String {
        switch item {
        case .tab(let id): "tab:\(id.uuidString)"
        case .folder(let id): "folder:\(id.uuidString)"
        }
    }

    /// The text a favorite's tile drag carries.
    static func text(forFavorite id: Favorite.ID) -> String { "favorite:\(id.uuidString)" }

    static func item(from string: String) -> PinnedItem? {
        if string.hasPrefix("tab:") { return UUID(uuidString: String(string.dropFirst(4))).map(PinnedItem.tab) }
        if string.hasPrefix("folder:") { return UUID(uuidString: String(string.dropFirst(7))).map(PinnedItem.folder) }
        return nil
    }

    /// The favorite a tile's drag text names, or nil for anything else.
    static func favorite(from string: String) -> Favorite.ID? {
        string.hasPrefix("favorite:") ? UUID(uuidString: String(string.dropFirst(9))) : nil
    }

    /// The longest `data:` address a drag offers other apps; web addresses go at any length.
    static let maxDataAddressLength = 2048

    /// The address a drag offers other apps (#78): a web page's (`http`, `https`), or a short
    /// `data:` one; never a file's (Finder would copy the file), an extension's, or Axo's own.
    /// A web address loses any user name and password in it, which go no further than Axo.
    static func addressForOtherApps(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https":
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            components.user = nil
            components.password = nil
            return components.url
        case "data": return url.absoluteString.utf8.count <= maxDataAddressLength ? url : nil
        default: return nil
        }
    }

    /// The item provider a drag hands out: the payload as text, first, for Axo's drop targets,
    /// and, for a page with an address other apps can use, that address as a URL, so a row
    /// dropped in Finder, Mail, or Notes drops its link, as a tab dragged out of Safari does.
    /// On the hosted Mac, SwiftUI's drop targets took neither a drag type of Axo's own (declared,
    /// or with its conformance in code) nor text visible only to Axo's process, so the text is
    /// visible to every app, and a plain text field gets the ID. The text is registered as plain
    /// text only: an `NSString` object also registers itself as `public.url` (`tab:<id>` reads
    /// as a URL with the scheme `tab`), which would take the address's place.
    static func provider(for text: String, address: URL?) -> NSItemProvider {
        let provider = NSItemProvider()
        // The ID first: with the URL first, SwiftUI's `dropDestination(for: String.self)` read
        // the URL as the text (a row stopped dropping on a Space's dot).
        let data = Data(text.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        if let address = addressForOtherApps(address) {
            provider.registerObject(address as NSURL, visibility: .all)
        }
        return provider
    }
}

/// A favorite's tile drag (#77, #78), for `.draggable`: a button's `itemProvider` never started a
/// drag on the hosted Mac. It exports the ID as text first, for Axo's drop targets, then the
/// address other apps can use, as a URL, like ``SidebarDragPayload/provider(for:address:)``.
nonisolated struct FavoriteDrag: Transferable {
    let text: String
    let address: URL?

    static var transferRepresentation: some TransferRepresentation {
        // The ID first, as in ``SidebarDragPayload/provider(for:address:)``; no URL without an
        // address (the placeholder is never offered).
        DataRepresentation(exportedContentType: .utf8PlainText) { Data($0.text.utf8) }
        ProxyRepresentation(exporting: { $0.address ?? URL(string: "about:blank")! })
            .exportingCondition { $0.address != nil }
    }
}

extension View {
    /// Makes a sidebar row draggable (#77): it carries its ID as text (``SidebarDragPayload``)
    /// to the other sections, folders, Favorites, the Space dots, and the
    /// page's edges (a split, #78), and a tab's page address to other apps (#78). `address` is
    /// read when the drag starts, so it's the page's address then.
    func sidebarDraggable(_ item: PinnedItem, isEnabled: Bool, address: @escaping () -> URL? = { nil }) -> some View {
        itemProvider(isEnabled ? { SidebarDragPayload.provider(for: SidebarDragPayload.text(for: item), address: address()) } : nil)
    }
}

extension View {
    /// Lets a tab's row take a drop onto itself (#77): a row from elsewhere, or a favorite,
    /// lands just before it in its section. The section's insert only takes drops between rows.
    func sidebarRowDropTarget(model: BrowserModel, collection: SidebarCollection, item: PinnedItem,
                              isEnabled: Bool) -> some View {
        dropDestination(for: String.self, isEnabled: isEnabled) { texts, _ in
            guard let text = texts.first, SidebarDragPayload.item(from: text) != item else { return }
            Task { await model.receiveSidebarDrop(text, to: collection, before: item) }
        }
    }
}

extension DynamicViewContent {
    /// Makes one section's rows (a pinned level or the tabs section) reorderable, and lets it
    /// take rows dragged from the other sections and favorites dropped in (#77), at the drop
    /// point. Rows use the list's own move and insert, not SwiftUI 27's reorderable
    /// containers: with those, the sidebar list stopped selecting rows on a click and drawing
    /// the selected row.
    func sidebarDropTarget(model: BrowserModel, collection: SidebarCollection, items: [PinnedItem],
                           isEnabled: Bool) -> some DynamicViewContent {
        onMove(perform: isEnabled ? { source, destination in
            let moving = source.compactMap { items.indices.contains($0) ? items[$0] : nil }
            let before = SidebarDrop.target(before: destination, in: items, moving: moving)
            Task { await model.moveSidebarItems(moving, to: collection, before: before) }
        } : nil)
        .onInsert(of: [.utf8PlainText]) { index, providers in
            guard isEnabled else { return }
            let before = SidebarDrop.target(before: index, in: items, moving: [])
            for provider in providers {
                _ = provider.loadTransferable(type: String.self) { result in
                    guard let text = try? result.get() else { return }
                    Task { @MainActor in await model.receiveSidebarDrop(text, to: collection, before: before) }
                }
            }
        }
    }
}

/// Where a drop lands in one section of the sidebar (#77).
enum SidebarDrop {
    /// The row a drop at `index` goes before: the first row from `index` on that isn't being
    /// moved (dropping a row on its own place keeps it there), or nil for the end.
    static func target(before index: Int, in items: [PinnedItem], moving: [PinnedItem]) -> PinnedItem? {
        guard index >= 0 else { return nil }
        return items.dropFirst(index).first { !moving.contains($0) }
    }
}

extension BrowserModel {
    /// The address a tab's or favorite's drag offers other apps (#78): its page's address when it
    /// has a live page that's somewhere (a pinned tab away from its page drags where it is), or
    /// its record's (a hibernated tab, or a page still on `about:blank`).
    func dragAddress(for id: AxoCore.Tab.ID) -> URL? {
        liveDragAddress(for: id) ?? tabs.first { $0.id == id }?.url ?? favorites.first { $0.id == id }?.url
    }

    /// A favorite's drag address: as ``dragAddress(for:)``, without looking through the tabs.
    func dragAddress(forFavorite favorite: Favorite) -> URL? {
        liveDragAddress(for: favorite.id) ?? favorite.url
    }

    /// The live page's address, unless it has none yet or is still on `about:blank`.
    private func liveDragAddress(for id: AxoCore.Tab.ID) -> URL? {
        guard let live = pool.state(for: id)?.url, live.scheme?.lowercased() != "about" else { return nil }
        return live
    }

    /// A drop into a section of the sidebar from elsewhere (#77): a row from another section
    /// (`tab:<id>` or `folder:<id>`) moves there, and a favorite (`favorite:<id>`) becomes a tab
    /// there. Other text is ignored.
    func receiveSidebarDrop(_ text: String, to collection: SidebarCollection, before target: PinnedItem?) async {
        if let item = SidebarDragPayload.item(from: text) {
            await moveSidebarItems([item], to: collection, before: target)
        } else if let favorite = SidebarDragPayload.favorite(from: text), favorites.contains(where: { $0.id == favorite }) {
            await moveFavoriteToSidebar(favorite, to: collection, before: target)
        }
    }
}

/// A folder row as a drop target (#77): a row dropped on it moves inside, at the end, and a
/// closed folder springs open after the drag rests on it a moment, as on the board. It takes
/// only sidebar rows and favorites' tiles, never other text.
private struct FolderDropTarget: ViewModifier {
    let model: BrowserModel
    let folder: Folder
    @State private var springTask: Task<Void, Never>?
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .background {
                // The board's highlight while a drop would land in it.
                RoundedRectangle(cornerRadius: 6)
                    .fill(.tint.opacity(isTargeted ? 0.18 : 0))
                    .allowsHitTesting(false)
            }
            .dropDestination(for: String.self) { items, _ in
                // A favorite's tile: it becomes a pinned tab in the folder.
                if let text = items.first, let favorite = SidebarDragPayload.favorite(from: text),
                   model.favorites.contains(where: { $0.id == favorite }) {
                    Task { await model.moveFavoriteToSidebar(favorite, to: .pinned(folder.id), before: nil) }
                    return true
                }
                // A sidebar row (`tab:` or `folder:`); anything else isn't for a folder.
                let moving = items.compactMap(SidebarDragPayload.item(from:)).filter { $0 != .folder(folder.id) }
                guard !moving.isEmpty else { return false }
                Task { await model.moveSidebarItems(moving, to: .pinned(folder.id), before: nil) }
                return true
            } isTargeted: { targeted in
                isTargeted = targeted
                springTask?.cancel()
                guard targeted, !folder.isExpanded else { return }
                springTask = Task {
                    try? await Task.sleep(for: .milliseconds(700))
                    guard !Task.isCancelled else { return }
                    await model.setFolderExpanded(true, id: folder.id)
                }
            }
    }
}

extension View {
    func folderDropTarget(model: BrowserModel, folder: Folder) -> some View {
        modifier(FolderDropTarget(model: model, folder: folder))
    }
}

/// The Space's name row as a drop target while Pinned is empty (#77): a row dropped on it is
/// pinned, so the first pin can be a drag too ("above the line", as the board puts it).
private struct PinDropTarget: ViewModifier {
    let model: BrowserModel
    let isEnabled: Bool
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.tint.opacity(isTargeted ? 0.6 : 0), lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
                .dropDestination(for: String.self) { items, _ in
                    if let text = items.first, let favorite = SidebarDragPayload.favorite(from: text),
                       model.favorites.contains(where: { $0.id == favorite }) {
                        Task { await model.moveFavoriteToSidebar(favorite, to: .pinned(nil), before: nil) }
                        return true
                    }
                    let moving = items.compactMap(SidebarDragPayload.item(from:))
                    guard !moving.isEmpty else { return false }
                    Task { await model.moveSidebarItems(moving, to: .pinned(nil), before: nil) }
                    return true
                } isTargeted: { isTargeted = $0 }
        } else {
            content
        }
    }
}

extension View {
    /// Pins rows dropped here while Pinned is empty.
    func pinDropTarget(model: BrowserModel, isEnabled: Bool) -> some View {
        modifier(PinDropTarget(model: model, isEnabled: isEnabled))
    }
}
