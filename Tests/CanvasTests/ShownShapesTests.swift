import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import TestKit

// A shape shown in another shape's place (`ShowingShapes`, `RenderContext.drawShape(inFile:through:standingIn:)`): drawn
// there by its own kind from any board, a container with what it holds, found under a point, and edited there, over
// CanvasTesting's lens, which shows a shape scaled into its box.

/// A box drawn blue, and red as a skeleton: which of the two a shape shown in another's place was drawn as.
struct Patch: BoxShapeProps {
    static let kind: ShapeKind = "patch"
    static let properties = Properties<Patch> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
}

extension Patch {
    init() { self.init(.zero) }
}

struct PatchDefinition {}

extension PatchDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Patch>, in context: RenderContext) {
        context.cg.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.cg.fill(shape.frame)
    }
}

extension PatchDefinition: CustomSkeleton {
    func renderSkeleton(_ shape: ShapeRecord<Patch>, in context: RenderContext) {
        context.cg.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.cg.fill(shape.frame)
    }
}

/// Every layout change services heard (`EditorService.shapesDidChangeLayout`).
@MainActor final class LayoutHearing {
    var heard: [Set<ShapeID>] = []
}

extension LayoutHearing: EditorService {
    func shapesDidChangeLayout(_ ids: Set<ShapeID>, in editor: CanvasEditor) { heard.append(ids) }
}

@MainActor private func shownHarness(log: LensLog = LensLog(), refusals: RefusalLog = RefusalLog(), hearing: LayoutHearing? = nil,
                                     root: [AnyShapeRecord], pocket: ShapeID, inside: [AnyShapeRecord]) throws -> EditorHarness {
    var plugins: [any CanvasPlugin] = [FixturesPlugin(), PocketsPlugin(), CorralsPlugin(), LensesPlugin(log: log), CardsPlugin(),
                                       FreezingPlugin(log: refusals), Contributor(id: "patches") { $0.shape(PatchDefinition()) }]
    if let hearing { plugins.append(Contributor(id: "hearing") { $0.service { _ in hearing } }) }
    return try EditorHarness(plugins: plugins, file: CanvasFile(root: CanvasDocument(shapes: ShapeStack(root)),
                                                                children: [pocket: CanvasDocument(shapes: ShapeStack(inside))]))
}

private func record<P: ShapeProps>(_ id: ShapeID, _ props: P) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, props)) }

private let lensFill = [217, 217, 217, 255]
private let canvas = [246, 246, 246, 255]

