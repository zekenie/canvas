import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Geometry
import TestKit

// A card made with `adoptsPress` and shown in a press (or any action) takes that step over: the press and
// the card's commits are one Undo and one Redo, however the card closes. Shown outside any action, it is
// as any card.

private let cardAnchor = CGRect(x: 100, y: 100, width: 120, height: 22)

@MainActor private final class CardRig {
    let h: EditorHarness
    let box = ShapeID(), pocket = ShapeID(), inner = ShapeID()
    let probe = CardProbe(frame: .zero)
    let log = ClosingLog()

    init() throws {
        let root = CanvasDocument(shapes: [
            AnyShapeRecord(ShapeRecord(id: box, Box(CGRect(x: 400, y: 100, width: 100, height: 100)))),
            AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 600, y: 0, width: 100, height: 100)))),
        ])
        let inside = CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: inner, Box(CGRect(x: 0, y: 0, width: 10, height: 10))))])
        h = try EditorHarness(plugins: [FixturesPlugin(), CardsPlugin(), PocketsPlugin(), FreezingPlugin()],
                              file: CanvasFile(root: root, children: [pocket: inside]))
    }

    var e: CanvasEditor { h.editor }

    func card(_ id: String = "c", step: String? = "Card", adoptsPress: Bool = true) -> CanvasCard {
        probeCard(id, anchor: cardAnchor, stepName: step, adoptsPress: adoptsPress, probe: probe, closings: log)
    }

    func nudge(_ key: AnyHashable? = nil, _ name: String? = nil) {
        h.editor.transact(name, coalescing: key) { $0.update(box, as: Box.self) { $0.frame.origin.x += 1 } }
    }

    /// A press that changes the document and shows an adopting card, released; then one card commit.
    func gesture() {
        h.press(at: CGPoint(x: 900, y: 600))
        nudge(nil, "Press")
        expect(e.showCard(card()))
        h.release()
        nudge("c")
    }

    func encoded(_ file: CanvasFile) throws -> Data { try BoardCodec(registry: e.registry).encode(file) }
}

