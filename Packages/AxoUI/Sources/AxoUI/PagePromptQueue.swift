import AppKit
import AxoCore
import AxoWeb
import Foundation

/// A question from a page waiting for an answer: a permission request or a JavaScript dialog.
public struct PagePrompt: Identifiable {
    /// What the page asked.
    public enum Content {
        case permission(PermissionRequest)
        case dialog(JavaScriptDialog)
        case extensionPermission(ExtensionPermissionPrompt)
    }

    /// A stable identifier for presentation.
    public let id = UUID()
    /// What the page asked.
    public let content: Content

    /// The tab whose page asked, or `nil` for an extension's request.
    public var tabID: AxoCore.Tab.ID? {
        switch content {
        case .permission(let request): request.tabID
        case .dialog(let dialog): dialog.tabID
        case .extensionPermission: nil
        }
    }
}

/// Holds page prompts until someone answers them, presenting one at a time in arrival order.
@MainActor
final class PagePromptQueue {
    private enum Answer {
        case permission(CheckedContinuation<PermissionDecision, Never>)
        case dialog(CheckedContinuation<JavaScriptDialogResult, Never>)
        case extensionPermission(CheckedContinuation<Bool, Never>)
    }

    private var pending: [(prompt: PagePrompt, answer: Answer)] = []
    /// Called whenever the prompt at the front of the queue changes.
    var onChange: ((PagePrompt?) -> Void)?

    /// The prompt to show now.
    var current: PagePrompt? { pending.first?.prompt }

    func ask(_ request: PermissionRequest) async -> PermissionDecision {
        await withCheckedContinuation { continuation in
            enqueue(PagePrompt(content: .permission(request)), .permission(continuation))
        }
    }

    func ask(_ dialog: JavaScriptDialog) async -> JavaScriptDialogResult {
        await withCheckedContinuation { continuation in
            enqueue(PagePrompt(content: .dialog(dialog)), .dialog(continuation))
        }
    }

    func ask(_ prompt: ExtensionPermissionPrompt) async -> Bool {
        await withCheckedContinuation { continuation in
            enqueue(PagePrompt(content: .extensionPermission(prompt)), .extensionPermission(continuation))
        }
    }

    /// Answers the current prompt if it's a permission request (from a page or an extension).
    func answerCurrent(with decision: PermissionDecision) {
        guard let first = pending.first else { return }
        switch first.answer {
        case .permission(let continuation):
            pending.removeFirst()
            continuation.resume(returning: decision)
        case .extensionPermission(let continuation):
            pending.removeFirst()
            continuation.resume(returning: decision == .allow)
        case .dialog:
            return
        }
        onChange?(current)
    }

    /// Answers the current prompt if it's a JavaScript dialog.
    func answerCurrent(with result: JavaScriptDialogResult) {
        guard let first = pending.first, case .dialog(let continuation) = first.answer else { return }
        pending.removeFirst()
        continuation.resume(returning: result)
        onChange?(current)
    }

    /// Denies or cancels every prompt from a tab, for example when it closes.
    func dismissAll(from tabID: AxoCore.Tab.ID) {
        let before = current?.id
        let (dismissed, kept) = pending.reduce(into: ([(PagePrompt, Answer)](), [(PagePrompt, Answer)]())) { result, entry in
            if entry.prompt.tabID == tabID { result.0.append(entry) } else { result.1.append(entry) }
        }
        pending = kept.map { (prompt: $0.0, answer: $0.1) }
        for (_, answer) in dismissed {
            switch answer {
            case .permission(let continuation): continuation.resume(returning: .deny)
            case .dialog(let continuation): continuation.resume(returning: .cancelled)
            case .extensionPermission(let continuation): continuation.resume(returning: false)
            }
        }
        if current?.id != before { onChange?(current) }
    }

    private func enqueue(_ prompt: PagePrompt, _ answer: Answer) {
        pending.append((prompt, answer))
        if pending.count == 1 { onChange?(current) }
    }
}
