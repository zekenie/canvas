import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import TestKit

// What a plugin provides to lay shapes out (`registrar.layoutInput`), asked by the editor's contexts,
// a transaction's, and by no plain one.

/// CanvasTesting's gauge: KindSchemaTests has a `Gauge` of its own.
typealias StretchGauge = CanvasTesting.Gauge

/// What a gauged shape is laid out with: the width of the box it names, provided.
let gaugedSide = LayoutInputKey<CGFloat>("gauged-side")

/// What a spacer is laid out with: set (`editor.setLayoutInput`) or, failing that, nothing.
let spacerSide = LayoutInputKey<CGFloat>("spacer-side")

/// Every call of the provider: the shape, whether the file it read was the editor's as committed, and
/// the width it found for the shape it names (nil: none there).
@MainActor final class ProvidedLog {
    var calls: [(shape: ShapeID, isCommitted: Bool, found: CGFloat?)] = []
}

/// A square at the origin, 10 units a side unless the box it names gives another: its geometry reads a
/// provided input.
struct Gauged: ShapeProps {
    static let kind: ShapeKind = "gauged"
    static let properties = Properties<Gauged> {
        Property("peg", \.peg)
    }
    var peg: ShapeID?
}

struct GaugedDefinition {}

extension GaugedDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Gauged>, in context: RenderContext) {}

    func geometry(of shape: ShapeRecord<Gauged>, in context: ShapeContext) -> ShapeGeometry {
        let side = context.layoutInput(gaugedSide, of: shape) ?? 10
        return ShapeGeometry(outline: CGRect(x: 0, y: 0, width: side, height: side).polygon)
    }
}

/// A box at its own place, 10 units a side unless a value is set for it.
struct Spacer: BoxShapeProps {
    static let kind: ShapeKind = "spacer"
    static let properties = Properties<Spacer> {
        Property("frame", \.frame).required()
        Property("label", \.label)
    }
    var frame: CGRect
    var label: String
    init(_ frame: CGRect, label: String = "") {
        self.frame = frame
        self.label = label
    }
}

extension Spacer {
    init() { self.init(.zero) }
}

struct SpacerDefinition {}

extension SpacerDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Spacer>, in context: RenderContext) {}

    func geometry(of shape: ShapeRecord<Spacer>, in context: ShapeContext) -> ShapeGeometry {
        let side = context.layoutInput(spacerSide, of: shape) ?? 10
        return ShapeGeometry(outline: CGRect(origin: shape.frame.origin, size: CGSize(width: side, height: side)).polygon)
    }
}

struct ProvidedKinds: CanvasPlugin {
    let log: ProvidedLog
    var id: PluginID { "provided-kinds" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(GaugedDefinition())
        registrar.shape(SpacerDefinition())
        let log = log
        registrar.layoutInput(gaugedSide) { record, reading in
            guard let gauged = record.typed(as: Gauged.self) else { return nil }
            let found = gauged.props.peg.flatMap { reading.shape(inFile: $0) }?.typed(as: Box.self)?.frame.width
            log.calls.append((record.id, reading.isCommitted, found))
            return found
        }
    }
}

extension Transaction {
    /// Inserts a shape of these props, returning its id.
    @discardableResult
    mutating func insert<P: ShapeProps>(_ props: P) -> ShapeID {
        let id = ShapeID()
        insert(ShapeRecord(id: id, props))
        return id
    }
}

@MainActor func stretchEditor(_ log: StretchLog) throws -> EditorHarness {
    try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin(), StretchesPlugin(log: log)])
}

/// Stretches laid out at their gauge's size, smaller than they store too.
@MainActor func shrinkingEditor(_ log: StretchLog = StretchLog()) throws -> EditorHarness {
    try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin(), StretchesPlugin(log: log, shrinking: true)])
}

@MainActor func providedEditor(_ log: ProvidedLog) throws -> EditorHarness {
    try EditorHarness(plugins: [FixturesPlugin(), ProvidedKinds(log: log)])
}

