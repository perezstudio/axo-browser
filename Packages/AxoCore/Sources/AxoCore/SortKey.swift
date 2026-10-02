/// Fractional sort keys for ordering sidebar items.
///
/// A key is an ASCII string that sorts bytewise. To place an item between two neighbors, generate
/// a key between theirs; no other row changes, so a move updates one row and concurrent reorders
/// on two devices rarely collide during sync.
///
/// Keys have an integer part and an optional fraction. The first character gives the integer
/// part's length (`a`...`z` for positive, `Z`...`A` for negative), followed by base-62 digits.
/// Appending or prepending repeatedly only grows keys logarithmically.
///
/// When two items end up with the same key (for example after a sync merge), order them by ID
/// as a tiebreaker.
public enum SortKey {
    /// Errors thrown when the inputs can't produce a key.
    public enum Error: Swift.Error, Equatable {
        /// A key isn't in the expected format.
        case invalidKey(String)
        /// The lower bound is not strictly less than the upper bound.
        case outOfOrder(lower: String, upper: String)
        /// No key exists beyond the input (practically unreachable).
        case exhausted
    }

    /// The key to use for the first item in an empty list.
    public static let initial = "a0"

    /// Returns a key that sorts strictly between `lower` and `upper`.
    ///
    /// - Parameters:
    ///   - lower: The key of the item before the new position, or `nil` for the start of the list.
    ///   - upper: The key of the item after the new position, or `nil` for the end of the list.
    /// - Throws: ``Error`` if a key is malformed or `lower` is not less than `upper`.
    public static func between(_ lower: String?, _ upper: String?) throws -> String {
        let a = lower.map { Array($0.utf8) }
        let b = upper.map { Array($0.utf8) }
        if let a { try validate(a) }
        if let b { try validate(b) }
        if let a, let b, !a.lexicographicallyPrecedes(b) {
            throw Error.outOfOrder(lower: lower!, upper: upper!)
        }
        return String(decoding: try keyBetween(a, b), as: UTF8.self)
    }

    /// Returns `true` if `key` is a well-formed sort key.
    public static func isValid(_ key: String) -> Bool {
        (try? validate(Array(key.utf8))) != nil
    }

    // MARK: - Implementation

    private static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
    private static let zero = digits.first!
    private static let lastDigit = digits.last!
    private static let smallestInteger = Array("A".utf8) + Array(repeating: zero, count: 26)

    private static func digitValue(_ byte: UInt8) -> Int? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): Int(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): Int(byte - UInt8(ascii: "A")) + 10
        case UInt8(ascii: "a")...UInt8(ascii: "z"): Int(byte - UInt8(ascii: "a")) + 36
        default: nil
        }
    }

    private static func integerLength(_ head: UInt8) -> Int? {
        switch head {
        case UInt8(ascii: "a")...UInt8(ascii: "z"): Int(head - UInt8(ascii: "a")) + 2
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): Int(UInt8(ascii: "Z") - head) + 2
        default: nil
        }
    }

    private static func integerPart(_ key: [UInt8]) throws -> ArraySlice<UInt8> {
        guard let head = key.first, let length = integerLength(head), length <= key.count else {
            throw Error.invalidKey(String(decoding: key, as: UTF8.self))
        }
        return key[0..<length]
    }

    private static func validate(_ key: [UInt8]) throws {
        let invalid = Error.invalidKey(String(decoding: key, as: UTF8.self))
        guard key != smallestInteger else { throw invalid }
        let integer = try integerPart(key)
        guard key.dropFirst().allSatisfy({ digitValue($0) != nil }) else { throw invalid }
        if key.count > integer.count, key.last == zero { throw invalid }
    }

    private static func keyBetween(_ a: [UInt8]?, _ b: [UInt8]?) throws -> [UInt8] {
        switch (a, b) {
        case (nil, nil):
            return Array(initial.utf8)

        case (nil, let b?):
            let ib = Array(try integerPart(b))
            let fb = Array(b[ib.count...])
            if ib == smallestInteger { return ib + midpoint([], fb) }
            if ib.count < b.count { return ib }
            guard let decremented = decrement(ib) else { throw Error.exhausted }
            return decremented

        case (let a?, nil):
            let ia = Array(try integerPart(a))
            let fa = Array(a[ia.count...])
            if let incremented = increment(ia) { return incremented }
            return ia + midpoint(fa, nil)

        case (let a?, let b?):
            let ia = Array(try integerPart(a))
            let fa = Array(a[ia.count...])
            let ib = Array(try integerPart(b))
            let fb = Array(b[ib.count...])
            if ia == ib { return ia + midpoint(fa, fb) }
            guard let incremented = increment(ia) else { throw Error.exhausted }
            if incremented.lexicographicallyPrecedes(b) { return incremented }
            return ia + midpoint(fa, nil)
        }
    }

    /// A fraction strictly between `a` and `b`, where `b == nil` means 1. Neither input may end in `0`.
    private static func midpoint(_ a: [UInt8], _ b: [UInt8]?) -> [UInt8] {
        if let b {
            var n = 0
            while (n < a.count ? a[n] : zero) == (n < b.count ? b[n] : nil) { n += 1 }
            if n > 0 {
                return Array(b[0..<n]) + midpoint(Array(a.dropFirst(n)), Array(b.dropFirst(n)))
            }
        }
        let digitA = a.first.flatMap(digitValue) ?? 0
        let digitB = b.flatMap { $0.first.flatMap(digitValue) } ?? digits.count
        if digitB - digitA > 1 {
            return [digits[(digitA + digitB + 1) / 2]]
        }
        if let b, b.count > 1 {
            return [b[0]]
        }
        return [digits[digitA]] + midpoint(Array(a.dropFirst()), nil)
    }

    private static func increment(_ integer: [UInt8]) -> [UInt8]? {
        let head = integer[0]
        var body = Array(integer.dropFirst())
        var carry = true
        var i = body.count - 1
        while carry && i >= 0 {
            let next = digitValue(body[i])! + 1
            if next == digits.count {
                body[i] = zero
            } else {
                body[i] = digits[next]
                carry = false
            }
            i -= 1
        }
        guard carry else { return [head] + body }
        if head == UInt8(ascii: "Z") { return [UInt8(ascii: "a"), zero] }
        if head == UInt8(ascii: "z") { return nil }
        let newHead = head + 1
        if newHead > UInt8(ascii: "a") { body.append(zero) } else { body.removeLast() }
        return [newHead] + body
    }

    private static func decrement(_ integer: [UInt8]) -> [UInt8]? {
        let head = integer[0]
        var body = Array(integer.dropFirst())
        var borrow = true
        var i = body.count - 1
        while borrow && i >= 0 {
            let next = digitValue(body[i])! - 1
            if next == -1 {
                body[i] = lastDigit
            } else {
                body[i] = digits[next]
                borrow = false
            }
            i -= 1
        }
        guard borrow else { return [head] + body }
        if head == UInt8(ascii: "a") { return [UInt8(ascii: "Z"), lastDigit] }
        if head == UInt8(ascii: "A") { return nil }
        let newHead = head - 1
        if newHead < UInt8(ascii: "Z") { body.append(lastDigit) } else { body.removeLast() }
        return [newHead] + body
    }
}
