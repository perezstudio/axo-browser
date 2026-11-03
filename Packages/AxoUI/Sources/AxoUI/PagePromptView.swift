import AxoWeb
import SwiftUI

extension View {
    /// Presents the model's current page prompt as an alert.
    func pagePrompts(model: BrowserModel) -> some View {
        modifier(PagePromptModifier(model: model))
    }
}

/// Shows permission requests and JavaScript dialogs as alerts, one at a time.
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
        }
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
