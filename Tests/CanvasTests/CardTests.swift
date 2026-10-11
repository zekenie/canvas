import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Geometry
import TestKit

// The card: a plugin's view shown under a rect of the board, one at a time, closed as the person goes on
// to something else, and holding the undo step its plugin names until it closes. Headless: the host is
// a stub that counts what the editor tells it; CanvasUITests' `cardViewTests` hold the view.

/// Counts what the editor tells its view of the card, and what the card was then.
@MainActor private final class CardHost: CanvasEditorDelegate {
    var tells = 0
    var anchors: [CGRect?] = []
    /// What happened, in order: "told" as the host hears, then whatever a test's `didClose` adds.
    var order: [String] = []
    func editorNeedsDisplay(_ editor: CanvasEditor) {}
    func editorCursorDidChange(_ editor: CanvasEditor) {}
    func editorEditingDidChange(_ editor: CanvasEditor) {}
    func editorCardDidChange(_ editor: CanvasEditor) {
        tells += 1
        anchors.append(editor.card?.anchor)
        order.append("told")
    }
}

private let anchor = CGRect(x: 100, y: 100, width: 120, height: 22)

/// An editor of a root with two editable notes, a box and a pocket (which owns a board of one box), a
/// counting host, and one probe card at a time.
@MainActor private final class Rig {
    let h: EditorHarness
    let host = CardHost()
    let note = ShapeID(), other = ShapeID(), box = ShapeID(), pocket = ShapeID()
    let probe = CardProbe(frame: .zero)
    let log = ClosingLog()

    init() throws {
        let root = CanvasDocument(shapes: [
            AnyShapeRecord(ShapeRecord(id: note, Card(CGRect(x: 0, y: 300, width: 100, height: 60)))),
            AnyShapeRecord(ShapeRecord(id: other, Card(CGRect(x: 300, y: 300, width: 100, height: 60)))),
            AnyShapeRecord(ShapeRecord(id: box, Box(CGRect(x: 400, y: 100, width: 100, height: 100)))),
            AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 600, y: 0, width: 100, height: 100)))),
        ])
        let inside = CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(Box(CGRect(x: 0, y: 0, width: 10, height: 10))))])
        h = try EditorHarness(plugins: [FixturesPlugin(), CardsPlugin(), PocketsPlugin(), FreezingPlugin()],
                              file: CanvasFile(root: root, children: [pocket: inside]))
        h.editor.delegate = host
        log.heard = { [unowned host] _ in host.order.append("closed") }
    }

    func card(_ id: String = "c", about shape: ShapeID? = nil, at rect: CGRect = anchor, step: String? = nil) -> CanvasCard {
        probeCard(id, about: shape, anchor: rect, stepName: step, probe: probe, closings: log)
    }

    /// Shows a card about `shape`, and forgets what the host was told and the history before it.
    @discardableResult
    func show(_ id: String = "c", about shape: ShapeID? = nil, step: String? = nil) -> Bool {
        let shown = h.editor.showCard(card(id, about: shape, step: step))
        host.tells = 0
        host.anchors = []
        host.order = []
        return shown
    }

    /// Moves the box, in a transaction, coalescing under `key`.
    func nudge(_ key: AnyHashable? = nil, _ name: String? = nil) {
        h.editor.transact(name, coalescing: key) { $0.update(box, as: Box.self) { $0.frame.origin.x += 1 } }
    }

    var boxX: CGFloat { h.editor.document[box]?.box?.origin.x ?? -1 }
    var name: String? { h.editor.card.flatMap { $0.id.base as? String } }
}

/// What is there so far, as the start: nothing to undo.
@MainActor private func forget(_ rig: Rig) { rig.h.editor.replaceDocument(with: rig.h.editor.document) }

