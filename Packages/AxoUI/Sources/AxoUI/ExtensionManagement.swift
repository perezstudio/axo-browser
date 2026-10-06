#if os(macOS)
import AppKit
#endif
import AxoCore
import SwiftUI

/// What an extension will be able to do, shown before it's added.
public struct ExtensionInstallPrompt: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var version: String
    /// What it can do, in plain language.
    public var lines: [String]
    public var isUnpacked: Bool

    public init(id: String, name: String, version: String, lines: [String], isUnpacked: Bool) {
        self.id = id
        self.name = name
        self.version = version
        self.lines = lines
        self.isUnpacked = isUnpacked
    }
}

/// An installed extension, for the Extensions window.
public struct ExtensionSummary: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var version: String
    public var isEnabled: Bool
    public var isUnpacked: Bool
    /// Whether it can reach every site it asked for, or only where it's clicked.
    public var reachesAllRequestedSites: Bool
    /// What it can do now, in plain language.
    public var lines: [String]
    /// Why it isn't working, in plain words (it couldn't load, or its background couldn't
    /// start), or `nil` when it's fine.
    public var loadError: String?

    public init(id: String, name: String, version: String, isEnabled: Bool, isUnpacked: Bool, reachesAllRequestedSites: Bool, lines: [String], loadError: String?) {
        self.id = id
        self.name = name
        self.version = version
        self.isEnabled = isEnabled
        self.isUnpacked = isUnpacked
        self.reachesAllRequestedSites = reachesAllRequestedSites
        self.lines = lines
        self.loadError = loadError
    }
}

/// An extension asking for more access after install.
public struct ExtensionPermissionPrompt: Hashable, Sendable {
    public var extensionName: String
    /// What it wants, in plain language.
    public var lines: [String]

    public init(extensionName: String, lines: [String]) {
        self.extensionName = extensionName
        self.lines = lines
    }
}

/// Installs and manages extensions. AxoExtensions provides the real implementation; the app
/// connects them.
@MainActor
public protocol ExtensionManaging: AnyObject {
    /// Verifies and saves an extension (a `.crx` file or an unpacked folder) turned off, and
    /// describes it for the install prompt.
    func prepareInstall(from url: URL, profileID: Profile.ID) async throws -> ExtensionInstallPrompt
    /// Downloads an extension from the Chrome Web Store, verifies and saves it turned off, and
    /// describes it for the install prompt.
    func prepareWebStoreInstall(_ extensionID: String, profileID: Profile.ID) async throws -> ExtensionInstallPrompt
    /// Turns on an extension the person agreed to add.
    func confirmInstall(_ extensionID: String, profileID: Profile.ID) async throws
    /// Removes an extension.
    func uninstall(_ extensionID: String, profileID: Profile.ID) async throws
    /// A profile's installed extensions.
    func installedExtensions(profileID: Profile.ID) async -> [ExtensionSummary]
    /// Turns an extension on or off.
    func setEnabled(_ enabled: Bool, extensionID: String, profileID: Profile.ID) async throws
    /// Lets an extension reach every site it asked for, or only where it's clicked.
    func setReachesAllRequestedSites(_ all: Bool, extensionID: String, profileID: Profile.ID) async throws
    /// Opens the Web Inspector for an extension's background page, loading it first if needed.
    /// Returns whether it could.
    func inspectBackgroundPage(_ extensionID: String, profileID: Profile.ID) async -> Bool
}

extension BrowserModel {
    #if os(macOS)
    /// Chooses a `.crx` file or an unpacked extension folder and starts installing it.
    public func chooseExtensionToInstall() {
        let panel = NSOpenPanel()
        panel.message = "Choose a Chrome extension (.crx) or an unpacked extension folder."
        panel.prompt = "Install"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.init(filenameExtension: "crx") ?? .data, .folder]
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { await self?.prepareExtensionInstall(from: url) }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            panel.begin(completionHandler: handle)
        }
    }
    #endif

    /// Verifies an extension and shows the install prompt.
    public func prepareExtensionInstall(from url: URL) async {
        guard let management = extensionManagement, let profileID = space?.profileID else { return }
        do {
            pendingExtensionInstall = try await management.prepareInstall(from: url, profileID: profileID)
        } catch {
            alertMessage = "Axo couldn't install this extension. \(error.localizedDescription)"
        }
    }

    /// Starts installing an extension from its Chrome Web Store page ("Add to Axo"): downloads
    /// it, then shows the usual install prompt. The current Space's profile gets it.
    public func installFromWebStore(_ extensionID: String) async {
        guard let management = extensionManagement, let profileID = space?.profileID else { return }
        do {
            pendingExtensionInstall = try await management.prepareWebStoreInstall(extensionID, profileID: profileID)
        } catch {
            alertMessage = "Axo couldn't add this extension from the Chrome Web Store. \(error.localizedDescription)"
        }
    }

    /// Adds the extension in the install prompt.
    public func confirmExtensionInstall() async {
        guard let prompt = pendingExtensionInstall, let profileID = space?.profileID else { return }
        pendingExtensionInstall = nil
        do {
            try await extensionManagement?.confirmInstall(prompt.id, profileID: profileID)
        } catch {
            alertMessage = "Axo couldn't turn on \(prompt.name). \(error.localizedDescription)"
        }
    }

    /// Declines the install prompt; the extension is removed.
    public func cancelExtensionInstall() async {
        guard let prompt = pendingExtensionInstall, let profileID = space?.profileID else { return }
        pendingExtensionInstall = nil
        try? await extensionManagement?.uninstall(prompt.id, profileID: profileID)
    }

    /// Asks the person whether an extension may have more access.
    public func askExtensionPermission(_ prompt: ExtensionPermissionPrompt) async -> Bool {
        await prompts.ask(prompt)
    }
}
// Mac only for now; iPhone and iPad have their own chrome.
#if os(macOS)

