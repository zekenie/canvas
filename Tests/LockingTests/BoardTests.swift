import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Locking
import Selection
import TestKit

/// A file whose root holds `root` and a pocket, and whose pocket's board holds `inside`.
@MainActor private func pocketHarness(root: [AnyShapeRecord] = [], inside: [AnyShapeRecord]) throws -> (h: EditorHarness, pocket: ShapeID) {
    let pocket = ShapeRecord(Pocket(CGRect(x: 100, y: 250, width: 150, height: 40)))
    let file = CanvasFile(root: CanvasDocument(shapes: root + [AnyShapeRecord(pocket)]),
                          children: [pocket.id: CanvasDocument(shapes: inside)])
    return (try lockingHarness([PocketsPlugin()], file: file), pocket.id)
}

@MainActor private func locked<P: ShapeProps>(_ props: P) -> AnyShapeRecord {
    var record = AnyShapeRecord(ShapeRecord(props))
    record[LockedProperty.self] = true
    return record
}

/// A locked pocket P on the root; its board holds a box A, a card C, a box L locked on its own (its
/// chip at `chipCenter`) and a pocket Q, whose board holds a box B.
@MainActor private struct LockedNest {
    let p = ShapeID(), a = ShapeID(), c = ShapeID(), l = ShapeID(), q = ShapeID(), b = ShapeID()
    static let aFrame = CGRect(x: 270, y: 130, width: 100, height: 100)
    static let cFrame = CGRect(x: 100, y: 220, width: 100, height: 60)

    var file: CanvasFile {
        var pocket = AnyShapeRecord(ShapeRecord(id: p, Pocket(CGRect(x: 100, y: 250, width: 150, height: 40))))
        pocket[LockedProperty.self] = true
        var own = AnyShapeRecord(ShapeRecord(id: l, Box(chipBox)))
        own[LockedProperty.self] = true
        func record<Props: ShapeProps>(_ id: ShapeID, _ props: Props) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, props)) }
        return CanvasFile(root: CanvasDocument(shapes: [pocket]),
                          children: [p: CanvasDocument(shapes: [record(a, Box(Self.aFrame)), record(c, Card(Self.cFrame)), own,
                                                                record(q, Pocket(CGRect(x: 280, y: 20, width: 80, height: 50)))]),
                                     q: CanvasDocument(shapes: [record(b, Box(CGRect(x: 100, y: 100, width: 100, height: 100)))])])
    }

    func harness() throws -> EditorHarness { try lockingHarness([PocketsPlugin()], file: file) }
}

