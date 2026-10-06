import CoreGraphics
import Testing
@testable import AxoUI

struct FavoritesLayoutTests {
    @Test(arguments: [(0, 0), (1, 1), (2, 2), (3, 3), (4, 4), (5, 4), (12, 4)])
    func columnsFollowTheCountUpToFour(count: Int, columns: Int) {
        #expect(FavoritesLayout.columns(count: count, width: 400) == columns)
    }

    @Test func narrowSidebarsGetFewerColumns() {
        // 44 pt tiles with 6 pt between them: 3 fit in 144 pt, 2 in 100 pt, and always at least 1.
        #expect(FavoritesLayout.columns(count: 8, width: 144) == 3)
        #expect(FavoritesLayout.columns(count: 8, width: 100) == 2)
        #expect(FavoritesLayout.columns(count: 8, width: 10) == 1)
        #expect(FavoritesLayout.columns(count: 2, width: 144) == 2, "The count still caps it")
    }
}
