import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Clipboard
import ContextMenus
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TestKit

@MainActor let copyPasteTests = Suite("Copying and pasting", [
    test("⌘C then ⌘V: a copy on top with a new id, naming its original, selected in its place; the original stays") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        let box = h.add(Box(slot(0)))
        h.add(Disc(slot(1)))
        h.editor.selection = box
        expect(h.command("c"))
        let before = h.editor.document
        expect(h.command("v"))
        let copies = h.editor.shapes(since: before)
        expectEqual(copies.count, 1)
        let copy = try require(copies.first)
        expect(copy.id != box)
        expectEqual(copy.kind, Box.kind)
        expectEqual(copy.box, slot(0))
        expectEqual(copy.copiedFrom, box)
        expectEqual(h.editor.document.shapes.last?.id, copy.id, "on top")
        expectEqual(h.editor.selectedShapeIDs, [copy.id])
        expectEqual(h.editor.document[box]?.box, slot(0))
        expectEqual(h.editor.document[box]?.copiedFrom, nil)
    },
    test("copying leaves the board alone; pasting again makes another copy of the same shapes") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        let box = h.add(Box(slot(0)))
        h.editor.selection = box
        let revision = h.editor.revision
        h.editor.copySelection()
        expectEqual(h.editor.revision, revision)
        let before = h.editor.document
        h.editor.paste()
        h.editor.paste()
        let copies = h.editor.shapes(since: before)
        expectEqual(copies.count, 2)
        expectEqual(copies.map(\.copiedFrom), [box, box])
        expectEqual(Set(copies.map(\.id)).count, 2)
        expectEqual(h.editor.selectedShapeIDs, [copies[1].id], "the last paste is selected")
    },
    test("a copy of a copy names the copy it was made from") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        let box = h.add(Box(slot(0)))
        h.editor.selection = box
        h.editor.copySelection()
        h.editor.paste()
        let first = try require(h.editor.selection)
        h.editor.copySelection()
        h.editor.paste()
        let second = try require(h.editor.selection)
        expectEqual(h.editor.document[first]?.copiedFrom, box)
        expectEqual(h.editor.document[second]?.copiedFrom, first)
    },
    test("several shapes paste back to front, as they were stacked, whatever order they were selected in") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        let back = h.add(Box(slot(0)))
        let front = h.add(Disc(slot(1)))
        h.editor.selectedShapeIDs = [front, back]
        expectEqual(h.editor.copy(h.editor.selectedShapeIDs), [back, front])
        let before = h.editor.document
        h.editor.paste()
        let copies = h.editor.shapes(since: before)
        expectEqual(copies.map(\.copiedFrom), [back, front])
        expectEqual(copies.map(\.box), [slot(0), slot(1)])
        expectEqual(h.editor.selectedShapeIDs, copies.map(\.id))
    },
    test("⌘X copies and deletes; ⌘V puts the same shapes back, under their ids, selected; ⌘V again pastes copies of them") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        let box = h.add(Box(slot(0)))
        let disc = h.add(Disc(slot(1)))
        h.editor.selectedShapeIDs = [box, disc]
        let revision = h.editor.revision
        expect(h.command("x"))
        expectEqual(h.editor.document.shapes.count, 0)
        expectEqual(h.editor.revision, revision + 1, "one transaction")
        expectEqual(h.editor.selectedShapeIDs, [])
        expect(h.command("v"))
        let pasted = h.editor.document.shapes
        expectEqual(pasted.map(\.id), [box, disc])
        expectEqual(pasted.map(\.kind), [Box.kind, Disc.kind])
        expectEqual(pasted.map(\.box), [slot(0), slot(1)])
        expectEqual(pasted.map(\.copiedFrom), [nil, nil], "moved, not copied")
        expectEqual(h.editor.selectedShapeIDs, [box, disc])
        let before = h.editor.document
        expect(h.command("v"))
        let copies = h.editor.shapes(since: before)
        expectEqual(copies.map(\.copiedFrom), [box, disc], "their ids are the moved shapes' now")
        expectEqual(copies.map(\.box), [slot(0), slot(1)])
    },
    test("with nothing selected, ⌘C and ⌘X pass the key on, and the pasteboard keeps what it had") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        let box = h.add(Box(slot(0)))
        h.editor.selection = box
        h.editor.copySelection()
        h.editor.selection = nil
        expect(!h.editor.canPerform(.copy))
        expect(!h.command("c"))
        expect(!h.command("x"))
        expectEqual(h.editor.document.shapes.count, 1)
        expect(h.editor.canPaste)
    },
    test("mid-gesture, ⌘X and ⌘V do nothing; ⌘C still copies") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        let box = h.add(Box(slot(0)))
        h.press(at: middle(0))
        h.drag(to: CGPoint(x: 80, y: 60))
        expect(h.editor.session != nil)
        expect(h.editor.canPerform(.copy))
        expect(!h.editor.canPerform(.cut))
        expect(!h.command("x"))
        expect(h.command("c"))
        expect(!h.editor.canPaste)
        expect(!h.command("v"))
        h.release()
        expectEqual(h.editor.document.shapes.map(\.id), [box])
        expect(h.editor.canPaste)
    },
    test("paste ends editing first") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard, [CardsPlugin()])
        let box = h.add(Box(slot(0)))
        let card = h.add(Card(slot(1)))
        h.editor.selection = box
        h.editor.copySelection()
        expect(h.editor.beginEditing(card))
        h.editor.paste()
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(h.editor.document.shapes.count, 3)
    },
])

