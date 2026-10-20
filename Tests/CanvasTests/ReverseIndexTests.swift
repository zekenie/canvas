import Canvas
import TestKit

/// The two sides as a plain table of pairs works them out: what each key names, and what names each value.
private func sides(of pairs: Set<[ShapeID]>) -> (of: [ShapeID: Set<ShapeID>], by: [ShapeID: Set<ShapeID>]) {
    var of: [ShapeID: Set<ShapeID>] = [:], by: [ShapeID: Set<ShapeID>] = [:]
    for pair in pairs {
        of[pair[0], default: []].insert(pair[1])
        by[pair[1], default: []].insert(pair[0])
    }
    return (of, by)
}

@MainActor let reverseIndexTests = Suite("A reverse index", [
    test("what a key names is set and forgotten, and what names each value follows, neither keeping an empty set") {
        let a = ShapeID(), b = ShapeID(), c = ShapeID()
        var index = ReverseIndex()
        index.set([b, c], for: a)
        expectEqual(index.of, [a: [b, c]])
        expectEqual(index.by, [b: [a], c: [a]])
        index.set([c], for: b)
        expectEqual(index.by, [b: [a], c: [a, b]])
        index.set([c, a], for: a)
        expectEqual(index.of, [a: [a, c], b: [c]], "a key may name itself")
        expectEqual(index.by, [a: [a], c: [a, b]])
        index.forget(a)
        expectEqual(index.of, [b: [c]])
        expectEqual(index.by, [c: [b]], "what named nothing else goes")
        index.set([], for: b)
        expectEqual(index.of, [:])
        expectEqual(index.by, [:])
    },
    test("whatever is set and forgotten, in whatever order, the two sides are the pairs it holds, both ways") {
        var generator = Seeded(seed: 0x5E7_1D3)
        let ids = (0..<6).map { _ in ShapeID() }
        for round in 0..<200 {
            var index = ReverseIndex()
            var named: [ShapeID: Set<ShapeID>] = [:]
            for _ in 0..<12 {
                let key = ids[Int(generator.next() % 6)]
                if generator.next() % 5 == 0 {
                    index.forget(key)
                    named[key] = nil
                } else {
                    let values = Set(ids.filter { _ in generator.next() % 3 == 0 })
                    index.set(values, for: key)
                    named[key] = values.isEmpty ? nil : values
                }
            }
            let expected = sides(of: Set(named.flatMap { key, values in values.map { [key, $0] } }))
            expectEqual(index.of, expected.of, "round \(round)")
            expectEqual(index.by, expected.by, "round \(round)")
        }
    },
])

/// A small seeded generator (SplitMix64), so the run is the same each time.
private struct Seeded {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
