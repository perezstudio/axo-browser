import Testing
@testable import AxoUI

/// Where tabs go (#136), and what that means for the navigation bar.
struct TabsPlacementTests {
    @Test func tabsAtTheTopPutTheNavigationBarAboveThePage() {
        #expect(TabsPlacement.top.navigationBarPlacement(chosen: .sidebar) == .page)
        #expect(TabsPlacement.top.navigationBarPlacement(chosen: .page) == .page)
    }

    @Test func tabsInTheSidebarKeepTheChosenNavigationBar() {
        #expect(TabsPlacement.sidebar.navigationBarPlacement(chosen: .sidebar) == .sidebar)
        #expect(TabsPlacement.sidebar.navigationBarPlacement(chosen: .page) == .page)
    }

    @Test func rawValuesStayStableForTheSavedSetting() {
        #expect(TabsPlacement.allCases.map(\.rawValue) == ["sidebar", "top"])
        #expect(TabsPlacement.storageKey == "tabsPlacement")
        #expect(TabsPlacement.allCases.map(\.title) == ["In the sidebar", "At the top"])
    }
}
