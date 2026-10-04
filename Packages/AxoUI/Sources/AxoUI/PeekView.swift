import AxoCore
import AxoWeb
import SwiftUI

/// Peek: a card over the page showing a link from a pinned tab. Open it as a tab, show it next to
/// the pinned tab in a split view, or close it (Esc, the close button, or clicking outside).
struct PeekOverlay: View {
    let model: BrowserModel
    let peek: Peek
    let profileID: Profile.ID

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture { model.closePeek() }
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                header
                Divider()
                WebViewHost(tab: peek.tab, profileID: profileID, pool: model.pool)
                    .overlay(alignment: .top) {
                        if let page = model.peekPage, page.isLoading {
                            ProgressView(value: page.estimatedProgress)
                                .progressViewStyle(.linear)
                                .controlSize(.small)
                                .accessibilityLabel("Loading")
                        }
                    }
            }
            .background(.background)
            .clipShape(.rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
            .padding(.horizontal, 48)
            .padding(.vertical, 28)
            // VoiceOver stays in Peek while it's open, like a sheet.
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityLabel("Peek")
            .accessibilityIdentifier("peek")
        }
        .onExitCommand { model.closePeek() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            Button("Open in Split View", systemImage: "rectangle.split.2x1") {
                Task { await model.promotePeek(inSplit: true) }
            }
            .help("Open in Split View next to the pinned tab")
            .accessibilityIdentifier("peekOpenInSplitButton")
            Button("Open as Tab", systemImage: "arrow.up.forward.app") {
                Task { await model.promotePeek() }
            }
            .help("Open as Tab (⌘↩)")
            .accessibilityIdentifier("peekOpenAsTabButton")
            Button("Close", systemImage: "xmark") { model.closePeek() }
                .help("Close Peek (Esc)")
                .accessibilityIdentifier("peekCloseButton")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// The page's title, or its host while it loads.
    private var title: String {
        let page = model.peekPage
        if let pageTitle = page?.title, !pageTitle.isEmpty { return pageTitle }
        let url = page?.url ?? peek.tab.url
        return url.host() ?? url.absoluteString
    }
}
