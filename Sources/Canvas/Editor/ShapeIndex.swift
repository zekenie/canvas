import CoreGraphics
import Geometry

/// What an editor works out from its document and keeps from one frame to the next, so that a
/// frame costs what's in view and what changed, not what's on the board: each shape's geometry
/// and extent, and the paint order. Each commit's change set says what to work out again.
///
/// A shape's geometry is kept until the shape changes, or a shape its definition looked up while
/// working it out does. Definitions look shapes up through their `ShapeContext` (`shape(_:)`,
/// `geometry(of:)`, `hitTest(_:shape:)`), which tells the index as they do; reading the context's
/// whole `document`, or its camera, ties the geometry to every change of them. The paint order is
/// kept until the stack changes or an anchored shape's anchor does (`PaintOrderAnchored`).
@MainActor
final class ShapeIndex {
    struct Entry {
        let geometry: ShapeGeometry?
        /// Where the shape can draw, and be hit: its outline's bounds, its geometry's bounds and
        /// its box, together. Null when it has no geometry (a shape kept aside: nothing draws or
        /// hits it); infinite when it has no outline, so there's nothing to cull it by.
        let extent: CGRect
        let hitMargin: HitMargin
        /// The shapes its geometry looked up.
        let reads: Set<ShapeID>
    }

    /// What a geometry being worked out has looked up so far.
    private struct Reads {
        var shapes: Set<ShapeID> = []
        var document = false
        var camera = false
    }

    /// The shapes back to front, with what culling and hit testing check for each.
    struct PaintList {
        /// Indices into the document's shapes, back to front.
        var order: [Int]
        /// Where each shape is in `order`, by its index in the document.
        var positions: [Int]
        /// In `order`'s order.
        var extents: [CGRect]
        var hitMargins: [HitMargin]
        /// Each anchored shape's anchor, as `order` has it.
        var anchors: [ShapeID: ShapeID?]
    }

    /// Bumped by every commit and camera change; a context made before then goes without the index.
    private(set) var generation = 0
    private var entries: [ShapeID: Entry] = [:]
    /// For each shape, the shapes whose geometry looked it up.
    private var readers: [ShapeID: Set<ShapeID>] = [:]
    private var documentReaders: Set<ShapeID> = []
    private var cameraReaders: Set<ShapeID> = []
    /// One per geometry being worked out, innermost last.
    private var frames: [Reads] = []
    private var paintList: PaintList?
    /// Shapes whose extent in `paintList` is out of date.
    private var staleExtents: Set<ShapeID> = []

    // MARK: Lookups, as definitions make them

    func noteRead(_ id: ShapeID) {
        if !frames.isEmpty { frames[frames.count - 1].shapes.insert(id) }
    }

    func noteReadingDocument() {
        if !frames.isEmpty { frames[frames.count - 1].document = true }
    }

    func noteReadingCamera() {
        if !frames.isEmpty { frames[frames.count - 1].camera = true }
    }

    /// The shape's entry, worked out now if it isn't kept. Nil if the shape isn't there. `context`
    /// must be current (of this generation).
    func entry(for id: ShapeID, in context: ShapeContext) -> Entry? {
        noteRead(id)
        if let entry = entries[id] { return entry }
        guard let record = context.storedDocument[id] else { return nil }
        let definition = context.registry.definition(for: record.kind)
        frames.append(Reads())
        let geometry = definition?.erasedGeometry(of: record, in: context)
        let reads = frames.removeLast()
        let entry = Entry(geometry: geometry, extent: Self.extent(of: record, geometry), hitMargin: definition?.hitMargin ?? HitMargin(),
                          reads: reads.shapes)
        entries[id] = entry
        for read in reads.shapes where read != id { readers[read, default: []].insert(id) }
        if reads.document { documentReaders.insert(id) }
        if reads.camera { cameraReaders.insert(id) }
        return entry
    }

    static func extent(of record: AnyShapeRecord, _ geometry: ShapeGeometry?) -> CGRect {
        guard let geometry else { return .null }
        guard !geometry.outline.isEmpty else { return record.box ?? .infinite }
        var extent = CGRect(enclosing: geometry.outline)
        if !geometry.bounds.isNull { extent = extent.union(geometry.bounds) }
        if let box = record.box { extent = extent.union(box) }
        return extent
    }

    /// Whether a point is near enough to a shape to ask its `hitTest`: within its extent, grown by
    /// its hit margin and a view point more, for rounding.
    static func mayHit(_ point: CGPoint, extent: CGRect, margin: HitMargin, zoom: CGFloat) -> Bool {
        let reach = margin.world + (margin.view + 1) / zoom
        return point.x >= extent.minX - reach && point.x <= extent.maxX + reach
            && point.y >= extent.minY - reach && point.y <= extent.maxY + reach
    }

    // MARK: Paint order