@MainActor let copyabilityTests = Suite("Copyability", [
    test("every kind is copyable unless it opts out: an uncopyable kind is left out of a copy, and stays when cut") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        let box = h.add(Box(slot(0)))
        let ticket = h.add(Ticket(frame: slot(1)))
        expect(h.editor.isCopyable(box))
        expect(!h.editor.isCopyable(ticket))
        h.editor.selectedShapeIDs = [box, ticket]
        expect(h.command("x"))
        expectEqual(h.editor.document.shapes.map(\.id), [ticket], "the ticket wasn't copied, so it isn't deleted")
        let before = h.editor.document
        h.editor.paste()
        expectEqual(h.editor.shapes(since: before).map(\.id), [box], "the box, moved back")
    },
    test("only uncopyable shapes selected: ⌘C and ⌘X pass the key on, and nothing changes") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        let ticket = h.add(Ticket(frame: slot(0)))
        h.editor.selection = ticket
        expect(!h.editor.canPerform(.copy))
        expect(!h.command("c"))
        expect(!h.command("x"))
        expect(!h.editor.canPaste)
        expectEqual(h.editor.document.shapes.map(\.id), [ticket])
    },
    test("copyable(when:) decides shape by shape: a sealed stamp isn't copied, an open one is") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        let open = h.add(Stamp(frame: slot(0)))
        let sealed = h.add(Stamp(frame: slot(1), isSealed: true))
        expect(h.editor.isCopyable(open))
        expect(!h.editor.isCopyable(sealed))
        expectEqual(h.editor.copy([open, sealed]), [open])
    },
    test("without the Clipboard plugin nothing is copyable") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        let box = h.add(Box(slot(0)))
        h.editor.selection = box
        expect(!h.editor.isCopyable(box))
        expect(!h.editor.canPerform(.copy))
        expectEqual(h.editor.copy([box]), [])
        expect(!h.command("c"))
    },
])

