@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Draw
import TestKit

// `registry.drawConnection(from:to:in:standingFor:beside:)`: the one maker of a connection by id, the
// public reader of the maker `canvas draw` draws edges with, so the app and a script make an arrow by
// one maker.

@MainActor let drawConnectionTests = Suite("A connection made by id", [
    test("whether anything makes connections: with the edges plugin, yes; without, no, and no connection is made") {
        let editor = try drawEditor()
        expect(editor.registry.drawsConnections)
        let none = try makeEditor([namesPlugin()])
        expect(!none.registry.drawsConnections)
        let hub = tile("Hub", CGRect(x: 0, y: 0, width: 100, height: 60), in: none)
        let east = tile("East", CGRect(x: 300, y: 0, width: 100, height: 60), in: none)
        expect(none.registry.drawConnection(from: hub.id, to: east.id, in: none.shapeContext) == nil)
    },
    test("a connection from one shape to another is the maker's, new, not inserted, and the one a script's edge between the same shapes makes") {
        let log = EdgeLog()
        let editor = try drawEditor(log: log)
        let hub = tile("Hub", CGRect(x: 0, y: 0, width: 100, height: 60), in: editor)
        let east = tile("East", CGRect(x: 300, y: 0, width: 100, height: 60), in: editor)
        let before = editor.document
        let made = try require(editor.registry.drawConnection(from: hub.id, to: east.id, in: editor.shapeContext))
        expectEqual(editor.document, before, "nothing is inserted")
        expectEqual(made.kind, Link.kind)
        let props = try require(made.typed(as: Link.self)).props
        expectEqual([props.from, props.to], [hub.id, east.id])
        expectEqual(log.requests.last, EdgeRequest(from: hub.id, to: east.id))
        expectEqual(log.existing.last, .some(nil), "a new one")
        editor.transact { $0.insert(made) }
        expectEqual(links(in: editor), ["Hub -> East"])
        // The same pair written as a script is that connection already: nothing to change.
        expectEqual(rows(try drawn(#"edge "Hub" -> "East""#, on: editor)).first?["did"], "unchanged")
        let other = try drawEditor()
        let a = tile("Hub", CGRect(x: 0, y: 0, width: 100, height: 60), in: other)
        let b = tile("East", CGRect(x: 300, y: 0, width: 100, height: 60), in: other)
        _ = try drawn(#"edge "Hub" -> "East""#, on: other)
        let scripted = try require(other.document.shapes.first { $0.kind == Link.kind }?.typed(as: Link.self)).props
        expectEqual([scripted.from, scripted.to], [a.id, b.id])
        expectEqual(props.from == hub.id, scripted.from == a.id, "by the same maker")
    },
    test("what an end stands for and how many already join the pair are carried to the maker as the request has them; a request that asks for neither has none") {
        let log = EdgeLog()
        let editor = try drawEditor(log: log)
        let hub = tile("Hub", CGRect(x: 0, y: 0, width: 100, height: 60), in: editor)
        let east = tile("East", CGRect(x: 300, y: 0, width: 100, height: 60), in: editor)
        _ = try require(editor.registry.drawConnection(from: hub.id, to: east.id, in: editor.shapeContext))
        expectEqual(log.requests.last?.fromStandsFor, [])
        expectEqual(log.requests.last?.toStandsFor, [])
        expectEqual(log.requests.last?.beside, .some(nil), "none: the maker reads them")
        _ = try require(editor.registry.drawConnection(from: hub.id, to: east.id, in: editor.shapeContext,
                                                       standingFor: (from: [], to: [Tile.kind, Card.kind]), beside: [hub.id]))
        expectEqual(log.requests.last?.fromStandsFor, [])
        expectEqual(log.requests.last?.toStandsFor, [Tile.kind, Card.kind])
        expectEqual(log.requests.last?.beside, [hub.id])
        _ = try require(editor.registry.drawConnection(from: hub.id, to: east.id, in: editor.shapeContext,
                                                       standingFor: (from: [Card.kind], to: [])))
        expectEqual(log.requests.last?.fromStandsFor, [Card.kind])
        expectEqual(log.requests.last?.beside, .some(nil))
    },
    test("a pair the maker refuses is nil, with nothing made: a shape to itself, a shape that isn't there") {
        let log = EdgeLog()
        let editor = try drawEditor(log: log)
        let hub = tile("Hub", CGRect(x: 0, y: 0, width: 100, height: 60), in: editor)
        let before = editor.document
        expect(editor.registry.drawConnection(from: hub.id, to: hub.id, in: editor.shapeContext) == nil, "to itself")
        expect(editor.registry.drawConnection(from: hub.id, to: ShapeID(), in: editor.shapeContext) == nil, "to nothing")
        expectEqual(editor.document, before)
        expectEqual(log.requests.count, 2, "the maker was asked both times")
    },
])
