import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import TestKit

/// What the index's kinds were asked to do.
@MainActor final class IndexLog {
    var geometries: [ShapeID] = []
    var renders: [ShapeID] = []
    var hitTests: [ShapeID] = []
}

/// A 10 × 10 square on its host's top-right corner (at the origin without one): its geometry looks
/// the host up, as a connector's looks up the shapes it joins.
struct Marker: ShapeProps {
    static let kind: ShapeKind = "marker"
    static let properties = Properties<Marker> {
        Property("host", \.host)
    }
    var host: ShapeID?
}

struct MarkerDefinition {
    let log: IndexLog
}

extension MarkerDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Marker>, in context: RenderContext) { log.renders.append(shape.id) }

    func geometry(of shape: ShapeRecord<Marker>, in context: ShapeContext) -> ShapeGeometry {
        log.geometries.append(shape.id)
        let host = shape.props.host.flatMap { context.geometry(of: $0)?.bounds }
        let corner = host.map { CGPoint(x: $0.maxX, y: $0.minY) } ?? .zero
        return ShapeGeometry(outline: CGRect(center: corner, size: CGSize(width: 10, height: 10)).polygon)
    }
}

/// A square at the origin, ten units a side for every shape on the board: its geometry reads the
/// whole document.
struct Census: ShapeProps {
    static let kind: ShapeKind = "census"
    static let properties = Properties<Census> {}
}

struct CensusDefinition {}

extension CensusDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Census>, in context: RenderContext) {}

    func geometry(of shape: ShapeRecord<Census>, in context: ShapeContext) -> ShapeGeometry {
        let side = CGFloat(context.document.shapes.count) * 10
        return ShapeGeometry(outline: CGRect(x: 0, y: 0, width: side, height: side).polygon)
    }
}

/// A square at the origin, 20 view points a side at any zoom: its geometry reads the camera.
struct Badge: ShapeProps {
    static let kind: ShapeKind = "badge"
    static let properties = Properties<Badge> {}
}

struct BadgeDefinition {}

extension BadgeDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Badge>, in context: RenderContext) {}

    func geometry(of shape: ShapeRecord<Badge>, in context: ShapeContext) -> ShapeGeometry {
        let side = 20 / context.zoom
        return ShapeGeometry(outline: CGRect(x: 0, y: 0, width: side, height: side).polygon)
    }
}

/// A segment, hit within 5 view points and 2 world units of it, as its hit margin says.
struct Wire: ShapeProps {
    static let kind: ShapeKind = "wire"
    static let properties = Properties<Wire> {
        Property("from", \.from).required()
        Property("to", \.to).required()
    }
    var from: CGPoint
    var to: CGPoint
}

extension Wire {
    init() { self.init(from: .zero, to: .zero) }
}

struct WireDefinition {
    let log: IndexLog
}

extension WireDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Wire>, in context: RenderContext) {}

    func geometry(of shape: ShapeRecord<Wire>, in context: ShapeContext) -> ShapeGeometry {
        ShapeGeometry(outline: [shape.props.from, shape.props.to], isClosed: false)
    }

    func hitTest(_ point: CGPoint, on shape: ShapeRecord<Wire>, in context: ShapeContext) -> Bool {
        log.hitTests.append(shape.id)
        return distanceToSegment(from: point, shape.props.from, shape.props.to) <= 5 / context.zoom + 2
    }

    var hitMargin: HitMargin { HitMargin(world: 2, view: 5) }
}

struct IndexKinds: CanvasPlugin {
    let log: IndexLog
    var id: PluginID { "index-kinds" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(MarkerDefinition(log: log))
        registrar.shape(CensusDefinition())
        registrar.shape(BadgeDefinition())
        registrar.shape(WireDefinition(log: log))
    }
}

