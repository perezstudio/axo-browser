import AxoCore
import AxoWeb
import SwiftUI

/// Asks macOS for location access the first time the person allows a site to use their
/// location. AxoIntegration's `LocationAuthorization` provides the real implementation.
@MainActor
public protocol LocationAuthorizing: AnyObject {
    /// Asks macOS for location access if it hasn't asked before.
    func requestIfNeeded()
}

/// Keeps the pool's permission answers in the database, so they survive restarts.
///
/// A request for the camera and microphone together is saved as an answer for each, and it
/// only counts as answered when both are.
@MainActor
final class SitePermissionAdapter: PermissionDecisionStore {
    private let store: SitePermissionStore

    init(store: SitePermissionStore) {
        self.store = store
    }

    /// The saved kinds a request covers.
    static func kinds(for kind: PermissionKind) -> Set<SitePermission.Kind> {
        switch kind {
        case .camera: [.camera]
        case .microphone: [.microphone]
        case .cameraAndMicrophone: [.camera, .microphone]
        case .location: [.location]
        case .notifications: [.notifications]
        case .clipboard: [.clipboard]
        }
    }

    /// What a page uses for a saved kind, for stopping it when the answer becomes deny.
    static func capture(for kind: SitePermission.Kind) -> PageCapture {
        switch kind {
        case .camera: .camera
        case .microphone: .microphone
        case .location: .location
        case .notifications, .clipboard: []
        }
    }

    /// The request kind that keeps a saved kind's answer in the engine, if the engine keeps one.
    static func lastingKind(for kind: SitePermission.Kind) -> PermissionKind? {
        switch kind {
        case .notifications: .notifications
        case .clipboard: .clipboard
        case .camera, .microphone, .location: nil
        }
    }

    /// The site's own answer, or the profile's default for sites without one (#133), for each
    /// kind the request covers; `nil` asks.
    func savedDecision(for kind: PermissionKind, origin: PageOrigin, profileID: Profile.ID) async -> PermissionDecision? {
        let saved = (try? await store.decisions(origin: origin.serialized, profileID: profileID)) ?? [:]
        let defaults = (try? await store.defaults(profileID: profileID)) ?? [:]
        let answers = Self.kinds(for: kind).map { saved[$0] ?? defaults[$0] }
        if answers.contains(.deny) { return .deny }
        if answers.allSatisfy({ $0 == .allow }) { return .allow }
        return nil
    }

    func saveDecision(_ decision: PermissionDecision, for kind: PermissionKind, origin: PageOrigin, profileID: Profile.ID) async {
        try? await store.setDecision(decision == .allow ? .allow : .deny, for: Self.kinds(for: kind), origin: origin.serialized, profileID: profileID)
    }
}

extension BrowserModel {
    /// The selected page's site, if it's an http or https page.
    public var siteSettingsOrigin: PageOrigin? {
        (selectedPage?.url ?? shownTab?.url).flatMap(PageOrigin.init(url:))
    }

    /// Opens Site Settings for the selected page's site.
    public func showSiteSettings() async {
        guard siteSettingsOrigin != nil else { return }
        await refreshSiteSettings()
        isShowingSiteSettings = true
    }

    /// Reloads the saved answers for the selected page's site.
    public func refreshSiteSettings() async {
        guard let origin = siteSettingsOrigin, let profileID = space?.profileID else {
            sitePermissions = [:]
            siteDefaults = [:]
            siteExternalApps = []
            siteExternalAppTitles = [:]
            siteExtensionAccess = [:]
            siteExtensionAccessKey = nil
            return
        }
        // The site's root, so an extension limited to some paths isn't listed for some pages of
        // the site and not others.
        if let root = URL(string: origin.serialized + "/") {
            siteExtensionAccess = extensionToolbar?.siteAccess(to: root, profileID: profileID) ?? [:]
            siteExtensionAccessKey = SiteAccessKey(profileID: profileID, origin: origin)
        }
        sitePermissions = (try? await store.sitePermissions.decisions(origin: origin.serialized, profileID: profileID)) ?? [:]
        siteDefaults = (try? await store.sitePermissions.defaults(profileID: profileID)) ?? [:]
        siteExternalApps = (try? await store.externalAppPermissions.schemes(origin: origin.serialized, profileID: profileID)) ?? []
        siteExternalAppTitles = Dictionary(uniqueKeysWithValues: siteExternalApps.map { ($0, externalAppTitle(for: $0)) })
    }

