import AxoCore
import AxoWeb
import Foundation

/// What Site Settings' Manage Website Permissions… asks Settings › Profiles to show (#133): a
/// profile, and a site in it. A new one each time, so asking again for the same site counts.
public struct WebsitePermissionsRequest: Equatable, Sendable {
    public var id = UUID()
    public var profileID: Profile.ID
    public var origin: PageOrigin

    public init(profileID: Profile.ID, origin: PageOrigin) {
        self.profileID = profileID
        self.origin = origin
    }
}

/// Website Permissions in Settings › Profiles (#133): every site's answer for a kind, per profile, and
/// what sites without one get. Changes apply now: the engine's copy follows for kinds it keeps
/// itself, and a site's pages stop using the camera, microphone, or location when it's denied.
extension BrowserModel {
    /// The kinds Website Permissions offers: the ones the engine asks Axo about (camera, microphone, and
    /// location everywhere; notifications and the clipboard on Chromium).
    public var websitePermissionKinds: [SitePermission.Kind] {
        let asked = pool.askedPermissionKinds
        return SitePermission.Kind.allCases.filter { kind in
            guard let lasting = SitePermissionAdapter.lastingKind(for: kind) else { return true }
            return asked.contains(lasting)
        }
    }

    /// A site the person typed, as an origin: `https://` is assumed without a scheme, and only
    /// http and https sites with a whole host count (no empty labels, as in `meet.` or `.com`).
    /// Notifications and the clipboard only reach secure sites, so those take only them. `nil`
    /// for anything else.
    public static func websiteOrigin(from text: String, for kind: SitePermission.Kind? = nil) -> PageOrigin? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: withScheme), url.user == nil, url.password == nil,
              let host = url.host(), let origin = PageOrigin(url: url) else { return nil }
        let isAddress = host.contains(":") || host.allSatisfy { $0.isNumber || $0 == "." }
        if !isAddress {
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            guard labels.count >= 2 || host == "localhost", !labels.contains(where: \.isEmpty) else { return nil }
        }
        if let kind, SitePermissionAdapter.lastingKind(for: kind) != nil, !origin.isPotentiallyTrustworthy { return nil }
        return origin
    }

    /// Whether a kind may default to Allow. Not the camera, microphone, or location: every site
    /// (iframes and ads too) would get them without asking, which Chrome refuses as a default too.
    public static func allowsAllowDefault(_ kind: SitePermission.Kind) -> Bool {
        SitePermissionAdapter.lastingKind(for: kind) != nil
    }

    /// Saves a site's answer for a kind, or forgets it (`nil`), and applies it now: the engine's
    /// copy follows for kinds it keeps itself, and denying stops the site's pages using the
    /// device. Site Settings and the pane both go through here.
    func applyWebsitePermission(_ decision: SitePermission.Decision?, for kind: SitePermission.Kind, origin: PageOrigin, profileID: Profile.ID) async {
        try? await store.sitePermissions.setDecision(decision, for: [kind], origin: origin.serialized, profileID: profileID)
        if let lasting = SitePermissionAdapter.lastingKind(for: kind) {
            pool.setLastingPermission(lasting, origin: origin, decision: decision.map { $0 == .allow ? .allow : .deny }, profileID: profileID)
        }
        await stopCaptureWhereDenied(kind, profileID: profileID)
    }

    /// Stops pages using a kind's device wherever the profile's answer is now deny: a site's own
    /// answer, or the default for sites without one. After any change to answers or defaults.
    func stopCaptureWhereDenied(_ kind: SitePermission.Kind, profileID: Profile.ID) async {
        let capture = SitePermissionAdapter.capture(for: kind)
        guard !capture.isEmpty else { return }
        let fallback = (try? await store.sitePermissions.defaults(profileID: profileID))?[kind]
        for origin in pool.liveOrigins(profileID: profileID) {
            let own = try? await store.sitePermissions.decision(kind, origin: origin.serialized, profileID: profileID)
            if (own ?? fallback) == .deny {
                pool.stopCapture(capture, origin: origin, profileID: profileID)
            }
        }
    }

    /// Sets a site's answer from the pane, and says so.
    public func setWebsitePermission(_ decision: SitePermission.Decision?, for kind: SitePermission.Kind, origin: PageOrigin, profileID: Profile.ID) async {
        await applyWebsitePermission(decision, for: kind, origin: origin, profileID: profileID)
        let title = SiteSettingsView.title(for: kind)
        switch decision {
        case .allow: announce("\(title) allowed for \(origin.displayName)")
        case .deny: announce("\(title) not allowed for \(origin.displayName)")
        case nil: announce("\(origin.displayName) will ask for \(title.lowercased()) again")
        }
        if siteSettingsOrigin == origin { await refreshSiteSettings() }
    }

    /// Adds a site the person typed with an answer. Returns `false` when the text isn't a
    /// website, for the pane to say so.
    @discardableResult
    public func addWebsitePermission(_ text: String, decision: SitePermission.Decision, for kind: SitePermission.Kind, profileID: Profile.ID) async -> Bool {
        guard let origin = Self.websiteOrigin(from: text, for: kind) else { return false }
        await setWebsitePermission(decision, for: kind, origin: origin, profileID: profileID)
        return true
    }

    /// Forgets every site's answer for a kind in a profile, so they all ask again.
    public func removeAllWebsitePermissions(for kind: SitePermission.Kind, profileID: Profile.ID) async {
        let origins = (try? await store.sitePermissions.removeAll(kind, profileID: profileID)) ?? []
        if let lasting = SitePermissionAdapter.lastingKind(for: kind) {
            for text in origins {
                guard let url = URL(string: text), let origin = PageOrigin(url: url) else { continue }
                pool.setLastingPermission(lasting, origin: origin, decision: nil, profileID: profileID)
            }
        }
        await stopCaptureWhereDenied(kind, profileID: profileID)
        announce("Removed every website's \(SiteSettingsView.title(for: kind).lowercased()) answer")
        if siteSettingsOrigin != nil { await refreshSiteSettings() }
    }

    /// Sets what sites without an answer get for a kind, or `nil` to ask, and says so.
    public func setWebsitePermissionDefault(_ decision: SitePermission.Decision?, for kind: SitePermission.Kind, profileID: Profile.ID) async {
        guard decision != .allow || Self.allowsAllowDefault(kind) else { return }
        try? await store.sitePermissions.setDefault(decision, for: kind, profileID: profileID)
        await stopCaptureWhereDenied(kind, profileID: profileID)
        if let lasting = SitePermissionAdapter.lastingKind(for: kind) {
            pool.setDefaultPermission(lasting, decision: decision.map { $0 == .allow ? .allow : .deny }, profileID: profileID)
        }
        let title = SiteSettingsView.title(for: kind)
        switch decision {
        case .allow: announce("Other websites are allowed \(title.lowercased())")
        case .deny: announce("Other websites aren't allowed \(title.lowercased())")
        case nil: announce("Other websites ask for \(title.lowercased())")
        }
    }

    /// Asks Settings › Profiles to show the selected page's site in its profile's Website
    /// Permissions, from Site Settings (which then opens Settings).
    public func manageWebsitePermissions() {
        guard let origin = siteSettingsOrigin, let profileID = space?.profileID else { return }
        websitePermissionsRequest = WebsitePermissionsRequest(profileID: profileID, origin: origin)
        isShowingSiteSettings = false
    }

    /// The kind Settings opens for a requested site: one it has an answer for, or the first.
    static func kindToShow(for origin: PageOrigin, in snapshot: SitePermissionSnapshot, kinds: [SitePermission.Kind]) -> SitePermission.Kind? {
        kinds.first { kind in snapshot.answers.contains { $0.kind == kind && $0.origin == origin.serialized } } ?? kinds.first
    }
}

