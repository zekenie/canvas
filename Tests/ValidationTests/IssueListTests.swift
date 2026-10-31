@_spi(Host) import Canvas
import AppKit
import CanvasTesting
import CanvasUI
import CoreGraphics
import DetailPanel
import Foundation
import Keyboard
import Observation
import Selection
import SwiftUI
import TestKit
import Topology
import Validation

// The issue walk's list (Issue List ⌃⌘', `IssueList`): the walk's rows by board in the panel's row list over the current
// stop's Issues tab. Hosted as `issueBandTests` host the band (`BandScene`: the panel and a canvas in an unshown window over this
// suite's cards, pockets and links), with a fixture contributor of the row value. The file's stops, in board order: the
// root's A, B and the link, then the pocket's board (headed "Texas") C, D and D again (two issues). The table's rows are the
// lines: a head per board and the rows of the boards unfolded. What SwiftUI draws in a row is read through `IssueWalk.line(of:)`,
// the model the row is drawn from; the table's own accessibility label is read as AppKit gives it.

private let shapes = walkShapes
private let texas = BoardID(owner: shapes.pocket)
private let ctrlCommandQuote = Chord("'", [.command, .control])

/// The shapes' first value, as Types' fields would give a note's: the card's words, for a plugin that opted every shape in.
private func rowValues() -> Contributor {
    Contributor(id: "row-values") { r in
        r.forEveryShape { every in
            every.issueRowValue { record, _ in record.typed(as: Card.self).map { "v:\($0.props.text)" } }
        }
    }
}

/// A contributor of a card's first value that gives `answer` for every card.
private func answering(_ id: String, _ answer: String?) -> Contributor {
    Contributor(id: PluginID(id)) { r in
        r.forEveryShape { every in
            every.issueRowValue { record, _ in record.typed(as: Card.self) == nil ? nil : answer }
        }
    }
}

/// How often the value of a row was asked: once for each time a row is drawn.
@MainActor private enum RowDraws {
    static var count = 0
}

/// The shapes' first value as `rowValues()` gives it, counting how often it is asked: a row asks once as it is drawn.
private func countedRowValues() -> Contributor {
    Contributor(id: "counted-row-values") { r in
        r.forEveryShape { every in
            every.issueRowValue { record, _ in
                MainActor.assumeIsolated { RowDraws.count += 1 }
                return record.typed(as: Card.self).map { "v:\($0.props.text)" }
            }
        }
    }
}

/// Cards that each have an error, on the root after the fixture's own (so the last stops of the root, before Texas's): the root
/// is a long board.
@MainActor private func addCards(_ n: Int, to editor: CanvasEditor) -> [ShapeID] {
    let ids = (0..<n).map { walkID(100 + $0) }
    editor.transact("Many") { t in
        for (offset, id) in ids.enumerated() {
            t.insert(AnyShapeRecord(ShapeRecord(id: id, Card(CGRect(x: 40 + offset * 4, y: 400, width: 100, height: 60), text: "bad"))))
        }
    }
    return ids
}

/// A root of a card and three subboards, each holding two cards that have an error: the stops are on the subboards, in the
/// order of their owners on the root.
private enum ThreeBoards {
    static let card = walkID(300), one = walkID(301), two = walkID(302), three = walkID(303)
    static let frame = CGRect(x: 0, y: 0, width: 100, height: 60)

    static func cards(_ n: Int) -> [AnyShapeRecord] {
        [AnyShapeRecord(ShapeRecord(id: walkID(n + 1), Card(frame, text: "bad"))), AnyShapeRecord(ShapeRecord(id: walkID(n + 2), Card(frame, text: "bad")))]
    }

    @MainActor static var file: CanvasFile {
        CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: card, Card(frame, text: "fine"))),
                                                 AnyShapeRecord(ShapeRecord(id: one, Pocket(frame))), AnyShapeRecord(ShapeRecord(id: two, Pocket(frame))),
                                                 AnyShapeRecord(ShapeRecord(id: three, Pocket(frame)))]),
                   children: [one: CanvasDocument(shapes: cards(310)), two: CanvasDocument(shapes: cards(320)), three: CanvasDocument(shapes: cards(330))])
    }
}

/// What `BoardWindowController.runCommand(_:)` does for a menu item.
@MainActor private final class CommandRunner: NSObject {
    let editor: CanvasEditor
    init(_ editor: CanvasEditor) { self.editor = editor }
    @objc func runCommand(_ sender: Any?) {
        if let item = sender as? NSMenuItem, let command = BoardMenus.command(of: item) { editor.perform(command) }
    }
}

/// The color the fixture gives a card as its tint, changed by a test that then says so (`editor.shapeTintsDidChange()`).
@MainActor private enum CardTint {
    static var color: NSColor?
}

private func cardTints() -> Contributor {
    Contributor(id: "card-tints") { r in
        r.shapeTints { record, _ in MainActor.assumeIsolated { record.typed(as: Card.self) == nil ? nil : CardTint.color } }
    }
}

/// What the table draws in a line, as a picture of its row: two pictures are the same only when the row looks the same.
@MainActor private func picture(ofLine line: Int, in scene: BandScene) throws -> Data {
    let table = try require(scene.table)
    let area = table.convert(table.rect(ofRow: line), to: scene.hosting)
    let rep = try require(scene.hosting.bitmapImageRepForCachingDisplay(in: area))
    scene.hosting.cacheDisplay(in: area, to: rep)
    return try require(rep.representation(using: .png, properties: [:]))
}

@MainActor extension BandScene {
    var table: NSTableView? { hosting.descendants(NSTableView.self).first }
    var lines: Int { table?.numberOfRows ?? 0 }
    var listHasKeyboard: Bool { table != nil && window.firstResponder === table }

    /// Begins a walk at the first stop, opens the list and waits for its lines.
    func openList(lines expected: Int = 5, at entry: IssueEntry = .first) {
        begin(.all, at: entry)
        walk.toggleList()
        window.spin { self.lines == expected && self.listHasKeyboard }
    }

    /// A key in the list, then the walk's place once the list's selection has reached it (the table tells SwiftUI a turn on).
    func press(_ chord: Chord, reaching shape: ShapeID? = nil, file: StaticString = #fileID, line: UInt = #line) {
        keys.press(chord)
        if let shape { window.spin(until: { self.walk.currentRow?.shape == shape }, file: file, line: line) } else { for _ in 0..<4 { window.settle() } }
    }

    /// The key as the menu bar takes it (a key equivalent of an item), the keyboard wherever it is.
    @discardableResult
    func pressItem(_ chord: Chord) -> Delivery {
        let editor = editor
        let menus = BoardMenus.make(appName: "Test", registry: editor.registry, editor: { editor })
        // The window controller's one action, run by a stand-in that does what it does: the item's command on this editor.
        let runner = CommandRunner(editor)
        func aim(_ menu: NSMenu) {
            for item in menu.items {
                if item.action == #selector(BoardWindowController.runCommand(_:)) { item.target = runner }
                if let submenu = item.submenu { aim(submenu) }
            }
        }
        aim(menus.main)
        let delivery = window.press(chord, menu: menus.main)
        window.settle()
        return delivery
    }

    /// The lines until the list is as it should be.
    func waitForLines(_ n: Int) { window.spin { self.lines == n } }

    /// The scroll view of the evidence under the list: the one that is not the list's.
    var evidenceScroll: NSScrollView? {
        hosting.descendants(NSScrollView.self).first { scroll in
            scroll.documentView.map { !($0 is NSTableView) } ?? false && scroll.convert(scroll.bounds, to: hosting).minY > 100
        }
    }

    /// The buttons under the band and outside the list's table: the evidence's.
    var evidenceButtons: [NSButton] {
        hosting.descendants(NSButton.self).filter { button in
            button.convert(button.bounds, to: hosting).maxY > 40 && !(table.map { button.isDescendant(of: $0) } ?? false)
        }
    }
}

