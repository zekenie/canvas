import CoreGraphics

/// What a step did to a board, shape by shape: each touched shape's whole record before and after
/// (nil: it wasn't there), its stacking key, metadata, added and kept values included, opaque (kept
/// aside) or not. Undo puts the `before` records back (`inverted`), and redo the `after` ones, with
/// `CanvasDocument.apply`.
///
/// It's the one type that holds a change's before and after, so what builds on them (subboards'
/// steps, an agent's change, a change from another copy of the board) grows here: a step will name
/// the board it was on, and the whole boards it added or removed.
public struct DocumentDelta: Equatable, Sendable {
    /// One shape's record before and after. Never both nil, and never equal.
    public struct Change: Equatable, Sendable {
        public let before: AnyShapeRecord?
        public let after: AnyShapeRecord?

        public init(before: AnyShapeRecord?, after: AnyShapeRecord?) {
            self.before = before
            self.after = after
        }
    }

    public private(set) var changes: [ShapeID: Change]

    /// Changes whose records are equal before and after are left out.
    public init(_ changes: [ShapeID: Change] = [:]) {
        self.changes = changes.filter { $0.value.before != $0.value.after }
    }

    public var isEmpty: Bool { changes.isEmpty }
    public var shapeIDs: Set<ShapeID> { Set(changes.keys) }

    /// The same change the other way: each shape's `after` back to its `before`.
    public var inverted: DocumentDelta {
        DocumentDelta(changes.mapValues { Change(before: $0.after, after: $0.before) })
    }

    /// Collects a step as its commits happen: each shape's record from before the first commit that
    /// touched it (constant time per shape a commit names), then, once the step is over, each one's
    /// record as it ends (`delta(now:)`), leaving out those that end where they began. A shape added
    /// and changed is added; added and deleted, not there; changed and changed back, not there;
    /// changed and deleted, deleted from what it first was.
    public struct Builder: Sendable {
        /// Each touched shape's first record before, nil if it wasn't there.
        private var before: [ShapeID: AnyShapeRecord?] = [:]

        public init() {}

        /// A commit is about to take the document from `old` to what `changes` says: notes the
        /// record of each shape it names that no earlier commit did.
        public mutating func willCommit(_ changes: ChangeSet, from old: CanvasDocument) {
            for id in changes.shapeIDs where before.index(forKey: id) == nil { before[id] = .some(old[id]) }
        }

        /// Whether any commit has touched a shape.
        public var isHolding: Bool { !before.isEmpty }

        /// Whether any touched shape's record in `now` differs from its first: whether `delta(now:)`
        /// would have a change. Stops at the first.
        public func hasChanges(now: CanvasDocument) -> Bool {
            before.contains { id, first in first != now[id] }
        }

        /// Every touched shape's first record and its record in `now`, those that differ.
        public func delta(now: CanvasDocument) -> DocumentDelta {
            var changes: [ShapeID: Change] = [:]
            for (id, first) in before {
                let last = now[id]
                if first != last { changes[id] = Change(before: first, after: last) }
            }
            return DocumentDelta(changes)
        }
    }
}

extension ChangeSet {
    /// What applying `delta` does: shapes that come are added, those that go removed, the rest
    /// changed (props, metadata, added values or stacking key); the stack changed if a shape came,
    /// went or changed its key. A changed shape whose box moved, and nothing else, is `moved`, as a
    /// drag's commits say, so undoing or redoing a drag costs services what the drag did.
    public init(_ delta: DocumentDelta) {
        self.init()
        for (id, change) in delta.changes {
            switch (change.before, change.after) {
            case (nil, _?):
                added.insert(id)
                reordered = true
            case (_?, nil):
                removed.insert(id)
                reordered = true
            case (let before?, let after?):
                changed.insert(id)
                if before.stackingKey != after.stackingKey {
                    reordered = true
                } else if let from = before.box, let to = after.box, from.size == to.size, from.origin != to.origin {
                    var only = before
                    only.box?.origin = to.origin
                    if only == after { moved.insert(id) }
                }
            case (nil, nil):
                break
            }
        }
    }
}
