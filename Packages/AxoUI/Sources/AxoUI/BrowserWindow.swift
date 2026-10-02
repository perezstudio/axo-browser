import SwiftUI

/// The root view of a browser window: the sidebar on the left and web content on the right.
///
/// This is a placeholder shell until the web view pool exists (Milestone 1).
public struct BrowserWindow: View {
    /// Creates an empty browser window.
    public init() {}

    public var body: some View {
        NavigationSplitView {
            List {
                Section("Tabs") {}
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 400)
            .accessibilityIdentifier("sidebar")
        } detail: {
            ContentUnavailableView(
                "No Tab Open",
                systemImage: "safari",
                description: Text("Open a tab to start browsing.")
            )
            .accessibilityIdentifier("emptyState")
        }
    }
}

#Preview {
    BrowserWindow()
}