    /// Makes Site Settings' site ask again before opening `scheme` links in another app.
    public func forgetSiteExternalApp(_ scheme: String) async {
        guard let origin = siteSettingsOrigin, let profileID = space?.profileID else { return }
        try? await store.externalAppPermissions.forget(scheme: scheme, origin: origin.serialized, profileID: profileID)
        await refreshSiteSettings()
    }

    /// How Site Settings names the app that opens `scheme` links: the app and the scheme, or just
    /// the scheme when no app opens it now. It asks the system, so the view reads
    /// ``siteExternalAppTitles`` instead.
    func externalAppTitle(for scheme: String) -> String {
        let app = URL(string: "\(scheme):").flatMap { externalApps.appName(for: $0) }
        return app.map { "\($0) (\(scheme):)" } ?? "\(scheme):"
    }

    /// Saves an answer for the selected page's site, or forgets it (`nil`) so the site asks again.
    public func setSitePermission(_ decision: SitePermission.Decision?, for kind: SitePermission.Kind) async {
        guard let origin = siteSettingsOrigin, let profileID = space?.profileID else { return }
        await applyWebsitePermission(decision, for: kind, origin: origin, profileID: profileID)
        await refreshSiteSettings()
    }

    /// Forgets every answer for the selected page's site, and the apps it may open without asking.
    public func resetSiteSettings() async {
        guard let origin = siteSettingsOrigin, let profileID = space?.profileID else { return }
        try? await store.sitePermissions.reset(origin: origin.serialized, profileID: profileID)
        try? await store.externalAppPermissions.reset(origin: origin.serialized, profileID: profileID)
        for kind in PermissionKind.allCases where kind.lastsInEngine {
            pool.setLastingPermission(kind, origin: origin, decision: nil, profileID: profileID)
        }
        await refreshSiteSettings()
    }

    /// The extensions Site Settings lists for its site (#110): the shown Space's profile's
    /// turned-on extensions that can, or ask to, read and change it, as the toolbar names and
    /// pins them, those that can first, then by name. Empty once the page or Space has moved on
    /// from the site and profile the access was read for.
    public var siteExtensions: [(item: ExtensionToolbarItem, access: SiteExtensionAccess)] {
        guard !siteExtensionAccess.isEmpty, let profileID = space?.profileID, let toolbar = extensionToolbar,
              let origin = siteSettingsOrigin, siteExtensionAccessKey == SiteAccessKey(profileID: profileID, origin: origin)
        else { return [] }
        return toolbar.toolbarItems(profileID: profileID, tabID: selectedTabID)
            .compactMap { item in siteExtensionAccess[item.id].map { (item, $0) } }
            .sorted { lhs, rhs in
                if lhs.access != rhs.access { return lhs.access == .granted }
                return lhs.item.label.localizedStandardCompare(rhs.item.label) == .orderedAscending
            }
    }

    /// The name of the profile Site Settings' choices apply to: the shown Space's.
    public var siteSettingsProfileName: String? {
        guard let profileID = space?.profileID else { return nil }
        return allProfiles.first { $0.id == profileID }?.name
    }

    /// Asks before clearing the selected page's site's website data: closes Site Settings, and
    /// the window's alert asks (``siteDataClear``).
    public func confirmClearSiteData() {
        guard let origin = siteSettingsOrigin, let profileID = space?.profileID else { return }
        isShowingSiteSettings = false
        siteDataClear = SiteDataClear(origin: origin, profileID: profileID, profileName: siteSettingsProfileName)
    }

    /// Removes a site's cookies, caches, and other website data in the profile the person was
    /// asked about, then says so. Its permission answers, history, and customizations stay. A
    /// profile deleted while the question showed is left alone: making its data store again would
    /// bring its storage back.
    public func clearSiteData(_ request: SiteDataClear) async {
        guard allProfiles.contains(where: { $0.id == request.profileID }),
              let url = URL(string: request.origin.serialized) else { return }
        await pool.clearWebsiteData(forSite: url, profileID: request.profileID)
        postNotice("Cleared website data for \(request.origin.displayName)")
    }

