import AxoWeb
import SwiftUI

// Mac only; iPhone and iPad keep their own address field.
#if os(macOS)
/// The address bar at the top of the sidebar, as in Arc: a borderless pill, as tall as a
/// favorite's tile, showing the page's site ("example.com"), not its whole URL. Clicking it (or
/// ⌘L) edits the full address, selected so typing replaces it: in the command bar, or, with
/// Settings › General › Edit the address in › Sidebar, right here, with suggestions below
/// (``AddressSuggestions``). While the address is edited the bar turns to a raised, lighter
/// material, and under the pointer it darkens a shade. Copy Link and Site Settings appear as separate buttons while the pointer is over
/// it, and a thin line along its bottom shows the page loading.
struct SidebarAddressBar: View {
    let model: BrowserModel
    @AppStorage(AddressBarSettings.showsFullAddressKey) private var showsFullAddress = false
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // One container, not a Group (which would hand each modifier to the branch showing), so
        // the popover, the anchor, and on-screen tracking stay put while the bar switches between
        // the pill and the field.
        ZStack {
            if model.isAddressEditedInSidebar {
                AddressBarField(model: model)
            } else {
                pillButton
            }
        }
        .anchorPreference(key: AddressBarBounds.self, value: .bounds) { $0 }
        .onAppear { model.isSidebarAddressBarOnScreen = true }
        .onDisappear { model.isSidebarAddressBarOnScreen = false }
        // Site Settings hangs from the bar, which stays when the pointer leaves (the hover
        // button doesn't), whether it opened from there or from View › Site Settings….
        .popover(isPresented: Binding(get: { model.isShowingSiteSettings }, set: { model.isShowingSiteSettings = $0 }), arrowEdge: .bottom) {
            SiteSettingsView(model: model).windowAppearance()
        }
    }

    /// The pill, as one VoiceOver button with the address as its value.
    private var pillButton: some View {
        // A data: page's address can hold a whole file; the tooltip and VoiceOver get the start.
        let address = model.shownPageURL.map { String($0.absoluteString.prefix(AddressBarSettings.maxShownAddressLength)) }
        return pill
            .onHover { isHovering = $0 }
            .help(address ?? "Search or enter address")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Address")
            .accessibilityValue(notSecurePrefix + (address ?? ""))
            .accessibilityHint(model.editsAddressInSidebar ? "Edits the address" : "Edits the address in the command bar")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.editAddress() }
            .accessibilityActions {
                if address != nil {
                    Button("Copy Link") { model.copyShownPageLink() }
                }
                if model.siteSettingsOrigin != nil {
                    Button("Site Settings") { Task { await model.showSiteSettings() } }
                }
            }
            .accessibilityIdentifier("sidebarAddressBar")
    }

    /// "Not secure, " before the address for VoiceOver, on a plain-http site.
    private var notSecurePrefix: String {
        AddressDisplay.shown(for: model.shownPageURL)?.kind == .notSecure ? "Not secure, " : ""
    }

    /// The pill: the site, the loading line, and, while hovered, the trailing buttons.
    private var pill: some View {
        // The command bar is editing this address: the bar shows it's the one being changed.
        let isEditing = model.commandBarEditedTabID != nil && model.isCommandBarVisible
        return Button {
            model.editAddress()
        } label: {
            label
                .animation(.easeOut(duration: 0.18), value: model.addressBarNotice?.id)
        }
        .buttonStyle(.plain)
        .addressBarMaterial(raised: isEditing, hovered: isHovering)
        .overlay(alignment: .bottom) { LoadingLine(page: model.selectedPage) }
        .clipShape(.rect(cornerRadius: FavoritesLayout.tileCornerRadius))
        .addressBarShadow(raised: isEditing)
        // The hover buttons sit over the text's trailing end, so the site never moves.
        .overlay(alignment: .trailing) {
            if isHovering, model.shownPageURL != nil {
                hoverButtons
            }
        }
    }

    private var label: some View {
        // A notice for the bar ("Link copied") takes the address's place for a moment: the
        // address rises and fades out, then the notice rises into view; on the way back the
        // notice sinks out and the address drops back in. Both stay inside the bar's frame, so
        // nothing around them moves. With Reduce Motion, they only fade.
        ZStack {
            if let notice = model.addressBarNotice {
                noticeLabel(notice)
                    .transition(swapTransition(from: .bottom))
            } else {
                addressLabel
                    .transition(swapTransition(from: .top))
            }
        }
        .frame(height: FavoritesLayout.tileHeight)
        .clipped()
    }

    /// Slides in from and out toward `edge` by a few points while fading; the incoming label
    /// waits for the outgoing one to clear.
    private func swapTransition(from edge: Edge) -> AnyTransition {
        let slide = reduceMotion ? AnyTransition.opacity
            : .offset(y: edge == .top ? -10 : 10).combined(with: .opacity)
        return .asymmetric(
            insertion: slide.animation(.easeOut(duration: 0.18).delay(0.12)),
            removal: slide.animation(.easeIn(duration: 0.12))
        )
    }

    private func noticeLabel(_ notice: Notice) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark")
                .fontWeight(.semibold)
            Text(notice.message)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 14))
        .padding(.horizontal, 12)
        .frame(height: FavoritesLayout.tileHeight)
        .contentShape(.rect(cornerRadius: FavoritesLayout.tileCornerRadius))
    }

    private var addressLabel: some View {
        let shown = AddressDisplay.shown(for: model.shownPageURL, fullAddress: showsFullAddress)
        return HStack(spacing: 5) {
            switch shown?.kind {
            case .notSecure?:
                Image(systemName: "lock.slash")
                    .foregroundStyle(.secondary)
                    .help("Not Secure: this page's connection isn't encrypted")
            case .search?:
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
            default:
                EmptyView()
            }
            Text(verbatim: shown?.text ?? "Search or enter address")
                .foregroundStyle(shown == nil ? .secondary : .primary)
                .lineLimit(1)
                // A host keeps its end, where the site's own domain is ("…account-verify.evil.example").
                .truncationMode(showsFullAddress ? .middle : (shown?.kind == .search ? .tail : .head))
            Spacer(minLength: 0)
        }
        .font(.system(size: 14))
        .padding(.leading, 12)
        // While the pointer is over the bar, the text makes room for the buttons rather than
        // passing under them.
        .padding(.trailing, isHovering && model.shownPageURL != nil ? 74 : 12)
        // As tall as a favorite's tile.
        .frame(height: FavoritesLayout.tileHeight)
        .contentShape(.rect(cornerRadius: FavoritesLayout.tileCornerRadius))
    }

    /// Copy Link and Site Settings, each its own button.
    private var hoverButtons: some View {
        HStack(spacing: 4) {
            HoverButton(title: "Copy Link", systemImage: "link", identifier: "copyLinkButton") {
                model.copyShownPageLink()
            }
            HoverButton(title: "Site Settings", systemImage: "slider.horizontal.3", identifier: "siteSettingsButton") {
                Task { await model.showSiteSettings() }
            }
            .disabled(model.siteSettingsOrigin == nil)
        }
        .padding(.trailing, 6)
        // Reachable from the keyboard (⇧⌘C, View › Site Settings…) and as VoiceOver actions on
        // the pill, so these copies stay out of the accessibility tree.
        .accessibilityHidden(true)
    }
}

