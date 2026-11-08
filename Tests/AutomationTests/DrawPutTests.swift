@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Draw
import Foundation
import Geometry
import TestKit

// `put`: a program's shapes put down by a person (Clipboard's paste readers give one): names found nearest first and never refused
// (a shape of the statement's kind with its title, anywhere in the file; another kind is no match), the new shapes laid out in
// rows at draw's normal gap and landed beside the selection or on a point, one step named as the caller says, not an agent's, and a
// run that reaches two boards drawn on a rehearsal and taken in whole. Scripts keep refusing: the options are `put`'s alone.

private func tiles(_ rows: [[(title: String?, finish: String?)]]) -> DrawPut {
    DrawPut(rows: rows.map { row in
        row.map { DrawPut.Shape(kind: "tile", title: $0.title, values: $0.finish.map { [(key: "finish", text: $0)] } ?? []) }
    })
}

private func one(_ title: String, _ finish: String? = nil) -> DrawPut { tiles([[(title, finish)]]) }

@MainActor private func finish(of id: ShapeID, in editor: CanvasEditor) -> Tile.Finish? {
    editor.file.record(id)?.typed(as: Tile.self)?.props.finish
}

@MainActor private func tileCount(_ editor: CanvasEditor) -> Int {
    editor.file.everyBoard.reduce(0) { $0 + editor.file[$1].shapes.filter { $0.kind == Tile.kind }.count }
}

/// Puts a pen on the board, labeled, holding `held`.
@MainActor private func pen(_ label: String, _ frame: CGRect, holding held: [ShapeID], in editor: CanvasEditor) -> ShapeID {
    let record = AnyShapeRecord(ShapeRecord(Pen(frame, label: label)))
    editor.transact { $0.insert(record) }
    editor.transact { $0.setContainer(held, to: record.id) }
    return record.id
}

