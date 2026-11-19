import AxoCore
import AxoWeb
import Foundation

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
    /// http and https sites with a host count. `nil` for anything else.
    public static func websiteOrigin(from text: String) -> PageOrigin? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: withScheme), url.user == nil, url.password == nil,
              let host = url.host(), host.contains(".") || host == "localhost" || host.contains(":") else { return nil }
        return PageOrigin(url: url)
    }

    /// Saves a site's answer for a kind, or forgets it (`nil`), and applies it now: the engine's
    /// copy follows for kinds it keeps itself, and denying stops the site's pages using the
    /// device. Site Settings and the pane both go through here.
    func applyWebsitePermission(_ decision: SitePermission.Decision?, for kind: SitePermission.Kind, origin: PageOrigin, profileID: Profile.ID) async {
        try? await store.sitePermissions.setDecision(decision, for: [kind], origin: origin.serialized, profileID: profileID)
        if let lasting = SitePermissionAdapter.lastingKind(for: kind) {
            pool.setLastingPermission(lasting, origin: origin, decision: decision.map { $0 == .allow ? .allow : .deny }, profileID: profileID)
        }
        if decision == .deny {
            pool.stopCapture(SitePermissionAdapter.capture(for: kind), origin: origin, profileID: profileID)
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
        guard let origin = Self.websiteOrigin(from: text) else { return false }
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
        announce("Removed every website's \(SiteSettingsView.title(for: kind).lowercased()) answer")
        if siteSettingsOrigin != nil { await refreshSiteSettings() }
    }

    /// Sets what sites without an answer get for a kind, or `nil` to ask, and says so.
    public func setWebsitePermissionDefault(_ decision: SitePermission.Decision?, for kind: SitePermission.Kind, profileID: Profile.ID) async {
        try? await store.sitePermissions.setDefault(decision, for: kind, profileID: profileID)
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
        websitePermissionsFocus = siteSettingsOrigin
        websitePermissionsProfileID = space?.profileID
        isShowingSiteSettings = false
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
            Text("Each profile keeps its own answers. They stay on this Mac and don't sync through iCloud.")
                .foregroundStyle(.secondary)
        }
        .task(id: profileID) { await follow() }
        .onAppear(perform: showFocus)
        .onChange(of: model.websitePermissionsFocus) { showFocus() }
        .sheet(item: $editing) { editing in
            WebsitePermissionsSheet(model: model, profileID: profileID, kind: editing.kind, initialQuery: editing.query, snapshot: snapshot)
        }
    }

    /// Opens the sheet for the site Site Settings asked about: on a kind it has an answer for,
    /// searched for its host.
    private func showFocus() {
        guard model.websitePermissionsProfileID == profileID || model.websitePermissionsProfileID == nil,
              let origin = model.websitePermissionsFocus else { return }
        model.websitePermissionsFocus = nil
        let kinds = model.websitePermissionKinds
        let answered = kinds.first { kind in snapshot.answers.contains { $0.kind == kind && $0.origin == origin.serialized } }
        editing = .init(kind: answered ?? kinds.first ?? .camera, query: origin.host)
    }

    private func follow() async {
        do {
            for try await next in model.store.sitePermissions.observe(profileID: profileID) {
                snapshot = next
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
    @State private var newSiteDecision: SitePermission.Decision = .allow
    @State private var invalidSite = false
    @State private var isConfirmingRemoveAll = false

    private var title: String { SiteSettingsView.title(for: kind) }

    /// The kind's answers matching the search, by origin.
    static func shownAnswers(_ answers: [SitePermission], kind: SitePermission.Kind, query: String) -> [SitePermission] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return answers.filter { $0.kind == kind && (trimmed.isEmpty || $0.origin.localizedCaseInsensitiveContains(trimmed)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("When other websites ask", selection: Binding(
                        get: { snapshot.defaults[kind] },
                        set: { decision in Task { await model.setWebsitePermissionDefault(decision, for: kind, profileID: profileID) } }
                    )) {
                        Text("Ask").tag(SitePermission.Decision?.none)
                        Text("Allow").tag(SitePermission.Decision?.some(.allow))
                        Text("Don't Allow").tag(SitePermission.Decision?.some(.deny))
                    }
                    .accessibilityLabel("\(title) for other websites")
                    .accessibilityIdentifier("websitePermissionDefault")
                    if model.isBlockedBySystem(kind) {
                        Label("Axo can't use the \(title.lowercased()) on this Mac. Allow it in System Settings › Privacy & Security.",
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
                            .onSubmit(addSite)
                            .accessibilityLabel("Website to add")
                            .accessibilityIdentifier("websitePermissionNewSite")
                        Picker("Answer", selection: $newSiteDecision) {
                            Text("Allow").tag(SitePermission.Decision.allow)
                            Text("Don't Allow").tag(SitePermission.Decision.deny)
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityLabel("Answer for the website to add")
                        Button("Add", action: addSite)
                            .disabled(newSite.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityIdentifier("websitePermissionAdd")
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
        .navigationTitle(title)
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
            Text(site)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            Picker("\(title) for \(site)", selection: Binding(
                get: { answer.decision },
                set: { decision in
                    guard let origin else { return }
                    Task { await model.setWebsitePermission(decision, for: kind, origin: origin, profileID: profileID) }
                }
            )) {
                Text("Allow").tag(SitePermission.Decision.allow)
                Text("Don't Allow").tag(SitePermission.Decision.deny)
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("\(title) for \(site)")
            Button("Remove") {
                guard let origin else { return }
                Task { await model.setWebsitePermission(nil, for: kind, origin: origin, profileID: profileID) }
            }
            .accessibilityLabel("Remove \(site)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("websitePermissionRow")
    }

    private func addSite() {
        let text = newSite
        Task {
            if await model.addWebsitePermission(text, decision: newSiteDecision, for: kind, profileID: profileID) {
                newSite = ""
                invalidSite = false
            } else {
                invalidSite = true
            }
        }
    }
}
#endif
