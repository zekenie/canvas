import CoreGraphics

// Containers within a board: a shape of a `ShapeContaining` kind (a frame) holds the shapes on its
// board that name it as their container (`AnyShapeRecord.container`). The document keeps who names
// whom (`members`), as the board keeps it; what the core goes by is that, less what isn't usable: a
// container kept aside, or of a kind that holds nothing here (not installed, or not
// `ShapeContaining`), holds nothing, and a shape kept aside, or without a box, is in none. These are
// nonisolated, so what reads a file off the main actor (Topology's snapshot) draws the same lines;
// the registry (`containingKinds`) and `ShapeContext` lend them with the kinds filled in.
extension CanvasDocument {
    /// The container a shape is directly in, as the core goes by it: the one it names
    /// (`AnyShapeRecord.container`), if that's on this board, of one of `kinds` (the registry's
    /// `containingKinds`) and not kept aside, and the shape itself can be in one (it isn't kept aside,
    /// and has a box). Nil for a shape on the board directly. O(1).
    public func container(of shape: AnyShapeRecord, containingKinds kinds: Set<ShapeKind>) -> ShapeID? {
        guard shape.namesContainer, let id = shape.container, let holder = self[id], kinds.contains(holder.kind), !holder.isOpaque,
              shape.box != nil else { return nil }
        return id
    }

    /// The container a shape on this board is directly in (`container(of:containingKinds:)`); nil for
    /// one on the board directly, or not on it.
    public func container(of id: ShapeID, containingKinds kinds: Set<ShapeKind>) -> ShapeID? {
        self[id].flatMap { container(of: $0, containingKinds: kinds) }
    }

    /// The containers a shape is in, the nearest first: its container, that one's, and so on up. Empty
    /// for a shape on the board directly. O(its depth).
    public func containers(of id: ShapeID, containingKinds kinds: Set<ShapeKind>) -> [ShapeID] {
        var chain: [ShapeID] = [], met: Set<ShapeID> = [id], next = container(of: id, containingKinds: kinds)
        // A board never holds a loop (reading breaks one, and nothing done in the app makes one), but
        // the walk stops at a shape it has met all the same.
        while let id = next, met.insert(id).inserted {
            chain.append(id)
            next = container(of: id, containingKinds: kinds)
        }
        return chain
    }

    /// The shapes directly in a container, back to front: those that name it, if it's a container
    /// the core goes by (`kinds`), and can be in one. Empty for any other shape. Costs what it holds.
    public func contents(of container: ShapeID, containingKinds kinds: Set<ShapeKind>) -> [ShapeID] {
        guard isContainer(container, kinds), let named = members[container] else { return [] }
        return named.compactMap { id -> Int? in
            guard let index = index(of: id), shapes[index].box != nil else { return nil }
            return index
        }.sorted().map { shapes[$0].id }
    }

    /// Whether a container holds a shape (`contents(of:containingKinds:)` isn't empty): stops at the
    /// first.
    public func hasContents(_ container: ShapeID, containingKinds kinds: Set<ShapeKind>) -> Bool {
        guard isContainer(container, kinds), let named = members[container] else { return false }
        return named.contains { self[$0]?.box != nil }
    }

    /// Every shape in a container, at any depth, back to front: what moves with it. Costs what it
    /// holds.
    public func descendants(of container: ShapeID, containingKinds kinds: Set<ShapeKind>) -> [ShapeID] {
        descendantIndices(of: container, containingKinds: kinds).map { shapes[$0].id }
    }

    /// `descendants(of:containingKinds:)`, by their indices in `shapes`, ascending.
    func descendantIndices(of container: ShapeID, containingKinds kinds: Set<ShapeKind>) -> [Int] {
        guard members[container] != nil else { return [] }
        var found: [Int] = [], queue = [container], met: Set<ShapeID> = [container], next = 0
        while next < queue.count {
            let holder = queue[next]
            next += 1
            guard isContainer(holder, kinds), let named = members[holder] else { continue }
            for id in named where met.insert(id).inserted {
                guard let index = index(of: id), shapes[index].box != nil else { continue }
                found.append(index)
                if members[id] != nil { queue.append(id) }
            }
        }
        return found.sorted()
    }

