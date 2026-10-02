//
//  BrowserWindow.swift
//  Axo
//
//  Created by Kevin Perez on 10/2/26.
//

import SwiftUI

/// The root view of a browser window: the sidebar on the left and web content on the right.
///
/// This is a placeholder shell until AxoUI and the web view pool exist (Milestone 1).
struct BrowserWindow: View {
    var body: some View {
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