    /// Replaces the answers the engine keeps itself (notifications and the clipboard) with Axo's
    /// saved ones, in every profile or just `profileID`, forgetting any the engine has that Axo
    /// doesn't: at launch, and after clearing a profile's website data, which clears the engine's.
    func syncLastingPermissions(profileID only: Profile.ID? = nil) async {
        guard let saved = try? await store.sitePermissions.all([.notifications, .clipboard]) else { return }
        let profileIDs = if let only { [only] } else { await profiles().map(\.id) }
        // The profiles' defaults for those kinds too (#133); clearing website data resets Chrome's.
        let defaults = (try? await store.sitePermissions.allDefaults([.notifications, .clipboard])) ?? []
        for profileID in profileIDs {
            for kind in [SitePermission.Kind.notifications, .clipboard] {
                guard let lasting = SitePermissionAdapter.lastingKind(for: kind) else { continue }
                let decision = defaults.first { $0.profileID == profileID && $0.kind == kind }?.decision
                pool.setDefaultPermission(lasting, decision: decision.map { $0 == .allow ? .allow : .deny }, profileID: profileID)
            }
        }
        for profileID in profileIDs {
            let answers = saved.filter { $0.profileID == profileID }.compactMap { permission -> LastingPermission? in
                guard let kind = SitePermissionAdapter.lastingKind(for: permission.kind),
                      let url = URL(string: permission.origin), let origin = PageOrigin(url: url) else { return nil }
                return LastingPermission(kind: kind, origin: origin, decision: permission.decision == .allow ? .allow : .deny)
            }
            pool.replaceLastingPermissions(answers, profileID: profileID)
        }
    }

    /// What Site Settings offers for the selected page's site: the kinds the engine asks Axo
    /// about, and notifications and the clipboard only on a secure site (https, or this Mac),
    /// where pages can ask for them.
    public var siteSettingsKinds: [SitePermission.Kind] {
        guard let origin = siteSettingsOrigin else { return [] }
        let asked = pool.askedPermissionKinds
        let secure = origin.isPotentiallyTrustworthy
        return SitePermission.Kind.allCases.filter { kind in
            guard let lasting = SitePermissionAdapter.lastingKind(for: kind) else { return true }
            return secure && asked.contains(lasting)
        }
    }
}

/// The profile and site extensions' access was read for (``BrowserModel/siteExtensionAccess``).
struct SiteAccessKey: Hashable {
    var profileID: Profile.ID
    var origin: PageOrigin
}

/// Clearing one site's website data, which the window asks about first (#110).
public struct SiteDataClear: Identifiable, Hashable, Sendable {
    /// The site whose data goes: its registrable domain and subdomains, which the engine works out.
    public var origin: PageOrigin
    /// The profile whose data for the site goes; other profiles keep theirs.
    public var profileID: Profile.ID
    /// The profile's name, for the question.
    public var profileName: String?

    public var id: Self { self }

    /// Creates a request.
    public init(origin: PageOrigin, profileID: Profile.ID, profileName: String?) {
        self.origin = origin
        self.profileID = profileID
        self.profileName = profileName
    }

    /// The question.
    public var title: String {
        "Clear website data for “\(origin.displayName)”?"
    }

    /// What clearing does, plainly.
    public var message: String {
        let profile = profileName.map { " in the “\($0)” profile" } ?? ""
        return "Cookies, caches, and other data stored by this site and the rest of its domain\(profile) are removed, "
            + "and you may be signed out. Its permissions and your history stay."
    }
}

/// Asks before clearing a site's website data, from Site Settings' Clear Website Data…. Cancel is
/// the default button, so Return never clears.
struct SiteDataClearAlert: ViewModifier {
    let model: BrowserModel

    func body(content: Content) -> some View {
        content
            .alert(model.siteDataClear?.title ?? "", item: Binding(get: { model.siteDataClear }, set: { model.siteDataClear = $0 })) { request in
                Button("Cancel", role: .cancel) {}
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("cancelClearSiteData")
                Button("Clear", role: .destructive) { Task { await model.clearSiteData(request) } }
                    .accessibilityIdentifier("confirmClearSiteData")
            } message: { request in
                Text(request.message)
            }
    }
}

/// The button beside the address field that opens Site Settings.
struct SiteSettingsButton: View {
    let model: BrowserModel

    var body: some View {
        Button {
            Task { await model.showSiteSettings() }
        } label: {
            Label("Site Settings", systemImage: "slider.horizontal.3")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help("Site Settings")
        .disabled(model.siteSettingsOrigin == nil)
        .accessibilityIdentifier("siteSettingsButton")
        .popover(isPresented: Binding(get: { model.isShowingSiteSettings }, set: { model.isShowingSiteSettings = $0 }), arrowEdge: .bottom) {
            SiteSettingsView(model: model)
        }
    }
}

/// One panel for the selected page's site (#110), as the Prompts board draws it: the site and its
/// connection, what it can use (camera, microphone, location, notifications, and the clipboard,
/// each Ask, Allow, or Don't Allow, and the apps it may open without asking), its customization,
/// and its website data, in the shown Space's profile.
struct SiteSettingsView: View {
    let model: BrowserModel
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsView.paneStorageKey) private var settingsPane: SettingsPane = .general
    #endif