@MainActor let lockingBoardTests = Suite("Locking across boards", [
    test("a locked shape that owns a board is entered, but not deleted: it keeps its board") {
        let inner = AnyShapeRecord(ShapeRecord(Box(chipBox)))
        let (h, pocket) = try pocketHarness(inside: [inner])
        h.editor.lock([pocket])
        expect(h.enter(pocket), "entering isn't a change to it")
        expectEqual(h.editor.document.shapes.map(\.id), [inner.id])
        h.editor.showBoard(.root)
        h.editor.selectedShapeIDs = [pocket]
        expect(h.key("\u{7f}"))
        expectEqual(h.editor.document.shapes.map(\.id), [pocket])
        expectEqual(h.file[BoardID(owner: pocket)].shapes.map(\.id), [inner.id])
    },
    test("a locked subboard is entered, and what's on its board holds still, at any depth: a drag moves no shape, Delete takes none, none is edited, and each try shakes it") {
        let n = LockedNest(), h = try n.harness()
        expect(h.enter(n.p), "entering isn't a change")
        expect(h.editor.isBoardReadOnly && !h.editor.isLocked(n.a), "read-only, though A isn't locked itself")
        let before = h.file
        h.press(at: CGPoint(x: 320, y: 180))
        h.drag(to: CGPoint(x: 360, y: 180))
        h.wait(16)
        expectEqual(h.editor.document[n.a]?.box, LockedNest.aFrame, "a drag moves nothing")
        expect(h.editor.drawingOffset(of: n.a) != .zero, "the shape shakes")
        h.release()
        h.wait(1000)
        h.editor.selectedShapeIDs = [n.a]
        expect(h.key("\u{7f}"))
        expectEqual(h.editor.document[n.a]?.box, LockedNest.aFrame)
        h.wait(16)
        expect(h.editor.drawingOffset(of: n.a) != .zero, "Delete shakes it")
        h.wait(1000)
        h.click(at: CGPoint(x: 150, y: 250))
        h.click(at: CGPoint(x: 150, y: 250), clickCount: 2)
        expectEqual(h.editor.editingShapeID, nil, "a double-click edits no card")
        h.wait(16)
        expect(h.editor.drawingOffset(of: n.c) != .zero, "and shakes it")
        expectEqual(h.file, before, "nothing changed")
        expect(!h.editor.canUndo, "and no step")
        expect(h.enter(n.q), "a pocket on it opens")
        expect(h.editor.isBoardReadOnly && h.editor.isReadOnly(n.b), "its board is read-only too")
        h.editor.selectedShapeIDs = [n.b]
        expect(h.key("\u{7f}"))
        expectEqual(h.editor.document.shapes.map(\.id), [n.b])
        expectEqual(h.file, before)
    },
    test("on its board neither Lock nor Unlock is offered, whatever the shape; a box locked on its own keeps its chip, and a click on it is refused: it shakes, and stays locked") {
        let n = LockedNest(), h = try n.harness()
        expect(h.enter(n.p))
        for (shape, at) in [(n.a, CGPoint(x: 320, y: 180)), (n.l, CGPoint(x: 150, y: 150))] {
            let outline = try require(h.secondaryClick(at: at)).outline
            expectEqual(h.editor.selectedShapeIDs, [shape])
            expect(!outline.contains("Lock") && !outline.contains("Unlock"), "\(outline)")
        }
        h.editor.selectedShapeIDs = [n.a, n.l]
        let both = try require(h.secondaryClick(at: CGPoint(x: 320, y: 180))).outline
        expect(!both.contains("Lock") && !both.contains("Unlock"), "\(both)")
        expect(h.editor.isLocked(n.l) && h.editor.button(atViewPoint: chipCenter) != nil, "L's chip")
        h.wait(1000)
        let before = h.file
        h.click(at: chipCenter)
        expect(h.editor.isLocked(n.l), "still locked")
        expectEqual(h.file, before)
        expect(!h.editor.canUndo)
        h.wait(16)
        expect(h.editor.drawingOffset(of: n.l) != .zero, "it shakes")
        h.move(to: elsewhere)
        h.wait(2000)
        expect(h.editor.isLocked(n.l) && h.editor.button(atViewPoint: chipCenter) != nil, "the chip stays: no unlock to fade from")
    },
    test("unlocking the subboard makes its board editable again, and the boards under it: what was locked on its own stays locked") {
        let n = LockedNest(), h = try n.harness()
        expect(h.enter(n.p))
        expect(h.enter(n.q))
        expect(h.editor.isBoardReadOnly)
        expect(h.editor.showBoard(.root))
        h.editor.unlock([n.p])
        expect(h.enter(n.p))
        expect(!h.editor.isBoardReadOnly && !h.editor.isReadOnly(n.a))
        expect(h.editor.isReadOnly(n.l), "L is locked itself")
        h.press(at: CGPoint(x: 320, y: 180))
        h.drag(to: CGPoint(x: 360, y: 180))
        h.release()
        expectEqual(h.editor.document[n.a]?.box, LockedNest.aFrame.offsetBy(dx: 40, dy: 0), "it moves now")
        let menu = try require(h.secondaryClick(at: CGPoint(x: 360, y: 180))).outline
        expect(menu.contains("Lock"), "\(menu)")
        expect(h.enter(n.q))
        expect(!h.editor.isBoardReadOnly && !h.editor.isReadOnly(n.b))
    },
    test("a shape whose board holds a locked shape isn't deleted either, and it's the one that shakes") {
        let (h, pocket) = try pocketHarness(inside: [locked(Box(chipBox))])
        expect(!h.editor.isLocked(pocket))
        h.editor.selectedShapeIDs = [pocket]
        expect(h.key("\u{7f}"))
        expectEqual(h.editor.document.shapes.map(\.id), [pocket])
        h.wait(16)
        expect(h.editor.drawingOffset(of: pocket) != .zero, "it shakes, though it isn't locked itself")
    },
    test("the board shown gets its own chips; the one left stops shaking, and its open lock goes") {
        let outer = locked(Box(chipBox))
        let (h, pocket) = try pocketHarness(root: [outer], inside: [locked(Box(chipBox))])
        let plain = try pocketHarness(root: [AnyShapeRecord(ShapeRecord(Box(chipBox)))], inside: []).h
        h.editor.selectedShapeIDs = [outer.id]
        expect(h.key("\u{7f}"))                        // refused: it shakes
        h.wait(16)
        expect(h.editor.drawingOffset(of: outer.id) != .zero)
        h.enter(pocket)
        expect(h.editor.button(atViewPoint: chipCenter) != nil, "the locked box inside has its chip")
        h.editor.showBoard(.root)
        h.wait(16)
        expectEqual(h.editor.drawingOffset(of: outer.id), .zero, "its shake stopped when its board was left")
        h.editor.selectedShapeIDs = [outer.id]
        expect(h.key("\u{7f}"))
        h.wait(16)
        expect(h.editor.drawingOffset(of: outer.id) != .zero, "refused again, it shakes again: the stopped shake went with the board")
        h.wait(400)
        expectEqual(h.editor.drawingOffset(of: outer.id), .zero)
        h.editor.selectedShapeIDs = []
        h.click(at: chipCenter)                         // unlocks it: the lock shows open
        expect(!h.editor.isLocked(outer.id))
        h.enter(pocket)
        h.editor.showBoard(.root)
        h.move(to: elsewhere)
        expectEqual(h.editor.button(atViewPoint: chipCenter), nil, "the open lock went with the board")
        expectEqual(changedPixels(render(plain), render(h), in: wholeView), 0)
    },
    test("going back to a board takes back its locked shapes as they were kept; one changed since is looked through again") {
        let inner = locked(Box(chipBox))
        let (h, pocket) = try pocketHarness(root: [locked(Box(chipBox))], inside: [inner])
        h.enter(pocket)
        h.editor.showBoard(.root)
        #if DEBUG
        let scanned = h.editor.boardsScannedForLocks
        #endif
        h.enter(pocket)
        expect(h.editor.button(atViewPoint: chipCenter) != nil, "the locked box inside has its chip")
        h.editor.showBoard(.root)
        expect(h.editor.button(atViewPoint: chipCenter) != nil, "and the root's has its own")
        #if DEBUG
        expectEqual(h.editor.boardsScannedForLocks, scanned, "neither board looked through again")
        #endif
        var file = h.file                                // the pocket's box unlocked while the root is shown
        var unlocked = inner
        unlocked[LockedProperty.self] = nil
        file.set(CanvasDocument(shapes: [unlocked]), for: BoardID(owner: pocket))
        h.editor.replaceFile(with: file)
        h.enter(pocket)
        expect(!h.editor.isLocked(inner.id))
        expectEqual(h.editor.button(atViewPoint: chipCenter), nil, "what was kept of the board before isn't taken for it")
    },
])
