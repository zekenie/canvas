import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Find
import Foundation
import Locking
import Selection
import ShippedTesting
import StickyNotes
import TestKit
import Titles
import Types

// The pair, on the shipped list with real arrows and real presses: the two arrows at a relationship type are one line through
// its pill for the select tool. A point on either half is the type (hover, a click, a right-click) and both halves are
// outlined with it; once the type is selected a press on a half is the half's, with its end handles; Delete takes the type and its
// ends in one step. And ⌘F finds the type by its name, ringing the capsule.

@MainActor
private struct Pair {
    let m: Minute
    var editor: CanvasEditor { m.editor }
    let hub: ShapeID
    let from: ShapeID, to: ShapeID

    init() throws {
        let m = try Minute()
        self.m = m
        try m.drag(from: m.feature, to: m.layer)
        let field = try require(m.pillField)
        field.insertText("owner", replacementRange: NSRange(location: 0, length: 0))
        field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        m.editor.closeCard()
        m.editor.selection = nil
        m.editor.undoHistory.seal()
        let hub = try require(m.editor.document.shapes.last { $0[RelationshipProperty.self] == true }).id
        let index = try require(m.editor.relationships)
        let ends = index.endArrows(of: hub)
        self.hub = hub
        from = try require(ends.first { index.end($0)?.side == .from })
        to = try require(ends.first { index.end($0)?.side == .to })
    }

    /// A point on a half's line: a quarter of the way along it from its far end to the pill.
    func onHalf(_ arrow: ShapeID) throws -> CGPoint {
        let geometry = try require(editor.arrowGeometry(of: arrow))
        let far = arrow == from ? geometry.startHandle : geometry.endHandle
        let near = arrow == from ? geometry.endHandle : geometry.startHandle
        return CGPoint(x: far.x + (near.x - far.x) * 0.4, y: far.y + (near.y - far.y) * 0.4)
    }

    func view(_ world: CGPoint) -> CGPoint { m.h.view(world) }
    func hover(_ world: CGPoint) { m.h.move(to: view(world)) }
    func click(_ world: CGPoint, count: Int = 1) { m.h.click(at: view(world), clickCount: count) }

    /// Accent-blue pixels in the strip of the canvas around a half's middle, as the canvas draws it now.
    func accent(around arrow: ShapeID) throws -> Int {
        let at = try onHalf(arrow)
        let rep = renderBitmap(editor, size: CGSize(width: 1600, height: 900))
        var count = 0
        for dx in -20...20 { for dy in -12...12 {
            let p = pixel(rep, at: view(CGPoint(x: at.x + CGFloat(dx), y: at.y + CGFloat(dy))))
            if p.count >= 3, p[2] > p[0] + 80, p[2] > 180 { count += 1 }
        } }
        return count
    }
}

