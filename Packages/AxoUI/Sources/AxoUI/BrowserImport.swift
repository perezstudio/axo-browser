import AxoCore
import Foundation
import Observation
import SwiftUI

/// A browser Axo can import from, such as Arc or one Chrome profile.
public struct ImportSourceOption: Identifiable, Hashable, Sendable {
    public var id: String
    /// The name shown in the browser picker.
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Something that can be imported from another browser.
public enum ImportPart: String, CaseIterable, Hashable, Sendable {
    /// Arc's Spaces, with their pinned tabs and folders. Always part of an Arc import.
    case spaces
    case favorites
    case openTabs
    case bookmarks
    case history
}

/// How much there is to import from a browser, or how much was imported.
public struct ImportCounts: Hashable, Sendable {
    public var spaces: Int
    public var pinnedTabs: Int
    public var favorites: Int
    public var openTabs: Int
    public var bookmarks: Int
    public var historyPages: Int

    public init(spaces: Int = 0, pinnedTabs: Int = 0, favorites: Int = 0, openTabs: Int = 0, bookmarks: Int = 0, historyPages: Int = 0) {
        self.spaces = spaces
        self.pinnedTabs = pinnedTabs
        self.favorites = favorites
        self.openTabs = openTabs
        self.bookmarks = bookmarks
        self.historyPages = historyPages
    }

    /// The parts with something in them, in display order.
    public var parts: [ImportPart] {
        ImportPart.allCases.filter { count(of: $0) > 0 }
    }

    /// The number of items in a part.
    public func count(of part: ImportPart) -> Int {
        switch part {
        case .spaces: spaces
        case .favorites: favorites
        case .openTabs: openTabs
        case .bookmarks: bookmarks
        case .history: historyPages
        }
    }

    /// A plain description of a part, such as "5 Spaces, with 141 pinned tabs".
    public func description(of part: ImportPart) -> String {
        switch part {
        case .spaces: "\(Self.count(spaces, "Space", "Spaces")), with \(Self.count(pinnedTabs, "pinned tab", "pinned tabs"))"
        case .favorites: "\(Self.count(favorites, "favorite", "favorites")), in a Favorites folder"
        case .openTabs: Self.count(openTabs, "open tab", "open tabs")
        case .bookmarks: "\(Self.count(bookmarks, "bookmark", "bookmarks")), as pinned tabs in an “Imported from Chrome” folder"
        case .history: Self.count(historyPages, "page of history", "pages of history")
        }
    }

    /// A one-line summary of everything, such as "5 Spaces, 141 pinned tabs, and 1,273 pages of
    /// history".
    public var summary: String {
        var items: [String] = []
        if spaces > 0 { items.append(Self.count(spaces, "Space", "Spaces")) }
        if pinnedTabs > 0 { items.append(Self.count(pinnedTabs, "pinned tab", "pinned tabs")) }
        if favorites > 0 { items.append(Self.count(favorites, "favorite", "favorites")) }
        if openTabs > 0 { items.append(Self.count(openTabs, "open tab", "open tabs")) }
        if bookmarks > 0 { items.append(Self.count(bookmarks, "bookmark", "bookmarks")) }
        if historyPages > 0 { items.append(Self.count(historyPages, "page of history", "pages of history")) }
        return items.isEmpty ? "Nothing" : items.formatted(.list(type: .and))
    }

    private static func count(_ value: Int, _ singular: String, _ plural: String) -> String {
        "\(value.formatted()) \(value == 1 ? singular : plural)"
    }
}

/// Reads and imports other browsers' data. AxoImport provides the real implementation; the app
/// connects them. Tests use fakes.
@MainActor
public protocol BrowserImporting: AnyObject {
    /// The browsers with data on this Mac.
    func availableSources() -> [ImportSourceOption]
    /// Counts what there is to import from a browser, without changing anything.
    func preview(_ sourceID: String) async throws -> ImportCounts
    /// Imports the chosen parts from a browser. Bookmarks go into `currentSpace`.
    func importData(from sourceID: String, parts: Set<ImportPart>, currentSpace: Space) async throws -> ImportCounts
}

/// The state of the Import sheet: which browser, what it has, and what to bring over.
@Observable
public final class ImportSession: Identifiable {
    /// Where the import is.
    public enum Phase: Equatable {
        /// Reading what the chosen browser has.
        case loading
        /// Showing what can be imported.
        case choosing(ImportCounts)
        /// Reading the browser's data failed.
        case unreadable(String)
        /// Importing.
        case importing
        /// Finished, with what was imported.
        case finished(ImportCounts)
        /// Importing failed.
        case failed(String)
    }

