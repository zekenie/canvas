import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import CoreGraphics
import LanguageModels
import Mentions
import Selection
import ShippedTesting
import SlashCommands
import StickyNotes
import TestKit
import TextEditing
import Titles

// `/bulk-create A, B, C` as shipped: typed in the command bar with nothing selected, it makes a note titled
// with each value, waiting on the pointer in a column (a row while ⌥ is held) until a click, or Return, puts
// them down together. The app's canvas view in an unshown window, the camera at the origin at 100%, so view
// points are world units; a note is 260 × 200, the notes 80 apart.

/// The shipped plugins over an empty board, in the app's canvas view, the canvas with the keyboard.
@MainActor private final class BulkRig {
    let editor: CanvasEditor
    let window: NSWindow
    let canvas: CanvasView
    private var time: TimeInterval = 100

    init() {
        editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        (window, canvas) = windowed(editor)
        editor.viewportDidResize(to: canvas.bounds.size)
        window.makeFirstResponder(canvas)
    }

    var bar: SlashBar? { editor.slashBar }
    var listed: [String] { bar?.typing?.picker?.listed.map(\.name) ?? [] }
    var rows: [String] {
        bar?.typing?.picker?.rows.compactMap(\.item).map { item in item.detail.map { "\(item.title) (\($0))" } ?? item.title } ?? []
    }
    /// The waiting notes' titles, and their boxes.
    var waitingTitles: [String?] { editor.pendingShapes.map { $0[TitleProperty.self] } }
    var waitingBoxes: [CGRect] { editor.pendingShapes.compactMap(\.box) }
    var notes: [AnyShapeRecord] { editor.document.shapes.filter { $0.kind == StickyNote.kind } }

    /// `/` on the canvas, and a line typed in the bar.
    func type(_ line: String) {
        window.makeFirstResponder(canvas)
        window.type("/")
        window.type(line)
    }

    /// The pointer moves over the canvas to `point` (view points), as the view tells the editor.
    func move(to point: CGPoint) {
        time += 0.016
        editor.pointerMoved(PointerEvent(location: point, timestamp: time, clickCount: 0))
    }

    /// A click where the pointer is, with `modifiers` held.
    func click(at point: CGPoint, modifiers: Modifiers = []) {
        time += 0.016
        editor.pointerDown(PointerEvent(location: point, timestamp: time, modifiers: modifiers))
        time += 0.016
        editor.pointerUp(PointerEvent(location: point, timestamp: time, modifiers: modifiers))
    }
}

/// A column of `count` notes 260 × 200, 80 apart, the first's middle at `point`; a row with `inRow`.
private func column(_ count: Int, from point: CGPoint, inRow: Bool = false) -> [CGRect] {
    (0..<count).map { index in
        let step = CGFloat(index)
        return CGRect(x: point.x - 130 + (inRow ? step * 340 : 0), y: point.y - 100 + (inRow ? 0 : step * 280), width: 260, height: 200)
    }
}

