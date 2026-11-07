import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Connections
import CoreGraphics
import Mentions
import Publishing
import References
import Selection
import ShippedTesting
import StickyNotes
import TestKit
import TextEditing
import Titles
import Topology

// ⌘L's picker as the app wires it: one shape selected and ⌘L lists every shape of the file it can be connected to, with where each
// is, and Itself last; two shapes Connect as before. A pick on another board is reached through a reference pill beside the
// shape, made or reused, in the same step. Over the nested file: the root's two notes and the subboard Plans, whose board holds two
// notes and the subboard inside it, holding two.

extension NestedWindow {
    /// ⌘L from the canvas, as the shortcut takes it.
    @discardableResult
    func pressConnect() -> Bool {
        window.makeFirstResponder(canvas)
        return canvas.performKeyEquivalent(with: window.keyEvent("l", code: 37, modifiers: .command))
    }

    var picker: ConnectPickerHost? { editor.connectPicker }
    var pickerField: EditingTextView? { picker?.field }
    var pickerHasKeyboard: Bool { pickerField.map { window.firstResponder === $0 } ?? false }

    /// Opens the picker on `shape` with the key and waits for the keyboard to reach it.
    func openPicker(on shape: ShapeID) throws {
        editor.selection = shape
        expect(pressConnect(), "⌘L")
        window.spin { self.pickerHasKeyboard }
        expect(pickerHasKeyboard, "the picker's field has the keyboard")
    }

    /// The picker's lines, as the list shows them.
    var lines: [CaretListItem] { picker?.picker?.list.rows.compactMap(\.item) ?? [] }
    var titles: [String] { lines.map(\.title) }

    /// The row of the line titled `title` (and, when two are called alike, saying `detail`).
    func row(_ title: String, detail: String? = nil) throws -> Int {
        let rows = picker?.picker?.list.rows ?? []
        return try require(rows.firstIndex { $0.item?.title == title && (detail == nil || $0.item?.detail == detail) }, "a line \(title): \(titles)")
    }

    /// Names a shape on a board, as its header does.
    func title(_ id: ShapeID, _ title: String, on board: BoardID) {
        editor.transact(on: board, "Rename") { $0.update(id) { $0[TitleProperty.self] = title } }
    }

    var arrows: [AnyShapeRecord] { editor.document.shapes.filter { $0.kind == Arrow.kind } }
    var pills: [AnyShapeRecord] { editor.document.shapes.filter { $0.kind == Reference.kind } }
}

@MainActor private func ends(_ editor: CanvasEditor, _ arrow: AnyShapeRecord) -> [ShapeID]? {
    editor.registry.connectionEnds(of: arrow).map { [$0.from, $0.to] }
}