@MainActor let shownShapesTests = Suite("Shapes shown in another shape's place", [
    test("a lens draws a box on another board as the box draws itself, through its transform, and on the board shown the same way") {
        let lens = ShapeID(), pocket = ShapeID(), box = ShapeID(), reference = ShapeID(), here = ShapeID(), near = ShapeID()
        let log = LensLog()
        let h = try shownHarness(log: log, root: [
            record(pocket, Pocket(CGRect(x: -300, y: 0, width: 100, height: 100))),
            record(reference, Box(CGRect(x: 20, y: 300, width: 40, height: 40))),
            record(here, Box(CGRect(x: 600, y: 600, width: 100, height: 100))),
            record(lens, Lens(CGRect(x: 200, y: 200, width: 100, height: 100), shows: box, scale: 0.5)),
            record(near, Lens(CGRect(x: 0, y: 100, width: 100, height: 100), shows: here, origin: CGPoint(x: 600, y: 600), scale: 0.5)),
        ], pocket: pocket, inside: [record(box, Box(CGRect(x: 0, y: 0, width: 100, height: 100)))])
        let picture = renderBitmap(h.editor, size: CGSize(width: 400, height: 400))
        let gray = pixel(picture, at: CGPoint(x: 40, y: 320))
        expect(gray != canvas, "the reference box is drawn")
        expectEqual(pixel(picture, at: CGPoint(x: 225, y: 225)), gray, "the box at half its size at the lens's corner")
        expectEqual(pixel(picture, at: CGPoint(x: 280, y: 280)), lensFill, "past the half-size box, the lens")
        expectEqual(pixel(picture, at: CGPoint(x: 25, y: 125)), gray, "a box on the board shown, through another lens")
        expect(log.drawn.contains { $0.lens == lens && $0.shownThrough == nil && $0.showed }, "it showed the box")
    },
    test("a container is drawn with what it holds, at any depth, and nothing beside it, culled to the lens") {
        let lens = ShapeID(), pocket = ShapeID(), corral = ShapeID(), a = ShapeID(), b = ShapeID(), outside = ShapeID()
        let h = try shownHarness(root: [
            record(pocket, Pocket(CGRect(x: -300, y: 0, width: 100, height: 100))),
            record(lens, Lens(CGRect(x: 200, y: 200, width: 140, height: 100), shows: corral, origin: CGPoint(x: -80, y: 0), scale: 0.5)),
        ], pocket: pocket, inside: [
            record(outside, Box(CGRect(x: -60, y: 10, width: 50, height: 50))),
            record(corral, Corral(CGRect(x: 0, y: 0, width: 200, height: 200))),
            record(a, Box(CGRect(x: 10, y: 10, width: 50, height: 50))),
            record(b, Box(CGRect(x: 100, y: 100, width: 50, height: 50))),
        ])
        let board = BoardID(owner: pocket)
        h.editor.transact(on: board, "Hold") { $0.setContainer([a, b], to: corral) }
        let picture = renderBitmap(h.editor, size: CGSize(width: 400, height: 400))
        let gray = pixel(picture, at: CGPoint(x: 257, y: 217))
        expect(gray != lensFill, "the first box it holds")
        expectEqual(pixel(picture, at: CGPoint(x: 302, y: 262)), gray, "the second")
        expectEqual(pixel(picture, at: CGPoint(x: 330, y: 230)), [230, 230, 230, 255], "the corral's own fill between them")
        expectEqual(pixel(picture, at: CGPoint(x: 222, y: 217)), lensFill, "a box beside the corral, in the lens's view, isn't drawn")
    },
    test("nothing is drawn through two lenses: a lens a shown container holds is drawn plainly there") {
        let outer = ShapeID(), inner = ShapeID(), pocket = ShapeID(), corral = ShapeID(), box = ShapeID()
        let log = LensLog()
        let h = try shownHarness(log: log, root: [
            record(pocket, Pocket(CGRect(x: -300, y: 0, width: 100, height: 100))),
            record(outer, Lens(CGRect(x: 0, y: 0, width: 200, height: 200), shows: corral)),
        ], pocket: pocket, inside: [
            record(corral, Corral(CGRect(x: 0, y: 0, width: 200, height: 200))),
            record(inner, Lens(CGRect(x: 20, y: 20, width: 100, height: 100), shows: box)),
            record(box, Box(CGRect(x: 500, y: 500, width: 50, height: 50))),
        ])
        h.editor.transact(on: BoardID(owner: pocket), "Hold") { $0.setContainer([inner], to: corral) }
        _ = renderBitmap(h.editor, size: CGSize(width: 300, height: 300))
        expect(log.drawn.contains { $0.lens == outer && $0.shownThrough == nil && $0.showed }, "the outer lens showed the corral")
        expect(log.drawn.contains { $0.lens == inner && $0.shownThrough == outer && !$0.showed }, "the inner one, drawn through it, showed nothing: \(log.drawn)")
    },
    test("a shape on no board the editor can show, gone, or kept aside isn't drawn, and the lens says so") {
        let lens = ShapeID(), gone = ShapeID()
        let log = LensLog()
        let h = try shownHarness(log: log, root: [
            record(lens, Lens(CGRect(x: 0, y: 0, width: 100, height: 100), shows: gone)),
        ], pocket: ShapeID(), inside: [])
        _ = renderBitmap(h.editor, size: CGSize(width: 200, height: 200))
        expect(log.drawn.contains { $0.lens == lens && !$0.showed }, "nothing to show")
        expect(h.editor.shown(through: lens) == nil, "and nothing shown through it")
    },
    test("the shown shape is its skeleton where the canvas draws skeletons, or it's drawn under the skeleton zoom; else its render") {
        let small = ShapeID(), large = ShapeID(), pocket = ShapeID(), patch = ShapeID()
        let h = try shownHarness(root: [
            record(pocket, Pocket(CGRect(x: -300, y: 0, width: 100, height: 100))),
            record(small, Lens(CGRect(x: 0, y: 0, width: 30, height: 30), shows: patch, scale: 0.3)),
            record(large, Lens(CGRect(x: 100, y: 0, width: 100, height: 100), shows: patch, scale: 1)),
        ], pocket: pocket, inside: [record(patch, Patch(CGRect(x: 0, y: 0, width: 100, height: 100)))])
        let red = [255, 0, 0, 255], blue = [0, 0, 255, 255]
        var picture = renderBitmap(h.editor, size: CGSize(width: 300, height: 200))
        expectEqual(pixel(picture, at: CGPoint(x: 15, y: 15)), red, "30% on screen: its skeleton")
        expectEqual(pixel(picture, at: CGPoint(x: 150, y: 50)), blue, "100%: its render")
        h.editor.camera = Camera(zoom: 0.5)
        picture = renderBitmap(h.editor, size: CGSize(width: 300, height: 200))
        expectEqual(pixel(picture, at: CGPoint(x: 75, y: 25)), blue, "50% on screen, the canvas in full: its render")
        h.editor.camera = Camera(zoom: 0.3)
        picture = renderBitmap(h.editor, size: CGSize(width: 300, height: 200))
        expectEqual(pixel(picture, at: CGPoint(x: 45, y: 15)), red, "the canvas drawing skeletons: its skeleton")
    },
    test("what a lens shows is placed and found under a point: the shape, what a container holds, and nothing else") {
        let lens = ShapeID(), pocket = ShapeID(), corral = ShapeID(), a = ShapeID(), outside = ShapeID()
        let h = try shownHarness(root: [
            record(pocket, Pocket(CGRect(x: -300, y: 0, width: 100, height: 100))),
            record(lens, Lens(CGRect(x: 200, y: 200, width: 100, height: 100), shows: corral, scale: 0.5)),
        ], pocket: pocket, inside: [
            record(corral, Corral(CGRect(x: 0, y: 0, width: 200, height: 200))),
            record(a, Box(CGRect(x: 10, y: 10, width: 50, height: 50))),
            record(outside, Box(CGRect(x: 300, y: 300, width: 50, height: 50))),
        ])
        h.editor.transact(on: BoardID(owner: pocket), "Hold") { $0.setContainer([a], to: corral) }
        let transform = CGAffineTransform(translationX: 200, y: 200).scaledBy(x: 0.5, y: 0.5)
        expectEqual(h.editor.placement(of: corral, through: lens), transform)
        expectEqual(h.editor.placement(of: a, through: lens), transform, "what it holds, through the same transform")
        expectEqual(h.editor.placement(of: outside, through: lens), nil, "a shape it doesn't hold")
        let hit = h.editor.shownShape(at: CGPoint(x: 215, y: 215), in: lens)
        expectEqual(hit?.id, a)
        expectEqual(hit?.point, CGPoint(x: 30, y: 30), "in the box's own units")
        expectEqual(h.editor.shownShape(at: CGPoint(x: 280, y: 280), in: lens)?.id, corral, "the corral where it holds nothing")
        expect(h.editor.shownShape(at: CGPoint(x: 100, y: 100), in: lens) == nil, "off the lens")
    },
    test("editing through a lens: the card's own editor over the lens at its scale, writing the card on its board, undone without leaving") {
        let lens = ShapeID(), pocket = ShapeID(), card = ShapeID()
        let hearing = LayoutHearing()
        let h = try shownHarness(hearing: hearing, root: [
            record(pocket, Pocket(CGRect(x: -300, y: 0, width: 100, height: 100))),
            record(lens, Lens(CGRect(x: 200, y: 200, width: 200, height: 120), shows: card, scale: 2)),
        ], pocket: pocket, inside: [record(card, Card(CGRect(x: 0, y: 0, width: 100, height: 60)))])
        let e = h.editor
        expect(e.beginEditing(card, through: lens, at: CGPoint(x: 220, y: 210), clickCount: 2))
        expectEqual(e.editingShapeID, card)
        expectEqual(e.editingStandIn, lens)
        expectEqual(e.editingStartPoint, CGPoint(x: 10, y: 5), "the press in the card's own units")
        expectEqual(e.editingStartClickCount, 2)
        expectEqual(e.editingFrame, CGRect(x: 200, y: 200, width: 200, height: 120), "over the lens, at its scale")
        expectEqual(e.editingViewBounds, CGRect(x: 0, y: 0, width: 100, height: 60), "its bounds the card's own size")
        expect(hearing.heard.contains([card, lens]), "both laid out afresh, and services told: \(hearing.heard)")
        let field = try require(e.makeEditingView()?.view as? CardField)
        expectEqual(field.context.frame, CGRect(x: 0, y: 0, width: 100, height: 60), "the card's own editing frame")
        field.context.update { $0.text = "Hello" }
        expectEqual(e.shape(inFile: card)?.typed(as: Card.self)?.props.text, "Hello", "written on its board")
        expectEqual(field.context.shape?.props.text, "Hello")
        expectEqual(e.board, .root, "the board shown stays")
        e.endEditing()
        expectEqual(e.editingStandIn, nil)
        e.undo()
        expectEqual(e.board, .root, "undone from where it was typed")
        expectEqual(e.shape(inFile: card)?.typed(as: Card.self)?.props.text, "")
    },
    test("a read-only lens or card refuses editing through it, and the lens is what's refused") {
        let lens = ShapeID(), pocket = ShapeID(), card = ShapeID(), other = ShapeID()
        let refusals = RefusalLog()
        let h = try shownHarness(refusals: refusals, root: [
            record(pocket, Pocket(CGRect(x: -300, y: 0, width: 100, height: 100))),
            record(lens, Lens(CGRect(x: 200, y: 200, width: 100, height: 60), shows: card)),
        ], pocket: pocket, inside: [record(card, Card(CGRect(x: 0, y: 0, width: 100, height: 60))),
                                    record(other, Card(CGRect(x: 200, y: 0, width: 100, height: 60)))])
        let e = h.editor
        expect(!e.beginEditing(other, through: lens), "a shape the lens doesn't show")
        h.editor.freeze([lens])
        expect(!e.beginEditing(card, through: lens))
        expectEqual(refusals.refusals.last, [lens])
        h.editor.freeze([lens], false)
        e.transact(on: BoardID(owner: pocket), "Freeze") { $0.update(card) { $0[Frozen.self] = true } }
        expect(!e.beginEditing(card, through: lens))
        expectEqual(refusals.refusals.last, [lens], "the lens shakes, the one in view")
        expectEqual(e.editingShapeID, nil)
    },
    test("editing through a lens ends with the lens: deleted, showing something else, or read-only; and with the card gone") {
        let lens = ShapeID(), pocket = ShapeID(), card = ShapeID()
        let h = try shownHarness(root: [
            record(pocket, Pocket(CGRect(x: -300, y: 0, width: 100, height: 100))),
            record(lens, Lens(CGRect(x: 200, y: 200, width: 100, height: 60), shows: card)),
        ], pocket: pocket, inside: [record(card, Card(CGRect(x: 0, y: 0, width: 100, height: 60)))])
        let e = h.editor
        expect(e.beginEditing(card, through: lens))
        e.transact { $0.update(lens, as: Lens.self) { $0.props.shows = nil } }
        expectEqual(e.editingShapeID, nil, "showing nothing")
        e.undo()
        expect(e.beginEditing(card, through: lens))
        e.freeze([lens])
        expectEqual(e.editingShapeID, nil, "frozen")
        e.freeze([lens], false)
        expect(e.beginEditing(card, through: lens))
        e.transact(on: BoardID(owner: pocket), "Delete") { $0.delete([card]) }
        expectEqual(e.editingShapeID, nil, "the card deleted on its board")
        e.undo()
        _ = e.showBoard(.root)
        expect(e.beginEditing(card, through: lens))
        e.transact { $0.delete([lens]) }
        expectEqual(e.editingShapeID, nil, "the lens deleted")
        expectEqual(e.editingStandIn, nil)
    },
    test("the lens edited through is drawn in full zoomed out, and told so") {
        let lens = ShapeID(), pocket = ShapeID(), card = ShapeID()
        let log = LensLog()
        let h = try shownHarness(log: log, root: [
            record(pocket, Pocket(CGRect(x: -300, y: 0, width: 100, height: 100))),
            record(lens, Lens(CGRect(x: 0, y: 0, width: 100, height: 60), shows: card)),
        ], pocket: pocket, inside: [record(card, Card(CGRect(x: 0, y: 0, width: 100, height: 60)))])
        h.editor.camera = Camera(zoom: 0.3)
        expect(h.editor.drawsSkeleton(of: lens))
        expect(h.editor.beginEditing(card, through: lens))
        expect(!h.editor.drawsSkeleton(of: lens), "drawn in full under the editor")
        _ = renderBitmap(h.editor, size: CGSize(width: 100, height: 100))
        expectEqual(log.editedThrough, [lens], "its render told it's edited through")
    },
])
