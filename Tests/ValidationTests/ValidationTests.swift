import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import TestKit
import Validation

/// A vertical that opts in, the way sticky-notes does, but with fixture kinds.
struct Rules: CanvasPlugin {
    let id: PluginID
    let body: @MainActor (inout PluginRegistrar) -> Void
    init(_ id: PluginID = "rules", _ body: @escaping @MainActor (inout PluginRegistrar) -> Void) {
        self.id = id
        self.body = body
    }
    func register(into registrar: inout PluginRegistrar) { body(&registrar) }
}

struct TinyBoxDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Tiny>, in context: RenderContext) {}
}
struct Tiny: BoxShapeProps {
    static let kind: ShapeKind = "tiny"
    static let properties = Properties<Tiny> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
}
extension Tiny {
    init() { self.init(frame: .zero) }
}

/// What a box may say about itself, in at most 5 characters: a bound a shape can break.
enum Motto {}
extension Motto: ShapeProperty {
    static let key: PropertyKey = "motto"
    static var defaultValue: String? { nil }
    static var keywords: PropertyKeywords<String> { PropertyKeywords().maxLength(5) }
}

/// Validation's rings in full as it drew them before its line width and join were set once a frame:
/// each shape's stroked alone, its width and join set for it, in paint order, 2 wide, around its
/// outline (`indicatorPath`) grown 3 view points, for shapes 32 points or more on screen. The
/// overlay still strokes each alone in full; only zoomed out does it fill a run of one color at
/// once (square rings).
struct OneAtATime: CanvasOverlay {
    let severity: @MainActor (AnyShapeRecord) -> Severity?
    var space: OverlaySpace { .world }
    func draw(in context: OverlayContext) {
        let zoom = context.zoom, pad = 3 / zoom
        for record in context.editor.paintOrder(in: context.visibleRect.insetBy(dx: -10 / zoom, dy: -10 / zoom)) {
            guard let worst = severity(record), let geometry = context.shapes.geometry(of: record.id),
                  let outline = context.shapes.registry.indicatorPath(of: record, in: context.shapes) else { continue }
            let band = outline.copy(strokingWithWidth: pad * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
            context.cg.addPath(geometry.isClosed ? outline.union(band) : band.normalized())
            context.cg.setStrokeColor(worst.color.cgColor)
            context.cg.setLineWidth(2 / zoom)
            context.cg.setLineJoin(.round)
            context.cg.strokePath()
        }
    }
}

/// What a test has the canvas outline: the selection, and groups of shapes in colors of their own.
@MainActor final class Outlined {
    var shapes: [ShapeID] = []
    var tinted: [TintedOutlines] = []
}

@MainActor var calls = 0

@MainActor let validationTests = Suite("Validation", [
    test("a rule registered in a shape's registrar gets typed props and applies only to its kind") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), Rules { r in
            r.shape(TinyBoxDefinition()) { tiny in
                tiny.validate { shape, _ in shape.props.frame.width < 10 ? [.error("too small")] : [] }
            }
        }])
        let small = h.add(Tiny(frame: CGRect(x: 0, y: 0, width: 5, height: 5)))
        h.add(Tiny(frame: CGRect(x: 0, y: 0, width: 50, height: 50)))
        h.add(Box(CGRect(x: 0, y: 0, width: 1, height: 1)))
        let results = try require(h.editor.validation).results
        expectEqual(Array(results.keys), [small])
        expectEqual(results[small]?.isValid, false)
    },
    test("a plugin can add a rule for another plugin's kind, and one for every kind; kind rules run first") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), Rules { r in
            r.validateEveryShape { _, _ in [.warning("every")] }
            r.validate(Box.self) { box, _ in box.frame.isEmpty ? [.warning("empty box")] : [] }
        }])
        let box = h.add(Box(.zero))
        let disc = h.add(Disc(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let results = try require(h.editor.validation).results
        expectEqual(results[box]?.issues.map(\.message), ["empty box", "every"])
        expectEqual(results[disc]?.issues.map(\.message), ["every"])
    },
    test("a rule for every kind reads the registry, to ask about the kind of what it checks") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), NamingPlugin(), ValidationPlugin(), Rules { r in
            r.validateEveryShape { shape, context in context.registry.namingKinds.contains(shape.kind) ? [.warning("may name shapes")] : [] }
        }])
        let memo = h.add(Memo())
        let box = h.add(Box(.zero))
        let results = try require(h.editor.validation).results
        expectEqual(results[memo]?.issues.map(\.message), ["may name shapes"])
        expectEqual(results[box], nil)
    },
    test("validity is derived: an error makes a shape invalid; warnings don't") {
        expectEqual(ValidationResult(issues: [.warning("w"), .error("e")]).isValid, false)
        expectEqual(ValidationResult(issues: [.warning("w"), .error("e")]).worst, .error)
        expectEqual(ValidationResult(issues: [.warning("w"), .warning("v")]).isValid, true)
        expectEqual(ValidationResult(issues: [.warning("w"), .warning("v")]).worst, .warning)
    },
    test("worst first: the errors, then the warnings, each in the rules' order") {
        let result = ValidationResult(issues: [.warning("w1"), .error("e1"), .warning("w2"), .error("e2")])
        expectEqual(result.worstFirst.map(\.message), ["e1", "e2", "w1", "w2"])
    },
    test("results recompute after a change, and only then") {
        calls = 0
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), Rules { r in
            r.validate(Box.self) { box, _ in calls += 1; return box.frame.isEmpty ? [.warning("empty")] : [] }
        }])
        let box = h.add(Box(.zero))
        let engine = try require(h.editor.validation)
        expect(engine.result(for: box) != nil)
        _ = engine.results
        expectEqual(calls, 1)
        h.editor.transact { $0.update(box, as: Box.self) { $0.frame.size = CGSize(width: 5, height: 5) } }
        expect(engine.result(for: box) == nil)
        expectEqual(calls, 2)
        h.editor.transact { $0.delete([box]) }
        expect(engine.results.isEmpty)
    },
    test("rules can read other shapes through the context") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), Rules { r in
            r.validate(Tag.self) { tag, context in
                tag.props.target.flatMap { context.shape($0) } == nil ? [.error("dangling")] : []
            }
        }])
        let box = h.add(Box(.zero))
        let tag = h.add(Tag(target: box))
        expect(h.editor.validation?.result(for: tag) == nil)
        h.editor.transact { $0.delete([box]) }
        expectEqual(h.editor.validation?.result(for: tag)?.issues.map(\.message), ["dangling"])
    },
    test("after a change, only the shapes it touched are checked again, and those whose rules looked one of them up") {
        calls = 0
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), Rules { r in
            r.validate(Tag.self) { tag, context in
                calls += 1
                guard let box = tag.props.target.flatMap({ context.shape($0)?.box }) else { return [.error("dangling")] }
                return box.isEmpty ? [.warning("empty target")] : []
            }
        }])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let other = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let tag = h.add(Tag(target: box))
        let engine = try require(h.editor.validation)
        expect(engine.result(for: tag) == nil)
        expectEqual(calls, 1)
        h.editor.transact { $0.update(other, as: Box.self) { $0.frame.size = .zero } }
        _ = engine.results
        expectEqual(calls, 1, "the tag's rule never looked at the other box")
        h.editor.transact { $0.update(box, as: Box.self) { $0.frame.size = .zero } }
        expectEqual(engine.result(for: tag)?.issues.map(\.message), ["empty target"])
        expectEqual(calls, 2)
        h.editor.transact { $0.update(tag, as: Tag.self) { $0.props.target = other } }
        expectEqual(engine.result(for: tag)?.issues.map(\.message), ["empty target"], "the other box is empty too")
        expectEqual(calls, 3)
        h.editor.transact { $0.update(box, as: Box.self) { $0.frame.size = CGSize(width: 5, height: 5) } }
        _ = engine.results
        expectEqual(calls, 3, "the tag no longer looks at the first box")
    },
    test("a move runs no rule that ignores moves again, of what moved or of what looked it up; the others run, and the issues keep their order") {
        var runs: [String: Int] = [:]
        var watched: ShapeID?
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), Rules { r in
            r.validate(Box.self) { box, _ in
                runs["placed", default: 0] += 1
                return box.frame.minX < 0 ? [.warning("left of the origin")] : []
            }
            r.validate(Box.self, ignoringMoves: true) { box, _ in
                runs["steady", default: 0] += 1
                return box.frame.width < 20 ? [.warning("narrow")] : []
            }
            r.validate(Tag.self, ignoringMoves: true) { tag, context in
                runs["tag", default: 0] += 1
                return tag.props.target.flatMap { context.shape($0) } == nil ? [.error("dangling")] : []
            }
            r.validate(Disc.self) { _, context in
                runs["disc", default: 0] += 1
                return watched.flatMap { context.shape($0)?.box }.map { $0.minX < 0 ? [.warning("watching a box left of the origin")] : [] } ?? []
            }
        }])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        watched = box
        let tag = h.add(Tag(target: box))
        let disc = h.add(Disc(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let engine = try require(h.editor.validation)
        expectEqual(engine.result(for: box)?.issues.map(\.message), ["narrow"])
        expectEqual(runs, ["placed": 1, "steady": 1, "tag": 1, "disc": 1])
        expectEqual(engine.dependents(of: [box]), [tag, disc], "both looked it up")
        // Moved: the box's rule that reads where it is runs, and the disc's, which looked it up;
        // the box's other rule and the tag's keep what they found.
        h.editor.transact { $0.moveBox(box, to: CGPoint(x: -5, y: 0)) }
        expectEqual(engine.result(for: box)?.issues.map(\.message), ["left of the origin", "narrow"], "in the rules' order")
        expectEqual(engine.result(for: disc)?.issues.map(\.message), ["watching a box left of the origin"])
        expectEqual(runs, ["placed": 2, "steady": 1, "tag": 1, "disc": 2])
        h.editor.transact { $0.moveBox(box, to: CGPoint(x: -8, y: 0)) }
        expectEqual(engine.result(for: box)?.issues.map(\.message), ["left of the origin", "narrow"])
        expectEqual(runs, ["placed": 3, "steady": 1, "tag": 1, "disc": 3])
        // Changed otherwise, every rule runs, and the tag's too.
        h.editor.transact { $0.update(box, as: Box.self) { $0.frame.size.width = 30 } }
        expectEqual(engine.result(for: box)?.issues.map(\.message), ["left of the origin"])
        expectEqual(runs, ["placed": 4, "steady": 2, "tag": 2, "disc": 4])
        // Moved back: what the rule that ignores moves found (nothing, now) still holds.
        h.editor.transact { $0.moveBox(box, to: .zero) }
        expectEqual(engine.result(for: box), nil)
        expectEqual(runs, ["placed": 5, "steady": 2, "tag": 2, "disc": 5])
        // Deleted, the tag's rule runs again (it looked the box up), and finds it gone.
        h.editor.transact { $0.delete([box]) }
        expectEqual(engine.result(for: tag)?.issues.map(\.message), ["dangling"])
        expectEqual(runs["tag"], 3)
    },
    test("a shape's dependents are the shapes whose rules looked it up when they were last checked") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), Rules { r in
            r.validate(Tag.self) { tag, context in
                tag.props.target.flatMap { context.shape($0) } == nil ? [.error("dangling")] : []
            }
        }])
        let box = h.add(Box(.zero)), other = h.add(Box(.zero))
        let tag = h.add(Tag(target: box))
        let engine = try require(h.editor.validation)
        _ = engine.results
        expectEqual(engine.dependents(of: [box]), [tag])
        expectEqual(engine.dependents(of: [other, tag]), [])
        h.editor.transact { $0.update(tag, as: Tag.self) { $0.props.target = other } }
        h.editor.transact { $0.update(box, as: Box.self) { $0.frame.size.width = 5 } }
        // Unread since: the lookups are the ones the last check made, which is what a service asks
        // about as it hears of a commit, before anything reads.
        expectEqual(engine.dependents(of: [box]), [tag])
        _ = engine.results
        expectEqual(engine.dependents(of: [box]), [])
        expectEqual(engine.dependents(of: [box, other]), [tag])
    },
    test("a shape's issues, as the engine finds them, for a shape on the board or not, against the shapes they're asked with") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), Rules { r in
            r.declare(Motto.self)
            r.optIn(Box.self, to: Motto.self)
            r.validate(Box.self) { box, _ in box.frame.isEmpty ? [.warning("empty box")] : [] }
            r.validate(Tag.self) { tag, context in
                tag.props.target.flatMap { context.shape($0) } == nil ? [.error("dangling")] : []
            }
            r.validateEveryShape { _, _ in [.warning("every")] }
        }])
        let registry = h.editor.registry, engine = try require(h.editor.validation)
        let box = h.add(Box(.zero))
        h.editor.transact { $0.update(box) { $0[Motto.self] = "Carpe diem" } }
        let onBoard = try require(h.editor.document[box])
        let issues = registry.validationIssues(of: onBoard, in: h.editor.shapeContext)
        expectEqual(issues.map(\.message), ["empty box", "Motto is 10 characters long, and should be at most 5.", "every"],
                    "every rule for the kind, in order, the schema's too")
        expectEqual(issues, engine.result(for: box)?.issues, "as the engine has them")
        // A tag and the box it names, neither on the board: looked up in the shapes it's asked with.
        let crate = AnyShapeRecord(ShapeRecord(Box(CGRect(x: 0, y: 0, width: 10, height: 10))))
        let tag = AnyShapeRecord(ShapeRecord(Tag(target: crate.id)))
        expectEqual(registry.validationIssues(of: tag, in: h.editor.shapeContext).map(\.message), ["dangling", "every"])
        let planned = ShapeContext(document: CanvasDocument(shapes: h.editor.document.shapes + [crate, tag]), registry: registry)
        expectEqual(registry.validationIssues(of: tag, in: planned).map(\.message), ["every"])
        expectEqual(engine.dependents(of: [crate.id]), [], "the engine heard nothing of it")
    },
    test("contributing a rule without the validation plugin installed is an error") {
        expectThrows(RegistryError.ownerNotInstalled(point: "ValidationRules", owner: .validation, contributor: "rules")) {
            _ = try Registry(plugins: [FixturesPlugin(), Rules { r in r.validate(Box.self) { _, _ in [] } }])
        }
    },
    test("the overlay outlines a flagged shape 3 view points outside it, colored by the worst issue") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), Rules { r in
            r.validate(Box.self) { box, _ in
                switch box.frame.minX {
                case ..<100: [.warning("left"), .warning("again")]
                case ..<200: [.warning("middle"), .error("right")]
                default: []
                }
            }
        }])
        h.add(Box(CGRect(x: 40, y: 40, width: 40, height: 40)))
        h.add(Box(CGRect(x: 140, y: 40, width: 40, height: 40)))
        h.add(Box(CGRect(x: 240, y: 40, width: 40, height: 40)))
        h.editor.camera = Camera(origin: .zero, zoom: 2)
        let rep = renderBitmap(h.editor, size: CGSize(width: 600, height: 200))
        // Each box's top edge, 3 pt out. Orange and red differ in green: about 141 and 56.
        let warning = pixel(rep, at: CGPoint(x: 60 * 2, y: 40 * 2 - 3))
        let error = pixel(rep, at: CGPoint(x: 160 * 2, y: 40 * 2 - 3))
        let clean = pixel(rep, at: CGPoint(x: 260 * 2, y: 40 * 2 - 3))
        expect(warning[0] > 200 && warning[1] > 110 && warning[2] < 100, "orange outline: \(warning)")
        expect(error[0] > 200 && error[1] < 100 && error[2] < 100, "red outline: \(error)")
        expect(clean[0] < 250 && abs(clean[0] - clean[2]) < 10, "no outline: \(clean)")
    },
    test("the ring of a stretch follows the frame it is laid out in: on the grown part's top edge, and moved with the gauge, with no commit of the stretch's") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), StretchesPlugin(), ValidationPlugin(), Rules { r in
            r.validate(Stretch.self) { _, _ in [.error("always")] }
        }])
        let gauge = h.add(CanvasTesting.Gauge(CGRect(x: 300, y: 200, width: 60, height: 40), width: 160, height: 60))
        h.add(Stretch(CGRect(x: 40, y: 40, width: 40, height: 40), gauge: gauge))              // laid out to x 200
        h.editor.camera = Camera(origin: .zero, zoom: 2)
        let size = CGSize(width: 800, height: 400)
        @MainActor func red(_ rep: NSBitmapImageRep, _ point: CGPoint) -> Bool {
            let p = pixel(rep, at: point)
            return p[0] > 200 && p[1] < 100 && p[2] < 100
        }
        let rep = renderBitmap(h.editor, size: size)
        expect(red(rep, CGPoint(x: 150 * 2, y: 40 * 2 - 3)), "the ring runs along the grown part's top edge: \(pixel(rep, at: CGPoint(x: 300, y: 77)))")
        expect(!red(rep, CGPoint(x: 250 * 2, y: 40 * 2 - 3)), "and stops at its laid-out right edge")
        h.editor.transact("Gauge") { $0.update(gauge, as: CanvasTesting.Gauge.self) { $0.props.width = 300 } }
        expect(red(renderBitmap(h.editor, size: size), CGPoint(x: 250 * 2, y: 40 * 2 - 3)), "and reaches the new one")
    },
    test("a closed shape's ring stands 3 view points outside the outline, which stands off its edge: 7 out at any zoom, clear of the outline's line; an open shape's is 3 out; it follows the standoff") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), LinksPlugin(), ValidationPlugin(), Rules { r in
            r.validate(Box.self) { _, _ in [.error("always")] }
            r.validate(Link.self) { _, _ in [.error("always")] }
        }])
        h.editor.outlineStandoff = 4                       // what ships: EditorHarness outlines on the edge
        let a = h.add(Box(CGRect(x: 40, y: 40, width: 40, height: 40)))
        let b = h.add(Box(CGRect(x: 140, y: 40, width: 40, height: 40)))
        h.add(Link(from: a, to: b))                        // the segment from (60, 60) to (160, 60)
        let size = CGSize(width: 400, height: 300)
        @MainActor func red(_ rep: NSBitmapImageRep, _ point: CGPoint) -> Bool {
            let p = pixel(rep, at: point)
            return p[0] > 200 && p[1] < 100 && p[2] < 100
        }
        for zoom: CGFloat in [1, 2] {
            h.editor.camera = Camera(origin: .zero, zoom: zoom)
            let rep = renderBitmap(h.editor, size: size)
            // The first box's top edge, 40 down, and the ring's line, 2 wide, centered 7 above it.
            let ring = CGPoint(x: 60 * zoom, y: 40 * zoom - 7)
            expect(red(rep, ring), "7 out at \(zoom * 100)%: \(pixel(rep, at: ring))")
            expect(!red(rep, CGPoint(x: 60 * zoom, y: 40 * zoom - 3)), "not where it would be on the shape's own outline")
            // A selection's outline (the hint, as it's drawn alike) is between, 4 out, and clear of it.
            h.editor.hintedShapeID = a
            let outlined = renderBitmap(h.editor, size: size)
            h.editor.hintedShapeID = nil
            expectEqual(pixel(outlined, at: ring), pixel(rep, at: ring), "the outline doesn't touch the ring, at \(zoom * 100)%")
            let line = CGPoint(x: 60 * zoom, y: 40 * zoom - 4)
            expect(pixel(outlined, at: line) != pixel(rep, at: line), "the outline's own line, 4 out, between the shape and its ring")
        }
        h.editor.camera = Camera(origin: .zero, zoom: 1)
        // The link has no inside to stand off from: its ring is 3 above its line, at y = 57, as it was.
        let rep = renderBitmap(h.editor, size: size)
        expect(red(rep, CGPoint(x: 110, y: 57)), "an open shape's ring, 3 out: \(pixel(rep, at: CGPoint(x: 110, y: 57)))")
        expect(!red(rep, CGPoint(x: 110, y: 53)), "not 7")
        // With no standoff the ring is 3 out of a box's edge again, and not where it was.
        h.editor.outlineStandoff = 0
        let bare = renderBitmap(h.editor, size: size)
        expect(red(bare, CGPoint(x: 60, y: 37)), "3 out, no standoff: \(pixel(bare, at: CGPoint(x: 60, y: 37)))")
        expect(!red(bare, CGPoint(x: 60, y: 33)), "and not 7")
    },
    test("a ring stands outside the rings of tinted outlines round its shape, 4 view points further out for each past the first, selected or not, in full and zoomed out; an open shape's is where it was") {
        let lit = Outlined()
        let h = try EditorHarness(plugins: [FixturesPlugin(), LinksPlugin(), ValidationPlugin(), Rules { r in
            r.validate(Box.self) { _, _ in [.error("always")] }
            r.validate(Link.self) { _, _ in [.error("always")] }
            r.outlines { _ in Outlines(shapes: lit.shapes, tinted: lit.tinted) }
        }])
        h.editor.outlineStandoff = 4                       // what ships: EditorHarness outlines on the edge
        let green = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1), magenta = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        let size = CGSize(width: 400, height: 300)
        /// What colors the rows `rows` of a column are: r for the ring (the error's red), g and m for the tints, . for none of them.
        @MainActor func column(_ rep: NSBitmapImageRep, x: CGFloat, rows: Range<Int>) -> String {
            String(rows.map { y -> Character in
                let p = pixel(rep, at: CGPoint(x: x, y: CGFloat(y)))
                if p[0] > 200 && p[1] < 100 && p[2] < 100 { return "r" }
                if p[1] > 200 && p[0] < 80 && p[2] < 80 { return "g" }
                if p[0] > 200 && p[2] > 200 && p[1] < 80 { return "m" }
                return "."
            })
        }
        let box = h.add(Box(CGRect(x: 40, y: 40, width: 40, height: 40)))
        for zoom: CGFloat in [1, 2] {
            h.editor.camera = Camera(origin: .zero, zoom: zoom)
            // Above the box's top edge, at 40 × zoom: the ring is 7 out, the outline 4 (the tint of a first ring), then 8, 12.
            let top = Int(40 * zoom), x = 60 * zoom
            @MainActor func rows() -> String { column(renderBitmap(h.editor, size: size), x: x, rows: top - 14..<top) }
            lit.tinted = []
            expectEqual(rows(), "......rr......", "no tint: the ring 7 out, at \(zoom * 100)%")
            lit.tinted = [TintedOutlines(color: green, shapes: [box])]
            expectEqual(rows(), "......rr.gg...", "one ring of tint, 4 out: the ring where it was, at \(zoom * 100)%")
            lit.tinted = [TintedOutlines(color: green, shapes: [box]), TintedOutlines(color: magenta, shapes: [box], ring: 1)]
            expectEqual(rows(), "..rr.mm..gg...", "two lights: the second's ring 8 out, so the ring 11 out, at \(zoom * 100)%")
            // Selected, the one light's tint stands a ring further out, and the ring with it.
            lit.tinted = [TintedOutlines(color: green, shapes: [box])]
            lit.shapes = [box]
            // (The selection's own line is 4 out, over where the tint was, in the accent color.)
            expectEqual(String(rows().prefix(9)), "..rr.gg..", "selected: its tint 8 out, the ring 11 out, at \(zoom * 100)%")
            lit.shapes = []
        }
        // Zoomed out: the ring is 3 out of the frame, and 7 with a second ring of tint, which is 4 out.
        let big = h.add(Box(CGRect(x: 200, y: 200, width: 500, height: 300)))
        h.editor.camera = Camera(origin: .zero, zoom: 0.2)             // (40, 40) to (140, 100)
        expect(h.editor.drawsSkeletons)
        h.editor.transact { $0.delete([box]) }
        lit.tinted = []
        expectEqual(column(renderBitmap(h.editor, size: size), x: 80, rows: 28..<44), "........rr......", "zoomed out, the ring 3 out of the frame")
        lit.tinted = [TintedOutlines(color: green, shapes: [big]), TintedOutlines(color: magenta, shapes: [big], ring: 1)]
        expectEqual(column(renderBitmap(h.editor, size: size), x: 80, rows: 28..<44), "....rr.mm..gg...", "with two rings of tint, 7 out, outside them")
        // An open shape has no ring of tint: its ring is 3 above its line, as it was, tinted or not.
        let a = h.add(Box(CGRect(x: 100, y: 300, width: 40, height: 40)))
        let b = h.add(Box(CGRect(x: 200, y: 300, width: 40, height: 40)))
        let link = h.add(Link(from: a, to: b))
        h.editor.camera = Camera(origin: .zero, zoom: 1)
        lit.tinted = [TintedOutlines(color: green, shapes: [link]), TintedOutlines(color: magenta, shapes: [link], ring: 1)]
        lit.shapes = [link]
        let line = column(renderBitmap(h.editor, size: CGSize(width: 400, height: 400)), x: 180, rows: 310..<330)
        expectEqual(String(line.prefix(8)), "......rr", "the open shape's ring 3 above its line, which is at 320")
    },
    test("a shape just out of view has its ring drawn when the tinted rings round it reach it into view: the shapes looked at grow by how far they reach") {
        let lit = Outlined()
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), Rules { r in
            r.validate(Box.self) { _, _ in [.error("always")] }
            r.outlines { _ in Outlines(shapes: lit.shapes, tinted: lit.tinted) }
        }])
        h.editor.outlineStandoff = 4
        // Its right edge is 11 left of the view. Its ring is centered 7 out of that, 4 left of the view, with one ring of tint; with two
        // lights, 11 out, at x = 0, and in view (2 wide: pixel 0 is the ring's). It's only looked at if the shapes looked at are grown
        // by how far the tint pushes the ring out.
        let box = h.add(Box(CGRect(x: -51, y: 100, width: 40, height: 100)))
        let size = CGSize(width: 400, height: 300)
        @MainActor func edge() -> [Int] { pixel(renderBitmap(h.editor, size: size), at: CGPoint(x: 0, y: 150)) }
        lit.tinted = [TintedOutlines(color: .systemGreen, shapes: [box])]
        let one = edge()
        expect(!(one[0] > 200 && one[1] < 100 && one[2] < 100), "one ring: the ring is out of view, \(one)")
        lit.tinted = [TintedOutlines(color: .systemGreen, shapes: [box]), TintedOutlines(color: .systemPurple, shapes: [box], ring: 1)]
        let two = edge()
        expect(two[0] > 200 && two[1] < 100 && two[2] < 100, "two lights: the ring reaches into view, 11 out of the edge, at x = 0: \(two)")
    },
    test("a ring is grown again when the tinted rings round its shape change, and not while they stay") {
        #if DEBUG
        let lit = Outlined()
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), Rules { r in
            r.validate(Box.self) { _, _ in [.error("always")] }
            r.outlines { _ in Outlines(shapes: lit.shapes, tinted: lit.tinted) }
        }])
        let box = h.add(Box(CGRect(x: 40, y: 40, width: 40, height: 40)))
        let engine = try require(h.editor.validation)
        let size = CGSize(width: 200, height: 200)
        @MainActor func draw() { _ = renderBitmap(h.editor, size: size) }
        draw()
        expectEqual(engine.ringsGrown, 1)
        draw()
        expectEqual(engine.ringsGrown, 1, "kept")
        lit.tinted = [TintedOutlines(color: .systemGreen, shapes: [box]), TintedOutlines(color: .systemPurple, shapes: [box], ring: 1)]
        draw()
        expectEqual(engine.ringsGrown, 2, "grown again with a second ring of tint")
        draw()
        expectEqual(engine.ringsGrown, 2, "kept")
        lit.tinted = []
        draw()
        expectEqual(engine.ringsGrown, 3, "and again when it's gone")
        #endif
    },
    test("the shape being edited isn't outlined, since what it says is still being written; once editing ends, it is") {
        let h = try EditorHarness(plugins: [CardsPlugin(), ValidationPlugin(), Rules { r in
            r.validate(Card.self) { card, _ in card.props.text.isEmpty ? [.warning("empty")] : [] }
        }])
        let card = h.add(Card(CGRect(x: 40, y: 40, width: 40, height: 40)))
        let other = h.add(Card(CGRect(x: 140, y: 40, width: 40, height: 40)))
        let outlined = renderBitmap(h.editor, size: CGSize(width: 300, height: 200))
        expect(h.editor.beginEditing(card))
        let editing = renderBitmap(h.editor, size: CGSize(width: 300, height: 200))
        // Each card's top edge, 3 points out.
        let top = CGPoint(x: 60, y: 37), otherTop = CGPoint(x: 160, y: 37)
        expect(pixel(outlined, at: top)[0] > 200 && pixel(outlined, at: top)[2] < 100, "outlined before: \(pixel(outlined, at: top))")
        expect(pixel(editing, at: top)[2] > 200, "not while it's edited: \(pixel(editing, at: top))")
        expectEqual(pixel(editing, at: otherTop), pixel(outlined, at: otherTop), "the other card is still outlined")
        expectEqual(h.editor.validation?.result(for: card)?.issues.map(\.message), ["empty"], "its issues are still there")
        h.editor.endEditing()
        expectEqual(pixel(renderBitmap(h.editor, size: CGSize(width: 300, height: 200)), at: top), pixel(outlined, at: top))
    },
    test("the ring follows the shape's own outline, 3 view points out: a disc's is a circle, not its bounds' corners") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), Rules { r in
            r.validate(Disc.self) { _, _ in [.error("always")] }
        }])
        h.add(Disc(CGRect(x: 50, y: 50, width: 100, height: 100)))
        let rep = renderBitmap(h.editor, size: CGSize(width: 200, height: 200))
        @MainActor func red(_ point: CGPoint) -> Bool { let p = pixel(rep, at: point); return p[0] > 200 && p[1] < 150 && p[2] < 150 }
        // The circle's radius is 50; the ring's, 53, around (100, 100).
        expect(red(CGPoint(x: 100, y: 47)), "above the top, 3 out")
        expect(red(CGPoint(x: 153, y: 100)), "right of the right")
        let diagonal = 53 / CGFloat(2).squareRoot()
        expect(red(CGPoint(x: 100 - diagonal, y: 100 - diagonal)), "on the diagonal, where the circle is")
        expect(!red(CGPoint(x: 49, y: 49)) && !red(CGPoint(x: 48, y: 48)), "not at the bounds' corner: \(pixel(rep, at: CGPoint(x: 48, y: 48)))")
    },
    test("a shape small on screen is ringed by a rounded rect around its bounds; the ring is kept until the zoom changes by a tenth, or the shape changes") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), Rules { r in
            r.validate(Disc.self) { _, _ in [.error("always")] }
        }])
        let disc = h.add(Disc(CGRect(x: 50, y: 50, width: 100, height: 100)))
        let engine = try require(h.editor.validation)
        h.editor.skeletonZoom = 0                                // in full at 20%: zoomed out, a ring is a skeleton's (below)
        h.editor.camera = Camera(origin: .zero, zoom: 0.2)       // 20 points across
        let far = renderBitmap(h.editor, size: CGSize(width: 200, height: 200))
        // The disc is (10, 10) to (30, 30) on screen; the ring, 3 points out, a rounded rect from 7 to
        // 33, where a circle's would be 13 from (20, 20).
        let edge = pixel(far, at: CGPoint(x: 12, y: 7)), corner = pixel(far, at: CGPoint(x: 8, y: 8))
        expect(edge[0] > 200 && edge[1] < 150, "along the bounds' top: \(edge)")
        expect(corner[0] > 200 && corner[1] < 215, "by the bounds' corner, rounded a little: \(corner)")
        #if DEBUG
        expectEqual(engine.ringsGrown, 0, "nothing grown")
        h.editor.camera = Camera(origin: .zero, zoom: 1)
        _ = renderBitmap(h.editor, size: CGSize(width: 200, height: 200))
        expectEqual(engine.ringsGrown, 1)
        _ = renderBitmap(h.editor, size: CGSize(width: 200, height: 200))
        expectEqual(engine.ringsGrown, 1, "kept")
        h.editor.camera = Camera(origin: CGPoint(x: 10, y: 0), zoom: 1)
        _ = renderBitmap(h.editor, size: CGSize(width: 200, height: 200))
        expectEqual(engine.ringsGrown, 1, "kept as the camera pans")
        h.editor.camera = Camera(origin: .zero, zoom: 1.08)
        _ = renderBitmap(h.editor, size: CGSize(width: 200, height: 200))
        expectEqual(engine.ringsGrown, 1, "kept through a zoom's frames within a tenth of it")
        h.editor.camera = Camera(origin: .zero, zoom: 1.5)
        _ = renderBitmap(h.editor, size: CGSize(width: 200, height: 200))
        expectEqual(engine.ringsGrown, 2, "grown again at another zoom")
        h.editor.transact { $0.update(disc, as: Disc.self) { $0.frame.size.width = 120 } }
        _ = renderBitmap(h.editor, size: CGSize(width: 200, height: 200))
        expectEqual(engine.ringsGrown, 3, "and for the shape changed")
        h.editor.transact { $0.delete([disc]) }
        _ = renderBitmap(h.editor, size: CGSize(width: 200, height: 200))
        expectEqual(engine.ringsKept, 0, "dropped once it has no issues")
        #endif
    },
    test("the outline goes where its shape is drawn (a shake)") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), Rules { r in
            r.validate(Box.self) { _, _ in [.error("always")] }
        }])
        let box = h.add(Box(CGRect(x: 40, y: 40, width: 40, height: 40)))
        let still = renderBitmap(h.editor, size: CGSize(width: 200, height: 200))
        h.editor.setDrawingOffset(CGPoint(x: 10, y: 0), for: box)
        let moved = renderBitmap(h.editor, size: CGSize(width: 200, height: 200))
        // The top edge's outline, 3 points out, and the left one.
        for point in [CGPoint(x: 60, y: 37), CGPoint(x: 37, y: 60)] {
            expectEqual(pixel(moved, at: CGPoint(x: point.x + 10, y: point.y)), pixel(still, at: point), "\(point)")
        }
    },
    test("in full, rings that cross are stroked as they always were, the line width and join now set once for all: a front shape's over a back one's, whatever their colors") {
        // An error at A, crossed by a warning at B in front of it, which a warning at C in front of
        // it crosses: each crossing on straight edges, on whole points, so no edge is antialiased.
        let a = CGRect(x: 40, y: 40, width: 100, height: 60), b = CGRect(x: 100, y: 80, width: 100, height: 60)
        let c = CGRect(x: 160, y: 120, width: 80, height: 60)
        let severity: @MainActor (AnyShapeRecord) -> Severity? = { $0.box?.minX == a.minX ? .error : .warning }
        let rules = Rules { r in r.validate(Box.self) { box, _ in [ValidationIssue("flagged", severity: box.frame.minX == a.minX ? .error : .warning)] } }
        let shipped = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), rules])
        let alone = try EditorHarness(plugins: [FixturesPlugin(), Rules("one-at-a-time") { $0.overlay(OneAtATime(severity: severity)) }])
        var ids: [[ShapeID]] = []
        for h in [shipped, alone] { ids.append([a, b, c].map { h.add(Box($0)) }) }
        let size = CGSize(width: 300, height: 220)
        let crossings = [CGPoint(x: 97, y: 103), CGPoint(x: 143, y: 77), CGPoint(x: 203, y: 117), CGPoint(x: 157, y: 143)]
        let front = pixel(renderBitmap(shipped.editor, size: size), at: crossings[0])
        expect(front[1] > 110, "B's orange over A's red: \(front)")
        expectEqual(changedPixels(renderBitmap(shipped.editor, size: size), renderBitmap(alone.editor, size: size),
                                  in: CGRect(origin: .zero, size: size)), 0, "as one at a time")
        for (h, shapes) in zip([shipped, alone], ids) { h.editor.transact { $0.bringToFront(shapes[0]) } }
        let raised = pixel(renderBitmap(shipped.editor, size: size), at: crossings[0])
        expect(raised[1] < 100, "A's red, brought to the front: \(raised)")
        expectEqual(changedPixels(renderBitmap(shipped.editor, size: size), renderBitmap(alone.editor, size: size),
                                  in: CGRect(origin: .zero, size: size)), 0, "as one at a time, A in front")
    },
    test("zoomed out, where shapes are skeletons, the outline stays, square-cornered, grown from no outline, and a front shape's is over a back one's") {
        // As the crossing test above, at 20%: each box 5 times as big, so its outline is where it is there.
        let a = CGRect(x: 200, y: 200, width: 500, height: 300), b = CGRect(x: 500, y: 400, width: 500, height: 300)
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), Rules { r in
            r.validate(Box.self) { box, _ in [ValidationIssue("flagged", severity: box.frame.minX == a.minX ? .error : .warning)] }
        }])
        let back = h.add(Box(a))
        h.add(Box(b))
        h.editor.camera = Camera(origin: .zero, zoom: 0.2)                         // A from (40, 40), B from (100, 80), in view
        expect(h.editor.drawsSkeletons)
        let size = CGSize(width: 300, height: 220)
        var rep = renderBitmap(h.editor, size: size)
        let error = pixel(rep, at: CGPoint(x: 80, y: 37)), corner = pixel(rep, at: CGPoint(x: 37, y: 37))
        expect(error[0] > 200 && error[1] < 100 && error[2] < 100, "A's red outline: \(error)")
        expectEqual(corner, error, "its corner square")
        let inside = pixel(rep, at: CGPoint(x: 60, y: 60))
        expect(inside[1] > 100, "hollow: \(inside)")
        expect(pixel(rep, at: CGPoint(x: 97, y: 103))[1] > 110, "B's orange over A's red where they cross")
        h.editor.transact { $0.bringToFront(back) }
        rep = renderBitmap(h.editor, size: size)
        expect(pixel(rep, at: CGPoint(x: 97, y: 103))[1] < 100, "A's red, brought to the front")
        #if DEBUG
        expectEqual(h.editor.validation?.ringsGrown, 0, "no ring grown from an outline, though each shape is 100 points across")
        #endif
    },
    test("zoomed out, the shape being edited has no ring, and the ring of a shape under it shows where the two crossed") {
        // As above, but cards, and B, in front, being edited: A's is a ring, B has none.
        let a = CGRect(x: 200, y: 200, width: 500, height: 300), b = CGRect(x: 500, y: 400, width: 500, height: 300)
        let h = try EditorHarness(plugins: [CardsPlugin(), ValidationPlugin(), Rules { r in
            r.validate(Card.self) { card, _ in [ValidationIssue("flagged", severity: card.frame.minX == a.minX ? .error : .warning)] }
        }])
        h.add(Card(a))
        let edited = h.add(Card(b))
        h.editor.camera = Camera(origin: .zero, zoom: 0.2)
        let size = CGSize(width: 300, height: 220)
        let before = renderBitmap(h.editor, size: size)
        expect(h.editor.beginEditing(edited))
        let rep = renderBitmap(h.editor, size: size)
        let error = pixel(rep, at: CGPoint(x: 80, y: 37))
        expect(error[0] > 200 && error[1] < 100 && error[2] < 100, "A's red outline: \(error)")
        expectEqual(pixel(rep, at: CGPoint(x: 37, y: 37)), error, "A's corner square: a ring")
        // B's top edge, 3 points out.
        let warning = pixel(before, at: CGPoint(x: 150, y: 77))
        expect(warning[0] > 200 && warning[1] > 110 && warning[2] < 100, "B's orange ring before it's edited: \(warning)")
        expect(pixel(rep, at: CGPoint(x: 150, y: 77))[2] > 200, "none while it's edited: \(pixel(rep, at: CGPoint(x: 150, y: 77)))")
        let crossing = pixel(rep, at: CGPoint(x: 97, y: 103))
        expect(crossing[0] > 200 && crossing[1] < 100, "A's red ring where B's crossed it: \(crossing)")
    },
])