/// "Add “Name”?" with what the extension can do.
struct ExtensionInstallSheet: View {
    let model: BrowserModel
    let prompt: ExtensionInstallPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add “\(prompt.name)”?").font(.headline).accessibilityAddTraits(.isHeader)
                    Text(prompt.isUnpacked ? "Version \(prompt.version), unpacked (developer mode)" : "Version \(prompt.version)")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "puzzlepiece.extension").font(.title)
            }
            if prompt.lines.isEmpty {
                Text("It doesn't ask for any special access.").foregroundStyle(.secondary)
            } else {
                Text("It can:").font(.subheadline.weight(.semibold))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(prompt.lines, id: \.self) { line in
                        Label(line, systemImage: "checkmark.circle").labelStyle(.titleAndIcon)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { Task { await model.cancelExtensionInstall() } }
                    .keyboardShortcut(.cancelAction)
                Button("Add Extension") { Task { await model.confirmExtensionInstall() } }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("confirmExtensionInstall")
            }
        }
        .padding(20)
        .frame(width: 420)
        // .contain keeps the children's own identifiers (such as the Add button's).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("extensionInstallPrompt")
    }
}

/// The Extensions window: each installed extension in this Space's profile, with controls.
struct ExtensionsView: View {
    let model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var extensions: [ExtensionSummary] = []

    var body: some View {
        VStack(spacing: 0) {
            // Sheets don't show their navigation title, so the window names itself.
            Text("Extensions")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 16)
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
            if extensions.isEmpty {
                ContentUnavailableView {
                    Label("No Extensions", systemImage: "puzzlepiece.extension")
                } description: {
                    Text("Install Chrome extensions from a .crx file or an unpacked folder.")
                } actions: {
                    Button("Install Extension…") { model.chooseExtensionToInstall() }
                }
            } else {
                List(extensions) { item in
                    ExtensionRow(item: item, model: model, refresh: refresh)
                }
            }
        }
        .frame(width: 520, height: 420)
        .navigationTitle("Extensions")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Install Extension…") { model.chooseExtensionToInstall() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onExitCommandIfAvailable { dismiss() }
        .task(id: model.pendingExtensionInstall) { await refresh() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("extensionsWindow")
    }

    private func refresh() async {
        guard let profileID = model.space?.profileID else { return }
        extensions = await model.extensionManagement?.installedExtensions(profileID: profileID) ?? []
    }
}

private struct ExtensionRow: View {
    let item: ExtensionSummary
    let model: BrowserModel
    let refresh: () async -> Void
    @State private var isConfirmingRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.headline)
                    Text(item.isUnpacked ? "\(item.version) · Unpacked" : item.version)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("On", isOn: Binding(
                    get: { item.isEnabled },
                    set: { on in change { try await $0.setEnabled(on, extensionID: item.id, profileID: $1) } }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                // The switch says whether it's on; the label says what it turns on.
                .accessibilityLabel(item.name)
            }
            if let problem = item.loadError {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("extensionProblem")
            }
            Picker("Site access", selection: Binding(
                get: { item.reachesAllRequestedSites },
                set: { all in change { try await $0.setReachesAllRequestedSites(all, extensionID: item.id, profileID: $1) } }
            )) {
                Text("On all requested sites").tag(true)
                Text("Only when you click it").tag(false)
            }
            .pickerStyle(.menu)
            .fixedSize()
            if !item.lines.isEmpty {
                Text(item.lines.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Inspect Background Page") {
                    guard let management = model.extensionManagement, let profileID = model.space?.profileID else { return }
                    Task {
                        if !(await management.inspectBackgroundPage(item.id, profileID: profileID)) {
                            model.alertMessage = "\(item.name) has no background page to inspect, or it isn't running."
                        }
                    }
                }
                .disabled(!item.isEnabled)
                .accessibilityLabel("Inspect \(item.name) Background Page")
                Spacer()
                Button("Remove…", role: .destructive) { isConfirmingRemoval = true }
                    .accessibilityLabel("Remove \(item.name)")
                    .confirmationDialog("Remove “\(item.name)”?", isPresented: $isConfirmingRemoval) {
                        Button("Remove", role: .destructive) {
                            change { try await $0.uninstall(item.id, profileID: $1) }
                        }
                    } message: {
                        Text("It stops running in this profile.")
                    }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("extensionRow")
    }

    private func change(_ action: @escaping @MainActor (any ExtensionManaging, Profile.ID) async throws -> Void) {
        guard let management = model.extensionManagement, let profileID = model.space?.profileID else { return }
        Task {
            do {
                try await action(management, profileID)
            } catch {
                model.alertMessage = "Axo couldn't change \(item.name). \(error.localizedDescription)"
            }
            await refresh()
        }
    }
}
#endif
