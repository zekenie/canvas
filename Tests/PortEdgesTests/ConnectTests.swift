@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Keyboard
import Selection
import TestKit

// Connect (⌘L): two selected shapes connected, the first selected to the second, by the maker `canvas
// draw` makes an edge with, over the fixtures: tiles take the wire on every side, cards dot the pipe
// and take the wire on their left only.

@MainActor private func add(_ shape: some ShapeProps, to editor: CanvasEditor) -> ShapeID {
    let record = AnyShapeRecord(ShapeRecord(shape))
    editor.transact { $0.insert(record) }
    return record.id
}

@MainActor private func connections(in editor: CanvasEditor) -> [AnyShapeRecord] {
    editor.document.shapes.filter { $0.kind == Link.kind }
}

@MainActor let connectTests = Suite("Connect", [
    test("⌘L connects two selected shapes, from the one selected first, on the channel the maker picks: one step, Connect; the selection stays") {
        let editor = try edgesEditor()
        expectEqual(editor.registry.shortcut(forCommand: .connect)?.chord, KeyChord("l", .command))
        expectEqual(editor.registry.title(of: .connect), "Connect")
        let a = add(Tile(CGRect(x: 0, y: 0, width: 100, height: 60), label: "A"), to: editor)
        let card = add(Card(CGRect(x: 300, y: 0, width: 100, height: 60), text: "C"), to: editor)
        editor.selectedShapeIDs = [card, a]
        editor.perform(.connect)
        expectEqual(connections(in: editor).count, 0, "a card dots the pipe, which a tile doesn't take: nothing")
        expect(editor.service(RefusalShake.self)?.isShaking == true, "and both shake")
        editor.selectedShapeIDs = [a, card]
        expect(editor.canPerform(.connect))
        editor.perform(.connect)
        let link = try require(connections(in: editor).first)
        expectEqual(endsList(editor.registry.connectionEnds(of: link)), [a, card])
        expectEqual(link[ChannelProperty.self], "wire")
        expectEqual(editor.undoHistory.undoName, "Connect")
        expectEqual(editor.selectedShapeIDs, [a, card], "the selection stays")
        editor.undo()
        expectEqual(connections(in: editor).count, 0)
    },
    test("the connection-made hook runs once, after the commit and inside the Connect step; a refusal runs none") {
        var heard: [(ShapeID, Bool, String?)] = []
        let hook = Contributor(id: "heard") { registrar in
            registrar.connectionMade { id, editor in heard.append((id, editor.document[id] != nil, editor.undoHistory.undoName)) }
        }
        let editor = try edgesEditor(more: [hook])
        let a = add(Tile(CGRect(x: 0, y: 0, width: 100, height: 60), label: "A"), to: editor)
        let card = add(Card(CGRect(x: 300, y: 0, width: 100, height: 60), text: "C"), to: editor)
        editor.selectedShapeIDs = [card, a]
        editor.perform(.connect)
        expectEqual(heard.count, 0, "a refusal runs none")
        editor.selectedShapeIDs = [a, card]
        editor.perform(.connect)
        expectEqual(heard.count, 1)
        expectEqual(heard.first?.0, connections(in: editor).first?.id)
        expectEqual(heard.first?.1, true, "after the commit")
        expectEqual(heard.first?.2, "Connect", "inside the step")
        expectEqual(editor.undoHistory.undoName, "Connect")
    },
    test("Connect can't run with three shapes, or none, selected, nor while a shape is edited; the key then goes on") {
        let editor = try edgesEditor()
        let a = add(Tile(CGRect(x: 0, y: 0, width: 100, height: 60), label: "A"), to: editor)
        let b = add(Tile(CGRect(x: 300, y: 0, width: 100, height: 60), label: "B"), to: editor)
        let c = add(Tile(CGRect(x: 600, y: 0, width: 100, height: 60), label: "C"), to: editor)
        for selected in [[a, b, c], []] {
            editor.selectedShapeIDs = selected
            expect(!editor.canPerform(.connect), "\(selected.count) selected")
            expect(!editor.keyDown(KeyStroke("l", modifiers: .command)), "the key goes on")
        }
        editor.selectedShapeIDs = [a, b]
        expect(editor.keyDown(KeyStroke("l", modifiers: .command)))
        expectEqual(connections(in: editor).count, 1)
    },
    test("⌘L on one shape connects it to itself, as the maker makes `edge \"A\" -> \"A\"`: one step, Connect; one it can't join to itself shakes, with no step") {
        let editor = try edgesEditor()
        let a = add(Tile(CGRect(x: 0, y: 0, width: 100, height: 60), label: "A"), to: editor)
        let card = add(Card(CGRect(x: 300, y: 0, width: 100, height: 60), text: "C"), to: editor)
        let glossy = add(Tile(CGRect(x: 600, y: 0, width: 100, height: 60), label: "G", finish: .glossy), to: editor)
        editor.replaceDocument(with: editor.document)
        editor.selectedShapeIDs = [a]
        expect(editor.canPerform(.connect))
        expect(editor.keyDown(KeyStroke("l", modifiers: .command)))
        let link = try require(connections(in: editor).first)
        expectEqual(endsList(editor.registry.connectionEnds(of: link)), [a, a])
        expectEqual(link[ChannelProperty.self], "wire")
        expectEqual(editor.undoHistory.undoName, "Connect")
        expectEqual(editor.selectedShapeIDs, [a], "the selection stays")
        editor.selectedShapeIDs = [card]
        editor.perform(.connect)
        expectEqual(connections(in: editor).last.flatMap { editor.registry.connectionEnds(of: $0) }.map { [$0.from, $0.to] }, [card, card],
                    "a card dots the pipe and takes it")
        editor.selectedShapeIDs = [glossy]
        editor.undoHistory.seal()
        let steps = editor.undoHistory.undoName
        editor.perform(.connect)
        expectEqual(connections(in: editor).count, 2, "the maker refuses a glossy tile")
        expect(editor.service(RefusalShake.self)?.isShaking == true)
        expectEqual(editor.undoHistory.undoName, steps, "no step")
    },
    test("a glossy tile, which the maker refuses, is connected to nothing: both shake and no step is left") {
        let editor = try edgesEditor()
        let a = add(Tile(CGRect(x: 0, y: 0, width: 100, height: 60), label: "A"), to: editor)
        let glossy = add(Tile(CGRect(x: 300, y: 0, width: 100, height: 60), label: "G", finish: .glossy), to: editor)
        editor.replaceDocument(with: editor.document)
        editor.selectedShapeIDs = [a, glossy]
        editor.perform(.connect)
        expectEqual(connections(in: editor).count, 0)
        expect(editor.service(RefusalShake.self)?.isShaking == true)
        expect(!editor.canUndo)
    },
])

/// A connection's ends, as a list, so they compare.
private func endsList(_ ends: (from: ShapeID, to: ShapeID)?) -> [ShapeID]? { ends.map { [$0.from, $0.to] } }