@MainActor let bulkCreateShippedTests = Suite("Bulk create, as shipped", [
    test("on an empty board / opens the bar with bulk-create; its line's Return leaves three titled notes waiting on the pointer in a column, ⌥ a row; a click puts them down there, one step, all selected") {
        let rig = BulkRig()
        rig.window.type("/")
        expect(rig.bar?.isOpen == true, "an empty board offers bulk-create")
        expectEqual(rig.rows, ["bulk-create (A, B, C)"])
        expectEqual(rig.bar?.label, "", "no shapes to act on")
        rig.window.type("bulk-create Auth, Billing , ,Payments")
        rig.window.pressReturn()
        expect(rig.bar?.isOpen != true, "the bar closes")
        expect(rig.editor.isPlacingLater)
        expectEqual(rig.editor.announcements.last, "3 notes to place")
        expect(rig.notes.isEmpty, "nothing on the board yet")
        rig.move(to: CGPoint(x: 300, y: 150))
        expectEqual(rig.waitingTitles, ["Auth", "Billing", "Payments"], "commas split, spaces trimmed, the empty one left out")
        expectEqual(rig.waitingBoxes, column(3, from: CGPoint(x: 300, y: 150)), "the first's middle on the pointer, the rest below, 80 apart")
        rig.editor.modifiersChanged(held: .option)
        expectEqual(rig.waitingBoxes, column(3, from: CGPoint(x: 300, y: 150), inRow: true), "⌥: a row")
        rig.editor.modifiersChanged(held: [])
        expectEqual(rig.waitingBoxes, column(3, from: CGPoint(x: 300, y: 150)), "let go: the column")
        rig.move(to: CGPoint(x: 400, y: 200))
        rig.click(at: CGPoint(x: 400, y: 200))
        expectEqual(rig.notes.map { $0[TitleProperty.self] }, ["Auth", "Billing", "Payments"])
        expectEqual(rig.notes.compactMap { $0.typed(as: StickyNote.self)?.props.text.stored }, ["", "", ""], "titled, their words empty")
        expectEqual(rig.notes.compactMap(\.box), column(3, from: CGPoint(x: 400, y: 200)), "where they were drawn")
        expectEqual(Set(rig.editor.selectedShapeIDs), Set(rig.notes.map(\.id)), "all three selected")
        expectEqual(rig.editor.undoHistory.undoName, "Add Notes")
        expect(!rig.editor.isPlacingLater)
        expectEqual(rig.editor.currentToolID, rig.editor.registry.defaultTool)
        rig.editor.undo()
        expect(rig.notes.isEmpty, "one Undo takes them all")
    },
    test("by the keys alone: /, the line, Return, Return puts the column in the middle of the view; ⌥↩ puts a row; Escape drops what waits") {
        let rig = BulkRig()
        expect(!rig.editor.isPointerOverCanvas)
        rig.type("bulk-create A, B")
        rig.window.pressReturn()
        expect(rig.editor.isPlacingLater && rig.window.firstResponder === rig.canvas, "waiting, the canvas with the keyboard")
        let view = rig.editor.unobscuredViewport
        let block = rig.waitingBoxes.reduce(CGRect.null) { $0.union($1) }
        expectEqual(CGPoint(x: block.midX, y: block.midY), CGPoint(x: view.midX, y: view.midY), "the block in the middle of the view")
        rig.window.pressReturn()
        expectEqual(rig.notes.count, 2, "Return puts them down where they're drawn")
        let placed = rig.notes.compactMap(\.box)
        expect(placed.count == 2 && placed[0].minX == placed[1].minX && placed[0].minY < placed[1].minY, "a column: \(placed)")
        expectEqual(rig.editor.selectedShapeIDs.count, 2)
        rig.editor.selectedShapeIDs = []
        rig.type("bulk-create C, D")
        rig.window.pressReturn()
        rig.editor.modifiersChanged(held: .option)
        rig.window.press(Chord(Key.return, .option))
        rig.editor.modifiersChanged(held: [])
        let row = rig.notes.suffix(2).compactMap(\.box)
        expectEqual(row.count, 2, "⌥↩ puts them down")
        expectEqual(row.first?.minY, row.last?.minY, "in a row")
        rig.editor.selectedShapeIDs = []
        rig.type("bulk-create E")
        rig.window.pressReturn()
        expect(rig.editor.isPlacingLater)
        rig.window.pressEscape()
        expect(!rig.editor.isPlacingLater, "Escape drops them")
        expectEqual(rig.notes.count, 4, "nothing more placed")
    },
    test("while notes wait, no key with no use there changes the board (P8), and an undo or another card lets them go") {
        let rig = BulkRig()
        let note = rig.editor.add(StickyNote(frame: CGRect(x: 600, y: 400, width: 260, height: 200)))
        rig.editor.selectedShapeIDs = []
        for chord in Chord.inert {
            if !rig.editor.isPlacingLater {
                rig.type("bulk-create A, B")
                rig.window.pressReturn()
            }
            let revision = rig.editor.revision
            rig.window.press(chord)
            expectEqual(rig.editor.revision, revision, "\(chord) changed the board while notes wait")
            if rig.window.firstResponder !== rig.canvas { rig.window.makeFirstResponder(rig.canvas) }
            if rig.bar?.isOpen == true { rig.bar?.close() }
        }
        expect(rig.editor.document[note] != nil)
        if !rig.editor.isPlacingLater {
            rig.type("bulk-create A, B")
            rig.window.pressReturn()
        }
        rig.editor.undo()
        expect(!rig.editor.isPlacingLater, "an undo changes the board under them: they go")
        rig.type("bulk-create C")
        rig.window.pressReturn()
        rig.window.type("/")
        expect(rig.bar?.isOpen == true)
        expect(!rig.editor.isPlacingLater, "the command bar shown: they go")
    },
    test("offered with nothing selected, never for a selection; nothing typed, or only commas, isn't accepted, and one title is a note") {
        let rig = BulkRig()
        let note = rig.editor.add(StickyNote(frame: CGRect(x: 100, y: 100, width: 260, height: 200)))
        rig.window.type("/")
        expectEqual(Array(rig.listed.suffix(2)), ["bulk-create", "query"], "after what the board's shapes offer, before /query")
        rig.window.pressEscape()
        rig.window.pressEscape()
        rig.editor.selection = note
        rig.window.makeFirstResponder(rig.canvas)
        rig.window.type("/")
        expect(!rig.listed.contains("bulk-create"), "not for a selection")
        rig.window.pressEscape()
        rig.window.pressEscape()
        rig.editor.selectedShapeIDs = []
        rig.type("bulk-create , ,")
        rig.window.pressReturn()
        expect(!rig.editor.isPlacingLater, "only commas: nothing to make")
        rig.window.pressEscape()
        rig.window.pressEscape()
        let commands = try require(rig.editor.slashCommands)
        expect(!commands.run("bulk-create", for: .everything([note]), with: SlashArguments([])), "nothing typed")
        expect(commands.run("bulk-create", for: .everything([note]), with: SlashArguments("Solo")))
        expectEqual(rig.waitingTitles, ["Solo"])
        expectEqual(rig.editor.announcements.last, "1 note to place")
    },
])
