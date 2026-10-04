import AxoCore
import Foundation

extension BrowserModel {
    /// Applies a Focus filter: shows `spaceID` when a Focus with Axo's filter starts, and goes
    /// back to the Space shown before when it ends (`nil`). A Space that no longer exists is
    /// ignored.
    public func applyFocusSpace(_ spaceID: Space.ID?) async {
        if let spaceID {
            guard spaces.contains(where: { $0.id == spaceID }) else { return }
            // Keep the first Space from before any Focus, if Focuses change back to back.
            if spaceBeforeFocus == nil, space?.id != spaceID { spaceBeforeFocus = space?.id }
            await selectSpace(spaceID)
        } else if let previous = spaceBeforeFocus {
            spaceBeforeFocus = nil
            guard spaces.contains(where: { $0.id == previous }) else { return }
            await selectSpace(previous)
        }
    }
}
