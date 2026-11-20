import AxoCore
import SwiftUI

// MARK: The model

extension BrowserModel {
    /// How searches from the shown Space work: its profile's engine and every engine's keyword.
    public var searchContext: SearchContext {
        SearchContext(engine: searchEngine(forProfile: space?.profileID), engines: searchEngines)
    }

    /// The engine a profile searches with: its choice, or Google.
    public func searchEngine(forProfile profileID: Profile.ID?) -> SearchEngine {
        SearchEngine.engine(for: allProfiles.first { $0.id == profileID }, in: searchEngines)
    }

    /// The profiles that search with `engine` (Google's include those that picked nothing).
    public func profiles(searchingWith engine: SearchEngine) -> [Profile] {
        allProfiles.filter { searchEngine(forProfile: $0.id).id == engine.id }
    }

    /// Adds a custom engine. Returns what's wrong with the fields, if anything.
    public func addSearchEngine(name: String, urlTemplate: String, suggestionsTemplate: String?, keyword: String?) async -> SearchEngine.Problem? {
        do {
            let engine = try await store.searchEngines.add(name: name, urlTemplate: urlTemplate, suggestionsTemplate: suggestionsTemplate, keyword: keyword)
            announce("Added \(engine.name)")
            return nil
        } catch SearchEngineStoreError.invalid(let problem) {
            return problem
        } catch {
            report(error, "Axo couldn't add the search engine.")
            return nil
        }
    }

    /// Changes an engine (only the keyword of a built-in one). Returns what's wrong, if anything.
    public func updateSearchEngine(_ engine: SearchEngine) async -> SearchEngine.Problem? {
        do {
            try await store.searchEngines.update(engine)
            return nil
        } catch SearchEngineStoreError.invalid(let problem) {
            return problem
        } catch {
            report(error, "Axo couldn't change the search engine.")
            return nil
        }
    }

    /// Removes an engine; the profiles that used it search with Google.
    public func removeSearchEngine(_ engine: SearchEngine) async {
        do {
            try await store.searchEngines.remove(id: engine.id)
            announce("Removed \(engine.name)")
        } catch {
            report(error, "Axo couldn't remove the search engine.")
        }
    }

    /// Brings back the built-in engines that were removed.
    public func restoreBuiltInSearchEngines() async {
        do {
            try await store.searchEngines.restoreBuiltIns()
        } catch {
            report(error, "Axo couldn't restore the search engines.")
        }
    }

    /// Sets the engine a profile's Spaces search with.
    public func setSearchEngine(_ engine: SearchEngine, forProfile profileID: Profile.ID) async {
        do {
            try await store.searchEngines.setEngine(engine.id, forProfile: profileID)
        } catch {
            report(error, "Axo couldn't change the profile's search engine.")
        }
    }

    /// Keeps ``searchEngines`` current.
    func observeSearchEngines() {
        searchEnginesObservationTask?.cancel()
        let observation = store.searchEngines.observeEngines()
        searchEnginesObservationTask = Task { [weak self] in
            do {
                for try await engines in observation {
                    self?.searchEngines = engines
                }
            } catch {
                self?.logger.error("Search engine observation failed: \(error)")
            }
        }
    }
}

// Mac only for now; iPhone and iPad have their own chrome.
#if os(macOS)

// MARK: Settings › Search

/// Settings › Search (#132): the engines, each with its keyword and the profiles that search
/// with it, New Search Engine…, and editing or removing one. Each profile picks its engine in
/// Profiles.
struct SearchSettings: View {
    let model: BrowserModel
    @State private var editing: SearchEngineEditor.Target?

    private var visible: [SearchEngine] { model.searchEngines.filter { !$0.isHidden } }
    private var hidden: [SearchEngine] { model.searchEngines.filter(\.isHidden) }

