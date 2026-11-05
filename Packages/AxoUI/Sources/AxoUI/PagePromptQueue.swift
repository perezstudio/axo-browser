#if os(macOS)
import AppKit
#endif
import AxoCore
import AxoWeb
import Foundation

/// A question from a page waiting for an answer: a permission request, a JavaScript dialog, a File
/// System Access question, or a link to another app.
public struct PagePrompt: Identifiable {
    /// What the page asked.
    public enum Content {
        case permission(PermissionRequest)
        case dialog(JavaScriptDialog)
        case extensionPermission(ExtensionPermissionPrompt)
        case fileAccess(FileAccessRequest)
        case externalApp(ExternalAppRequest)
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
        case .fileAccess(let request): request.tabID
        case .externalApp(let request): request.tabID
        }
    }
}

/// Holds page prompts until someone answers them, presenting one at a time in arrival order.
@MainActor
final class PagePromptQueue {
    private enum Answer {
        case permission(CheckedContinuation<PermissionDecision?, Never>)
        case dialog(CheckedContinuation<JavaScriptDialogResult, Never>)
        case extensionPermission(CheckedContinuation<Bool, Never>)
        case fileAccess(CheckedContinuation<Bool?, Never>)
        case externalApp(CheckedContinuation<ExternalAppAnswer, Never>)
    }

    private var pending: [(prompt: PagePrompt, answer: Answer)] = []
    /// Called whenever the prompt at the front of the queue changes.
    var onChange: ((PagePrompt?) -> Void)?
    /// Called when a tab's prompts are taken away (``dismissAll(from:)``), so other questions open
    /// for it (its file panel) can go too.
    var onDismissAll: ((AxoCore.Tab.ID) -> Void)?

    /// The prompt to show now.
    var current: PagePrompt? { pending.first?.prompt }

    /// Asks about a page's permission request: the person's answer, or `nil` if the prompt went
    /// away unanswered (``dismissAll(from:)``).
    func ask(_ request: PermissionRequest) async -> PermissionDecision? {
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

    /// Asks a page's File System Access question: `true` to allow (or, for a restricted file or
    /// folder, to choose another; for a dangerous file, to save it anyway), `false` to refuse, and
    /// `nil` if the prompt went away unanswered.
    func ask(_ request: FileAccessRequest) async -> Bool? {
        await withCheckedContinuation { continuation in
            enqueue(PagePrompt(content: .fileAccess(request)), .fileAccess(continuation))
        }
    }

    /// Takes away a tab's File System Access permission questions from sites other than
    /// `origin`, with no answer: its page went to another site, which shouldn't get the earlier
    /// site's access, as Chrome's own dialog closes when the page navigates. Questions about a
    /// pick the page just made (restricted folders, dangerous files) stay; Chrome checks those
    /// again.
    func dismissFileAccess(from tabID: AxoCore.Tab.ID, notFrom origin: PageOrigin?) {
        let before = current?.id
        pending.removeAll { entry in
            guard case .fileAccess(let request) = entry.prompt.content, request.tabID == tabID,
                  request.origin != origin,
                  [.view, .edit, .viewAndEdit].contains(request.kind),
                  case .fileAccess(let continuation) = entry.answer
            else { return false }
            continuation.resume(returning: nil)
            return true
        }
        if current?.id != before { onChange?(current) }
    }

    /// Asks about a page's link to another app; ``ExternalAppAnswer/cancel`` if the prompt went
    /// away unanswered.
    func ask(_ request: ExternalAppRequest) async -> ExternalAppAnswer {
        await withCheckedContinuation { continuation in
            enqueue(PagePrompt(content: .externalApp(request)), .externalApp(continuation))
        }
    }

    /// Answers the current prompt if it's a link to another app.
    func answerCurrent(externalApp answer: ExternalAppAnswer) {
        guard let first = pending.first, case .externalApp(let continuation) = first.answer else { return }
        pending.removeFirst()
        continuation.resume(returning: answer)
        onChange?(current)
    }

    /// Answers the current prompt if it's a File System Access question.
    func answerCurrent(fileAccess answer: Bool) {
        guard let first = pending.first, case .fileAccess(let continuation) = first.answer else { return }
        pending.removeFirst()
        continuation.resume(returning: answer)
        onChange?(current)
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
        case .dialog, .fileAccess, .externalApp:
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

    /// Takes away every prompt from a tab, for example when it closes: a page's permission request
    /// and a File System Access question get no answer (so nothing is saved), an extension's is
    /// refused, and a dialog or a link to another app is cancelled.
    func dismissAll(from tabID: AxoCore.Tab.ID) {
        let before = current?.id
        let (dismissed, kept) = pending.reduce(into: ([(PagePrompt, Answer)](), [(PagePrompt, Answer)]())) { result, entry in
            if entry.prompt.tabID == tabID { result.0.append(entry) } else { result.1.append(entry) }
        }
        pending = kept.map { (prompt: $0.0, answer: $0.1) }
        for (_, answer) in dismissed {
            switch answer {
            case .permission(let continuation): continuation.resume(returning: nil)
            case .dialog(let continuation): continuation.resume(returning: .cancelled)
            case .extensionPermission(let continuation): continuation.resume(returning: false)
            case .fileAccess(let continuation): continuation.resume(returning: nil)
            case .externalApp(let continuation): continuation.resume(returning: .cancel)
            }
        }
        if current?.id != before { onChange?(current) }
        onDismissAll?(tabID)
    }

    private func enqueue(_ prompt: PagePrompt, _ answer: Answer) {
        pending.append((prompt, answer))
        if pending.count == 1 { onChange?(current) }
    }
}