    private var siteName: String { model.siteSettingsOrigin?.displayName ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            permissions
            let extensions = model.siteExtensions
            if !extensions.isEmpty {
                Divider()
                extensionsSection(extensions)
            }
            Divider()
            customization
            Divider()
            websiteData
            if let profile = model.siteSettingsProfileName {
                Text("Choices apply to \(siteName) in the \(profile) profile.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("siteSettingsProfile")
            }
        }
        .padding(16)
        #if os(macOS)
        .frame(width: 330)
        #else
        // The sheet's whole width on iPhone and iPad.
        .frame(maxWidth: .infinity, alignment: .leading)
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("siteSettings")
    }

    /// The site's icon and name, and how secure its connection is.
    private var header: some View {
        HStack(spacing: 10) {
            Group {
                if let url = model.shownPageURL, let icon = model.favicon(for: url) {
                    Image(platformImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "globe").font(.system(size: 18)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(siteName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.head)
                    // In words: the audit can't read a bare address (an IP and port) as a label.
                    .accessibilityLabel("Site Settings for \(siteName)")
                    .accessibilityAddTraits(.isHeader)
                if let indicator = model.connectionIndicator {
                    Label(Self.connectionTitle(for: indicator), systemImage: indicator == .secure ? "lock.fill" : "lock.slash")
                        .font(.caption)
                        .foregroundStyle(indicator == .notPrivate ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .accessibilityIdentifier("siteSettingsConnection")
                }
            }
        }
    }

    /// What the site can use, and the apps it may open without asking.
    private var permissions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("This site can use")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Reset") { Task { await model.resetSiteSettings() } }
                    .controlSize(.small)
                    .disabled(model.sitePermissions.isEmpty && model.siteExternalApps.isEmpty)
                    .help("Ask again for everything")
                    .accessibilityLabel("Reset permissions for \(siteName)")
                    .accessibilityIdentifier("resetSiteSettings")
            }
            ForEach(model.siteSettingsKinds, id: \.self) { kind in
                HStack {
                    Label(Self.title(for: kind), systemImage: Self.symbol(for: kind))
                        .symbolRenderingMode(.hierarchical)
                        .accessibilityHidden(true)
                    Spacer()
                    permissionMenu(for: kind)
                }
            }
            if !model.siteExternalApps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Opens Other Apps Without Asking", systemImage: "arrow.up.forward.app")
                        .symbolRenderingMode(.hierarchical)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(model.siteExternalApps, id: \.self) { scheme in
                        let title = model.siteExternalAppTitles[scheme] ?? "\(scheme):"
                        HStack {
                            Text(title)
                                .padding(.leading, 26)
                            Spacer()
                            Button("Remove") { Task { await model.forgetSiteExternalApp(scheme) } }
                                .controlSize(.small)
                                .accessibilityLabel("Remove \(title)")
                                .accessibilityIdentifier("forgetExternalApp-\(scheme)")
                        }
                        .accessibilityElement(children: .contain)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("siteExternalApps")
            }
            Text("Don't Allow stops the site using it now.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// The extensions that can, or ask to, read and change the site, each with what it may do and
    /// a pin for the toolbar, and the Extensions window for the rest.
    private func extensionsSection(_ extensions: [(item: ExtensionToolbarItem, access: SiteExtensionAccess)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Extensions on this site")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Manage…") {
                    let profileID = model.space?.profileID
                    model.isShowingSiteSettings = false
                    model.showExtensions(profileID: profileID)
                }
                .controlSize(.small)
                .help("Manage this profile's extensions")
                .accessibilityLabel("Manage Extensions…")
                .accessibilityIdentifier("siteManageExtensions")
            }
            ForEach(extensions, id: \.item.id) { entry in
                let name = entry.item.label
                HStack(spacing: 8) {
                    Group {
                        if let icon = entry.item.icon {
                            Image(platformImage: icon).resizable().interpolation(.high)
                        } else {
                            Image(systemName: "puzzlepiece.extension").foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).lineLimit(1)
                        Text(entry.access.title)
                            .font(.caption)
                            .foregroundStyle(entry.access == .granted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    }
                    .accessibilityElement(children: .combine)
                    Spacer()
                    Button {
                        guard let profileID = model.space?.profileID else { return }
                        model.setExtensionPinned(!entry.item.isPinned, extensionID: entry.item.id, name: name, profileID: profileID)
                    } label: {
                        Image(systemName: entry.item.isPinned ? "pin.fill" : "pin")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.borderless)
                    .help(entry.item.isPinned ? "Unpin from the Toolbar" : "Pin to the Toolbar")
                    .accessibilityLabel(entry.item.isPinned ? "Unpin \(name) from the Toolbar" : "Pin \(name) to the Toolbar")
                    .accessibilityIdentifier("siteExtensionPin")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("siteExtension")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("siteExtensions")
    }

    /// A kind's answer as a menu button holding the choices. A menu-style picker's pop-up button
    /// fails the accessibility audit ("Action is missing"), as in Settings; a menu button passes.
    private func permissionMenu(for kind: SitePermission.Kind) -> some View {
        let selection = model.sitePermissions[kind]
        let current = selection.map { $0 == .allow ? "Allow" : "Don't Allow" } ?? Self.defaultTitle(model.siteDefaults[kind])
        return Menu {
            Picker(Self.title(for: kind), selection: Binding(
                get: { model.sitePermissions[kind] },
                set: { decision in Task { await model.setSitePermission(decision, for: kind) } }
            )) {
                // Without an answer of its own, the profile's default decides (#133).
                Text(Self.defaultTitle(model.siteDefaults[kind])).tag(SitePermission.Decision?.none)
                Text("Allow").tag(SitePermission.Decision?.some(.allow))
                Text("Don't Allow").tag(SitePermission.Decision?.some(.deny))
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Text(current)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: .rect(cornerRadius: 6))
        }
        // As the Extensions menu: a plain button VoiceOver can press, named for itself. The
        // default menu button style failed the audit too ("Action is missing", no label).
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Self.title(for: kind))
        .accessibilityValue(current)
        .accessibilityIdentifier("sitePermission-\(kind.rawValue)")
    }

    /// The site's own CSS and JavaScript: a switch and Edit for the one that covers it, or a
    /// button to add one.
    @ViewBuilder
    private var customization: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Customization")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if let customization = model.selectedSiteCustomization {
                HStack {
                    Toggle(isOn: Binding(
                        get: { customization.isEnabled },
                        set: { enabled in Task { await model.setCustomizationEnabled(enabled, id: customization.id) } }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("CSS and JavaScript")
                            Text(customization.domain)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel("Customization for \(customization.domain)")
                    .accessibilityIdentifier("siteCustomizationSwitch")
                    Spacer()
                    Button("Edit…") { customize() }
                        .controlSize(.small)
                        .accessibilityLabel("Edit Customization for \(customization.domain)")
                        .accessibilityIdentifier("customizeSiteButton")
                }
                Text("Applies to pages loaded after a change.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Add your own CSS and JavaScript to this site.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Customize…") { customize() }
                        .controlSize(.small)
                        .accessibilityLabel("Customize \(siteName)")
                        .accessibilityIdentifier("customizeSiteButton")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("siteCustomizationSection")
    }

    /// Clearing the site's cookies and data, and every site's permissions in Settings.
    private var websiteData: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cookies and site data")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            HStack {
                Button("Clear Website Data…") { model.confirmClearSiteData() }
                    .accessibilityLabel("Clear Website Data for \(siteName)…")
                    .accessibilityIdentifier("clearSiteDataButton")
                Spacer()
                #if os(macOS)
                Button("All Settings…") {
                    model.manageWebsitePermissions()
                    settingsPane = .profiles
                    openSettings()
                }
                .help("Every site's permissions in this profile, in Settings")
                .accessibilityIdentifier("manageWebsitePermissions")
                #endif
            }
        }
    }

    private func customize() {
        model.isShowingSiteSettings = false
        model.customizeCurrentSite()
    }

    /// How the header says the connection is.
    static func connectionTitle(for indicator: ConnectionIndicator) -> String {
        switch indicator {
        case .secure: "Connection is secure"
        case .notSecure: "Connection isn't secure"
        case .notPrivate: "Connection isn't private"
        }
    }

    /// Each kind's symbol.
    static func symbol(for kind: SitePermission.Kind) -> String {
        switch kind {
        case .camera: "video"
        case .microphone: "mic"
        case .location: "location"
        case .notifications: "bell"
        case .clipboard: "doc.on.clipboard"
        }
    }

    /// What a site without an answer of its own gets, as its row says it.
    static func defaultTitle(_ decision: SitePermission.Decision?) -> String {
        switch decision {
        case nil: "Ask"
        case .allow: "Allow (Default)"
        case .deny: "Don't Allow (Default)"
        }
    }

    static func title(for kind: SitePermission.Kind) -> String {
        switch kind {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .location: "Location"
        case .notifications: "Notifications"
        case .clipboard: "Clipboard"
        }
    }
}