@MainActor let referenceTests = Suite("Shapes that name shapes", [
    test("copied with the shapes it names, a link names their copies") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        let a = h.add(Box(slot(0)))
        let b = h.add(Box(slot(1)))
        let link = h.add(Link(from: a, to: b))
        h.editor.selectedShapeIDs = [link, a, b]
        h.editor.copySelection()
        let before = h.editor.document
        h.editor.paste()
        let copies = h.editor.shapes(since: before)
        let byOriginal = Dictionary(uniqueKeysWithValues: copies.map { ($0.copiedFrom!, $0.id) })
        let pastedLink = try require(h.editor.document[byOriginal[link]!]?.typed(as: Link.self)?.props)
        expectEqual(pastedLink.from, byOriginal[a])
        expectEqual(pastedLink.to, byOriginal[b])
        expectEqual(h.editor.document[link]?.typed(as: Link.self)?.props, Link(from: a, to: b), "the original is untouched")
    },
    test("copied without a shape it names, a link lets go of that one; the original keeps it") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        let a = h.add(Box(slot(0)))
        let b = h.add(Box(slot(1)))
        let link = h.add(Link(from: a, to: b))
        h.editor.selectedShapeIDs = [link, a]
        h.editor.copySelection()
        let before = h.editor.document
        h.editor.paste()
        let copies = h.editor.shapes(since: before)
        let pastedBox = try require(copies.first { $0.kind == Box.kind })
        let pastedLink = try require(copies.first { $0.kind == Link.kind }?.typed(as: Link.self)?.props)
        expectEqual(pastedLink, Link(from: pastedBox.id, to: nil))
        expectEqual(h.editor.document[link]?.typed(as: Link.self)?.props, Link(from: a, to: b))
    },
    test("the pasteboard holds what copying let go of: a shape deleted after the copy doesn't matter") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        let a = h.add(Box(slot(0)))
        let link = h.add(Link(from: a, to: nil))
        h.editor.selection = link
        h.editor.copySelection()
        h.editor.transact { $0.delete([a]) }
        let before = h.editor.document
        h.editor.paste()
        expectEqual(h.editor.shapes(since: before).first?.typed(as: Link.self)?.props, Link(from: nil, to: nil))
    },
    test("copied without its shape, a tether ends where that shape was") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        let a = h.add(Box(slot(1)))
        h.editor.selection = h.add(Tether(to: a))
        h.editor.copySelection()
        let before = h.editor.document
        h.editor.paste()
        expectEqual(h.editor.shapes(since: before).first?.typed(as: Tether.self)?.props, Tether(to: nil, end: middle(1)))
    },
    test("a shape that can't do without one this board can't read is left out of a paste, and what can't do without it in turn") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let source = try harness(pasteboard, [CardsPlugin()])
        let target = try harness(pasteboard)
        let card = source.add(Card(slot(0)))
        let tether = source.add(Tether(to: card))
        let onTether = source.add(Tether(to: tether))
        let box = source.add(Box(slot(1)))
        source.editor.selectedShapeIDs = [card, tether, onTether, box]
        expectEqual(source.editor.copy(source.editor.selectedShapeIDs), [card, tether, onTether, box])
        expect(target.editor.canPaste)
        target.editor.paste()
        expectEqual(target.editor.document.shapes.map(\.kind), [Box.kind], "no tether ending at the origin")
    },
    test("a shape that can't do without one it can't find (kept aside by its board) isn't copied, and stays when cut") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let comet = ShapeID()
        let registry = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), ClipboardPlugin(pasteboard: pasteboard),
                                              FixturesPlugin(), KindsPlugin()])
        let json = #"{ "format" : 1, "schema" : {}, "shapes" : [ { "id" : "\#(comet)", "index" : "a0", "kind" : "comet", "props" : {} } ] }"#
        var shapes = try BoardCodec(registry: registry).decode(Data(json.utf8)).document.shapes
        let tether = AnyShapeRecord(ShapeRecord(Tether(to: comet)))
        let box = AnyShapeRecord(ShapeRecord(Box(slot(1))))
        shapes += [tether, box]
        let h = EditorHarness { CanvasEditor(registry: registry, document: CanvasDocument(shapes: shapes), scheduler: $0) }
        h.editor.selectedShapeIDs = [tether.id, box.id]
        h.editor.cutSelection()
        expectEqual(h.editor.document.shapes.map(\.id), [comet, tether.id])
        h.editor.paste()
        expectEqual(h.editor.document.shapes.map(\.id), [comet, tether.id, box.id], "the box, moved back")
    },
])

@MainActor let placementTests = Suite("Where a paste lands", [
    test("with any of its shapes in view, a paste lands where they were copied from") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        let near = h.add(Box(CGRect(x: 700, y: 500, width: 200, height: 200)))      // half in view
        let far = h.add(Box(CGRect(x: 3000, y: 3000, width: 100, height: 100)))
        h.editor.selectedShapeIDs = [near, far]
        h.editor.copySelection()
        let before = h.editor.document
        h.editor.paste()
        expectEqual(h.editor.shapes(since: before).map(\.box), [CGRect(x: 700, y: 500, width: 200, height: 200), CGRect(x: 3000, y: 3000, width: 100, height: 100)])
    },
    test("with none of them in view, a paste is centered in the view, the shapes keeping their places among themselves") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 200, y: 100, width: 100, height: 100)))
        h.editor.selectedShapeIDs = [a, b]
        h.editor.copySelection()
        h.editor.camera = Camera(origin: CGPoint(x: 5000, y: 5000), zoom: 2)       // shows 5000...5400 by 5000...5300
        let before = h.editor.document
        h.editor.paste()
        // The view's center is (5200, 5150); the two boxes' is (150, 100).
        expectEqual(h.editor.shapes(since: before).map(\.box), [CGRect(x: 5050, y: 5050, width: 100, height: 100),
                                                                CGRect(x: 5250, y: 5150, width: 100, height: 100)])
    },
    test("a centered paste moves every kind as dragging would: a link's shapes and all") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let link = h.add(Link(from: a, to: nil))
        h.editor.selectedShapeIDs = [a, link]
        h.editor.copySelection()
        h.editor.camera = Camera(origin: CGPoint(x: -2000, y: 0))
        let before = h.editor.document
        h.editor.paste()
        let copies = h.editor.shapes(since: before)
        expectEqual(copies.first?.box, CGRect(x: -1650, y: 250, width: 100, height: 100))
        expectEqual(copies.last?.typed(as: Link.self)?.props.from, copies.first?.id)
    },
])

