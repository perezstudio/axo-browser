import AppKit
import Observation

/// The observable state of a tab's live web view, for the address bar and toolbar.
///
/// The pool keeps it in sync with the web view through key-value observation. It exists only
/// while the tab has a live web view; a hibernated tab's URL and title come from its `Tab` record.
@MainActor
@Observable
public final class WebTabState {
    /// The URL of the current page, or `nil` before the first navigation commits.
    public internal(set) var url: URL?
    /// The current page's title, or an empty string if it has none.
    public internal(set) var title = ""
    /// Whether the web view is loading a page.
    public internal(set) var isLoading = false
    /// The current load's progress, from 0 to 1.
    public internal(set) var estimatedProgress = 0.0
    /// Whether there is a page to go back to.
    public internal(set) var canGoBack = false
    /// Whether there is a page to go forward to.
    public internal(set) var canGoForward = false
    /// A picture of the page from when the tab hibernated, shown while it restores. `nil` once
    /// the restored page finishes loading, or if the tab didn't wake from hibernation.
    public internal(set) var restoringSnapshot: NSImage?

    init() {}
}
