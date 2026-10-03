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
private struct PagePromptModifier: ViewModifier {
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
            "Allow “\(request.origin.displayName)” to use your \(Self.noun(for: request.kind))?"
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
            Text("Axo remembers your choice for this site until you quit.")
        case .dialog(let dialog):
            Text(dialog.message)
        case .extensionPermission(let request):
            Text("It wants to:\n" + request.lines.map { "• " + $0 }.joined(separator: "\n"))
        }
    }

    /// The device named in a permission request.
    static func noun(for kind: PermissionKind) -> String {
        switch kind {
        case .camera: "camera"
        case .microphone: "microphone"
        case .cameraAndMicrophone: "camera and microphone"
        case .location: "location"
        }
    }
}
