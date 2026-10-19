import Canvas
import CanvasTesting
import CoreGraphics
import Keyboard
import Selection
import SlashCommands
import Subboards
import TableOfContents
import TestKit
import Titles
import Transform

// Subboards takes the container channel: whatever offers it turns into a subboard. Frames are what offer
// it in the app (CompositionTests hold that); here it's CanvasTesting's corral, a box that holds shapes
// as a frame does, titled as a frame is so that a title is one both kinds hold.

/// Corrals offer the container channel, as a frame does. Their links and boxes come with the fixtures.
@MainActor private func corralsTurnIntoSubboards() -> [any CanvasPlugin] {
    [CorralsPlugin(), LinksPlugin(), Contributor(id: "corral-turning") { r in
        r.title(Corral.self)
        r.turnable(Corral.self, through: ContainerChannel.self)
    }]
}

@MainActor private func turnHarness(_ file: CanvasFile) throws -> EditorHarness {
    try EditorHarness(plugins: subboardPlugins() + corralsTurnIntoSubboards(), file: file)
}

private func box(_ id: ShapeID, x: CGFloat, y: CGFloat, in container: ShapeID? = nil) -> AnyShapeRecord {
    record(id, Box(CGRect(x: x, y: y, width: 40, height: 30))).copy(as: id, container: container)
}

private func corral(_ id: ShapeID, _ frame: CGRect, title: String? = nil, in container: ShapeID? = nil) -> AnyShapeRecord {
    var corral = ShapeRecord(id: id, Corral(frame))
    corral[TitleProperty.self] = title
    return AnyShapeRecord(corral).copy(as: id, container: container)
}

private func link(_ id: ShapeID, _ from: ShapeID?, _ to: ShapeID?) -> AnyShapeRecord { record(id, Link(from: from, to: to)) }

/// Corral K, "Kitchen", 400 × 300 from (100, 100), that holds box A and corral L, which holds box B; box C
/// beside it and Z far off; a link I between A and B and one, O, from A to C.
private struct Kitchen {
    let z = ShapeID(), k = ShapeID(), a = ShapeID(), l = ShapeID(), b = ShapeID(), c = ShapeID(), i = ShapeID(), o = ShapeID()

    var file: CanvasFile {
        CanvasFile(root: CanvasDocument(shapes: [
            box(z, x: 900, y: 0), corral(k, CGRect(x: 100, y: 100, width: 400, height: 300), title: "Kitchen"), box(a, x: 120, y: 120, in: k),
            corral(l, CGRect(x: 200, y: 200, width: 200, height: 150), in: k), box(b, x: 220, y: 220, in: l), box(c, x: 600, y: 0),
            link(i, a, b), link(o, a, c),
        ]))
    }

    /// Where K shows, under neither A nor L.
    let point = CGPoint(x: 450, y: 380)
}

extension EditorHarness {
    fileprivate func props<P: ShapeProps>(_ id: ShapeID, as _: P.Type) -> P? { file.record(id)?.typed(as: P.self)?.props }

    /// The ids of the rows of the table of contents, at any depth.
    fileprivate var rows: Set<ShapeID> {
        func walk(_ entries: [ContentsEntry]) -> [ShapeID] { entries.flatMap { [$0.id] + walk($0.children ?? []) } }
        return Set(walk(editor.tableOfContents?.entries ?? []))
    }
}

