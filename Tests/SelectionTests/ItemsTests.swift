import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TestKit

// Items inside a shape (`ShapeItems`), one level in as a group's parts are: a fixture plugin gives every box four rows
// (r0 to r3, 20 apart from its top), the last a closed line standing for a hidden row (h1), and logs what each key asks of
// them; its Delete changes the box, so Undo has a step to restore the items with. Walked with the keys a keyboard sends.

/// What the fixture's items were asked to do.
@MainActor final class ItemLog {
    var deleted: [[String]] = []
    var moved: [([String], Int)] = []
    var opened: [(String, CGPoint?)] = []
    var setOpen: [(String, Bool)] = []
    var r3Open = false
    /// What a drag of the selected items asked of the kind, and whether the kind gives a session for it (else the shape is dragged).
    var dragged: [[String]] = []
    var givesDrag = false
    /// The rows' words, as the kind says a run of them is selected.
    var said: [Int] = []
    /// Whether the fixture lists any rows at all (another writer deleted them all when not), and whether row 0 has a lead.
    var listed = true
    var led: [String] = []
    var hasLead = false
}

/// The session the fixture's drag of its items runs: logs that it ran.
@MainActor final class ItemDrag: Session {
    static var ran = 0
    func drag(_ pointer: Pointer, in editor: CanvasEditor) { Self.ran += 1 }
    func end(_ pointer: Pointer, in editor: CanvasEditor) {}
    func cancel(in editor: CanvasEditor) -> Bool { true }
}

@MainActor func fourRows(_ log: ItemLog) -> Contributor {
    Contributor(id: "items") { registrar in
        registrar.forShapes(adopting: .box) { box in
            box.shapeItems(named: "rows", { _, shape in
                guard log.listed, let f = shape.box else { return [] }
                return (0..<4).map { index in
                    let rect = CGRect(x: f.minX, y: f.minY + CGFloat(index) * 20, width: f.width, height: 20)
                    return index == 3
                        ? ShapeItem(id: "r3", title: "Row 3", rect: rect, outline: log.r3Open ? .open : .closed, stands: log.r3Open ? [] : ["h1"])
                        : ShapeItem(id: "r\(index)", title: "Row \(index)", rect: rect)
                }
            }, at: { _, shape, point in
                guard let f = shape.box, point.x >= f.minX, point.x < f.maxX, point.y >= f.minY, point.y < f.minY + 80 else { return nil }
                return AnyHashable("r\(Int((point.y - f.minY) / 20))")
            }, actions: ShapeItemActions(
                delete: { editor, id, ids in
                    log.deleted.append(ids.map { "\($0)" })
                    editor.transact("Delete Rows") { $0.update(id, as: Box.self) { $0.frame.size.height += 1 } }
                },
                move: { _, _, ids, delta in log.moved.append((ids.map { "\($0)" }, delta)) },
                open: { _, _, item, point in log.opened.append(("\(item)", point)) },
                setOpen: { _, _, item, open in
                    log.setOpen.append(("\(item)", open))
                    log.r3Open = open
                },
                drag: { _, _, ids, _ in
                    log.dragged.append(ids.map { "\($0)" })
                    return log.givesDrag ? ItemDrag() : nil
                },
                lead: { _, shape, point in
                    guard log.hasLead, let f = shape.box, point.x >= f.minX, point.x < f.minX + 40, point.y >= f.minY, point.y < f.minY + 20 else { return nil }
                    return ItemLead(item: "r0") { _, _ in log.led.append("r0") }
                },
                selectedWords: { count in
                    log.said.append(count)
                    return "\(count) rows selected"
                }))
        }
    }
}

/// A canvas in an unshown window with two boxes, A (200 × 160, its rows its top 80) and B to its right, the items fixture
/// and `threeParts` (two chips and a handle on every box).
@MainActor final class ItemsWindow {
    let h: EditorHarness
    let log = ItemLog()
    let parts = PartLog()
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
    let canvas: CanvasView
    let a: ShapeID
    let b: ShapeID

