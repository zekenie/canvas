import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import DetailPanel
import Foundation
import Geometry
import Mentions
import Selection
import TestKit
import Types

// An arrow that is an end of a relationship type is half of one line through the type's pill: car ——[owner]——> person. No head at the
// pill, no words, and, with the one end on each side and their far ends on two different shapes, each half its part of the circle
// through the far end of one, the pill's middle and the far end of the other (`ArrowThrough`, pure; the geometry's `EndLine`), so a type
// moved, or the pill dragged off the line, bends the line smoothly through the pill. Plain arrows are untouched.

private func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.01) -> Bool { abs(a - b) <= tolerance }

/// Car on the left, person on the right and the relationship type `owner` between them, a level line apart: an arrow from car into
/// the type (a from end) and one out of it to person (a to end), all bound at their middles.
@MainActor
private struct EndBoard {
    let h: EditorHarness
    let car: ShapeID, person: ShapeID, hub: ShapeID
    let into: ShapeID, out: ShapeID

    init(words: String = "") throws {
        h = try EditorHarness(plugins: arrowsPlugins(more: [PortsPlugin(), ArrowPortsPlugin(), DetailPanelPlugin(), LabelFixturesPlugin()]))
        car = h.editor.addType("car", at: CGRect(x: 0, y: 270, width: 200, height: 60))
        person = h.editor.addType("person", at: CGRect(x: 800, y: 270, width: 200, height: 60))
        let made = h.editor.addType("owner", at: CGRect(x: 400, y: 270, width: 200, height: 60))
        h.editor.transact { $0.update(made) { $0[RelationshipProperty.self] = true } }
        hub = made
        into = h.add(Arrow(start: Self.bound(car), end: Self.bound(hub), text: MentionText(plain: words)))
        out = h.add(Arrow(start: Self.bound(hub), end: Self.bound(person), text: MentionText(plain: words)))
    }

    static func bound(_ id: ShapeID) -> ArrowTerminal {
        .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
    }

    var editor: CanvasEditor { h.editor }
    func geometry(_ id: ShapeID) -> ArrowGeometry? { editor.arrowGeometry(of: id) }
    func middle(of id: ShapeID) -> CGPoint? { editor.shapeContext.frame(of: id).map { CGPoint(x: $0.midX, y: $0.midY) } }

    /// Moves a shape so its frame's middle is at `point`.
    func move(_ id: ShapeID, toMiddle point: CGPoint) {
        guard let now = middle(of: id) else { return }
        editor.transact("Move") { $0.translate([id], by: point - now) }
    }

    /// The circle through the middles of car, the pill and person.
    func circle() -> Arc? {
        guard let a = middle(of: car), let b = middle(of: hub), let c = middle(of: person) else { return nil }
        return Arc(from: a, through: b, to: c)
    }

    var isStraight: Bool {
        [into, out].allSatisfy { if case .straight? = geometry($0)?.path { true } else { false } }
    }
}