/// One of the address bar's hover buttons: an icon on its own small raised square.
private struct HoverButton: View {
    let title: String
    let systemImage: String
    let identifier: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isEnabled ? .secondary : .tertiary)
                .frame(width: 28, height: 28)
                .background(isHovering && isEnabled ? AnyShapeStyle(.background.secondary) : AnyShapeStyle(.background),
                            in: .rect(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator, lineWidth: 0.5))
                .contentShape(.rect(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}

/// The address bar while its address is edited in the sidebar: a field on the raised material,
/// typing into the command bar's query. ↑ and ↓ move through the suggestions below, Return opens
/// the highlighted one (a page loads in the same tab), and Esc or clicking elsewhere stops
/// editing.
private struct AddressBarField: View {
    let model: BrowserModel
    @FocusState private var isFocused: Bool
    @State private var selection: TextSelection?

    var body: some View {
        HStack(spacing: 6) {
            TextField("Search or enter address", text: Binding(
                get: { model.commandQuery },
                set: { model.setCommandQuery($0) }
            ), selection: $selection)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .focused($isFocused)
            .autocorrectionDisabled()
            .accessibilityLabel("Address")
            .accessibilityHint("Search or enter an address. Use the up and down arrow keys to choose a suggestion.")
            .accessibilityIdentifier("sidebarAddressField")
            .onSubmit { Task { await model.runCommand() } }
            .onExitCommandIfAvailable { model.hideCommandBar() }
            .onKeyPress(.downArrow) { model.moveCommandSelection(by: 1); return .handled }
            .onKeyPress(.upArrow) { model.moveCommandSelection(by: -1); return .handled }
        }
        .padding(.horizontal, 12)
        .frame(height: FavoritesLayout.tileHeight)
        .addressBarMaterial(raised: true)
        // The page's own loading bar gives way to this one in this mode, so it stays while editing.
        .overlay(alignment: .bottom) { LoadingLine(page: model.selectedPage) }
        .clipShape(.rect(cornerRadius: FavoritesLayout.tileCornerRadius))
        .addressBarShadow(raised: true)
        .task {
            isFocused = true
            selectAll()
        }
        .onChange(of: model.commandQuerySelectionRequest) { selectAll() }
        // Focus moving elsewhere (a click on the page or sidebar, Tab, ⌘F) stops editing, as in
        // Dia, and leaves focus where it went. (Suggestions are buttons, which don't take focus.)
        .onChange(of: isFocused) {
            guard !isFocused else { return }
            Task {
                guard !isFocused, model.isAddressEditedInSidebar else { return }
                model.hideCommandBar(focusingPage: false)
            }
        }
    }

    /// Selects the whole query a turn later, once the field holds it and focus.
    private func selectAll() {
        Task {
            let query = model.commandQuery
            selection = TextSelection(range: query.startIndex..<query.endIndex)
        }
    }
}

/// The suggestions below an address edited in the sidebar: the command bar's results, in a
/// raised panel as wide as the address bar, drawn over the sidebar (``SidebarView`` places it
/// from ``AddressBarBounds``).
struct AddressSuggestions: View {
    let model: BrowserModel
    /// The rows' height, so the panel is only as tall as its rows (up to a limit).
    @State private var rowsHeight: CGFloat = 0

    var body: some View {
        if !model.commandResults.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(model.commandResults.enumerated()), id: \.element.id) { index, result in
                            // A button, which a click doesn't give focus, so the field keeps it
                            // until the row runs.
                            Button {
                                Task { await model.runCommand(at: index) }
                            } label: {
                                CommandRow(model: model, result: result, isSelected: index == model.commandSelection, showsHint: false)
                            }
                            .buttonStyle(.plain)
                            .id(result.id)
                        }
                    }
                    .padding(4)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
                    // The rows' container is what VoiceOver enters, so it carries the name.
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Suggestions")
                }
                .frame(height: min(rowsHeight, 320))
                .onChange(of: model.commandSelection) {
                    guard model.commandResults.indices.contains(model.commandSelection) else { return }
                    proxy.scrollTo(model.commandResults[model.commandSelection].id)
                }
            }
            .background(.background, in: .rect(cornerRadius: FavoritesLayout.tileCornerRadius))
            .overlay(RoundedRectangle(cornerRadius: FavoritesLayout.tileCornerRadius).strokeBorder(.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Suggestions")
            .accessibilityIdentifier("addressSuggestions")
        }
    }
}

