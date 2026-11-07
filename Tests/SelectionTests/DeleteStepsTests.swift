@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Keyboard
import Selection
import TestKit

// Delete says what went: the step is named for the shapes asked for and what went along with them ("Delete Ledger and 2
// links", with the kind names the registry gives), and is plain "Delete" when nothing did. CanvasTesting's ledgers take their
// links (`TakesBoundShapes`); a box's links let go. The Undo item's own title is CompositionTests'.

private let frame = CGRect(x: 0, y: 0, width: 40, height: 30)

/// Ledgers L and M, a box B, links K1 (L to B), K2 (M to L), K3 (B to M) and K4 (L to L), a lone ledger N, with a link
/// K5 locked (L to N): all in a root, with the selection's keys and Selection.
@MainActor private struct Rig {
    let h: EditorHarness
    let l = ShapeID(), m = ShapeID(), b = ShapeID(), n = ShapeID()
    let k1 = ShapeID(), k2 = ShapeID(), k3 = ShapeID(), k4 = ShapeID(), k5 = ShapeID()

    init(locked: Bool = false) throws {
        h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), LinksPlugin(), LedgersPlugin(), FreezingPlugin()])
        for (id, x) in [(l, 0), (m, 100)] as [(ShapeID, CGFloat)] { h.add(Ledger(CGRect(x: x, y: 0, width: 40, height: 30)), id: id) }
        h.add(Box(CGRect(x: 200, y: 0, width: 40, height: 30)), id: b)
        h.add(Ledger(CGRect(x: 300, y: 0, width: 40, height: 30)), id: n)
        h.add(Link(from: l, to: b), id: k1)
        h.add(Link(from: m, to: l), id: k2)
        h.add(Link(from: b, to: m), id: k3)
        h.add(Link(from: l, to: l), id: k4)
        h.add(Link(from: l, to: n), id: k5)
        if locked { h.editor.freeze([k5]) }
        h.editor.replaceDocument(with: h.editor.document)       // nothing to undo
    }

    var editor: CanvasEditor { h.editor }

    func delete(_ ids: [ShapeID]) -> String? {
        editor.selectedShapeIDs = ids
        expect(h.key("\u{7f}"), "Delete is heard")
        return editor.undoHistory.undoName
    }
}

@MainActor let deleteStepsTests = Suite("Delete says what went", [
    test("a ledger deleted with the links bound to it: one step named for the ledger and the links that went with it, in the registry's words") {
        let r = try Rig()
        let before = r.editor.document
        expectEqual(r.delete([r.m]), "Delete Ledger and 2 links", "K2 and K3 are bound to M")
        expect(r.editor.document[r.k2] == nil && r.editor.document[r.k3] == nil)
        r.editor.undo()
        expectEqual(r.editor.document, before, "one Undo brings them all back")
        expect(!r.editor.canUndo)
    },
    test("a single link along is not pluralized, and a locked one that let go is not counted") {
        let r = try Rig(locked: true)
        // L takes K1, K2, K4 (L to L: once) and K5 (locked: let go, stays); N takes K5 (locked) too.
        expectEqual(r.delete([r.l]), "Delete Ledger and 3 links", "K1, K2 and K4; K5 is locked and stays")
        expect(r.editor.document[r.k5] != nil)
        expectEqual(r.editor.document[r.k5]?.typed(as: Link.self)?.props, Link(from: nil, to: r.n), "it let go of the ledger")
        r.editor.undo()
        expectEqual(r.delete([r.n]), "Delete", "N's only link is locked, so nothing went along")
    },
    test("several ledgers: the count of each kind, the kinds asked for first") {
        let r = try Rig()
        expectEqual(r.delete([r.l, r.m, r.b]), "Delete 2 Ledgers, box and 5 links", "K1 to K4, and K5 (L to N), which is bound to L")
    },
    test("nothing went along: plain Delete, for a box whose links let go, a ledger with no links, and a ledger with its links asked for") {
        let r = try Rig()
        expectEqual(r.delete([r.b]), "Delete", "a box takes nothing: its links let go")
        expect(r.editor.document[r.k1] != nil)
        r.editor.undo()
        expectEqual(r.delete([r.n, r.k5]), "Delete", "the link asked for is not along")
        r.editor.undo()
        expectEqual(r.delete([r.l, r.k1, r.k2, r.k4, r.k5]), "Delete", "all of its links asked for")
    },
    test("DeleteSteps.name: the verb, each kind once with its count, plural by the word's end; a kind in both counts once") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), LedgersPlugin(), LinksPlugin()])
        let registry = h.editor.registry
        let ledger = Ledger.kind, box = Box.kind, link = Link.kind
        expectEqual(DeleteSteps.name(asked: [ledger], along: [], in: registry), "Delete")
        expectEqual(DeleteSteps.name("Cut", asked: [ledger], along: [KindCount(kind: link, count: 3)], in: registry), "Cut Ledger and 3 links")
        expectEqual(DeleteSteps.name(asked: [ledger, ledger, box], along: [KindCount(kind: link, count: 1)], in: registry), "Delete 2 Ledgers, box and link")
        expectEqual(DeleteSteps.name(asked: [link], along: [KindCount(kind: link, count: 2)], in: registry), "Delete 3 links", "asked and along")
        expectEqual(DeleteSteps.plural("Entry"), "Entries")
        expectEqual(DeleteSteps.plural("Day"), "Days")
        expectEqual(DeleteSteps.plural("Box"), "Boxes")
        expectEqual(DeleteSteps.plural("Branch"), "Branches")
        expectEqual(DeleteSteps.plural("Arrow"), "Arrows")
        expectEqual(DeleteSteps.list(["A", "B", "C"]), "A, B and C")
    },
])