    /// Where the topmost shape a container holds, at any depth, is in `shapes`, but those at
    /// `excluded`; nil for none. What a shape joining it rises above: one pass over what it holds,
    /// nothing sorted.
    func topIndex(heldBy container: ShapeID, excluding excluded: Set<Int>, containingKinds kinds: Set<ShapeKind>) -> Int? {
        guard members[container] != nil else { return nil }
        var top: Int?, queue = [container], met: Set<ShapeID> = [container], next = 0
        while next < queue.count {
            let holder = queue[next]
            next += 1
            guard isContainer(holder, kinds), let named = members[holder] else { continue }
            for id in named where met.insert(id).inserted {
                guard let index = index(of: id), shapes[index].box != nil else { continue }
                if !excluded.contains(index), index > top ?? -1 { top = index }
                if members[id] != nil { queue.append(id) }
            }
        }
        return top
    }

    /// The shapes that name `container` as theirs, as the board keeps them, usable or not: what a
    /// deletion lets go of.
    func shapesNaming(_ container: ShapeID) -> Set<ShapeID> { members[container] ?? [] }

    /// Whether any shape on the board names a container: a board without any has nothing of
    /// containment to write (`BoardCodec`), to settle, or to walk (Topology's file order), which
    /// this tells in O(1).
    public var namesContainers: Bool { !members.isEmpty }

    private func isContainer(_ id: ShapeID, _ kinds: Set<ShapeKind>) -> Bool {
        guard let record = self[id] else { return false }
        return kinds.contains(record.kind) && !record.isOpaque
    }
}

extension ShapeContext {
    /// The container a shape is directly in, as the core goes by it
    /// (`CanvasDocument.container(of:containingKinds:)`); nil for a shape on the board directly.
    public func container(of id: ShapeID) -> ShapeID? {
        currentIndexNotesDocument()
        return storedDocument.container(of: id, containingKinds: registry.containingKinds)
    }

    /// The shapes directly in a container, back to front (`CanvasDocument.contents(of:containingKinds:)`).
    public func contents(of container: ShapeID) -> [ShapeID] {
        currentIndexNotesDocument()
        return storedDocument.contents(of: container, containingKinds: registry.containingKinds)
    }

    /// Whether a container holds anything: what a container's hit test reads (an empty frame is
    /// grabbed anywhere inside). A geometry worked out from it is worked out again on every change
    /// of the board, as one that reads `document` is.
    public func hasContents(_ container: ShapeID) -> Bool {
        currentIndexNotesDocument()
        return storedDocument.hasContents(container, containingKinds: registry.containingKinds)
    }
}

extension Registry {
    /// Whether a shape is a container the core goes by: of a `ShapeContaining` kind, not kept aside.
    public func isContainer(_ shape: AnyShapeRecord) -> Bool { containingKinds.contains(shape.kind) && !shape.isOpaque }

    /// The container a shape is directly in, in `document`, as the core goes by it
    /// (`CanvasDocument.container(of:containingKinds:)`).
    public func container(of shape: AnyShapeRecord, in document: CanvasDocument) -> ShapeID? {
        document.container(of: shape, containingKinds: containingKinds)
    }

    /// Whether a shape can't change, in `document`: a plugin's rule says so of it (`isReadOnly(_:)`),
    /// or of a container it's in, at any depth (everything in a locked frame is locked too). What the
    /// core goes by, and what a view that shows the shape asks (its handles, its panel): the rules
    /// alone are for what reads one record by itself. O(the shape's depth).
    public func isReadOnly(_ shape: AnyShapeRecord, in document: CanvasDocument) -> Bool {
        guard hasReadOnlyRules else { return false }
        return isReadOnly(shape) || isInsideReadOnlyContainer(shape, in: document)
    }

    /// Whether a container a shape is in, at any depth, is read-only by a plugin's rule.
    func isInsideReadOnlyContainer(_ shape: AnyShapeRecord, in document: CanvasDocument) -> Bool {
        guard hasReadOnlyRules, shape.namesContainer else { return false }
        return document.containers(of: shape.id, containingKinds: containingKinds).contains { id in
            document[id].map(isReadOnly) ?? false
        }
    }
}