@MainActor let cardAdoptionTests = Suite("A card that adopts a press", [
    test("press + card, closed each way, is one Undo that returns the whole file, and one Redo that restores it") {
        let closings: [(String, @MainActor (CardRig) -> Void)] = [
            ("asked", { $0.e.closeCard() }),
            ("a press elsewhere that changes nothing", { $0.h.click(at: CGPoint(x: 900, y: 650)) }),
            ("a board shown and left", { rig in rig.h.enter(rig.pocket); _ = rig.e.showBoard(.root) }),
            ("editing begun and ended", { rig in rig.e.undoHistory.seal() ; rig.e.closeCard(.editing) }),
            ("replaced by a card that holds no step", { rig in _ = rig.e.showCard(rig.card("d", step: nil, adoptsPress: false)); rig.e.closeCard() }),
        ]
        for (what, close) in closings {
            let rig = try CardRig()
            let e = rig.e
            let s0 = rig.h.file
            rig.gesture()
            let s1 = rig.h.file
            expect(s0 != s1)
            close(rig)
            expect(e.card == nil, "\(what): closed")
            expectEqual(rig.h.file, s1, "\(what): closing changes nothing")
            e.undo()
            expectEqual(rig.h.file, s0, "\(what): one Undo returns the file")
            expectEqual(try rig.encoded(rig.h.file), try rig.encoded(s0), "\(what): as bytes")
            expect(!e.canUndo, "\(what): and it was the only step")
            e.redo()
            expectEqual(rig.h.file, s1, "\(what): one Redo restores it")
            expect(!e.canRedo, "\(what)")
        }
    },
    test("undo with the card up takes the whole step, and redo puts all of it back") {
        let rig = try CardRig()
        let e = rig.e
        let s0 = rig.h.file
        rig.gesture()
        rig.nudge("c")
        let s1 = rig.h.file
        e.undo()
        expectEqual(rig.log.closings, [.undo])
        expectEqual(rig.h.file, s0)
        expect(!e.canUndo)
        e.redo()
        expectEqual(rig.h.file, s1)
    },
    test("a step on another board while the adopted step is kept: each undo and redo is exact") {
        let rig = try CardRig()
        let e = rig.e
        let s0 = rig.h.file
        rig.gesture()
        let s1 = rig.h.file
        e.transact(on: BoardID(owner: rig.pocket), "Elsewhere") { $0.update(rig.inner, as: Box.self) { $0.frame.origin.x = 55 } }
        let s2 = rig.h.file
        rig.nudge("c")
        let s3 = rig.h.file
        e.closeCard()
        expect(s0 != s1 && s1 != s2 && s2 != s3)
        var seen: [CanvasFile] = []
        while e.canUndo { e.undo(); seen.append(rig.h.file) }
        expectEqual(seen.last, s0, "all undone returns the file")
        _ = e.showBoard(.root)
        while e.canRedo { e.redo() }
        _ = e.showBoard(.root)
        expectEqual(rig.h.file, s3, "all redone restores it")
    },
    test("breakStep while the card is up, then close: two undos return the file exactly, two redos restore it") {
        let rig = try CardRig()
        let e = rig.e
        let s0 = rig.h.file
        rig.gesture()
        let s1 = rig.h.file
        e.undoHistory.breakStep()
        rig.nudge("c")
        let s2 = rig.h.file
        e.closeCard()
        e.undo(); expectEqual(rig.h.file, s1)
        e.undo(); expectEqual(rig.h.file, s0)
        expect(!e.canUndo)
        e.redo(); e.redo()
        expectEqual(rig.h.file, s2)
    },
    test("a card that adopts, shown outside any action, is as any card: a later action that sets its step name is a step of its own, closed when that action ends") {
        let rig = try CardRig()
        let e = rig.e
        expect(e.showCard(rig.card()))
        rig.nudge("c")                                   // the card's own step, 401
        e.undoHistory.group("Other") {
            rig.nudge(nil, "Inner")                      // 402, the group's
            e.setCardStep("Renamed")
        }
        rig.nudge("c")                                   // 403: the card's next commit
        e.closeCard()
        e.undo()
        let x = e.document[rig.box]?.box?.origin.x
        expectEqual(x, 402, "the card's commit after the group is a step apart from the group's")
    },
    test("a card that does not adopt, same sequence: the group's step is its own") {
        let rig = try CardRig()
        let e = rig.e
        expect(e.showCard(rig.card(adoptsPress: false)))
        rig.nudge("c")
        e.undoHistory.group("Other") {
            rig.nudge(nil, "Inner")
            e.setCardStep("Renamed")
        }
        rig.nudge("c")
        e.closeCard()
        e.undo()
        expectEqual(e.document[rig.box]?.box?.origin.x, 402)
    },
    test("a second card that adopts, shown in a later press while the first's adopted step is kept: each press is its own step") {
        let rig = try CardRig()
        let e = rig.e
        let s0 = rig.h.file
        rig.gesture()
        let s1 = rig.h.file
        rig.h.press(at: CGPoint(x: 900, y: 650))
        rig.nudge(nil, "Second")
        expect(e.showCard(rig.card("d")))
        rig.h.release()
        rig.nudge("d")
        let s2 = rig.h.file
        e.closeCard()
        e.undo(); expectEqual(rig.h.file, s1, "the second press and its card")
        e.undo(); expectEqual(rig.h.file, s0, "the first")
        expect(!e.canUndo)
        e.redo(); e.redo()
        expectEqual(rig.h.file, s2)
    },
    test("a key's action that shows an adopting card: its step is the card's, not held for the key's repeats") {
        let rig = try CardRig()
        let e = rig.e
        let s0 = rig.h.file
        e.undoHistory.group("Command") {
            rig.nudge(nil, "Inner")
            _ = e.showCard(rig.card())
        }
        rig.nudge("c")
        e.undoHistory.seal()
        rig.nudge("c")
        e.closeCard()
        e.undo()
        expectEqual(rig.h.file, s0)
        expect(!e.canUndo)
    },
])