@MainActor let endLineTests = Suite("An arrow that is an end of a relationship type", [
    test("ArrowThrough: each half takes its part of the circle through the three points, either way round, on the side away from the other far end") {
        for (hub, name) in [(CGPoint(x: 100, y: 40), "above"), (CGPoint(x: 100, y: -40), "below"), (CGPoint(x: 30, y: 25), "nearer the first")] {
            let first = CGPoint(x: 0, y: 0), last = CGPoint(x: 200, y: 0)
            let circle = try require(Arc(from: first, through: hub, to: last), name)
            for (start, end, third) in [(first, hub, last), (hub, last, first), (hub, first, last), (last, hub, first)] {
                let bend = ArrowThrough.bend(from: start, to: end, awayFrom: third)
                let middle = (start + end) / 2, axis = (end - start).normalized.perpendicular
                let arc = try require(Arc(from: start, through: middle + axis * bend, to: end), "\(name): \(start) to \(end)")
                expect(arc.center.distance(to: circle.center) < 0.001, "\(name): the circle of the three, centre \(arc.center) for \(circle.center)")
                expect(near(arc.radius, circle.radius, 0.001), "\(name): its radius")
                expect(arc.parameter(of: third) == nil, "\(name): the arc from \(start) to \(end) leaves out \(third)")
            }
            expectEqual(ArrowThrough.bend(from: first, to: hub, awayFrom: last), -ArrowThrough.bend(from: hub, to: first, awayFrom: last), "\(name): an arrow the other way bends the other way")
        }
        // Mirrored, the bends are: a far end on the other side of the line bends them the other way.
        let up = ArrowThrough.bend(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 40), awayFrom: CGPoint(x: 200, y: 0))
        let down = ArrowThrough.bend(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: -40), awayFrom: CGPoint(x: 200, y: 0))
        expect(near(up, -down, 0.0001) && up != 0, "mirrored: \(up) and \(down)")
    },
    test("ArrowThrough: straight within a quarter of a unit of the line, a zero bend there, and a bend, however small, past it") {
        let first = CGPoint(x: 0, y: 0), last = CGPoint(x: 400, y: 0)
        expect(ArrowThrough.isStraight(first, hub: CGPoint(x: 200, y: 0), last))
        expect(ArrowThrough.isStraight(first, hub: CGPoint(x: 200, y: 0.2), last))
        expect(ArrowThrough.isStraight(first, hub: CGPoint(x: 120, y: -0.2), last))
        expect(!ArrowThrough.isStraight(first, hub: CGPoint(x: 200, y: 0.3), last))
        expect(ArrowThrough.isStraight(first, hub: CGPoint(x: 5, y: 3), first), "both far ends one point: nothing to bend")
        expectEqual(ArrowThrough.bend(from: first, to: CGPoint(x: 200, y: 0), awayFrom: last), 0, "on a line")
        let nearly = ArrowThrough.bend(from: first, to: CGPoint(x: 200, y: 0.3), awayFrom: last)
        expect(nearly != 0 && abs(nearly) < 0.2, "nearly: \(nearly)")
        expectEqual(ArrowThrough.bend(from: first, to: first, awayFrom: last), 0, "no chord, no bend")
    },
    test("no head at the pill whatever the arrow stores, and the head at the other end stays; the stored flags are left as they are") {
        let b = try EndBoard()
        let into = try require(b.geometry(b.into)), out = try require(b.geometry(b.out))
        expect(!into.endArrowhead && !into.startArrowhead, "the arrow into the pill: no head at it")
        expect(!out.startArrowhead && out.endArrowhead, "the arrow out of it: the head at person")
        expectEqual(b.editor.document[b.into]?.typed(as: Arrow.self)?.props.endArrowhead, true, "stored as it was")
        // Both stored heads on: still none at the pill.
        b.editor.transact { transaction in
            transaction.update(b.out, as: Arrow.self) { $0.props.startArrowhead = true }
            transaction.update(b.into, as: Arrow.self) { $0.props.startArrowhead = true }
        }
        expect(try require(b.geometry(b.out)).startArrowhead == false && b.geometry(b.out)?.endArrowhead == true)
        expect(try require(b.geometry(b.into)).startArrowhead == true && b.geometry(b.into)?.endArrowhead == false)
    },
    test("no words: no label, no cut and nothing drawn, whatever they say; the words are kept") {
        let said = try EndBoard(words: "owner of"), silent = try EndBoard()
        for id in [said.into, said.out] {
            expectEqual(said.editor.arrowLabelFrame(of: id), nil, "no label")
            expectEqual(said.editor.shapeContext.geometry(of: id)?.label, nil)
            expectEqual(said.editor.document[id]?.typed(as: Arrow.self)?.props.text.stored, "owner of", "kept")
        }
        let size = CGSize(width: 1100, height: 700)
        let a = renderBitmap(said.editor, size: size), b = renderBitmap(silent.editor, size: size)
        // Where the lines run (the types' own pills above them are beside the point).
        let lines = CGRect(x: 0, y: 265, width: 1100, height: 70)
        expect(changedPixels(a, b, in: lines) == 0, "drawn the same as with no words")
        // The same at any distance: zoomed out, where the skeleton leaves a label off anyway, nothing differs.
        said.editor.camera = Camera(origin: .zero, zoom: 0.3)
        silent.editor.camera = Camera(origin: .zero, zoom: 0.3)
        expect(changedPixels(renderBitmap(said.editor, size: size), renderBitmap(silent.editor, size: size), in: CGRect(x: 0, y: 70, width: 330, height: 40)) == 0)
    },
    test("with the pill on the line between the two types, each half is a straight line; the stored bend is not read") {
        let b = try EndBoard()
        expect(b.isStraight)
        let into = try require(b.geometry(b.into)), out = try require(b.geometry(b.out))
        expect(near(into.start.y, 300) && near(into.end.y, 300) && near(out.start.y, 300) && near(out.end.y, 300), "level")
        b.editor.transact { transaction in
            for id in [b.into, b.out] { transaction.update(id, as: Arrow.self) { $0.props.bend = 90 } }
        }
        expect(b.isStraight, "a stored bend is a person's for an arrow that stands alone")
    },
    test("a far type moved: the pill stays where it is, and both halves are parts of the circle through the three middles, meeting at the pill with no corner") {
        let b = try EndBoard()
        let pill = try require(b.middle(of: b.hub))
        for target in [CGPoint(x: 900, y: 80), CGPoint(x: 900, y: 600), CGPoint(x: 700, y: 300), CGPoint(x: 1300, y: 500)] {
            b.move(b.person, toMiddle: target)
            expectEqual(b.middle(of: b.hub), pill, "the pill stays")
            guard let circle = b.circle() else {
                expect(b.isStraight, "\(target): on a line, straight")
                continue
            }
            for id in [b.into, b.out] {
                let body = try require(b.geometry(id)).body
                for t: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
                    let point = body.point(at: t)
                    expect(near(point.distance(to: circle.center), circle.radius, 0.05), "\(target): \(t) along the half from \(id) is on the circle: \(point.distance(to: circle.center)) for \(circle.radius)")
                }
            }
            // Smooth at the pill: leaving it one way is the tangent of arriving the other way.
            let arriving = try require(b.geometry(b.into)).directionFromHandle(at: .end), leaving = try require(b.geometry(b.out)).directionFromHandle(at: .start)
            expect((arriving + leaving).length < 1e-6, "\(target): no corner at the pill: \(arriving) and \(leaving)")
            expect(!b.isStraight, "\(target): curved")
        }
    },
    test("the far end on the other side of the pill bends the line the other way") {
        let b = try EndBoard()
        b.move(b.person, toMiddle: CGPoint(x: 900, y: 80))
        let above = try require(b.geometry(b.out)).middle
        b.move(b.person, toMiddle: CGPoint(x: 900, y: 520))
        let below = try require(b.geometry(b.out)).middle
        // The chord to the far end rises the first time and falls the second; the pill is between: the bow is on opposite sides of the chord.
        expect(above.y < 300 && below.y > 300, "\(above), \(below)")
    },
    test("the pill dragged off the line bends it, through the pill; dragged back onto it, it is straight again") {
        let b = try EndBoard()
        b.move(b.hub, toMiddle: CGPoint(x: 500, y: 150))
        expect(!b.isStraight)
        let circle = try require(b.circle())
        for id in [b.into, b.out] {
            let body = try require(b.geometry(id)).body
            for t: CGFloat in [0.2, 0.5, 0.8] {
                expect(near(body.point(at: t).distance(to: circle.center), circle.radius, 0.05), "on the circle through the pill")
            }
        }
        b.move(b.hub, toMiddle: CGPoint(x: 500, y: 300))
        expect(b.isStraight)
        b.move(b.hub, toMiddle: CGPoint(x: 500, y: 300.1))
        expect(b.isStraight, "within a quarter of a unit")
    },
    test("a side with two types, or a type related to itself, or an end free at its far end: each half keeps its own stored geometry, with no head at the pill and no words") {
        let b = try EndBoard()
        let company = b.editor.addType("company", at: CGRect(x: 0, y: 600, width: 200, height: 60))
        let third = b.h.add(Arrow(start: EndBoard.bound(company), end: EndBoard.bound(b.hub), bend: 60))
        // What each is, drawn as today's code draws an arrow: the same arrow bound to a box (no type, so no end) where the pill is, its
        // head at that end left off.
        let hubFrame = try require(b.editor.shapeContext.frame(of: b.hub))
        let twin = b.h.add(Box(hubFrame))
        @MainActor func expectOwn(_ id: ShapeID, _ message: String) throws {
            var plain = try require(b.editor.document[id]?.typed(as: Arrow.self)?.props)
            func retarget(_ end: ArrowEnd) {
                guard case .bound(var binding) = plain[end], binding.shapeID == b.hub else { return }
                binding.shapeID = twin
                plain[end] = .bound(binding)
                if end == .start { plain.startArrowhead = false } else { plain.endArrowhead = false }
            }
            retarget(.start)
            retarget(.end)
            let copy = b.h.add(plain)
            let expected = try require(b.geometry(copy)), drawn = try require(b.geometry(id), message)
            expect(b.editor.relationships?.end(copy) == nil, "\(message): the copy is no end")
            expect(drawn.start.distance(to: expected.start) < 0.001 && drawn.end.distance(to: expected.end) < 0.001 && drawn.middle.distance(to: expected.middle) < 0.001,
                   "\(message): its own geometry")
            expectEqual(drawn.startArrowhead, expected.startArrowhead, message)
            expectEqual(drawn.endArrowhead, expected.endArrowhead, message)
            b.editor.transact("Delete the copy") { $0.delete([copy]) }
        }
        for (id, name) in [(b.into, "into"), (b.out, "out"), (third, "second from")] { try expectOwn(id, "two types on a side, \(name)") }
        expect(b.isStraight, "the stored bends of the first two were 0, and the third's 60 is its own")
        if case .curved? = b.geometry(third)?.path {} else { expect(false, "the third's stored bend is drawn") }
        // Delete the third: the line through the pill is one again.
        b.editor.transact("Delete") { $0.delete([third]) }
        b.move(b.person, toMiddle: CGPoint(x: 900, y: 600))
        expect(!b.isStraight, "back to one line through the pill")
        let circle = try require(b.circle())
        expect(near(try require(b.geometry(b.out)).body.point(at: 0.5).distance(to: circle.center), circle.radius, 0.05))
        // Re-aimed: the partner's far end moves to another shape, and the line goes through that.
        let other = b.editor.addType("other", at: CGRect(x: 800, y: 0, width: 200, height: 60))
        b.editor.transact("Re-aim") { $0.update(b.out, as: Arrow.self) { $0.props.end = EndBoard.bound(other) } }
        let moved = try require(Arc(from: try require(b.middle(of: b.car)), through: try require(b.middle(of: b.hub)), to: try require(b.middle(of: other))))
        expect(near(try require(b.geometry(b.into)).body.point(at: 0.5).distance(to: moved.center), moved.radius, 0.05), "the first half follows the partner's new far end")
        // Free at its far end: no arc.
        b.editor.transact("Free") { $0.update(b.out, as: Arrow.self) { $0.props.end = .free(CGPoint(x: 900, y: 40)) } }
        if case .straight? = b.geometry(b.out)?.path {} else { expect(false, "an end free at its far end keeps its own straight line") }
    },
    test("a type related to itself is two arrows, each its own: no line through the pill") {
        let b = try EndBoard()
        // Person's arrow back from the type goes to car: out of the type to the same shape the other comes from.
        b.editor.transact("Re-aim") { $0.update(b.out, as: Arrow.self) { $0.props.end = EndBoard.bound(b.car); $0.props.bend = 40 } }
        let own = try require(b.geometry(b.out))
        if case .curved = own.path {} else { expect(false, "its stored bend") }
        expect(!own.startArrowhead && own.endArrowhead)
        expect(try require(b.geometry(b.into)).endArrowhead == false)
        expect(near(try require(b.geometry(b.into)).middle.y, 300), "the first is as stored: straight")
    },
    test("a plain arrow is what it was: its geometry has every head and keeps no detail, and is drawn as one between two boxes is") {
        let b = try EndBoard()
        let plain = b.h.add(Arrow(start: EndBoard.bound(b.car), end: EndBoard.bound(b.person), bend: 50, startArrowhead: true))
        // The same arrow between two boxes, where no type is: the one tldraw's port works out from its record.
        let one = b.h.add(Box(try require(b.editor.shapeContext.frame(of: b.car)))), two = b.h.add(Box(try require(b.editor.shapeContext.frame(of: b.person))))
        let twin = b.h.add(Arrow(start: EndBoard.bound(one), end: EndBoard.bound(two), bend: 50, startArrowhead: true))
        let drawn = try require(b.geometry(plain)), expected = try require(b.geometry(twin))
        expectEqual(drawn.start, expected.start)
        expectEqual(drawn.end, expected.end)
        expectEqual(drawn.middle, expected.middle)
        expect(drawn.startArrowhead && drawn.endArrowhead)
        expect(b.editor.shapeContext.geometry(of: plain)?.detail == nil, "nothing kept")
        expect(b.editor.relationships?.end(plain) == nil, "between two types it is no end")
    },
    test("opening an end (a double-click, Return) opens the type's card at the row name that end gives, and edits nothing; any other arrow edits its label") {
        let b = try EndBoard()
        for id in [b.into, b.out] {
            b.editor.selection = id
            expect(b.editor.canOpen(id))
            expect(b.editor.open(id, clickCount: 2))
            expectEqual(b.editor.editingShapeID, nil, "no label to edit")
            expectEqual(b.editor.definitionCards?.openType, b.hub)
            expectEqual(b.editor.definitionCards?.openView?.focus, .endName(id))
            b.editor.closeCard()
        }
        let plain = b.h.add(Arrow(start: EndBoard.bound(b.car), end: EndBoard.bound(b.person)))
        expect(b.editor.open(plain))
        expectEqual(b.editor.editingShapeID, plain)
        expectEqual(b.editor.definitionCards?.openType, nil)
    },
    test("zoomed out, each half's skeleton follows the same arc, with no head at the pill and the head at person") {
        let b = try EndBoard()
        b.move(b.person, toMiddle: CGPoint(x: 900, y: 600))
        b.editor.camera = Camera(origin: .zero, zoom: 0.3)
        let size = CGSize(width: 330, height: 220)
        let drawn = renderBitmap(b.editor, size: size, scale: 4)
        // Along the arc through the three middles, inked.
        let circle = try require(b.circle())
        for id in [b.into, b.out] {
            let body = try require(b.geometry(id)).body
            for t: CGFloat in [0.25, 0.5, 0.75] {
                let point = body.point(at: t)
                expect(pixel(drawn, at: CGPoint(x: point.x * 0.3, y: point.y * 0.3), scale: 4).prefix(3).allSatisfy { $0 < 140 }, "the skeleton is drawn along the arc at \(t)")
                expect(near(point.distance(to: circle.center), circle.radius, 0.05))
            }
        }
        // The head at the pill is left off whatever is stored; the head at person is there.
        @MainActor func render(into head: Bool, out startHead: Bool) -> NSBitmapImageRep {
            b.editor.transact("Heads") {
                $0.update(b.into, as: Arrow.self) { $0.props.endArrowhead = head }
                $0.update(b.out, as: Arrow.self) { $0.props.startArrowhead = startHead }
            }
            return renderBitmap(b.editor, size: size, scale: 4)
        }
        let rect = CGRect(x: 0, y: 0, width: size.width * 4, height: size.height * 4)
        let withHeads = render(into: true, out: true), without = render(into: false, out: false)
        expect(changedPixels(withHeads, without, in: rect) == 0, "no head at the pill, stored or not")
        b.editor.transact("Heads") { $0.update(b.out, as: Arrow.self) { $0.props.endArrowhead = false } }
        expect(changedPixels(without, renderBitmap(b.editor, size: size, scale: 4), in: rect) > 0, "the head at person is drawn")
    },
])
