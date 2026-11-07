import AppKit
import Canvas
import CanvasTesting
import Clipboard
import CoreGraphics
import Foundation
import TestKit

// Shapes that take what is bound to them (`TakesBoundShapes`, CanvasTesting's ledgers) are copied with what is bound only to
// shapes copied: two ledgers copied, duplicated or cut keep the link between them, selected or not; a cut names what went
// ("Cut Ledger and 2 links"). Boxes keep tldraw's rule: a copy keeps a binding only for a link among the shapes given.

@MainActor private func ledgers(_ pasteboard: NSPasteboard) throws -> EditorHarness {
    try harness(pasteboard, [LedgersPlugin()])
}

@MainActor private func linkProps(_ editor: CanvasEditor, _ id: ShapeID) -> Link? { editor.document[id]?.typed(as: Link.self)?.props }

@MainActor let takeAlongTests = Suite("Copying shapes that take what is bound to them", [
    test("two ledgers copied take the link between them, selected or not, and the paste binds it to the copies; a link to a shape not copied stays behind") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try ledgers(pasteboard)
        let a = h.add(Ledger(slot(0))), b = h.add(Ledger(slot(1))), c = h.add(Box(slot(2)))
        let between = h.add(Link(from: a, to: b)), toBox = h.add(Link(from: a, to: c)), loose = h.add(Link(from: nil, to: nil))
        let before = h.editor.document
        expectEqual(h.editor.copy([a, b]).count, 3, "the two ledgers and the link between them")
        h.editor.paste()
        let added = h.editor.shapes(since: before)
        expectEqual(added.map(\.kind), [Ledger.kind, Ledger.kind, Link.kind])
        let copies = added.filter { $0.kind == Ledger.kind }.map(\.id)
        let copy = try require(added.last)
        expectEqual(copy.typed(as: Link.self)?.props, Link(from: copies[0], to: copies[1]), "bound to the copies")
        expectEqual(copy.copiedFrom, between)
        expect(h.editor.document[toBox] != nil && h.editor.document[loose] != nil)
        expectEqual(linkProps(h.editor, between), Link(from: a, to: b), "the original is as it was")
    },
    test("one ledger copied takes no link: it is bound to a shape not copied") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try ledgers(pasteboard)
        let a = h.add(Ledger(slot(0))), b = h.add(Ledger(slot(1)))
        h.add(Link(from: a, to: b))
        h.add(Link(from: a, to: a))
        expectEqual(h.editor.copy([a]).count, 2, "the ledger and the link from it to itself, which is bound only to a shape copied")
    },
    test("duplicating two ledgers keeps the link between them, in one step, Duplicate") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try ledgers(pasteboard)
        let a = h.add(Ledger(slot(0))), b = h.add(Ledger(slot(1)))
        let between = h.add(Link(from: b, to: a))
        let before = h.editor.document
        let made = h.editor.duplicate([a, b], offsetBy: CGPoint(x: 16, y: 16))
        let added = h.editor.shapes(since: before)
        expectEqual(added.count, 3)
        expectEqual(made.count, 3, "the copies, the link taken along among them, selected")
        let copies = added.filter { $0.kind == Ledger.kind }
        let link = try require(added.first { $0.kind == Link.kind })
        expectEqual(link.typed(as: Link.self)?.props, Link(from: copies[1].id, to: copies[0].id))
        expect(link.id != between)
        expectEqual(h.editor.undoHistory.undoName, "Duplicate")
        h.editor.undo()
        expectEqual(h.editor.document, before)
    },
    test("two boxes copied keep tldraw's rule: a link between them that isn't selected stays behind") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try ledgers(pasteboard)
        let a = h.add(Box(slot(0))), b = h.add(Box(slot(1)))
        h.add(Link(from: a, to: b))
        expectEqual(h.editor.copy([a, b]).count, 2)
    },
    test("cutting a ledger deletes the links bound to it and names the step for them; a paste brings back the ledger, not those links") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try ledgers(pasteboard)
        let a = h.add(Ledger(slot(0))), b = h.add(Ledger(slot(1))), c = h.add(Box(slot(2)))
        let toBox = h.add(Link(from: a, to: c)), fromB = h.add(Link(from: b, to: a))
        let before = h.editor.document
        h.editor.cut([a])
        expectEqual(h.editor.undoHistory.undoName, "Cut Ledger and 2 links")
        expect(h.editor.document[a] == nil && h.editor.document[toBox] == nil && h.editor.document[fromB] == nil)
        h.editor.paste()
        expect(h.editor.document[a] != nil, "the ledger is back under its id")
        expect(h.editor.document[toBox] == nil && h.editor.document[fromB] == nil, "the links to shapes not cut are not")
        h.editor.undo()
        h.editor.undo()
        expectEqual(h.editor.document, before, "undo puts everything back exact")
    },
    test("cutting two ledgers takes the link between them with the copy and the others with the delete: one name, and a paste brings back the link between") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try ledgers(pasteboard)
        let a = h.add(Ledger(slot(0))), b = h.add(Ledger(slot(1))), c = h.add(Box(slot(2)))
        let between = h.add(Link(from: a, to: b)), toBox = h.add(Link(from: b, to: c))
        h.editor.cut([a, b])
        expectEqual(h.editor.undoHistory.undoName, "Cut 2 Ledgers and 2 links")
        expect([a, b, between, toBox].allSatisfy { h.editor.document[$0] == nil })
        h.editor.paste()
        expect(h.editor.document[a] != nil && h.editor.document[b] != nil)
        expectEqual(linkProps(h.editor, between), Link(from: a, to: b), "the link between them is back, bound, under its id")
        expect(h.editor.document[toBox] == nil)
    },
    test("a cut that took nothing along is just Cut: a box whose links let go, a ledger with none") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try ledgers(pasteboard)
        let box = h.add(Box(slot(0))), a = h.add(Ledger(slot(1))), c = h.add(Box(slot(2)))
        let link = h.add(Link(from: box, to: c))
        h.editor.cut([box])
        expectEqual(h.editor.undoHistory.undoName, "Cut")
        expectEqual(linkProps(h.editor, link), Link(from: nil, to: c), "it let go of the box")
        h.editor.cut([a])
        expectEqual(h.editor.undoHistory.undoName, "Cut")
    },
])
