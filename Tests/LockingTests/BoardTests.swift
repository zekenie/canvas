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
