import Canvas
import Foundation
import TestKit
import Types

// The order a shape's types are read in, over values: `TypeOrder`, with no editor.

private func id(_ n: Int) -> ShapeID { ShapeID(UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!) }

private struct Random {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }
}

/// Each shape's own list, latest first (what `parents` is); a name not in it has none.
private func graph(_ lists: [Int: [Int]]) -> (ShapeID) -> [ShapeID] {
    { shape in lists.first { id($0.key) == shape }?.value.map(id) ?? [] }
}

private func ids(_ numbers: Int...) -> [ShapeID] { numbers.map(id) }

@MainActor let orderTests = Suite("The order types are read in", [
    test("no heads is empty, one is itself, repeats are once, and a gone name is listed with no parents") {
        let parents = graph([1: [2]])
        expectEqual(TypeOrder.linearized([], parents: parents), [])
        expectEqual(TypeOrder.linearized(ids(2), parents: parents), ids(2))
        expectEqual(TypeOrder.linearized(ids(1, 1), parents: parents), ids(1, 2))
        expectEqual(TypeOrder.linearized(ids(9), parents: parents), ids(9), "nothing knows 9")
        expectEqual(TypeOrder.linearized(ids(1), parents: graph([1: [9, 2]])), ids(1, 9, 2))
    },
    test("unrelated types come in the order the heads name them") {
        expectEqual(TypeOrder.linearized(ids(2, 1), parents: graph([:])), ids(2, 1))
    },
    test("a type builds on its own types before the next head's: 1 is 3, 2 is 4, added 1 then 2") {
        let parents = graph([1: [3], 2: [4]])
        expectEqual(TypeOrder.linearized(ids(2, 1), parents: parents), ids(2, 4, 1, 3), "not 2, 1, 4, 3")
    },
    test("a diamond is read once: D is B and C (B then C), both are A, so C, B, A") {
        let parents = graph([2: [1], 3: [1]])
        expectEqual(TypeOrder.linearized(ids(3, 2), parents: parents), ids(3, 2, 1), "C, B, then A once")
    },
    test("a type is before the one it builds on, whatever order they were given in") {
        // Employee (2) is a Person (1).
        let parents = graph([2: [1]])
        expectEqual(TypeOrder.c3(ids(2, 1), parents: parents), ids(2, 1), "added Person, then Employee")
        expectEqual(TypeOrder.c3(ids(1, 2), parents: parents), nil, "added Employee, then Person: C3 has no order")
        expectEqual(TypeOrder.linearized(ids(1, 2), parents: parents), ids(2, 1), "still Employee first")
    },
    test("two lists that disagree have no C3 order, and the walk breaks the tie") {
        // X (3) is P (1) then Q (2): its list reads Q, P. Y (4) is Q then P: it reads P, Q. Added X then Y.
        let parents = graph([3: [2, 1], 4: [1, 2]])
        expectEqual(TypeOrder.c3(ids(4, 3), parents: parents), nil)
        expectEqual(TypeOrder.linearized(ids(4, 3), parents: parents), ids(4, 3, 1, 2))
    },
    test("a cycle ends where it comes back, the shape asked about is never listed, a shape that is its own parent is once") {
        let ring = graph([1: [2], 2: [3], 3: [1]])
        expectEqual(TypeOrder.linearized(ids(2), excluding: id(1), parents: ring), ids(2, 3))
        expectEqual(TypeOrder.linearized(ids(1), parents: ring), ids(1, 2, 3))
        expectEqual(TypeOrder.c3(ids(2), excluding: id(1), parents: ring), nil)
        let own = graph([1: [1, 2]])
        expectEqual(TypeOrder.linearized(ids(2, 1), excluding: id(1), parents: own), ids(2))
    },
    test("on random graphs: each shape once, the one rule kept, C3's own properties where it has an order") {
        var random = Random(state: 11)
        for round in 0..<200 {
            let count = 2 + random.next(7)
            var lists: [Int: [Int]] = [:]
            for n in 0..<count where random.next(5) != 0 {                                  // some shapes are gone: no entry
                lists[n] = (0..<random.next(4)).map { _ in random.next(count + 1) }       // one past the end is gone too
            }
            let parents = graph(lists)
            let heads = (0..<(1 + random.next(3))).map { _ in id(random.next(count + 1)) }
            let excluding: ShapeID? = random.next(3) == 0 ? id(random.next(count)) : Optional.none
            let order = TypeOrder.linearized(heads, excluding: excluding, parents: parents)
            expectEqual(Set(order).count, order.count, "round \(round): each shape once")
            if let excluding { expect(!order.contains(excluding), "round \(round): the excluded is never listed") }
            let c3 = TypeOrder.c3(heads, excluding: excluding, parents: parents)
            if let c3 { expectEqual(order, c3, "round \(round): C3 where it has an order") }
            // Whatever is reachable from the heads (not through the excluded) is listed.
            var reached: Set<ShapeID> = [], queue = heads.filter { $0 != excluding }
            while let next = queue.popLast() {
                guard reached.insert(next).inserted else { continue }
                queue += parents(next).filter { $0 != excluding }
            }
            expectEqual(Set(order), reached, "round \(round): everything the heads lead to")
            let acyclic = !lists.keys.contains { start in
                var seen: Set<ShapeID> = [], stack = parents(id(start))
                while let next = stack.popLast() {
                    if next == id(start) { return true }
                    if seen.insert(next).inserted { stack += parents(next) }
                }
                return false
            }
            if acyclic {
                for (place, shape) in order.enumerated() {
                    for parent in parents(shape) {
                        if let at = order.firstIndex(of: parent) { expect(at > place, "round \(round): a shape before what it builds on") }
                    }
                }
            }
            if let c3 {
                for (place, shape) in c3.enumerated() {
                    let own = parents(shape).filter { c3.contains($0) }
                    let seen = c3[(place + 1)...].filter { own.contains($0) }
                    expectEqual(seen, own.reduce(into: [ShapeID]()) { if !$0.contains($1) { $0.append($1) } }, "round \(round): its own list, in the order it names them")
                }
            }
        }
    },
    test("on random acyclic graphs: a shape before what it builds on, with the fallback reached often") {
        var random = Random(state: 29)
        var fallbacks = 0
        for round in 0..<300 {
            let count = 3 + random.next(7)
            var lists: [Int: [Int]] = [:]
            for n in 1..<count { lists[n] = (0..<random.next(4)).map { _ in random.next(n) } }   // parents from lower indices only
            let parents = graph(lists)
            let heads = (0..<(1 + random.next(4))).map { _ in id(random.next(count)) }
            let order = TypeOrder.linearized(heads, excluding: nil, parents: parents)
            if TypeOrder.c3(heads, excluding: nil, parents: parents) == nil { fallbacks += 1 }
            expectEqual(Set(order).count, order.count, "round \(round): each shape once")
            for (place, shape) in order.enumerated() {
                for parent in parents(shape) {
                    if let at = order.firstIndex(of: parent) { expect(at > place, "round \(round): a shape before what it builds on") }
                }
            }
        }
        expect(fallbacks >= 20, "the fallback was reached \(fallbacks) times")
    },
])
