import AxoWeb
import SwiftUI

extension View {
    /// Presents the model's current page prompt as an alert.
    func pagePrompts(model: BrowserModel) -> some View {
        modifier(PagePromptModifier(model: model))
    }
}

/// Shows permission requests, JavaScript dialogs, File System Access questions, and links to other
/// apps as alerts, one at a time.
///
/// Every alert names the asking site, so a page can't pass its dialogs off as Axo's or another
/// site's.
struct PagePromptModifier: ViewModifier {
    let model: BrowserModel
    @State private var promptText = ""

    func body(content: Content) -> some View {
        content
            .alert(
                title(for: model.currentPrompt),
                isPresented: Binding(get: { model.currentPrompt != nil }, set: { _ in }),
                presenting: model.currentPrompt
            ) { prompt in
                actions(for: prompt)
            } message: { prompt in
                message(for: prompt)
            }
            .onChange(of: model.currentPrompt?.id) {
                if case .dialog(let dialog) = model.currentPrompt?.content, case .prompt(let defaultText) = dialog.kind {
                    promptText = defaultText
                }
            }
    }

    private func title(for prompt: PagePrompt?) -> String {
        switch prompt?.content {
        case .permission(let request):
            Self.question(for: request)
        case .dialog(let dialog):
            dialog.origin.host.isEmpty ? "This page says" : "\(dialog.origin.displayName) says"
        case .extensionPermission(let prompt):
            "Allow “\(prompt.extensionName)” more access?"
        case .fileAccess(let request):
            Self.fileAccessCopy(for: request).title
        case .externalApp(let request):
            Self.externalAppCopy(for: request).title
        case nil:
            ""
        }
    }

    @ViewBuilder
    private func actions(for prompt: PagePrompt) -> some View {
        switch prompt.content {
        case .permission, .extensionPermission:
            Button("Don't Allow", role: .cancel) { model.answerPermission(.deny) }
            Button("Allow") { model.answerPermission(.allow) }
        case .fileAccess(let request):
            // Cancel is the default, as in Chrome: Return mustn't give a site access, or save a
            // dangerous file, right after the person pressed it in the panel.
            Button("Cancel", role: .cancel) { model.answerFileAccess(false) }
                .keyboardShortcut(.defaultAction)
            Button(Self.fileAccessCopy(for: request).button) { model.answerFileAccess(true) }
        case .externalApp(let request):
            if request.appName == nil {
                Button("OK") { model.answerExternalApp(.cancel) }
            } else {
                // Cancel is the default: a page can ask while the person is typing, and their next
                // Return mustn't open an app, or allow one for good.
                Button("Cancel", role: .cancel) { model.answerExternalApp(.cancel) }
                    .keyboardShortcut(.defaultAction)
                if request.canAlwaysAllow {
                    Button("Always Allow") { model.answerExternalApp(.alwaysAllow) }
                }
                Button("Allow") { model.answerExternalApp(.allow) }
            }
        case .dialog(let dialog):
            switch dialog.kind {
            case .alert:
                Button("OK") { model.answerDialog(JavaScriptDialogResult(accepted: true)) }
            case .confirm:
                Button("Cancel", role: .cancel) { model.answerDialog(.cancelled) }
                Button("OK") { model.answerDialog(JavaScriptDialogResult(accepted: true)) }
            case .prompt:
                TextField("Response", text: $promptText)
                    .accessibilityIdentifier("dialogTextField")
                Button("Cancel", role: .cancel) { model.answerDialog(.cancelled) }
                Button("OK") { model.answerDialog(JavaScriptDialogResult(accepted: true, text: promptText)) }
            }
        }
    }

    @ViewBuilder
    private func message(for prompt: PagePrompt) -> some View {
        switch prompt.content {
        case .permission:
            Text("Axo remembers your choice for this site. You can change it in Site Settings.")
        case .dialog(let dialog):
            Text(dialog.message)
        case .extensionPermission(let request):
            Text("It wants to:\n" + request.lines.map { "• " + $0 }.joined(separator: "\n"))
        case .fileAccess(let request):
            Text(Self.fileAccessCopy(for: request).message)
        case .externalApp(let request):
            Text(Self.externalAppCopy(for: request).message)
        }
    }

    /// The words of a File System Access question's alert: its title, its message, and the button
    /// that answers `true` (Cancel answers `false`).
    static func fileAccessCopy(for request: FileAccessRequest) -> (title: String, message: String, button: String) {
        let site = "“\(request.origin.displayName)”"
        let name = "“\(request.name ?? (request.isDirectory ? "this folder" : "this file"))”"
        switch request.kind {
        case .view where !request.isDirectory:
            return ("Let \(site) view \(name)?", "The site can see the file.", "View File")
        case .view:
            return ("Let \(site) view the files in \(name)?", "The site can see everything in the folder.", "View Files")
        case .edit where request.isDirectory:
            return ("Let \(site) save changes to the files in \(name)?", "The site can change, add, and delete files in the folder.", "Save Changes")
        case .edit:
            return ("Let \(site) save changes to \(name)?", "The site can change the file.", "Save Changes")
        case .viewAndEdit:
            return ("Let \(site) view and edit the files in \(name)?", "The site can see everything in the folder, and change, add, and delete files in it.", "View and Edit")
        case .restricted:
            let thing = request.isDirectory ? "folder" : "file"
            return ("\(site) can't open this \(thing)", "It holds system files. Choose another \(thing), or cancel.", "Choose Another")
        case .dangerousFile:
            return ("\(name) can harm your Mac", "\(site) wants to save a file of a type that can run code. Save it only if you trust the site.", "Save Anyway")
        }
    }

    /// The words of a link to another app's alert: its title and message.
    static func externalAppCopy(for request: ExternalAppRequest) -> (title: String, message: String) {
        let scheme = request.url.scheme?.lowercased() ?? ""
        guard let app = request.appName else {
            return ("Axo can't open this link", "No app on this Mac opens “\(scheme):” links.")
        }
        let site = request.origin.map { "“\($0.displayName)”" } ?? "this page"
        let message = !request.canAlwaysAllow
            ? "The link opens in \(app)."
            : "The link opens in \(app). With Always Allow, the site opens “\(scheme):” links without asking."
        return ("Allow \(site) to open “\(app)”?", message)
    }

    /// The question a permission prompt asks.
    static func question(for request: PermissionRequest) -> String {
        let site = "“\(request.origin.displayName)”"
        return switch request.kind {
        case .camera: "Allow \(site) to use your camera?"
        case .microphone: "Allow \(site) to use your microphone?"
        case .cameraAndMicrophone: "Allow \(site) to use your camera and microphone?"
        case .location: "Allow \(site) to use your location?"
        case .notifications: "Allow \(site) to send you notifications?"
        case .clipboard: "Allow \(site) to see text and images you copy?"
        }
    }
}