/// Where the sidebar's address bar is, so its suggestions can hang below it.
struct AddressBarBounds: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

extension View {
    /// The address bar's fill: the favorites' tile at rest, a shade darker under the pointer (so
    /// it's clear what a click will do), and a lighter raised surface while its address is edited.
    fileprivate func addressBarMaterial(raised: Bool, hovered: Bool = false) -> some View {
        let fill: AnyShapeStyle = raised ? AnyShapeStyle(.background)
            : hovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quaternary.opacity(0.6))
        return background(fill, in: .rect(cornerRadius: FavoritesLayout.tileCornerRadius))
            .animation(.easeOut(duration: 0.12), value: hovered)
    }

    /// The raised address bar's soft shadow and hairline.
    fileprivate func addressBarShadow(raised: Bool) -> some View {
        overlay {
            if raised {
                RoundedRectangle(cornerRadius: FavoritesLayout.tileCornerRadius).strokeBorder(.separator, lineWidth: 0.5)
            }
        }
        .shadow(color: .black.opacity(raised ? 0.12 : 0), radius: 3, y: 1)
        .animation(.easeOut(duration: 0.15), value: raised)
    }
}

/// A thin line along the address bar's bottom edge showing the page's loading progress.
private struct LoadingLine: View {
    let page: WebTabState?

    var body: some View {
        if let page, page.isLoading {
            GeometryReader { geometry in
                Rectangle()
                    .fill(.tint)
                    .frame(width: geometry.size.width * max(0.08, page.estimatedProgress))
                    .animation(.easeOut(duration: 0.2), value: page.estimatedProgress)
            }
            .frame(height: 2)
            .accessibilityHidden(true)
        }
    }
}

/// The address bar's settings, read with `@AppStorage` (the app picks the store, so UI tests
/// never change the person's own).
enum AddressBarSettings {
    /// Settings › General › "Show full website address": the whole URL instead of the site.
    static let showsFullAddressKey = "showsFullWebsiteAddress"
    /// View › Show Address Bar in Sidebar.
    static let showsSidebarAddressBarKey = "showsSidebarAddressBar"
    /// The longest address the tooltip and VoiceOver get.
    static let maxShownAddressLength = 2048
}
#endif
