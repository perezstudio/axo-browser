#if os(macOS)
import AppKit
import AxoWeb
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import AxoUI

/// The Open and Save panels pages' file inputs and pickers get.
@MainActor
struct FilePanelsTests {
    let tabID = UUID()
    let folder = FileManager.default.temporaryDirectory

    @Test func aSavePickerGetsASavePanelWithItsNameAndTypes() throws {
        let request = FileSelectionRequest(
            tabID: tabID, kind: .save, allowsMultipleSelection: false, allowsDirectories: false,
            suggestedName: "notes.txt", directory: folder, allowedExtensions: ["txt", "md", "txt"]
        )
        let panel = FilePanels.panel(for: request)
        #expect(!(panel is NSOpenPanel))
        #expect(panel.nameFieldStringValue == "notes.txt")
        #expect(panel.canCreateDirectories)
        #expect(!panel.isExtensionHidden)
        #expect(panel.allowedContentTypes == [.plainText, try #require(UTType(filenameExtension: "md"))], "Each type once")
        #expect(panel.directoryURL?.standardizedFileURL == folder.standardizedFileURL)
    }

    @Test func fileInputsAndOpenPickersGetAnOpenPanel() throws {
        let input = FileSelectionRequest(tabID: tabID, allowsMultipleSelection: true, allowsDirectories: false)
        let panel = try #require(FilePanels.panel(for: input) as? NSOpenPanel)
        #expect(panel.allowsMultipleSelection)
        #expect(panel.canChooseFiles)
        #expect(!panel.canChooseDirectories)
        #expect(panel.allowedContentTypes.isEmpty, "Any file")

        let images = FileSelectionRequest(tabID: tabID, allowsMultipleSelection: false, allowsDirectories: false, allowedExtensions: ["png"])
        #expect(FilePanels.panel(for: images).allowedContentTypes == [.png])
    }

    @Test func aFolderPickerChoosesOnlyFolders() throws {
        let request = FileSelectionRequest(tabID: tabID, panel: FilePanel(kind: .folder))
        let panel = try #require(FilePanels.panel(for: request) as? NSOpenPanel)
        #expect(panel.canChooseDirectories)
        #expect(!panel.canChooseFiles)
        #expect(!panel.allowsMultipleSelection)
    }

    @Test func cancellingChoosesNothing() {
        let panel = NSSavePanel()
        #expect(FilePanels.chosenFiles(in: panel, response: .cancel) == nil)
    }

    @Test func unknownExtensionsStillGetATypeOfTheirOwn() throws {
        let types = FilePanels.contentTypes(forExtensions: ["axotestformat"])
        #expect(types.count == 1)
        #expect(try #require(types.first).preferredFilenameExtension == "axotestformat")
    }

    @Test func panelsCloseWhenTheirPageGivesUpOrTheirTabCloses() {
        let open = OpenFilePanels()
        var closed: [NSSavePanel] = []
        open.close = { closed.append($0) }
        let first = NSSavePanel(), second = NSOpenPanel(), other = NSSavePanel()
        let otherTab = UUID()
        open.begin(first, for: tabID)
        open.begin(second, for: tabID)
        open.begin(other, for: otherTab)

        open.end(first, for: tabID)
        #expect(open.panels(for: tabID) == [second], "An answered panel is forgotten")
        open.dismiss(tabID)
        #expect(closed == [second])
        #expect(open.panels(for: tabID).isEmpty)
        #expect(open.panels(for: otherTab) == [other], "Only that tab's")

        open.dismiss(tabID)
        #expect(closed == [second], "Nothing left to close")
    }

    @Test func fileAccessAlertsNameTheSiteAndWhatItWants() {
        let site = PageOrigin(scheme: "https", host: "editor.example.com")
        func copy(_ kind: FileAccessRequest.Kind, _ name: String?, folder: Bool) -> (title: String, message: String, button: String) {
            PagePromptModifier.fileAccessCopy(for: FileAccessRequest(tabID: tabID, origin: site, kind: kind, name: name, isDirectory: folder))
        }
        #expect(copy(.view, "Photos", folder: true).title == "Let “editor.example.com” view the files in “Photos”?")
        #expect(copy(.view, "Photos", folder: true).button == "View Files")
        #expect(copy(.view, "notes.txt", folder: false).title == "Let “editor.example.com” view “notes.txt”?")
        #expect(copy(.view, "notes.txt", folder: false).message == "The site can see the file.")
        #expect(copy(.edit, "notes.txt", folder: false).title == "Let “editor.example.com” save changes to “notes.txt”?")
        #expect(copy(.edit, "Photos", folder: true).title == "Let “editor.example.com” save changes to the files in “Photos”?")
        #expect(copy(.viewAndEdit, "Photos", folder: true).button == "View and Edit")
        #expect(copy(.restricted, nil, folder: true).title == "“editor.example.com” can't open this folder")
        #expect(copy(.restricted, nil, folder: true).button == "Choose Another")
        #expect(copy(.dangerousFile, "run.command", folder: false).title == "“run.command” can harm your Mac")
        #expect(copy(.dangerousFile, "run.command", folder: false).button == "Save Anyway")
        #expect(copy(.edit, nil, folder: false).title == "Let “editor.example.com” save changes to “this file”?")
    }
}
#endif