#if os(macOS)
import SwiftUI

/// A profile's Website Permissions in Settings › Profiles (#133), as the Settings board draws
/// them: a row per permission with how many sites have answered and what other websites get;
/// each opens a sheet with that default and the profile's sites. Answers stay on this Mac.
struct WebsitePermissionsSection: View {
    let model: BrowserModel
    let profileID: Profile.ID
    @State private var snapshot = SitePermissionSnapshot(answers: [], defaults: [:])
    /// Whether the first snapshot arrived, so a requested site opens on a kind it answered.
    @State private var hasLoaded = false
    @State private var editing: WebsitePermissionsSheet.Editing?

    /// A row's summary: how many sites answered, and what other websites get.
    static func summary(_ snapshot: SitePermissionSnapshot, kind: SitePermission.Kind) -> String {
        let count = snapshot.answers.filter { $0.kind == kind }.count
        let sites = count == 0 ? "No websites" : (count == 1 ? "1 website" : "\(count) websites")
        let others = switch snapshot.defaults[kind] {
        case .allow: "others allowed"
        case .deny: "others not allowed"
        case nil: "others ask"
        }
        return "\(sites), \(others)"
    }

    var body: some View {
        Section {
            ForEach(model.websitePermissionKinds, id: \.self) { kind in
                Button {
                    editing = .init(kind: kind, query: "")
                } label: {
                    LabeledContent(SiteSettingsView.title(for: kind)) {
                        HStack(spacing: 4) {
                            Text(Self.summary(snapshot, kind: kind))
                            Image(systemName: "chevron.right").font(.caption).accessibilityHidden(true)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(SiteSettingsView.title(for: kind))
                .accessibilityValue(Self.summary(snapshot, kind: kind))
                .accessibilityHint("Shows the websites that asked")
                .accessibilityIdentifier("websitePermission-\(kind.rawValue)")
            }
        } header: {
            Text("Website Permissions")
        } footer: {
            // The section's work hangs off its footer, one view, so it runs once rather than
            // per row.
            Text("Each profile keeps its own answers. They stay on this Mac and don't sync through iCloud.")
                .foregroundStyle(.secondary)
                .task(id: profileID) { await follow() }
                .onChange(of: model.websitePermissionsRequest?.id) { showRequest() }
                .sheet(item: $editing) { editing in
                    WebsitePermissionsSheet(model: model, profileID: profileID, kind: editing.kind, initialQuery: editing.query, snapshot: snapshot)
                }
        }
    }

    /// Opens the sheet for the site Site Settings asked about, once this profile's answers are
    /// read: on a kind it has an answer for, searched for its host. The request is then done.
    private func showRequest() {
        guard hasLoaded, let request = model.websitePermissionsRequest, request.profileID == profileID else { return }
        model.websitePermissionsRequest = nil
        guard let kind = BrowserModel.kindToShow(for: request.origin, in: snapshot, kinds: model.websitePermissionKinds) else { return }
        editing = .init(kind: kind, query: request.origin.host)
    }

    private func follow() async {
        hasLoaded = false
        do {
            for try await next in model.store.sitePermissions.observe(profileID: profileID) {
                snapshot = next
                if !hasLoaded {
                    hasLoaded = true
                    showRequest()
                }
            }
        } catch {}
    }
}

/// One permission for one profile: what other websites get, and every site's answer, which can
/// be changed, removed, or added, or all removed.
struct WebsitePermissionsSheet: View {
    /// What the sheet shows: a kind, and a search to start with.
    struct Editing: Identifiable {
        var kind: SitePermission.Kind
        var query: String
        var id: String { kind.rawValue }
    }

    let model: BrowserModel
    let profileID: Profile.ID
    let kind: SitePermission.Kind
    let initialQuery: String
    /// The profile's answers and defaults, kept current by the section.
    let snapshot: SitePermissionSnapshot
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var newSite = ""
    @State private var invalidSite = false
    @State private var isConfirmingRemoveAll = false

    private var title: String { SiteSettingsView.title(for: kind) }

    /// The device a kind uses, in a sentence.
    static func deviceName(_ kind: SitePermission.Kind) -> String {
        switch kind {
        case .camera: "the camera"
        case .microphone: "the microphone"
        case .location: "your location"
        case .notifications: "notifications"
        case .clipboard: "the clipboard"
        }
    }

    /// The kind's answers matching the search, by origin.
    static func shownAnswers(_ answers: [SitePermission], kind: SitePermission.Kind, query: String) -> [SitePermission] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return answers.filter { $0.kind == kind && (trimmed.isEmpty || $0.origin.localizedCaseInsensitiveContains(trimmed)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Text(title)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Picker("When other websites ask", selection: Binding(
                        get: { snapshot.defaults[kind] },
                        set: { decision in Task { await model.setWebsitePermissionDefault(decision, for: kind, profileID: profileID) } }
                    )) {
                        Text("Ask").tag(SitePermission.Decision?.none)
                        if BrowserModel.allowsAllowDefault(kind) {
                            Text("Allow").tag(SitePermission.Decision?.some(.allow))
                        }
                        Text("Don't Allow").tag(SitePermission.Decision?.some(.deny))
                    }
                    // Every choice on screen (a pop-up in this sheet had no action VoiceOver
                    // could press, as in the Extensions window).
                    .pickerStyle(.radioGroup)
                    .accessibilityLabel("\(title) for other websites")
                    .accessibilityIdentifier("websitePermissionDefault")
                    if model.isBlockedBySystem(kind) {
                        Label("Axo can't use \(Self.deviceName(kind)) on this Mac. Allow it in System Settings › Privacy & Security.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Websites") {
                    TextField("Search", text: $query, prompt: Text("Search websites"))
                        .accessibilityLabel("Search websites")
                    let shown = Self.shownAnswers(snapshot.answers, kind: kind, query: query)
                    if shown.isEmpty {
                        Text(query.isEmpty ? "No websites have asked yet." : "No matching websites.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(shown, id: \.origin) { answer in
                            row(for: answer)
                        }
                    }
                }
                Section {
                    HStack {
                        TextField("Add a website", text: $newSite, prompt: Text("meet.example.com"))
                            .accessibilityLabel("Website to add")
                            .accessibilityIdentifier("websitePermissionNewSite")
                        Button("Allow") { addSite(.allow) }
                            .disabled(newSite.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityLabel("Allow the website")
                            .accessibilityIdentifier("websitePermissionAddAllow")
                        Button("Don't Allow") { addSite(.deny) }
                            .disabled(newSite.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityLabel("Don't allow the website")
                            .accessibilityIdentifier("websitePermissionAddDeny")
                    }
                    if invalidSite {
                        Text("Enter a website's address, such as meet.example.com.")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Remove All…", role: .destructive) { isConfirmingRemoveAll = true }
                    .disabled(snapshot.answers.allSatisfy { $0.kind != kind })
                    .accessibilityIdentifier("websitePermissionsRemoveAll")
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 480, height: 520)
        .onAppear { query = initialQuery }
        .confirmationDialog("Remove every website's \(title.lowercased()) answer?", isPresented: $isConfirmingRemoveAll) {
            Button("Remove All", role: .destructive) {
                Task { await model.removeAllWebsitePermissions(for: kind, profileID: profileID) }
            }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("They'll ask again the next time they want it.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("websitePermissionsSheet")
    }

    private func row(for answer: SitePermission) -> some View {
        let origin = URL(string: answer.origin).flatMap(PageOrigin.init(url:))
        let site = origin?.displayName ?? answer.origin
        return HStack {
            // On means Allow. The switch is labeled with the site, so VoiceOver reads "Camera for
            // meet.example.com, on".
            Toggle(isOn: Binding(
                get: { answer.decision == .allow },
                set: { allowed in
                    guard let origin else { return }
                    Task { await model.setWebsitePermission(allowed ? .allow : .deny, for: kind, origin: origin, profileID: profileID) }
                }
            )) {
                Text(site)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .toggleStyle(.switch)
            .accessibilityLabel("\(title) for \(site)")
            .accessibilityIdentifier("websitePermissionSwitch")
            Button("Remove") {
                guard let origin else { return }
                Task { await model.setWebsitePermission(nil, for: kind, origin: origin, profileID: profileID) }
            }
            .accessibilityLabel("Remove \(site)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("websitePermissionRow")
    }

    private func addSite(_ decision: SitePermission.Decision) {
        let text = newSite
        Task {
            if await model.addWebsitePermission(text, decision: decision, for: kind, profileID: profileID) {
                newSite = ""
                invalidSite = false
            } else {
                invalidSite = true
            }
        }
    }
}
#endif
