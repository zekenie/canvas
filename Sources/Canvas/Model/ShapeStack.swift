/// The shapes of a board, back to front: a random-access collection of their records, the bottom
/// shape first (`Int` positions, like an array's), kept so that a copy shares with the original
/// everything neither has changed.
///
/// The records are held in chunks of 128 and an array of the chunks, each a value Swift copies when
/// written to while another copy holds it, so a write copies the list of chunks and the one chunk it
/// reaches, never the board: a shape changed in place (a keystroke, a drag event's move) or put on top
/// costs a chunk and a short list, whatever the board holds. Where each shape is (`position(of:)`) is a
/// table kept the same way (`ShapeMap`), changed only for the shapes whose place changed. So holding the
/// board as it was before a commit (what the commit's `ChangeSet` does, and every undo step) costs the
/// chunks the commit wrote, and comparing two copies of a board (`==`) passes over the chunks they share.
///
/// Every chunk but the last holds exactly `chunkSize` records, so a position is a chunk and a place in it
/// by shifting and masking. A shape moved in the stack passes a record from chunk to chunk between where it
/// was and is (`move(from:to:as:)`); a removal, an insertion below the top and a restack of several make
/// the chunks again from the first place they change (`remove(_:)`, `replaceSubrange`), where an equal
/// number of shapes in and out stays within the chunks between. The chunks before are shared still.
public struct ShapeStack: RandomAccessCollection, Equatable, Sendable, ExpressibleByArrayLiteral {
    typealias Chunk = ContiguousArray<AnyShapeRecord>

    #if DEBUG
    /// Debug builds, the tests', chunk four records, so a few shapes cross chunks and every case of
    /// the code at the edges between them is met by the smallest board.
    static let chunkShift = 2
    #else
    static let chunkShift = 7
    #endif
    static let chunkSize = 1 << chunkShift
    static let chunkMask = chunkSize - 1

    private var chunks: [Chunk] = []
    /// Where each shape is, by id: always the number of records, each id once.
    private var positions = ShapeMap<Int>()
    public private(set) var count = 0

    public init() {}

    public init(arrayLiteral records: AnyShapeRecord...) { self.init(records) }

    /// The records, back to front. No two may share an id.
    public init<Records: Sequence>(_ records: Records) where Records.Element == AnyShapeRecord {
        var builder = Builder()
        for record in records { builder.append(record) }
        count = builder.count
        chunks = builder.finish()
        positions = ShapeMap(expecting: count)
        var place = 0
        for chunk in chunks {
            for record in chunk {
                let old = positions.updateValue(place, forKey: record.id)
                precondition(old == nil, "two shapes share an id")
                place += 1
            }
        }
    }

    // MARK: Reading

    public var startIndex: Int { 0 }
    public var endIndex: Int { count }
    public var underestimatedCount: Int { count }

    public subscript(position: Int) -> AnyShapeRecord {
        chunks[position >> Self.chunkShift][position & Self.chunkMask]
    }

    /// Where the shape with this id is; nil for none.
    func position(of id: ShapeID) -> Int? { positions[id] }

    /// The shape with this id; nil for none.
    func record(for id: ShapeID) -> AnyShapeRecord? {
        guard let place = positions[id] else { return nil }
        return self[place]
    }

    /// The records in `range`, in an array.
    func records(in range: Range<Int>) -> [AnyShapeRecord] {
        var found: [AnyShapeRecord] = []
        found.reserveCapacity(range.count)
        var place = range.lowerBound
        while place < range.upperBound {
            let chunk = chunks[place >> Self.chunkShift]
            let start = place & Self.chunkMask
            let end = Swift.min(chunk.count, start + range.upperBound - place)
            found.append(contentsOf: chunk[start..<end])
            place += end - start
        }
        return found
    }

    public struct Iterator: IteratorProtocol {
        private let chunks: [Chunk]
        private var current: Chunk
        private var chunk = 0
        private var offset = 0

