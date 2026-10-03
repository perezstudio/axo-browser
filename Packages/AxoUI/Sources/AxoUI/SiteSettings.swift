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
        (selectedPage?.url ?? selectedTab?.url).flatMap(PageOrigin.init(url:))
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
            return
        }
        sitePermissions = (try? await store.sitePermissions.decisions(origin: origin.serialized, profileID: profileID)) ?? [:]
    }

    /// Saves an answer for the selected page's site, or forgets it (`nil`) so the site asks again.
    public func setSitePermission(_ decision: SitePermission.Decision?, for kind: SitePermission.Kind) async {
        guard let origin = siteSettingsOrigin, let profileID = space?.profileID else { return }
        try? await store.sitePermissions.setDecision(decision, for: [kind], origin: origin.serialized, profileID: profileID)
        await refreshSiteSettings()
    }

    /// Forgets every answer for the selected page's site.
    public func resetSiteSettings() async {
        guard let origin = siteSettingsOrigin, let profileID = space?.profileID else { return }
        try? await store.sitePermissions.reset(origin: origin.serialized, profileID: profileID)
        await refreshSiteSettings()
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

/// What the selected page's site may use: camera, microphone, and location, each Ask, Allow,
/// or Don't Allow.
struct SiteSettingsView: View {
    let model: BrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.siteSettingsOrigin?.displayName ?? "")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Form {
                ForEach(SitePermission.Kind.allCases, id: \.self) { kind in
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
            HStack {
                Text("Changes apply the next time the site asks.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { Task { await model.resetSiteSettings() } }
                    .disabled(model.sitePermissions.isEmpty)
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
        }
    }
}
