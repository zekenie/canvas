import Canvas
import Foundation
import FuzzyMatching
import os
import Topology

/// Where a hit is: which of its shape's texts (in the order the index keeps them), and where in it
/// (UTF-16, as the text reads), and whether it's the query as typed or a typo's.
public struct FindHit: Hashable, Sendable {
    public let text: Int
    public let range: Range<Int>
    public let isExact: Bool

    public init(text: Int, range: Range<Int>, isExact: Bool = true) {
        self.text = text
        self.range = range
        self.isExact = isExact
    }
}

/// A shape a search found something in: how many hits, the first, and where it is in what's
/// searched (`rank`: its place among the scope's shapes, in order).
public struct FindResult: Hashable, Sendable, Identifiable {
    public let id: ShapeID
    public let board: BoardID
    public let hitCount: Int
    public let first: FindHit
    let rank: Int
}

/// One keystroke's search, handed off the main actor whole: the query, the index's entries as they
/// were (shared until a commit changes them, which then copies the table once: held for this
/// search, never past it), and the scope, ordered already if a search before ordered it and
/// nothing has changed the file's shapes since, else with what orders it (Topology's snapshot).
struct SearchRequest: Sendable {
    let generation: Int
    let query: TextSearch
    let entries: [ShapeID: IndexedShape]
    let scope: BoardID
    let order: [ShapeID]?
    let topology: TopologySnapshot?
    let file: CanvasFile
}

/// What it found: the results in order, their hits counted, and the order it went by (kept for the
/// next keystroke's).
struct SearchAnswer: Sendable {
    let generation: Int
    let order: [ShapeID]
    let results: [FindResult]
    let total: Int
    /// Each result's place, and the hits before each: worked out where the search ran, so the main
    /// actor only takes them.
    let places: [ShapeID: Int]
    let offsets: [Int]

    init(generation: Int, order: [ShapeID], results: [FindResult]) {
        self.generation = generation
        self.order = order
        self.results = results
        var places: [ShapeID: Int] = [:], offsets: [Int] = [], sum = 0
        places.reserveCapacity(results.count)
        offsets.reserveCapacity(results.count)
        for (i, result) in results.enumerated() {
            places[result.id] = i
            offsets.append(sum)
            sum += result.hitCount
        }
        self.places = places
        self.offsets = offsets
        total = sum
    }
}

/// A value handed from one task to another whole: taken out once, so the taker is its last holder
/// and it's freed where the taker lets go of it (Queries' `Handover`, which Find can't import).
final class Handover<Value: Sendable>: Sendable {
    private let value: OSAllocatedUnfairLock<Value?>

    init(_ value: Value) { self.value = OSAllocatedUnfairLock(initialState: value) }

    func take() -> Value? {
        value.withLock { held in
            let taken = held
            held = nil
            return taken
        }
    }
}

enum FindSearch {
    /// How many shapes it searches between asking whether it's been cancelled (a new keystroke).
    static let cancellationStride = 256

    /// Runs the search off the main actor; nil if it was cancelled.
    @concurrent
    nonisolated static func run(_ handover: Handover<SearchRequest>) async -> SearchAnswer? {
        guard let request = handover.take() else { return nil }
        return search(request, isCancelled: { Task.isCancelled })
    }

    /// The search itself, anywhere: the scope's shapes in order, each one's texts matched, those
    /// with hits kept. Nil once `isCancelled` says so.
    nonisolated static func search(_ request: SearchRequest, isCancelled: () -> Bool) -> SearchAnswer? {
        let order = request.order ?? Self.order(of: request.scope, topology: request.topology, file: request.file)
        guard !isCancelled() else { return nil }
        var results: [FindResult] = []
        let query = request.query
        for (rank, id) in order.enumerated() {
            if rank % cancellationStride == 0, rank > 0, isCancelled() { return nil }
            guard let entry = request.entries[id] else { continue }
            var count = 0
            var first: FindHit?
            for (index, text) in entry.texts.enumerated() {
                let hits = query.hits(in: text.folded, isCancelled: isCancelled)
                guard let hit = hits.first else { continue }
                if first == nil { first = FindHit(text: index, range: hit.range, isExact: hit.isExact) }
                count += hits.count
            }
            if let first {
                results.append(FindResult(id: id, board: entry.board, hitCount: count, first: first, rank: rank))
            }
        }
        guard !isCancelled() else { return nil }
        return SearchAnswer(generation: request.generation, order: order, results: results)
    }

    /// The scope's shapes, in the order Find lists and steps through them: the scope board's, in
    /// file order (what a frame holds after it), then each board under it, depth first, in file
    /// order (the board a shape owns as its owner comes in its own board's order). From Topology's
    /// walk of the file (`forEachShape(inFileOrder:)`, every board the editor can show), bucketed
    /// by board; without Topology, each board's shapes in document order.
    nonisolated static func order(of scope: BoardID, topology: TopologySnapshot?, file: CanvasFile) -> [ShapeID] {
        var buckets: [BoardID: [ShapeID]] = [:]
        if let topology {
            topology.forEachShape { record, board in buckets[board, default: []].append(record.id) }
        }
        var order: [ShapeID] = []
        var stack: [BoardID] = [scope]
        var met: Set<BoardID> = [scope]
        // Depth first: a board's shapes, then the boards its shapes own, in its order.
        while let board = stack.popLast() {
            let shapes = topology == nil ? file[board].shapes.map(\.id) : buckets[board] ?? []
            order.append(contentsOf: shapes)
            var owned: [BoardID] = []
            for id in shapes {
                let child = BoardID(owner: id)
                guard topology == nil ? file.children[id] != nil : buckets[child] != nil, met.insert(child).inserted else { continue }
                owned.append(child)
            }
            stack.append(contentsOf: owned.reversed())
        }
        return order
    }
}
