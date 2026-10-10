import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import TestKit

// What a plugin provides to lay shapes out (`registrar.layoutInput`), asked by the editor's contexts,
// a transaction's, and by no plain one.

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
])
