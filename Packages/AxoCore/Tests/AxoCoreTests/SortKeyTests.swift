import Testing
@testable import AxoCore

struct SortKeyTests {
    @Test func firstKeyInAnEmptyList() throws {
        #expect(try SortKey.between(nil, nil) == SortKey.initial)
    }

    @Test func keysAfterAndBeforeAKeySortCorrectly() throws {
        let after = try SortKey.between("a0", nil)
        let before = try SortKey.between(nil, "a0")
        #expect("a0" < after)
        #expect(before < "a0")
    }

    @Test func keyBetweenTwoKeysSortsBetweenThem() throws {
        let pairs: [(String, String)] = [("a0", "a1"), ("a0", "a0V"), ("a1", "a2"), ("Zz", "a0"), ("a0V", "a1")]
        for (lower, upper) in pairs {
            let key = try SortKey.between(lower, upper)
            #expect(lower < key && key < upper, "\(key) is not between \(lower) and \(upper)")
            #expect(SortKey.isValid(key))
        }
    }

    @Test func appendingAThousandItemsKeepsKeysShortAndOrdered() throws {
        var keys: [String] = []
        for _ in 0..<1_000 {
            keys.append(try SortKey.between(keys.last, nil))
        }
        #expect(keys == keys.sorted())
        #expect(Set(keys).count == keys.count)
        #expect(keys.allSatisfy { $0.count <= 4 })
    }

    @Test func prependingAThousandItemsKeepsKeysShortAndOrdered() throws {
        var keys: [String] = []
        for _ in 0..<1_000 {
            keys.insert(try SortKey.between(nil, keys.first), at: 0)
        }
        #expect(keys == keys.sorted())
        #expect(keys.allSatisfy { $0.count <= 4 })
    }

    @Test func repeatedlyInsertingBetweenTheSameNeighborsStaysOrdered() throws {
        // Always insert directly after the first item: the worst case for key growth.
        var keys = ["a0", "a1"]
        for _ in 0..<200 {
            let key = try SortKey.between(keys[0], keys[1])
            keys.insert(key, at: 1)
        }
        #expect(keys == keys.sorted())
        #expect(Set(keys).count == keys.count)
    }

    @Test func randomInsertionsKeepEveryKeyValidAndOrdered() throws {
        var generator = SeededGenerator(seed: 42)
        var keys: [String] = []
        for _ in 0..<2_000 {
            let index = Int.random(in: 0...keys.count, using: &generator)
            let lower = index > 0 ? keys[index - 1] : nil
            let upper = index < keys.count ? keys[index] : nil
            keys.insert(try SortKey.between(lower, upper), at: index)
        }
        #expect(keys == keys.sorted())
        #expect(Set(keys).count == keys.count)
        #expect(keys.allSatisfy(SortKey.isValid))
    }

    @Test func outOfOrderBoundsThrow() {
        #expect(throws: SortKey.Error.outOfOrder(lower: "a1", upper: "a0")) {
            try SortKey.between("a1", "a0")
        }
        #expect(throws: SortKey.Error.outOfOrder(lower: "a1", upper: "a1")) {
            try SortKey.between("a1", "a1")
        }
    }

    @Test(arguments: ["", "0", "a", "a00", "a0!", "b0", "A" + String(repeating: "0", count: 26)])
    func malformedKeysAreRejected(key: String) {
        #expect(!SortKey.isValid(key))
        #expect(throws: SortKey.Error.self) { try SortKey.between(key, nil) }
    }
}

/// A small deterministic random number generator (SplitMix64), so failures reproduce.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