/// What a takeover standing in for Find's reads: whether it is active.
@Observable @MainActor private final class StandIn {
    var isActive = false
}

/// A takeover listed before the walk's panel, as Find's is (the first active shows): a text field named "Stand-in".
@MainActor private func standIn(_ model: StandIn) -> Contributor {
    Contributor(id: "stand-in") { r in
        r.detailTakeover(isActive: { _ in model.isActive }, onEscape: { _ in model.isActive = false }) { _, _ in
            TextField("Stand-in", text: .constant("")).padding()
        }
    }
}

@MainActor let issueListTests = Suite("The issue walk's list", [
    test("the light follows the walk's own list: Find's panel opened over the open list closes it and takes the light with it, and closing Find leaves the shape's panel") {
        let model = StandIn()
        let s = try BandScene(before: [standIn(model)])
        s.openList()
        expect(s.walk.isListShown, "the list is what the panel shows")
        s.window.spin { s.editor.issueLights?.isLit == true }
        expect(s.editor.issueLights?.isLit == true, "the keyboard is in the walk's list: the other stops are lit")
        // The stand-in opens over the list and takes the keyboard: the list is closed, so it is not left open behind it.
        model.isActive = true
        s.window.spin { !s.walk.isListShown }
        s.window.spin { s.hosting.descendants(NSTextField.self).contains { $0.placeholderString == "Stand-in" } }
        let field = try require(s.hosting.descendants(NSTextField.self).first { $0.placeholderString == "Stand-in" })
        expect(s.window.makeFirstResponder(field), "the keyboard in the stand-in's field")
        s.window.settle()
        expect(!s.walk.isListOpen, "the walk's list is closed: it is not open behind another takeover")
        expect(s.editor.detailPanel?.keyboardPlace == .takeover)
        s.window.spin { s.editor.issueLights?.isLit == false }
        expect(s.editor.issueLights?.isLit == false, "the keyboard is in another takeover: the walk's stops are not lit")
        // It closes: the shape's panel shows, not the list.
        model.isActive = false
        s.window.settle()
        expect(!s.walk.isListOpen && !s.walk.isListShown, "the list stays closed")
        expect(s.table == nil, "the shape's panel shows")
        expect(s.walk.isRunning, "the walk goes on")
        s.walk.end()
        expect(!s.walk.isListShown)
    },
    test("another takeover over the list: the list closes without moving the keyboard, Issue List is dimmed, and works again once it goes") {
        let model = StandIn()
        let s = try BandScene(before: [standIn(model)])
        s.openList()
        expect(s.editor.canPerform(.issueList) && s.walk.canToggleList, "Issue List works with nothing over the list")
        model.isActive = true
        s.window.spin { !s.walk.isListShown }
        s.window.spin { s.hosting.descendants(NSTextField.self).contains { $0.placeholderString == "Stand-in" } }
        let field = try require(s.hosting.descendants(NSTextField.self).first { $0.placeholderString == "Stand-in" })
        expect(s.window.makeFirstResponder(field), "the keyboard in the stand-in's field")
        s.window.settle()
        expect(!s.walk.isListOpen, "the list is closed")
        expect(s.walk.isRunning, "the walk goes on")
        expect((s.window.firstResponder as? NSText)?.delegate === field, "the keyboard stays in the stand-in's field")
        expect(!s.editor.canPerform(.issueList) && !s.walk.canToggleList, "Issue List is dimmed while the stand-in shows")
        // The key does nothing: it opens no list behind the stand-in and takes no keyboard from its field.
        expect(!s.editor.perform(.issueList))
        s.walk.toggleList()
        s.walk.openList()
        s.window.settle()
        expect(!s.walk.isListOpen, "no list is opened behind it")
        expect((s.window.firstResponder as? NSText)?.delegate === field, "the keyboard is still in the stand-in's field")
        expect(s.count.map { !$0.isEnabled } ?? false, "the band's count is dimmed with it")
        // Closing it brings the shape's panel, not the list, and Issue List again.
        model.isActive = false
        s.window.settle()
        expect(s.table == nil && !s.walk.isListOpen, "the shape's panel shows")
        expect(s.editor.canPerform(.issueList), "Issue List works again")
        expect(s.count?.isEnabled == true, "and the count")
        expect(s.editor.perform(.issueList))
        s.window.spin { s.lines > 0 }
        expect(s.walk.isListOpen && s.table != nil, "the list opens")
    },
    test("another takeover opening over the list with the keyboard on the count: the count keeps the keyboard, nothing opens, and it is dimmed once the keyboard leaves") {
        let model = StandIn()
        let s = try BandScene(before: [standIn(model)])
        s.openList()
        let count = try require(s.count)
        expect(s.focus(count), "the keyboard on the count")
        let output = standardError(during: {
            model.isActive = true
            s.window.spin { !s.walk.isListShown }
            s.window.settle()
            s.window.settle()
        })
        expect(!s.editor.canPerform(.issueList), "Issue List is off while the stand-in shows")
        // Nothing in the stand-in takes the keyboard, so it stays where it was: on the count, never left on the window.
        expect(s.window.firstResponder === count, "the keyboard stays on the count (\(String(describing: s.window.firstResponder)))")
        expect(count.isEnabled, "the count is not dimmed under the keyboard")
        s.click(count)
        expect(!s.walk.isListOpen, "and its press opens nothing")
        expect(!output.contains("AttributeGraph"), "no cycle: \(output)")
        // The keyboard leaves it: dimmed, as before.
        expect(s.window.makeFirstResponder(s.canvas))
        s.window.settle()
        s.window.settle()
        expect(!count.isEnabled, "the count is dimmed once the keyboard is gone")
    },
    test("ending the walk with the keyboard in the list on an ignored stop gives the canvas the keyboard, never the window") {
        let s = try BandScene()
        s.openList(at: .shape(shapes.b))
        expect(s.walk.ignoreCurrent())
        s.window.spin { s.walk.currentRow?.state == .ignored }
        s.window.spin { s.evidenceButtons.isEmpty }
        expect(s.evidenceButtons.isEmpty, "the ignored stop has no warning line, so nothing under the list takes the keyboard back")
        s.window.spin { s.listHasKeyboard }
        expect(s.listHasKeyboard, "the keyboard is in the list")
        let exits = s.exits
        s.walk.end()
        s.window.spin { s.table == nil && !s.hasBand }
        s.window.spin { s.canvasHasKeyboard }
        expect(s.canvasHasKeyboard, "the canvas has the keyboard (\(String(describing: s.window.firstResponder)))")
        expect(s.exits > exits, "the panel gave it back")
    },
    test("a list closed gives the Tab ring back to the panel's controls: Tab from the band never reaches a view that left the window") {
        let s = try BandScene()
        s.begin()
        expect(s.focus(s.next), "the keyboard in the band")
        s.walk.toggleList()
        s.window.spin { s.listHasKeyboard }
        // Escape as the panel does it: the takeover's escape, then the keyboard to the band, before SwiftUI has removed the list.
        s.walk.closeListOnEscape()
        // With Keyboard navigation off the band's buttons take no key and the keyboard stays where it is, and the ring
        // isn't the one that setting makes: only the list's closing is checked then.
        expect(s.editor.detailPanel?.focusBand() == true || !s.keys.keyboardNavigation, "the band has the keyboard")
        s.window.spin { s.table == nil }
        guard s.keys.keyboardNavigation else {
            FileHandle.standardError.write(Data("skipped: the Tab ring after the list closes (Keyboard navigation is off; the list's closing is checked)\n".utf8))
            return
        }
        // The ring is made again once the list's views are gone.
        for _ in 0..<6 { s.window.settle() }
        let start = try require(s.bandButtons.first)
        expect(s.window.makeFirstResponder(start))
        var view: NSView = start
        for step in 1...40 {
            guard let nextView = view.nextKeyView else {
                expect(false, "the ring ends at a view with no next after \(step) steps")
                return
            }
            expect(nextView.window === s.window, "step \(step): the next stop is in the window")
            if nextView === start { return }
            view = nextView
        }
        expect(false, "the ring comes round to where it began")
    },
    test("the list opens over the panel with the heads and rows in the walk's board order, every board folded but the current stop's") {
        let s = try BandScene()
        s.begin()
        expect(s.table == nil, "no list yet")
        s.walk.toggleList()
        s.window.spin { s.lines > 0 }
        expect(s.walk.isListOpen)
        expectEqual(s.walk.boards.map(\.board), [.root, texas], "the root's shapes, then the board under it")
        expectEqual(s.walk.boards.map(\.open), [3, 3], "A, B and the link; C, D and D")
        expectEqual(s.editor.boardHeading(of: .root).title, "Root")
        expectEqual(s.editor.boardHeading(of: texas).title, "Texas")
        expectEqual(s.lines, 5, "two heads and the root's three rows: Texas is folded")
        expectEqual(s.walk.currentRow?.shape, shapes.a)
    },
    test("a step to a folded board unfolds it and folds the board it leaves: a walk through the file builds the board it is in") {
        let s = try BandScene()
        s.openList()
        expect(s.listHasKeyboard, "opening puts the keyboard in the list: \(s.keys.traceText)")
        // Which board is unfolded is told by the line the highlight is on, which is false before each step.
        for _ in 0..<3 { s.walk.step(forward: true) }
        expectEqual(s.walk.currentRow?.shape, shapes.c)
        s.window.spin { s.table?.selectedRow == 2 }
        expectEqual(s.table?.selectedRow, 2, "Texas unfolds as the walk reaches it: the highlight is on C's row, the first under Texas's head (the root's head above it, folded)")
        expectEqual(s.lines, 5, "the root folds as it leaves: two heads and Texas's three rows")
        s.walk.step(forward: false)
        expectEqual(s.walk.currentRow?.shape, shapes.link)
        s.window.spin { s.table?.selectedRow == 3 }
        expectEqual(s.table?.selectedRow, 3, "the root unfolds again: the highlight is on the link's row, its third")
        expectEqual(s.lines, 5, "and Texas folds: the heads and the root's three rows")
    },
    test("the current stop's shape moved onto another board while the list is open: that board unfolds, and the one it left folds") {
        let s = try BandScene()
        s.openList()
        expectEqual(s.walk.currentRow?.shape, shapes.a)
        expectEqual(s.table?.selectedRow, 1, "A's row, the first under the root's head")
        // One commit moves A onto Texas's board (Move To ▸, a drop onto the subboard's card): the same stop, on another board.
        s.editor.transact(on: .root, "Move") { t in expect(t.move([shapes.a], toBoardOwnedBy: shapes.pocket)) }
        s.window.spin { s.walk.currentRow?.board == texas }
        expectEqual(s.walk.currentRow?.shape, shapes.a, "the stop is kept")
        // Texas now holds A with C and D (4 rows), the root B and the link (2): the line count says which board shows its rows.
        s.window.spin { s.lines == 6 }
        expectEqual(s.lines, 6, "two heads and Texas's four rows: the root folded")
        let row = try require(s.walk.boards.first { $0.board == texas }?.rows.lowerBound)
        expectEqual(s.walk.rows[row].board, texas)
        expect((s.table?.selectedRow ?? -1) >= 2, "the highlight is on the stop's row under Texas's head")
    },
    test("← folds a board and → unfolds it, and a board the person unfolded stays unfolded as the walk leaves it") {
        let s = try BandScene()
        s.openList()
        for _ in 0..<3 { s.walk.step(forward: true) }
        expectEqual(s.walk.currentRow?.shape, shapes.c)
        s.waitForLines(5)
        // ← on a row goes up to its head, ← on the head folds it, → unfolds.
        s.press(.left)
        expectEqual(s.walk.currentRow?.shape, shapes.c, "the head takes the highlight and moves nothing")
        s.press(.left)
        s.waitForLines(2)
        expectEqual(s.lines, 2, "Texas folded, its three rows go")
        s.press(.right)
        s.waitForLines(5)
        expectEqual(s.lines, 5, "and → brings them back")
        expectEqual(s.walk.currentRow?.shape, shapes.c)
        // The person opened Texas: it stays as the walk goes back to the root, which opens as the walk reaches it.
        s.walk.step(forward: false)
        expectEqual(s.walk.currentRow?.shape, shapes.link)
        s.waitForLines(8)
        expectEqual(s.lines, 8, "the root's rows and Texas's")
        // The root was the walk's: it folds as the walk leaves it for Texas, which stays as it is.
        s.walk.step(forward: true)
        expectEqual(s.walk.currentRow?.shape, shapes.c)
        s.waitForLines(5)
        expectEqual(s.lines, 5, "the root folded")
    },
    test("a step to the stop the walk is at unfolds its board when the person folded it") {
        let s = try BandScene()
        s.walk.begin(walkScope("meh", candidates: [shapes.b]), at: .first)
        s.window.spin { !s.walk.isGathering && s.walk.rows.count == 1 }
        s.walk.toggleList()
        s.window.spin { s.lines == 2 && s.listHasKeyboard }
        expectEqual(s.lines, 2, "the root's head and B")
        // The head's fold: the highlight is on B's row, which goes up to the head, and the head folds.
        s.press(.left)
        s.press(.left)
        s.waitForLines(1)
        expectEqual(s.lines, 1, "the root folded")
        // The only stop: the step lands on the key the walk is at, and its board shows it.
        s.editor.perform(.nextIssue)
        s.waitForLines(2)
        expectEqual(s.lines, 2, "the board is unfolded and the highlight is on a line")
        expectEqual(s.table?.selectedRow, 1, "on B's row")
    },
    test("↑ and ↓ move the walk: the stop's shape is selected and its board shown; a head moves nothing, and ↑ undoes ↓") {
        let s = try BandScene()
        s.openList()
        expectEqual(s.editor.selectedShapeIDs, [shapes.a])
        s.press(.down, reaching: shapes.b)
        expectEqual(s.editor.selectedShapeIDs, [shapes.b], "the stop's shape is selected")
        s.press(.down, reaching: shapes.link)
        s.press(.down)
        expectEqual(s.walk.currentRow?.shape, shapes.link, "the next line is Texas's head: the walk stays")
        expectEqual(s.editor.selectedShapeIDs, [shapes.link])
        expectEqual(s.editor.board, .root)
        s.press(.up)
        expectEqual(s.walk.currentRow?.shape, shapes.link, "back on the row it left")
        s.press(.up, reaching: shapes.b)
        s.press(.up, reaching: shapes.a)
        expectEqual(s.walk.number, 1)
        // ⌘' while the list is open: the highlight follows the walk.
        s.walk.step(forward: true)
        s.window.settle()
        s.press(.down, reaching: shapes.link)
    },
    test("a click on a row goes to its stop and the list stays; a click on a head folds it") {
        let s = try BandScene()
        s.openList()
        // Each line is a borderless button in the table (a click is its press): top to bottom, the root's head, A, B, the link
        // and Texas's head.
        let table = try require(s.table)
        @MainActor func buttons() -> [NSButton] {
            table.descendants(NSButton.self).sorted { $0.convert($0.bounds, to: s.hosting).minY < $1.convert($1.bounds, to: s.hosting).minY }
        }
        expectEqual(buttons().count, 5, "a button a line")
        buttons()[2].performClick(nil)
        s.window.spin { s.walk.currentRow?.shape == shapes.b }
        expectEqual(s.walk.currentRow?.shape, shapes.b, "a click on the row moves the walk")
        expect(s.walk.isListOpen, "and the list stays open")
        buttons()[4].performClick(nil)
        s.waitForLines(8)
        expectEqual(s.lines, 8, "a click on Texas's head unfolds it")
        expectEqual(s.walk.currentRow?.shape, shapes.b, "and moves nothing")
    },
    test("Page Up and Page Down go to the first stop of the previous and next board, wrapping") {
        let s = try BandScene()
        s.openList()
        s.press(.pageDown, reaching: shapes.c)
        expectEqual(s.editor.board, texas, "the pocket board's first stop")
        s.waitForLines(5)
        s.press(.pageDown, reaching: shapes.a)
        expectEqual(s.editor.board, .root, "wrapping to the root's first")
        s.press(.pageUp, reaching: shapes.c)
        s.press(.pageUp, reaching: shapes.a)
        // From a head the page goes by that head's board.
        s.walk.step(forward: true)
        s.window.settle()
        s.press(.down, reaching: shapes.link)
        s.press(.down)
        s.press(.pageUp, reaching: shapes.a)
    },
    test("Page Down from a head goes by the head's board, not the current stop's") {
        let s = try BandScene()
        s.openList()
        s.press(.down, reaching: shapes.b)
        s.press(.down, reaching: shapes.link)
        s.press(.down)
        expectEqual(s.walk.currentRow?.shape, shapes.link, "on Texas's head, the walk at the link (on the root)")
        s.press(.pageDown, reaching: shapes.a)
        expectEqual(s.editor.board, .root, "the board after Texas's, wrapping to the root's first: the current stop's board would have gone to Texas")
        expectEqual(s.walk.currentRow?.shape, shapes.a)
    },
    test("Page Up and Page Down pass a board with no stop left") {
        let s = try BandScene()
        s.begin()
        // A fix on the pocket's board: C and D no longer have issues, so Texas keeps its rows with no stop.
        s.editor.transact(on: texas, "Fix") { t in
            t.update(shapes.c, as: Card.self) { $0.props.text = "fine" }
            t.update(shapes.d, as: Card.self) { $0.props.text = "fine" }
        }
        s.window.spin { s.walk.boards.map(\.open) == [3, 0] }
        expectEqual(s.walk.boards.map(\.open), [3, 0], "Texas has no open stop")
        s.walk.toggleList()
        s.window.spin { s.lines > 0 && s.listHasKeyboard }
        s.press(.down, reaching: shapes.b)
        s.press(.pageDown, reaching: shapes.a)
        expectEqual(s.editor.board, .root, "Page Down skips the board with no stop: the root's own first stop")
        s.press(.down, reaching: shapes.b)
        s.press(.pageUp, reaching: shapes.a)
        expectEqual(s.editor.board, .root, "and Page Up")
    },
    test("Page Up and Page Down stay on the first stop of a walk's only board, and make no Back step") {
        let s = try BandScene()
        s.walk.begin(walkScope("meh", candidates: [shapes.b]), at: .first)
        s.window.spin { !s.walk.isGathering && s.walk.rows.count == 1 }
        s.walk.toggleList()
        s.window.spin { s.lines == 2 && s.listHasKeyboard }
        expectEqual(s.walk.currentRow?.shape, shapes.b)
        let selected = s.editor.selectedShapeIDs
        for page in [Chord.pageDown, Chord.pageUp] {
            s.press(page)
            expectEqual(s.walk.currentRow?.shape, shapes.b, "the only board's first stop: the walk stays")
            expectEqual(s.editor.selectedShapeIDs, selected)
        }
        // The walk is one Back step (landing on its first stop), and the pages made none: one Back leaves nothing to go back to.
        expect(s.editor.canGoBack)
        s.editor.goBack()
        expect(!s.editor.canGoBack, "no step of the pages' own")
    },
    test("a step takes the highlight back from a row that is no stop, even to the stop the walk is at") {
        let s = try BandScene()
        s.walk.begin(walkScope("meh", candidates: [shapes.b, shapes.d]), at: .first)
        s.window.spin { !s.walk.isGathering && s.walk.rows.count == 2 }
        s.walk.toggleList()
        s.window.spin { s.lines > 0 && s.listHasKeyboard }
        expectEqual(s.walk.currentRow?.shape, shapes.b)
        s.walk.step(forward: true)
        expectEqual(s.walk.currentRow?.shape, shapes.d)
        expect(s.walk.ignoreCurrent())
        s.window.spin { s.walk.currentRow?.state == .ignored }
        s.walk.step(forward: true)
        expectEqual(s.walk.currentRow?.shape, shapes.b, "the only stop left")
        s.waitForLines(3)
        // The root's head, B, Texas's head: the person unfolds Texas, whose rows the walk folded as it left it.
        s.window.settle()
        s.press(.down)
        s.press(.right)
        s.waitForLines(4)
        // The root's head, B, Texas's head, D's row (ignored): ↓ to the ignored row takes the highlight and the walk stays.
        s.press(.down)
        expectEqual(s.table?.selectedRow, 3, "the highlight is on the ignored row")
        expectEqual(s.walk.currentRow?.shape, shapes.b)
        // Next Issue goes to the same and only stop: the highlight comes back to it.
        s.editor.perform(.nextIssue)
        s.window.settle()
        s.window.spin { s.table?.selectedRow == 1 }
        expectEqual(s.table?.selectedRow, 1, "the highlight is on the walk's stop again")
    },
    test("a row's value is the first contribution that answers, in plugin order: nil and empty give way to the next") {
        for first in [nil, "", "  \n "] as [String?] {
            let s = try BandScene(more: [answering("first-value", first), answering("second-value", "v")])
            let record = try require(s.editor.shape(inFile: shapes.a), "a card")
            expectEqual(s.editor.registry.issueRowValue(of: record, in: s.editor), "v", "after \(String(describing: first))")
        }
        let s = try BandScene(more: [answering("second-value", "v"), answering("first-value", "w")])
        let record = try require(s.editor.shape(inFile: shapes.a), "a card")
        expectEqual(s.editor.registry.issueRowValue(of: record, in: s.editor), "v", "the first in plugin order that answers")
    },
    test("a row's value is one line, cut with an ellipsis: lines and runs of whitespace fold to a space, a long text is capped") {
        let s = try BandScene(more: [answering("tall-value", "a\nb\n\n  c")])
        let record = try require(s.editor.shape(inFile: shapes.a), "a card")
        expectEqual(s.editor.registry.issueRowValue(of: record, in: s.editor), "a b c")
        let long = String(repeating: "word ", count: 40)
        let cut = try require(IssueRowValues.line(long), "a value")
        expectEqual(cut.count, IssueRowValues.maxLength)
        expect(cut.hasSuffix("…") && cut.hasPrefix("word word"), cut)
        let exact = String(repeating: "x", count: IssueRowValues.maxLength)
        expectEqual(IssueRowValues.line(exact), exact, "a value that fits is whole")
    },
    test("a row ending in a value is drawn again when the value changes with no row changing") {
        let s = try BandScene(more: [rowValues()])
        s.openList()
        let revision = s.walk.textRevision
        s.editor.transact("Edit") { $0.update(shapes.a, as: Card.self) { $0.props.text = "bad again" } }
        s.window.settle()
        expect(s.walk.textRevision != revision, "a commit that wrote a shape draws the rows again")
        let before = s.walk.textRevision
        s.editor.transact("Move") { $0.translate([shapes.b], by: CGPoint(x: 5, y: 0)) }
        s.window.settle()
        expectEqual(s.walk.textRevision, before, "a move writes no words")
        expectEqual(s.walk.line(of: try require(s.walk.rows.first { $0.shape == shapes.a })).detail, "v:bad again")
    },
    test("a row is drawn again when its value changes, and when its shape's tint does: the table shows it, not only the model") {
        CardTint.color = nil
        let s = try BandScene(more: [rowValues(), cardTints()])
        s.openList()
        s.window.settle()
        // Line 1 is A's row, after the root's head.
        let first = try picture(ofLine: 1, in: s)
        let other = try picture(ofLine: 2, in: s)
        expect(first != other, "the pictures tell the rows apart (A's value is not B's)")
        s.editor.transact("Edit") { $0.update(shapes.a, as: Card.self) { $0.props.text = "bad, and worse" } }
        s.window.settle()
        s.window.spin { (try? picture(ofLine: 1, in: s)) != first }
        let edited = try picture(ofLine: 1, in: s)
        expect(edited != first, "the row shows the new value")
        expectEqual(try picture(ofLine: 2, in: s), other, "and B's row is as it was")
        // A color for the shape: the walk hears the tints changed and the rows are drawn with it.
        let tints = s.walk.tintRevision
        CardTint.color = .systemRed
        s.editor.shapeTintsDidChange()
        s.window.settle()
        expect(s.walk.tintRevision != tints, "the walk heard the tints change")
        s.window.spin { (try? picture(ofLine: 1, in: s)) != edited }
        expect(try picture(ofLine: 1, in: s) != edited, "the row's symbol is drawn in the new tint")
        CardTint.color = nil
    },
    test("a commit that only moves a shape draws no row again, and one that writes words draws them") {
        RowDraws.count = 0
        let s = try BandScene(more: [countedRowValues()])
        s.openList()
        s.window.settle()
        let drawn = RowDraws.count
        expect(drawn > 0, "the root's three rows were drawn")
        // A drag of B: every event is a commit, and none of them changes a word, a tint or a place.
        for n in 1...3 { s.editor.transact("Move") { $0.translate([shapes.b], by: CGPoint(x: Double(5 * n), y: 0)) } }
        s.window.settle()
        s.window.settle()
        expectEqual(RowDraws.count, drawn, "no row is asked for its value again by a commit that writes none")
        // Words written: the rows are drawn again, as the stamp says.
        s.editor.transact("Edit") { $0.update(shapes.a, as: Card.self) { $0.props.text = "bad again" } }
        s.window.settle()
        s.window.settle()
        expect(RowDraws.count > drawn, "a commit that writes words draws the rows again")
    },
    test("a list opened on a stop deep in a long board scrolls to the stop's row") {
        let s = try BandScene()
        let added = addCards(40, to: s.editor)
        s.begin(.all, at: .shape(added[34]))
        expectEqual(s.walk.currentRow?.shape, added[34])
        s.walk.toggleList()
        s.window.spin { s.lines == 2 + 43 && s.listHasKeyboard }
        // The root's head, then its rows: A, B, the link and the cards.
        let table = try require(s.table)
        let line = 1 + 3 + 34
        s.window.spin { table.visibleRect.contains(table.rect(ofRow: line)) }
        s.window.spin { table.visibleRect.contains(table.rect(ofRow: line)) }
        expect(table.visibleRect.contains(table.rect(ofRow: line)), "the row is inside what the table shows: \(table.visibleRect) of \(table.rect(ofRow: line))")
        expect(!table.visibleRect.intersects(table.rect(ofRow: 1)), "and the list is not at its top")
        // Closed and opened again on another stop, the same.
        s.walk.toggleList()
        s.window.spin { s.table == nil }
        s.walk.step(forward: false)
        s.walk.step(forward: false)
        s.walk.toggleList()
        s.window.spin { s.lines == 2 + 43 && s.listHasKeyboard }
        let again = try require(s.table)
        let current = 1 + 3 + 32
        s.window.spin { again.visibleRect.contains(again.rect(ofRow: current)) }
        expect(again.visibleRect.contains(again.rect(ofRow: current)), "opened again, on the stop it is at now")
    },
    test("a list scrolled under the band with the keyboard in it: ‹ and › dim as a gesture turns their commands off, the keyboard being the table's, not theirs") {
        let s = try BandScene()
        let added = addCards(40, to: s.editor)
        s.begin(.all, at: .shape(added[34]))
        s.walk.toggleList()
        s.window.spin { s.lines == 2 + 43 && s.listHasKeyboard }
        let table = try require(s.table)
        let line = 1 + 3 + 34
        s.window.spin { table.visibleRect.contains(table.rect(ofRow: line)) }
        let previous = try require(s.previous), next = try require(s.next)
        // Scrolled, the table runs up under the band: a control that covers ‹, though the keyboard is on a row.
        let middle = previous.convert(CGPoint(x: previous.bounds.midX, y: previous.bounds.midY), to: nil)
        expect(table.convert(table.bounds, to: nil).contains(middle), "the scrolled table covers ‹")
        s.editor.session = IdleGesture()
        s.window.settle()
        s.window.settle()
        expect(s.listHasKeyboard, "the list keeps the keyboard")
        expect(!previous.isEnabled && !next.isEnabled, "‹ and › are dimmed: the keyboard is not on them")
        s.editor.session = nil
        s.window.settle()
        expect(previous.isEnabled && next.isEnabled, "and enabled again with their commands")
    },
    test("each stop's evidence begins at its top: the scroll of the last does not carry over") {
        let tall = Contributor(id: "tall") { r in
            r.detailsForEveryBox { DetailSection("Tall", in: IssuesTab.self) { _ in Color.clear.frame(height: 900) } }
        }
        let s = try BandScene(more: [tall])
        s.openList()
        s.window.spin { s.evidenceScroll != nil }
        let scroll = try require(s.evidenceScroll)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 300))
        scroll.reflectScrolledClipView(scroll.contentView)
        expect(s.evidenceScroll?.contentView.bounds.origin.y ?? 0 > 100, "the evidence is scrolled down")
        s.walk.step(forward: true)
        s.window.settle()
        s.window.spin { (s.evidenceScroll?.contentView.bounds.origin.y ?? 0) == 0 }
        expectEqual(s.evidenceScroll?.contentView.bounds.origin.y ?? -1, 0, "the next stop's evidence is at its top")
    },
    test("a board has one head whatever was shifted before its stops: a delete, a restack of a subboard's owner and a later edit, and Page Down goes through every board") {
        let s = try BandScene(file: ThreeBoards.file)
        s.begin()
        expectEqual(s.walk.boards.map(\.board), [BoardID(owner: ThreeBoards.one), BoardID(owner: ThreeBoards.two), BoardID(owner: ThreeBoards.three)])
        // The root's card goes: every owner's place in the stack moves, and no row was read again.
        s.editor.transact(on: .root, "Delete") { $0.delete([ThreeBoards.card]) }
        // The first subboard's owner goes to the front; then a card on the last board is edited, and read again at its fresh key.
        s.editor.transact(on: .root, "Front") { $0.bringToFront(ThreeBoards.one) }
        s.editor.transact(on: BoardID(owner: ThreeBoards.three), "Edit") { $0.update(walkID(332), as: Card.self) { $0.props.text = "bad again" } }
        let boards = s.walk.boards.map(\.board)
        expectEqual(boards, [ThreeBoards.two, ThreeBoards.three, ThreeBoards.one].map { BoardID(owner: $0) }, "one run a board, in the owners' stack order")
        expectEqual(Set(boards).count, boards.count, "no board twice")
        s.walk.toggleList()
        s.window.spin { s.lines > 0 && s.listHasKeyboard }
        // Page Down visits each board once and comes round.
        let start = try require(s.walk.boards.firstIndex { $0.board == s.walk.currentRow?.board })
        var visited: [BoardID] = []
        for _ in boards {
            let at = try require(s.walk.boards.firstIndex { $0.board == s.walk.currentRow?.board })
            let next = s.walk.boards[(at + 1) % boards.count]
            let first = try require(next.firstOpen.map { s.walk.rows[$0].shape })
            s.press(.pageDown, reaching: first)
            visited.append(s.editor.board)
        }
        expectEqual(visited, (1...boards.count).map { boards[(start + $0) % boards.count] }, "Page Down goes through every board and comes round")
    },
    test("a head the highlight was left on whose board has no rows left is dropped: Page Down goes by the board of the walk's stop") {
        let s = try BandScene(file: ThreeBoards.file)
        let two = BoardID(owner: ThreeBoards.two)
        s.openList()
        s.waitForLines(5)
        // S1's head, its two rows, S2's head: ↓ twice moves the walk to the second row and then onto S2's head.
        s.press(.down, reaching: walkID(312))
        s.press(.down)
        expectEqual(s.table?.selectedRow, 3, "the highlight is on S2's head")
        // S2's cards go, and its head with them.
        s.editor.transact(on: two, "Delete") { $0.delete([walkID(321), walkID(322)]) }
        s.window.spin { s.walk.boards.count == 2 && s.table?.selectedRow == 2 }
        expectEqual(s.walk.boards.map(\.board), [BoardID(owner: ThreeBoards.one), BoardID(owner: ThreeBoards.three)])
        expectEqual(s.table?.selectedRow, 2, "the highlight is back on the walk's stop")
        // The next board is S3, not the first board with a stop.
        s.press(.pageDown, reaching: walkID(331))
        expectEqual(s.editor.board, BoardID(owner: ThreeBoards.three))
    },
    test("a row that is no stop reads ignored or holds, and takes the highlight without moving the walk") {
        let s = try BandScene()
        s.openList(at: .shape(shapes.b))
        let b = try require(s.walk.currentRow)
        expectEqual(s.walk.line(of: b).detail, nil, "an open stop with no contributor of a value has none")
        expect(!s.walk.line(of: b).isDimmed, "an open stop is drawn as any row")
        expect(s.walk.ignoreCurrent())
        s.window.spin { s.walk.currentRow?.state == .ignored }
        let ignored = try require(s.walk.currentRow)
        expectEqual(s.walk.line(of: ignored).detail, "ignored")
        expect(s.walk.line(of: ignored).isDimmed, "an ignored row is dimmed")
        expectEqual(s.walk.line(of: ignored).spoken, "Root, ignored")
        expect(s.listHasKeyboard)
        // ↓ to the link, ↑ onto B's row, which is no stop: the highlight is on it and the walk stays at the link.
        s.press(.down, reaching: shapes.link)
        s.press(.up)
        expectEqual(s.walk.currentRow?.shape, shapes.link, "a row that is no stop moves nothing")
        expectEqual(s.editor.selectedShapeIDs, [shapes.link])
        // A fix: A's error goes, its row holds.
        s.editor.transact("Fix") { $0.update(shapes.a, as: Card.self) { $0.props.text = "fine" } }
        s.window.spin { s.walk.rows.contains { $0.state == .holds } }
        let held = try require(s.walk.rows.first { $0.state == .holds })
        expectEqual(s.walk.line(of: held).detail, "holds")
        expect(s.walk.line(of: held).isDimmed, "and so is one that holds")
        expect(s.walk.rows.filter(\.isOpen).allSatisfy { !s.walk.line(of: $0).isDimmed }, "the open stops are not")
        expectEqual(s.walk.line(of: held).spoken, "Root, holds")
        expectEqual(s.walk.boards.map(\.open), [1, 3], "the heads count the stops that are left: the link, then C and D twice")
    },
    test("a row ends in its first value from the plugins that give one, none without them") {
        let plain = try BandScene()
        plain.begin()
        expectEqual(plain.walk.rows.map { plain.walk.line(of: $0).detail }, [nil, nil, nil, nil, nil, nil], "no contributor, no value")
        let s = try BandScene(more: [rowValues()])
        s.begin()
        expectEqual(s.walk.rows.map { s.walk.line(of: $0).detail }, ["v:bad", "v:meh", nil, "v:bad", "v:bad meh", "v:bad meh"],
                    "the card's words; the link is not a card")
        let b = try require(s.walk.rows.first { $0.shape == shapes.b })
        expectEqual(s.editor.registry.issueRowValue(of: try require(s.editor.shape(inFile: b.shape)), in: s.editor), "v:meh")
        s.walk.toggleList()
        s.window.spin { s.lines > 0 }
        expectEqual(s.lines, 5)
    },
    test("the highlight follows ⌘' while the list is open, the list stays open and the keyboard stays in it") {
        let s = try BandScene()
        s.openList()
        s.editor.perform(.nextIssue)
        expectEqual(s.walk.currentRow?.shape, shapes.b)
        s.editor.perform(.nextIssue)
        s.editor.perform(.nextIssue)
        expectEqual(s.walk.currentRow?.shape, shapes.c)
        s.waitForLines(5)
        expect(s.walk.isListOpen)
        s.editor.perform(.previousIssue)
        expectEqual(s.walk.currentRow?.shape, shapes.link)
        s.window.settle()
        // The next ↓ goes on from the walk's place, which the highlight is: Texas's head is next (folded, the walk left it), and
        // unfolded, C.
        s.press(.down)
        s.press(.right)
        s.waitForLines(8)
        s.press(.down, reaching: shapes.c)
    },
    test("Return closes the list on the current stop with the keyboard in the shape's panel, the band staying") {
        let s = try BandScene()
        s.openList()
        s.press(.down, reaching: shapes.b)
        s.keys.press(.return)
        s.window.spin { !s.walk.isListOpen }
        expect(!s.walk.isListOpen, "Return closes the list: \(s.keys.traceText)")
        s.window.spin { s.editor.detailPanel?.keyboardPlace == .content }
        expect(s.walk.isRunning && s.hasBand, "the walk goes on, the band stays")
        expectEqual(s.walk.currentRow?.shape, shapes.b, "on the current stop")
        expect(s.editor.detailPanel?.keyboardPlace == .content && !s.canvasHasKeyboard, "the stop's panel has a control, so the keyboard is in it: \(s.keys.traceText)")
        s.window.spin { s.table == nil }
        expect(s.table == nil, "the list is gone")
    },
    test("Return on a head folds or unfolds it and closes nothing") {
        let s = try BandScene()
        s.openList()
        s.press(.down, reaching: shapes.b)
        s.press(.down, reaching: shapes.link)
        s.press(.down)
        expectEqual(s.walk.currentRow?.shape, shapes.link, "on Texas's head, the walk at the link")
        s.press(.return)
        s.waitForLines(8)
        expectEqual(s.lines, 8, "Return unfolds Texas")
        expect(s.walk.isListOpen)
        s.press(.return)
        s.waitForLines(5)
        expectEqual(s.lines, 5, "and folds it again")
        expect(s.walk.isListOpen)
    },
    test("Escape closes the list and the band has the keyboard (or the canvas, with Keyboard navigation off); then the canvas; ⌘. ends the walk") {
        let s = try BandScene()
        s.openList()
        s.keys.press(.escape)
        s.window.spin { !s.walk.isListOpen }
        expect(!s.walk.isListOpen, "Escape closes the list: \(s.keys.traceText)")
        expect(s.walk.isRunning && s.hasBand, "the walk goes on")
        if s.keys.keyboardNavigation {
            s.window.spin { s.editor.detailPanel?.keyboardPlace == .band }
            expect(s.editor.detailPanel?.keyboardPlace == .band, "the band has the keyboard: \(s.keys.traceText)")
            s.keys.press(.escape)
            s.window.spin { s.canvasHasKeyboard }
            expect(s.canvasHasKeyboard, "and Escape from the band the canvas: \(s.keys.traceText)")
        } else {
            s.window.spin { s.canvasHasKeyboard }
            expect(s.canvasHasKeyboard, "no control of the band takes the keys: the canvas has them: \(s.keys.traceText)")
        }
        expect(s.walk.isRunning, "the walk goes on")
        s.openList()
        s.keys.press(.commandPeriod)
        s.window.spin { !s.walk.isRunning }
        expect(!s.walk.isRunning, "⌘. in the list ends the walk: \(s.keys.traceText)")
        expect(!s.walk.isListOpen)
        expect(s.canvasHasKeyboard, "and the canvas has the keyboard")
    },
    test("Issue List toggles the list of the walk running, and with none begins All Issues from the selection with the list open") {
        let s = try BandScene()
        expect(s.editor.canPerform(.issueList), "it runs with no walk")
        expect(!s.walk.isRunning)
        s.editor.selection = shapes.b
        expect(s.editor.perform(.issueList))
        expect(s.walk.isRunning && s.walk.isListOpen, "a walk begun with the list open")
        s.window.spin { !s.walk.isGathering && s.lines > 0 }
        expectEqual(s.walk.scope?.id, "all")
        expectEqual(s.walk.currentRow?.shape, shapes.link, "from the first stop after the selection")
        expect(s.editor.perform(.issueList))
        expect(!s.walk.isListOpen && s.walk.isRunning, "closes the list, the walk goes on")
        expect(s.editor.perform(.issueList))
        expect(s.walk.isListOpen, "and opens it again")
        s.window.spin { s.lines > 0 }
        // The band's count is the same toggle.
        s.walk.end()
        s.window.spin { !s.hasBand }
        s.begin()
        s.click(s.count)
        expect(s.walk.isListOpen)
        s.window.spin { s.lines > 0 }
        s.click(s.count)
        expect(!s.walk.isListOpen)
        // The key itself, with the canvas holding the keyboard.
        s.window.makeFirstResponder(s.canvas)
        s.pressItem(ctrlCommandQuote)
        expect(s.walk.isListOpen, "⌃⌘' opens the list")
        s.window.spin { s.listHasKeyboard }
        expect(s.listHasKeyboard)
        s.pressItem(ctrlCommandQuote)
        expect(!s.walk.isListOpen, "and closes it with the keyboard in the list")
        s.window.spin { s.canvasHasKeyboard }
        expect(s.canvasHasKeyboard, "the keyboard back on the canvas")
    },
    test("Issue List begun on the canvas with no walk gives the keyboard back to the canvas when it is pressed again") {
        let s = try BandScene()
        s.window.makeFirstResponder(s.canvas)
        expect(s.canvasHasKeyboard)
        expect(!s.walk.isRunning && !s.hasBand, "no walk, no band to tell the window")
        s.pressItem(ctrlCommandQuote)
        expect(s.walk.isRunning && s.walk.isListOpen, "begun with the list open")
        s.window.spin { s.listHasKeyboard }
        expect(s.listHasKeyboard)
        s.pressItem(ctrlCommandQuote)
        expect(!s.walk.isListOpen && s.walk.isRunning)
        s.window.spin { s.canvasHasKeyboard }
        expect(s.canvasHasKeyboard, "the canvas has the keyboard it had: \(s.keys.traceText)")
    },
    test("a selection that leaves the current stop closes the list, the band stays, and ⌘' comes back to the walk") {
        let s = try BandScene()
        s.openList()
        expect(s.walk.isListOpen)
        // What Show Rule does: another shape is selected from a button under the list.
        s.editor.selectedShapeIDs = [shapes.q]
        s.window.spin { !s.walk.isListOpen }
        expect(!s.walk.isListOpen, "the list gives way to the panel of what is selected")
        expect(s.walk.isRunning && s.hasBand, "the band stays")
        expectEqual(s.editor.selectedShapeIDs, [shapes.q])
        s.editor.perform(.nextIssue)
        expectEqual(s.walk.currentRow?.shape, shapes.b, "the walk goes on from where it was")
        expect(!s.walk.isListOpen)
        // Stepping with the list open does not close it.
        expect(s.editor.perform(.issueList))
        expect(s.walk.isListOpen)
        s.editor.perform(.nextIssue)
        s.window.settle()
        expect(s.walk.isListOpen, "a step selects the stop's own shape")
    },
    test("Issue List does not run while a gesture is under way, and the command is the panel plugin's") {
        let h = try walkTestHarness()
        let walk = try require(h.editor.issueWalk)
        expect(!h.editor.canPerform(.issueList), "a list without the panel has no Issue List")
        h.press(at: CGPoint(x: 50, y: 30))
        walk.toggleList()
        expect(!walk.isRunning && !walk.isListOpen, "a press is under way: nothing begins")
        let s = try BandScene()
        let line = s.editor.registry.report.split(separator: "\n").first { $0.hasPrefix("issue-walk-panel") }
        expect(line?.contains("command issueList after previousIssue in IssuesSection") == true, "\(line ?? "no line")")
        expect(line?.contains("detail takeover") == true, "\(line ?? "no line")")
    },
    test("the keyboard goes back where it was: the canvas, a band control, and the band when the shape's panel field is gone") {
        let s = try BandScene()
        s.begin()
        // The canvas.
        s.window.makeFirstResponder(s.canvas)
        s.walk.toggleList()
        s.window.spin { s.listHasKeyboard }
        expect(s.listHasKeyboard, "opening puts the keyboard in the list")
        s.walk.toggleList()
        s.window.spin { s.canvasHasKeyboard }
        expect(s.canvasHasKeyboard, "closing gives it back to the canvas")
        // A control of the band.
        expect(s.focus(s.next), "the keyboard on ›")
        s.walk.toggleList()
        s.window.spin { s.listHasKeyboard }
        expect(s.listHasKeyboard)
        s.walk.toggleList()
        s.window.settle()
        expect(s.window.firstResponder === s.next, "closing gives it back to ›, exactly")
        // The panel's field, which the list replaces: the band.
        s.window.spin { s.notes != nil }
        s.window.focus(try require(s.notes))
        expect(s.editor.detailPanel?.keyboardPlace == .content)
        s.walk.toggleList()
        s.window.spin { s.listHasKeyboard }
        expect(s.listHasKeyboard)
        s.walk.toggleList()
        s.window.settle()
        if s.keys.keyboardNavigation {
            s.window.spin { s.editor.detailPanel?.keyboardPlace == .band }
            expect(s.editor.detailPanel?.keyboardPlace == .band, "its field is gone, so the band has it")
        } else {
            s.window.spin { s.editor.detailPanel?.keyboardPlace != nil || s.canvasHasKeyboard }
            expect(s.editor.detailPanel?.keyboardPlace != nil || s.canvasHasKeyboard, "never lost")
        }
    },
    test("opening the list ends the edit under way") {
        let s = try BandScene()
        s.begin(.all, at: .shape(shapes.a))
        s.editor.selection = shapes.a
        expect(s.editor.beginEditing(shapes.a))
        expectEqual(s.editor.editingShapeID, shapes.a)
        s.walk.toggleList()
        expectEqual(s.editor.editingShapeID, nil, "editing ended first")
        expect(s.walk.isListOpen)
    },
    test("opening the list writes a number being typed in the stop's panel, in one undo step") {
        let width = Contributor(id: "width") { r in
            r.detailsForEveryBox {
                DetailSection("Width", in: IssuesTab.self) { $frame in
                    DetailFields { DetailNumberField("Width", value: $frame.size.width, unit: "pt", in: 1...100_000) }
                }
            }
        }
        let s = try BandScene(more: [width])
        s.begin(.all, at: .shape(shapes.a))
        s.window.spin { s.hosting.descendants(NSTextField.self).contains { $0.isEditable && $0.stringValue.hasSuffix("pt") } }
        let field = try require(s.hosting.descendants(NSTextField.self).first { $0.isEditable && $0.stringValue.hasSuffix("pt") })
        let before = try require(s.editor.document[shapes.a]?.box?.width)
        s.window.focus(field)
        s.window.type("300")
        expectEqual(s.editor.document[shapes.a]?.box?.width, before, "a draft: nothing is written yet")
        s.walk.toggleList()
        expectEqual(s.editor.document[shapes.a]?.box?.width, 300, "opening the list wrote what was typed")
        s.window.spin { s.table != nil }
        s.editor.undo()
        expectEqual(s.editor.document[shapes.a]?.box?.width, before, "one undo step takes it back")
    },
    test("under the list is the current stop's Issues tab, following each step: its warning line's buttons, then another stop's") {
        let s = try BandScene()
        s.openList(at: .shape(shapes.b))
        s.window.spin { !s.evidenceButtons.isEmpty }
        let buttons = s.evidenceButtons
        expect(!buttons.isEmpty, "B's warning line has its Ignore under the list")
        s.walk.step(forward: true)
        s.walk.step(forward: true)
        expectEqual(s.walk.currentRow?.shape, shapes.c)
        s.window.spin { s.evidenceButtons.isEmpty }
        expect(s.evidenceButtons.isEmpty, "C's error line has none: the evidence followed the step")
        s.walk.step(forward: false)
        s.walk.step(forward: false)
        s.window.spin { !s.evidenceButtons.isEmpty }
        expect(!s.evidenceButtons.isEmpty, "and B's are back")
        // The Ignore under the list is the walk's Ignore: B reads ignored.
        let ignore = try require(s.evidenceButtons.first)
        ignore.performClick(nil)
        s.window.settle()
        s.window.spin { s.walk.currentRow?.state == .ignored }
        expectEqual(s.walk.currentRow?.state, .ignored)
        expect(s.walk.isListOpen, "the list stays")
        s.editor.undo()
        s.window.spin { s.walk.currentRow?.state == .open }
        expectEqual(s.walk.currentRow?.state, .open, "⌘Z brings the stop back")
    },
    test("the list is at most half the panel: a tall list leaves room for the evidence") {
        let s = try BandScene()
        // Forty cards after the fixture's on the root: its rows are far taller than half the panel.
        _ = addCards(40, to: s.editor)
        s.begin(.all, at: .shape(shapes.b))
        s.walk.toggleList()
        s.window.spin { s.lines == 2 + 43 && s.listHasKeyboard }
        let table = try require(s.table)
        let scroll = try require(table.enclosingScrollView)
        let frame = scroll.convert(scroll.bounds, to: s.hosting)
        expect(table.bounds.height > s.hosting.bounds.height, "the rows are taller than the panel: \(table.bounds.height)")
        let room = s.hosting.bounds.height
        expect(abs(frame.height - room * IssueWalkStyle.listShare) <= 1, "the list is \(frame.height) of \(room)")
        s.window.spin { !s.evidenceButtons.isEmpty }
        let button = try require(s.evidenceButtons.first)
        let place = button.convert(button.bounds, to: s.hosting)
        expect(place.minY >= frame.maxY - 1 && place.maxY <= s.hosting.bounds.maxY, "the evidence's button stays in view under the list: \(place) under \(frame)")
    },
    test("the walk's light shows with the keyboard in the list and goes with it") {
        let s = try BandScene()
        let apart: [(ShapeID, CGRect)] = [(shapes.a, CGRect(x: 40, y: 40, width: 100, height: 60)), (shapes.b, CGRect(x: 240, y: 40, width: 100, height: 60))]
        s.editor.transact("Apart") { t in for (id, frame) in apart { t.update(id, as: Card.self) { $0.props.frame = frame } } }
        s.openList()
        s.window.spin { s.editor.issueLights?.isLit == true }
        expect(s.editor.issueLights?.isLit == true, "the list has the keyboard: the other stops are lit")
        expectEqual(s.editor.outlines.tinted.first?.shapes, [shapes.b, shapes.link])
        s.keys.press(.escape)
        s.window.spin { s.editor.issueLights?.isLit == false }
        if s.keys.keyboardNavigation {
            // The keyboard went to the band: lit still.
            s.window.spin { s.editor.detailPanel?.keyboardPlace == .band }
            expect(s.editor.issueLights?.isLit == true, "the band has the keyboard: lit")
            s.window.makeFirstResponder(s.canvas)
        }
        s.window.spin { s.editor.issueLights?.isLit == false }
        expect(s.editor.issueLights?.isLit == false, "the keyboard on the canvas: none")
        s.walk.toggleList()
        s.window.spin { s.listHasKeyboard && s.editor.issueLights?.isLit == true }
        expect(s.editor.issueLights?.isLit == true)
        s.window.makeFirstResponder(s.canvas)
        s.window.spin { s.editor.issueLights?.isLit == false }
        expect(s.editor.issueLights?.isLit == false, "the keyboard out of the list: none, the list still open")
    },
    test("VoiceOver: the list is named Issue List, a row says its name, its board and its place, and a head its title, count and fold") {
        let s = try BandScene()
        s.openList()
        expectEqual(try require(s.table).accessibilityLabel(), "Issue List")
        let rows = s.walk.rows.map { s.walk.line(of: $0) }
        expectEqual(rows.map(\.spoken), ["Root, 1 of 6", "Root, 2 of 6", "Root, 3 of 6", "Texas, 4 of 6", "Texas, 5 of 6", "Texas, 6 of 6"])
        expect(rows[2].name.contains("→"), "an arrow is named by its ends: \(rows[2].name)")
        expectEqual(DetailGroupHeader.spoken(count: 3, isCollapsed: true), "3, collapsed")
        expectEqual(s.editor.boardHeading(of: texas).title, "Texas", "a head: Texas, 3, collapsed")
    },
    test("the band, the list and what is under it are walked by Tab round the panel in reading order, each stop shown (P7) and named (P9), the exact way back at every stop") {
        let s = try BandScene()
        s.openList(at: .shape(shapes.b))
        s.window.spin { !s.evidenceButtons.isEmpty && s.notes != nil }
        expect(s.listHasKeyboard)
        // The evidence's buttons are standard controls, as the band's: out of the ring with Keyboard navigation off, and then
        // listed as skipped. The ring begins at the band, then the list, the evidence's buttons and the stop's Notes field.
        let evidence = s.evidenceButtons.sorted { $0.convert($0.bounds, to: s.hosting).minX < $1.convert($1.bounds, to: s.hosting).minX }
            .map { "window/\($0.title)" }
        let band = ["window/Previous Issue", "window/1 of 6", "window/Next Issue", "window/Done"]
        s.keys.standardControls.formUnion(band + evidence)
        let order = band + ["window/Issue List"] + evidence + ["window/Notes"]
        let cycle = s.keys.expectCycle(inOrder: order, wraps: .closed)
        expect(cycle.stops.map(\.id).contains("window/Issue List") && cycle.stops.map(\.id).contains("window/Notes"), "the list and Notes are stops: \(cycle.stops.map(\.id))")
        if !s.keys.keyboardNavigation {
            expectEqual(Set(s.keys.skipped), Set(order).intersection(s.keys.standardControls), "the standard controls are left out of the ring, not failed")
        }
        s.keys.expectShows(Array(cycle.stops))
    },
    test("the list is a stop of Tab that Tab leaves and ⇧Tab comes back to, and ↓ then ↑ lands on the same stop, with Keyboard navigation on or off") {
        let s = try BandScene()
        s.openList()
        expect(s.listHasKeyboard)
        let start = s.walk.currentRow?.key
        s.press(.down, reaching: shapes.b)
        s.press(.down, reaching: shapes.link)
        s.press(.up, reaching: shapes.b)
        s.press(.up, reaching: shapes.a)
        expectEqual(s.walk.currentRow?.key, start, "↑ undoes ↓")
        s.keys.press(.tab)
        expect(!s.listHasKeyboard, "Tab leaves the list: \(s.keys.traceText)")
        s.keys.press(.backTab)
        expect(s.listHasKeyboard, "and ⇧Tab is the exact way back: \(s.keys.traceText)")
        expect(s.walk.isListOpen, "the list stays open")
        if !s.keys.keyboardNavigation {
            // Nothing a click does is lost: the band's count, Done and the menus hold the buttons' work (checked by the band's tests).
            expect(s.editor.canPerform(.issueList) && s.editor.canPerform(.endIssueWalk))
        }
    },
    test("the list's row value is a report line of the point, and a contribution for no scope is refused") {
        let s = try BandScene(more: [rowValues()])
        let line = s.editor.registry.report.split(separator: "\n").first { $0.hasPrefix("row-values") }
        expect(line?.contains("IssueRowValues → every shape") == true, "\(line ?? "no line")")
        let bad = Contributor(id: "unscoped-values") { r in r.contribute({ (_: AnyShapeRecord, _: CanvasEditor) -> String? in "x" }, to: IssueRowValues.self) }
        do {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FixturesPlugin(), ValidationPlugin(), bad])
            expect(false, "a value for every shape with no scope is refused")
        } catch let error as RegistryError {
            guard case .invalid(let point, _) = error else { return expect(false, "\(error)") }
            expectEqual(point, "IssueRowValues")
        }
    },
])