@MainActor let relationshipPairShippedTests = Suite("The pair of halves of a relationship type, shipped", [
    test("the pointer on either half hovers the relationship type, and its pill and both halves are lit faintly; off the line, nothing") {
        let p = try Pair()
        defer { p.m.close() }
        p.hover(try p.onHalf(p.from))
        expectEqual(p.editor.hovered, p.hub)
        expectEqual(Set(p.editor.outlines.faintShapes), [p.hub, p.from, p.to])
        p.hover(try p.onHalf(p.to))
        expectEqual(p.editor.hovered, p.hub)
        p.hover(CGPoint(x: 600, y: 700))
        expectEqual(p.editor.hovered, nil)
        expectEqual(p.editor.outlines.faintShapes, [])
    },
    test("a click on a half selects the type and outlines the pill and both halves; a second click on a half takes that half alone, with its handles") {
        let p = try Pair()
        defer { p.m.close() }
        let editor = p.editor
        let before = try p.accent(around: p.to)
        p.click(try p.onHalf(p.from))
        expectEqual(editor.selectedShapeIDs, [p.hub])
        expectEqual(Set(editor.outlines.shapes), [p.hub, p.from, p.to])
        expect(try p.accent(around: p.to) > before + 20, "the half the click was not on is drawn outlined too")
        // Another view takes the keyboard: the halves go quiet with the type, not back to the accent (P7).
        editor.keyboardDidChange(hasKeyboard: false)
        expect(editor.outlines.color != nil, "the selection's quiet color, the halves with it")
        expectEqual(editor.outlines.color, editor.selectionOutlineColor)
        editor.keyboardDidChange(hasKeyboard: true)
        expectEqual(editor.outlines.color, nil, "the accent again")
        // A pointer on a half of the selected type hovers the half, not the type.
        p.hover(try p.onHalf(p.from))
        expectEqual(editor.hovered, p.from)
        p.click(try p.onHalf(p.from))
        expectEqual(editor.selectedShapeIDs, [p.from])
        expectEqual(editor.outlines.shapes, [p.from])
        expect(editor.handle(atViewPoint: p.view(try require(editor.arrowGeometry(of: p.from)).startHandle)) != nil, "its end handles")
        // The other half, with this half selected: the type again (neither it nor its half is selected).
        p.click(try p.onHalf(p.to))
        expectEqual(editor.selectedShapeIDs, [p.hub])
    },
    test("a double-click on a half opens the type's card: the first click selects the type, the second is the half's and runs the open") {
        let p = try Pair()
        defer { p.m.close() }
        p.click(try p.onHalf(p.from))
        p.click(try p.onHalf(p.from), count: 2)
        expect(p.editor.card != nil, "the card is open")
        expectEqual(p.editor.selectedShapeIDs, [p.hub], "the card is the type's, and selects it")
    },
    test("an end of the selected half dragged to another type re-aims that half; Escape and a click elsewhere let go") {
        let p = try Pair()
        defer { p.m.close() }
        let editor = p.editor
        p.click(try p.onHalf(p.from))
        p.click(try p.onHalf(p.from))
        let geometry = try require(editor.arrowGeometry(of: p.from))
        let handle = geometry.startHandle
        let other = try p.m.center(p.m.layerNote)
        p.m.h.move(to: p.view(handle))
        p.m.h.press()
        p.m.h.drag(to: p.view(other), speed: 3)
        p.m.h.release()
        let arrow = try require(editor.document[p.from]?.typed(as: Arrow.self))
        expectEqual(arrow.props.start.binding?.shapeID, p.m.layerNote, "the far end now at the note")
        editor.undo()
        expectEqual(editor.document[p.from]?.typed(as: Arrow.self)?.props.start.binding?.shapeID, p.m.feature)
        p.m.h.escape()
        p.click(CGPoint(x: 600, y: 800))
        expectEqual(editor.selectedShapeIDs, [])
    },
    test("Delete with the type selected takes it and both halves in one step, and one Undo gives them back exact") {
        let p = try Pair()
        defer { p.m.close() }
        let editor = p.editor
        let start = editor.document
        p.click(try p.onHalf(p.to))
        expectEqual(editor.selectedShapeIDs, [p.hub])
        expect(p.m.h.key("\u{7f}"), "Delete is heard")
        expect(editor.document[p.hub] == nil && editor.document[p.from] == nil && editor.document[p.to] == nil)
        expectEqual(editor.undoHistory.undoName, "Delete Note and 2 Arrows", "the step says what went along")
        editor.undo()
        expectEqual(editor.document, start)
        expect(editor.relationships?.endArrows(of: p.hub).count == 2)
    },
    test("Cut with the type selected is named for the halves it took, as Delete is: Undo Cut Note and 2 Arrows") {
        let p = try Pair()
        defer { p.m.close() }
        let editor = p.editor
        let start = editor.document
        p.click(try p.onHalf(p.to))
        expectEqual(editor.selectedShapeIDs, [p.hub])
        p.m.h.hold(.command)
        expect(p.m.h.key("x"), "⌘X is heard")
        p.m.h.hold([])
        expect(editor.document[p.hub] == nil && editor.document[p.from] == nil && editor.document[p.to] == nil)
        expectEqual(editor.undoHistory.undoName, "Cut Note and 2 Arrows")
        editor.undo()
        expectEqual(editor.document, start)
    },
    test("a right-click on a half is the type's menu, with Straighten; on a selected half, the arrow's own") {
        let p = try Pair()
        defer { p.m.close() }
        let editor = p.editor
        var menu = try require(p.m.h.secondaryClick(at: p.view(try p.onHalf(p.from))))
        expect(menu.outline.contains("Straighten") || menu.outline.contains("(Straighten)"), "\(menu.outline)")
        expectEqual(editor.selectedShapeIDs, [p.hub])
        editor.selectedShapeIDs = [p.from]
        menu = try require(p.m.h.secondaryClick(at: p.view(try p.onHalf(p.from))))
        expect(!menu.outline.contains("Straighten"), "the arrow's own: \(menu.outline)")
        expectEqual(editor.selectedShapeIDs, [p.from])
    },
    test("a locked type is selected by a click on a half and outlined with them, and Delete shakes and takes nothing") {
        let p = try Pair()
        defer { p.m.close() }
        let editor = p.editor
        editor.lock([p.hub])
        let start = editor.document
        p.click(try p.onHalf(p.from))
        expectEqual(editor.selectedShapeIDs, [p.hub])
        expectEqual(Set(editor.outlines.shapes), [p.hub, p.from, p.to])
        _ = p.m.h.key("\u{7f}")
        expectEqual(editor.document, start)
    },
    test("⌘F finds a relationship type by its name, ringing the capsule, and a rename follows") {
        let p = try Pair()
        defer { p.m.close() }
        let editor = p.editor
        let find = try require(editor.find)
        find.open()
        find.query = "owner"
        while find.isIndexing { p.m.h.scheduler.advance(by: .zero) }
        _ = try awaitResult { await find.settled() }
        expectEqual(find.results.map(\.id), [p.hub])
        let box = try require(editor.shapeContext.geometry(of: p.hub)?.bounds)
        let hit = try require(find.currentHit).hit
        expectEqual(find.rects(of: hit, in: p.hub).first?.size, box.size, "the capsule")
        editor.transact("Rename") { $0.update(p.hub) { $0[TitleProperty.self] = "keeper" } }
        find.query = "owner"
        while find.isIndexing { p.m.h.scheduler.advance(by: .zero) }
        _ = try awaitResult { await find.settled() }
        expectEqual(find.results.count, 0)
        find.query = "keeper"
        while find.isIndexing { p.m.h.scheduler.advance(by: .zero) }
        _ = try awaitResult { await find.settled() }
        expectEqual(find.results.map(\.id), [p.hub])
    },
    test("a note lying over a half's line is the note's: a click there selects the note, not the relationship type") {
        let p = try Pair()
        defer { p.m.close() }
        let at = try p.onHalf(p.from)
        let note = AnyShapeRecord(ShapeRecord(StickyNote(frame: CGRect(x: at.x - 40, y: at.y - 40, width: 80, height: 80))))
        p.editor.transact { $0.insert(note) }
        p.click(at)
        expectEqual(p.editor.selectedShapeIDs, [note.id], "the note in front, not the type under it")
        p.click(try p.onHalf(p.to))
        expectEqual(p.editor.selectedShapeIDs, [p.hub], "the other half, with nothing over it, is the type")
    },
])