        fileprivate init(_ chunks: [Chunk]) {
            self.chunks = chunks
            current = chunks.first ?? []
        }

        public mutating func next() -> AnyShapeRecord? {
            if offset < current.count {
                defer { offset += 1 }
                return current[offset]
            }
            chunk += 1
            guard chunk < chunks.count else { return nil }
            current = chunks[chunk]
            offset = 1
            return current[0]
        }
    }

    public func makeIterator() -> Iterator { Iterator(chunks) }

    /// Calls `body` with each record, back to front, read in place: a `for` loop copies each record out of the stack
    /// (an array's does too, but the compiler sees through that, and cannot through this stack's chunk by chunk), where
    /// this lends it, so a pass over many shapes that reads a few fields of each costs those.
    public func forEach(_ body: (borrowing AnyShapeRecord) throws -> Void) rethrows {
        for chunk in chunks {
            try chunk.withUnsafeBufferPointer { records in
                for index in records.indices { try body(records[index]) }
            }
        }
    }

    /// Equal when the records are, shape for shape: the chunks two copies share are passed over.
    public static func == (a: Self, b: Self) -> Bool { a.count == b.count && a.chunks == b.chunks }

    // MARK: Changing it

    /// Puts a record on top. Its id must be new.
    mutating func append(_ record: AnyShapeRecord) {
        let old = positions.updateValue(count, forKey: record.id)
        assert(old == nil, "two shapes share an id")
        if count & Self.chunkMask == 0 {
            var chunk = Chunk()
            chunk.reserveCapacity(Self.chunkSize)
            chunk.append(record)
            chunks.append(chunk)
        } else {
            chunks[chunks.count - 1].append(record)
        }
        count += 1
    }

    /// Puts `record` in the place of the shape at `place`, which has its id.
    mutating func replace(at place: Int, with record: AnyShapeRecord) {
        assert(self[place].id == record.id, "a shape in place keeps its id")
        chunks[place >> Self.chunkShift][place & Self.chunkMask] = record
    }

    /// Takes the shape at `place` out and puts `moved`, the same shape (with another key, say), in at `destination`, where
    /// it ends: the shapes between shift by one. Each chunk from one to the other is written once, a record passed on
    /// from chunk to chunk, and the table is written for the shapes that shifted.
    mutating func move(from place: Int, to destination: Int, as moved: AnyShapeRecord) {
        assert(self[place].id == moved.id, "a shape moved keeps its id")
        guard place != destination else { return replace(at: place, with: moved) }
        let source = place >> Self.chunkShift, target = destination >> Self.chunkShift
        chunks[source].remove(at: place & Self.chunkMask)
        if destination > place {
            // Each chunk after the first gives its first record to the one before.
            if target > source {
                for chunk in (source + 1)...target { chunks[chunk - 1].append(chunks[chunk].removeFirst()) }
            }
        } else if source > target {
            // Each chunk before the last gives its last record to the one after.
            for chunk in stride(from: source, to: target, by: -1) { chunks[chunk].insert(chunks[chunk - 1].removeLast(), at: 0) }
        }
        chunks[target].insert(moved, at: destination & Self.chunkMask)
        for shifted in Swift.min(place, destination)...Swift.max(place, destination) {
            positions.updateValue(shifted, forKey: chunks[shifted >> Self.chunkShift][shifted & Self.chunkMask].id)
        }
    }

