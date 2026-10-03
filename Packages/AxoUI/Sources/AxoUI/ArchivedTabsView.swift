import AxoCore
import SwiftUI

/// The Space's archived tabs: closed tabs and tabs that went unused, newest first.
struct ArchivedTabsView: View {
    let model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var tabs: [AxoCore.Tab] = []
    @State private var hasLoaded = false

    var body: some View {
        VStack(spacing: 0) {
            // Sheets don't show their navigation title, so the sheet names itself.
            Text("Archived Tabs in \(model.space?.name ?? "this Space")")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 16)
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
            if hasLoaded && tabs.isEmpty {
                ContentUnavailableView(
                    "No Archived Tabs",
                    systemImage: "archivebox",
                    description: Text("Tabs you close, and tabs you haven't looked at in a while, show up here.")
                )
            } else {
                List(tabs) { tab in
                    HStack {
                        TabRow(tab: tab, favicon: model.favicon(for: tab))
                        Spacer()
                        if let archivedAt = tab.archivedAt {
                            Text(archivedAt, format: .relative(presentation: .named))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button("Restore") {
                            Task {
                                await model.restoreTab(tab.id)
                                dismiss()
                            }
                        }
                        .accessibilityLabel("Restore \(TabRow.displayTitle(for: tab))")
                        .accessibilityIdentifier("restoreTabButton")
                    }
                }
            }
        }
        .frame(width: 460, height: 380)
        .navigationTitle("Archived Tabs in \(model.space?.name ?? "this Space")")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onExitCommand { dismiss() }
        .task {
            tabs = await model.archivedTabs()
            hasLoaded = true
        }
        .accessibilityIdentifier("archivedTabs")
    }
}
