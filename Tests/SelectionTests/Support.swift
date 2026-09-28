@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Keyboard
import Selection

/// Cards that claim the double-click on empty canvas.
@MainActor func doubleClickCards() -> CardsPlugin {
    CardsPlugin { card, place in card.createOnDoubleClick(place) }
}

/// A box with one handle, at its center.
struct Knob: BoxShapeProps {
    static let kind: ShapeKind = "knob"
    static let properties = Properties<Knob> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
}
extension Knob {
    init() { self.init(.zero) }
}

struct KnobDefinition {}

extension KnobDefinition: ShapeDefinition, HandleProviding {
    func render(_ shape: ShapeRecord<Knob>, in context: RenderContext) {}
    func handles(of shape: ShapeRecord<Knob>, in context: ShapeContext) -> [HandleLocation<Int>] {
        [HandleLocation(0, at: CGPoint(x: shape.frame.midX, y: shape.frame.midY))]
    }
    func pressHandle(_ handle: Int, of shape: ShapeRecord<Knob>, at pointer: Pointer, in editor: CanvasEditor) -> HandlePress { .drag }
    func dragSession(for handle: Int, of shape: ShapeRecord<Knob>, from origin: CGPoint, in editor: CanvasEditor) -> any Session { IdleSession() }
}

struct KnobsPlugin: CanvasPlugin {
    var id: PluginID { "knobs" }
    func register(into registrar: inout PluginRegistrar) { registrar.shape(KnobDefinition()) }
}

/// Counts what the editor tells its view. (Its delegate protocol is the host's, so it can't be
/// public in CanvasTesting.)
final class DisplayCounter: CanvasEditorDelegate {
    var redraws = 0
    func editorNeedsDisplay(_ editor: CanvasEditor) { redraws += 1 }
    func editorCursorDidChange(_ editor: CanvasEditor) {}
    func editorEditingDidChange(_ editor: CanvasEditor) {}
}

/// Pockets (CanvasTesting's board-owning kind) that open onto their boards, from a bridge
/// (`registrar.opens(Pocket.self, …)`), as a board-owning kind's plugin would.
@MainActor func openingPockets() -> Contributor {
    Contributor(id: "opening-pockets") { r in
        r.opens(Pocket.self, "Open") { pocket, editor in editor.showBoard(BoardID(owner: pocket.id)) }
    }
}

/// A root holding box A, pocket P and card C, left to right, 100 points apart, and P's board
/// holding box B, just where P is on the root, and pocket Q.
struct PocketBoards {
    let a = ShapeID(), p = ShapeID(), c = ShapeID(), b = ShapeID(), q = ShapeID()
    var pBoard: BoardID { BoardID(owner: p) }

    var file: CanvasFile {
        func record<P: ShapeProps>(_ id: ShapeID, _ props: P) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, props)) }
        return CanvasFile(root: CanvasDocument(shapes: [record(a, Box(CGRect(x: 0, y: 0, width: 100, height: 100))),
                                                        record(p, Pocket(CGRect(x: 200, y: 0, width: 100, height: 100))),
                                                        record(c, Card(CGRect(x: 400, y: 0, width: 100, height: 100)))]),
                          children: [p: CanvasDocument(shapes: [record(b, Box(CGRect(x: 200, y: 0, width: 100, height: 100))),
                                                                record(q, Pocket(CGRect(x: 0, y: 300, width: 100, height: 100)))])])
    }

    /// Where each root shape's middle is, while the camera hasn't moved.
    let aPoint = CGPoint(x: 50, y: 50), pPoint = CGPoint(x: 250, y: 50), cPoint = CGPoint(x: 450, y: 50)
}

/// An editor of `PocketBoards`, with keys, the selection, boxes, cards, and pockets that open.
@MainActor func pocketsHarness(_ boards: PocketBoards, cards: CardsPlugin = CardsPlugin(), _ more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), cards, PocketsPlugin(), openingPockets()] + more,
                      file: boards.file)
}
