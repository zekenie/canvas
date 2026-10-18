import Canvas
import Selection

/// The groups on one board, as its shapes' paths say (`GroupsProperty`), and what grouping and
/// ungrouping shapes there write. A group counts while it holds two parts or more on the board, a
/// part being a shape or a group in it that counts (tldraw's group of one, or none, is gone): one
/// whose shapes were deleted, moved to another board or taken into another group down to one part
/// is no group, though a shape may still hold its id, until something writes that shape's path
/// again. Pure: made from the shapes' paths alone, so a board, a transaction, a query and a copy
/// read groups alike.
public struct BoardGroups: Sendable {
    /// Each shape in a group that counts: those groups, outermost first.
    public private(set) var paths: [ShapeID: [String]] = [:]
    /// Each group that counts: its shapes, at any depth, back to front.
    public private(set) var shapes: [String: [ShapeID]] = [:]

    /// `stored`: the board's shapes that hold a path, back to front, with it, outermost first.
    public init(_ stored: [(id: ShapeID, path: [String])]) {
        guard !stored.isEmpty else { return }
        var paths: [ShapeID: [String]] = [:], members: [String: [ShapeID]] = [:], order: [String] = []
        for (id, path) in stored {
            var seen = Set<String>()
            let path = path.filter { seen.insert($0).inserted }
            guard !path.isEmpty else { continue }
            paths[id] = path
            for group in path {
                if members[group] == nil { order.append(group) }
                members[group, default: []].append(id)
            }
        }
        // Each pass drops the groups of fewer than two parts, as the groups left count them; a group
        // dropped makes its shapes parts of the group around it, so the next pass looks again.
        var counting = Set(order)
        var changed = true
        while changed {
            changed = false
            for group in order where counting.contains(group) {
                var parts = Set<Part>()
                for id in members[group] ?? [] {
                    let path = paths[id] ?? []
                    let below = path.firstIndex(of: group).map { path[($0 + 1)...] } ?? []
                    parts.insert(below.first(where: counting.contains).map(Part.group) ?? .shape(id))
                    if parts.count > 1 { break }
                }
                if parts.count < 2 {
                    counting.remove(group)
                    changed = true
                }
            }
        }
        for (id, path) in paths {
            let kept = path.filter(counting.contains)
            if !kept.isEmpty { self.paths[id] = kept }
        }
        for group in order where counting.contains(group) { shapes[group] = members[group] }
    }

    /// What a group holds directly: a shape, or a group in it.
    private enum Part: Hashable {
        case shape(ShapeID)
        case group(String)
    }

    /// The groups a shape is in that count, outermost first; none for a shape in none.
    public func path(of id: ShapeID) -> [String] { paths[id] ?? [] }

    /// What grouping `ids` writes: a new group, `group`, inside the groups they are all in (less
    /// those they hold whole), holding each of them with the groups past those it holds whole (a
    /// group they hold part of, they leave). The new path of each of them; nil when they're fewer
    /// than two parts there (a shape, or a group they hold whole), as tldraw groups two or more.
    public func grouping(_ ids: [ShapeID], as group: String) -> [ShapeID: [String]]? {
        guard let level = level(of: ids) else { return nil }
        var written: [ShapeID: [String]] = [:], parts = Set<Part>()
        for (id, kept) in level.below {
            parts.insert(kept.first.map(Part.group) ?? .shape(id))
            written[id] = level.inside + [group] + kept
        }
        return parts.count > 1 ? written : nil
    }

    /// What ungrouping `ids` writes: the outermost groups they hold whole, inside the groups they are
    /// all in, taken apart (tldraw's ungroup: one level), each of their shapes left in the rest. The
    /// new path of each shape of those groups; nil when they hold no group whole.
    public func ungrouping(_ ids: [ShapeID]) -> [ShapeID: [String]]? {
        guard let level = level(of: ids) else { return nil }
        let apart = Set(level.below.compactMap(\.kept.first))
        guard !apart.isEmpty else { return nil }
        var written: [ShapeID: [String]] = [:]
        for group in apart {
            for id in shapes[group] ?? [] { written[id] = path(of: id).filter { $0 != group } }
        }
        return written
    }

    /// Whether `ids` can be grouped: they're two parts or more.
    public func canGroup(_ ids: [ShapeID]) -> Bool { grouping(ids, as: "") != nil }

    /// Whether `ids` can be ungrouped: they hold a group whole.
    public func canUngroup(_ ids: [ShapeID]) -> Bool {
        level(of: ids)?.below.contains { !$0.kept.isEmpty } ?? false
    }

    /// Where `ids` sit: `inside`, the groups they are all in, outermost first, less those they hold
    /// whole (as the selection is inside them: Selection's focus); and for each of them, the groups
    /// past those it is in from the first it holds whole (`kept`: none when it holds none). Nil for
    /// none.
    private func level(of ids: [ShapeID]) -> (inside: [String], below: [(id: ShapeID, kept: [String])])? {
        var seen = Set<ShapeID>()
        let ids = ids.filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { return nil }
        func isWhole(_ group: String) -> Bool { (shapes[group] ?? []).allSatisfy(seen.contains) }
        let inside = ids.lazy.map(path(of:)).groupsInside(holdsWhole: isWhole)
        let below = ids.map { id -> (id: ShapeID, kept: [String]) in
            let past = path(of: id).dropFirst(inside.count)
            return (id, past.firstIndex(where: isWhole).map { Array(past[$0...]) } ?? [])
        }
        return (inside, below)
    }

    /// The paths copies of shapes hold (`paths`: each copy's, as its original held it, by the copy's
    /// id): each group two or more of them share, under a new id (`mint`), shared by those copies;
    /// one that only one of them holds, gone. So copies of a group are a group of their own, and a
    /// copy of a part of one is in none of it.
    public static func copied(_ paths: [ShapeID: [String]], mint: () -> String) -> [ShapeID: [String]] {
        var holders: [String: Int] = [:]
        for path in paths.values { for group in Set(path) { holders[group, default: 0] += 1 } }
        var minted: [String: String] = [:]
        for (group, count) in holders.sorted(by: { $0.key < $1.key }) where count > 1 { minted[group] = mint() }
        return paths.mapValues { path in
            var seen = Set<String>()
            return path.compactMap { minted[$0] }.filter { seen.insert($0).inserted }
        }
    }
}
