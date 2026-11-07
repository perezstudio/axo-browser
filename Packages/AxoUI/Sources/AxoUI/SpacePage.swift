import AxoCore
import SwiftUI

#if os(macOS)
/// One Space's page in the sidebar's strip of Spaces (#84): its favorites, pinned tabs, and tabs.
/// Every Space has one, always drawn, so a swipe slides the real page in. Every page draws its
/// rows the same way (``SidebarSections``) from the same kind of data: the shown Space's from the
/// model, the others' from their kept rows (``SpaceSidebarPreview``). A page that isn't shown
/// takes no clicks and stays out of VoiceOver; when its Space is shown it turns live in place,
/// with the same rows, so nothing reloads.
struct SpacePage: View {
    let model: BrowserModel
    let space: Space
    let isShown: Bool
    /// How far to shift the page's favorites against the page's own movement: the whole way
    /// while sliding between two Spaces of one profile, whose favorites are the same and so stay
    /// still; otherwise none, and they slide with the page.
    var favoritesOffset: CGFloat = 0

    /// The page's rows: the model's for the shown Space, the kept ones otherwise.
    private var data: SpaceSidebarPreview? { isShown ? model.shownSpaceRows : model.spacePreviews[space.id] }
    private var preview: SpaceSidebarPreview? { isShown ? nil : model.spacePreviews[space.id] }

    var body: some View {
        // Folders are selectable too, so the keyboard can reach, open, and act on them.
        List(selection: Binding(
            get: { isShown ? model.selectedSidebarItem : previewSelection },
            set: { if isShown { model.selectSidebarItem($0) } }
        )) {
            if let data {
                SidebarSections(model: model, data: data)
            }
        }
        // The shown page's list is the sidebar UI tests and VoiceOver find, as before the pages.
        .accessibilityIdentifier(isShown ? "sidebar" : "")
        // Favorites sit above the pinned tabs, each Space's page showing all of its profile's.
        .safeAreaInset(edge: .top, spacing: 0) {
            Group {
                if isShown {
                    FavoritesGrid(model: model)
                } else if let preview {
                    PreviewFavoritesGrid(model: model, preview: preview)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .offset(x: favoritesOffset)
        }
        .allowsHitTesting(isShown)
        .accessibilityHidden(!isShown)
    }

    /// The row a kept Space's selection shows on: a split's row for any of its panes.
    private var previewSelection: PinnedItem? {
        guard let preview, let selected = preview.selectedTabID else { return nil }
        let leader = preview.splitPanes.first { $0.value.contains { $0.id == selected } }?.key
        return .tab(leader ?? selected)
    }
}

#endif
