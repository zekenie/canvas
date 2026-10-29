import CoreGraphics
import Geometry

/// What an editor works out from its document and keeps from one frame to the next, so that a
/// frame costs what's in view and what changed, not what's on the board: each shape's geometry
/// and extent, and the paint order, with a grid over the extents (`SpatialGrid`) that finds the
/// shapes near a rect or a point without going through every one. Each commit's change set says
/// what to work out again.
///
/// A shape's geometry is kept until the shape changes, or a shape its definition looked up while
/// working it out does. Definitions look shapes up through their `ShapeContext` (`shape(_:)`,
/// `geometry(of:)`, `hitTest(_:shape:)`), which tells the index as they do; reading the context's
/// whole `document`, or its camera, ties the geometry to every change of them. The paint order is
/// kept until the stack changes or an anchored shape's anchor does (`PaintOrderAnchored`).
///
/// It also keeps what a picture of the board kept from one frame to the next (the minimap's) needs
/// in order to redraw only what changed: the bounds of every shape, and where each commit moved or
/// reshaped shapes (`damage(since:in:)`).
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
        /// How many shapes at the end of `order` are anchored with no plain shape to be above (the anchor is missing, or
        /// anchored itself), which go on top.
        var topCount: Int
        /// The index in the document of the last plain shape in `order`, which closes the shapes that have an anchor:
        /// whatever is anchored to it comes after it, so a shape added to the document with that anchor goes at the end,
        /// if none go on top. -1 with no plain shape.
        var lastPlain: Int
    }

    /// Bumped by every commit and camera change; a context made before then goes without the index.
    private(set) var generation = 0
    /// This index's own number, never another's: a damage mark names the index it was taken on, so
    /// an index made after another is freed can't take the other's marks for its own.
    let serial: Int
    private static var serials = 0
    private var entries: [ShapeID: Entry] = [:]
    /// For each shape, the shapes whose geometry looked it up.
    private var readers: [ShapeID: Set<ShapeID>] = [:]
    private var documentReaders: Set<ShapeID> = []
    private var cameraReaders: Set<ShapeID> = []
    /// One per geometry being worked out, innermost last.
    private var frames: [Reads] = []
    private var paintList: PaintList?
    /// Which cells each extent in `paintList` covers, made when a search first needs it and kept up with the extents
    /// from then on; nil while there is none, with a short list or after the list was built again.
    private var grid: SpatialGrid?
    /// The greatest hit margin any kind of the registry has, in each measure (`greatestMargin(in:)`).
    private var kindsGreatestMargin: HitMargin?
    /// Shapes whose extent in `paintList` is out of date.
    private var staleExtents: Set<ShapeID> = []
    /// The union of `paintList`'s extents, but the null and infinite ones; nil when it has to be
    /// worked out again (an extent that held an edge moved in, or the list was rebuilt).
    private var knownBounds: CGRect?

    /// Where a commit (or a camera change) moved or reshaped shapes: one record for each that did,
    /// oldest first.
    private struct Damage {
        let generation: Int
        /// Where the shapes it touched were: the extents they had before it.
        let before: CGRect
        /// The shapes it touched, which are wherever their extents are now as well.
        let ids: Set<ShapeID>
    }
    /// A slice, so forgetting the oldest record doesn't move the rest.
    private var damageLog: ArraySlice<Damage> = []
    /// How many shapes the log's records name, in all.
    private var damageLogNamed = 0
    /// The log answers for any generation from this one on; for an earlier one it no longer
    /// knows, so the damage since then is everywhere.
    private var damageFloor = 0
    /// How many records the log keeps, and how many shapes they may name in all, before it forgets
    /// its oldest. A picture on screen catches up every frame, which takes a record or two.
    static let damageLogLength = 512
    static let damageLogCapacity = 50_000

    init() {
        Self.serials += 1
        serial = Self.serials
    }

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
        let entry = Entry(geometry: geometry, extent: Self.extent(of: record, geometry, laidOut: context.registry.isLaidOutBox(record.kind)), hitMargin: definition?.hitMargin ?? HitMargin(),
                          reads: reads.shapes)
        entries[id] = entry
        for read in reads.shapes where read != id { readers[read, default: []].insert(id) }
        if reads.document { documentReaders.insert(id) }
        if reads.camera { cameraReaders.insert(id) }
        return entry
    }

    /// The shape's extent, as its entry has it (`entry(for:in:)`, worked out now if it isn't kept),
    /// read without copying the rest of the entry: what culling asks of every shape it might draw.
    func extent(of id: ShapeID, in context: ShapeContext) -> CGRect? {
        noteRead(id)
        if let entry = entries[id] { return entry.extent }
        return entry(for: id, in: context)?.extent
    }

    /// The bounds of the shape's geometry, nil for one with no outline (nothing drawn) or none at
    /// all, as its entry has it (`entry(for:in:)`), read without copying the entry: what a union of
    /// many shapes' bounds asks of each (`ShapeContext.bounds(of:)`, a selection's box).
    func outlineBounds(of id: ShapeID, in context: ShapeContext) -> CGRect? {
        noteRead(id)
        if let entry = entries[id] { return Self.outlineBounds(entry.geometry) }
        return entry(for: id, in: context).flatMap { Self.outlineBounds($0.geometry) }
    }

    private static func outlineBounds(_ geometry: ShapeGeometry?) -> CGRect? {
        guard let geometry, !geometry.outline.isEmpty, !geometry.bounds.isNull else { return nil }
        return geometry.bounds
    }

    /// A `LaidOutBox` shape's extent is its geometry's, which is its laid-out frame: the box it stores
    /// may be larger than that, and is not where it is.
    static func extent(of record: AnyShapeRecord, _ geometry: ShapeGeometry?, laidOut: Bool = false) -> CGRect {
        guard let geometry else { return .null }
        guard !geometry.outline.isEmpty else { return record.box ?? .infinite }
        var extent = CGRect(enclosing: geometry.outline)
        if !geometry.bounds.isNull { extent = extent.union(geometry.bounds) }
        if !laidOut, let box = record.box { extent = extent.union(box) }
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
        refresh(in: context)
        return paintList!
    }

    /// Builds the paint list if there is none, and works out again the extents of what changed, filing each in the
    /// grid, if there is one, where it now is. So many that filing each costs more than filing them all: the grid is let
    /// go, made again when a search needs it.
    private func refresh(in context: ShapeContext) {
        guard paintList != nil else {
            paintList = buildPaintList(in: context)
            grid = nil
            return
        }
        guard !staleExtents.isEmpty else { return }
        let stale = staleExtents
        staleExtents = []
        let filing = grid != nil && stale.count <= max(64, paintList!.extents.count / 8)
        for id in stale {
            guard let index = context.storedDocument.index(of: id) else { continue }
            let extent = entry(for: id, in: context)?.extent ?? .null
            let position = paintList!.positions[index]
            let old = paintList!.extents[position]
            keepBounds(from: old, to: extent)
            paintList!.extents[position] = extent
            if filing { grid?.update(position, from: old, to: extent) }
        }
        if !filing { grid = nil }
    }

    // MARK: Searching the paint list

    /// How many shapes a list is short enough to go through every one of, without a grid.
    static let indexedFrom = 64
    /// How many found at once are put in order by sorting them, and not by marking each in a bitmap of the list.
    static let sortedUpTo = 96

    /// The paint positions of the shapes whose extent touches `rect`, in paint order: exactly those `CGRect.touches` finds
    /// by going through every extent, found in the cells `rect` covers when it covers few enough, so it costs the cells and
    /// what's in them.
    func positions(touching rect: CGRect, in context: ShapeContext) -> [Int] {
        refresh(in: context)
        let count = paintList!.extents.count
        if let grid = currentGrid(), let block = grid.block(of: rect, most: Swift.max(count / 4, 16)) {
            var found: [Int32] = []
            let complete = paintList!.extents.withUnsafeBufferPointer { extents in
                grid.gather(block, touching: rect, extents: extents, into: &found, most: count / 4)
            }
            if complete { return Self.inOrder(found, listCount: count) }
        }
        var positions: [Int] = []
        for (position, extent) in paintList!.extents.enumerated() where extent.touches(rect) { positions.append(position) }
        return positions
    }

    /// The paint positions of the shapes a point may hit (`mayHit`, by their own margins), front to back.
    func positions(mayHit point: CGPoint, zoom: CGFloat, in context: ShapeContext) -> [Int] {
        refresh(in: context)
        let count = paintList!.extents.count
        if let grid = currentGrid() {
            let margin = greatestMargin(in: context.registry), reach = margin.world + (margin.view + 1) / zoom
            // A cell more all round than the farthest reach, against rounding.
            let around = CGRect(x: point.x - reach, y: point.y - reach, width: reach * 2, height: reach * 2)
            if let block = grid.block(of: around, margin: 1, most: Swift.max(count / 4, 16)) {
                var found: [Int32] = []
                let complete = paintList!.extents.withUnsafeBufferPointer { extents in
                    grid.gather(block, touching: nil, extents: extents, into: &found, most: count / 4)
                }
                if complete {
                    found.sort(by: >)
                    var positions: [Int] = []
                    var previous: Int32 = -1
                    for position in found where position != previous {
                        previous = position
                        let place = Int(position)
                        if Self.mayHit(point, extent: paintList!.extents[place], margin: paintList!.hitMargins[place], zoom: zoom) { positions.append(place) }
                    }
                    return positions
                }
            }
        }
        var positions: [Int] = []
        for position in paintList!.extents.indices.reversed()
        where Self.mayHit(point, extent: paintList!.extents[position], margin: paintList!.hitMargins[position], zoom: zoom) {
            positions.append(position)
        }
        return positions
    }

    /// How far past its extent a shape can be hit, at the most: the greatest of the hit margins the registry's kinds declare, in
    /// each of the two measures, so a search for a point reaches as far as the shape that reaches farthest, found or not.
    private func greatestMargin(in registry: Registry) -> HitMargin {
        if let kindsGreatestMargin { return kindsGreatestMargin }
        var greatest = HitMargin()
        for kind in registry.kinds {
            if let margin = registry.definition(for: kind)?.hitMargin { greatest = greatest.greatest(with: margin) }
        }
        kindsGreatestMargin = greatest
        return greatest
    }

    /// The indices in the document of the shapes a point may hit, the front-most first in the document's order (that is,
    /// the highest index first): the same shapes `positions(mayHit:zoom:in:)` finds.
    func documentIndices(mayHit point: CGPoint, zoom: CGFloat, in context: ShapeContext) -> [Int] {
        let positions = positions(mayHit: point, zoom: zoom, in: context)
        var indices = positions.map { paintList!.order[$0] }
        indices.sort(by: >)
        return indices
    }

    /// The grid over the paint list's extents, made now if there is none (or the one there is has fallen behind the board);
    /// nil for a list too short to need one.
    private func currentGrid() -> SpatialGrid? {
        guard let extents = paintList?.extents, extents.count >= Self.indexedFrom, !scansEveryExtent else { return nil }
        if let grid, !grid.isStale { return grid.wide.count <= extents.count / 8 ? grid : nil }
        let made = SpatialGrid(extents: extents)
        grid = made
        #if DEBUG
        gridsMade += 1
        #endif
        // Most shapes on the short list every search reads: going through every extent is no dearer.
        return made.wide.count <= extents.count / 8 ? made : nil
    }

    /// Positions found in cells, some more than once, in paint order, each once.
    private static func inOrder(_ found: [Int32], listCount count: Int) -> [Int] {
        guard found.count > sortedUpTo else {
            var sorted = found
            sorted.sort()
            var positions: [Int] = []
            positions.reserveCapacity(sorted.count)
            var previous: Int32 = -1
            for position in sorted where position != previous {
                previous = position
                positions.append(Int(position))
            }
            return positions
        }
        // Many: marked in a bitmap of the list, whose words are read in order.
        var bits = [UInt64](repeating: 0, count: (count + 63) >> 6)
        for position in found { bits[Int(position) >> 6] |= 1 << UInt64(position & 63) }
        var positions: [Int] = []
        positions.reserveCapacity(found.count)
        for (word, marked) in bits.enumerated() where marked != 0 {
            var marked = marked
            while marked != 0 {
                positions.append(word << 6 + marked.trailingZeroBitCount)
                marked &= marked - 1
            }
        }
        return positions
    }

    /// Whether searches go through every extent instead of looking in cells: what tests compare them against.
    var scansEveryExtent = false

    #if DEBUG
    /// How many grids and paint lists have been made (debug builds), for tests of when they are.
    private(set) var gridsMade = 0
    private(set) var paintListsBuilt = 0
    #endif

    // MARK: Bounds

    /// The union of every shape's extent, in world units: where all of the board is. Shapes that
    /// could be anywhere (no outline, and no box) and shapes kept aside don't count; null when that's
    /// all there is.
    func bounds(in context: ShapeContext) -> CGRect {
        let list = paintList(in: context)
        if let knownBounds { return knownBounds }
        var bounds = CGRect.null
        for extent in list.extents where Self.isBounded(extent) { bounds = bounds.union(extent) }
        knownBounds = bounds
        return bounds
    }

    /// Keeps `knownBounds` as one extent changes: they take in the new extent, unless the old one
    /// held one of their edges and the new one no longer reaches it, when they may shrink, and are
    /// worked out again when next asked. (So dragging a shape out past the edge costs nothing.)
    private func keepBounds(from old: CGRect, to new: CGRect) {
        guard let bounds = knownBounds else { return }
        if Self.isBounded(old) {
            let reaches = Self.isBounded(new)
            if (old.minX <= bounds.minX && !(reaches && new.minX <= old.minX))
                || (old.minY <= bounds.minY && !(reaches && new.minY <= old.minY))
                || (old.maxX >= bounds.maxX && !(reaches && new.maxX >= old.maxX))
                || (old.maxY >= bounds.maxY && !(reaches && new.maxY >= old.maxY)) {
                knownBounds = nil
                return
            }
        }
        if Self.isBounded(new) { knownBounds = bounds.union(new) }
    }

    private static func isBounded(_ extent: CGRect) -> Bool { !extent.isNull && !extent.isInfinite }

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
        knownBounds = nil
        #if DEBUG
        paintListsBuilt += 1
        #endif
        return PaintList(order: order, positions: positions, extents: extents, hitMargins: hitMargins, anchors: anchors,
                         topCount: top.count, lastPlain: plain.last ?? -1)
    }

    // MARK: Keeping up

    /// After a commit (`document` is the new one): forgets what `changes` touched, and everything
    /// worked out from it, and notes where those shapes were.
    func documentDidChange(_ changes: ChangeSet, in document: CanvasDocument, registry: Registry) {
        generation += 1
        let (touched, before) = forget(changes.shapeIDs.union(documentReaders))
        noteDamage(before: before, ids: touched)
        // No copy of the list is held while it's added to: its arrays would be copied, whole, to be changed.
        guard paintList != nil else { return }
        if anchorsMoved(changes.changed, in: document, registry: registry)
            || changes.reordered && !appendAdded(changes, in: document, registry: registry) {
            paintList = nil
            grid = nil
            staleExtents = []
        }
    }

    /// Puts the shapes a commit added at the end of the paint list, if that's where they belong and nothing else in
    /// the order changed, instead of building the list again: the commit added shapes at the top of the stack, none
    /// went, and none that stayed moved in it. Each is a plain shape, which goes last when no anchored shape is on top, or
    /// anchored to the last plain shape, just above everything else anchored to it, which is last too. Their extents are
    /// worked out when next asked for (they are stale), as any shape's the commit touched. False, with the list as it was,
    /// when it has to be built again: shapes came in elsewhere in the stack, shapes went, an undo or a redo or a shape from
    /// another board brought them (anything might refer to a shape it brings back: an arrow bound to it is painted above it
    /// then), or one is anchored to a shape that is not the last plain one, or something is on top.
    private func appendAdded(_ changes: ChangeSet, in document: CanvasDocument, registry: Registry) -> Bool {
        guard !changes.added.isEmpty, changes.removed.isEmpty, !changes.replacedDocument, !changes.restoredStep,
              changes.priors.holdsRecords, let old = paintList?.order.count, document.shapes.count == old + changes.added.count,
              paintList?.topCount == 0 else { return false }
        for id in changes.changed {
            guard let now = document[id], let before = changes.before(id), before.stackingKey == now.stackingKey else { return false }
        }
        var lastPlain = paintList!.lastPlain
        var anchors: [ShapeID: ShapeID] = [:]
        for index in old..<document.shapes.count {
            let record = document.shapes[index]
            guard changes.added.contains(record.id), changes.before(record.id) == nil else { return false }
            if let anchored = registry.definition(for: record.kind) as? any PaintOrderAnchored {
                guard let anchor = anchored.erasedPaintAnchor(of: record, in: document), document.index(of: anchor) == lastPlain else { return false }
                anchors[record.id] = anchor
            } else {
                lastPlain = index
            }
        }
        for index in old..<document.shapes.count {
            let record = document.shapes[index]
            let margin = registry.definition(for: record.kind)?.hitMargin ?? HitMargin()
            paintList!.positions.append(paintList!.order.count)
            paintList!.order.append(index)
            // Not known yet: it's stale, and is worked out and filed when next asked.
            paintList!.extents.append(.null)
            paintList!.hitMargins.append(margin)
            if let anchor = anchors[record.id] { paintList!.anchors[record.id] = .some(anchor) }
            grid?.addPosition()
        }
        paintList!.lastPlain = lastPlain
        return true
    }

    /// Shapes whose geometry reads something no commit changed (`editor.shapesDidChangeLayout`): the
    /// entries kept for them, and for shapes that looked them up, are let go, and where they were is
    /// noted as a commit's damage is. Shapes with no entry kept have nothing to forget.
    func layoutDidChange(_ ids: Set<ShapeID>) {
        let known = ids.filter { entries[$0] != nil }
        guard !known.isEmpty else { return }
        generation += 1
        let (touched, before) = forget(known)
        noteDamage(before: before, ids: touched)
    }

    /// Whether any geometry kept was worked out from the camera, which a pan or a zoom then works out again.
    var readsCamera: Bool { !cameraReaders.isEmpty }

    func cameraDidChange() {
        generation += 1
        guard !cameraReaders.isEmpty else { return }
        let (touched, before) = forget(cameraReaders)
        noteDamage(before: before, ids: touched)
    }

    // MARK: Damage

    /// Now, for `damage(since:in:)`. Works out every extent that's out of date first, so that what a
    /// commit after this forgets, it knows where it was.
    func mark(in context: ShapeContext) -> DamageMark {
        _ = paintList(in: context)
        return DamageMark(index: serial, generation: generation)
    }

    /// Whether the mark was taken on this index.
    func isCurrent(_ mark: DamageMark) -> Bool { mark.index == serial }

    /// Where shapes may be other than they were at `mark`, in world units: wherever the shapes a
    /// commit since then touched were before it, and wherever they are now, with those of every
    /// shape whose geometry followed theirs (an arrow, its ends' shapes) or the camera. Not the paint
    /// order: a restack names the shapes it moved in the stack, but not a shape it carried along
    /// with its anchor. Null when nothing moved; infinite when anything may have, since the log
    /// doesn't reach back that far, a shape that could be anywhere changed, or the mark is another
    /// index's (another board's).
    func damage(since mark: DamageMark, in context: ShapeContext) -> CGRect {
        guard isCurrent(mark), mark.generation >= damageFloor, mark.generation <= generation else { return .infinite }
        var damage = CGRect.null
        var ids: Set<ShapeID> = []
        for record in damageLog.reversed() {
            guard record.generation > mark.generation else { break }
            damage = damage.union(record.before)
            ids.formUnion(record.ids)
        }
        for id in ids { damage = damage.union(entry(for: id, in: context)?.extent ?? .null) }
        return damage
    }

    private func noteDamage(before: CGRect, ids: Set<ShapeID>) {
        guard !ids.isEmpty || !before.isNull else { return }
        damageLog.append(Damage(generation: generation, before: before, ids: ids))
        damageLogNamed += ids.count
        while damageLog.count > Self.damageLogLength || damageLogNamed > Self.damageLogCapacity {
            let oldest = damageLog.removeFirst()
            damageLogNamed -= oldest.ids.count
            damageFloor = oldest.generation
        }
    }

    /// Whether a changed shape's anchor isn't the one the paint order has. (An anchor follows from
    /// the shape's own props and the order of the document, so only a shape that changed, in a
    /// stack that didn't, needs asking.)
    private func anchorsMoved(_ changed: Set<ShapeID>, in document: CanvasDocument, registry: Registry) -> Bool {
        changed.contains { id in
            guard let record = document[id], let anchored = registry.definition(for: record.kind) as? any PaintOrderAnchored else { return false }
            let recorded = paintList!.anchors[id]
            return recorded != .some(anchored.erasedPaintAnchor(of: record, in: document))
        }
    }

    /// Drops the entries of `ids` and of every shape whose geometry looked one of them up, however
    /// indirectly. Returns those shapes, and the union of the extents they had.
    private func forget(_ ids: Set<ShapeID>) -> (ids: Set<ShapeID>, extents: CGRect) {
        var queue = Array(ids)
        var forgotten: Set<ShapeID> = []
        var extents = CGRect.null
        while let id = queue.popLast() {
            guard forgotten.insert(id).inserted else { continue }
            if let entry = entries.removeValue(forKey: id) {
                extents = extents.union(entry.extent)
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
        return (forgotten, extents)
    }
}

/// When a picture of a board was brought up to date (`editor.damageMark`): the moment, on the index
/// of the board shown then. A mark from another board's index, or one no longer kept, is never
/// current (`editor.isCurrent`), and the damage since it is everywhere.
@_spi(Host) public struct DamageMark: Equatable, Sendable {
    let index: Int
    let generation: Int
}

extension HitMargin {
    /// The greater of the two in each measure.
    func greatest(with other: HitMargin) -> HitMargin { HitMargin(world: Swift.max(world, other.world), view: Swift.max(view, other.view)) }
}
