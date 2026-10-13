import AppKit
import Boards
import Canvas
import FuzzyMatching
import Geometry
import Topology

/// What a query finds: the best of the catalog's shapes, ranked.
///
/// - One piece (a word, no whitespace): the titles alone, `FuzzyMatcher.rank` over the catalog's
///   keys in two linear passes, as the `@` picker's matching runs.
/// - Several pieces: the pieces go in order along a path, a group of neighbors to a name, names
///   skipped as they like, the last group in the shape's own title (`PathMatcher`). The last piece
///   (a word of the title) is matched against every title first, in the same two passes, and only
///   the shapes it matches are scored by their paths: a container's row (the best score of placing
///   the first g pieces along the chain from the root to it) is made once per query for every shape
///   under it, from its parent's row and its own name, and a shape then costs one match for each
///   group the last could be in. No shape's ancestors are ever listed to rank it; a path is built
///   only for the rows shown.
///
/// What's kept of those is the best `JumpToStyle.maxRows`, by score, then the recent pick, then the
/// catalog's order; the rows shown are put in order by score, then the fewer names skipped, the
/// shallower, the recent pick, and the file's order (a shape's position as Topology gives it).
extension JumpToState {
    /// A catalog entry a query matched, by its slot, and its score.
    private struct Found {
        let slot: Int
        let score: Int
        /// Where it is among the recent picks, the latest 0; `Int.max` if it isn't one.
        let recent: Int
    }

    /// A shape among the best, with what the rows shown are put in order by.
    private struct Ranked {
        let found: Found
        let path: [Segment]
        let match: PathMatcher.Match?
        let leafMatched: [Range<Int>]
    }

    /// A name on a path.
    private struct Segment {
        let id: ShapeID
        let title: String?
        let placeholder: String
    }

    /// The rows for `text`: for an empty query, recent picks and the shapes nearby; else the best matches.
    func search(_ text: String) -> [JumpToRow] {
        let matcher = PathMatcher(text)
        guard !matcher.isEmpty else { return emptyQueryRows() }
        let ranked = matcher.pieceCount == 1 ? rankTitles(matcher) : rankPaths(matcher)
        guard !ranked.isEmpty else { return [.empty(JumpToStyle.noMatches)] }
        return ordered(ranked).map { .match(candidate($0)) }
    }

    // MARK: One piece

    private func rankTitles(_ matcher: PathMatcher) -> [Ranked] {
        let query = FuzzyMatcher.Query(matcher.pieces[0])
        var best = BoundedHeap<Found>(capacity: JumpToStyle.maxRows, isWorse: Self.isWorse)
        query.withView { view in
            catalog.keys.withUnsafeBufferPointer { keys in
                catalog.entries.withUnsafeBufferPointer { entries in
                    FuzzyMatcher.rank(view, count: entries.count, wantSpans: false, label: { slot in
                        let entry = entries[slot]
                        return UnsafeBufferPointer(rebasing: keys[entry.start..<entry.start + entry.count])
                    }) { slot, score, _ in
                        let rank = entries[slot].recentRank
                        best.insert(Found(slot: slot, score: score, recent: rank < 0 ? .max : rank))
                    }
                }
            }
        }
        return best.sorted().map { found in
            let matched = FuzzyMatcher.match(query, in: catalog.label(at: found.slot))?.matched ?? []
            return Ranked(found: found, path: path(of: catalog.entries[found.slot].id), match: nil, leafMatched: matched)
        }
    }

    // MARK: Several pieces

    private func rankPaths(_ matcher: PathMatcher) -> [Ranked] {
        // Every title the last piece matches, in the tiers a title is matched by.
        let last = FuzzyMatcher.Query(matcher.pieces[matcher.pieceCount - 1])
        var candidates: [Int] = []
        last.withView { view in
            catalog.keys.withUnsafeBufferPointer { keys in
                catalog.entries.withUnsafeBufferPointer { entries in
                    FuzzyMatcher.rank(view, count: entries.count, wantSpans: false, label: { slot in
                        let entry = entries[slot]
                        return UnsafeBufferPointer(rebasing: keys[entry.start..<entry.start + entry.count])
                    }) { slot, _, _ in candidates.append(slot) }
                }
            }
        }
        // Each by its path, through the rows of its containers, made once for all they hold: kept by
        // the number the catalog gives each container, in an array, so a shape costs no lookup of one.
        var chains: [ShapeID: PathMatcher.Row] = [:]
        var rows = [PathMatcher.Row?](repeating: nil, count: catalog.containers.count)
        let root = matcher.rootRow
        var best = BoundedHeap<Found>(capacity: JumpToStyle.maxRows, isWorse: Self.isWorse)
        let entries = catalog.entries
        for slot in candidates {
            let entry = entries[slot]
            let row: PathMatcher.Row
            if entry.container < 0 {
                row = root
            } else if let known = rows[Int(entry.container)] {
                row = known
            } else {
                row = self.row(after: entry.parent, matcher, root: root, memo: &chains)
                rows[Int(entry.container)] = row
            }
            guard let score = matcher.leafScore(after: row, label: catalog.label(at: slot)) else { continue }
            best.insert(Found(slot: slot, score: score, recent: entry.recentRank < 0 ? .max : entry.recentRank))
        }
        return best.sorted().map { found in
            let path = path(of: catalog.entries[found.slot].id)
            let names = path.map { $0.title ?? "" } + [catalog.titles[found.slot]]
            return Ranked(found: found, path: path, match: matcher.match(path: names), leafMatched: [])
        }
    }

