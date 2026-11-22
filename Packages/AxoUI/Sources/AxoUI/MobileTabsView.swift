#if os(iOS)
import AxoCore
import AxoWeb
import SwiftUI

/// The iPhone's tabs view (#182), as the iPhone board draws it: the Space's favorites, pinned
/// tabs, and today's tabs as cards on its theme, each card a picture of its page. Tapping a card
/// opens its page, which zooms up out of the card (and back into it from the bar's tabs
/// button); a card's × closes the tab, the cards after it moving into its place; New Tab adds
/// a card that opens the command bar. With Reduce Motion, pages and cards fade instead.
struct MobileTabsView: View {
    let model: BrowserModel
    /// The cards' zoom source, shared with the pushed page.
    let namespace: Namespace.ID
    /// The tab whose page showed last, whose card is outlined.
    let highlighted: AxoCore.Tab.ID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let space = model.space, !model.favorites.isEmpty {
                    favorites(in: space)
                }
                let pinned = Self.flatten(model.pinnedTree)
                if !pinned.isEmpty {
                    section("Pinned") {
                        ForEach(pinned) { tab in card(for: tab, closes: false) }
                    }
                }
                section("Today") {
                    ForEach(model.unpinnedTabs) { tab in card(for: tab, closes: true) }
                    newTabCard
                }
            }
            .padding(16)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0.2), value: model.unpinnedTabs.map(\.id))
        }
        .background { themeBackground.ignoresSafeArea() }
        .navigationTitle(model.space?.name ?? "Axo")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { MobileSpacesMenu(model: model) }
            ToolbarItem(placement: .primaryAction) {
                Button("New Tab", systemImage: "plus") { model.beginNewTab() }
                    .accessibilityIdentifier("newTabButton")
            }
        }
        .accessibilityIdentifier("tabsView")
    }

    /// The Space's theme behind the cards, or the system's grouped background without one.
    @ViewBuilder
    private var themeBackground: some View {
        if let colors = model.space?.theme?.colors.map(Color.init(themeColor:)), !colors.isEmpty {
            LinearGradient(colors: colors.count == 1 ? [colors[0], colors[0]] : colors, startPoint: .top, endPoint: .bottom)
                .opacity(0.85)
        } else {
            Color(uiColor: .systemGroupedBackground)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, spacing: 14, content: content)
        }
    }

    private func favorites(in space: Space) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Favorites").font(.headline).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(model.favorites) { favorite in
                    let tab = favorite.tab(in: space.id)
                    Button { model.select(favorite.id) } label: {
                        VStack(spacing: 4) {
                            FaviconImage(image: model.favicon(for: tab))
                                .frame(width: 28, height: 28)
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .background(.regularMaterial, in: .rect(cornerRadius: 12))
                            Text(TabRow.displayTitle(for: tab)).font(.caption2).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .matchedTransitionSource(id: favorite.id, in: namespace)
                    .accessibilityLabel(TabRow.displayTitle(for: tab))
                    .accessibilityIdentifier("favoriteCard")
                }
            }
        }
    }

    private func card(for tab: AxoCore.Tab, closes: Bool) -> some View {
        MobileTabCard(model: model, tab: tab, isSelected: tab.id == highlighted, closes: closes)
            .matchedTransitionSource(id: tab.id, in: namespace)
            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .scale(scale: 0.6).combined(with: .opacity),
                                                              removal: .move(edge: .leading).combined(with: .opacity)))
    }

    private var newTabCard: some View {
        Button { model.beginNewTab() } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 26, weight: .medium))
                Text("New Tab").font(.subheadline)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: MobileTabCard.height)
            .background(.thinMaterial, in: .rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("newTabCard")
    }

    /// Pinned tabs in sidebar order, folders' tabs included.
    static func flatten(_ nodes: [PinnedNode]) -> [AxoCore.Tab] {
        nodes.flatMap { node -> [AxoCore.Tab] in
            switch node {
            case .tab(let tab): [tab]
            case .folder(_, let children): flatten(children)
            }
        }
    }
}

/// A tab's card: a picture of its page with its icon and title, and × for an open tab.
struct MobileTabCard: View {
    static let height: CGFloat = 196

    let model: BrowserModel
    let tab: AxoCore.Tab
    let isSelected: Bool
    let closes: Bool
    @State private var picture: UIImage?

    var body: some View {
        Button { model.select(tab.id) } label: {
            VStack(spacing: 0) {
                ZStack {
                    Color(uiColor: .secondarySystemBackground)
                    if let picture {
                        Image(uiImage: picture).resizable().scaledToFill()
                    } else {
                        FaviconImage(image: model.favicon(for: tab)).frame(width: 32, height: 32)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 150)
                .clipped()
                HStack(spacing: 6) {
                    FaviconImage(image: model.favicon(for: tab)).frame(width: 14, height: 14)
                    Text(TabRow.displayTitle(for: tab)).font(.caption.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 46)
                .background(.regularMaterial)
            }
            .frame(height: Self.height)
            .clipShape(.rect(cornerRadius: 16))
            // In the Space's color, as in-app accents are.
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(isSelected ? (model.space?.markerColor ?? .accentColor) : .clear, lineWidth: 2))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if closes {
                Button {
                    Task { await model.closeTab(tab.id, byPerson: true) }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                        .background(.ultraThinMaterial, in: .circle)
                }
                .buttonStyle(.plain)
                .padding(6)
                .accessibilityLabel("Close \(TabRow.displayTitle(for: tab))")
                .accessibilityIdentifier("closeCardButton")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TabRow.displayTitle(for: tab))
        .accessibilityIdentifier("tabCard")
        .task(id: tab.id) {
            if let data = await model.pool.previewSnapshot(for: tab.id) { picture = UIImage(data: data) }
        }
    }
}

/// The Spaces menu: choose which Space shows.
struct MobileSpacesMenu: View {
    let model: BrowserModel

    var body: some View {
        Menu {
            ForEach(model.spaces) { space in
                Button {
                    Task { await model.selectSpace(space.id) }
                } label: {
                    if space.id == model.space?.id {
                        Label(space.name, systemImage: "checkmark")
                    } else {
                        Text(space.name)
                    }
                }
            }
        } label: {
            Label("Spaces", systemImage: "square.stack")
        }
        .accessibilityIdentifier("spacesMenu")
    }
}

/// A favicon, or a globe without one.
struct FaviconImage: View {
    let image: PlatformImage?

    var body: some View {
        if let image {
            Image(platformImage: image).resizable().scaledToFit()
        } else {
            Image(systemName: "globe").resizable().scaledToFit().foregroundStyle(.secondary)
        }
    }
}
#endif
