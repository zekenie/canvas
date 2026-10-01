import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Keyboard
import Selection
import TableOfContents
import TestKit

// Shapes in containers (CanvasTesting's corrals, as a frame holds shapes): every shape's row nests
// under its container's by default, as deep as containers nest, and a container's row starts
// expanded.

/// `contentsEditor`, with corrals.
@MainActor func corralEditor(_ more: [any CanvasPlugin] = [], file: CanvasFile = CanvasFile(), scheduler: any Scheduler = ManualScheduler()) throws -> CanvasEditor {
    try contentsEditor([CorralsPlugin()] + more, file: file, scheduler: scheduler)
}

/// Corral O holding widget A and corral I, which holds widget B; and widget C, on the board.
struct NestedCorrals {
    let outer: ShapeID, a: ShapeID, inner: ShapeID, b: ShapeID, c: ShapeID

    @MainActor init(in editor: CanvasEditor) {
        outer = editor.add(Corral(CGRect(x: 0, y: 0, width: 800, height: 600)))
        a = editor.add(Widget(CGRect(x: 20, y: 20, width: 100, height: 60), name: "A"))
        inner = editor.add(Corral(CGRect(x: 200, y: 200, width: 400, height: 300)))
        b = editor.add(Widget(CGRect(x: 220, y: 220, width: 100, height: 60), name: "B"))
        c = editor.add(Widget(CGRect(x: 1000, y: 0, width: 100, height: 60), name: "C"))
        editor.put([a, inner], in: outer)
        editor.put([b], in: inner)
    }
}

extension ContentsState {
    /// The row of `id`, at any depth of what's listed.
    func entry(_ id: ShapeID) -> ContentsEntry? {
        func find(_ entries: [ContentsEntry]) -> ContentsEntry? {
            for entry in entries {
                if entry.id == id { return entry }
                if let found = find(entry.children ?? []) { return found }
            }
            return nil
        }
        return find(entries)
    }
}

/// A reproducible stream of choices for the fuzz test.
private struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 11 | state << 53
    }
}