@MainActor let connectPickerShippedTests = Suite("⌘L's picker, shipped", [
    test("⌘L on one shape opens the picker under it with the keyboard, listing every shape of the file by name, on every board, and Itself last; on two shapes it Connects at once") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let (a, b) = w.nest.notes(on: 1)
        let before = w.arrows.count
        try w.openPicker(on: a)
        let host = try require(w.picker)
        expect(host.isOpen)
        expectEqual(w.editor.card?.accessibilityLabel, "Connect from Note")
        expectEqual(w.pickerField?.accessibilityLabel(), "Connect to")
        expectEqual(w.titles.last, "Itself")
        expectEqual(Set(w.titles), ["Root, second", "Plans, first", "Plans, second", "Inside, first", "Inside, second", "Plans", "Untitled Subboard", "Itself"],
                    "the notes of every board and the subboards, not the shape itself: \(w.titles)")
        expectEqual(w.lines.first?.title, host.picker?.target(row: 0).flatMap { w.editor.accessibleDescription(of: $0)?.name }, "the first is highlighted")
        expectEqual(host.picker?.list.highlighted, 0)
        expectEqual(w.arrows.count, before, "listing writes nothing")
        w.window.pressEscape()
        w.window.spin { !host.isOpen && w.window.firstResponder === w.canvas }
        expect(!host.isOpen && w.window.firstResponder === w.canvas, "Escape gives the canvas the keyboard")
        expectEqual(w.editor.selectedShapeIDs, [a], "with the selection as it was")
        // Two shapes: today's Connect, no picker.
        w.editor.selectedShapeIDs = [a, b]
        expect(w.pressConnect())
        expect(!host.isOpen)
        expectEqual(w.arrows.count, before + 1)
        expectEqual(w.arrows.last.flatMap { ends(w.editor, $0) }, [a, b])
        expectEqual(w.editor.undoHistory.undoName, "Connect")
    },
    test("typing narrows the list as the @ picker ranks it; two shapes called alike say where each is, the board shown's without a place") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let (a, b) = w.nest.notes(on: 1)
        let (inPlans, _) = w.nest.notes(on: 2)
        w.title(b, "Checkout", on: .root)
        w.title(inPlans, "Checkout", on: w.nest.sBoard)
        try w.openPicker(on: a)
        let alike = w.lines.filter { $0.title == "Checkout" }
        expectEqual(alike.map(\.detail), ["Note", "Note · Plans"], "the board shown's first, then the one in Plans: \(w.lines.map { [$0.title, $0.detail ?? ""] })")
        w.window.type("checkout")
        w.window.settle()
        expectEqual(w.titles, ["Checkout", "Checkout", "Itself"])
        expectEqual(w.picker?.picker?.query, "checkout")
        w.window.type("zzzz")
        w.window.settle()
        expectEqual(w.titles, [], "a word that finds nothing leaves the list empty, so Return makes no loop")
        w.window.pressReturn()
        expect(w.picker?.isOpen == true, "Return picks nothing")
        expectEqual(w.arrows.count, 1)
    },
    test("picking Itself is today's loop: one arrow from the shape to itself, one step, Connect, with the connection hooks heard once; the selection stays") {
        var heard = 0
        let hook = Contributor(id: "heard") { registrar in registrar.connectionMade { _, _ in heard += 1 } }
        let w = try NestedWindow(extra: [hook])
        defer { w.board.close() }
        let (a, _) = w.nest.notes(on: 1)
        let before = w.arrows.count
        try w.openPicker(on: a)
        // ↑ from the first line wraps to the last: Itself.
        w.window.press(.up)
        expectEqual(w.picker?.picker?.list.highlightedItem?.title, "Itself")
        w.window.pressReturn()
        w.window.spin { w.picker?.isOpen == false }
        let loop = try require(w.arrows.last)
        expectEqual(w.arrows.count, before + 1)
        expectEqual(ends(w.editor, loop), [a, a])
        expectEqual(heard, 1)
        expectEqual(w.editor.undoHistory.undoName, "Connect")
        expectEqual(w.editor.selectedShapeIDs, [a])
        expect(w.window.firstResponder === w.canvas, "the canvas has the keyboard")
        w.editor.undo()
        expectEqual(w.arrows.count, before, "one Undo takes the loop back")
    },
    test("a pick on the board shown draws the arrow to that shape: one step, Connect, hooks once; no pill") {
        var heard = 0
        let hook = Contributor(id: "heard") { registrar in registrar.connectionMade { _, _ in heard += 1 } }
        let w = try NestedWindow(extra: [hook])
        defer { w.board.close() }
        let (a, b) = w.nest.notes(on: 1)
        let before = w.arrows.count
        try w.openPicker(on: a)
        w.window.type("root second")
        w.window.settle()
        w.window.pressReturn()
        w.window.spin { w.picker?.isOpen == false }
        expectEqual(w.arrows.count, before + 1)
        expectEqual(w.arrows.last.flatMap { ends(w.editor, $0) }, [a, b])
        expect(w.pills.isEmpty)
        expectEqual(heard, 1)
        expectEqual(w.editor.undoHistory.undoName, "Connect")
    },
    test("a pick on another board puts a reference pill beside the shape and draws the arrow to it, in one step; a second pick of it reuses the pill") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let (a, _) = w.nest.notes(on: 1)
        let (far, _) = w.nest.notes(on: 2)
        let before = w.arrows.count
        try w.openPicker(on: a)
        w.window.type("plans first")
        w.window.settle()
        expectEqual(w.titles.first, "Plans, first", "the other board's, with where it is: \(w.titles)")
        expectEqual(w.lines.first?.detail, "Plans")
        expectEqual(w.titles.last, "Itself")
        w.window.pressReturn()
        w.window.spin { w.picker?.isOpen == false }
        let pill = try require(w.pills.first, "a pill on the board shown")
        expectEqual(w.pills.count, 1)
        expectEqual(w.editor.topology?.standingKinds(of: pill.id), [StickyNote.kind])
        let arrow = try require(w.arrows.last)
        expectEqual(w.arrows.count, before + 1)
        expectEqual(ends(w.editor, arrow), [a, pill.id])
        expectEqual(w.editor.undoHistory.undoName, "Connect")
        // The pill is beside the shape, clear of it.
        let aBox = try require(w.editor.document[a]?.box), pillBox = try require(pill.box)
        expect(!aBox.intersects(pillBox), "\(aBox) \(pillBox)")
        expectEqual(w.editor.shape(inFile: far)?.kind, StickyNote.kind)
        // Again: the board has its pill, so the second arrow ends on it.
        try w.openPicker(on: a)
        w.window.type("plans first")
        w.window.settle()
        w.window.pressReturn()
        w.window.spin { w.picker?.isOpen == false }
        expectEqual(w.pills.count, 1, "one pill however many arrows reach the shape")
        expectEqual(w.arrows.count, before + 2)
        expectEqual(w.arrows.last.flatMap { ends(w.editor, $0) }, [a, pill.id])
        w.editor.undo()
        expectEqual(w.pills.count, 1, "the second pick left the pill alone")
        w.editor.undo()
        expectEqual(w.pills.count, 0, "one Undo takes back the arrow and the pill the first pick made")
        expectEqual(w.arrows.count, before)
    },
    test("a private far shape is listed `will be made public`, and its pick makes it public in the step, one Undo back") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let (a, _) = w.nest.notes(on: 1)
        let (far, _) = w.nest.notes(on: 2)
        w.editor.transact(on: w.nest.sBoard, "Make Private") { $0.update(far) { $0[PrivateProperty.self] = true } }
        try w.openPicker(on: a)
        w.window.type("plans first")
        w.window.settle()
        let line = try require(w.lines.first)
        expectEqual(line.title, "Plans, first")
        expect(line.detail?.contains("will be made public") == true, "\(line.detail ?? "")")
        expect(line.spoken.contains("will be made public"), line.spoken)
        w.window.pressReturn()
        w.window.spin { w.picker?.isOpen == false }
        expectEqual(w.editor.shape(inFile: far)?[PrivateProperty.self], nil, "public now")
        expectEqual(w.pills.count, 1)
        w.editor.undo()
        expectEqual(w.editor.shape(inFile: far)?[PrivateProperty.self], true, "private again with the arrow gone")
        expectEqual(w.pills.count, 0)
    },
    test("a pick the kind's plan refuses shakes the shape and leaves no step; a plan names the step, writes first inside it, and a kind can leave picks out of the list") {
        let blocked = NestedFile().notes(on: 1).1
        let plans = Contributor(id: "plans") { registrar in
            registrar.connectPicks(StickyNote.self, admitting: { pick, _ in pick.to.shape != blocked }) { pick, editor in
                guard pick.to.shape != pick.from.shape else { return nil }
                return ConnectPlan(step: "Add Key Column", from: pick.from, to: pick.to) { transaction in
                    let key = AnyShapeRecord(ShapeRecord(StickyNote(frame: CGRect(x: 900, y: 900, width: 100, height: 100))))
                    transaction.insert(key)
                    return (ConnectEnd(key.id), pick.to)
                }
            }
        }
        let w = try NestedWindow(extra: [plans])
        defer { w.board.close() }
        let (a, b) = w.nest.notes(on: 1)
        try w.openPicker(on: a)
        expect(!w.titles.contains("Root, second"), "the pick the kind does not admit is not listed: \(w.titles)")
        expectEqual(w.titles.last, "Itself", "Itself is listed: the kind admits it, and refuses it below")
        // Itself: the plan gives none, so it shakes.
        let steps = w.editor.undoHistory.undoName
        let notes = w.editor.document.shapes.count
        w.window.press(.up)
        w.window.pressReturn()
        w.window.spin { w.picker?.isOpen == false }
        expect(w.editor.service(RefusalShake.self)?.isShaking == true, "the source shakes")
        expectEqual(w.editor.undoHistory.undoName, steps, "no step")
        expectEqual(w.editor.document.shapes.count, notes)
        // A shape in the list: the plan's step, the key written first, the arrow from it.
        try w.openPicker(on: a)
        w.window.type("plans first")
        w.window.settle()
        w.window.pressReturn()
        w.window.spin { w.picker?.isOpen == false }
        expectEqual(w.editor.undoHistory.undoName, "Add Key Column")
        let key = try require(w.editor.document.shapes.last { $0.kind == StickyNote.kind && $0.id != a && $0.id != b })
        expect(w.arrows.last.flatMap { ends(w.editor, $0) }?.first == key.id, "from the note the plan wrote")
        w.editor.undo()
        expect(w.editor.document[key.id] == nil, "one Undo takes back the note and the arrow")
        expectEqual(w.pills.count, 0)
    },
    test("⌘L in a note's words ends editing, its words kept, and opens the picker; Escape then gives the canvas the keyboard") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let menus = BoardMenus.make(appName: "Infinite Canvas", registry: w.editor.registry)
        for item in menus.main.items.compactMap(\.submenu).flatMap(\.items) { item.target = w.controller }
        let (a, _) = w.nest.notes(on: 1)
        w.editor.selection = a
        expect(w.editor.beginEditing(a))
        w.window.spin { w.window.firstResponder is NSText }
        w.window.type(" more")
        expect(menus.main.performKeyEquivalent(with: w.window.keyEvent("l", code: 37, modifiers: .command)), "the menu bar's key")
        w.window.spin { w.pickerHasKeyboard }
        expect(w.pickerHasKeyboard, "the picker has the keyboard")
        expectEqual(w.editor.editingShapeID, nil, "editing ended")
        expect(w.editor.document[a]?.typed(as: StickyNote.self)?.props.text.plainText().hasSuffix("more") == true, "its words kept")
        w.window.pressEscape()
        w.window.spin { w.picker?.isOpen == false && w.window.firstResponder === w.canvas }
        expect(w.window.firstResponder === w.canvas)
        expectEqual(w.editor.selectedShapeIDs, [a])
    },
    test("the walk: ⌘L goes into the picker, ↓ and ↑ cycle its lines and undo each other, Tab picks, Escape and ⌘. come back to the canvas and the selection, other keys type or do nothing, and VoiceOver hears the card, the field and the lines") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let (a, _) = w.nest.notes(on: 1)
        w.editor.selection = a
        w.window.makeFirstResponder(w.canvas)
        let walk = KeyWalk(w.window, editor: w.editor, readers: [.canvas(w.canvas, editor: w.editor, names: [a: "A"])])
        expectEqual(walk.focus.id, "canvas/A")
        let field = walk.press(Chord("l", .command))
        expectEqual(field.id, "window/Connect to")
        expectEqual(field.label, "Connect to")
        expect(field.isMarked, "a caret")
        // The lines cycle: ↓ to the last and past it to the first, ↑ the exact way back.
        let list = try require(w.picker?.picker?.list)
        let count = w.lines.count
        expect(count > 2)
        for step in 1...count {
            walk.press(.down)
            expectEqual(list.highlighted, step % count, "↓ \(step)")
        }
        for step in 1...count {
            walk.press(.up)
            expectEqual(list.highlighted, (count - step) % count, "↑ \(step)")
        }
        walk.press(.down)
        walk.press(Chord.backTab)
        expectEqual(list.highlighted, 0, "⇧Tab moves the highlight up")
        walk.press(.pageDown)
        expectEqual(list.highlighted, min(count - 1, list.metrics.rowsShown), "a page")
        walk.press(.pageUp)
        expectEqual(list.highlighted, 0)
        // Keys with no use there type into the field and change nothing of the board: no tool, no shape deleted.
        let revision = w.editor.revision, tool = w.editor.currentToolID
        for key in [Chord("v"), Chord("n"), Chord("f"), Chord("1")] { walk.press(key) }
        expectEqual(w.pickerField?.string, "vnf1")
        for _ in 0..<4 { walk.press(.delete) }
        walk.press(.forwardDelete)
        expectEqual(w.pickerField?.string, "")
        expectEqual(w.editor.revision, revision)
        expectEqual(w.editor.currentToolID, tool)
        expect(w.editor.document[a] != nil, "the shape is still there")
        expect(w.picker?.isOpen == true)
        // VoiceOver and focus: the keyboard shows (a caret, in view), the card and the field are named, the lines are said, the last Itself.
        let now = walk.focus
        expect(now.isMarked, "a caret")
        expect(!(now.role ?? "").isEmpty && !(now.label ?? "").isEmpty, "role \(now.role ?? "-"), label \(now.label ?? "-")")
        if let frame = now.frame, let content = w.window.contentView {
            expect(frame.intersects(content.convert(content.bounds, to: nil)), "in view")
        }
        expectEqual(w.editor.card?.accessibilityLabel, "Connect from Note")
        expectEqual(w.lines.last?.spoken, "Itself")
        expect(w.lines.first?.spoken.contains("1 of") == true, w.lines.first?.spoken ?? "")
        // Escape comes back exactly: the canvas, the selection.
        walk.expectEscapeLadder(["canvas/A"])
        expect(w.picker?.isOpen == false)
        expectEqual(w.editor.revision, revision)
        // ⌘. does the same; Tab picks.
        walk.press(Chord("l", .command))
        let closed = walk.press(.commandPeriod)
        expectEqual(closed.id, "canvas/A", "⌘. closes it")
        walk.press(Chord("l", .command))
        walk.press(.tab)
        expect(w.picker?.isOpen == false)
        expectEqual(w.editor.undoHistory.undoName, "Connect", "Tab picked the first line")
        expectEqual(w.editor.selectedShapeIDs, [a])
    },
    test("the Shape menu has Connect To… with ⌘L on one shape, Connect on two") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let (a, b) = w.nest.notes(on: 1)
        w.editor.selection = a
        let one = try require(w.editor.menuForSelection(omitting: []))
        let item = try require(one.item(withTitle: "Connect To…"), "\(one.outline)")
        expectEqual(KeyboardShortcutSection.key(of: item), "⌘L")
        w.editor.selectedShapeIDs = [a, b]
        let two = try require(w.editor.menuForSelection(omitting: []))
        expect(two.item(withTitle: "Connect") != nil && two.item(withTitle: "Connect To…") == nil, "\(two.outline)")
    },
])

/// ⌘L on the one shape selected, and its Itself picked: what ⌘L did to one shape before the picker.
@MainActor func connectToItself(_ editor: CanvasEditor, file: StaticString = #fileID, line: UInt = #line) {
    editor.perform(.connect)
    guard let host = editor.connectPicker, let row = host.picker?.rows.firstIndex(of: .itself) else {
        return expect(false, "the picker lists Itself", file: file, line: line)
    }
    host.pick(row: row)
}
