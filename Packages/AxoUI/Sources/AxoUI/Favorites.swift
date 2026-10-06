import AxoCore
import AxoWeb
import Foundation

/// Favorites: the grid above the pinned tabs, shared by every Space of a profile. A favorite's
/// web view is keyed by its ID, so it's the same page in every Space of the profile.
extension BrowserModel {
    /// The selected favorite, if a favorite is showing.
    public var selectedFavorite: Favorite? {
        favorites.first { $0.id == selectedTabID }
    }

    /// The page showing: the selected tab, or the selected favorite as a stand-in tab.
    public var shownTab: AxoCore.Tab? {
        if let selectedTab { return selectedTab }
        guard let favorite = selectedFavorite, let space else { return nil }
        return favorite.tab(in: space.id)
    }

    /// Whether an ID belongs to one of the current profile's favorites.
    public func isFavorite(_ id: AxoCore.Tab.ID) -> Bool {
        favorites.contains { $0.id == id }
    }

    /// Whether a favorite's page has moved away from its home page.
    public func favoriteHasLeftHome(_ favorite: Favorite) -> Bool {
        guard let url = pool.state(for: favorite.id)?.url else { return false }
        return url != favorite.url
    }

    /// Shows favorite number `index` (0-based), as ⌘1–⌘9 do.
    public func showFavorite(at index: Int) {
        guard favorites.indices.contains(index) else { return }
        select(favorites[index].id)
    }

    /// Makes a tab a favorite of its Space's profile. It keeps its page and stays selected.
    public func addToFavorites(_ tabID: AxoCore.Tab.ID) async {
        guard let space else { return }
        do {
            let favorite = try await store.favorites.add(fromTab: tabID)
            // Update both lists before the next frame, so the page never disappears.
            favorites = try await store.favorites.favorites(for: space.profileID)
            tabs = try await store.tabs(in: space.id)
            onTabEvent?(.closed(tabID))
            if selectedTabID == tabID { activateSelectedTab() }
            announce("Added \(Self.title(of: favorite)) to Favorites")
        } catch {
            report(error, "Axo couldn't add the favorite.")
        }
    }

    /// Removes a favorite, closing its page.
    public func removeFavorite(_ id: Favorite.ID) async {
        guard let favorite = favorites.first(where: { $0.id == id }) else { return }
        do {
            try await store.favorites.remove(id)
            favorites.removeAll { $0.id == id }
            prompts.dismissAll(from: id)
            pool.discard(id)
            if selectedTabID == id { select(visibleTabOrder.first) }
            announce("Removed \(Self.title(of: favorite)) from Favorites")
        } catch {
            report(error, "Axo couldn't remove the favorite.")
        }
    }

    /// Turns a favorite into a pinned tab of the current Space, keeping its page.
    public func moveFavoriteToPinned(_ id: Favorite.ID) async {
        guard let space else { return }
        do {
            try await store.favorites.moveToPinned(id, in: space.id)
            tabs = try await store.tabs(in: space.id)
            favorites.removeAll { $0.id == id }
            onTabEvent?(.opened(id))
            if selectedTabID == id { activateSelectedTab() }
        } catch {
            report(error, "Axo couldn't pin the favorite.")
        }
    }

    /// Moves a favorite in the grid, after `anchor` or first when it's `nil`.
    public func moveFavorite(_ id: Favorite.ID, after anchor: Favorite.ID?) async {
        do {
            try await store.favorites.move(id, after: anchor)
        } catch {
            report(error, "Axo couldn't move the favorite.")
        }
    }

    /// Moves a favorite one place earlier (`-1`) or later (`1`) in the grid.
    public func moveFavorite(_ id: Favorite.ID, by offset: Int) async {
        guard let index = favorites.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard favorites.indices.contains(target) else { return }
        var order = favorites
        order.remove(at: index)
        await moveFavorite(id, after: target > 0 ? order[target - 1].id : nil)
    }

    /// Makes a favorite's current page its home page.
    public func setFavoriteHome(_ id: Favorite.ID) async {
        guard let url = pool.state(for: id)?.url else { return }
        do {
            try await store.favorites.setHome(url, title: pool.state(for: id)?.title ?? "", for: id)
        } catch {
            report(error, "Axo couldn't change the favorite.")
        }
    }

    /// Unloads a favorite: its page goes away and returns to its home page next time.
    func closeFavorite(_ id: Favorite.ID) {
        guard let favorite = favorites.first(where: { $0.id == id }) else { return }
        prompts.dismissAll(from: id)
        pool.discard(id)
        if selectedTabID == id { select(visibleTabOrder.first) }
        announce("Unloaded \(Self.title(of: favorite))")
    }

    /// Starts showing `profileID`'s favorites, if they aren't already.
    func observeFavorites(for profileID: Profile.ID) async {
        guard favoritesProfileID != profileID else { return }
        favoritesProfileID = profileID
        favorites = (try? await store.favorites.favorites(for: profileID)) ?? []
        favoritesObservationTask?.cancel()
        let observation = store.favorites.observe(for: profileID)
        favoritesObservationTask = Task { [weak self] in
            do {
                for try await _ in observation {
                    // Re-read, so a value observed before this model's own write can't undo it.
                    guard let self, self.favoritesProfileID == profileID else { return }
                    self.favorites = try await self.store.favorites.favorites(for: profileID)
                }
            } catch {
                self?.logger.error("Favorite observation failed: \(error)")
            }
        }
    }

    /// A favorite's title, or its host for one without a title.
    static func title(of favorite: Favorite) -> String {
        favorite.title.isEmpty ? (favorite.url.host() ?? favorite.url.absoluteString) : favorite.title
    }
}