@MainActor let subboardTurnTests = Suite("Turning into a subboard", [
    test("subboards take the container channel, with its menu item and its command: the report says so, and a kind that offers the channel has the subboard among its targets; a subboard offers nothing") {
        let registry = try Registry(plugins: subboardPlugins())
        let line = try require(registry.report.split(separator: "\n").first { $0.hasPrefix("subboards") })
        expect(line.hasSuffix("takes channel container → subboard · CanvasContextMenu · /turn-into-subboard → every shape that can turn into subboard"), "\(line)")
        expectEqual(registry.turnTargets(of: Subboard.kind), [])

        let turning = try Registry(plugins: subboardPlugins() + corralsTurnIntoSubboards())
        expectEqual(turning.turnTargets(of: Corral.kind), [Subboard.kind])
        expectEqual(turning.turnTargets(of: Box.kind), [], "a box holds nothing")
        expectEqual(turning.turnTargets(of: Subboard.kind), [], "and a subboard is what shapes turn into")

        let k = Kitchen()
        let h = try turnHarness(k.file)
        expectEqual(h.editor.slashCommands?.commands(for: k.k).map(\.name), ["turn-into-subboard", "title"], "in plugin order: Subboards' before Titles'")
        expectEqual(h.editor.slashCommands?.commands(for: k.z).map(\.name), [])
    },

    test("a corral titled Kitchen turns into a subboard of 240 × 160 at its corner: the same shape under its id with its title, what it held on its board where it was, a corral inside still holding its box; the item reads Turn into Subboard, and it's one step") {
        let k = Kitchen()
        let h = try turnHarness(k.file)
        let before = h.file
        let menu = try require(h.secondaryClick(at: k.point))
        expectEqual(menu.outline, ["Turn into Subboard", "—", "Delete"])
        expectEqual(h.editor.selectedShapeIDs, [k.k], "the right-click selected it")
        try menu.choose("Turn into Subboard")

        let subboard = try require(h.file.record(k.k))
        expectEqual(subboard.kind, Subboard.kind, "under its id")
        expectEqual(subboard.box, CGRect(x: 100, y: 100, width: 240, height: 160), "a subboard's size at the corral's corner")
        expectEqual(subboard[TitleProperty.self], "Kitchen", "its title, which both kinds hold")
        expectEqual(h.editor.document.shapes.map(\.id), [k.z, k.k, k.c, k.o], "what it held is off this board, the subboard where the corral was")
        let board = h.file[BoardID(owner: k.k)]
        expectEqual(board.shapes.map(\.id), [k.a, k.l, k.b, k.i], "on its board, in the order they were")
        expectEqual(board.shapes.map(\.container), [nil, nil, k.l, nil], "the corral inside is still one, holding its box")
        expectEqual(board[k.b]?.box, before.record(k.b)?.box, "where they were")
        expectEqual(board[k.l]?.box, before.record(k.l)?.box)
        expectEqual(h.props(k.i, as: Link.self), Link(from: k.a, to: k.b), "a link between what moved rode along")
        expectEqual(h.props(k.o, as: Link.self), Link(from: nil, to: k.c), "one to a shape that stays let go of its end")
        expectEqual(h.editor.selectedShapeIDs, [k.k], "still selected")
        expectEqual(h.editor.undoHistory.undoName, "Turn into Subboard")
        let after = h.file

        h.editor.undo()
        expectEqual(h.file, before, "the corral, and everything in it")
        expectEqual(h.editor.document[k.k]?.kind, Corral.kind)
        expectEqual(h.editor.holder(of: k.b), k.l)
        h.editor.redo()
        expectEqual(h.file, after, "and the subboard again")
    },

    test("the subboard it makes opens onto what the corral held: Return enters it, and ⌘↑ comes back with it selected") {
        let k = Kitchen()
        let h = try turnHarness(k.file)
        try require(h.secondaryClick(at: k.point)).choose("Turn into Subboard")
        h.editor.selection = k.k
        expect(h.key("\r"))
        expectEqual(h.editor.board, BoardID(owner: k.k))
        expectEqual(h.editor.document.shapes.map(\.id), [k.a, k.l, k.b, k.i])
        expectEqual(h.editor.holder(of: k.b), k.l)
        expect(h.command(KeyChord.upArrow.key))
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.selection, k.k)
    },

    test("the table of contents lists the subboard and what stayed, and what moved is on its board's list; undone, the corral and what it held again") {
        let k = Kitchen()
        let h = try turnHarness(k.file)
        let everything = h.rows
        expectEqual(everything, [k.z, k.k, k.a, k.l, k.b, k.c, k.i, k.o], "every shape, the corral's under it")
        h.editor.transforms?.turn([k.k], into: Subboard.kind)
        expectEqual(h.rows, [k.z, k.k, k.c, k.o], "nothing of what moved is left in the board shown's list")
        let row = try require(h.editor.tableOfContents?.entries.first { $0.id == k.k }?.label)
        expectEqual(row.text, "Kitchen")
        expectEqual(row.systemImage, "rectangle.stack", "the subboard's own row")
        expect(h.enter(k.k))
        expectEqual(h.rows, [k.a, k.l, k.b, k.i], "its board's")
        expect(h.editor.showBoard(.root))
        h.editor.undo()
        expectEqual(h.rows, everything)
    },

    test("corrals selected together turn into subboards together, the one inside first: its subboard is on the outer one's board") {
        let o = ShapeID(), i = ShapeID(), a = ShapeID(), b = ShapeID()
        let h = try turnHarness(CanvasFile(root: CanvasDocument(shapes: [
            corral(o, CGRect(x: 0, y: 0, width: 600, height: 400), title: "Roadmap"), box(a, x: 20, y: 20, in: o),
            corral(i, CGRect(x: 100, y: 100, width: 300, height: 200), title: "Sprint 3", in: o), box(b, x: 120, y: 120, in: i),
        ])))
        let before = h.file
        h.editor.selectedShapeIDs = [o, i]
        try require(h.secondaryClick(at: CGPoint(x: 500, y: 350))).choose("Turn into Subboard")
        expectEqual(h.editor.document.shapes.map(\.id), [o])
        expectEqual(h.file[BoardID(owner: o)].shapes.map(\.id), [a, i])
        expectEqual(h.file[BoardID(owner: i)].shapes.map(\.id), [b])
        expectEqual(h.file.record(i)?.kind, Subboard.kind)
        expectEqual(h.file.record(i)?[TitleProperty.self], "Sprint 3")
        expectEqual(h.file.record(i)?.box, CGRect(x: 100, y: 100, width: 240, height: 160), "where the corral was")
        expectEqual(h.file.path(to: BoardID(owner: i)), [.root, BoardID(owner: o), BoardID(owner: i)])
        h.editor.undo()
        expectEqual(h.file, before, "both corrals, and everything in them: one step")
    },

    test("/turn-into-subboard turns it as the menu's item does, in a step of the same name; a subboard doesn't offer it") {
        let k = Kitchen()
        let h = try turnHarness(k.file)
        let before = h.file
        let state = try require(h.editor.slashCommands)
        expect(state.run("turn-into-subboard", on: k.k, with: SlashArguments([])))
        expectEqual(h.editor.document[k.k]?.kind, Subboard.kind)
        expectEqual(h.editor.undoHistory.undoName, "Turn into Subboard")
        expect(!state.run("turn-into-subboard", on: k.k, with: SlashArguments([])), "it's a subboard now")
        h.editor.undo()
        expectEqual(h.file, before)
    },

    test("a corral with nothing in it turns into an empty subboard, which opens: no board is kept for it") {
        let k = ShapeID()
        let h = try turnHarness(CanvasFile(root: CanvasDocument(shapes: [corral(k, CGRect(x: 40, y: 40, width: 100, height: 100), title: "Later")])))
        let menu = try require(h.secondaryClick(at: CGPoint(x: 90, y: 90)))
        try menu.choose("Turn into Subboard")
        expectEqual(h.editor.document[k]?.kind, Subboard.kind)
        expectEqual(h.editor.document[k]?.box?.size, CGSize(width: 240, height: 160), "larger than the corral was")
        expectEqual(h.file.children.count, 0, "an empty board isn't kept")
        expect(h.enter(k))
        expectEqual(h.editor.document.shapes.count, 0)
    },
])