    public let id = UUID()
    /// The browsers found on this Mac.
    public let sources: [ImportSourceOption]
    /// The chosen browser.
    public private(set) var sourceID: String?
    public private(set) var phase: Phase
    /// The parts the person chose. Every part is chosen until they turn it off.
    public private(set) var selectedParts: Set<ImportPart> = Set(ImportPart.allCases)

    @ObservationIgnored private let importer: any BrowserImporting
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    init(importer: any BrowserImporting) {
        self.importer = importer
        sources = importer.availableSources()
        phase = .loading
    }

    /// Chooses a browser and reads what it has.
    public func selectSource(_ id: String) async {
        guard sources.contains(where: { $0.id == id }) else { return }
        sourceID = id
        selectedParts = Set(ImportPart.allCases)
        phase = .loading
        do {
            let counts = try await importer.preview(id)
            guard sourceID == id else { return }
            phase = .choosing(counts)
        } catch {
            guard sourceID == id else { return }
            phase = .unreadable(error.localizedDescription)
        }
    }

    /// Whether a part can be turned off. Arc's Spaces are the import itself.
    public func isOptional(_ part: ImportPart) -> Bool {
        part != .spaces
    }

    /// Turns a part on or off.
    public func setPart(_ part: ImportPart, included: Bool) {
        guard isOptional(part) else { return }
        if included { selectedParts.insert(part) } else { selectedParts.remove(part) }
    }

    /// Whether Import can run: a browser was read and something is chosen.
    public var canImport: Bool {
        guard case .choosing(let counts) = phase else { return false }
        return counts.parts.contains { selectedParts.contains($0) }
    }

    /// Imports the chosen parts into `space` (bookmarks) and the app (Spaces).
    public func run(currentSpace: Space) async {
        guard canImport, let sourceID else { return }
        let parts = selectedParts
        phase = .importing
        do {
            phase = .finished(try await importer.importData(from: sourceID, parts: parts, currentSpace: currentSpace))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

extension BrowserModel {
    /// Opens the Import sheet with the first browser found chosen.
    public func beginImport() {
        guard let browserImporter else { return }
        let session = ImportSession(importer: browserImporter)
        importSession = session
        if let first = session.sources.first {
            Task { await session.selectSource(first.id) }
        }
    }

    /// Runs the import in the open sheet.
    public func runImport() async {
        guard let importSession, let space else { return }
        await importSession.run(currentSpace: space)
    }
}

/// The Import sheet: pick a browser, see what it has, choose what to bring over.
struct ImportSheet: View {
    let model: BrowserModel
    let session: ImportSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text("Import from Another Browser").font(.headline)
            } icon: {
                Image(systemName: "square.and.arrow.down.on.square").font(.title)
            }
            .accessibilityAddTraits(.isHeader)

            if session.sources.isEmpty {
                Text("Axo didn't find Arc or Google Chrome on this Mac.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("importNothingFound")
            } else {
                content
            }

            HStack {
                Spacer()
                switch session.phase {
                case .finished:
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("importDoneButton")
                default:
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(session.phase == .importing)
                    if !session.sources.isEmpty {
                        Button("Import") { Task { await model.runImport() } }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!session.canImport)
                            .accessibilityIdentifier("importButton")
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("importSheet")
    }

    @ViewBuilder
    private var content: some View {
        Picker("Browser:", selection: Binding(
            get: { session.sourceID ?? "" },
            set: { id in Task { await session.selectSource(id) } }
        )) {
            ForEach(session.sources) { Text($0.name).tag($0.id) }
        }
        .disabled(session.phase == .importing || isFinished)
        .accessibilityIdentifier("importSourcePicker")

        switch session.phase {
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        case .choosing(let counts):
            if counts.parts.isEmpty {
                Text("There's nothing to import from this browser.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(counts.parts, id: \.self) { part in
                        Toggle(counts.description(of: part), isOn: Binding(
                            get: { session.selectedParts.contains(part) },
                            set: { session.setPart(part, included: $0) }
                        ))
                        .disabled(!session.isOptional(part))
                        .accessibilityIdentifier("importPart-\(part.rawValue)")
                    }
                }
            }
            Text("Logins, passwords, and cookies aren't imported, so you'll sign in to websites again.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .unreadable(let message), .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("importError")
        case .importing:
            ProgressView("Importing…").controlSize(.small).frame(maxWidth: .infinity)
        case .finished(let counts):
            Text("Imported \(counts.summary).")
                .accessibilityIdentifier("importResult")
        }
    }

    private var isFinished: Bool {
        if case .finished = session.phase { true } else { false }
    }
}
