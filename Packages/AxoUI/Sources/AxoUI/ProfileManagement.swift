import AxoCore
import AxoWeb
import Foundation

extension BrowserModel {
    /// The Spaces that use a profile, in sidebar order.
    public func spaces(using profileID: Profile.ID) -> [Space] {
        spaces.filter { $0.profileID == profileID }
    }

    /// Creates a profile with its own cookies and website data.
    @discardableResult
    public func addProfile(named name: String) async -> Profile? {
        do {
            return try await store.createProfile(name: name)
        } catch {
            report(error, "Axo couldn't create the profile.")
            return nil
        }
    }

    /// Renames a profile.
    public func renameProfile(_ id: Profile.ID, to name: String) async {
        do {
            try await store.renameProfile(id: id, to: name)
        } catch {
            report(error, "Axo couldn't rename the profile.")
        }
    }

    /// Deletes a profile and its website data for good, first moving the Spaces that use it to
    /// `replacement`. Those Spaces' pages reload with their new profile's cookies.
    public func deleteProfile(_ id: Profile.ID, movingSpacesTo replacement: Profile.ID?) async {
        let name = allProfiles.first { $0.id == id }?.name ?? "Profile"
        do {
            let movedTabs = try await store.deleteProfile(id: id, movingSpacesTo: replacement)
            await discardWebViews(for: movedTabs)
            await pool.removeWebsiteData(for: id)
            announce("Deleted \(name)")
        } catch {
            report(error, "Axo couldn't delete the profile.")
        }
    }

    /// Moves a Space to another profile. Its pages reload with that profile's cookies and
    /// website data.
    public func moveSpace(_ spaceID: Space.ID, toProfile profileID: Profile.ID) async {
        do {
            await discardWebViews(for: try await store.moveSpace(id: spaceID, toProfile: profileID))
        } catch {
            report(error, "Axo couldn't move the Space.")
        }
    }

    /// Signs a profile out of every site by removing its cookies and website data.
    public func clearWebsiteData(for profileID: Profile.ID) async {
        await pool.clearWebsiteData(for: profileID)
        // That clears the engine's own copy of site answers too; Axo's still count.
        await syncLastingPermissions(profileID: profileID)
        announce("Website data cleared")
    }

    /// Discards tabs' pages, which belong to their old profile's website data. If the shown
    /// Space moved, it takes its new profile first (from the store, without waiting for the Spaces
    /// observation), so its shown tab's new page uses the new profile's data, never the old one's.
    private func discardWebViews(for tabIDs: [AxoCore.Tab.ID]) async {
        for tabID in tabIDs {
            if fullscreenTabID == tabID { exitPageFullscreen() }
            prompts.dismissAll(from: tabID)
            pool.discard(tabID)
        }
        // Without the Space's new record (a failed read, or one a newer read overtook, which makes
        // the page itself), the page waits: made now, it would use the old profile.
        guard (try? await refreshSpaces()) == true else { return }
        if let selectedTabID, tabIDs.contains(selectedTabID), !pool.isLive(selectedTabID) {
            activateSelectedTab()
        }
    }

    func observeProfiles() {
        profilesObservationTask?.cancel()
        let observation = store.observeProfiles()
        profilesObservationTask = Task { [weak self] in
            do {
                for try await profiles in observation {
                    self?.allProfiles = profiles
                }
            } catch {
                self?.logger.error("Profile observation failed: \(error)")
            }
        }
    }
}

extension BrowserModel {
    /// Sets a Space's color and icon; `nil` clears either.
    public func setSpaceAppearance(_ spaceID: Space.ID, color: SpaceColor?, icon: String?) async {
        do {
            try await store.setSpaceAppearance(id: spaceID, color: color?.rawValue, icon: icon)
        } catch {
            report(error, "Axo couldn't change the Space.")
        }
    }

    /// Moves a Space in the Space order, after `anchor` or first when it's `nil`.
    public func moveSpace(_ spaceID: Space.ID, after anchor: Space.ID?) async {
        do {
            // The Space observation updates `spaces`.
            try await store.moveSpace(id: spaceID, after: anchor)
        } catch {
            report(error, "Axo couldn't move the Space.")
        }
    }
}