    init(resizable: Bool = false) throws {
        h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()] + (resizable ? [resizableBoxes()] : []) + [fourRows(log), threeParts(parts)])
        canvas = CanvasView(editor: h.editor)
        canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 500)
        window.contentView = canvas
        window.makeFirstResponder(canvas)
        a = h.add(Box(CGRect(x: 100, y: 100, width: 200, height: 160)))
        b = h.add(Box(CGRect(x: 400, y: 100, width: 100, height: 100)))
        h.editor.undoHistory.seal()
    }

    var editor: CanvasEditor { h.editor }

    /// The items selected, by id: "r1".
    var items: [String] { editor.selectedItems?.ids.map { "\($0)" } ?? [] }

    /// The middle of A's row n, in view points.
    func row(_ n: Int) -> CGPoint { h.view(CGPoint(x: 200, y: 110 + CGFloat(n) * 20)) }

    func walk() -> KeyWalk {
        let names = [a: "A", b: "B"]
        return KeyWalk(window, editor: editor, readers: [.canvas(canvas, selection: { [editor] in editor.selectedShapeIDs.map { names[$0] ?? "?" } },
                                                                 part: { [editor] in
                                                                     editor.selectedItems.map { $0.ids.map { "\($0)" }.joined(separator: "+") } ?? editor.focusedPart?.title
                                                                 })],
                       settle: .manual(h.scheduler))
    }
}