    /// Up to date: rebuilt if the stack changed, with the extents of whatever else changed redone.
    func paintList(in context: ShapeContext) -> PaintList {
        guard paintList != nil else {
            let list = buildPaintList(in: context)
            paintList = list
            return list
        }
        if !staleExtents.isEmpty {
            let stale = staleExtents
            staleExtents = []
            for id in stale {
                guard let index = context.storedDocument.index(of: id) else { continue }
                let extent = entry(for: id, in: context)?.extent ?? .null
                paintList!.extents[paintList!.positions[index]] = extent
            }
        }
        return paintList!
    }

    /// Document order, with each anchored shape just above its anchor (anchored shapes whose
    /// anchor is missing, or anchored itself, go on top).
    private func buildPaintList(in context: ShapeContext) -> PaintList {
        let document = context.storedDocument, registry = context.registry, shapes = document.shapes
        var anchoredKinds: [ShapeKind: any PaintOrderAnchored] = [:]
        for kind in registry.kinds {
            if let anchored = registry.definition(for: kind) as? any PaintOrderAnchored { anchoredKinds[kind] = anchored }
        }
        var anchors: [ShapeID: ShapeID?] = [:]
        var isAnchored = [Bool](repeating: false, count: shapes.count)
        var anchorIDs = [ShapeID?](repeating: nil, count: shapes.count)
        if !anchoredKinds.isEmpty {
            for (i, record) in shapes.enumerated() {
                guard let anchored = anchoredKinds[record.kind] else { continue }
                let anchor = anchored.erasedPaintAnchor(of: record, in: document)
                anchors[record.id] = .some(anchor)
                isAnchored[i] = true
                anchorIDs[i] = anchor
            }
        }
        var above: [Int: [Int]] = [:]
        var plain: [Int] = []
        var top: [Int] = []
        for i in shapes.indices {
            guard isAnchored[i] else {
                plain.append(i)
                continue
            }
            // Only a plain shape that's still there can anchor another.
            if let anchor = anchorIDs[i], let j = document.index(of: anchor), !isAnchored[j] {
                above[j, default: []].append(i)
            } else {
                top.append(i)
            }
        }
        var order: [Int] = []
        order.reserveCapacity(shapes.count)
        for i in plain {
            order.append(i)
            if let anchored = above[i] { order += anchored }
        }
        order += top

        var positions = [Int](repeating: 0, count: shapes.count)
        var extents: [CGRect] = [], hitMargins: [HitMargin] = []
        extents.reserveCapacity(shapes.count)
        hitMargins.reserveCapacity(shapes.count)
        for (position, i) in order.enumerated() {
            positions[i] = position
            let entry = entry(for: shapes[i].id, in: context)
            extents.append(entry?.extent ?? .null)
            hitMargins.append(entry?.hitMargin ?? HitMargin())
        }
        staleExtents = []
        return PaintList(order: order, positions: positions, extents: extents, hitMargins: hitMargins, anchors: anchors)
    }

    // MARK: Keeping up

    /// After a commit (`document` is the new one): forgets what `changes` touched, and everything
    /// worked out from it.
    func documentDidChange(_ changes: ChangeSet, in document: CanvasDocument, registry: Registry) {
        generation += 1
        forget(changes.shapeIDs.union(documentReaders))
        guard let list = paintList else { return }
        if changes.reordered || anchorsMoved(changes.changed, from: list, in: document, registry: registry) {
            paintList = nil
            staleExtents = []
        }
    }

    func cameraDidChange() {
        generation += 1
        if !cameraReaders.isEmpty { forget(cameraReaders) }
    }

    /// Whether a changed shape's anchor isn't the one the paint order has. (An anchor follows from
    /// the shape's own props and the order of the document, so only a shape that changed, in a
    /// stack that didn't, needs asking.)
    private func anchorsMoved(_ changed: Set<ShapeID>, from list: PaintList, in document: CanvasDocument, registry: Registry) -> Bool {
        changed.contains { id in
            guard let record = document[id], let anchored = registry.definition(for: record.kind) as? any PaintOrderAnchored else { return false }
            return list.anchors[id] != .some(anchored.erasedPaintAnchor(of: record, in: document))
        }
    }

    /// Drops the entries of `ids` and of every shape whose geometry looked one of them up, however
    /// indirectly.
    private func forget(_ ids: Set<ShapeID>) {
        var queue = Array(ids)
        var forgotten: Set<ShapeID> = []
        while let id = queue.popLast() {
            guard forgotten.insert(id).inserted else { continue }
            if let entry = entries.removeValue(forKey: id) {
                for read in entry.reads where read != id {
                    readers[read]?.remove(id)
                    if readers[read]?.isEmpty == true { readers[read] = nil }
                }
                documentReaders.remove(id)
                cameraReaders.remove(id)
            }
            if let dependents = readers.removeValue(forKey: id) { queue += dependents }
        }
        if paintList != nil { staleExtents.formUnion(forgotten) }
    }
}