@MainActor let pasteboardTests = Suite("The pasteboard", [
    test("anything but this app's shapes on the pasteboard is left alone: ⌘V passes the key on") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        pasteboard.setString("hello", forType: .string)
        expect(!h.editor.canPaste)
        expect(!h.command("v"))
        expectEqual(h.editor.document.shapes.count, 0)
    },
    test("this app's type holding nothing it can read (not a board, a newer format, only unknown kinds) is nothing to paste: ⌘V passes") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        let type = NSPasteboard.PasteboardType("com.example.InfiniteCanvas.shapes")
        for json in ["not json", #"{ "format" : 99, "schema" : {}, "shapes" : [] }"#,
                     #"{ "format" : 1, "schema" : {}, "shapes" : [ { "id" : "\#(ShapeID())", "kind" : "comet", "props" : {} } ] }"#] {
            pasteboard.clearContents()
            pasteboard.setData(Data(json.utf8), forType: type)
            expect(!h.editor.canPaste, json)
            expect(!h.command("v"), json)
        }
        expectEqual(h.editor.document.shapes.count, 0)
    },
    test("copying puts shapes in place of what the pasteboard held") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        pasteboard.setString("hello", forType: .string)
        h.editor.selection = h.add(Box(slot(0)))
        h.editor.copySelection()
        expectEqual(pasteboard.string(forType: .string), nil)
        expect(h.editor.canPaste)
    },
    test("one pasteboard serves every editor: copied on one board, pasted on another") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let source = try harness(pasteboard)
        let target = try harness(pasteboard)
        let box = source.add(Box(slot(2)))
        source.editor.selection = box
        source.editor.copySelection()
        target.editor.paste()
        expectEqual(target.editor.document.shapes.map(\.box), [slot(2)])
        expectEqual(target.editor.document.shapes.first?.copiedFrom, box)
    },
    test("a kind this board doesn't install is left out of a paste; the rest pastes") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let source = try harness(pasteboard, [CardsPlugin()])
        let target = try harness(pasteboard)
        let card = source.add(Card(slot(0)))
        let box = source.add(Box(slot(1)))
        source.editor.selectedShapeIDs = [card, box]
        source.editor.copySelection()
        target.editor.paste()
        expectEqual(target.editor.document.shapes.map(\.kind), [Box.kind])
        expectEqual(target.editor.selectedShapeIDs, target.editor.document.shapes.map(\.id))
    },
    test("pasted shapes keep the rest of their metadata, whoever it's for") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        let box = h.add(Box(slot(0)))
        h.editor.transact { $0.update(box) { $0.meta = ShapeMeta(json: ["other": ["note": "kept"]]) } }
        h.editor.selection = box
        h.editor.copySelection()
        let before = h.editor.document
        h.editor.paste()
        let copy = try require(h.editor.shapes(since: before).first)
        expectEqual(copy.meta.json["other"]?["note"], "kept")
        expectEqual(copy.copiedFrom, box)
    },
])