    /// Moves the shapes at `block` (ascending places), in their order among themselves, to just above the shape at `anchor`
    /// (a place not in `block`), or to the bottom for nil, as `moved`, their records (with other keys, say) in the same
    /// order. The chunks from the first place a shape changes to the last are made again in one pass over them, each
    /// shape that shifted written in the table.
    mutating func move(_ block: [Int], above anchor: Int?, as moved: [AnyShapeRecord]) {
        assert(block.count == moved.count, "a record for each shape moved")
        guard let first = block.first, let last = block.last else { return }
        let low = Swift.min(first, anchor.map { $0 + 1 } ?? 0), high = Swift.max(last, anchor ?? -1)
        let firstChunk = low >> Self.chunkShift, lastChunk = high >> Self.chunkShift
        let before = chunks
        var builder = Builder()
        for offset in 0..<(low & Self.chunkMask) { builder.append(before[firstChunk][offset]) }
        var place = low
        func put(_ record: AnyShapeRecord) {
            positions.updateValue(place, forKey: record.id)
            builder.append(record)
            place += 1
        }
        // Moved to the bottom, or just above the shape before the first place that changes: first.
        if anchor.map({ $0 < low }) ?? true { for record in moved { put(record) } }
        var old = low, next = 0
        while old <= high {
            let chunk = before[old >> Self.chunkShift]
            var offset = old & Self.chunkMask
            while offset < chunk.count, old <= high {
                if next < block.count, block[next] == old {
                    next += 1
                } else {
                    put(chunk[offset])
                    if old == anchor { for record in moved { put(record) } }
                }
                offset += 1
                old += 1
            }
        }
        // The rest of the last chunk written, as it was.
        while old < count, old & Self.chunkMask != 0 {
            builder.append(before[old >> Self.chunkShift][old & Self.chunkMask])
            old += 1
        }
        chunks.replaceSubrange(firstChunk...lastChunk, with: builder.finish())
    }

    /// Takes the shapes with these ids out of the stack (those it has), the rest keeping their order. The chunks from
    /// the first shape taken are made again, each shape after it written in the table at its new place.
    mutating func remove(_ ids: Set<ShapeID>) {
        var first = count
        for id in ids { if let place = positions[id], place < first { first = place } }
        guard first < count else { return }
        for id in ids { positions.removeValue(forKey: id) }
        // A few ids are compared with each shape's, a longer list is hashed.
        let few = ids.count <= 8 ? Array(ids) : nil
        let isTaken: (ShapeID) -> Bool = { few?.contains($0) ?? ids.contains($0) }
        let before = chunks
        var builder = Builder()
        for offset in 0..<(first & Self.chunkMask) { builder.append(before[first >> Self.chunkShift][offset]) }
        var place = first
        Self.forEachRecord(in: before, from: first) { record in
            guard !isTaken(record.id) else { return }
            positions.updateValue(place, forKey: record.id)
            builder.append(record)
            place += 1
        }
        chunks.removeSubrange((first >> Self.chunkShift)...)
        chunks.append(contentsOf: builder.finish())
        count = place
    }

    /// Puts `new` in the place of the records in `range`; `departing` are the ids of those that leave the stack
    /// (the ones in `range` that `new` does not have). With as many records as the range had, the chunks between
    /// its ends are all that is written (one the range covers whole is replaced); with more or fewer, the stack from
    /// the range's start is made again.
    mutating func replaceSubrange(_ range: Range<Int>, with new: [AnyShapeRecord], departing: [ShapeID] = []) {
        let lower = range.lowerBound
        assert(lower >= 0 && range.upperBound <= count, "a range of the stack")
        for id in departing { positions.removeValue(forKey: id) }
        guard new.count != range.count else {
            var place = lower
            for record in new {
                if positions[record.id] != place { positions.updateValue(place, forKey: record.id) }
                place += 1
            }
            place = lower
            var taken = 0
            while taken < new.count {
                let chunk = place >> Self.chunkShift, offset = place & Self.chunkMask
                let written = Swift.min(chunks[chunk].count - offset, new.count - taken)
                if offset == 0 && written == chunks[chunk].count {
                    chunks[chunk] = Chunk(new[taken..<taken + written])
                } else {
                    for i in 0..<written { chunks[chunk][offset + i] = new[taken + i] }
                }
                place += written
                taken += written
            }
            return
        }
        // The chunks from the one `lower` is in are made again: the records before it in that one, the new ones,
        // then those after the range, each in its new place.
        let first = lower >> Self.chunkShift
        let before = chunks
        var builder = Builder()
        for offset in 0..<(lower & Self.chunkMask) { builder.append(before[first][offset]) }
        var place = lower
        for record in new {
            if positions[record.id] != place { positions.updateValue(place, forKey: record.id) }
            builder.append(record)
            place += 1
        }
        Self.forEachRecord(in: before, from: range.upperBound) { record in
            positions.updateValue(place, forKey: record.id)
            builder.append(record)
            place += 1
        }
        chunks.removeSubrange(first...)
        chunks.append(contentsOf: builder.finish())
        count = place
    }

