import SwiftUI

// Mac only; iPhone and iPad have their own chrome.
#if os(macOS)
/// The sheets the window's tabs present (the archive, extensions, import, folder and Space
/// names, a site's customization), in whichever layout shows the tabs: the sidebar's, or the
/// tab bar's with tabs at the top (#136), which has no sidebar to present them.
struct BrowserSheets: ViewModifier {
    let model: BrowserModel
    @Binding var isShowingArchive: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isShowingArchive) {
                ArchivedTabsView(model: model).windowAppearance()
            }
            .sheet(item: Binding(get: { model.pendingExtensionInstall }, set: { if $0 == nil { Task { await model.cancelExtensionInstall() } } })) { prompt in
                ExtensionInstallSheet(model: model, prompt: prompt).windowAppearance()
            }
            .sheet(isPresented: Binding(get: { model.isShowingExtensions }, set: { model.isShowingExtensions = $0 })) {
                ExtensionsView(model: model).windowAppearance()
            }
            .sheet(item: Binding(get: { model.importSession }, set: { model.importSession = $0 })) { session in
                ImportSheet(model: model, session: session).windowAppearance()
            }
            .sheet(item: Binding(get: { model.namingRequest }, set: { model.namingRequest = $0 })) { request in
                folderNameSheet(for: request).windowAppearance()
            }
            .sheet(item: Binding(get: { model.customizationDraft }, set: { model.customizationDraft = $0 })) { draft in
                CustomizeSiteSheet(model: model, customization: draft).windowAppearance()
            }
            .sheet(item: Binding(get: { model.spaceToRename }, set: { model.spaceToRename = $0 })) { space in
                NameSheet(title: "Rename Space", initialName: space.name, confirmTitle: "Rename") { name in
                    Task { await model.renameSpace(space.id, to: name) }
                }
                .windowAppearance()
            }
    }

    @ViewBuilder
    private func folderNameSheet(for request: NamingRequest) -> some View {
        switch request {
        case .newFolder(let parent, let moving):
            NameSheet(title: "New Folder", initialName: "", confirmTitle: "Create") { name in
                Task { await model.createFolder(named: name, parent: parent, moving: moving) }
            }
        case .renameFolder(let folder):
            NameSheet(title: "Rename Folder", initialName: folder.name, confirmTitle: "Rename") { name in
                Task { await model.renameFolder(folder.id, to: name) }
            }
        }
    }
}

/// New Space and Delete Space, which the sidebar's footer presents, for the tab bar too.
struct SpaceSheets: ViewModifier {
    @Bindable var model: BrowserModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $model.isCreatingSpace) {
                NewSpaceSheet(model: model).windowAppearance()
            }
            .confirmationDialog(
                "Delete “\(model.spaceToDelete?.name ?? "")”?",
                isPresented: Binding(get: { model.spaceToDelete != nil }, set: { if !$0 { model.spaceToDelete = nil } }),
                presenting: model.spaceToDelete
            ) { space in
                Button("Delete Space", role: .destructive) {
                    Task { await model.deleteSpace(space.id) }
                }
            } message: { _ in
                Text("Its tabs will be closed. Its profile and website data are kept.")
            }
    }
}
#endif
