import Canvas
import Draw
import Foundation

/// Draw's groups, in Grouping: `canvas draw`'s `group "A" and "B"` and `ungroup "A"`. Draw resolves the shapes a statement names
/// and hands them, with the transaction its run applies everything in, to what these two write.
///
/// - `group` makes exactly the shapes named one group of their own, flat: each leaves the groups it was in and holds just the new
///   one (a new id, as the app's Group makes), so the others in those groups stay a group only if they are two parts or more
///   (`BoardGroups` works that out, from the paths shapes hold). Shapes that already are one group that counts, alone, are
///   left as they are: nothing is written.
/// - `ungroup` leaves each shape named in no group (its path cleared); one in no group that counts, whatever stale id it holds,
///   is left alone.
///
/// Both read the groups as the transaction has them, after the shapes and edges the script draws, so a shape the same script
/// draws can be named; a write to a read-only shape is refused by the transaction, and Draw says so.
public struct GroupDrawPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { "group-draw" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.drawGroups(group: { ids, transaction in DrawnGroups.group(ids, in: &transaction) },
                             ungroup: { ids, transaction in DrawnGroups.ungroup(ids, in: &transaction) })
    }
}

/// What the two statements write, over the transaction.
@MainActor
enum DrawnGroups {
    /// The groups on the transaction's board, as the paths its shapes hold now make them.
    static func groups(in transaction: Transaction) -> BoardGroups {
        BoardGroups(transaction.document.shapes.compactMap { record in
            guard let path = record[GroupsProperty.self], !path.isEmpty else { return nil }
            return (id: record.id, path: path)
        })
    }

    /// Puts `ids` in one group of their own. False, writing nothing, for fewer than two shapes or shapes that already are one group.
    static func group(_ ids: [ShapeID], in transaction: inout Transaction) -> Bool {
        let ids = unique(ids)
        guard let path = groups(in: transaction).path(forGrouping: ids, as: UUID().uuidString) else { return false }
        for id in ids { transaction.update(id) { $0[GroupsProperty.self] = path } }
        return true
    }

    /// Takes `ids` out of every group they are in. False, writing nothing, when none of them is in a group that counts.
    static func ungroup(_ ids: [ShapeID], in transaction: inout Transaction) -> Bool {
        let apart = groups(in: transaction).inAGroup(unique(ids))
        for id in apart { transaction.update(id) { $0[GroupsProperty.self] = nil } }
        return !apart.isEmpty
    }

    /// Each shape once, in the order given.
    private static func unique(_ ids: [ShapeID]) -> [ShapeID] {
        var seen = Set<ShapeID>()
        return ids.filter { seen.insert($0).inserted }
    }
}

extension BoardGroups {
    /// The path each of `ids` is to hold to be exactly one group of their own, flat, `group` being the new group's id: that path
    /// alone, whatever groups they were in. Nil when nothing is to be written: fewer than two shapes, or shapes that already are
    /// one group that counts, alone (each is in that group and no other, and it holds no other shape).
    func path(forGrouping ids: [ShapeID], as group: String) -> [String]? {
        guard Set(ids).count > 1, !isExactlyOneGroup(ids) else { return nil }
        return [group]
    }

    /// Whether `ids` are one group that counts and nothing else: the groups each is in are that one alone, and it holds no other
    /// shape. A stale id a shape still holds (a group that no longer counts) is no group.
    func isExactlyOneGroup(_ ids: [ShapeID]) -> Bool {
        guard let group = ids.first.flatMap({ path(of: $0).first }) else { return false }
        return ids.allSatisfy { path(of: $0) == [group] } && Set(shapes[group] ?? []) == Set(ids)
    }

    /// The shapes among `ids` that are in a group that counts, in the order given: the ones `ungroup` writes.
    func inAGroup(_ ids: [ShapeID]) -> [ShapeID] {
        ids.filter { !path(of: $0).isEmpty }
    }
}
