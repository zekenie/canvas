import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import CoreGraphics
import Geometry
import Mentions
import Selection
import TestKit

// An arrow's handles by the keys (`ArrowParts`): ⌥Tab into its start, bend, label and end; the arrows move
// each as its drag does, one undo step while held; ⌥⌘ and an arrow bind an end to the nearest shape that
// way, as a drag released on it does; Return presses each; Escape goes back to the arrow. Its heads are in
// the Shape menu, and VoiceOver says where it runs.

/// A canvas in an unshown window over two boxes, A and B, titled, with an arrow between their middles that
/// says "ships" a little past halfway (short of where the label is kept clear of the head).
@MainActor final class ArrowKeysWindow {
    let h: EditorHarness
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
    let canvas: CanvasView
    let a: ShapeID
    let b: ShapeID
    let arrow: ShapeID

    init() throws {
        h = try EditorHarness(plugins: labelPlugins())
        canvas = CanvasView(editor: h.editor)
        canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 500)
        window.contentView = canvas
        window.makeFirstResponder(canvas)
        a = h.editor.addBox("A", at: boxA)
        b = h.editor.addBox("B", at: boxB)
        arrow = h.add(Arrow(start: .bound(ArrowBinding(shapeID: a, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)),
                            end: .bound(ArrowBinding(shapeID: b, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)),
                            text: "ships", labelPosition: 0.6))
    }

    var editor: CanvasEditor { h.editor }

    func walk() -> KeyWalk {
        let names = [a: "A", b: "B", arrow: "Arrow"]
        return KeyWalk(window, editor: editor, readers: [.canvas(canvas, selection: { [editor] in editor.selectedShapeIDs.map { names[$0] ?? "?" } },
                                                                 part: { [editor] in editor.focusedPart?.title },
                                                                 frame: { [editor, canvas] in
                                                                     guard let rect = editor.focusedPart?.rect ?? editor.selectionBounds else { return nil }
                                                                     return editor.shownFrame(ofWorld: rect, in: canvas)
                                                                 })],
                       settle: .manual(h.scheduler))
    }
}

/// An arrow bound to A at its start whose end is free, between A and B.
@MainActor private func freeEnded() throws -> Board {
    let board = try Board()
    let arrow = Arrow(start: .bound(ArrowBinding(shapeID: board.a, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)),
                      end: .free(CGPoint(x: 370, y: 180)))
    _ = board.h.add(arrow)
    return board
}

@MainActor private func arrow(_ board: Board) throws -> Arrow { try require(board.arrows.first) }

/// The arrow selected and its last part (its end, of an arrow left to right) focused with ⌥⇧Tab.
@MainActor private func focusEnd(_ board: Board) throws {
    board.h.editor.selection = try require(board.arrowIDs.first)
    board.h.key(Chord.optionBackTab)
    expectEqual(board.h.editor.focusedPart?.title, "End")
}

