/// Where a shape sits in the stack: a document paints its shapes in ascending key order, and the
/// key is part of the shape's record, so moving a shape changes that shape alone. A fractional
/// index, as tldraw's: an integer part whose first character says how long it is, then an optional
/// base-62 fraction, compared as plain bytes. There's always a key between two others, so a shape
/// can be put anywhere without touching its neighbors, and two copies of a board that reorder
/// different shapes merge record by record.
public struct StackingKey: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String

    /// Nil if `rawValue` isn't a well-formed key.
    public init?(_ rawValue: String) {
        guard FractionalIndexing.isValid(Array(rawValue.utf8)) else { return nil }
        self.rawValue = rawValue
    }

    private init(bytes: [UInt8]) { rawValue = String(decoding: bytes, as: UTF8.self) }

    /// A key strictly between `a` and `b`, either of which may be open (nil): the shortest there
    /// is. Keys above the top grow only when the integer part runs out of digits, so a shape
    /// brought to the front again and again keeps a short key. `a` must be below `b`.
    public static func between(_ a: StackingKey?, _ b: StackingKey?) -> StackingKey {
        if let a, let b { precondition(a < b, "\(a) isn't below \(b)") }
        return StackingKey(bytes: FractionalIndexing.key(between: a.map { Array($0.rawValue.utf8) }, b.map { Array($0.rawValue.utf8) }))
    }

    public static func < (a: StackingKey, b: StackingKey) -> Bool { a.rawValue.utf8.lexicographicallyPrecedes(b.rawValue.utf8) }

    public var description: String { rawValue }
}

extension StackingKey: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let key = StackingKey(rawValue) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "\"\(rawValue)\" isn't a stacking key")
        }
        self = key
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// How an editor makes new keys. Jittered keys are a random key in the range rather than its
/// midpoint (tldraw's 16 random bisections), so two copies of a board that put shapes at the same
/// place at once almost never pick the same key. Tests that compare keys, or boards encoded byte
/// for byte, use `sequential`.
public struct StackingKeyGenerator: Sendable {
    let jitterBits: Int

    public static let jittered = StackingKeyGenerator(jitterBits: 16)
    /// Always the shortest key: "a0", "a1", "a2"... for shapes added in turn.
    public static let sequential = StackingKeyGenerator(jitterBits: 0)

    /// A key strictly between `a` and `b` (either open). Above the top, it's between the next two
    /// whole keys, and below the bottom between the two before, so keys stay short.
    public func key(between a: StackingKey?, and b: StackingKey?) -> StackingKey {
        guard jitterBits > 0 else { return .between(a, b) }
        var low: StackingKey, high: StackingKey
        switch (a, b) {
        case (nil, nil):
            low = .between(nil, nil)
            high = .between(low, nil)
        case (let a?, nil):
            low = .between(a, nil)
            high = .between(low, nil)
        case (nil, let b?):
            high = .between(nil, b)
            low = .between(nil, high)
        case (let a?, let b?):
            (low, high) = (a, b)
        }
        var random = SystemRandomNumberGenerator()
        for _ in 0..<jitterBits {
            let middle = StackingKey.between(low, high)
            if Bool.random(using: &random) { low = middle } else { high = middle }
        }
        return .between(low, high)
    }
}

/// rocicorp's fractional-indexing (`generateKeyBetween`), over bytes. The integer part's head is a
/// letter: "a" to "z" are 2 to 27 characters long, counting up from "a0"; "Z" down to "A" are 2 to
/// 27 characters, counting down below it. The fraction never ends in "0", so every key has a
/// single spelling.
enum FractionalIndexing {
    static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
    static let zero = digits[0]
    static let top = digits[digits.count - 1]
    static let integerZero = Array("a0".utf8)
    /// Below every integer: only ever a prefix, never a key.
    static let smallestInteger = [UInt8(ascii: "A")] + [UInt8](repeating: zero, count: 26)

    private static let values: [Int] = {
        var table = [Int](repeating: -1, count: 256)
        for (value, digit) in digits.enumerated() { table[Int(digit)] = value }
        return table
    }()

    static func value(of digit: UInt8) -> Int? {
        let value = values[Int(digit)]
        return value < 0 ? nil : value
    }