    var body: some View {
        Form {
            Section {
                ForEach(visible) { engine in
                    SearchEngineRow(model: model, engine: engine) { editing = .edit(engine) }
                }
            } header: {
                Text("The search engines you can use from the command bar. Type an engine’s keyword and a space to search with it. Each profile picks its engine in Profiles.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            } footer: {
                HStack {
                    if !hidden.isEmpty {
                        Button(hidden.count == 1 ? "Restore \(hidden[0].name)" : "Restore Removed Engines") {
                            Task { await model.restoreBuiltInSearchEngines() }
                        }
                        .accessibilityIdentifier("restoreSearchEnginesButton")
                    }
                    Spacer()
                    Button("New Search Engine…") { editing = .new }
                        .accessibilityIdentifier("newSearchEngineButton")
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { target in
            SearchEngineEditor(model: model, target: target)
        }
    }
}

/// One engine in the list: its initial, name, keyword, the profiles that use it, and Edit.
private struct SearchEngineRow: View {
    let model: BrowserModel
    let engine: SearchEngine
    let edit: () -> Void

    var body: some View {
        let users = model.profiles(searchingWith: engine).map(\.name)
        HStack(spacing: 10) {
            Text(String(engine.name.prefix(1)).uppercased())
                .font(.callout.bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(.tint, in: .rect(cornerRadius: 6))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.name)
                if !users.isEmpty {
                    Text(users.formatted(.list(type: .and)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let keyword = engine.keyword {
                Text("“\(keyword)”")
                    .foregroundStyle(.secondary)
                    .monospaced()
            }
            Button("Edit…", action: edit)
                .accessibilityLabel("Edit \(engine.name)")
                .accessibilityIdentifier("editSearchEngineButton")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(engine.name)
        .accessibilityValue([
            engine.keyword.map { "Keyword \($0)" },
            users.isEmpty ? nil : "Used by \(users.formatted(.list(type: .and)))",
        ].compactMap(\.self).joined(separator: ", "))
        .accessibilityIdentifier("searchEngineRow")
    }
}

/// Adds or edits an engine: its name, keyword, search URL, and suggestions URL (a built-in
/// engine's name and addresses come from Axo, so only its keyword changes), the profiles that
/// use it, and removing it.
struct SearchEngineEditor: View {
    /// What the sheet edits.
    enum Target: Identifiable {
        case new
        case edit(SearchEngine)

        var id: String {
            switch self {
            case .new: "new"
            case .edit(let engine): engine.id.uuidString
            }
        }
    }

    let model: BrowserModel
    let target: Target
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var keyword = ""
    @State private var urlTemplate = ""
    @State private var suggestionsTemplate = ""
    @State private var problem: SearchEngine.Problem?
    @State private var isConfirmingRemoval = false
    @State private var isSaving = false

    private var engine: SearchEngine? {
        if case .edit(let engine) = target { engine } else { nil }
    }

    private var isBuiltIn: Bool { engine?.isBuiltIn == true }

    var body: some View {
        Form {
            Text(engine == nil ? "New Search Engine" : engine!.name)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if isBuiltIn {
                LabeledContent("Name", value: name)
            } else {
                TextField("Name", text: $name, prompt: Text("Kagi"))
                    .accessibilityIdentifier("searchEngineNameField")
            }
            TextField("Keyword", text: $keyword, prompt: Text("Optional"))
                .accessibilityIdentifier("searchEngineKeywordField")
            if isBuiltIn {
                LabeledContent("Search URL", value: urlTemplate)
            } else {
                TextField("Search URL", text: $urlTemplate, prompt: Text("https://kagi.com/search?q=%s"))
                    .accessibilityIdentifier("searchEngineURLField")
                TextField("Suggestions URL", text: $suggestionsTemplate, prompt: Text("Optional"))
                    .accessibilityIdentifier("searchEngineSuggestionsField")
            }
            Text("%s is replaced with what you type. Type the keyword and a space in the command bar to search with this engine.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let problem {
                Label(problem.message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("searchEngineProblem")
            }
            if let engine {
                let users = model.profiles(searchingWith: engine).map(\.name)
                LabeledContent("Used by", value: users.isEmpty ? "None" : users.formatted(.list(type: .and)))
                if engine.isRemovable {
                    Button(isBuiltIn ? "Remove Search Engine…" : "Delete Search Engine…", role: .destructive) {
                        isConfirmingRemoval = true
                    }
                    .accessibilityIdentifier("removeSearchEngineButton")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear(perform: load)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(engine == nil ? "Add" : "Save") { Task { await save() } }
                    // A second click while saving would add the engine twice.
                    .disabled(isSaving)
                    .accessibilityIdentifier("saveSearchEngineButton")
            }
        }
        .alert(removalTitle, isPresented: $isConfirmingRemoval) {
            // Cancel is the default button, so Return never removes, as for extensions.
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
            Button(isBuiltIn ? "Remove" : "Delete", role: .destructive) {
                guard let engine else { return }
                dismiss()
                Task { await model.removeSearchEngine(engine) }
            }
            .accessibilityIdentifier("confirmRemoveSearchEngineButton")
        } message: {
            Text(removalMessage)
        }
    }

    private var removalTitle: String {
        guard let engine else { return "" }
        return isBuiltIn ? "Remove \(engine.name)?" : "Delete \(engine.name)?"
    }

    /// Names the profiles that will search with Google instead, as the issue asks.
    private var removalMessage: String {
        guard let engine else { return "" }
        let users = model.allProfiles.filter { $0.searchEngineID == engine.id }.map(\.name)
        let profiles = users.isEmpty ? ""
            : "\(users.formatted(.list(type: .and))) \(users.count == 1 ? "uses" : "use") \(engine.name). \(users.count == 1 ? "It" : "They") will search with Google instead. "
        return profiles + (isBuiltIn ? "You can bring it back here later." : "Its keyword stops working.")
    }

    private func load() {
        guard let engine else { return }
        name = engine.name
        keyword = engine.keyword ?? ""
        urlTemplate = engine.urlTemplate
        suggestionsTemplate = engine.suggestionsTemplate ?? ""
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        if var engine {
            engine.name = name
            engine.keyword = keyword
            engine.urlTemplate = urlTemplate
            engine.suggestionsTemplate = suggestionsTemplate
            problem = await model.updateSearchEngine(engine)
        } else {
            problem = await model.addSearchEngine(name: name, urlTemplate: urlTemplate, suggestionsTemplate: suggestionsTemplate, keyword: keyword)
        }
        if problem == nil { dismiss() }
    }
}

/// A profile's search engine, in Settings › Profiles.
struct ProfileSearchSection: View {
    let model: BrowserModel
    let profile: Profile

    var body: some View {
        Section("Search") {
            Picker("Search engine", selection: Binding(
                get: { model.searchEngine(forProfile: profile.id).id },
                set: { id in
                    guard let engine = model.searchEngines.first(where: { $0.id == id }) else { return }
                    Task { await model.setSearchEngine(engine, forProfile: profile.id) }
                }
            )) {
                ForEach(model.searchEngines.filter { !$0.isHidden }) { engine in
                    Text(engine.name).tag(engine.id)
                }
            }
            .accessibilityIdentifier("profileSearchEnginePicker")
            let engine = model.searchEngine(forProfile: profile.id)
            Toggle(isOn: Binding(
                get: { model.allProfiles.first { $0.id == profile.id }?.showsSearchSuggestions ?? true },
                set: { shows in Task { await model.setShowsSearchSuggestions(shows, forProfile: profile.id) } }
            )) {
                Text("Search suggestions")
                Text(engine.suggestionsTemplate == nil
                     ? "\(engine.name) doesn’t offer suggestions."
                     : "As you type in the command bar, what you type is sent to \(engine.name) for suggestions. Off, nothing is sent until you press Return.")
            }
            .accessibilityIdentifier("profileSearchSuggestionsToggle")
            Text("Add and edit search engines in Search.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
#endif
