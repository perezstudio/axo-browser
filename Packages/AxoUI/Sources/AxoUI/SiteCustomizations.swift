import AxoCore
import AxoWeb
import SwiftUI

extension BrowserModel {
    /// The selected page's host, if it's a web page.
    var selectedHost: String? {
        guard let url = selectedPage?.url ?? shownTab?.url,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url.host()?.lowercased()
    }

    /// Opens the editor for the selected page's site: the customization that applies to it, or
    /// a new one for its domain (without "www.").
    public func customizeCurrentSite() {
        guard let host = selectedHost else { return }
        // The most specific one that covers this host, even if it's turned off, so it can be
        // edited or turned back on.
        let existing = siteCustomizations
            .filter { host == $0.domain || host.hasSuffix("." + $0.domain) }
            .max { $0.domain.count < $1.domain.count }
        customizationDraft = existing ?? SiteCustomization(domain: LinkRoute.normalizedDomain(from: host) ?? host)
    }

    /// Saves a customization, optionally reloading the selected page to show it.
    ///
    /// - Returns: A plain message if it can't be saved, or `nil` on success.
    @discardableResult
    public func saveCustomization(_ customization: SiteCustomization, reloadingPage: Bool = false) async -> String? {
        do {
            try await store.siteCustomizations.save(customization)
            let all = try await store.siteCustomizations.all()
            siteCustomizations = all
            pool.setSiteCustomizations(all)
            if reloadingPage, let selectedTabID { pool.reload(selectedTabID) }
            return nil
        } catch SiteCustomizationError.invalidDomain(let text) {
            return "“\(text)” isn't a domain, like example.com."
        } catch SiteCustomizationError.duplicate(let domain) {
            return "\(domain) already has a customization."
        } catch {
            return "Axo couldn't save the customization."
        }
    }

    /// Turns a customization on or off.
    public func setCustomizationEnabled(_ enabled: Bool, id: SiteCustomization.ID) async {
        do {
            try await store.siteCustomizations.setEnabled(enabled, id: id)
            await refreshSiteCustomizations()
        } catch {
            report(error, "Axo couldn't change the customization.")
        }
    }

    /// Deletes a customization.
    public func deleteCustomization(_ id: SiteCustomization.ID) async {
        do {
            try await store.siteCustomizations.delete(id)
            await refreshSiteCustomizations()
        } catch {
            report(error, "Axo couldn't delete the customization.")
        }
    }

    private func refreshSiteCustomizations() async {
        guard let all = try? await store.siteCustomizations.all() else { return }
        siteCustomizations = all
        pool.setSiteCustomizations(all)
    }
}

/// Edits one site's custom CSS and JavaScript.
struct CustomizeSiteSheet: View {
    let model: BrowserModel
    @State private var draft: SiteCustomization
    private let isNew: Bool
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss

    init(model: BrowserModel, customization: SiteCustomization) {
        self.model = model
        _draft = State(initialValue: customization)
        isNew = !model.siteCustomizations.contains { $0.id == customization.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "Customize Site" : "Customize \(draft.domain)")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            HStack {
                TextField("Domain", text: $draft.domain, prompt: Text("example.com"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Domain")
                    .accessibilityIdentifier("customizationDomainField")
                Toggle("On", isOn: $draft.isEnabled)
                    .accessibilityIdentifier("customizationEnabledToggle")
            }
            Text("Applies to this domain and its subdomains, in every profile.")
                .font(.callout).foregroundStyle(.secondary)
            codeEditor("CSS", text: $draft.css, note: "Added before the page appears.", identifier: "customizationCSSEditor")
            codeEditor("JavaScript", text: $draft.js, note: "Runs in the page once it loads.", identifier: "customizationJSEditor")
            if let message {
                Text(message).foregroundStyle(.red).font(.callout)
                    .accessibilityIdentifier("customizationMessage")
            }
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        Task {
                            await model.deleteCustomization(draft.id)
                            dismiss()
                        }
                    }
                    .accessibilityIdentifier("deleteCustomizationButton")
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save and Reload") { save(reloading: true) }
                    .keyboardShortcut("r")
                    .help("Save, and reload the page to see the changes (⌘R)")
                    .disabled(model.selectedHost == nil)
                Button("Save") { save(reloading: false) }
                    .keyboardShortcut("s")
                    .help("Save (⌘S). Changes apply when pages load.")
                    .accessibilityIdentifier("saveCustomizationButton")
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
    }

    private func codeEditor(_ title: String, text: Binding<String>, note: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            TextEditor(text: text)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(.background.secondary, in: .rect(cornerRadius: 6))
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifier)
        }
    }

    private func save(reloading: Bool) {
        Task {
            message = await model.saveCustomization(draft, reloadingPage: reloading)
            if message == nil { dismiss() }
        }
    }
}

/// Settings › Site Customizations: every customized site, to edit, turn off, or delete.
struct SiteCustomizationSettings: View {
    let model: BrowserModel
    @State private var editing: SiteCustomization?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add your own CSS and JavaScript to sites. Each customization applies to a domain and its subdomains; the most specific one wins.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.siteCustomizations.isEmpty {
                ContentUnavailableView("No Customizations", systemImage: "paintbrush", description: Text("Use Customize This Site… on a page, or add a site here."))
                    .frame(maxHeight: .infinity)
            } else {
                List(model.siteCustomizations) { customization in
                    HStack(spacing: 10) {
                        Toggle(customization.domain, isOn: Binding(
                            get: { customization.isEnabled },
                            set: { on in Task { await model.setCustomizationEnabled(on, id: customization.id) } }
                        ))
                        .accessibilityIdentifier("customizationToggle")
                        Text(summary(of: customization)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Edit…") { editing = customization }
                            .accessibilityLabel("Edit \(customization.domain)")
                        Button("Delete", systemImage: "trash") { Task { await model.deleteCustomization(customization.id) } }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Delete")
                            .accessibilityLabel("Delete \(customization.domain)")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("siteCustomization")
                }
            }
            Button("Add Site…") { editing = SiteCustomization(domain: "") }
                .accessibilityIdentifier("addSiteCustomizationButton")
        }
        .padding(20)
        .sheet(item: $editing) { customization in
            CustomizeSiteSheet(model: model, customization: customization)
        }
    }

    private func summary(of customization: SiteCustomization) -> String {
        var parts: [String] = []
        if !customization.css.isEmpty { parts.append("CSS") }
        if !customization.js.isEmpty { parts.append("JavaScript") }
        return parts.isEmpty ? "Empty" : parts.joined(separator: " · ")
    }
}
