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

    /// The request kind that keeps a saved kind's answer in the engine, if the engine keeps one.
    static func lastingKind(for kind: SitePermission.Kind) -> PermissionKind? {
        switch kind {
        case .notifications: .notifications
        case .clipboard: .clipboard
        case .camera, .microphone, .location: nil
        }
    }

    func savedDecision(for kind: PermissionKind, origin: PageOrigin, profileID: Profile.ID) async -> PermissionDecision? {
        let saved = (try? await store.decisions(origin: origin.serialized, profileID: profileID)) ?? [:]
        let answers = Self.kinds(for: kind).map { saved[$0] }
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
            siteExternalApps = []
            siteExternalAppTitles = [:]
            return
        }
        sitePermissions = (try? await store.sitePermissions.decisions(origin: origin.serialized, profileID: profileID)) ?? [:]
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
        try? await store.sitePermissions.setDecision(decision, for: [kind], origin: origin.serialized, profileID: profileID)
        if let lasting = SitePermissionAdapter.lastingKind(for: kind) {
            pool.setLastingPermission(lasting, origin: origin, decision: decision.map { $0 == .allow ? .allow : .deny }, profileID: profileID)
        }
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

    /// Replaces the answers the engine keeps itself (notifications and the clipboard) with Axo's
    /// saved ones, in every profile or just `profileID`, forgetting any the engine has that Axo
    /// doesn't: at launch, and after clearing a profile's website data, which clears the engine's.
    func syncLastingPermissions(profileID only: Profile.ID? = nil) async {
        guard let saved = try? await store.sitePermissions.all([.notifications, .clipboard]) else { return }
        let profileIDs = if let only { [only] } else { await profiles().map(\.id) }
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

/// What the selected page's site may use: camera, microphone, location, notifications, and the
/// clipboard, each Ask, Allow, or Don't Allow; and the apps it may open without asking.
struct SiteSettingsView: View {
    let model: BrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.siteSettingsOrigin?.displayName ?? "")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Form {
                ForEach(model.siteSettingsKinds, id: \.self) { kind in
                    Picker(Self.title(for: kind), selection: Binding(
                        get: { model.sitePermissions[kind] },
                        set: { decision in Task { await model.setSitePermission(decision, for: kind) } }
                    )) {
                        Text("Ask").tag(SitePermission.Decision?.none)
                        Text("Allow").tag(SitePermission.Decision?.some(.allow))
                        Text("Don't Allow").tag(SitePermission.Decision?.some(.deny))
                    }
                    .accessibilityIdentifier("sitePermission-\(kind.rawValue)")
                }
            }
            .formStyle(.columns)
            if !model.siteExternalApps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Opens without asking")
                        .font(.subheadline.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    ForEach(model.siteExternalApps, id: \.self) { scheme in
                        let title = model.siteExternalAppTitles[scheme] ?? "\(scheme):"
                        HStack {
                            Text(title)
                            Spacer()
                            Button("Remove") { Task { await model.forgetSiteExternalApp(scheme) } }
                                .accessibilityLabel("Remove \(title)")
                                .accessibilityIdentifier("forgetExternalApp-\(scheme)")
                        }
                        .accessibilityElement(children: .contain)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("siteExternalApps")
            }
            HStack {
                Text("Changes apply the next time the site asks.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Customize…") {
                    model.isShowingSiteSettings = false
                    model.customizeCurrentSite()
                }
                .help("Add your own CSS and JavaScript to this site")
                .accessibilityIdentifier("customizeSiteButton")
                Button("Reset") { Task { await model.resetSiteSettings() } }
                    .disabled(model.sitePermissions.isEmpty && model.siteExternalApps.isEmpty)
                    .accessibilityIdentifier("resetSiteSettings")
            }
        }
        .padding(16)
        .frame(width: 320)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("siteSettings")
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
