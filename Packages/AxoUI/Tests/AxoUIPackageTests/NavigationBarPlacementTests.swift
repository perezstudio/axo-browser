import Testing
@testable import AxoUI

struct NavigationBarPlacementTests {
    @Test func placementsAreStoredByStableNamesAndTitledPlainly() {
        // Saved in user defaults, so these raw values must not change.
        #expect(NavigationBarPlacement(rawValue: "sidebar") == .sidebar)
        #expect(NavigationBarPlacement(rawValue: "page") == .page)
        #expect(NavigationBarPlacement.allCases.map(\.title) == ["In the sidebar", "Above the page"])
        #expect(NavigationBarPlacement.storageKey == "navigationBarPlacement")
    }
}
