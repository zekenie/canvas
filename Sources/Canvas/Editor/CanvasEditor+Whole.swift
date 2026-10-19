// Work that must happen whole or not at all: a grouping, a recolor across the file, a move, a turn,
// a paste, a relationship drawn. The rule is the core's, so no plugin keeps a refusal error of its own.
extension CanvasEditor {
    /// One transaction that commits only whole: when its body returns and the transaction refused
    /// nothing (`transaction.refusedShapes`: a read-only shape left as it was, a read-only container
    /// that wouldn't take a shape as it settled, a read-only board that took nothing). Otherwise
    /// nothing commits and no step opens (what there was to redo stays), as when the body throws, and
    /// the refused shapes shake (`refuseChanges(to:)`), with those a thrown `Transaction.Refused`
    /// names (a body gives up for a reason of its own with it). A body that throws anything else gives
    /// up with nothing heard refused, as `transact` hears none. Given `shaking`, exactly those shake,
    /// whatever stopped it (the note whose row asked; none at all). The body's value, or nil when
    /// nothing committed. `name` and `coalescing` are `transact`'s.
    @discardableResult
    public func transactWhole<T>(_ name: String? = nil, coalescing key: AnyHashable? = nil, shaking: Set<ShapeID>? = nil,
                                 _ body: (inout Transaction) throws -> T) -> T? {
        var refused: Set<ShapeID> = []
        do {
            return try transact(name, coalescing: key) { transaction in
                defer { refused = transaction.refusedShapes }
                let result = try body(&transaction)
                guard transaction.refusedShapes.isEmpty else { throw Transaction.Refused() }
                return result
            }
        } catch {
            let refusal = error as? Transaction.Refused
            let shaken = shaking ?? refusal.map { refused.union($0.shapes) } ?? []
            if !shaken.isEmpty { refuseChanges(to: shaken) }
            return nil
        }
    }
}

extension Transaction {
    /// Thrown out of `editor.transactWhole` to give the whole up for a reason of the body's own (a
    /// read-only shape it found before changing it, a stand-in that won't take a note): nothing
    /// commits, and `shapes` shake with what the transaction refused.
    public struct Refused: Error {
        public let shapes: Set<ShapeID>

        public init(_ shapes: Set<ShapeID> = []) {
            self.shapes = shapes
        }
    }
}