    /// Every record of `chunks` from `start` on, in order.
    private static func forEachRecord(in chunks: [Chunk], from start: Int, _ body: (AnyShapeRecord) -> Void) {
        var chunk = start >> chunkShift, offset = start & chunkMask
        while chunk < chunks.count {
            let records = chunks[chunk]
            while offset < records.count {
                body(records[offset])
                offset += 1
            }
            chunk += 1
            offset = 0
        }
    }

    /// Fills chunks, one record after another.
    private struct Builder {
        private var full: [Chunk] = []
        private var chunk = Chunk()
        private(set) var count = 0

        mutating func append(_ record: AnyShapeRecord) {
            if chunk.isEmpty { chunk.reserveCapacity(ShapeStack.chunkSize) }
            chunk.append(record)
            count += 1
            if chunk.count == ShapeStack.chunkSize {
                full.append(chunk)
                chunk = Chunk()
            }
        }

        mutating func finish() -> [Chunk] {
            if !chunk.isEmpty {
                full.append(chunk)
                chunk = Chunk()
            }
            return full
        }
    }

    // MARK: What it shares

    /// What the stack is as against `old`, a stack it was made from: the ids it added, those it has with another
    /// record, those it no longer has, and whether the order of the ids is not what it was. A chunk it holds in
    /// common with `old` in the same place is passed over, being the same records in the same order, so a stack
    /// changed in a few places costs those and the list of chunks, never the stack.
    func differences(from old: ShapeStack) -> (added: Set<ShapeID>, changed: Set<ShapeID>, removed: Set<ShapeID>, reordered: Bool) {
        var added: Set<ShapeID> = [], changed: Set<ShapeID> = [], removed: Set<ShapeID> = []
        var reordered = false
        for place in 0..<Swift.max(chunks.count, old.chunks.count) {
            let now = place < chunks.count ? chunks[place] : nil, was = place < old.chunks.count ? old.chunks[place] : nil
            if let now, let was, now.withUnsafeBufferPointer({ $0.baseAddress }) == was.withUnsafeBufferPointer({ $0.baseAddress }) { continue }
            for record in now ?? [] {
                if let before = old.record(for: record.id) {
                    if before != record { changed.insert(record.id) }
                } else {
                    added.insert(record.id)
                }
            }
            for record in was ?? [] where positions[record.id] == nil { removed.insert(record.id) }
            if !reordered { reordered = !(now ?? []).lazy.map(\.id).elementsEqual((was ?? []).lazy.map(\.id)) }
        }
        return (added, changed, removed, reordered)
    }

    /// How many chunks the stack is held in.
    @_spi(Host) public var chunkCount: Int { chunks.count }

    /// How many of its chunks are the very ones `other` has in the same place (held in common, not merely
    /// equal): what a copy keeps of the stack it was made from through the writes that did not reach
    /// them. For the tests and benchmarks that hold a commit to costing what it changed.
    @_spi(Host) public func sharedChunkCount(with other: ShapeStack) -> Int {
        var shared = 0
        for (mine, theirs) in zip(chunks, other.chunks) {
            if mine.withUnsafeBufferPointer({ $0.baseAddress }) == theirs.withUnsafeBufferPointer({ $0.baseAddress }) { shared += 1 }
        }
        return shared
    }
}

extension ShapeStack: CustomStringConvertible {
    public var description: String { Array(self).description }
}
