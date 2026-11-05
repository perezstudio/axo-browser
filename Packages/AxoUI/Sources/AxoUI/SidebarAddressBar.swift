import AxoWeb
import SwiftUI

// Mac only; iPhone and iPad keep their own address field.
#if os(macOS)
/// The address bar at the top of the sidebar, as in Arc: a borderless pill showing the page's site
/// ("example.com"), not its whole URL. Clicking it (or ⌘L) opens the command bar with the full
/// address selected, so typing replaces it. Copy Link and Site Settings appear while the pointer
/// is over it, and a thin line along its bottom shows the page loading.
struct SidebarAddressBar: View {
    let model: BrowserModel
    @AppStorage(AddressBarSettings.showsFullAddressKey) private var showsFullAddress = false
    @State private var isHovering = false

    var body: some View {
        // A data: page's address can hold a whole file; the tooltip and VoiceOver get the start.
        let address = model.shownPageURL.map { String($0.absoluteString.prefix(AddressBarSettings.maxShownAddressLength)) }
        pill
            .onHover { isHovering = $0 }
            .help(address ?? "Search or enter address")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Address")
            .accessibilityValue(notSecurePrefix + (address ?? ""))
            .accessibilityHint("Edits the address in the command bar")
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
            .onAppear { model.isSidebarAddressBarOnScreen = true }
            .onDisappear { model.isSidebarAddressBarOnScreen = false }
            // Site Settings hangs from the pill, which stays when the pointer leaves (the hover
            // button doesn't), whether it opened from there or from View › Site Settings….
            .popover(isPresented: Binding(get: { model.isShowingSiteSettings }, set: { model.isShowingSiteSettings = $0 }), arrowEdge: .bottom) {
                SiteSettingsView(model: model)
            }
    }

    /// "Not secure, " before the address for VoiceOver, on a plain-http site.
    private var notSecurePrefix: String {
        AddressDisplay.shown(for: model.shownPageURL)?.kind == .notSecure ? "Not secure, " : ""
    }

    /// The pill: the site, the loading line, and, while hovered, the trailing buttons.
    private var pill: some View {
        Button {
            model.editAddress()
        } label: {
            label
        }
        .buttonStyle(.plain)
        .background(.fill.quaternary, in: .rect(cornerRadius: 8))
        .overlay(alignment: .bottom) { LoadingLine(page: model.selectedPage) }
        .clipShape(.rect(cornerRadius: 8))
        // The hover buttons sit over the text's trailing end, so the site never moves.
        .overlay(alignment: .trailing) {
            if isHovering, model.shownPageURL != nil {
                hoverButtons
            }
        }
    }

    private var label: some View {
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
        .padding(.leading, 10)
        // While the pointer is over the bar, the text makes room for the buttons rather than
        // passing under them.
        .padding(.trailing, isHovering && model.shownPageURL != nil ? 62 : 10)
        .frame(height: 30)
        .contentShape(.rect(cornerRadius: 8))
    }

    private var hoverButtons: some View {
        HStack(spacing: 2) {
            Button("Copy Link", systemImage: "link") { model.copyShownPageLink() }
                .help("Copy Link")
                .accessibilityIdentifier("copyLinkButton")
            Button("Site Settings", systemImage: "slider.horizontal.3") {
                Task { await model.showSiteSettings() }
            }
            .help("Site Settings")
            .disabled(model.siteSettingsOrigin == nil)
            .accessibilityIdentifier("siteSettingsButton")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 6)
        .frame(height: 30)
        .background(.bar, in: .rect(cornerRadius: 8))
        // Reachable from the keyboard (⇧⌘C, View › Site Settings…) and as VoiceOver actions on
        // the pill, so these copies stay out of the accessibility tree.
        .accessibilityHidden(true)
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
