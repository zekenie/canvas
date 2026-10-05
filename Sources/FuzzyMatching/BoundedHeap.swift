/// The best `capacity` of what's inserted: a heap with the worst on top, so each insert costs a
/// logarithm of the capacity, whatever was inserted before. What ranks a query's matches for the
/// few rows a list shows (the `@` picker's, Jump To's) without sorting every match.
public struct BoundedHeap<Element> {
    public let capacity: Int
    /// Whether the first is worse than the second: what's kept is the best.
    public let isWorse: (Element, Element) -> Bool
    private var heap: [Element] = []

    public init(capacity: Int, isWorse: @escaping (Element, Element) -> Bool) {
        self.capacity = capacity
        self.isWorse = isWorse
    }

    public mutating func insert(_ element: Element) {
        guard capacity > 0 else { return }
        if heap.count < capacity {
            heap.append(element)
            siftUp(heap.count - 1)
        } else if isWorse(heap[0], element) {
            heap[0] = element
            siftDown(0)
        }
    }

    /// The best first.
    public func sorted() -> [Element] { heap.sorted { isWorse($1, $0) } }

    private mutating func siftUp(_ index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard isWorse(heap[child], heap[parent]) else { return }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(_ index: Int) {
        var parent = index
        while true {
            let left = 2 * parent + 1, right = left + 1
            var worst = parent
            if left < heap.count, isWorse(heap[left], heap[worst]) { worst = left }
            if right < heap.count, isWorse(heap[right], heap[worst]) { worst = right }
            guard worst != parent else { return }
            heap.swapAt(parent, worst)
            parent = worst
        }
    }
}
