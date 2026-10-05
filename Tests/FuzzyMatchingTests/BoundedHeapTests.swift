import FuzzyMatching
import TestKit

// The bounded heap Mentions' picker and Jump To's list keep their best matches in.

@MainActor let boundedHeapTests = Suite("Bounded heap", [
    test("it keeps the best capacity of what's inserted, best first, whatever the order") {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            let values = (0..<200).map { _ in Int.random(in: 0..<1000, using: &generator) }
            var heap = BoundedHeap<Int>(capacity: 10) { $0 < $1 }
            for value in values { heap.insert(value) }
            expectEqual(heap.sorted(), Array(values.sorted(by: >).prefix(10)))
        }
    },
    test("fewer than capacity keeps all; capacity zero keeps none; the order is the caller's") {
        var few = BoundedHeap<String>(capacity: 5) { $0.count > $1.count }
        for word in ["ccc", "a", "bb"] { few.insert(word) }
        expectEqual(few.sorted(), ["a", "bb", "ccc"], "shorter is better here")
        var none = BoundedHeap<Int>(capacity: 0) { $0 < $1 }
        none.insert(1)
        expectEqual(none.sorted(), [])
    },
])
