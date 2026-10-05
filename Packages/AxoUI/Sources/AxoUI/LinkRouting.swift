#if os(macOS)
import AppKit
#endif
import AxoCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension BrowserModel {
    /// Adds a rule sending links to a domain (and its subdomains) to a Space.
    ///
    /// - Returns: A plain message if the rule can't be added, or `nil` on success.
    @discardableResult
    public func addDomainRoute(_ text: String, spaceID: Space.ID) async -> String? {
        guard let domain = LinkRoute.normalizedDomain(from: text) else {
            return "“\(text.trimmingCharacters(in: .whitespaces))” isn't a domain, like example.com."
        }
        return await addRoute(.domain, value: domain, displayName: "", spaceID: spaceID, name: domain)
    }

    /// Adds a rule sending links from an app to a Space.
    ///
    /// - Parameter appURL: The app's bundle, such as `/Applications/Slack.app`.
    /// - Returns: A plain message if the rule can't be added, or `nil` on success.
    @discardableResult
    public func addAppRoute(_ appURL: URL, spaceID: Space.ID) async -> String? {
        guard let bundleID = Bundle(url: appURL)?.bundleIdentifier else {
            return "Axo couldn't read that app."
        }
        let name = FileManager.default.displayName(atPath: appURL.path).replacingOccurrences(of: ".app", with: "")
        return await addRoute(.app, value: bundleID, displayName: name, spaceID: spaceID, name: name)
    }

    private func addRoute(_ kind: LinkRoute.Kind, value: String, displayName: String, spaceID: Space.ID, name: String) async -> String? {
        do {
            try await store.linkRoutes.add(kind, value: value, displayName: displayName, spaceID: spaceID)
            linkRoutes = try await store.linkRoutes.routes()
            return nil
        } catch LinkRouteError.duplicate {
            return "There's already a rule for \(name)."
        } catch {
            return "Axo couldn't save the rule."
        }
    }

    /// Sends a rule's links to another Space.
    public func setRouteSpace(_ spaceID: Space.ID, for id: LinkRoute.ID) async {
        do {
            try await store.linkRoutes.setSpace(spaceID, for: id)
            linkRoutes = try await store.linkRoutes.routes()
        } catch {
            report(error, "Axo couldn't change the rule.")
        }
    }

    /// Deletes a rule.
    public func deleteRoute(_ id: LinkRoute.ID) async {
        do {
            try await store.linkRoutes.delete(id)
            linkRoutes = try await store.linkRoutes.routes()
        } catch {
            report(error, "Axo couldn't delete the rule.")
        }
    }
}
// Mac only for now; iPhone and iPad have their own chrome.
#if os(macOS)

/// Axo's Settings window (⌘,).
public struct SettingsView: View {
    let model: BrowserModel

    /// Creates the Settings window's content.
    public init(model: BrowserModel) {
        self.model = model
    }

    public var body: some View {
        TabView {
            LinkRoutingSettings(model: model)
                .tabItem { Label("Link Routing", systemImage: "arrow.triangle.branch") }
            SiteCustomizationSettings(model: model)
                .tabItem { Label("Site Customizations", systemImage: "paintbrush") }
            if let sync = model.iCloudSync {
                SyncSettings(sync: sync)
                    .tabItem { Label("iCloud", systemImage: "icloud") }
            }
        }
        .frame(width: 560, height: 420)
    }
}

/// Rules that open links from other apps in a chosen Space.
struct LinkRoutingSettings: View {
    let model: BrowserModel
    @State private var isAddingDomain = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Links from other apps open in a mini window. A rule opens them as tabs in a Space instead, by the link's domain or the app it came from. Domain rules come first.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.isDefaultBrowser == false {
                HStack {
                    Label("Axo isn't your default browser, so links from other apps open somewhere else.", systemImage: "exclamationmark.circle")
                    Spacer()
                    Button("Make Default…") { Task { await model.makeDefaultBrowser() } }
                }
                .font(.callout)
            }

            if model.linkRoutes.isEmpty {
                ContentUnavailableView("No Rules", systemImage: "arrow.triangle.branch", description: Text("Add a domain or an app to send its links to a Space."))
                    .frame(maxHeight: .infinity)
            } else {
                List(model.linkRoutes) { route in
                    LinkRouteRow(model: model, route: route)
                }
                .accessibilityIdentifier("linkRoutes")
            }

            HStack {
                Button("Add Domain…") { isAddingDomain = true }
                    .accessibilityIdentifier("addDomainRouteButton")
                Button("Add App…") { Task { await chooseApp() } }
                    .accessibilityIdentifier("addAppRouteButton")
                Spacer()
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(.red)
                    .accessibilityIdentifier("linkRouteMessage")
            }
        }
        .padding(20)
        .sheet(isPresented: $isAddingDomain) {
            AddDomainRouteSheet(model: model)
        }
    }

    /// Asks for an app in the Applications folder and adds a rule for it, sending its links to
    /// the current Space (changeable in the list).
    private func chooseApp() async {
        guard let spaceID = model.space?.id ?? model.spaces.first?.id else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        panel.message = "Choose an app whose links should open in a Space."
        guard await panel.begin() == .OK, let appURL = panel.url else { return }
        message = await model.addAppRoute(appURL, spaceID: spaceID)
    }
}

/// One rule: what it matches, the Space it opens links in, and Delete.
private struct LinkRouteRow: View {
    let model: BrowserModel
    let route: LinkRoute

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: route.kind == .app ? "app" : "globe")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(description)
                .lineLimit(1)
            Spacer()
            Picker("Open in", selection: Binding(
                get: { route.spaceID },
                set: { spaceID in Task { await model.setRouteSpace(spaceID, for: route.id) } }
            )) {
                ForEach(model.spaces) { Text($0.name).tag($0.id) }
            }
            .fixedSize()
            .accessibilityLabel("Open \(description.lowercased()) in")
            Button("Delete", systemImage: "trash") { Task { await model.deleteRoute(route.id) } }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Delete Rule")
                .accessibilityLabel("Delete rule for \(route.kind == .app ? route.displayName : route.value)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("linkRoute")
    }

    private var description: String {
        switch route.kind {
        case .app: "Links from \(route.displayName.isEmpty ? route.value : route.displayName)"
        case .domain: "Links to \(route.value)"
        }
    }
}

/// Asks for a domain and the Space its links open in.
private struct AddDomainRouteSheet: View {
    let model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var domain = ""
    @State private var spaceID: Space.ID?
    @State private var message: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        Form {
            Section {
                TextField("Domain", text: $domain, prompt: Text("example.com"))
                    .focused($isFocused)
                    .accessibilityIdentifier("routeDomainField")
                Picker("Open in", selection: $spaceID) {
                    ForEach(model.spaces) { Text($0.name).tag(Optional($0.id)) }
                }
                .accessibilityIdentifier("routeSpacePicker")
                if let message {
                    Text(message).foregroundStyle(.red)
                }
            } header: {
                // Sheets don't show their navigation title, so the sheet names itself.
                Text("Add Domain Rule").font(.headline).accessibilityAddTraits(.isHeader)
            } footer: {
                Text("Links to this domain and its subdomains open in the Space.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .defaultFocus($isFocused, true)
        .onAppear { spaceID = spaceID ?? model.space?.id }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    guard let spaceID else { return }
                    Task {
                        message = await model.addDomainRoute(domain, spaceID: spaceID)
                        if message == nil { dismiss() }
                    }
                }
                .disabled(domain.trimmingCharacters(in: .whitespaces).isEmpty || spaceID == nil)
                .accessibilityIdentifier("addRouteConfirmButton")
            }
        }
    }
}
#endif
