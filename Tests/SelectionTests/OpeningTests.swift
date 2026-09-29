@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Keyboard
import Selection
import TestKit

// Opening a shape (`ShapeOpening`): a double-click, Return, Enter and ⌘↓ open the only selected
// shape, by its kind's opener (pockets here show their boards), else by editing an `Editable` one.

@MainActor let openingTests = Suite("Opening shapes", [
    test("a double-click on a shape whose kind opens opens it: a pocket shows its board, nothing selected there and nothing following the pointer, and the release does nothing") {
        let t = PocketBoards()
        let h = try pocketsHarness(t)
        h.click(at: t.pPoint)
        expectEqual(h.editor.selection, t.p)
        h.press(at: t.pPoint, clickCount: 2)
        expectEqual(h.editor.board, t.pBoard)
        expectEqual(h.editor.selectedShapeIDs, [])
        expect(h.editor.session == nil, "no press went on onto the board")
        h.drag(to: CGPoint(x: 300, y: 80))
        h.release()                                             // over B, where P was
        expectEqual(h.editor.selectedShapeIDs, [])
        expectEqual(h.editor.document[t.b]?.box, CGRect(x: 200, y: 0, width: 100, height: 100), "nothing moved")
        expectEqual(h.editor.document[t.p], nil)
    },
    test("a double-click on an editable kind still edits it, and one on a kind that neither opens nor edits does neither") {
        let t = PocketBoards()
        let h = try pocketsHarness(t)
        h.press(at: t.cPoint, clickCount: 2); h.release()
        expectEqual(h.editor.editingShapeID, t.c)
        expectEqual(h.editor.board, .root)
        h.press(at: t.aPoint, clickCount: 2); h.release()
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(h.editor.selection, t.a)
        expectEqual(h.editor.board, .root)
    },
    test("a double-click on empty canvas still places what claims it") {
        let t = PocketBoards()
        let h = try pocketsHarness(t, cards: doubleClickCards())
        h.press(at: CGPoint(x: 700, y: 300), clickCount: 2)
        h.release()
        let card = try require(h.editor.document.shapes.last)
        expectEqual(card.kind, Card.kind)
        expectEqual(h.editor.editingShapeID, card.id)
        expectEqual(h.editor.board, .root)
    },
    test("Return, Enter and ⌘↓ open the only selected shape: a pocket's board, a card's editing") {
        let t = PocketBoards()
        let h = try pocketsHarness(t)
        let keys: [(String, Modifiers)] = [("\r", []), ("\u{3}", []), ("\u{F701}", .command)]
        for (key, modifiers) in keys {
            h.editor.selection = t.p
            h.hold(modifiers)
            expect(h.key(key))
            h.hold([])
            expectEqual(h.editor.board, t.pBoard)
            h.editor.goBack()
            expectEqual(h.editor.board, .root)
            expectEqual(h.editor.selection, t.p)
        }
        h.editor.selection = t.c
        expect(h.key("\r"))
        expectEqual(h.editor.editingShapeID, t.c)
    },
    test("Return with nothing to open still takes the key, and does nothing; ⌘↓ passes, as Go › Open Selection is dimmed") {
        let t = PocketBoards()
        let h = try pocketsHarness(t)
        for selection in [[], [t.a], [t.p, t.c]] {
            h.editor.selectedShapeIDs = selection
            expect(h.key("\r"))
            expect(h.key("\u{3}"))
            h.hold(.command)
            expect(!h.key("\u{F701}"))
            h.hold([])
            expectEqual(h.editor.board, .root)
            expectEqual(h.editor.editingShapeID, nil)
            expectEqual(h.editor.selectedShapeIDs, selection)
        }
    },
    test("Open Selection can run only for one selected shape that opens, with nothing under way and nothing being edited") {
        let t = PocketBoards()
        let h = try pocketsHarness(t)
        expect(!h.editor.canPerform(.openSelection))
        h.editor.selection = t.a
        expect(!h.editor.canPerform(.openSelection), "a box neither opens nor edits")
        h.editor.selection = t.c
        expect(h.editor.canPerform(.openSelection))
        expect(h.editor.beginEditing(t.c))
        expect(!h.editor.canPerform(.openSelection), "not while it's being edited: ⌘↓ is the text's")
        h.editor.endEditing()
        h.editor.selectedShapeIDs = [t.p, t.c]
        expect(!h.editor.canPerform(.openSelection), "not several")
        h.editor.selection = t.p
        expect(h.editor.canPerform(.openSelection))
        h.press(at: t.pPoint)
        expect(!h.editor.canPerform(.openSelection), "not mid-press")
        expect(!h.editor.perform(.openSelection))
        h.release()
        expect(h.editor.perform(.openSelection))
        expectEqual(h.editor.board, t.pBoard)
    },
    test("what can be opened: a shape on the board shown whose kind opens or edits, a read-only one too, whose editing is refused, though opening a board isn't") {
        let t = PocketBoards(), log = RefusalLog()
        let h = try pocketsHarness(t, [FreezingPlugin(log: log)])
        expect(h.editor.canOpen(t.p))
        expect(h.editor.canOpen(t.c))
        expect(!h.editor.canOpen(t.a))
        expect(!h.editor.canOpen(t.b), "not on the board shown")
        expect(!h.editor.canOpen(ShapeID()))
        h.editor.freeze([t.c, t.p])
        expect(h.editor.canOpen(t.c))
        expect(!h.editor.open(t.c))
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(log.refusals, [[t.c]])
        expect(h.editor.open(t.p))
        expectEqual(h.editor.board, t.pBoard, "entering is going somewhere, not a change")
        expectEqual(log.refusals, [[t.c]])
        expect(h.editor.canOpen(t.q))
        expect(!h.editor.open(t.b))
    },
    test("one opener per kind; one for every kind is the fallback a kind's own overrides") {
        expectThrows(RegistryError.conflict(point: "ShapeOpening", key: "pocket", plugins: ["opening-pockets", "more"])) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), PocketsPlugin(), openingPockets(), Contributor(id: "more") { r in
                r.opens(Pocket.self, "Open Again") { _, _ in }
            }])
        }
        var opened: [ShapeID] = []
        let t = PocketBoards()
        let h = try pocketsHarness(t, [Contributor(id: "everything") { r in
            r.contribute(ShapeOpener(title: "Open") { id, _ in opened.append(id) }, to: ShapeOpening.self)
        }])
        expect(h.editor.open(t.a))
        expectEqual(opened, [t.a], "a box opens by the fallback")
        expect(h.editor.open(t.c))
        expectEqual(opened, [t.a, t.c], "so does a card, which isn't edited")
        expectEqual(h.editor.editingShapeID, nil)
        expect(h.editor.open(t.p))
        expectEqual(opened, [t.a, t.c], "a pocket by its own")
        expectEqual(h.editor.board, t.pBoard)
    },
])