    static func integerLength(head: UInt8) -> Int? {
        switch head {
        case UInt8(ascii: "a")...UInt8(ascii: "z"): Int(head - UInt8(ascii: "a")) + 2
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): Int(UInt8(ascii: "Z") - head) + 2
        default: nil
        }
    }

    static func isValid(_ key: [UInt8]) -> Bool {
        guard let head = key.first, let length = integerLength(head: head), key.count >= length,
              key.allSatisfy({ value(of: $0) != nil }), key != smallestInteger else { return false }
        return key.count == length || key.last != zero
    }

    static func key(between a: [UInt8]?, _ b: [UInt8]?) -> [UInt8] {
        guard let a else {
            guard let b else { return integerZero }
            let integer = integerPart(of: b)
            if integer == smallestInteger { return integer + midpoint(ArraySlice(), b.dropFirst(integer.count)) }
            if integer.count < b.count { return integer }           // b has a fraction: its integer is below it
            guard let below = decrement(integer) else { preconditionFailure("no key is below \(b)") }
            // The smallest integer is only a prefix, never a key.
            return below == smallestInteger ? below + midpoint(ArraySlice(), nil) : below
        }
        let aInteger = integerPart(of: a), aFraction = a.dropFirst(aInteger.count)
        guard let b else {
            return increment(aInteger) ?? aInteger + midpoint(aFraction, nil)
        }
        let bInteger = integerPart(of: b), bFraction = b.dropFirst(bInteger.count)
        if aInteger == bInteger { return aInteger + midpoint(aFraction, bFraction) }
        guard let next = increment(aInteger) else { preconditionFailure("no key is above \(a)") }
        return next.lexicographicallyPrecedes(b) ? next : aInteger + midpoint(aFraction, nil)
    }

    static func integerPart(of key: [UInt8]) -> [UInt8] { Array(key.prefix(integerLength(head: key[0]) ?? 0)) }

    /// A fraction strictly between `a` and `b` (nil: 1). Neither ends in "0", and neither does the result.
    static func midpoint(_ a: ArraySlice<UInt8>, _ b: ArraySlice<UInt8>?) -> [UInt8] {
        if let b {
            // Drop the common prefix, reading past the end of `a` as zeros. (`b` can't end first:
            // it's above `a`.)
            var n = 0
            while n < b.count, (n < a.count ? a[a.startIndex + n] : zero) == b[b.startIndex + n] { n += 1 }
            if n > 0 { return Array(b.prefix(n)) + midpoint(a.dropFirst(n), b.dropFirst(n)) }
        }
        let digitA = a.first.flatMap(value(of:)) ?? 0
        let digitB = b.flatMap { $0.first.flatMap(value(of:)) } ?? digits.count
        if digitB - digitA > 1 {
            return [digits[(digitA + digitB + 1) / 2]]
        }
        // The first digits are consecutive.
        if let b, b.count > 1 { return [b[b.startIndex]] }
        return [digits[digitA]] + midpoint(a.dropFirst(), nil)
    }

    /// Nil past the largest integer.
    static func increment(_ integer: [UInt8]) -> [UInt8]? {
        let head = integer[0]
        var tail = Array(integer.dropFirst())
        var carry = true
        var i = tail.count - 1
        while carry, i >= 0 {
            let digit = value(of: tail[i])! + 1
            if digit == digits.count { tail[i] = zero } else { tail[i] = digits[digit]; carry = false }
            i -= 1
        }
        guard carry else { return [head] + tail }
        if head == UInt8(ascii: "Z") { return [UInt8(ascii: "a"), zero] }
        if head == UInt8(ascii: "z") { return nil }
        let next = head + 1
        if next > UInt8(ascii: "a") { tail.append(zero) } else { tail.removeLast() }
        return [next] + tail
    }

    /// Nil past the smallest integer.
    static func decrement(_ integer: [UInt8]) -> [UInt8]? {
        let head = integer[0]
        var tail = Array(integer.dropFirst())
        var borrow = true
        var i = tail.count - 1
        while borrow, i >= 0 {
            let digit = value(of: tail[i])! - 1
            if digit < 0 { tail[i] = top } else { tail[i] = digits[digit]; borrow = false }
            i -= 1
        }
        guard borrow else { return [head] + tail }
        if head == UInt8(ascii: "a") { return [UInt8(ascii: "Z"), top] }
        if head == UInt8(ascii: "A") { return nil }
        let previous = head - 1
        if previous < UInt8(ascii: "Z") { tail.append(top) } else { tail.removeLast() }
        return [previous] + tail
    }
}