@MainActor let menuTests = Suite("Cut, Copy and Paste in the context menu", [
    test("every shape's menu has Cut and Copy after its own items, and Paste once there's something to paste") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard, [Contributor(id: "own") { r in r.contextMenu(Box.self) { MenuItem("Own") { _ in } } }])
        let box = h.add(Box(slot(0)))
        expectEqual(try require(h.secondaryClick(at: middle(0))).outline, ["Own", "—", "Cut", "Copy", "Duplicate", "—", "Delete"])
        h.editor.copy([box])
        expectEqual(try require(h.secondaryClick(at: middle(0))).outline, ["Own", "—", "Cut", "Copy", "Duplicate", "Paste", "—", "Delete"])
    },
    test("on empty canvas, Paste shows once there's something to paste, and lands centered where the menu was asked for; ⌘V keeps its place") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        let box = h.add(Box(slot(0)))
        h.editor.selection = box
        expectEqual(try require(h.secondaryClick(at: middle(1))).outline, ["Select All"], "nothing to paste")
        h.editor.copySelection()
        var before = h.editor.document
        let menu = try require(h.secondaryClick(at: middle(1)))
        expectEqual(menu.outline, ["Paste", "—", "Select All"])
        expectEqual(h.editor.selectedShapeIDs, [box])
        try menu.choose("Paste")
        let pasted = try require(h.editor.shapes(since: before).first)
        expectEqual(pasted.copiedFrom, box)
        expectEqual(pasted.box, slot(1), "centered on the click, the middle of slot 1")
        expectEqual(h.editor.undoHistory.undoName, "Paste")
        before = h.editor.document
        h.editor.paste()
        expectEqual(h.editor.shapes(since: before).first?.box, slot(0), "⌘V: where it was copied from")
    },
    test("Copy then Paste from the menu copy the right-clicked shape and paste it") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        let box = h.add(Box(slot(0)))
        try require(h.secondaryClick(at: middle(0))).choose("Copy")
        expectEqual(h.editor.selectedShapeIDs, [box])
        let before = h.editor.document
        let menu = try require(h.secondaryClick(at: CGPoint(x: 60, y: 70)))
        expectEqual(menu.outline, ["Cut", "Copy", "Duplicate", "Paste", "—", "Delete"])
        try menu.choose("Paste")
        let copy = try require(h.editor.shapes(since: before).first)
        expectEqual(copy.copiedFrom, box)
        expectEqual(copy.box, slot(0).offsetBy(dx: 10, dy: 20), "centered on the click, on the box")
        expectEqual(h.editor.selectedShapeIDs, [copy.id])
    },
    test("Cut from the menu cuts the whole selection") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        let a = h.add(Box(slot(0)))
        let b = h.add(Disc(slot(1)))
        h.add(Box(slot(2)))
        h.editor.selectedShapeIDs = [a, b]
        try require(h.secondaryClick(at: middle(1))).choose("Cut")
        expectEqual(h.editor.document.shapes.count, 1)
        h.editor.paste()
        expectEqual(h.editor.document.shapes.suffix(2).map(\.id), [a, b])
    },
    test("an uncopyable shape alone has no Cut or Copy, only Delete; with a copyable one too, they cut and copy that one") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        let ticket = h.add(Ticket(frame: slot(0)))
        let box = h.add(Box(slot(1)))
        expectEqual(try require(h.secondaryClick(at: middle(0))).outline, ["Delete"])
        expectEqual(h.editor.selectedShapeIDs, [ticket])
        h.editor.selectedShapeIDs = [ticket, box]
        let menu = try require(h.secondaryClick(at: middle(0)))
        expectEqual(menu.outline, ["Cut", "Copy", "Duplicate", "—", "Delete"])
        try menu.choose("Cut")
        expectEqual(h.editor.document.shapes.map(\.id), [ticket])
        expectEqual(try require(h.secondaryClick(at: middle(0))).outline, ["Paste", "—", "Delete"])
        h.editor.paste()
        expectEqual(h.editor.document.shapes.last?.id, box)
    },
])

@MainActor let registryTests = Suite("Clipboard's registration", [
    test("two copyability rules for one kind conflict") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        expectThrows(RegistryError.conflict(point: "ShapeCopyability", key: "ticket", plugins: ["clipboard-kinds", "again"])) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), ClipboardPlugin(pasteboard: pasteboard),
                                       FixturesPlugin(), KindsPlugin(),
                                       Contributor(id: "again") { $0.contribute({ _ in true }, to: ShapeCopyability.self, for: .kind(Ticket.kind)) }])
        }
    },
    test("opting out without the Clipboard plugin installed is an error") {
        expectThrows(RegistryError.ownerNotInstalled(point: "ShapeCopyability", owner: .clipboard, contributor: "clipboard-kinds")) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), FixturesPlugin(), KindsPlugin()])
        }
    },
])
