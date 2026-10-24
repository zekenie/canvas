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

    func card(_ id: String = "c", about shape: ShapeID? = nil, at rect: CGRect = anchor, step: String? = nil,
              adoptsPress: Bool = false, zoomedOut: Bool = false) -> CanvasCard {
        probeCard(id, about: shape, anchor: rect, stepName: step, adoptsPress: adoptsPress, showsZoomedOut: zoomedOut, probe: probe, closings: log)
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
    test("a card that shows zoomed out shows among skeletons, about no shape and about a shape drawn as one; a card that doesn't is refused there; a shape not on the board refuses either") {
        let rig = try Rig()
        let editor = rig.h.editor
        editor.camera.setZoom(0.2, around: .zero)
        expect(editor.drawsSkeletons)
        expect(!editor.showCard(rig.card("plain", about: rig.box)), "about what a shape draws: refused")
        expect(!editor.showCard(rig.card("plain")), "and with no shape")
        expect(editor.showCard(rig.card("bar", zoomedOut: true)), "about no shape")
        expectEqual(rig.name, "bar")
        expect(editor.showCard(rig.card("bar on box", about: rig.box, zoomedOut: true)), "about a shape drawn as a skeleton")
        expectEqual(rig.name, "bar on box")
        expect(!editor.showCard(rig.card("gone", about: ShapeID(), zoomedOut: true)), "not on the board shown")
        expectEqual(rig.name, "bar on box", "a refusal leaves the card showing as it is")
    },
    test("shown in full, a card that shows zoomed out stays as the zoom crosses the skeleton level and as skeletonZoom moves past it, where one that doesn't closes") {
        let rig = try Rig()
        let editor = rig.h.editor
        expect(editor.showCard(rig.card("bar", about: rig.box, zoomedOut: true)))
        editor.camera.setZoom(0.3, around: .zero)
        editor.camera.setZoom(0.05, around: .zero)
        editor.skeletonZoom = 2
        expectEqual(rig.log.closings, [], "never .skeleton")
        expectEqual(rig.name, "bar")
        editor.skeletonZoom = 0.35
        editor.camera.setZoom(1, around: .zero)
        expect(editor.showCard(rig.card("none", zoomedOut: true)))
        editor.camera.setZoom(0.1, around: .zero)
        expectEqual(rig.name, "none", "with no shape either")
        editor.camera.setZoom(1, around: .zero)
        expect(editor.showCard(rig.card("plain", about: rig.box)))
        editor.camera.setZoom(0.3, around: .zero)
        expectEqual(rig.log.closings.last, .skeleton, "a card about what a shape draws closes as it did")
    },
    test("zoomed out, a card that shows there still closes as any card does: a press elsewhere, another board, an undo, its anchor out of the view") {
        let cases: [(String, CanvasCardClosing, @MainActor (Rig) -> Void)] = [
            ("a press", .pressedElsewhere, { $0.h.press(at: CGPoint(x: 700, y: 500)); $0.h.release() }),
            ("a board shown", .board, { $0.h.enter($0.pocket) }),
            ("undo", .undo, { $0.h.editor.undo() }),
            ("its anchor out of the view", .leftView, { $0.h.editor.camera.pan(by: CGSize(width: -50000, height: 0)) }),
        ]
        for (going, reason, happen) in cases {
            let rig = try Rig()
            rig.nudge(nil, "Nudge")
            rig.h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
            rig.h.editor.camera.setZoom(0.2, around: .zero)
            expect(rig.h.editor.drawsSkeletons, going)
            expect(rig.h.editor.showCard(rig.card("bar", about: rig.box, zoomedOut: true)), going)
            happen(rig)
            expectEqual(rig.log.closings, [reason], going)
            expect(rig.h.editor.card == nil, going)
        }
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
    test("a card's anchor is judged where the camera is headed: one opened on a shape the camera glides to stays, one the glide leaves behind closes") {
        let rig = try Rig()
        let editor = rig.h.editor
        editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        rig.show(about: rig.box)
        var there = Camera()
        there.origin = CGPoint(x: 5000, y: 0)
        editor.animateCamera(to: there, duration: .milliseconds(200))
        editor.moveCard(to: CGRect(x: 5100, y: 100, width: 10, height: 10))
        expect(editor.card != nil, "off the view now, in it where the camera is headed")
        editor.moveCard(to: CGRect(x: 100, y: 100, width: 10, height: 10))
        expectEqual(rig.log.closings, [.leftView], "in the view now, out of it where the camera is headed")
    },
    test("through every frame of a glide a card is judged where the camera is headed: one on a shape the glide brings into view stays to the end, one it leaves behind closes") {
        let rig = try Rig()
        let editor = rig.h.editor
        editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        let far = CGRect(x: 5100, y: 100, width: 10, height: 10)
        var there = Camera()
        there.origin = CGPoint(x: 5000, y: 0)
        editor.animateCamera(to: there, duration: .milliseconds(200))
        expect(editor.showCard(rig.card("far", at: far)))
        rig.h.wait(100)
        expect(editor.camera.origin.x > 0 && editor.camera.origin.x < 5000, "mid-glide")
        expectEqual(rig.name, "far", "its frames judge the card where the camera is headed")
        rig.h.wait(200)
        expectEqual(editor.camera, there)
        expectEqual(rig.name, "far", "and so does the last")
        expectEqual(rig.log.closings, [])
        editor.animateCamera(to: Camera(), duration: .milliseconds(200))
        rig.h.wait(16)
        expectEqual(rig.log.closings, [.leftView], "a glide away closes it as it begins")
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
    test("a delete on a board that isn't shown, under the card's key, is in the card's step: one undo puts it and the card's other commits back") {
        let rig = try Rig()
        let e = rig.h.editor, pocketBoard = BoardID(owner: rig.pocket)
        e.undoHistory.clear()
        let before = rig.h.file
        let inside = try require(before[pocketBoard].shapes.first?.id)
        rig.show(step: "Card")
        rig.nudge("c")
        e.transact("Remove", coalescing: "c") { $0.delete([inside], on: pocketBoard) }
        expect(rig.h.file.record(inside) == nil)
        rig.nudge("c")
        expectEqual(e.undoHistory.undoName, "Card")
        e.undo()
        expectEqual(rig.h.file, before, "one step")
        expect(!e.canUndo)
        e.redo()
        expect(rig.h.file.record(inside) == nil)
        expectEqual(rig.boxX, 402)
    },
    test("a step recorded on a board the card's step holds closes the card's first: undo, undo, redo, redo are each exact") {
        let rig = try Rig()
        let e = rig.h.editor, pocketBoard = BoardID(owner: rig.pocket)
        e.undoHistory.clear()
        let s0 = rig.h.file
        let inside = try require(s0[pocketBoard].shapes.first?.id)
        @MainActor func slide(_ tx: inout Transaction, by dx: CGFloat) { tx.update(inside, on: pocketBoard, as: Box.self) { $0.props.frame.origin.x += dx } }
        rig.show(step: "Card")
        // The card's step reaches the pocket's board, which it then holds whole.
        e.transact("Card", coalescing: "c") { slide(&$0, by: 5) }
        let s1 = rig.h.file
        e.transact(on: pocketBoard, "Elsewhere") { slide(&$0, by: 7) }
        let s2 = rig.h.file
        e.closeCard()
        expect(s0 != s1 && s1 != s2)
        e.undo()
        expectEqual(rig.h.file, s1, "the step on the board is undone alone")
        expectEqual(e.board, pocketBoard, "and shows its board")
        e.undo()
        expectEqual(rig.h.file, s0, "then the card's")
        expectEqual(e.board, .root)
        expect(!e.canUndo)
        e.redo()
        expectEqual(rig.h.file, s1)
        e.redo()
        expectEqual(rig.h.file, s2)
        expect(!e.canRedo)
    },
    test("a step recorded on another board that changes, takes or adds a third board the card's step holds closes the card's first: undo, undo, redo, redo are each exact") {
        let m = ShapeID(), pocketP = ShapeID(), pocketW = ShapeID(), pocketQ = ShapeID(), d = ShapeID(), d2 = ShapeID(), c = ShapeID()
        func shape(_ id: ShapeID, _ x: CGFloat) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Box(CGRect(x: x, y: 0, width: 40, height: 30)))) }
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: pocketP, Pocket(CGRect(x: 0, y: 0, width: 100, height: 100)))),
                                                            AnyShapeRecord(ShapeRecord(id: pocketW, Pocket(CGRect(x: 200, y: 0, width: 100, height: 100))))]),
                              children: [pocketP: CanvasDocument(shapes: [shape(m, 0), AnyShapeRecord(ShapeRecord(id: pocketQ, Pocket(CGRect(x: 100, y: 0, width: 100, height: 100))))]),
                                         pocketW: CanvasDocument(shapes: [shape(d, 0), shape(d2, 100)]), pocketQ: CanvasDocument(shapes: [shape(c, 0)])])
        let p = BoardID(owner: pocketP), w = BoardID(owner: pocketW), q = BoardID(owner: pocketQ)
        // The card's step reaches W and Q (a write on each), so holds them whole. A step on P then changes
        // W too, by a write or by a delete, or takes Q with the pocket that owns it.
        let steps: [(String, @MainActor (CanvasEditor) -> Void)] = [
            ("a write", { e in
                e.transact(on: p, "Elsewhere") { tx in
                    tx.update(m, as: Box.self) { $0.props.frame.origin.x = 9 }
                    tx.update(d2, on: w, as: Box.self) { $0.props.frame.origin.x = 77 }
                }
            }),
            ("a delete", { e in e.transact(on: p, "Elsewhere") { $0.delete([d2], on: w) } }),
            ("the owner taken", { e in e.transact(on: p, "Elsewhere") { $0.delete([pocketQ]) } }),
        ]
        for (what, elsewhere) in steps {
            let h = try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin(), FreezingPlugin()], file: file)
            let e = h.editor
            let s0 = h.file
            e.transact("Card", coalescing: "c") { tx in
                tx.update(d, on: w, as: Box.self) { $0.props.frame.origin.x = 5 }
                tx.update(c, on: q, as: Box.self) { $0.props.frame.origin.x = 6 }
            }
            let s1 = h.file
            elsewhere(e)
            let s2 = h.file
            e.undoHistory.seal()
            expect(s0 != s1 && s1 != s2, "\(what): each step changed the file")
            e.undo()
            expectEqual(h.file, s1, "\(what): the step on the board is undone alone")
            e.undo()
            expectEqual(h.file, s0, "\(what): then the card's")
            expect(!e.canUndo)
            e.redo()
            expectEqual(h.file, s1, "\(what): redone")
            e.redo()
            expectEqual(h.file, s2, "\(what): and the other")
            let codec = BoardCodec(registry: e.registry)
            expectEqual(try codec.encode(h.file), try codec.encode(s2), "\(what): as a file")
        }
    },
    test("a card that adopts the press it is shown in: the press's changes and the card's are one step, open past the release, named for the press, and one Undo after the card closes takes back both") {
        let rig = try Rig()
        let e = rig.h.editor
        forget(rig)
        rig.h.press(at: CGPoint(x: 700, y: 500))
        rig.nudge(nil, "Press")
        expect(e.showCard(rig.card("c", step: "Card", adoptsPress: true)))
        rig.nudge(nil, "Also the press")
        rig.h.release()
        expectEqual(rig.boxX, 402)
        expect(e.card != nil, "the card stays")
        expectEqual(e.undoHistory.undoName, "Press", "the step is open, and it is the press's")
        rig.nudge("c"); e.undoHistory.seal(); rig.nudge("c")
        expectEqual(rig.boxX, 404)
        expectEqual(e.undoHistory.undoName, "Press", "the card's commits joined it, whatever its step name")
        e.closeCard()
        expectEqual(rig.log.closings, [.asked])
        e.undo()
        expectEqual(rig.boxX, 400, "one Undo takes back the press's changes and the card's")
        expect(!e.canUndo, "and there was no other step")
        e.redo()
        expectEqual(rig.boxX, 404, "one Redo puts all back")
        expectEqual(e.undoHistory.undoName, "Press")
        e.undo()
        expect(!e.canUndo)
        // Undo with the card up closes the card, and takes the same step.
        let second = try Rig()
        let s = second.h.editor
        forget(second)
        second.h.press(at: CGPoint(x: 700, y: 500))
        second.nudge(nil, "Press")
        expect(s.showCard(second.card("c", step: "Card", adoptsPress: true)))
        second.h.release()
        second.nudge("c")
        s.undo()
        expectEqual(second.boxX, 400)
        expectEqual(second.log.closings, [.undo])
        expect(!s.canUndo, "one step")
        // A group is an action too.
        let third = try Rig()
        let t = third.h.editor
        forget(third)
        t.undoHistory.group("Grouped") {
            third.nudge(nil, "Inner")
            expect(t.showCard(third.card("c", step: "Card", adoptsPress: true)))
        }
        third.nudge("c")
        expectEqual(t.undoHistory.undoName, "Grouped")
        t.closeCard()
        t.undo()
        expectEqual(third.boxX, 400)
        expect(!t.canUndo)
    },
    test("an adopted press's step splits as any kept step does: breakStep during the card, a commit from elsewhere, a new press; and the card's next commit is a step of its own by its name") {
        @MainActor func shown(_ rig: Rig) {
            rig.h.press(at: CGPoint(x: 700, y: 500))
            rig.nudge(nil, "Press")
            expect(rig.h.editor.showCard(rig.card("c", step: "Card", adoptsPress: true)))
            rig.h.release()
            rig.nudge("c")
        }
        // A save point.
        let rig = try Rig()
        let e = rig.h.editor
        forget(rig)
        shown(rig)
        e.undoHistory.breakStep()
        rig.nudge("c")
        expectEqual(e.undoHistory.undoName, "Card", "after the save the card's commits are a step of their own")
        e.closeCard()
        e.undo()
        expectEqual(rig.boxX, 402, "the card's step after the save")
        e.undo()
        expectEqual(rig.boxX, 400, "the press's, with its card commit, up to the save")
        expect(!e.canUndo)
        // A commit from elsewhere.
        let other = try Rig()
        let o = other.h.editor
        forget(other)
        shown(other)
        other.nudge(nil, "Elsewhere")
        other.nudge("c")
        o.closeCard()
        o.undo(); expectEqual(other.boxX, 403, "the card's again")
        o.undo(); expectEqual(other.boxX, 402, "elsewhere")
        o.undo(); expectEqual(other.boxX, 400, "the press, with the card's first commit")
        expect(!o.canUndo)
        // A new press closes the card and the step.
        let next = try Rig()
        let n = next.h.editor
        forget(next)
        shown(next)
        next.h.press(at: CGPoint(x: 700, y: 520))
        next.nudge(nil, "Next")
        next.h.release()
        expect(n.card == nil, "a press elsewhere closed the card")
        n.undo(); expectEqual(next.boxX, 402, "the next press's step is its own")
        n.undo(); expectEqual(next.boxX, 400)
        expect(!n.canUndo)
        // Nothing came of it: no step.
        let nothing = try Rig()
        let z = nothing.h.editor
        forget(nothing)
        nothing.h.press(at: CGPoint(x: 700, y: 500))
        expect(z.showCard(nothing.card("c", step: "Card", adoptsPress: true)))
        nothing.h.release()
        expect(!z.canUndo)
        nothing.nudge("c")
        expectEqual(z.undoHistory.undoName, "Card", "a card whose press changed nothing holds a step of its own")
        z.undo()
        expect(!z.canUndo)
    },
    test("a card that does not adopt the press, or is shown outside one, or is closed before the release, is as it was: the press's step closes at the release and the card's commits are another") {
        // Not adopting.
        let rig = try Rig()
        let e = rig.h.editor
        forget(rig)
        rig.h.press(at: CGPoint(x: 700, y: 500))
        rig.nudge(nil, "Press")
        expect(e.showCard(rig.card("c", step: "Card")))
        rig.h.release()
        rig.nudge("c")
        expectEqual(e.undoHistory.undoName, "Card")
        e.undo(); expectEqual(rig.boxX, 401)
        expectEqual(e.undoHistory.undoName, "Press")
        e.undo(); expectEqual(rig.boxX, 400)
        // Adopting, shown outside a press.
        let outside = try Rig()
        let o = outside.h.editor
        forget(outside)
        outside.nudge(nil, "Before")
        expect(o.showCard(outside.card("c", step: "Card", adoptsPress: true)))
        outside.nudge("c"); outside.nudge("c")
        o.undo(); expectEqual(outside.boxX, 401, "the card's step, apart from the commit before it")
        expectEqual(o.undoHistory.undoName, "Before")
        o.undo(); expectEqual(outside.boxX, 400)
        expect(!o.canUndo)
        // Closed before the release.
        let early = try Rig()
        let c = early.h.editor
        forget(early)
        early.h.press(at: CGPoint(x: 700, y: 500))
        early.nudge(nil, "Press")
        expect(c.showCard(early.card("c", step: "Card", adoptsPress: true)))
        c.closeCard()
        early.h.release()
        early.nudge("c"); early.nudge(nil, "Later")
        expectEqual(c.undoHistory.undoName, "Later")
        c.undo(); expectEqual(early.boxX, 402)
        c.undo(); expectEqual(early.boxX, 401, "the run the closed card's key made")
        c.undo(); expectEqual(early.boxX, 400, "the press's step closed at the release")
        expect(!c.canUndo)
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