@MainActor let drawPutTests = Suite("put: a program's shapes put down by a person", [
    test("a title finds the shape of that kind the board shown has, not the one on another board; the board shown's first, then the file's order") {
        let n = Nest(), editor = try n.editor()
        let landed = try put(one("Hub", "glossy"), at: .beside([]), in: editor, step: "Paste Hubs")
        expectEqual(landed, [n.hub], "restated, made nothing")
        expectEqual(finish(of: n.hub, in: editor), .glossy)
        expectEqual(finish(of: n.pHub, in: editor), .matte, "P's Hub is another shape")
        expectEqual(tileCount(editor), 5)
        expect(editor.showBoard(BoardID(owner: n.p)))
        let there = try put(one("Hub", "glossy"), at: .beside([]), in: editor)
        expectEqual(there, [n.pHub], "now P's, the board shown's")
        expectEqual(finish(of: n.pHub, in: editor), .glossy)
        expect(editor.showBoard(.root))
        // "Twin" is on both P's and Q's board; the file's order is the root, then P (the board shown's first, then Topology's).
        let twin = try put(one("Twin", "glossy"), at: .beside([]), in: editor)
        expectEqual(twin, [], "on another board: restated there, and not a shape of the board shown")
        expectEqual(finish(of: n.pTwin, in: editor), .glossy, "the first in the file's order")
        expectEqual(finish(of: n.twin, in: editor), .matte)
    },
    test("of two shapes called alike on the board shown, the one in the container the block lands in wins over the one outside it, either order in the file") {
        for anchorInside in [true, false] {
            let editor = try drawEditor([pens])
            // The one that should lose is first in the file's order, so the order alone would pick it.
            let outside = tile("Hub", CGRect(x: 900, y: 0, width: 100, height: 60), in: editor)
            let inside = tile("Hub", CGRect(x: 40, y: 40, width: 100, height: 60), in: editor)
            let anchor = tile("Anchor", CGRect(x: 40, y: 140, width: 100, height: 60), in: editor)
            let outsideAnchor = tile("Far", CGRect(x: 900, y: 400, width: 100, height: 60), in: editor)
            _ = pen("Pen", CGRect(x: 0, y: 0, width: 400, height: 300), holding: [inside.id, anchor.id], in: editor)
            let landed = try put(one("Hub", "glossy"), at: .beside([anchorInside ? anchor.id : outsideAnchor.id]), in: editor)
            expectEqual(landed, [anchorInside ? inside.id : outside.id], anchorInside ? "the one in the pen the anchor is in" : "the one outside it, the anchor being outside")
            expectEqual(tileCount(editor), 4, "restated, nothing made")
        }
    },
    test("a title written twice in one put is one shape: made once when the file has none, restated once when it has one, its values joined; never two, never a refusal") {
        let editor = try drawEditor()
        let landed = try put(tiles([[("Twin", nil), ("Twin", "glossy")]]), at: .beside([]), in: editor)
        expectEqual(landed.count, 1, "one shape")
        expectEqual(tileCount(editor), 1)
        expectEqual(finish(of: landed[0], in: editor), .glossy, "the later statement's values joined the first's")
        // Now the file has it: both statements name it.
        let again = try put(tiles([[("Twin", "matte"), ("Twin", "glossy")]]), at: .beside([]), in: editor)
        expectEqual(again, landed, "the shape the file has, restated once")
        expectEqual(tileCount(editor), 1)
        expectEqual(finish(of: landed[0], in: editor), .matte, "a key both write keeps the first's")
    },
    test("a match that cannot be changed is no match for a statement that gives it values: a new shape is made, never a refusal; with no values it is found") {
        let editor = try drawEditor([FreezingPlugin()])
        let locked = tile("Held", CGRect(x: 0, y: 0, width: 100, height: 60), in: editor)
        editor.freeze([locked.id], true)
        let landed = try put(one("Held", "glossy"), at: .beside([]), in: editor)
        expectEqual(landed.count, 1)
        expect(landed != [locked.id], "a new shape beside it")
        expectEqual(tileCount(editor), 2)
        expectEqual(finish(of: locked.id, in: editor), .matte, "the locked one as it was")
        _ = try put(one("Held"), at: .beside([]), in: editor)
        expectEqual(tileCount(editor), 2, "a statement with no values finds one of the two, and makes nothing")
    },
    test("a shape of another kind with the title is no match: a new shape is made, never a refusal") {
        let n = Nest(), editor = try n.editor()
        let landed = try put(one("P"), at: .beside([]), in: editor)
        expectEqual(landed.count, 1)
        let made = try require(editor.document[landed[0]])
        expectEqual(made.kind, Tile.kind)
        expectEqual(editor.document.shapes.filter { $0.kind == Tile.kind && $0.typed(as: Tile.self)?.props.label == "P" }.count, 1, "a tile called P beside the pocket called P")
        expectEqual(editor.document.shapes.count, 4)
        let again = try put(one("P"), at: .beside([]), in: editor)
        expectEqual(again, landed, "the tile is the match now")
        expectEqual(editor.document.shapes.count, 4)
    },
    test("a title of the file twice is the nearest: the same container as the block's, then the board shown") {
        let n = Nest(), editor = try n.editor()
        // The root's Hub is on the board shown; P's Hub is not: with P shown, P's wins, whatever the order.
        expect(editor.showBoard(BoardID(owner: n.p)))
        let landed = try put(one("Hub", "glossy"), at: .beside([n.deep]), in: editor)
        expectEqual(landed, [n.pHub])
        expectEqual(finish(of: n.hub, in: editor), .matte)
    },
    test("new shapes land beside one selected shape at draw's normal gap, centered on it, in the rows the block says") {
        let editor = try drawEditor()
        let anchor = tile("Anchor", CGRect(x: 100, y: 100, width: 120, height: 80), in: editor)
        let landed = try put(tiles([[("A", nil), ("B", nil)], [("C", nil)]]), at: .beside([anchor.id]), in: editor)
        expectEqual(landed.count, 3)
        let frames = try landed.map { try require(editor.document[$0]?.box) }
        expectEqual(frames[0].minX, 220 + 80, "draw's normal gap from the anchor")
        expectEqual(frames[1].minX, frames[0].maxX + 80, "a row's shapes 80 apart")
        expectEqual(frames[1].minY, frames[0].minY)
        expectEqual(frames[2].minX, frames[0].minX)
        expectEqual(frames[2].minY, frames[0].maxY + 80, "the next row 80 below")
        let block = frames.reduce(CGRect.null) { $0.union($1) }
        expectEqual(block.midY, 140, "the block centered on the anchor")
        expectEqual(landed.map { editor.document[$0]?.typed(as: Tile.self)?.props.label }, ["A", "B", "C"])
    },
    test("beside several lands beside the box around them; with none, in the middle of the view; centered on a point, on it") {
        let editor = try drawEditor()
        let a = tile("A1", CGRect(x: 100, y: 100, width: 120, height: 80), in: editor)
        let b = tile("B1", CGRect(x: 100, y: 400, width: 120, height: 80), in: editor)
        let beside = try put(one("Z"), at: .beside([a.id, b.id]), in: editor)
        let frame = try require(editor.document[beside[0]]?.box)
        expectEqual(frame.minX, 220 + 80, "beside the box around both")
        expectEqual(frame.midY, 290)
        let middle = try put(one("M"), at: .beside([]), in: editor)
        let view = editor.camera.toWorld(CGRect(origin: .zero, size: editor.viewportSize))
        let spot = try require(editor.document[middle[0]]?.box)
        expect(view.contains(spot), "in view")
        let on = try put(one("On"), at: .centered(CGPoint(x: 2000, y: 2000)), in: editor)
        expectEqual(editor.document[on[0]]?.box?.center, CGPoint(x: 2000, y: 2000))
    },
    test("one step, named as the caller says, not an agent's change; undo takes it all, redo puts it back") {
        let log = AgentLog()
        let editor = try drawEditor([Contributor(id: "agents") { $0.service { _ in log } }])
        let before = editor.document
        let landed = try put(tiles([[("A", nil), ("B", nil)]]), at: .beside([]), in: editor, step: "Paste Tiles")
        expectEqual(landed.count, 2)
        expectEqual(editor.undoHistory.undoName, "Paste Tiles")
        expectEqual(log.commits, [false], "a person's")
        let after = editor.document
        editor.undo()
        expectEqual(editor.document, before)
        expect(!editor.canUndo, "one step")
        editor.redo()
        expectEqual(editor.document, after)
        let other = try drawEditor()
        _ = try put(one("A"), at: .beside([]), in: other)
        expectEqual(other.undoHistory.undoName, "Put", "the default")
        let scripted = try drawEditor([Contributor(id: "agents") { $0.service { _ in log } }])
        _ = try drawn(#"tile "A""#, on: scripted)
        expectEqual(log.commits.last, true, "a script is still an agent's")
        expectEqual(scripted.undoHistory.undoName, "Draw")
    },
    test("a run that reaches two boards is drawn on a rehearsal and taken in whole: one step, one undo, the board shown stays") {
        let n = Nest(), log = AgentLog(), editor = try n.editor([Contributor(id: "agents") { $0.service { _ in log } }])
        let heard = log.commits.count
        let landed = try put(tiles([[("Fresh", nil), ("Deep", "glossy")]]), at: .beside([n.hub]), in: editor, step: "Paste Both")
        expectEqual(editor.board, .root)
        expectEqual(landed.count, 1, "Fresh, the one shape of the board shown")
        expectEqual(finish(of: n.deep, in: editor), .glossy, "P's Deep restated on its own board")
        expectEqual(editor.document.shapes.filter { $0.typed(as: Tile.self)?.props.label == "Fresh" }.count, 1, "Fresh made on the board shown")
        expectEqual(editor.undoHistory.undoName, "Paste Both")
        expect(!log.commits.dropFirst(heard).contains(true), "a person's, on the rehearsal and when taken in")
        editor.undo()
        expectEqual(finish(of: n.deep, in: editor), .matte)
        expect(editor.document.shapes.allSatisfy { $0.typed(as: Tile.self)?.props.label != "Fresh" })
        expect(editor.undoHistory.undoName != "Paste Both")
    },
    test("a board that takes no shapes refuses with no step and nothing changed; a script's own rules still refuse") {
        let editor = try drawEditor([PocketsPlugin(), namedPockets, FreezingPlugin()])
        let pocket = AnyShapeRecord(ShapeRecord(Pocket(CGRect(x: 0, y: 300, width: 100, height: 100))))
        editor.transact { $0.insert(pocket) }
        editor.freeze([pocket.id], true)
        expect(editor.showBoard(BoardID(owner: pocket.id)))
        let before = editor.file, step = editor.undoHistory.undoName
        do {
            _ = try put(one("A"), at: .beside([]), in: editor)
            expect(false, "a read-only board takes no shapes")
        } catch {
            expectEqual((error as? DrawError)?.reason, "read_only")
        }
        expectEqual(editor.file, before)
        expectEqual(editor.undoHistory.undoName, step)
        // Two tiles called Same: a script is refused as ambiguous; a put restates the nearest.
        let twins = try drawEditor()
        let first = tile("Same", CGRect(x: 0, y: 0, width: 100, height: 60), in: twins)
        _ = tile("Same", CGRect(x: 300, y: 0, width: 100, height: 60), in: twins)
        _ = try refused(#"tile "Same" finish: glossy"#, on: twins)
        let landed = try put(one("Same", "glossy"), at: .beside([]), in: twins)
        expectEqual(landed, [first.id], "the first on the board")
        expectEqual(twins.document.shapes.count, 2)
    },
    test("a shape named within a container is the one at that path, before one of its title alone; failing that, its title's; nothing is made of the path") {
        let editor = try drawEditor([pens])
        let loose = tile("Hub", CGRect(x: 900, y: 0, width: 100, height: 60), in: editor)
        let held = tile("Hub", CGRect(x: 40, y: 40, width: 100, height: 60), in: editor)
        let pen = pen("Pen", CGRect(x: 0, y: 0, width: 400, height: 300), holding: [held.id], in: editor)
        let within = DrawPut(rows: [[DrawPut.Shape(kind: "tile", title: "Hub", within: ["Pen"], values: [(key: "finish", text: "glossy")])]])
        expectEqual(try put(within, at: .beside([]), in: editor), [held.id], "the Hub in Pen, though the loose one is nearer by title")
        expectEqual(finish(of: held.id, in: editor), .glossy)
        let nowhere = DrawPut(rows: [[DrawPut.Shape(kind: "tile", title: "Hub", within: ["Nope"], values: [(key: "finish", text: "glossy")])]])
        expectEqual(try put(nowhere, at: .beside([]), in: editor), [loose.id], "no container Nope: the Hub its title finds, the loose one, in no container as the block")
        expectEqual(tileCount(editor), 2, "nothing made")
        expectEqual(editor.document.shapes.filter { $0.kind == Pen.kind }.map(\.id), [pen], "no container made")
        let fresh = DrawPut(rows: [[DrawPut.Shape(kind: "tile", title: "Spoke", within: ["Pen"])]])
        let made = try put(fresh, at: .beside([]), in: editor)
        expectEqual(made.count, 1)
        expectEqual(editor.document[made[0]]?.typed(as: Tile.self)?.props.label, "Spoke", "made with its title, where the block lands")
        expect(editor.file.record(made[0])?.container == nil, "not in the pen its path names")
    },
    test("the edges a statement implies are drawn to the shape the put makes or the file's nearest; one whose shape is found nowhere is left out, never refused") {
        let editor = try drawEditor()
        let far = tile("Far", CGRect(x: 900, y: 0, width: 100, height: 60), in: editor)
        func edge(to title: String, kind: String = "tile") -> DrawPut.Edge {
            DrawPut.Edge(fromRow: nil, toKind: kind, toTitle: title, toRow: nil, attributes: [Tone.key.rawValue: "warm"])
        }
        let program = DrawPut(rows: [[
            DrawPut.Shape(kind: "tile", title: "A", edges: [edge(to: "B"), edge(to: "Far"), edge(to: "Nobody"), edge(to: "Far", kind: "pocket")]),
            DrawPut.Shape(kind: "tile", title: "B"),
        ]])
        let before = editor.document
        let landed = try put(program, at: .beside([]), in: editor, step: "Paste Tiles")
        expectEqual(landed.count, 2)
        expectEqual(links(in: editor).sorted(), ["A -> B", "A -> Far"], "to B, made with it, and to Far, the file's; Nobody and a pocket called Far, nowhere")
        expect(editor.document.shapes.compactMap { $0.typed(as: Link.self) }.allSatisfy { $0[Tone.self] == "warm" })
        expectEqual(editor.undoHistory.undoName, "Paste Tiles")
        let drawn = editor.document
        _ = try put(program, at: .beside([]), in: editor, step: "Paste Tiles")
        expectEqual(editor.document, drawn, "put again: the same edges, nothing new")
        while editor.undoHistory.undoName == "Paste Tiles" { editor.undo() }
        expectEqual(editor.document, before, "a put is its own step")
        expect(editor.document[far.id] != nil)
    },
    test("two names that both fall back to one title are two shapes: the second finds the next nearest, else is made, never the one twice") {
        let editor = try drawEditor()
        let first = tile("Hub", CGRect(x: 0, y: 0, width: 100, height: 60), in: editor)
        let program = DrawPut(rows: [[
            DrawPut.Shape(kind: "tile", title: "Hub", within: ["Nope"], values: [(key: "finish", text: "glossy")]),
            DrawPut.Shape(kind: "tile", title: "Hub", values: [(key: "finish", text: "matte")]),
        ]])
        let landed = try put(program, at: .beside([]), in: editor)
        expectEqual(landed.count, 2)
        expectEqual(landed[0], first.id, "the path, failing that the title: the one the file has")
        expect(landed[1] != first.id, "the bare title finds no other: a new one")
        expectEqual(finish(of: first.id, in: editor), .glossy)
        expectEqual(finish(of: landed[1], in: editor), .matte)
        expectEqual(tileCount(editor), 2)
        // Pasted again: each finds its own.
        let again = try put(program, at: .beside([]), in: editor)
        expectEqual(again, landed, "restated in place, neither twice")
        expectEqual(tileCount(editor), 2)
        expectEqual(finish(of: first.id, in: editor), .glossy)
        expectEqual(finish(of: landed[1], in: editor), .matte)
    },
    test("a row only the far shape can say is asked of the shape the put found; where it gives none the edge is left out") {
        let editor = try drawEditor()
        _ = tile("Far", CGRect(x: 900, y: 0, width: 100, height: 60), in: editor)
        func edge(_ ask: (@MainActor @Sendable (ShapeID, CanvasEditor) -> String?)?) -> DrawPut.Edge {
            DrawPut.Edge(fromRow: nil, toKind: "tile", toTitle: "Far", toRow: nil, attributes: [Tone.key.rawValue: "warm"], toRowOfShape: ask)
        }
        let program = DrawPut(rows: [[
            DrawPut.Shape(kind: "tile", title: "A", edges: [edge(nil)]),
            DrawPut.Shape(kind: "tile", title: "B", edges: [edge({ _, _ in nil })]),
        ]])
        _ = try put(program, at: .beside([]), in: editor)
        expectEqual(links(in: editor).sorted(), ["A -> Far"], "B's was asked and had no row to give")
    },
    test("a late value is written once every name is found: told the statement's shape, whether the file had it, and the shape another statement found or made; nil writes none") {
        let editor = try drawEditor()
        let hub = tile("Hub", CGRect(x: 0, y: 0, width: 100, height: 60), in: editor)
        final class Seen: @unchecked Sendable { var told: [(shape: ShapeID, found: Bool, other: ShapeID?)] = []; var nowhere: [ShapeID?] = [] }
        let seen = Seen()
        func late(_ other: String) -> DrawPut.LateValue {
            DrawPut.LateValue(key: "finish") { names in
                seen.told.append((names.shape, names.found, names.shape(Tile.kind, called: other)))
                seen.nowhere.append(names.shape(Tile.kind, called: "Nowhere"))
                return names.found ? "glossy" : nil
            }
        }
        let program = DrawPut(rows: [[
            DrawPut.Shape(kind: "tile", title: "Hub", late: [late("New")]),
            DrawPut.Shape(kind: "tile", title: "New", late: [late("Hub")]),
        ]])
        let landed = try put(program, at: .beside([]), in: editor)
        expectEqual(landed.count, 2)
        let made = try require(landed.first { $0 != hub.id })
        expectEqual(seen.told.count, 2)
        expectEqual(seen.told.first?.shape, hub.id)
        expectEqual(seen.told.first?.found, true)
        expectEqual(seen.told.first?.other, made, "the shape the other statement makes, before it is made")
        expectEqual(seen.told.last?.shape, made)
        expectEqual(seen.told.last?.found, false)
        expectEqual(seen.told.last?.other, hub.id, "the file's, found")
        expectEqual(finish(of: hub.id, in: editor), .glossy, "found: written")
        expectEqual(finish(of: made, in: editor), .matte, "made: nil wrote nothing, the default")
        expectEqual(seen.nowhere, [nil, nil], "a title none of the put's statements names: none")
    },
    test("a statement finds only a shape it admits: one it doesn't is no match and a new one is made, never a refusal; a late value counts as a value, so a locked match is none") {
        let editor = try drawEditor([FreezingPlugin()])
        let matte = tile("Hub", CGRect(x: 0, y: 0, width: 100, height: 60), in: editor)
        let glossy: @MainActor @Sendable (AnyShapeRecord) -> Bool = { $0.typed(as: Tile.self)?.props.finish == .glossy }
        let landed = try put(DrawPut(rows: [[DrawPut.Shape(kind: "tile", title: "Hub", values: [(key: "finish", text: "glossy")], admits: glossy)]]),
                             at: .beside([]), in: editor)
        expectEqual(landed.count, 1)
        expect(landed != [matte.id], "the matte Hub isn't admitted: a glossy one made beside it")
        expectEqual(finish(of: matte.id, in: editor), .matte)
        let again = try put(DrawPut(rows: [[DrawPut.Shape(kind: "tile", title: "Hub", admits: glossy)]]), at: .beside([]), in: editor)
        expectEqual(again, landed, "the glossy one is the match now")
        expectEqual(tileCount(editor), 2)
        editor.freeze(landed, true)
        let late = DrawPut.LateValue(key: "finish") { _ in "glossy" }
        let third = try put(DrawPut(rows: [[DrawPut.Shape(kind: "tile", title: "Hub", late: [late], admits: glossy)]]), at: .beside([]), in: editor)
        expect(third != landed, "locked, and the statement writes: a new one")
        expectEqual(tileCount(editor), 3)
    },
    test("a name written twice with late values for one key keeps the first's, as it does a plain value's; a key only the later one writes joins") {
        let editor = try drawEditor()
        let program = DrawPut(rows: [[
            DrawPut.Shape(kind: "tile", title: "Twin", late: [DrawPut.LateValue(key: "finish") { _ in "glossy" }]),
            DrawPut.Shape(kind: "tile", title: "Twin", late: [DrawPut.LateValue(key: "finish") { _ in "matte" }]),
        ]])
        let landed = try put(program, at: .beside([]), in: editor)
        expectEqual(landed.count, 1, "one shape")
        expectEqual(finish(of: landed[0], in: editor), .glossy, "the first file's, not the last's")
        let plain = DrawPut(rows: [[
            DrawPut.Shape(kind: "tile", title: "Pair", values: [(key: "finish", text: "glossy")]),
            DrawPut.Shape(kind: "tile", title: "Pair", late: [DrawPut.LateValue(key: "finish") { _ in "matte" }]),
        ]])
        let pair = try put(plain, at: .beside([]), in: editor)
        expectEqual(finish(of: pair[0], in: editor), .glossy, "a plain value of the earlier is kept over a later late one")
    },
])