@MainActor let itemTests = Suite("Items inside a shape", [
    test("The ladder: a press on an item of a shape not selected selects the shape; released on the only selected shape, the item; ⇧ the run, ⌘ one toggled; a click on the only item opens it there; a press off the items drops them") {
        let w = try ItemsWindow()
        w.h.click(at: w.row(1))
        expectEqual(w.editor.selectedShapeIDs, [w.a])
        expectEqual(w.items, [], "the shape first, as a group whole")
        w.h.click(at: w.row(1))
        expectEqual(w.items, ["r1"])
        expectEqual(w.editor.selectedShapeIDs, [w.a], "the shape stays selected")
        w.h.hold(.shift)
        w.h.click(at: w.row(3))
        expectEqual(w.items, ["r1", "r2", "r3"], "⇧: the run from the anchor")
        w.h.hold(.command)
        w.h.wait(200)
        w.h.click(at: w.row(2))
        expectEqual(w.items, ["r1", "r3"], "⌘: one toggled")
        w.h.hold([])
        w.h.wait(200)
        w.h.click(at: w.row(3))
        expectEqual(w.items, ["r3"], "a click on one of several: it alone")
        expectEqual(w.log.opened.count, 0)
        w.h.click(at: w.row(3))
        expectEqual(w.log.opened.map(\.0), ["r3"], "a click on the only item opens it")
        expectEqual(w.log.opened.first?.1.map { Int($0.y) }, 170, "from where it was clicked")
        w.h.click(at: w.h.view(CGPoint(x: 200, y: 220)))
        expectEqual(w.items, [], "a press on the shape off its items drops them")
        expectEqual(w.editor.selectedShapeIDs, [w.a])
        w.h.click(at: w.row(0))
        w.h.click(at: w.h.view(CGPoint(x: 450, y: 150)))
        expectEqual(w.items, [], "another shape: gone")
        expectEqual(w.editor.selectedShapeIDs, [w.b])
    },
    test("Keys on items, each with its exact way back: ↑ ↓ step, ⇧↑ ⇧↓ draw the run, ⌥↑ ⌥↓ ask the kind to move them, → ← open and close, ⌘A all, Return opens; Escape: items, the shape, nothing") {
        let w = try ItemsWindow()
        let walk = w.walk()
        w.editor.selectItems(["r0"], of: w.a)
        expectEqual(walk.focus.id, "canvas/A/r0")
        walk.expectAxis(down: .down, up: .up, over: ["canvas/A/r0", "canvas/A/r1", "canvas/A/r2", "canvas/A/r3"])
        w.editor.selectItems(["r1"], of: w.a)
        expectEqual(walk.press(Chord(Key.down, .shift)).id, "canvas/A/r1+r2")
        expectEqual(walk.press(Chord(Key.down, .shift)).id, "canvas/A/r1+r2+r3")
        expectEqual(walk.press(Chord(Key.up, .shift)).id, "canvas/A/r1+r2", "⇧↑ draws it back")
        expectEqual(walk.press(Chord(Key.up, .shift)).id, "canvas/A/r1")
        expectEqual(walk.press(Chord(Key.up, .shift)).id, "canvas/A/r0+r1", "past the anchor, it grows up")
        walk.press(Chord(Key.down, .option))
        walk.press(Chord(Key.up, .option))
        expectEqual(w.log.moved.map(\.0), [["r0", "r1"], ["r0", "r1"]])
        expectEqual(w.log.moved.map(\.1), [1, -1], "the kind's move, a place each way")
        let frame = w.editor.document[w.a]?.box
        expectEqual(w.editor.document[w.a]?.box, frame, "⌥ and an arrow resize nothing while items are selected")
        walk.press(Chord("a", .command))
        expectEqual(w.items, ["r0", "r1", "r2", "r3"], "⌘A: every item")
        w.editor.selectItems(["r3"], of: w.a)
        walk.press(.right)
        walk.press(.left)
        expectEqual(w.log.setOpen.map(\.1), [true, false], "→ opens, ← closes")
        walk.press(.space)
        expectEqual(w.log.setOpen.last?.1, true, "Space toggles")
        walk.press(.return)
        expectEqual(w.log.opened.map(\.0), ["r3"], "Return opens it")
        expectEqual(w.editor.document[w.a]?.box?.origin, CGPoint(x: 100, y: 100), "the arrows nudge nothing")
        walk.expectEscapeLadder(["canvas/A", "canvas"])
    },
    test("⌥Tab goes into a shape's items first, one stop (its first item), then its parts; ⌥⇧Tab back to the items left; the ring comes round to them") {
        let w = try ItemsWindow()
        let walk = w.walk()
        w.editor.selectedShapeIDs = [w.a]
        expectEqual(walk.press(.optionTab).id, "canvas/A/r0", "the first item: the rows are one level in, by keys")
        expectEqual(walk.press(.down).id, "canvas/A/r1", "↓ walks them")
        let part = walk.press(.optionTab).id
        expect(part.hasPrefix("canvas/A/") && w.items.isEmpty, "on to the first part, the items let go: \(part)")
        expectEqual(walk.press(.optionBackTab).id, "canvas/A/r1", "⌥⇧Tab back to the item left, not the first")
        let ringLast = walk.press(.optionBackTab).id
        expect(ringLast != "canvas/A/r1" && w.items.isEmpty, "⌥⇧Tab from the items: the ring's last part: \(ringLast)")
        expectEqual(walk.press(.optionTab).id, "canvas/A/r1", "⌥Tab its way back, to the item left")
        expectEqual(walk.press(.escape).id, "canvas/A", "Escape: back to the shape, the items forgotten")
        let last = walk.press(.optionBackTab).id
        expect(last != "canvas/A/r0" && w.items.isEmpty, "⌥⇧Tab from the shape: its last part, as ever: \(last)")
        expectEqual(walk.press(.optionTab).id, "canvas/A/r0", "⌥Tab from the last part comes round to the items")
        walk.expectEscapeLadder(["canvas/A", "canvas"])
    },
    test("Tab and ⇧Tab, and ⌥⌘ arrows, from an item: the opposite key comes back to the item, not only its shape") {
        let w = try ItemsWindow()
        let walk = w.walk()
        w.editor.selectItems(["r2"], of: w.a)
        expectEqual(walk.press(.tab).id, "canvas/B")
        expectEqual(walk.press(.backTab).id, "canvas/A/r2", "⇧Tab undoes Tab exactly")
        expectEqual(walk.press(Chord(Key.right, [.option, .command])).id, "canvas/B")
        expectEqual(walk.press(Chord(Key.left, [.option, .command])).id, "canvas/A/r2", "and ⌥⌘← ⌥⌘→")
    },
    test("Delete goes to the items, as the kind deletes them; never to a focused part; Undo restores the items with the step") {
        let w = try ItemsWindow()
        let walk = w.walk()
        w.editor.selectItems(["r1", "r2"], of: w.a)
        walk.press(.delete)
        expectEqual(w.log.deleted, [["r1", "r2"]])
        expectEqual(w.editor.document[w.a] != nil, true, "the shape stays")
        w.editor.selectItems(["r0"], of: w.a)
        w.editor.undo()
        expectEqual(w.items, ["r1", "r2"], "Undo selects what was selected as the step began")
        w.editor.redo()
        expectEqual(walk.press(.optionTab).id, "canvas/A/Left", "⌥Tab: a part, the items let go")
        expectEqual(w.items, [])
        walk.press(.delete)
        expectEqual(w.log.deleted.count, 1, "a focused part: Delete deletes nothing")
        expect(w.editor.document[w.a] != nil)
    },
    test("A selected item hidden behind another shows as the one standing for it, and comes back as itself") {
        let w = try ItemsWindow()
        w.editor.selectItems(["h1"], of: w.a)
        expectEqual(w.items, ["r3"], "h1 is hidden behind r3")
        w.log.r3Open = true
        w.editor.shapesDidChangeLayout([w.a])
        expectEqual(w.items, [], "shown again, h1 is no item of the fixture's: gone from what shows")
        w.log.r3Open = false
        w.editor.shapesDidChangeLayout([w.a])
        expectEqual(w.items, ["r3"])
    },
    test("Items are outlined inside their shape in the accent, a run at a time, and the shape's own outline gives way; nothing while another shape is selected") {
        let w = try ItemsWindow()
        let size = CGSize(width: 800, height: 500)
        w.editor.selection = w.a
        let shape = renderBitmap(w.editor, size: size)
        w.editor.selectItems(["r1", "r2"], of: w.a)
        let items = renderBitmap(w.editor, size: size)
        let run = w.h.view(CGPoint(x: 100, y: 120))
        expect(changedPixels(shape, items, in: CGRect(x: run.x + 2, y: run.y + 2, width: 4, height: 36)) > 0, "the run's left edge, inside the box")
        expect(changedPixels(shape, items, in: CGRect(x: run.x - 12, y: run.y + 50, width: 14, height: 40)) > 0, "the box's own outline gone")
        expectEqual(changedPixels(shape, items, in: CGRect(x: run.x + 20, y: run.y + 6, width: 100, height: 28)), 0, "a ring, not a fill")
    },
    test("VoiceOver: a shape's items are its first children, rows said selected as they are, before its ⌥Tab parts; the first selected has the focus") {
        let w = try ItemsWindow()
        w.editor.selectItems(["r2"], of: w.a)
        let parts = w.editor.accessibleParts(of: w.a)
        expectEqual(parts.prefix(4).map(\.title), ["Row 0", "Row 1", "Row 2", "Row 3"])
        expectEqual(parts.prefix(4).map(\.isSelected), [false, false, true, false])
        expect(parts.prefix(4).allSatisfy { $0.role == .row })
        expectEqual(parts.dropFirst(4).map(\.title), ["Left", "Right", "Handle"], "then the parts")
        expectEqual(w.editor.accessibleFocusedPart?.part, parts[2].id)
        parts[0].press(w.editor)
        expectEqual(w.items, ["r0"], "pressed, an item is selected")
    },
    test("A drag from a selected item asks the kind for a session to drag the selected items; with none given the shape is dragged; ⌘ held, the press is a brush as it was on any shape") {
        let w = try ItemsWindow()
        w.h.click(at: w.row(1))
        w.editor.selectItems(["r1", "r2"], of: w.a)
        w.log.givesDrag = true
        ItemDrag.ran = 0
        w.h.press(at: w.row(1))
        w.h.drag(to: w.h.view(CGPoint(x: 260, y: 140)))
        expectEqual(w.log.dragged, [["r1", "r2"]], "the selected items, from the press")
        expect(ItemDrag.ran > 0, "the kind's session runs")
        w.h.release()
        expectEqual(w.editor.document[w.a]?.box?.origin, CGPoint(x: 100, y: 100), "the shape stays")
        w.log.givesDrag = false
        w.editor.selectItems(["r1", "r2"], of: w.a)
        w.h.press(at: w.row(1))
        w.h.drag(to: w.h.view(CGPoint(x: 260, y: 160)))
        w.h.release()
        expect(w.editor.document[w.a]?.box?.origin != CGPoint(x: 100, y: 100), "none given: the shape is dragged")
        // ⌘ held: the brush, not the shape moved, and none of the items' drag.
        w.editor.undo()
        w.editor.selectItems(["r1"], of: w.a)
        w.log.dragged = []
        let origin = w.editor.document[w.a]?.box?.origin
        w.h.hold(.command)
        w.h.wait(200)
        w.h.press(at: w.row(1))
        w.h.drag(to: w.h.view(CGPoint(x: 700, y: 400)))
        expectEqual(w.log.dragged, [], "no drag of items")
        expect((w.editor.session.map { String(describing: type(of: $0)) } ?? "").contains("Brushing"), "a brush")
        w.h.release()
        expectEqual(w.editor.document[w.a]?.box?.origin, origin, "the shape did not move")
        w.h.hold([])
    },
    test("An item's lead is pressed before the faces: released, its click; past the threshold, its item dragged") {
        let w = try ItemsWindow()
        w.log.hasLead = true
        w.h.click(at: w.row(2))
        w.editor.selectItems(["r2"], of: w.a)
        let lead = w.h.view(CGPoint(x: 120, y: 110))
        w.h.click(at: lead)
        expectEqual(w.log.led, ["r0"], "a click on the lead runs its click")
        w.log.givesDrag = true
        ItemDrag.ran = 0
        w.h.press(at: lead)
        w.h.drag(to: w.h.view(CGPoint(x: 300, y: 200)))
        expectEqual(w.log.dragged, [["r0"]], "dragged from the lead: that item, selected")
        expect(ItemDrag.ran > 0)
        w.h.release()
        expectEqual(w.items, ["r0"])
    },
    test("A lead pressed on a shape not selected selects it only as a click: dragged, the selection waits for the drop, so the inspector it shows doesn't come in mid-drag") {
        let w = try ItemsWindow()
        w.log.hasLead = true
        w.log.givesDrag = true
        w.editor.selection = nil
        let lead = w.h.view(CGPoint(x: 120, y: 110))
        w.h.press(at: lead)
        expectEqual(w.editor.selectedShapeIDs, [], "the press selects nothing yet")
        w.h.drag(to: w.h.view(CGPoint(x: 300, y: 200)))
        expectEqual(w.log.dragged.last, ["r0"], "its item dragged")
        expectEqual(w.editor.selectedShapeIDs, [], "nothing selected while it's dragged")
        w.h.release()
        w.editor.selection = nil
        w.h.click(at: lead)
        expectEqual(w.editor.selectedShapeIDs, [w.a], "a click selects the shape, then runs the lead's click")
        expectEqual(w.log.led.last, "r0")
    },
    test("Rows another writer took out leave the shape selected with its outline and handles back; a run extended by key or click is said, a single step is not") {
        let w = try ItemsWindow(resizable: true)
        let size = CGSize(width: 800, height: 500)
        let corner = w.h.view(CGPoint(x: 300, y: 260))
        w.editor.selection = w.a
        expect(w.editor.handle(atViewPoint: corner) != nil, "the shape's own handles")
        let shape = renderBitmap(w.editor, size: size)
        w.editor.selectItems(["r1"], of: w.a)
        expectEqual(w.editor.handle(atViewPoint: corner) == nil, true, "items selected: the handles give way")
        w.log.listed = false
        w.editor.shapesDidChangeLayout([w.a])
        expectEqual(w.editor.selectedItems == nil, true, "none listed: none selected")
        expect(w.editor.handle(atViewPoint: corner) != nil, "the handles are back")
        let after = renderBitmap(w.editor, size: size)
        let run = w.h.view(CGPoint(x: 100, y: 120))
        expectEqual(changedPixels(shape, after, in: CGRect(x: run.x - 12, y: run.y + 50, width: 14, height: 40)), 0, "and the shape's own outline")
        w.log.listed = true
        w.editor.shapesDidChangeLayout([w.a])
        // What is said: a run grown or shrunk, not a step to one other.
        let walk = w.walk()
        w.editor.selectItems(["r0"], of: w.a)
        w.log.said = []
        walk.press(.down)
        expectEqual(w.log.said, [], "one item to one item: VoiceOver's focus says it")
        walk.press(Chord(Key.down, .shift))
        walk.press(Chord(Key.down, .shift))
        expectEqual(w.log.said, [2, 3], "the run grows, the count said")
        walk.press(Chord("a", .command))
        expectEqual(w.log.said.last, 4)
        w.h.hold(.shift)
        w.h.click(at: w.row(1))
        expectEqual(w.log.said.last, 2, "⇧ click: the run from the anchor to it")
        w.h.hold([])
    },
])
