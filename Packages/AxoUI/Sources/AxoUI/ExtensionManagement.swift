#if os(macOS)
import AppKit
#endif
import AxoCore
import AxoWeb
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
    /// Whether ``lines`` says what it can do; `false` when the engine doesn't report it, so an
    /// empty list doesn't claim it asks for nothing.
    public var listsAccess: Bool
    /// Why it couldn't load, if it couldn't.
    public var loadError: String?
    /// For an extension that runs user scripts (`chrome.userScripts`, as script managers do),
    /// whether the person allowed it to; `nil` for others.
    public var allowsUserScripts: Bool?
    /// Whether it's pinned to the toolbar.
    public var isPinned: Bool

    public init(id: String, name: String, version: String, isEnabled: Bool, isUnpacked: Bool, reachesAllRequestedSites: Bool, lines: [String], listsAccess: Bool = true, loadError: String?, allowsUserScripts: Bool? = nil, isPinned: Bool = false) {
        self.isPinned = isPinned
        self.listsAccess = listsAccess
        self.allowsUserScripts = allowsUserScripts
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

extension ExtensionSummary {
    /// Its state in a word or two, as the Extensions window's list says it: "Couldn't load",
    /// "Off", "On", or "On · Pinned", after "Unpacked · " for an unpacked one.
    public var stateDescription: String {
        if loadError != nil { return "Couldn’t load" }
        let state = isEnabled ? (isPinned ? "On · Pinned" : "On") : "Off"
        return isUnpacked ? "Unpacked · \(state)" : state
    }

    /// Whether it needs the person (it couldn't load), shown with a dot in the list.
    public var needsAttention: Bool { loadError != nil }
}

/// An extension the person asked to remove, waiting for them to confirm.
public struct ExtensionRemoval: Identifiable, Equatable, Sendable {
    public var id: String { extensionID }
    public var extensionID: String
    public var name: String
    public var profileID: Profile.ID
    /// The profile's name, which the confirmation names.
    public var profileName: String

    public init(extensionID: String, name: String, profileID: Profile.ID, profileName: String) {
        self.extensionID = extensionID
        self.name = name
        self.profileID = profileID
        self.profileName = profileName
    }

    /// "Remove “Name” from Profile?"
    public var title: String { "Remove “\(name)” from \(profileName)?" }
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
    /// Gives or takes away an extension's permission to run user scripts.
    func setAllowsUserScripts(_ allowed: Bool, extensionID: String, profileID: Profile.ID) async throws
    /// Opens the Web Inspector for an extension's background page, loading it first if needed.
    /// Returns whether it could.
    func inspectBackgroundPage(_ extensionID: String, profileID: Profile.ID) async -> Bool
}

extension ExtensionManaging {
    /// Does nothing, for extension systems without user scripts.
    public func setAllowsUserScripts(_ allowed: Bool, extensionID: String, profileID: Profile.ID) async throws {}
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

    /// The profile an install goes to: the Extensions window's while it's open, otherwise the
    /// shown Space's.
    var installProfileID: Profile.ID? {
        isShowingExtensions ? shownExtensionsProfileID : space?.profileID
    }

    /// Verifies an extension and shows the install prompt.
    public func prepareExtensionInstall(from url: URL) async {
        guard let management = extensionManagement, let profileID = installProfileID else { return }
        do {
            let prompt = try await management.prepareInstall(from: url, profileID: profileID)
            pendingExtensionInstallProfileID = profileID
            pendingExtensionInstall = prompt
        } catch {
            alertMessage = "Axo couldn't install this extension. \(error.localizedDescription)"
        }
    }

    /// Adds the extension in the install prompt.
    public func confirmExtensionInstall() async {
        guard let prompt = pendingExtensionInstall, let profileID = pendingExtensionInstallProfileID ?? space?.profileID else { return }
        pendingExtensionInstall = nil
        do {
            try await extensionManagement?.confirmInstall(prompt.id, profileID: profileID)
        } catch {
            alertMessage = "Axo couldn't turn on \(prompt.name). \(error.localizedDescription)"
        }
    }

    /// Declines the install prompt; the extension is removed.
    public func cancelExtensionInstall() async {
        guard let prompt = pendingExtensionInstall, let profileID = pendingExtensionInstallProfileID ?? space?.profileID else { return }
        pendingExtensionInstall = nil
        try? await extensionManagement?.uninstall(prompt.id, profileID: profileID)
    }

    /// Opens the Extensions window on a profile's extensions (the shown Space's by default),
    /// choosing one if given, and brings the browser window forward.
    public func showExtensions(profileID: Profile.ID? = nil, selecting extensionID: String? = nil) {
        extensionsProfileID = profileID
        extensionsSelection = extensionID
        isShowingExtensions = true
        showBrowserWindow?()
    }

    /// The profile the Extensions window shows.
    public var shownExtensionsProfileID: Profile.ID? {
        if let id = extensionsProfileID, allProfiles.contains(where: { $0.id == id }) { return id }
        return space?.profileID
    }

    /// Asks the person to confirm removing an extension from a profile.
    public func askToRemoveExtension(_ extensionID: String, name: String, profileID: Profile.ID) {
        let profileName = allProfiles.first(where: { $0.id == profileID })?.name ?? "this profile"
        pendingExtensionRemoval = ExtensionRemoval(extensionID: extensionID, name: name, profileID: profileID, profileName: profileName)
    }

    /// Removes an extension the person confirmed removing, from its profile only.
    public func removeExtension(_ removal: ExtensionRemoval) async {
        if pendingExtensionRemoval == removal { pendingExtensionRemoval = nil }
        guard let management = extensionManagement else { return }
        // The profile went (deleted, or through iCloud) while the person was asked.
        guard allProfiles.contains(where: { $0.id == removal.profileID }) else {
            alertMessage = "Axo couldn't remove \(removal.name). Its profile was deleted."
            return
        }
        do {
            try await management.uninstall(removal.extensionID, profileID: removal.profileID)
            announce("Removed \(removal.name) from \(removal.profileName)")
        } catch {
            alertMessage = "Axo couldn't remove \(removal.name). \(error.localizedDescription)"
        }
        extensionsRevision += 1
    }

    /// Pins an extension to the toolbar or unpins it, and says so.
    public func setExtensionPinned(_ pinned: Bool, extensionID: String, name: String, profileID: Profile.ID) {
        guard let toolbar = extensionToolbar else { return }
        toolbar.setPinned(pinned, extensionID: extensionID, profileID: profileID)
        announce(pinned ? "Pinned \(name) to the toolbar" : "Unpinned \(name) from the toolbar")
        extensionsRevision += 1
    }

    /// Moves a pinned extension's button to `index` among the pinned buttons, and says so.
    public func moveExtensionButton(_ extensionID: String, name: String, to index: Int, profileID: Profile.ID) {
        guard let toolbar = extensionToolbar else { return }
        toolbar.movePinned(extensionID: extensionID, to: index, profileID: profileID)
        announce("Moved \(name) to position \(index + 1)")
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

/// The Extensions window, as the Extensions board draws it (#131): one profile's extensions at a
/// time (the profile picker at the top, the shown Space's first), in a list you can search with
/// each one's state in a word, and the chosen one's details beside it.
struct ExtensionsView: View {
    let model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var extensions: [ExtensionSummary] = []
    @State private var selection: String?
    @State private var query = ""
    /// Shows each extension's ID and its Inspect buttons.
    @AppStorage("extensionsDeveloperMode") private var developerMode = false

    /// The Chrome Web Store, which the empty state and the top bar open.
    static let webStoreURL = URL(string: "https://chromewebstore.google.com/")!

    private var profileID: Profile.ID? { model.shownExtensionsProfileID }

    /// Whether the window shows the shown Space's profile, whose pages and toolbar are on screen.
    private var isShowingSpacesProfile: Bool { profileID != nil && profileID == model.space?.profileID }

    /// The profiles in the picker: the shown Space's first, then the rest in their order.
    static func pickerOrder(_ profiles: [Profile], first: Profile.ID?) -> [Profile] {
        profiles.filter { $0.id == first } + profiles.filter { $0.id != first }
    }

    /// What makes the list read again.
    private struct RefreshKey: Equatable {
        var profileID: Profile.ID?
        var install: ExtensionInstallPrompt?
        var revision: Int
    }

    /// The extensions matching the search, by name.
    static func filtered(_ extensions: [ExtensionSummary], query: String) -> [ExtensionSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let sorted = extensions.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !trimmed.isEmpty else { return sorted }
        return sorted.filter { $0.name.localizedStandardContains(trimmed) }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if extensions.isEmpty {
                ContentUnavailableView {
                    Label("No Extensions", systemImage: "puzzlepiece.extension")
                } description: {
                    Text("Add Chrome extensions from the Chrome Web Store, or from a .crx file or an unpacked folder.")
                } actions: {
                    Button("Install from File…") { model.chooseExtensionToInstall() }
                    if isShowingSpacesProfile {
                        Button("Chrome Web Store") { openWebStore() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    sidebar.frame(width: 260)
                    Divider()
                    if let item = extensions.first(where: { $0.id == selection }), let profileID {
                        ExtensionDetails(item: item, model: model, profileID: profileID, developerMode: developerMode, refresh: refresh)
                            .id(item.id)
                    } else {
                        Text("Choose an extension.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .frame(width: 820, height: 560)
        .navigationTitle("Extensions")
        .onExitCommandIfAvailable { dismiss() }
        .task(id: RefreshKey(profileID: profileID, install: model.pendingExtensionInstall, revision: model.extensionsRevision)) {
            await refresh()
        }
        .onDisappear {
            model.extensionsProfileID = nil
            model.extensionsSelection = nil
        }
        .alert(model.pendingExtensionRemoval?.title ?? "", item: Binding(get: { model.pendingExtensionRemoval }, set: { model.pendingExtensionRemoval = $0 })) { removal in
            // Cancel is the default, so Return never deletes an extension's data.
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
            Button("Remove", role: .destructive) { Task { await model.removeExtension(removal) } }
        } message: { _ in
            Text("Its data in this profile is deleted. Other profiles keep their own extensions.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("extensionsWindow")
    }

    /// The title, the profile picker, installing, and Done.
    private var topBar: some View {
        HStack(spacing: 10) {
            // Sheets don't show their navigation title, so the window names itself.
            Text("Extensions")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if model.allProfiles.count > 1 {
                Picker("Profile", selection: Binding(
                    get: { profileID },
                    set: { model.extensionsProfileID = $0; selection = nil }
                )) {
                    ForEach(Self.pickerOrder(model.allProfiles, first: model.space?.profileID)) { profile in
                        Text(profile.name).tag(Profile.ID?.some(profile.id))
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityIdentifier("extensionsProfilePicker")
            }
            Button("Install from File…") { model.chooseExtensionToInstall() }
            // The store installs into the shown Space's profile, so it's offered only for that one.
            if isShowingSpacesProfile {
                Button("Chrome Web Store") { openWebStore() }
            }
            // No Return shortcut: Return in the search field would close the window. Esc closes it.
            Button("Done") { dismiss() }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    /// The search field, the list, and the Developer Mode switch.
    private var sidebar: some View {
        let shown = Self.filtered(extensions, query: query)
        return VStack(spacing: 0) {
            TextField("Search", text: $query, prompt: Text("Search"))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search extensions")
                .padding(10)
            if shown.isEmpty {
                Text("No Matches")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(shown) { item in
                        ExtensionListRow(item: item, icon: icon(for: item.id))
                            .tag(item.id)
                    }
                }
                .listStyle(.sidebar)
                .accessibilityIdentifier("extensionsList")
            }
            Divider()
            Toggle("Developer Mode", isOn: $developerMode)
                .toggleStyle(.switch)
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .accessibilityIdentifier("extensionsDeveloperMode")
        }
    }

    /// An extension's toolbar icon, read for the shown tab, so only for the shown Space's
    /// profile: another profile's buttons would be read for a page that isn't its own.
    private func icon(for extensionID: String) -> PlatformImage? {
        guard isShowingSpacesProfile, let profileID else { return nil }
        return model.extensionToolbar?.toolbarItems(profileID: profileID, tabID: model.selectedTabID).first { $0.id == extensionID }?.icon
    }

    private func openWebStore() {
        dismiss()
        Task { await model.openTab(url: Self.webStoreURL) }
    }

    private func refresh() async {
        guard let profileID else { return }
        let list = await model.extensionManagement?.installedExtensions(profileID: profileID) ?? []
        // A newer read may have finished first (another profile chosen meanwhile).
        guard profileID == self.profileID else { return }
        extensions = list
        if let asked = model.extensionsSelection, list.contains(where: { $0.id == asked }) {
            selection = asked
            model.extensionsSelection = nil
        } else if selection == nil || !list.contains(where: { $0.id == selection }) {
            selection = Self.filtered(list, query: "").first?.id
        }
    }
}

/// An extension in the Extensions window's list: its icon, name, state in a word, and a dot when
/// it needs the person.
private struct ExtensionListRow: View {
    let item: ExtensionSummary
    let icon: PlatformImage?

    var body: some View {
        HStack(spacing: 8) {
            ExtensionSymbol(icon: icon, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1)
                Text(item.stateDescription)
                    .font(.caption)
                    .foregroundStyle(item.needsAttention ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if item.needsAttention {
                Circle().fill(.red).frame(width: 7, height: 7)
                    .accessibilityLabel("Needs attention")
            }
        }
        .padding(.vertical, 2)
        // The list's own row reads its texts (name, state, and the dot); an element made here
        // had no role the audit knew.
    }
}

/// An extension's icon, or a puzzle piece when it has none Axo can show.
private struct ExtensionSymbol: View {
    let icon: PlatformImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let icon {
                Image(platformImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: "puzzlepiece.extension").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The chosen extension's details: its on switch, Pin to Toolbar and keyboard shortcuts, site
/// access, user scripts, developer tools, About, and Remove….
private struct ExtensionDetails: View {
    let item: ExtensionSummary
    let model: BrowserModel
    let profileID: Profile.ID
    let developerMode: Bool
    let refresh: () async -> Void
    @Environment(\.dismiss) private var dismiss

    /// Its toolbar button for the shown tab, only for the shown Space's profile: another
    /// profile's extension must never run (Inspect Popup) on a page of this one.
    private var toolbarItem: ExtensionToolbarItem? {
        guard profileID == model.space?.profileID else { return nil }
        return model.extensionToolbar?.toolbarItems(profileID: profileID, tabID: model.selectedTabID).first { $0.id == item.id }
    }

    private var shortcuts: [ExtensionShortcut] {
        model.extensionToolbar?.shortcuts(profileID: profileID).filter { $0.extensionID == item.id } ?? []
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    ExtensionSymbol(icon: toolbarItem?.icon, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                        Text(item.isUnpacked ? "Unpacked (developer mode)" : "Installed package")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    // The switch says whether it's on; its (hidden) label says what it turns on.
                    Toggle(item.name, isOn: Binding(
                        get: { item.isEnabled },
                        set: { on in change { try await $0.setEnabled(on, extensionID: item.id, profileID: $1) } }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityIdentifier("extensionOnSwitch")
                }
                if let error = item.loadError {
                    Label("Couldn’t load: \(error)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            Section("In the Toolbar") {
                Toggle(isOn: Binding(
                    get: { item.isPinned },
                    set: { model.setExtensionPinned($0, extensionID: item.id, name: item.name, profileID: profileID) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pin to Toolbar")
                        Text(item.isPinned
                             ? "Its button shows beside the address. Every extension is also in the Extensions menu."
                             : "It’s in the Extensions menu. Pin it to give it a button beside the address.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Pin \(item.name) to the Toolbar")
                .accessibilityIdentifier("pinExtension")
                if shortcuts.isEmpty {
                    LabeledContent("Keyboard Shortcuts", value: "None")
                } else {
                    ForEach(shortcuts) { shortcut in
                        ShortcutRow(shortcut: shortcut)
                    }
                }
            }
            Section("Site Access") {
                Picker("Site access for \(item.name)", selection: Binding(
                    get: { item.reachesAllRequestedSites },
                    set: { all in change { try await $0.setReachesAllRequestedSites(all, extensionID: item.id, profileID: $1) } }
                )) {
                    Text("All requested sites").tag(true)
                    Text("When you click it").tag(false)
                }
                if !item.listsAccess {
                    // The engine doesn't say yet; never claim it asks for nothing.
                } else if item.lines.isEmpty {
                    Text("It doesn't ask for any special access.").foregroundStyle(.secondary)
                } else {
                    ForEach(item.lines, id: \.self) { line in
                        Label(line, systemImage: "checkmark.circle")
                    }
                }
            }
            if let allowed = item.allowsUserScripts {
                Section("User Scripts") {
                    Toggle(isOn: Binding(
                        get: { allowed },
                        set: { on in change { try await $0.setAllowsUserScripts(on, extensionID: item.id, profileID: $1) } }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Allow User Scripts")
                            Text("Lets it run scripts you add to it on the sites they're for.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityLabel("Allow User Scripts for \(item.name)")
                    .accessibilityIdentifier("allowUserScripts")
                }
            }
            if developerMode {
                Section("Developer") {
                    LabeledContent("ID") {
                        Text(item.id).textSelection(.enabled).font(.callout.monospaced())
                    }
                    Button("Inspect Background Page") { inspectBackground() }
                        .disabled(!item.isEnabled)
                        .accessibilityLabel("Inspect \(item.name) Background Page")
                    // Also in its toolbar button's menu. The Extensions window closes so the popup
                    // can show under its button.
                    if let toolbar = model.extensionToolbar, toolbar.canInspectPopups, toolbarItem != nil {
                        Button("Inspect Popup") {
                            dismiss()
                            toolbar.inspectPopup(extensionID: item.id, profileID: profileID, tabID: model.selectedTabID)
                        }
                        .disabled(!item.isEnabled)
                        .accessibilityLabel("Inspect \(item.name) Popup")
                    }
                }
            }
            Section("About") {
                LabeledContent("Version", value: item.version)
                LabeledContent("Source", value: item.isUnpacked ? "Unpacked folder" : "Package")
            }
            Section {
                Button("Remove…", role: .destructive) {
                    model.askToRemoveExtension(item.id, name: item.name, profileID: profileID)
                }
                .accessibilityLabel("Remove \(item.name)")
                .accessibilityIdentifier("removeExtension")
            }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("extensionDetails")
    }

    private func inspectBackground() {
        guard let management = model.extensionManagement else { return }
        Task {
            if !(await management.inspectBackgroundPage(item.id, profileID: profileID)) {
                model.alertMessage = "\(item.name) has no background page to inspect, or it isn't running."
            }
        }
    }

    private func change(_ action: @escaping @MainActor (any ExtensionManaging, Profile.ID) async throws -> Void) {
        guard let management = model.extensionManagement else { return }
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

/// One of an extension's keyboard shortcuts, struck through when one of Axo's own menu items
/// uses its keys (it then runs from Tabs › Extension Shortcuts without them).
private struct ShortcutRow: View {
    let shortcut: ExtensionShortcut

    var body: some View {
        let clashes = shortcut.clashes(with: NSApp.mainMenu)
        LabeledContent {
            Text(shortcut.keysDescription)
                .strikethrough(clashes)
                .font(.callout.monospaced())
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(shortcut.title)
                if clashes {
                    Text("Axo uses these keys, so it runs from Tabs › Extension Shortcuts without them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shortcut.title)
        .accessibilityValue(clashes ? "\(shortcut.keysDescription), used by Axo" : shortcut.keysDescription)
    }
}
#endif