@MainActor let laidOutTests = Suite("Laid out", [
    test("a layout input has one provider: a second for the key refuses the plugin list, and the report names the key") {
        let twice = { (id: PluginID) in Contributor(id: id) { $0.layoutInput(gaugedSide) { _, _ in 1 } } }
        expectThrows(RegistryError.conflict(point: "LayoutProviders", key: "layout input gauged-side", plugins: ["a", "b"])) {
            _ = try Registry(plugins: [twice("a"), twice("b")])
        }
        let registry = try Registry(plugins: [twice("a")])
        expect(registry.report.contains("layout input gauged-side"), "the report names it")
        _ = try Registry(plugins: [twice("a"), Contributor(id: "b") { $0.layoutInput(spacerSide) { _, _ in 1 } }])
    },
    test("a value set for a shape is read through a transaction's shapes for one it hasn't changed or only moved, and nil for one it changed or added") {
        let log = ProvidedLog()
        let h = try providedEditor(log)
        let still = h.add(Spacer(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let moved = h.add(Spacer(CGRect(x: 0, y: 50, width: 10, height: 10)))
        let changed = h.add(Spacer(CGRect(x: 0, y: 100, width: 10, height: 10)))
        for id in [still, moved, changed] { h.editor.setLayoutInput(spacerSide, 30, for: id) }
        @MainActor func side(_ id: ShapeID) -> CGFloat? { h.editor.shapeContext.geometry(of: id)?.bounds.width }
        expectEqual([side(still), side(moved), side(changed)], [30, 30, 30], "on screen")
        var added = ShapeID()
        var inside: [CGFloat?] = []
        h.editor.transact { transaction in
            added = transaction.insert(Spacer(CGRect(x: 0, y: 150, width: 10, height: 10)))
            transaction.moveBox(moved, to: CGPoint(x: 5, y: 50))
            transaction.update(changed, as: Spacer.self) { $0.props.label = "changed" }
            for id in [still, moved, changed, added] { inside.append(transaction.shapes.geometry(of: id)?.bounds.width) }
        }
        expectEqual(inside, [30, 30, 10, 10], "untouched, moved, changed, added")
        expectEqual([side(still), side(moved), side(changed)], [30, 30, 30], "the editor's own set values stay what they were")
    },
    test("a provider is asked by the editor's context with the file as committed, and by a transaction's with the file as the transaction leaves it, and by no plain one") {
        let log = ProvidedLog()
        let h = try providedEditor(log)
        let peg = h.add(Box(CGRect(x: 0, y: 0, width: 40, height: 20)))
        let gauged = h.add(Gauged(peg: peg))
        @MainActor func side(_ id: ShapeID) -> CGFloat? { h.editor.shapeContext.geometry(of: id)?.bounds.width }
        expectEqual(side(gauged), 40, "the box it names")
        expectEqual(log.calls.last?.isCommitted, true, "the editor's reading is the committed file")
        expectEqual(log.calls.last?.shape, gauged)
        let plain = ShapeContext(document: h.editor.document, registry: h.editor.registry)
        let asked = log.calls.count
        expectEqual(plain.geometry(of: gauged)?.bounds.width, 10, "a plain context lays nothing out")
        expectEqual(plain.layoutInput(gaugedSide, for: gauged), nil)
        expectEqual(log.calls.count, asked, "and asks nobody")
        var seen: [CGFloat?] = []
        var late = ShapeID()
        h.editor.transact { transaction in
            let wide = transaction.insert(Box(CGRect(x: 0, y: 100, width: 70, height: 20)))
            late = transaction.insert(Gauged(peg: wide))
            seen.append(transaction.shapes.geometry(of: late)?.bounds.width)
            expectEqual(log.calls.last?.isCommitted, false, "mid-transaction the file is the transaction's")
            transaction.update(wide, as: Box.self) { $0.frame.size.width = 90 }
            seen.append(transaction.shapes.geometry(of: late)?.bounds.width)
            transaction.update(gauged, as: Gauged.self) { $0.props.peg = wide }
            seen.append(transaction.shapes.geometry(of: gauged)?.bounds.width)
            transaction.delete([wide])
            seen.append(transaction.shapes.geometry(of: late)?.bounds.width)
            seen.append(transaction.shapes.layoutInput(gaugedSide, for: gauged))
        }
        expectEqual(seen, [70, 90, 90, 10, nil], "what it inserted, changed and deleted, as it leaves them")
        expectEqual(side(late), 10, "committed: the box it named went")
    },
    test("a stretch with no gauge is its stored box: its frame, geometry, editing frame and outline") {
        let log = StretchLog()
        let h = try stretchEditor(log)
        let box = CGRect(x: 10, y: 20, width: 100, height: 60)
        let free = h.add(Stretch(box))
        let lost = h.add(Stretch(box.offsetBy(dx: 200, dy: 0), gauge: ShapeID()))
        for id in [free, lost] {
            let stored = h.editor.document[id]!.box!
            expectEqual(h.editor.shapeContext.frame(of: id), stored, "its frame")
            expectEqual(h.editor.shapeContext.geometry(of: id)?.bounds, stored, "its geometry")
            expectEqual(h.editor.shapeContext.geometry(of: id)?.outline, stored.polygon, "its outline")
            expectEqual(h.editor.frame(inFile: id), stored)
            expectEqual(h.editor.outlinePath(of: h.editor.document[id]!)?.boundingBox, stored, "its outline path")
            expect(h.editor.beginEditing(id))
            expectEqual(h.editor.editingFrame, stored, "its editing frame")
            h.editor.endEditing()
        }
        expectEqual(h.editor.shapeBounds, box.union(box.offsetBy(dx: 200, dy: 0)))
    },
    test("a stretch naming a gauge is the larger of each side from the same origin; a smaller gauge leaves it as stored, and so does a size that isn't finite") {
        let log = StretchLog()
        let h = try stretchEditor(log)
        let box = CGRect(x: 10, y: 20, width: 100, height: 60)
        let gauge = h.add(StretchGauge(.zero, width: 200, height: 90))
        let stretch = h.add(Stretch(box, gauge: gauge))
        @MainActor func frame() -> CGRect? { h.editor.shapeContext.frame(of: stretch) }
        expectEqual(frame(), CGRect(x: 10, y: 20, width: 200, height: 90), "wider and taller, from the same top-left")
        expectEqual(h.editor.shapeContext.geometry(of: stretch)?.bounds, frame(), "its geometry is it")
        expectEqual(h.editor.document[stretch]?.box, box, "the stored box is what it was")
        expect(h.editor.beginEditing(stretch))
        expectEqual(h.editor.editingFrame, CGRect(x: 10, y: 20, width: 200, height: 90), "the editing view is laid over it")
        h.editor.endEditing()
        h.editor.transact { $0.update(gauge, as: StretchGauge.self) { $0.props.width = 300; $0.props.height = 10 } }
        expectEqual(frame(), CGRect(x: 10, y: 20, width: 300, height: 60), "the larger of each side")
        h.editor.transact { $0.update(gauge, as: StretchGauge.self) { $0.props.width = 50; $0.props.height = 30 } }
        expectEqual(frame(), box, "a gauge smaller than it leaves it as stored")
        h.editor.transact { $0.update(gauge, as: StretchGauge.self) { $0.props.width = .infinity; $0.props.height = 500 } }
        expectEqual(frame(), box, "a width that isn't finite counts as the box")
        h.editor.transact { $0.update(gauge, as: StretchGauge.self) { $0.props.width = 200; $0.props.height = .nan } }
        expectEqual(frame(), box, "and so does a height")
    },
    test("a kind may be laid out smaller than it stores: the frame is the kind's size from the stored origin, and so are its geometry, outline and editing frame; the stored box is what it was; a size that isn't finite or above zero counts as the box") {
        let h = try shrinkingEditor()
        let box = CGRect(x: 10, y: 20, width: 200, height: 120)
        let gauge = h.add(StretchGauge(.zero, width: 100, height: 40))
        let stretch = h.add(Stretch(box, gauge: gauge))
        let small = CGRect(x: 10, y: 20, width: 100, height: 40)
        @MainActor func frame() -> CGRect? { h.editor.shapeContext.frame(of: stretch) }
        expectEqual(frame(), small, "smaller on both sides, from the same top-left")
        expectEqual(h.editor.shapeContext.geometry(of: stretch)?.bounds, small, "its geometry is it")
        expectEqual(h.editor.shapeContext.geometry(of: stretch)?.outline, small.polygon, "and its outline")
        expectEqual(h.editor.frame(inFile: stretch), small, "on any board")
        expectEqual(h.editor.outlinePath(of: h.editor.document[stretch]!)?.boundingBox, small, "its outline path")
        expectEqual(h.editor.document[stretch]?.box, box, "the stored box is what it was")
        expect(h.editor.beginEditing(stretch))
        expectEqual(h.editor.editingFrame, small, "the editing view is laid over it")
        h.editor.endEditing()
        h.editor.transact { $0.update(gauge, as: StretchGauge.self) { $0.props.width = 300; $0.props.height = 20 } }
        expectEqual(frame(), CGRect(x: 10, y: 20, width: 300, height: 20), "wider and shorter than it stores")
        for (width, height) in [(CGFloat.infinity, 40), (100, .nan), (0, 40), (100, 0), (-5, 40), (100, -1)] as [(CGFloat, CGFloat)] {
            h.editor.transact { $0.update(gauge, as: StretchGauge.self) { $0.props.width = width; $0.props.height = height } }
            expectEqual(frame(), box, "\(width) by \(height) counts as the box")
        }
        // The default fixture keeps a stretch no smaller than it stores, as most tests rely on.
        let keeping = try stretchEditor(StretchLog())
        let keepGauge = keeping.add(StretchGauge(.zero, width: 100, height: 40))
        let kept = keeping.add(Stretch(box, gauge: keepGauge))
        expectEqual(keeping.editor.shapeContext.frame(of: kept), box, "the larger of each side")
    },
    test("the kept extent follows the laid-out frame: a point or a view in the stored box and outside the frame hits nothing and draws nothing, and the board's bounds are the frame") {
        let h = try shrinkingEditor()
        let gauge = h.add(StretchGauge(CGRect(x: 1000, y: 1000, width: 60, height: 40), width: 100, height: 40))
        let stretch = h.add(Stretch(CGRect(x: 0, y: 0, width: 300, height: 200), gauge: gauge))
        expectEqual(h.editor.shape(at: CGPoint(x: 50, y: 20)), stretch, "in the frame")
        expectEqual(h.editor.shape(at: CGPoint(x: 250, y: 150)), nil, "in the stored box, outside the frame")
        expectEqual(h.editor.paintOrder(in: CGRect(x: 40, y: 10, width: 10, height: 10)).map(\.id), [stretch])
        expectEqual(h.editor.paintOrder(in: CGRect(x: 240, y: 140, width: 10, height: 10)).map(\.id), [], "in view by its frame only")
        expectEqual(h.editor.shapeBounds, CGRect(x: 0, y: 0, width: 100, height: 40).union(CGRect(x: 1000, y: 1000, width: 60, height: 40)),
                    "the board's bounds, Zoom to Fit's and a first visit's, the frame and not the stored box")
        // Laid out again, the extent moves with it, down as well as up.
        h.editor.transact("Gauge") { $0.update(gauge, as: StretchGauge.self) { $0.props.width = 250; $0.props.height = 150 } }
        expectEqual(h.editor.shape(at: CGPoint(x: 240, y: 140)), stretch, "grown")
        expectEqual(h.editor.shapeBounds.minX, 0)
        expectEqual(h.editor.paintOrder(in: CGRect(x: 240, y: 140, width: 5, height: 5)).map(\.id), [stretch])
        h.editor.undo()
        expectEqual(h.editor.shape(at: CGPoint(x: 240, y: 140)), nil, "and back down with the undo")
        expectEqual(h.editor.paintOrder(in: CGRect(x: 240, y: 140, width: 5, height: 5)).map(\.id), [])
        // The minimap hears where it shrank.
        let mark = h.editor.damageMark
        h.editor.transact("Gauge") { $0.update(gauge, as: StretchGauge.self) { $0.props.width = 20 } }
        expect(h.editor.damage(since: mark).contains(CGRect(x: 0, y: 0, width: 100, height: 40)), "the area it left is redrawn")
    },
    test("a shape placed at a point is the stored size centered on it, whatever it is laid out at: the frame hangs from that origin, up and left of the point when it is smaller") {
        let h = try shrinkingEditor()
        let gauge = h.add(StretchGauge(CGRect(x: 1000, y: 1000, width: 60, height: 40), width: 40, height: 20))
        let placement = try require(h.editor.registry.placement(for: Stretch.kind)).mapping { record in
            var stretch = record.typed(as: Stretch.self)!
            stretch.props.gauge = GaugeLink(gauge)
            return AnyShapeRecord(stretch)
        }
        expectEqual(placement.shape(at: CGPoint(x: 500, y: 500)).box, CGRect(x: 450, y: 470, width: 100, height: 60), "the stored size, centered")
        h.editor.place(placement, at: CGPoint(x: 500, y: 500))
        let placed = try require(h.editor.document.shapes.first { $0.kind == Stretch.kind })
        expectEqual(placed.box, CGRect(x: 450, y: 470, width: 100, height: 60))
        expectEqual(h.editor.shapeContext.frame(of: placed.id), CGRect(x: 450, y: 470, width: 40, height: 20), "laid out smaller from the same origin")
    },
    test("the size is kept: a drag and its undo ask nothing, a resize of the stored box or another gauge asks once more, and a deleted shape's is let go") {
        let log = StretchLog()
        let h = try stretchEditor(log)
        let gauge = h.add(StretchGauge(.zero, width: 200, height: 90))
        let other = h.add(StretchGauge(.zero, width: 400, height: 120))
        let stretch = h.add(Stretch(CGRect(x: 10, y: 20, width: 100, height: 60), gauge: gauge))
        @MainActor func size() -> CGSize? { h.editor.shapeContext.frame(of: stretch)?.size }
        expectEqual(size(), CGSize(width: 200, height: 90))
        expectEqual(size(), CGSize(width: 200, height: 90))
        expectEqual(log.sizes, [stretch], "asked twice, the kind is asked once")
        expectEqual(log.provided, [stretch])
        for x: CGFloat in [20, 30, 40] {
            h.editor.transact("Move") { $0.moveBox(stretch, to: CGPoint(x: x, y: 20)) }
            _ = h.editor.paintOrder(in: .infinite)
            expectEqual(h.editor.shapeContext.frame(of: stretch), CGRect(x: x, y: 20, width: 200, height: 90), "a drag's event")
        }
        h.editor.undo()
        _ = h.editor.paintOrder(in: .infinite)
        expectEqual(h.editor.shapeContext.frame(of: stretch)?.origin, CGPoint(x: 30, y: 20), "undone")
        expectEqual(log.sizes.count, 1, "three events and an undo asked nothing")
        expectEqual(log.provided.count, 1)
        h.editor.transact { $0.update(stretch, as: Stretch.self) { $0.frame.size.width = 120 } }
        expectEqual(size(), CGSize(width: 200, height: 90))
        expectEqual(log.sizes.count, 2, "a resize of the stored box asks once more")
        h.editor.undo()
        expectEqual(size(), CGSize(width: 200, height: 90))
        expectEqual(log.sizes.count, 3, "its undo asks again")
        h.editor.redo()
        expectEqual(size(), CGSize(width: 200, height: 90))
        expectEqual(log.sizes.count, 4, "and so does its redo")
        h.editor.transact { $0.update(stretch, as: Stretch.self) { $0.props.gauge = GaugeLink(other) } }
        expectEqual(size(), CGSize(width: 400, height: 120), "naming another gauge")
        expectEqual(log.sizes.count, 5)
        #if DEBUG
        let kept = h.editor.laidOutSizeCount
        h.editor.transact { $0.delete([stretch]) }
        expectEqual(h.editor.laidOutSizeCount, kept - 1, "a deleted shape's size is let go")
        #endif
    },
    test("a gauge changed lays out again the stretches that name it and no others, with no commit of theirs, no step and no edit, and the minimap hears where they grew") {
        let log = StretchLog()
        let h = try stretchEditor(log)
        let gauge = h.add(StretchGauge(.zero, width: 200, height: 90))
        let other = h.add(StretchGauge(.zero, width: 300, height: 100))
        let named = h.add(Stretch(CGRect(x: 10, y: 20, width: 100, height: 60), gauge: gauge))
        let apart = h.add(Stretch(CGRect(x: 10, y: 400, width: 100, height: 60), gauge: other))
        @MainActor func frame(_ id: ShapeID) -> CGRect? { h.editor.shapeContext.frame(of: id) }
        _ = (frame(named), frame(apart))
        _ = h.editor.shapeContext.geometry(of: named)
        let asked = log.sizes
        let mark = h.editor.damageMark
        let revision = h.editor.revision, layout = h.editor.layoutRevision
        h.editor.transact("Gauge") { $0.update(gauge, as: StretchGauge.self) { $0.props.width = 500; $0.props.height = 250 } }
        expectEqual(frame(named), CGRect(x: 10, y: 20, width: 500, height: 250), "laid out again")
        expectEqual(frame(apart), CGRect(x: 10, y: 400, width: 300, height: 100), "another gauge's, as it was")
        expectEqual(log.sizes, asked + [named], "only the one that names it was asked")
        expectEqual(h.editor.revision, revision + 1, "the gauge's commit and no other")
        expectEqual(h.editor.undoHistory.undoName, "Gauge", "its step is the only one")
        expectEqual(h.editor.layoutRevision, layout + 1, "and the layout moved")
        expectEqual(h.editor.document[named]?.box, CGRect(x: 10, y: 20, width: 100, height: 60), "the stretch is not edited")
        expect(h.editor.damage(since: mark).contains(CGRect(x: 10, y: 20, width: 500, height: 250)), "the minimap redraws where it grew")
        h.editor.undo()
        expectEqual(frame(named), CGRect(x: 10, y: 20, width: 200, height: 90), "undone with the gauge")
        h.editor.redo()
        expectEqual(frame(named), CGRect(x: 10, y: 20, width: 500, height: 250), "and redone with it")
    },
    test("a gauge on another board lays out the stretch that names it, and a transaction on that board is followed") {
        let log = StretchLog()
        let h = try stretchEditor(log)
        let pocket = h.add(Pocket(CGRect(x: 500, y: 0, width: 100, height: 100)))
        expect(h.enter(pocket))
        let gauge = h.add(StretchGauge(.zero, width: 200, height: 90))
        expect(h.editor.showBoard(.root))
        let stretch = h.add(Stretch(CGRect(x: 10, y: 20, width: 100, height: 60), gauge: gauge))
        expectEqual(h.editor.shapeContext.frame(of: stretch)?.size, CGSize(width: 200, height: 90), "laid out by a gauge on another board")
        h.editor.transact(on: BoardID(owner: pocket), "Gauge") { $0.update(gauge, as: StretchGauge.self) { $0.props.height = 300 } }
        expectEqual(h.editor.shapeContext.frame(of: stretch)?.size, CGSize(width: 200, height: 300), "the stretch follows")
    },
    test("in a transaction a gauge and its stretch inserted together are laid out before the commit; a stretch it did not touch or only moved reads its kept size, and one it changed is asked again") {
        let log = StretchLog()
        let h = try stretchEditor(log)
        let gauge = h.add(StretchGauge(.zero, width: 200, height: 90))
        let still = h.add(Stretch(CGRect(x: 0, y: 200, width: 100, height: 60), gauge: gauge))
        let moved = h.add(Stretch(CGRect(x: 0, y: 300, width: 100, height: 60), gauge: gauge))
        let changed = h.add(Stretch(CGRect(x: 0, y: 400, width: 100, height: 60), gauge: gauge))
        for id in [still, moved, changed] { _ = h.editor.shapeContext.frame(of: id) }
        expectEqual(log.sizes.count, 3)
        let newGauge = ShapeID(), newStretch = ShapeID()
        var seen: [CGRect?] = []
        h.editor.transact { transaction in
            transaction.insert(ShapeRecord(id: newGauge, StretchGauge(.zero, width: 250, height: 120)))
            transaction.insert(ShapeRecord(id: newStretch, Stretch(CGRect(x: 0, y: 500, width: 100, height: 60), gauge: newGauge)))
            seen.append(transaction.shapes.frame(of: newStretch))
            expectEqual(log.sizes.count, 4, "the new one asked, with the gauge it was inserted with")
            seen.append(transaction.shapes.frame(of: still))
            transaction.moveBox(moved, to: CGPoint(x: 50, y: 300))
            seen.append(transaction.shapes.frame(of: moved))
            expectEqual(log.sizes.count, 4, "one not touched, and one moved, are read as kept")
            transaction.update(changed, as: Stretch.self) { $0.frame.size.height = 70 }
            seen.append(transaction.shapes.frame(of: changed))
            expectEqual(log.sizes.count, 5, "one changed is asked again")
        }
        expectEqual(seen, [CGRect(x: 0, y: 500, width: 250, height: 120), CGRect(x: 0, y: 200, width: 200, height: 90),
                           CGRect(x: 50, y: 300, width: 200, height: 90), CGRect(x: 0, y: 400, width: 200, height: 90)])
        expectEqual(h.editor.shapeContext.frame(of: newStretch), seen[0], "and the commit agrees")
    },
    test("a context laying out with records reads them as the file's, keeps nothing and touches nothing the editor keeps") {
        let log = StretchLog()
        let h = try stretchEditor(log)
        let onBoard = h.add(Stretch(CGRect(x: 0, y: 0, width: 100, height: 60)))
        expectEqual(h.editor.shapeContext.frame(of: onBoard)?.size, CGSize(width: 100, height: 60))
        #if DEBUG
        let kept = h.editor.laidOutSizeCount
        #endif
        let gauge = ShapeRecord(id: ShapeID(), StretchGauge(.zero, width: 250, height: 120))
        let stretch = ShapeRecord(id: ShapeID(), Stretch(CGRect(x: 10, y: 10, width: 100, height: 60), gauge: gauge.id))
        let restated = AnyShapeRecord(ShapeRecord(id: onBoard, Stretch(CGRect(x: 0, y: 0, width: 100, height: 60), gauge: gauge.id)))
        let context = h.editor.shapeContext.layingOut(with: [AnyShapeRecord(gauge), AnyShapeRecord(stretch), restated])
        expectEqual(context.frame(of: AnyShapeRecord(stretch)), CGRect(x: 10, y: 10, width: 250, height: 120), "laid out by a gauge only the records have")
        expectEqual(context.frame(of: restated)?.size, CGSize(width: 250, height: 120), "a changed copy is asked afresh, not read from what is kept")
        expectEqual(h.editor.shapeContext.frame(of: onBoard)?.size, CGSize(width: 100, height: 60), "the editor's own is as it was")
        #if DEBUG
        expectEqual(h.editor.laidOutSizeCount, kept, "nothing was kept")
        #endif
        expect(h.editor.shapeContext.geometry(of: stretch.id) == nil, "the editor's index worked out nothing for it")
        expectEqual(h.editor.document.shapes.count, 1)
    },
    test("a context laying out from a transaction's shapes still asks afresh for what the transaction changed") {
        let log = StretchLog()
        let h = try stretchEditor(log)
        let gauge = h.add(StretchGauge(.zero, width: 200, height: 90))
        let stretch = h.add(Stretch(CGRect(x: 10, y: 20, width: 100, height: 60), gauge: gauge))
        let still = h.add(Stretch(CGRect(x: 10, y: 200, width: 100, height: 60), gauge: gauge))
        _ = (h.editor.shapeContext.frame(of: stretch), h.editor.shapeContext.frame(of: still))
        var seen: [CGSize?] = []
        h.editor.transact { transaction in
            transaction.update(stretch, as: Stretch.self) { $0.frame.size.width = 300 }
            let context = transaction.shapes.layingOut(with: [])
            seen = [context.frame(of: stretch)?.size, context.frame(of: still)?.size]
        }
        expectEqual(seen, [CGSize(width: 300, height: 90), CGSize(width: 200, height: 90)], "the changed one at its new size, the other as kept")
    },
    test("a plain context gives the stored box") {
        let log = StretchLog()
        let h = try stretchEditor(log)
        let gauge = h.add(StretchGauge(.zero, width: 200, height: 90))
        let stretch = h.add(Stretch(CGRect(x: 10, y: 20, width: 100, height: 60), gauge: gauge))
        let plain = ShapeContext(document: h.editor.document, registry: h.editor.registry)
        expectEqual(plain.frame(of: stretch), CGRect(x: 10, y: 20, width: 100, height: 60))
        expectEqual(plain.geometry(of: stretch)?.bounds, CGRect(x: 10, y: 20, width: 100, height: 60))
        expectEqual(h.editor.shapeContext.frame(of: stretch)?.size, CGSize(width: 200, height: 90), "the editor's lays it out")
        expectEqual(log.provided.count, 1, "the plain context asked nobody")
    },
    test("a point in the grown part hits the stretch, and the paint order culls by the laid-out extent") {
        let log = StretchLog()
        let h = try stretchEditor(log)
        let gauge = h.add(StretchGauge(.zero, width: 300, height: 200))
        let stretch = h.add(Stretch(CGRect(x: 0, y: 0, width: 100, height: 60), gauge: gauge))
        h.editor.transact { $0.update(gauge, as: StretchGauge.self) { $0.frame.origin = CGPoint(x: 1000, y: 1000) } }
        expectEqual(h.editor.shape(at: CGPoint(x: 250, y: 150)), stretch, "in the grown part")
        expectEqual(h.editor.shape(at: CGPoint(x: 350, y: 150)), nil, "past it")
        expectEqual(h.editor.paintOrder(in: CGRect(x: 240, y: 140, width: 10, height: 10)).map(\.id), [stretch], "in view by its grown part only")
        expectEqual(h.editor.paintOrder(in: CGRect(x: 320, y: 140, width: 10, height: 10)).map(\.id), [])
    },
    test("the frame of a shape on a board that is not shown is laid out, and kept, without that board's geometry") {
        let log = StretchLog()
        let h = try stretchEditor(log)
        let pocket = h.add(Pocket(CGRect(x: 500, y: 0, width: 100, height: 100)))
        expect(h.enter(pocket))
        let gauge = h.add(StretchGauge(.zero, width: 200, height: 90))
        let stretch = h.add(Stretch(CGRect(x: 10, y: 20, width: 100, height: 60), gauge: gauge))
        expect(h.editor.showBoard(.root))
        expectEqual(h.editor.shapeContext.frame(of: stretch), nil, "not on the board shown")
        expectEqual(h.editor.frame(inFile: stretch), CGRect(x: 10, y: 20, width: 200, height: 90))
        expectEqual(h.editor.frame(inFile: stretch), CGRect(x: 10, y: 20, width: 200, height: 90))
        expectEqual(log.sizes, [stretch], "asked once")
        expectEqual(h.editor.frame(inFile: pocket), CGRect(x: 500, y: 0, width: 100, height: 100), "a shape that isn't laid out")
        expectEqual(h.editor.frame(inFile: ShapeID()), nil)
    },
    test("a kind that holds shapes can't be laid out past its box") {
        expectThrows(RegistryError.invalid(point: "Shapes", reason: "laid-corral holds shapes, so it can't be laid out past its box")) {
            _ = try Registry(plugins: [Contributor(id: "laid-corrals") { $0.shape(LaidCorralDefinition()) }])
        }
        let registry = try Registry(plugins: [StretchesPlugin(), CorralsPlugin()])
        expect(registry.isLaidOutBox("stretch"))
        expect(!registry.isLaidOutBox("corral"))
        expect(!registry.isLaidOutBox("nothing"))
    },
    test("asked too early: a service that hears a commit before the owner of a layout input is told the old size of a stretch, and after the commit it is the size the gauge says now, for it and for one the same commit added") {
        let log = StretchLog()
        let early = EarlyAsker()
        let h = try EditorHarness(plugins: [FixturesPlugin(), Contributor(id: "early") { $0.service { EarlyService(asker: early, editor: $0) } },
                                            StretchesPlugin(log: log)])
        let gauge = h.add(StretchGauge(.zero, width: 200, height: 90))
        let old = h.add(Stretch(CGRect(x: 0, y: 200, width: 100, height: 60), gauge: gauge))
        expectEqual(h.editor.shapeContext.frame(of: old)?.size, CGSize(width: 200, height: 90))
        let added = ShapeID()
        early.watching = [old, added]
        h.editor.transact {
            $0.update(gauge, as: StretchGauge.self) { $0.props.width = 400; $0.props.height = 150 }
            $0.insert(ShapeRecord(id: added, Stretch(CGRect(x: 0, y: 300, width: 100, height: 60), gauge: gauge)))
        }
        expectEqual(early.seen[old]?.size, CGSize(width: 200, height: 90), "it heard first: the old size")
        expectEqual(early.seen[added]?.size, CGSize(width: 400, height: 150), "the one added had nothing kept, so asked early it is laid out by the file as committed, and what it kept holds after")
        for id in [old, added] {
            expectEqual(h.editor.shapeContext.frame(of: id)?.size, CGSize(width: 400, height: 150), "after the commit")
        }
    },
])

/// A kind that holds shapes and says it is laid out past its box: the registry refuses it.
struct LaidCorral: BoxShapeProps {
    static let kind: ShapeKind = "laid-corral"
    static let properties = Properties<LaidCorral> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
}

extension LaidCorral {
    init() { self.init(.zero) }
}

struct LaidCorralDefinition {}

extension LaidCorralDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<LaidCorral>, in context: RenderContext) {}
}

extension LaidCorralDefinition: ShapeContaining {}

extension LaidCorralDefinition: LaidOutBox {
    func laidOutSize(of shape: ShapeRecord<LaidCorral>, in context: ShapeContext) -> CGSize { shape.frame.size }
}

/// What a service that hears first saw of the shapes it watches.
@MainActor final class EarlyAsker {
    var watching: [ShapeID] = []
    var seen: [ShapeID: CGRect] = [:]
}

/// Asks for the frame of each shape it watches as it hears a commit, before the service that owns
/// the layout input has.
@MainActor final class EarlyService: EditorService {
    let asker: EarlyAsker
    init(asker: EarlyAsker, editor: CanvasEditor) { self.asker = asker }

    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        for id in asker.watching { asker.seen[id] = editor.shapeContext.frame(of: id) }
    }
}