// What the editor keeps from frame to frame (each shape's geometry and extent, the paint order)
// must always be what working it all out again would give.
@MainActor let shapeIndexTests = Suite("Shape index", [
    test("a geometry that looks up another shape follows it, and is worked out again only when that shape changes") {
        let log = IndexLog()
        let h = try EditorHarness(plugins: [FixturesPlugin(), IndexKinds(log: log)])
        let host = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let other = h.add(Box(CGRect(x: 0, y: 200, width: 100, height: 100)))
        let marker = h.add(Marker(host: host))
        expectEqual(h.editor.shape(at: CGPoint(x: 102, y: -2)), marker, "on the host's top-right corner")
        _ = h.editor.paintOrder(in: .infinite)
        let worked = log.geometries.count
        h.editor.transact { $0.update(other, as: Box.self) { $0.frame.origin.x = 50 } }
        _ = h.editor.paintOrder(in: .infinite)
        expectEqual(log.geometries.count, worked, "another shape changed: the marker's geometry is kept")
        h.editor.transact { $0.update(host, as: Box.self) { $0.frame.origin.x = 300 } }
        _ = h.editor.paintOrder(in: .infinite)
        expectEqual(log.geometries.count, worked + 1, "its host changed: worked out again")
        expectEqual(h.editor.shape(at: CGPoint(x: 102, y: -2)), nil)
        expectEqual(h.editor.shape(at: CGPoint(x: 402, y: -2)), marker, "it went with its host")
        expectEqual(h.editor.paintOrder(in: CGRect(x: 380, y: -20, width: 40, height: 40)).map(\.id), [host, marker])
        expectEqual(h.editor.paintOrder(in: CGRect(x: 80, y: -20, width: 40, height: 40)).map(\.id), [])
        h.editor.transact { $0.delete([host]) }
        expectEqual(h.editor.shape(at: CGPoint(x: 2, y: 2)), marker, "at the origin, its host gone")
    },
    test("a geometry that reads the whole document is worked out again after every change") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), IndexKinds(log: IndexLog())])
        let census = h.add(Census())
        expectEqual(h.editor.shape(at: CGPoint(x: 15, y: 15)), nil, "one shape: 10 × 10")
        h.add(Box(CGRect(x: 500, y: 500, width: 10, height: 10)))
        expectEqual(h.editor.shape(at: CGPoint(x: 15, y: 15)), census, "two shapes: 20 × 20")
    },
    test("a geometry that reads the camera is worked out again when the camera changes") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), IndexKinds(log: IndexLog())])
        let badge = h.add(Badge())
        expectEqual(h.editor.shape(at: CGPoint(x: 15, y: 15)), badge, "20 world units at 100%")
        h.editor.camera = Camera(origin: .zero, zoom: 2)
        expectEqual(h.editor.shape(at: CGPoint(x: 15, y: 15)), nil, "10 at 200%")
        h.editor.camera = Camera(origin: .zero, zoom: 0.5)
        expectEqual(h.editor.shape(at: CGPoint(x: 30, y: 30)), badge, "40 at 50%")
        expectEqual(h.editor.paintOrder(in: CGRect(x: 30, y: 30, width: 5, height: 5)).map(\.id), [badge])
    },
    test("a context made before a change keeps to its own document") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let before = h.editor.shapeContext
        _ = before.geometry(of: box)
        h.editor.transact { $0.update(box, as: Box.self) { $0.frame.origin.x = 100 } }
        expectEqual(before.geometry(of: box)?.bounds, CGRect(x: 0, y: 0, width: 10, height: 10))
        expect(before.hitTest(CGPoint(x: 5, y: 5), shape: box))
        expectEqual(h.editor.shapeContext.geometry(of: box)?.bounds, CGRect(x: 100, y: 0, width: 10, height: 10))
        expect(!h.editor.shapeContext.hitTest(CGPoint(x: 5, y: 5), shape: box))
    },
    test("hit testing asks a shape only about points within its bounds and the hit margin it declares") {
        let log = IndexLog()
        let h = try EditorHarness(plugins: [FixturesPlugin(), IndexKinds(log: log)])
        let wire = h.add(Wire(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0)))
        expectEqual(h.editor.shape(at: CGPoint(x: 50, y: 6.5)), wire, "within 5 pt and 2 world units")
        expectEqual(h.editor.shape(at: CGPoint(x: 50, y: 7.5)), nil)
        h.editor.camera = Camera(origin: .zero, zoom: 0.25)
        expectEqual(h.editor.shape(at: CGPoint(x: 50, y: 21.5)), wire, "5 pt is 20 world units at 25%")
        expect(h.editor.shapeContext.hitTest(CGPoint(x: 104, y: 21.5), shape: wire))
        log.hitTests = []
        expectEqual(h.editor.shape(at: CGPoint(x: 50, y: 500)), nil)
        expect(!h.editor.shapeContext.hitTest(CGPoint(x: 50, y: 500), shape: wire))
        expectEqual(log.hitTests, [], "nowhere near it, so never asked")
    },
    test("drawing culls a shape without a box by its geometry; one with no outline always draws") {
        let log = IndexLog()
        let h = try EditorHarness(plugins: [FixturesPlugin(), IndexKinds(log: log)])
        let host = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let marker = h.add(Marker(host: host))
        let loose = h.add(Tag(target: nil))
        _ = renderBitmap(h.editor, size: CGSize(width: 300, height: 300))
        expectEqual(log.renders, [marker])
        h.editor.transact { $0.update(host, as: Box.self) { $0.frame.origin = CGPoint(x: 5000, y: 5000) } }
        log.renders = []
        _ = renderBitmap(h.editor, size: CGSize(width: 300, height: 300))
        expectEqual(log.renders, [], "its host took it out of view")
        expectEqual(h.editor.paintOrder(in: CGRect(x: -900, y: -900, width: 1, height: 1)).map(\.id), [loose],
                    "a tag has no outline to cull it by")
    },
    test("the paint order holds through changes that don't move anything in it, and follows those that do") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        let tag = h.add(Tag(target: a))
        expectEqual(h.editor.paintOrder().map(\.id), [a, tag, b])
        h.editor.transact { $0.update(a, as: Box.self) { $0.frame.origin.y = 50 } }
        expectEqual(h.editor.paintOrder().map(\.id), [a, tag, b])
        h.editor.transact { $0.update(tag, as: Tag.self) { $0.props.target = b } }
        expectEqual(h.editor.paintOrder().map(\.id), [a, b, tag], "above its new anchor")
        h.editor.transact { $0.bringToFront(a) }
        expectEqual(h.editor.paintOrder().map(\.id), [b, tag, a])
        h.editor.transact { $0.delete([b]) }
        expectEqual(h.editor.paintOrder().map(\.id), [a, tag], "on top, its anchor gone")
    },
])