    /// The row after the chain from the root to `container` (nil: the root), each container's made
    /// from its parent's through its own name, and kept for the query.
    private func row(after container: ShapeID?, _ matcher: PathMatcher, root: PathMatcher.Row,
                     memo: inout [ShapeID: PathMatcher.Row]) -> PathMatcher.Row {
        guard let container else { return root }
        if let known = memo[container] { return known }
        // Up to a container whose row is known, or the root; a loop of containers (a file nothing
        // in the app makes) ends the walk too.
        var chain: [ShapeID] = [], current: ShapeID? = container, row = root
        while let id = current, chain.count < JumpToStyle.deepest {
            if let known = memo[id] {
                row = known
                break
            }
            chain.append(id)
            current = node(id).parent
        }
        for id in chain.reversed() {
            row = matcher.advance(row, through: node(id).label)
            memo[id] = row
        }
        return row
    }

    // MARK: Containers

    /// A container's name and place, read once and kept until a commit changes it.
    func node(_ id: ShapeID) -> Node {
        if let known = nodes[id] { return known }
        var node = Node(parent: nil, title: nil, label: nil, placeholder: "")
        if let record = editor.shape(inFile: id) {
            node.parent = editor.topology?.parent(of: id)
            // Called as every path calls a container (Boards' rule).
            let name = registry.containerName(of: record)
            if let title = name.title {
                node.title = title
                node.label = FuzzyMatcher.Label(title)
            }
            node.placeholder = name.placeholder
        }
        nodes[id] = node
        return node
    }

    /// The containers a shape is inside, outermost first, as the table of contents' outline and the
    /// path over the canvas have them (Topology's ancestors, the root never one); none for a shape
    /// on the root, in no container.
    private func path(of id: ShapeID) -> [Segment] {
        guard let topology = editor.topology else { return [] }
        return topology.ancestors(of: id).reversed().map { ancestor in
            let node = node(ancestor)
            return Segment(id: ancestor, title: node.title, placeholder: node.placeholder)
        }
    }

    // MARK: Ordering

    /// Lower score, then not a recent pick (or an earlier one), then later in the catalog: what keeps
    /// the best of a query's matches (the rest's order is only the best's).
    private static func isWorse(_ a: Found, _ b: Found) -> Bool {
        if a.score != b.score { return a.score < b.score }
        if a.recent != b.recent { return a.recent > b.recent }
        return a.slot > b.slot
    }

    /// The best put in the order the rows show: by score, then the fewer names skipped, the
    /// shallower, the recent pick, and the file's order.
    private func ordered(_ ranked: [Ranked]) -> [Ranked] {
        var keys: [ShapeID: [Int]?] = [:]
        // One snapshot for the whole sort, made only if a tie needs it.
        var snapshot: TopologySnapshot?
        func fileOrder(_ slot: Int) -> [Int]? {
            let id = catalog.entries[slot].id
            if let known = keys[id] { return known }
            if snapshot == nil { snapshot = editor.topology?.snapshot() }
            let key = snapshot?.fileOrderKey(of: id)
            keys[id] = key
            return key
        }
        func isBefore(_ a: Ranked, _ b: Ranked) -> Bool {
            if a.found.score != b.found.score { return a.found.score > b.found.score }
            let skipped = (a.match?.skipped ?? 0, b.match?.skipped ?? 0)
            if skipped.0 != skipped.1 { return skipped.0 < skipped.1 }
            if a.path.count != b.path.count { return a.path.count < b.path.count }
            if a.found.recent != b.found.recent { return a.found.recent < b.found.recent }
            if let x = fileOrder(a.found.slot), let y = fileOrder(b.found.slot), x != y { return x.lexicographicallyPrecedes(y) }
            return a.found.slot < b.found.slot
        }
        return ranked.sorted(by: isBefore)
    }

