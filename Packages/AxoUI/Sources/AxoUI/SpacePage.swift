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
    /// Which Space's list has keyboard focus, shared by every page (``SidebarView`` moves it to
    /// the shown Space's list on a switch). The list gets it from the keyboard (Full Keyboard
    /// Access, VoiceOver), and then the arrow keys move through its rows.
    var focusedList: FocusState<Space.ID?>.Binding
    /// Where the page's favorites go during a swipe: held still between two Spaces of one
    /// profile (drawn by one page only), otherwise sliding with the page.
    var favorites = SpaceSwipe.FavoritesPlacement()

    /// The page's rows: the model's for the shown Space, the kept ones otherwise.
    private var data: SpaceSidebarPreview? { isShown ? model.shownSpaceRows : model.spacePreviews[space.id] }
    private var preview: SpaceSidebarPreview? { isShown ? nil : model.spacePreviews[space.id] }

    var body: some View {
        // Folders are selectable too, so the keyboard can reach, open, and act on them.
        List(selection: Binding(
            get: { isShown ? model.selectedSidebarItem : previewSelection },
            set: { item in
                guard isShown else { return }
                model.selectSidebarItem(item)
                // A click on a tab hands keyboard focus to its page, as in Arc, so typing and
                // scrolling go there; with the list focused (the keyboard), it stays in the list.
                if case .tab = item, focusedList.wrappedValue != space.id { model.focusPage() }
            }
        )) {
            if let data {
                SidebarSections(model: model, data: data)
            }
        }
        .focused(focusedList, equals: space.id)
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
            .offset(x: favorites.offset)
            .opacity(favorites.isHidden ? 0 : 1)
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
