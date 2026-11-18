import Foundation
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
    public internal(set) var restoringSnapshot: PlatformImage?
    /// Where the link under the pointer, or with keyboard focus, goes, for the status label over
    /// the page; `nil` when there's none, or while the page isn't showing.
    public internal(set) var hoveredLink: URL?
    /// The colors the current page offers for the toolbar (its `theme-color`, or the color at its
    /// top), read each time it finishes loading; `nil` before that, or when a load fails.
    public internal(set) var pageColors: PageColors?
    /// Whether the page plays sound, is muted, and what it uses (#71, #74), for its tab's row.
    public internal(set) var media = PageMedia()
    /// Whether the page stopped working, and why (#75), for its tab's row and the page's place;
    /// `nil` while it works.
    public internal(set) var problem: PageProblem?
    /// How secure the page's connection is, and its certificates (#96), for the address bar.
    public internal(set) var security = PageSecurity()
    /// Why the page's last load failed, while the engine's error page shows (#178).
    public internal(set) var loadError: PageLoadError?
    /// The warning showing in place of the page, if any (#178).
    public internal(set) var warning: PageWarning?

    /// Whether Axo covers the page with its own (#75, #178): it stopped working, a load failed,
    /// or a warning shows. The engine's page underneath mustn't take keys or be pictured.
    public var isCovered: Bool { problem != nil || loadError != nil || warning != nil }

    init() {}
}
