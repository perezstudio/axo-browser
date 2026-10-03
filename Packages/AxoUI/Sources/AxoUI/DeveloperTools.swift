import AxoCore

/// Opens the Web Inspector for tabs. AxoInspector provides the real implementation (the only
/// place Axo uses private WebKit API); the app connects them.
@MainActor
public protocol DeveloperToolsProviding: AnyObject {
    /// Opens or closes the inspector for a tab. Returns whether the built-in inspector was
    /// available.
    func toggleInspector(for tabID: AxoCore.Tab.ID) -> Bool
    /// Opens the inspector on its JavaScript console. Returns whether it was available.
    func showConsole(for tabID: AxoCore.Tab.ID) -> Bool
}

extension BrowserModel {
    /// Opens or closes the Web Inspector for the selected tab.
    public func toggleWebInspector() {
        guard let tabID = selectedTabID, let tools = developerTools else { return }
        if !tools.toggleInspector(for: tabID) { explainInspectorFallback() }
    }

    /// Opens the JavaScript console for the selected tab.
    public func showJavaScriptConsole() {
        guard let tabID = selectedTabID, let tools = developerTools else { return }
        if !tools.showConsole(for: tabID) { explainInspectorFallback() }
    }

    private func explainInspectorFallback() {
        alertMessage = "Axo's Web Inspector isn't available on this version of macOS. You can inspect this page from Safari's Develop menu instead."
    }
}