@MainActor let containerTests = Suite("Table of contents: shapes in containers", [
    test("every shape's row nests under its container's, as deep as containers nest") {
        let editor = try corralEditor()
        _ = NestedCorrals(in: editor)
        expectEqual(editor.contents.entries.outline, ["corral", "  A", "  corral", "    B", "C"])
        expectEqual(editor.contents.entries.tree, listedAfresh(editor))
    },
    test("a container's row starts expanded; every other row collapsed, a shape's arrows and a subboard's board too") {
        let editor = try corralEditor([PocketsPlugin()])
        let nest = NestedCorrals(in: editor)
        editor.add(Pin("on C", on: nest.c))
        let pocket = editor.add(Pocket(CGRect(x: 0, y: 900, width: 100, height: 60)))
        let empty = editor.add(Corral(CGRect(x: 2000, y: 0, width: 300, height: 300)))
        let contents = editor.contents
        let rows = try [nest.outer, nest.inner, nest.c, pocket, empty, nest.a].map { try require(contents.entry($0)) }
        expectEqual(rows.map(\.startsExpanded), [true, true, false, false, true, false])
        expectEqual(rows.map(contents.isExpanded), [true, true, false, false, true, false], "as they start")
        expectEqual(rows[4].children == nil, true, "an empty corral has nothing to open: no disclosure triangle")
    },
    test("a row keeps the disclosure it's turned to, whatever's listed, across boards; turned back, it's as it starts") {
        let editor = try corralEditor([PocketsPlugin()])
        let nest = NestedCorrals(in: editor)
        let pin = editor.add(Pin("on C", on: nest.c))
        let pocket = editor.add(Pocket(CGRect(x: 0, y: 900, width: 100, height: 60)))
        let contents = editor.contents
        let outer = try require(contents.entry(nest.outer)), c = try require(contents.entry(nest.c))
        contents.setExpanded(outer, false)
        contents.setExpanded(c, true)
        expect(!contents.isExpanded(outer) && contents.isExpanded(c))
        editor.selectedShapeIDs = [nest.outer, nest.a]
        expectEqual(editor.contents.entries.outline, ["corral", "  A"])
        expect(!contents.isExpanded(try require(contents.entry(nest.outer))), "listed again, its row stays collapsed")
        editor.selectedShapeIDs = []
        editor.transact { $0.update(pin, as: Pin.self) { $0.props.name = "on C, renamed" } }
        @MainActor func expanded() throws -> [Bool] {
            [contents.isExpanded(try require(contents.entry(nest.outer))), contents.isExpanded(try require(contents.entry(nest.c)))]
        }
        expectEqual(try expanded(), [false, true])
        editor.showBoard(BoardID(owner: pocket))
        editor.showBoard(.root)
        expectEqual(try expanded(), [false, true], "and back from another board")
        contents.setExpanded(outer, true)
        contents.setExpanded(c, false)
        expect(contents.isExpanded(outer) && !contents.isExpanded(c))
    },
    test("a shape nests only under a container the core goes by: one kept aside, or of a kind that holds nothing, kept as written, leaves it at the top") {
        let corral = ShapeID(), w1 = ShapeID(), gadget = ShapeID(), w2 = ShapeID(), w3 = ShapeID()
        func record(_ id: ShapeID, _ kind: String, _ index: String, name: String? = nil, container: ShapeID? = nil) -> String {
            let props = name.map { #", "name" : "\#($0)""# } ?? ""
            let holder = container.map { #", "container" : "\#($0)""# } ?? ""
            return #"{ "id" : "\#(id)", "kind" : "\#(kind)", "index" : "\#(index)", "props" : { "frame" : [[0, 0], [100, 60]]\#(props) }\#(holder) }"#
        }
        let shapes = [record(corral, "corral", "a0"), record(w1, "widget", "a1", name: "W1", container: corral),
                      record(gadget, "gadget", "a2"),                                       // a kind nobody installs: kept aside
                      record(w2, "widget", "a3", name: "W2", container: gadget),
                      record(w3, "widget", "a4", name: "W3", container: w1)]                // a widget holds nothing
        let json = #"{ "format" : 5, "versions" : { "kinds" : { "corral" : 0, "widget" : 0 } }, "shapes" : [\#(shapes.joined(separator: ", "))] }"#
        let registry = try contentsRegistry([CorralsPlugin()])
        let loaded = try BoardCodec(registry: registry).decode(Data(json.utf8))
        expectEqual(loaded.document[w2]?.container, gadget, "kept as written")
        expectEqual(loaded.document[w3]?.container, w1, "kept as written")
        let editor = CanvasEditor(registry: registry, document: loaded.document, scheduler: ManualScheduler())
        expectEqual(editor.contents.entries.outline, ["corral", "  W1", "W2", "W3"])
    },
    test("a kind's nestedUnder wins over the container: a pin in a corral nests under what it's pinned to, and under its corral when it names nothing") {
        let editor = try corralEditor()
        let nest = NestedCorrals(in: editor)
        let pinned = editor.add(Pin("on C", on: nest.c))
        let loose = editor.add(Pin("loose", on: nil))
        let link = editor.add(Link(on: nil))
        editor.put([pinned, loose], in: nest.outer)
        editor.put([link], in: nest.inner)
        expectEqual(editor.holder(of: pinned), nest.outer)
        expectEqual(editor.contents.entries.outline, ["corral", "  A", "  corral", "    B", "    Link", "  loose", "C", "  on C"])
        expectEqual(editor.contents.entries.tree, listedAfresh(editor))
    },
    test("a shape that joins a container moves its row there, with the rows under it; one that leaves goes back up") {
        let editor = try corralEditor()
        let nest = NestedCorrals(in: editor)
        editor.add(Pin("on C", on: nest.c))
        _ = editor.contents.entries
        let made = editor.contents.rowsMade
        editor.put([nest.c], in: nest.inner)
        expectEqual(editor.contents.entries.outline, ["corral", "  A", "  corral", "    B", "    C", "      on C"])
        expectEqual(editor.contents.rowsMade, made + 1, "C's row alone: its record changed")
        expectEqual(editor.contents.entries.tree, listedAfresh(editor))
        editor.put([nest.inner], in: nil)
        expectEqual(editor.contents.entries.outline, ["corral", "  A", "corral", "  B", "  C", "    on C"])
        expectEqual(editor.contents.entries.tree, listedAfresh(editor))
        editor.put([nest.inner], in: nest.outer)
        editor.put([nest.c], in: nil)
        expectEqual(editor.contents.entries.outline, ["corral", "  A", "  corral", "    B", "C", "  on C"])
        expectEqual(editor.contents.entries.tree, listedAfresh(editor))
    },
    test("a container deleted lets what it held go to its own container, rows and all") {
        let editor = try corralEditor()
        let nest = NestedCorrals(in: editor)
        _ = editor.contents.entries
        editor.transact { $0.delete([nest.inner]) }
        expectEqual(editor.contents.entries.outline, ["corral", "  A", "  B", "C"])
        expectEqual(editor.contents.entries.tree, listedAfresh(editor))
        editor.transact { $0.delete([nest.outer]) }
        expectEqual(editor.contents.entries.outline, ["A", "B", "C"])
        expectEqual(editor.contents.entries.tree, listedAfresh(editor))
    },
    test("rows follow undo and redo of joining, leaving, moving and deleting, as listing afresh gives them") {
        let editor = try corralEditor()
        let nest = NestedCorrals(in: editor)
        editor.replaceDocument(with: editor.document)
        let steps: [(String, @MainActor () -> Void)] = [
            ("join", { editor.put([nest.c], in: nest.inner) }),
            ("move", { editor.transact { $0.translate([nest.outer], by: CGPoint(x: 30, y: 10)) } }),
            ("leave", { editor.put([nest.inner], in: nil) }),
            ("delete", { editor.transact { $0.delete([nest.inner]) } }),
            ("restack", { editor.transact { $0.bringToFront(nest.outer) } }),
        ]
        var listed = [editor.contents.entries.tree]
        for (name, step) in steps {
            step()
            expectEqual(editor.contents.entries.tree, listedAfresh(editor), name)
            listed.append(editor.contents.entries.tree)
        }
        for expected in listed.dropLast().reversed() {
            editor.undo()
            expectEqual(editor.contents.entries.tree, listedAfresh(editor))
            expectEqual(editor.contents.entries.tree, expected)
        }
        for expected in listed.dropFirst() {
            editor.redo()
            expectEqual(editor.contents.entries.tree, expected)
        }
    },
    test("selecting lists the selection: a shape alone at the top, under its container while that's listed too") {
        let editor = try corralEditor()
        let nest = NestedCorrals(in: editor)
        editor.selectedShapeIDs = [nest.b]
        expectEqual(editor.contents.entries.outline, ["B"])
        editor.selectedShapeIDs = [nest.inner, nest.b, nest.c]
        expectEqual(editor.contents.entries.outline, ["corral", "  B", "C"])
        editor.selectedShapeIDs = [nest.outer, nest.b]
        expectEqual(editor.contents.entries.outline, ["corral", "B"], "B's container, the inner corral, isn't listed")
        editor.contents.showAll()
        expectEqual(editor.contents.entries.outline, ["corral", "  A", "  corral", "    B", "C"])
    },
    test("a move keeps every row, the container's and all it holds: a read after it makes none, and reads their marks again") {
        flag([])
        let editor = try corralEditor([flags])
        let nest = NestedCorrals(in: editor)
        let before = editor.contents.entries.tree
        let made = editor.contents.rowsMade
        marksMade = 0
        flagged = [nest.b]                // as a mark that follows where a shape is: no commit says so
        for step in 1...3 {
            editor.transact { $0.translate([nest.outer], by: CGPoint(x: 5, y: CGFloat(step))) }
            _ = editor.contents.entries
        }
        expectEqual(editor.contents.rowsMade, made, "no row made again")
        expectEqual(marksMade, 3 * 4, "the corrals' and their members' marks, read again on each read")
        expectEqual(editor.contents.entries.tree, before)
        expectEqual(editor.contents.entries.marks, [[], [], [], ["Flagged"], []], "B's mark follows")
        expectEqual(editor.document[nest.b]?.box?.origin, CGPoint(x: 235, y: 226), "B was carried")
        expectEqual(editor.contents.entries.tree, listedAfresh(editor))
        // Changed other than by moving, a row is made again, as ever.
        editor.transact { $0.update(nest.b, as: Widget.self) { $0.props.name = "Bee" } }
        expectEqual(editor.contents.entries.outline, ["corral", "  A", "  corral", "    Bee", "C"])
        expectEqual(editor.contents.rowsMade, made + 1)
        flag([])
    },
    test("another board's outline nests by container too, its containers' rows starting expanded") {
        let corral = ShapeRecord(Corral(CGRect(x: 0, y: 0, width: 600, height: 400)))
        let held = ShapeRecord(Widget(CGRect(x: 20, y: 20, width: 100, height: 60), name: "D"))
        let pocket = ShapeRecord(Pocket(CGRect(x: 0, y: 900, width: 100, height: 60)))
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(pocket)]),
                              children: [pocket.id: CanvasDocument(shapes: [AnyShapeRecord(corral),
                                                                           AnyShapeRecord(held).copy(as: held.id, container: corral.id)])])
        let editor = try corralEditor([PocketsPlugin()], file: file)
        let inside = BoardID(owner: pocket.id)
        expectEqual(editor.contents(of: inside).container(of: held.id, containingKinds: editor.registry.containingKinds), corral.id)
        let outline = editor.contents.outline(of: inside)
        expectEqual(outline.outline, ["corral", "  D"])
        expectEqual(outline.map(\.startsExpanded), [true])
        editor.showBoard(inside)
        expectEqual(editor.contents.entries.outline, ["corral", "  D"])
        expectEqual(editor.contents.outline(of: inside).outline, ["corral", "  D"], "the board shown's, from inside it")
    },
    test("kept up to date commit by commit among containers, the rows are those listing from scratch gives") {
        var random = Seeded(state: 2026_10_01)
        let early = Contributor(id: "early-reader") { $0.service { _ in EarlyReader() } }
        let editor = CanvasEditor(registry: try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), WidgetsPlugin(),
                                                                   CorralsPlugin(), early, TableOfContentsPlugin()]),
                                  scheduler: ManualScheduler())
        let reader = try require(editor.service(EarlyReader.self))
        @MainActor func chance(_ percent: Int) -> Bool { Int.random(in: 0..<100, using: &random) < percent }
        @MainActor func anyShape() -> ShapeID? { editor.document.shapes.randomElement(using: &random)?.id }
        @MainActor func anyCorral() -> ShapeID? { editor.document.shapes.filter { $0.kind == Corral.kind }.randomElement(using: &random)?.id }
        @MainActor func newShape() -> AnyShapeRecord {
            let frame = CGRect(x: Int.random(in: 0...2000, using: &random), y: Int.random(in: 0...2000, using: &random), width: 100, height: 60)
            return switch Int.random(in: 0..<10, using: &random) {
            case 0..<3: AnyShapeRecord(ShapeRecord(Corral(frame.insetBy(dx: -200, dy: -200))))
            case 3..<6: AnyShapeRecord(ShapeRecord(Widget(frame, name: "w\(Int.random(in: 0..<99, using: &random))", isHidden: chance(10))))
            case 6..<8: AnyShapeRecord(ShapeRecord(Pin("p\(Int.random(in: 0..<99, using: &random))", on: chance(50) ? anyShape() : nil)))
            default: AnyShapeRecord(ShapeRecord(Box(frame)))
            }
        }
        @MainActor func change(_ tx: inout Transaction) {
            guard let id = anyShape() else { return tx.insert(newShape()) }
            switch Int.random(in: 0..<12, using: &random) {
            case 0, 1:
                tx.insert(newShape())
            case 2:
                tx.delete([id])
            case 3, 4, 5:
                tx.setContainer(id, to: chance(25) ? nil : anyCorral())
            case 6:
                tx.translate([id], by: CGPoint(x: 7, y: 3))
            case 7:
                tx.bringToFront(id)
            case 8:
                tx.sendToBack(id)
            case 9:
                tx.update(id, as: Widget.self) { $0.props.isHidden.toggle() }
            case 10:
                tx.update(id, as: Pin.self) { $0.props.target = chance(30) ? nil : anyShape() }
            default:
                tx.update(id, as: Widget.self) { $0.props.count += 1 }
            }
        }
        for _ in 0..<30 { editor.transact { $0.insert(newShape()) } }
        for step in 0..<1500 {
            reader.reads = chance(3)                             // the rows read before the table of contents hears a commit
            switch Int.random(in: 0..<100, using: &random) {
            case 0..<60:
                editor.transact { change(&$0) }
            case 60..<70:
                editor.transact { tx in for _ in 0..<Int.random(in: 2...5, using: &random) { change(&tx) } }
            case 70..<80:                                        // a container dragged, the rows read after some events
                guard let corral = anyCorral() else { continue }
                for _ in 0..<Int.random(in: 1...4, using: &random) {
                    editor.transact { $0.translate([corral], by: CGPoint(x: 4, y: -2)) }
                    if chance(50) { expectEqual(editor.contents.entries.tree, listedAfresh(editor), "after step \(step), dragging") }
                }
            case 80..<84:
                editor.undo()
            case 84..<87:
                editor.redo()
            case 87..<92:
                editor.selectedShapeIDs = (0..<Int.random(in: 1...6, using: &random)).compactMap { _ in anyShape() }
            default:
                editor.selectedShapeIDs = []
            }
            guard chance(50) else { continue }
            let tree = editor.contents.entries.tree
            guard tree == listedAfresh(editor) else {
                expectEqual(tree, listedAfresh(editor), "after step \(step)")
                return
            }
        }
        expect(editor.document.shapes.contains { editor.holder(of: $0.id) != nil }, "some shapes are in containers")
    },
])
