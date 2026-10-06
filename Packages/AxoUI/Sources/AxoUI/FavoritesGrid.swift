import AxoCore
import AxoWeb
import SwiftUI

// Mac only for now; iPhone and iPad have their own chrome.
#if os(macOS)
/// The favorites grid at the top of the sidebar: one icon tile per favorite, shared by every
/// Space of the profile. Different from pinned tabs on purpose: no titles, no folders.
struct FavoritesGrid: View {
    let model: BrowserModel
    @State private var width: CGFloat = 0

    var body: some View {
        if !model.favorites.isEmpty {
            let columns = FavoritesLayout.columns(count: model.favorites.count, width: width)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: FavoritesLayout.spacing), count: max(columns, 1)),
                spacing: FavoritesLayout.spacing
            ) {
                ForEach(model.favorites) { favorite in
                    FavoriteTile(model: model, favorite: favorite)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Favorites")
            .accessibilityIdentifier("favoritesGrid")
        }
    }
}

/// One favorite: its site's icon on a rounded tile, highlighted while it's showing.
private struct FavoriteTile: View {
    let model: BrowserModel
    let favorite: Favorite

    private var isSelected: Bool { model.selectedTabID == favorite.id }
    private var title: String { BrowserModel.title(of: favorite) }

    var body: some View {
        let hasLeftHome = model.favoriteHasLeftHome(favorite)
        Button {
            model.select(favorite.id)
        } label: {
            icon
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.quaternary.opacity(0.6)))
                )
                .overlay {
                    if isSelected { RoundedRectangle(cornerRadius: 10).strokeBorder(.tint, lineWidth: 1.5) }
                }
                .overlay(alignment: .topTrailing) {
                    if hasLeftHome {
                        Circle().fill(.secondary).frame(width: 5, height: 5).padding(5)
                    }
                }
                .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(hasLeftHome ? "Away from favorite page" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("favoriteTile")
        .accessibilityAction(named: "Move Left") { Task { await model.moveFavorite(favorite.id, by: -1) } }
        .accessibilityAction(named: "Move Right") { Task { await model.moveFavorite(favorite.id, by: 1) } }
        .contextMenu { menu(hasLeftHome: hasLeftHome) }
        .draggable(favorite.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.first.flatMap(UUID.init(uuidString:)), dragged != favorite.id else { return false }
            Task { await drop(dragged) }
            return true
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let image = model.favicon(for: favorite.tab(in: model.space?.id ?? favorite.id)) {
            Image(platformImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
                .clipShape(.rect(cornerRadius: 4))
                .accessibilityHidden(true)
        } else {
            Image(systemName: "globe")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func menu(hasLeftHome: Bool) -> some View {
        Button("Make This Page the Favorite") { Task { await model.setFavoriteHome(favorite.id) } }
            .disabled(!hasLeftHome)
        Button("Move to Pinned Tabs") { Task { await model.moveFavoriteToPinned(favorite.id) } }
        Divider()
        Button("Move Left") { Task { await model.moveFavorite(favorite.id, by: -1) } }
            .disabled(model.favorites.first?.id == favorite.id)
        Button("Move Right") { Task { await model.moveFavorite(favorite.id, by: 1) } }
            .disabled(model.favorites.last?.id == favorite.id)
        Divider()
        Button("Unload") { Task { await model.closeTab(favorite.id) } }
            .disabled(model.pool.liveWebView(for: favorite.id) == nil)
        Button("Remove from Favorites") { Task { await model.removeFavorite(favorite.id) } }
    }

    /// Drops another favorite onto this one: it takes this tile's place.
    private func drop(_ dragged: Favorite.ID) async {
        let order = model.favorites.map(\.id)
        guard let from = order.firstIndex(of: dragged), let to = order.firstIndex(of: favorite.id) else { return }
        if from < to {
            await model.moveFavorite(dragged, after: favorite.id)
        } else {
            await model.moveFavorite(dragged, after: to > 0 ? order[to - 1] : nil)
        }
    }
}
#endif