@MainActor let arrowKeyboardTests = Suite("An arrow's handles by the keys", [
    test("⌥Tab walks the start, the bend, the label and the end in reading order, ⌥⇧Tab is its exact inverse, each shown and named") {
        let w = try ArrowKeysWindow()
        let walk = w.walk()
        w.editor.selection = w.arrow
        expectEqual(w.editor.shapeParts(of: w.arrow).map(\.title), ["Start", "Bend", "Label", "End"])
        expectEqual(walk.press(.optionTab).id, "canvas/Arrow/Start")
        let cycle = walk.expectCycle(["canvas/Arrow/Start", "canvas/Arrow/Bend", "canvas/Arrow/Label", "canvas/Arrow/End"],
                                     forward: .optionTab, back: .optionBackTab)
        walk.expectShows(cycle.stops, by: .optionTab)
        expect(w.editor.shapeParts(of: w.arrow).allSatisfy { $0.role == .handle })
        expectEqual(w.editor.selectedShapeIDs, [w.arrow], "the arrow stays selected throughout")
    },
    test("Escape goes back to the arrow, still selected, then deselects") {
        let w = try ArrowKeysWindow()
        let walk = w.walk()
        w.editor.selection = w.arrow
        walk.press(.optionTab)
        walk.press(.optionTab)
        walk.expectEscapeLadder(["canvas/Arrow", "canvas"])
    },
    test("on a free end the arrows move it a unit, ten with ⇧, a held key's moves one step, Move Arrow End") {
        let board = try freeEnded()
        try focusEnd(board)
        board.h.key(Chord.right)
        for _ in 0..<4 { expect(board.h.key(Chord.right, isRepeat: true)) }
        expectEqual(try arrow(board).end, .free(CGPoint(x: 375, y: 180)))
        board.h.key(Chord(Key.down, .shift))
        expectEqual(try arrow(board).end, .free(CGPoint(x: 375, y: 190)))
        expectEqual(board.h.editor.undoHistory.undoName, "Move Arrow End")
        board.h.editor.undo()
        expectEqual(try arrow(board).end, .free(CGPoint(x: 375, y: 180)))
        board.h.editor.undo()
        expectEqual(try arrow(board).end, .free(CGPoint(x: 370, y: 180)), "the held key's five, one step")
        expectEqual(try arrow(board).start, .bound(ArrowBinding(shapeID: board.a, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)),
                    "the arrow didn't move")
    },
    test("on a bound end the arrows slide its anchor across its shape, precise, and let go where it leaves the shape") {
        let board = try Board(arrow: 0)
        try focusEnd(board)
        board.h.key(Chord.right)
        let binding = try require(try arrow(board).end.binding)
        expectEqual(binding.shapeID, board.b)
        expect(binding.isPrecise)
        expectEqual(binding.normalizedAnchor, CGPoint(x: 0.505, y: 0.5))
        board.h.key(Chord(Key.right, .shift))
        for _ in 0..<14 { board.h.key(Chord(Key.right, .shift), isRepeat: true) }
        expectEqual(try arrow(board).end, .free(CGPoint(x: 711, y: 180)), "past B's right edge")
        expectEqual(board.h.editor.focusedPart?.title, "End", "the end keeps the keyboard")
    },
    test("⌥⌘ and an arrow bind an end to the nearest shape that way, as a quick drag released on its middle does") {
        let keys = try freeEnded()
        try focusEnd(keys)
        expect(keys.h.key(Chord(Key.right, [.option, .command])))
        expectEqual(try arrow(keys).end, .bound(ArrowBinding(shapeID: keys.b, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)))
        expectEqual(keys.h.editor.undoHistory.undoName, "Move Arrow End")
        expectEqual(keys.h.editor.selectedShapeIDs, keys.arrowIDs, "the arrow stays selected")
        expectEqual(keys.h.editor.focusedPart?.title, "End")
        expect(keys.h.editor.hintedShapeID == nil, "no drag is under way to outline B")
        expect(keys.h.editor.announcements.last != nil, "VoiceOver hears where it went")

        let drag = try freeEnded()
        drag.h.editor.selection = try require(drag.arrowIDs.first)
        drag.h.move(to: drag.h.view(CGPoint(x: 370, y: 180)))
        drag.h.press()
        drag.h.drag(to: drag.h.view(boxB.center), speed: fast)
        drag.h.release()
        let byKeys = try require(try arrow(keys).end.binding), byDrag = try require(try arrow(drag).end.binding)
        expectEqual(byDrag.shapeID, drag.b)
        expectEqual([byKeys.normalizedAnchor.x, byKeys.normalizedAnchor.y], [byDrag.normalizedAnchor.x, byDrag.normalizedAnchor.y], "the same as the drag's")
        expectEqual([byKeys.isPrecise, byKeys.isExact], [byDrag.isPrecise, byDrag.isExact])
        expectEqual(try arrow(keys).bend, try arrow(drag).bend)
    },
    test("⌥⌘ and an arrow rebind a bound end; with nothing that way the end stays, and the keyboard with it") {
        let board = try Board(arrow: 0)
        let c = board.h.add(Box(CGRect(x: 460, y: 400, width: 200, height: 200)))
        try focusEnd(board)
        board.h.key(Chord(Key.down, [.option, .command]))
        expectEqual(try arrow(board).end.binding?.shapeID, c)
        let before = try arrow(board)
        board.h.key(Chord(Key.right, [.option, .command]))
        expectEqual(try arrow(board), before)
        expectEqual(board.h.editor.selectedShapeIDs, board.arrowIDs, "no step to another shape while the end has the keyboard")
        expectEqual(board.h.editor.focusedPart?.title, "End")
        board.h.key(Chord(Key.up, [.option, .command]))
        expectEqual(try arrow(board).end.binding?.shapeID, board.b, "and back")
        expectEqual(try arrow(board).start.binding?.shapeID, board.a, "the start stays")
    },
    test("Return and Space on an end toggle its head, the double-click's step") {
        let board = try Board(arrow: 0)
        try focusEnd(board)
        board.h.key(Chord.return)
        expect(!(try arrow(board).endArrowhead))
        expectEqual(board.h.editor.undoHistory.undoName, "Toggle Arrowhead")
        board.h.key(Chord.space)
        expect(try arrow(board).endArrowhead)
        board.h.editor.keyUp(KeyStroke(" "))
        board.h.key(Chord.optionTab)
        expectEqual(board.h.editor.focusedPart?.title, "Start")
        board.h.key(Chord.return)
        expect(try arrow(board).startArrowhead)
    },
    test("on the bend the arrows move it across the arrow, as its drag does, and Return straightens it") {
        let board = try Board(arrow: 0)
        board.h.editor.selection = board.arrow
        board.h.key(Chord.optionTab)
        board.h.key(Chord.optionTab)
        expectEqual(board.h.editor.focusedPart?.title, "Bend")
        board.h.key(Chord.up)
        expectEqual(abs(try arrow(board).bend), 1)
        expectEqual(board.h.editor.undoHistory.undoName, "Bend Arrow")
        board.h.key(Chord.down)
        expectEqual(try arrow(board).bend, 0, "↓ undoes ↑")
        board.h.key(Chord(Key.down, .shift))
        expectEqual(abs(try arrow(board).bend), 10)
        let bent = try arrow(board)
        board.h.key(Chord.left)
        expectEqual(try arrow(board), bent, "a key along a level arrow bends it no more, and nudges nothing")
        board.h.key(Chord.return)
        expectEqual(try arrow(board).bend, 0)
        expectEqual(board.h.editor.undoHistory.undoName, "Straighten Arrow")
        expectEqual(board.h.editor.focusedPart?.title, "Bend")
    },
    test("on the label the arrows slide it along the body, and Return edits it") {
        let w = try ArrowKeysWindow()
        w.editor.selection = w.arrow
        for _ in 0..<3 { w.h.key(Chord.optionTab) }
        expectEqual(w.editor.focusedPart?.title, "Label")
        let start = try require(w.editor.document[w.arrow]?.typed(as: Arrow.self)?.props.labelPosition)
        let middle = try require(w.editor.arrowLabelFrame(of: w.arrow)).center
        w.h.key(Chord.right)
        let moved = try require(w.editor.document[w.arrow]?.typed(as: Arrow.self)?.props.labelPosition)
        expect(moved > start, "toward the end")
        expectEqual(w.editor.undoHistory.undoName, "Move Label")
        expect(abs(try require(w.editor.arrowLabelFrame(of: w.arrow)).center.x - middle.x - 1) < 0.01, "a unit along")
        w.h.key(Chord.left)
        expect(abs(try require(w.editor.document[w.arrow]?.typed(as: Arrow.self)?.props.labelPosition) - start) < 1e-6, "← undoes →")
        w.h.key(Chord.return)
        expectEqual(w.editor.editingShapeID, w.arrow)
    },
    test("Toggle Start Arrowhead and Toggle End Arrowhead are in the Shape menu, and toggle the heads") {
        let board = try Board(arrow: 0)
        board.h.editor.selection = board.arrow
        let outline = try require(board.h.editor.menuForSelection(omitting: [])).outline
        expect(outline.contains("Toggle Start Arrowhead"), "\(outline)")
        expect(outline.contains("Toggle End Arrowhead"), "\(outline)")
        try require(board.h.editor.menuForSelection(omitting: [])).choose("Toggle Start Arrowhead")
        expect(try arrow(board).startArrowhead)
        try require(board.h.editor.menuForSelection(omitting: [])).choose("Toggle End Arrowhead")
        expect(!(try arrow(board).endArrowhead))
        board.h.editor.selection = board.a
        expect(!(board.h.editor.menuForSelection(omitting: [])?.outline ?? []).contains("Toggle Start Arrowhead"), "an arrow's alone")
    },
    test("VoiceOver reads an arrow as Arrow from A to B, its label its value; a free end is left unsaid") {
        let w = try ArrowKeysWindow()
        let said = try require(w.editor.accessibleDescription(of: w.arrow))
        expectEqual(said.label, "Arrow, from A to B")
        expectEqual(said.value, "ships")
        w.editor.transact { $0.update(w.arrow, as: Arrow.self) { $0.props.start = .free(.zero); $0.props.text = "" } }
        let free = try require(w.editor.accessibleDescription(of: w.arrow))
        expectEqual(free.label, "Arrow, to B")
        expect(free.value == nil)
    },
    test("an arrow with no words has no label part, and one being edited has none: they are its editor's") {
        let board = try Board(arrow: 0)
        let id = try require(board.arrow)
        expectEqual(board.h.editor.shapeParts(of: id).map(\.title), ["Start", "Bend", "End"])
        board.h.editor.selection = id
        board.h.editor.beginEditing(id)
        expect(board.h.editor.shapeParts(of: id).isEmpty)
    },
])
