#if os(macOS)
import AppKit
import AxoCore
import AxoWeb
import UniformTypeIdentifiers

/// The Open and Save panels pages get: for file inputs, and for File System Access pickers on
/// engines that leave them to Axo.
enum FilePanels {
    /// A panel set up for `request`, not shown yet: a Save panel for ``FileSelectionRequest/Kind/save``,
    /// otherwise an Open panel.
    static func panel(for request: FileSelectionRequest) -> NSSavePanel {
        let types = contentTypes(forExtensions: request.allowedExtensions)
        let panel: NSSavePanel
        switch request.kind {
        case .save:
            panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = request.suggestedName ?? ""
            // The page chose the file's type, so its extension stays in view, as in Chrome.
            panel.isExtensionHidden = false
        case .open:
            let open = NSOpenPanel()
            open.allowsMultipleSelection = request.allowsMultipleSelection
            open.canChooseDirectories = request.allowsDirectories
            open.canChooseFiles = request.allowsFiles
            open.prompt = "Choose"
            panel = open
        }
        if !types.isEmpty {
            panel.allowedContentTypes = types
        }
        if let directory = request.directory {
            panel.directoryURL = directory
        }
        return panel
    }

    /// What the person chose in `panel`, closed with `response`, or `nil` when they cancelled.
    static func chosenFiles(in panel: NSSavePanel, response: NSApplication.ModalResponse) -> [URL]? {
        guard response == .OK else { return nil }
        if let open = panel as? NSOpenPanel {
            return open.urls
        }
        return panel.url.map { [$0] }
    }

    /// The types for file extensions a page accepts (without dots). Extensions macOS doesn't know
    /// still get a type of their own, so the panel accepts exactly what the page asked for.
    static func contentTypes(forExtensions extensions: [String]) -> [UTType] {
        var types: [UTType] = []
        for case let type? in extensions.map({ UTType(filenameExtension: $0) }) where !types.contains(type) {
            types.append(type)
        }
        return types
    }
}
/// The file panels open for tabs' pages, so a panel goes away when its page no longer wants the
/// answer (the engine gave up on it) or its tab closes, rather than staying up with its answer
/// going nowhere.
@MainActor
final class OpenFilePanels {
    private var panels: [AxoCore.Tab.ID: [NSSavePanel]] = [:]
    /// Closes a panel as Cancel does, which ends its sheet. Tests replace it.
    var close: (NSSavePanel) -> Void = { $0.cancel(nil) }

    /// The panels open for `tabID`.
    func panels(for tabID: AxoCore.Tab.ID) -> [NSSavePanel] {
        panels[tabID] ?? []
    }

    /// Records `panel` as open for `tabID`'s page.
    func begin(_ panel: NSSavePanel, for tabID: AxoCore.Tab.ID) {
        panels[tabID, default: []].append(panel)
    }

    /// Forgets `panel` once it has closed.
    func end(_ panel: NSSavePanel, for tabID: AxoCore.Tab.ID) {
        panels[tabID]?.removeAll { $0 === panel }
        if panels[tabID]?.isEmpty == true { panels[tabID] = nil }
    }

    /// Closes every panel open for `tabID`, as if cancelled.
    func dismiss(_ tabID: AxoCore.Tab.ID) {
        for panel in panels.removeValue(forKey: tabID) ?? [] {
            close(panel)
        }
    }
}
#endif