    // MARK: Rows

    private func candidate(_ ranked: Ranked) -> JumpToCandidate {
        let entry = catalog.entries[ranked.found.slot]
        let title = catalog.titles[ranked.found.slot]
        var titleMatched = ranked.leafMatched
        var segments = ranked.path.map { JumpToSegment(text: $0.title ?? $0.placeholder, isPlaceholder: $0.title == nil) }
        if let match = ranked.match {
            titleMatched = match.matched.last ?? []
            for index in segments.indices where segments[index].isPlaceholder == false { segments[index].matched = match.matched[index] }
        }
        let (name, symbol, tint) = appearance(of: entry.id)
        return JumpToCandidate(id: entry.id, title: title, titleMatched: titleMatched, path: segments, kindName: name, systemImage: symbol, tint: tint)
    }

    /// What a shape's kind is called, its symbol and the tint it shows in: its kind's label's
    /// (`registry.label(of:)`), the one color a kind has in the table of contents and the `@` picker
    /// too; a dashed square for a kind with no symbol, untinted for one with no tint.
    private func appearance(of id: ShapeID) -> (name: String, symbol: String, tint: NSColor?) {
        guard let record = editor.shape(inFile: id) else { return ("", "square.dashed", nil) }
        let label = registry.label(of: record.kind)
        return (label.name, label.systemImage ?? "square.dashed", label.tint)
    }

    // MARK: The empty query

    /// Recent picks (up to `recentShown`, those still in the catalog), then the shapes in view on
    /// the board shown nearest the view's center (up to `nearbyShown`).
    private func emptyQueryRows() -> [JumpToRow] {
        var rows: [JumpToRow] = []
        let recent = Array(recent.lazy.filter { self.catalog.contains($0) }.prefix(JumpToStyle.recentShown))
        if !recent.isEmpty {
            rows.append(.header(JumpToStyle.recentHeader))
            rows += recent.map { .match(candidate(of: $0)) }
        }
        let nearby = nearbyShapes(excluding: Set(recent))
        if !nearby.isEmpty {
            rows.append(.header(JumpToStyle.nearbyHeader))
            rows += nearby.map { .match(candidate(of: $0)) }
        }
        return rows.isEmpty ? [.empty(JumpToStyle.nothingToJumpTo)] : rows
    }

    /// A row for a shape in the catalog, nothing matched.
    private func candidate(of id: ShapeID) -> JumpToCandidate {
        let slot = catalog.slot(of: id)!
        return candidate(Ranked(found: Found(slot: slot, score: 0, recent: .max), path: path(of: id), match: nil, leafMatched: []))
    }

    /// The shapes of the catalog in view on the board shown (where the camera is headed) nearest the
    /// middle of what the host leaves clear of the view, nearest first: looked for in a square around it, grown until it
    /// holds enough, so a board of thousands costs what's around its middle, not the board.
    private func nearbyShapes(excluding taken: Set<ShapeID>) -> [ShapeID] {
        let clear = editor.unobscuredViewport
        guard !clear.isEmpty else { return [] }
        let view = editor.cameraTarget.toWorld(clear)
        let center = CGPoint(x: view.midX, y: view.midY)
        let wanted = JumpToStyle.nearbyShown
        let shapes = editor.shapeContext
        func nearest(in square: CGRect) -> [(id: ShapeID, distance: CGFloat)] {
            var found: [(id: ShapeID, distance: CGFloat)] = []
            for record in editor.paintOrder(in: square) where !taken.contains(record.id) && catalog.contains(record.id) {
                guard let bounds = shapes.geometry(of: record.id)?.bounds else { continue }
                found.append((record.id, hypot(bounds.midX - center.x, bounds.midY - center.y)))
            }
            found.sort { $0.distance < $1.distance }
            return Array(found.prefix(wanted))
        }
        var half = JumpToStyle.nearbySearch
        var found: [(id: ShapeID, distance: CGFloat)] = []
        for _ in 0..<JumpToStyle.nearbySearchSteps {
            let square = CGRect(x: center.x - half, y: center.y - half, width: 2 * half, height: 2 * half).intersection(view)
            found = nearest(in: square)
            // Nothing nearer than the farthest found can be outside a square it fills.
            if found.count == wanted, found[wanted - 1].distance <= half { break }
            if square == view { break }
            half *= 4
        }
        return found.map(\.id)
    }
}