@MainActor let cardTests = Suite("Cards", [
    test("a card shows and the host is told once; shown again, told again; another replaces it, which hears .replaced; closeCard() is .asked, heard once") {
        let rig = try Rig()
        let editor = rig.h.editor
        expect(editor.card == nil)
        expect(editor.showCard(rig.card("a", about: rig.box)))
        expectEqual(rig.name, "a")
        expectEqual(rig.host.tells, 1)
        expectEqual(editor.card?.anchor, anchor)
        expect(editor.card?.view === rig.probe)
        expect(editor.showCard(rig.card("a", about: rig.box)))
        expectEqual(rig.host.tells, 2, "told again")
        expectEqual(rig.log.closings, [.replaced], "the one it replaced, though the same")
        expect(editor.showCard(rig.card("b")))
        expectEqual(rig.name, "b")
        expectEqual(rig.log.closings, [.replaced, .replaced])
        expectEqual(rig.host.tells, 3, "a replacement is one telling")
        editor.closeCard()
        expectEqual(rig.log.closings, [.replaced, .replaced, .asked])
        expectEqual(rig.host.tells, 4)
        expect(editor.card == nil)
        editor.closeCard()
        expectEqual(rig.host.tells, 4, "none showing: nobody is told")
        expectEqual(rig.log.closings.count, 3)
    },
    test("a card about a shape that is not on the board shown, or is drawn as a skeleton, or with no shape while skeletons are drawn, is refused; one about the shape being edited shows at 20%") {
        let rig = try Rig()
        let editor = rig.h.editor
        expect(!editor.showCard(rig.card("gone", about: ShapeID())), "not on the board")
        rig.host.tells = 0
        rig.h.enter(rig.pocket)
        expect(!editor.showCard(rig.card("other board", about: rig.box)), "on another board")
        editor.showBoard(.root)
        editor.camera.setZoom(0.2, around: .zero)
        expect(editor.drawsSkeletons)
        expect(!editor.showCard(rig.card("skeleton", about: rig.box)), "drawn as a skeleton")
        expect(!editor.showCard(rig.card("nothing")), "no shape, while skeletons are drawn")
        expectEqual(rig.host.tells, 0, "refused: nobody told")
        expect(editor.card == nil)
        expect(editor.beginEditing(rig.note))
        expect(editor.showCard(rig.card("edited", about: rig.note)), "drawn in full under its editing view")
        expectEqual(rig.name, "edited")
        editor.camera.setZoom(0.1, around: .zero)
        expectEqual(rig.name, "edited", "and stays at any zoom while it's edited")
        editor.camera.setZoom(1, around: .zero)
        editor.endEditing()
        expect(editor.showCard(rig.card("again")))
        expect(!editor.showCard(rig.card("refused", about: ShapeID())))
        expectEqual(rig.name, "again", "a refusal leaves the card showing as it is")
    },
    test("it closes, each with its reason: a press off its anchor, a pan press, editing beginning and ending, a board shown, a file put in place") {
        // Each: what's so before it, and what happens; the card is about the first note.
        let cases: [(String, CanvasCardClosing, Bool, @MainActor (Rig) -> Void)] = [
            ("a press", .pressedElsewhere, false, { $0.h.press(at: CGPoint(x: 700, y: 500)); $0.h.release() }),
            ("a pan press", .pressedElsewhere, false, { $0.h.editor.isHandHeld = true; $0.h.press(at: CGPoint(x: 700, y: 500)); $0.h.release() }),
            ("editing another shape", .editing, false, { $0.h.editor.beginEditing($0.other) }),
            ("editing its own shape", .editing, false, { $0.h.editor.beginEditing($0.note) }),
            ("a board shown", .board, false, { $0.h.enter($0.pocket) }),
            ("a file put in place", .board, false, { $0.h.editor.replaceFile(with: $0.h.file) }),
            ("editing ending", .editing, true, { $0.h.editor.endEditing() }),
            ("a board shown from the note being edited", .editing, true, { $0.h.enter($0.pocket) }),
            ("undo", .undo, false, { $0.h.editor.undo() }),
            ("undo while editing", .undo, true, { $0.h.editor.undo() }),
            ("redo", .undo, false, { $0.h.editor.redo() }),
        ]
        for (going, reason, editing, happen) in cases {
            let rig = try Rig()
            // Something to undo and redo.
            rig.nudge(nil, "Nudge")
            if going == "redo" { rig.h.editor.undo() }
            if editing { expect(rig.h.editor.beginEditing(rig.note), going) }
            expect(rig.show(about: rig.note), going)
            rig.log.closings = []
            happen(rig)
            expectEqual(rig.log.closings, [reason], going)
            expect(rig.h.editor.card == nil, going)
            expectEqual(rig.host.order.suffix(2), ["told", "closed"], "\(going): the host first, then the plugin")
        }
    },
    test("it closes as the zoom crosses the skeleton level for a shape not edited, and as skeletonZoom moves past the zoom") {
        let rig = try Rig()
        let editor = rig.h.editor
        rig.show(about: rig.box)
        editor.camera.setZoom(0.36, around: .zero)
        expectEqual(rig.name, "c", "above 35%")
        editor.camera.setZoom(0.3, around: .zero)
        expectEqual(rig.log.closings, [.skeleton])
        editor.camera.setZoom(1, around: .zero)
        rig.show(about: rig.box)
        editor.skeletonZoom = 2
        expectEqual(rig.log.closings, [.skeleton, .skeleton])
        editor.skeletonZoom = 0.35
        editor.camera.setZoom(1, around: .zero)
        expect(editor.card == nil)
        rig.show()
        editor.camera.setZoom(0.3, around: .zero)
        expectEqual(rig.log.closings.last, .skeleton, "a card with no shape, as the skeletons come")
    },
    test("a card closes as its shape is deleted, and the delete's step is left whole; its own commit that deletes it too") {
        let rig = try Rig()
        let editor = rig.h.editor
        forget(rig)
        rig.show(about: rig.box, step: "Card")
        rig.nudge("c")
        expectEqual(rig.boxX, 401)
        editor.transact("Delete") { $0.delete([rig.box]) }
        expectEqual(rig.log.closings, [.shapeGone])
        expect(editor.document[rig.box] == nil)
        editor.undo()
        expectEqual(rig.boxX, 401, "the delete alone is undone, with the card's step before it")
        editor.undo()
        expectEqual(rig.boxX, 400)
        // The card's own commit.
        editor.redo(); editor.redo()
        rig.show(about: rig.other, step: "Card")
        rig.log.closings = []
        editor.transact(nil, coalescing: "c") { $0.delete([rig.other]) }
        expectEqual(rig.log.closings, [.shapeGone])
        expect(editor.document[rig.other] == nil)
        expectEqual(editor.undoHistory.undoName, "Card")
        editor.undo()
        expect(editor.document[rig.other] != nil, "one undo brings the shape back")
    },
    test("a card closes as its anchor is panned out of the view, or moved there; an empty viewport closes nothing") {
        let rig = try Rig()
        let editor = rig.h.editor
        rig.show(about: rig.box)
        editor.camera.pan(by: CGSize(width: -5000, height: 0))
        expectEqual(rig.name, "c", "no viewport: nothing to leave")
        editor.camera = Camera()
        editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        editor.camera.pan(by: CGSize(width: -50, height: -20))
        editor.camera.setZoom(0.5, around: .zero)
        expectEqual(rig.name, "c", "a pan and a zoom that keep it in view")
        editor.camera.pan(by: CGSize(width: -5000, height: 0))
        expectEqual(rig.log.closings, [.leftView])
        editor.camera = Camera()
        rig.show(about: rig.box)
        editor.moveCard(to: CGRect(x: 5000, y: 5000, width: 10, height: 10))
        expectEqual(rig.log.closings, [.leftView, .leftView])
        expect(editor.card == nil)
        rig.show(about: rig.box)
        editor.viewportDidResize(to: CGSize(width: 90, height: 90))
        expectEqual(rig.log.closings.last, .leftView, "the view shrinking past it")
    },
    test("a card stays: a press and a pan press on its anchor, a refused beginEditing, a commit, a hover popover") {
        let rig = try Rig()
        let editor = rig.h.editor
        editor.freeze([rig.note])
        rig.show(about: rig.note)
        rig.h.press(at: CGPoint(x: 110, y: 110)); rig.h.release()
        editor.isHandHeld = true
        rig.h.press(at: CGPoint(x: 110, y: 110)); rig.h.release()
        editor.isHandHeld = false
        expect(!editor.beginEditing(rig.note), "a read-only shape")
        rig.nudge()
        editor.transact { $0.update(rig.box, as: Box.self) { $0.frame.size.width = 50 } }
        editor.hoverPopover(CanvasPopover(id: "p", anchor: CGRect(x: 0, y: 0, width: 10, height: 10), text: NSAttributedString(string: "p")))
        rig.h.wait(600)
        expect(editor.popover != nil)
        editor.hoverPopover(nil)
        expectEqual(rig.name, "c")
        expectEqual(rig.log.closings, [])
    },
    test("moveCard tells the host with the new anchor and nothing for the same one; cardDidResize tells the host") {
        let rig = try Rig()
        let editor = rig.h.editor
        let moved = anchor.offsetBy(dx: 0, dy: 30)
        rig.show()
        editor.moveCard(to: anchor)
        expectEqual(rig.host.tells, 0)
        editor.moveCard(to: moved)
        expectEqual(rig.host.tells, 1)
        expectEqual(rig.host.anchors, [moved])
        expectEqual(editor.card?.anchor, moved)
        editor.cardDidResize()
        expectEqual(rig.host.tells, 2)
        editor.closeCard()
        rig.host.tells = 0
        editor.moveCard(to: moved)
        editor.cardDidResize()
        expectEqual(rig.host.tells, 0, "none showing")
    },
    test("commits under the card's key are one step, named by the card, from showing to closing: seal() doesn't end it, and one undo puts them all back and closes the card") {
        let rig = try Rig()
        let editor = rig.h.editor
        forget(rig)
        rig.show(step: "Change Tags")
        rig.nudge("c"); rig.nudge("c", "Not this name"); editor.undoHistory.seal(); rig.nudge("c")
        expectEqual(rig.boxX, 403)
        expectEqual(editor.undoHistory.undoName, "Change Tags", "while it's open")
        expect(editor.canUndo)
        editor.undo()
        expectEqual(rig.boxX, 400)
        expect(!editor.canUndo, "one step")
        expectEqual(rig.log.closings, [.undo])
        editor.redo()
        expectEqual(rig.boxX, 403, "and one redo puts them back")
        expectEqual(editor.undoHistory.undoName, "Change Tags")
    },
    test("a commit from elsewhere ends the card's step and is a step of its own; the card's next commit is another by the same name") {
        let others: [(String, @MainActor (Rig) -> Void)] = [
            ("no key", { $0.nudge(nil, "Other") }),
            ("another key", { $0.nudge("x", "Other") }),
        ]
        for (kind, other) in others {
            let rig = try Rig()
            let editor = rig.h.editor
            forget(rig)
            rig.show(step: "Card")
            rig.nudge("c")
            other(rig)
            rig.nudge("c")
            expectEqual(editor.undoHistory.undoName, "Card", kind)
            editor.undo()
            expectEqual(rig.boxX, 402, kind)
            editor.redo()
            expectEqual(rig.boxX, 403, kind)
            editor.undo()
            expectEqual(editor.undoHistory.undoName, "Other", kind)
            editor.undo()
            expectEqual(editor.undoHistory.undoName, "Card", kind)
            editor.undo()
            expectEqual(rig.boxX, 400, "\(kind): three steps in all")
            expect(!editor.canUndo, kind)
        }
    },
    test("closing the card closes its step: the next keyed commit is an ordinary run that seal() ends; a card with no step name holds nothing") {
        let rig = try Rig()
        let editor = rig.h.editor
        forget(rig)
        rig.show(step: "Card")
        rig.nudge("c")
        editor.closeCard()
        rig.nudge("k"); rig.nudge("k"); editor.undoHistory.seal(); rig.nudge("k")
        editor.undo()
        expectEqual(rig.boxX, 403, "an ordinary run, ended by seal()")
        editor.undo()
        expectEqual(rig.boxX, 401, "the run before it")
        editor.undo()
        expectEqual(rig.boxX, 400, "and the card's")
        // No step name.
        rig.show()
        rig.nudge("c"); editor.undoHistory.seal(); rig.nudge("c")
        editor.undo()
        expectEqual(rig.boxX, 401, "a run, not a kept step: seal() ended it")
    },
    test("setCardStep changes the step the card holds: a new name or none closes the one held; commits that come to nothing leave no step; breakStep splits the step") {
        let rig = try Rig()
        let editor = rig.h.editor
        forget(rig)
        rig.show(step: "A")
        rig.nudge("c")
        editor.setCardStep("B")
        expectEqual(editor.card?.stepName, "B")
        rig.nudge("c")
        expectEqual(editor.undoHistory.undoName, "B")
        editor.undo()
        expectEqual(rig.boxX, 401)
        expectEqual(editor.undoHistory.undoName, "A", "two steps")
        editor.undo()
        // None.
        rig.show(step: "A")
        rig.nudge("c")
        editor.setCardStep(nil)
        expectEqual(editor.card?.stepName, nil)
        rig.nudge("c"); editor.undoHistory.seal(); rig.nudge("c")
        editor.undo()
        expectEqual(rig.boxX, 402, "an ordinary run now")
        editor.undo(); editor.undo()
        expectEqual(rig.boxX, 400)
        // Nothing came of it.
        forget(rig)
        rig.show(step: "A")
        rig.nudge("c")
        editor.transact(nil, coalescing: "c") { $0.update(rig.box, as: Box.self) { $0.frame.origin.x = 400 } }
        expect(!editor.canUndo, "back where it began")
        expectEqual(editor.undoHistory.undoName, nil)
        // A save point.
        rig.nudge("c")
        editor.undoHistory.breakStep()
        rig.nudge("c")
        editor.undo()
        expectEqual(rig.boxX, 401)
        editor.undo()
        expectEqual(rig.boxX, 400)
    },
    test("a keyed commit inside a group is the group's step and not the card's; a card shown inside a press holds its step for what follows the release") {
        let rig = try Rig()
        let editor = rig.h.editor
        forget(rig)
        rig.show(step: "Card")
        editor.undoHistory.group("G") { rig.nudge("c") }
        rig.nudge("c")
        expectEqual(editor.undoHistory.undoName, "Card")
        editor.undo()
        expectEqual(editor.undoHistory.undoName, "G")
        editor.undo()
        expectEqual(rig.boxX, 400)
        // Shown in a press.
        let fresh = try Rig()
        let e = fresh.h.editor
        forget(fresh)
        fresh.h.press(at: CGPoint(x: 700, y: 500))
        expect(e.showCard(fresh.card("c", step: "Card")))
        fresh.h.release()
        fresh.nudge("c"); e.undoHistory.seal(); fresh.nudge("c")
        expectEqual(e.undoHistory.undoName, "Card")
        e.undo()
        expectEqual(fresh.boxX, 400, "one step")
        expect(!e.canUndo)
        // A commit on another board doesn't end it.
        let third = try Rig()
        let t = third.h.editor
        forget(third)
        third.show(step: "Card")
        third.nudge("c")
        t.transact(on: BoardID(owner: third.pocket), "Elsewhere") { $0.insert(ShapeRecord(Box(CGRect(x: 1, y: 1, width: 2, height: 2)))) }
        third.nudge("c")
        expectEqual(t.undoHistory.undoName, "Card")
    },
    test("in an editing session: typing, then the card's commits, then typing are three steps") {
        let rig = try Rig()
        let editor = rig.h.editor
        forget(rig)
        expect(editor.beginEditing(rig.note))
        let field = try require(editor.makeEditingView()?.view as? CardField)
        field.context.update { $0.text = "a" }
        expect(editor.showCard(rig.card("c", about: rig.note, step: "Card")))
        rig.nudge("c"); rig.nudge("c")
        field.context.update { $0.text = "ab" }
        expectEqual(editor.undoHistory.undoName, "Typing")
        editor.endEditing(discarding: false)
        expect(editor.card == nil, "editing ended")
        editor.undo()
        expectEqual(editor.document[rig.note]?.typed(as: Card.self)?.props.text, "a")
        expectEqual(editor.undoHistory.undoName, "Card")
        editor.undo()
        expectEqual(rig.boxX, 400)
        expectEqual(editor.undoHistory.undoName, "Typing")
        editor.undo()
        expectEqual(editor.document[rig.note]?.typed(as: Card.self)?.props.text, "")
    },
])
