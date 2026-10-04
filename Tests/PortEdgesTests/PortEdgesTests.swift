import Automation
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import Connections
import CoreGraphics
import TestKit

@MainActor let channelTests = Suite("An edge's channel", [
    test("unwritten, it's the first of the start's dot channels the end takes: a tile's wire, a card's pipe; the row says which") {
        let requests = Requests()
        let editor = try edgesEditor(requests)
        _ = try drawn(board, on: editor)
        let result = try drawn("""
            edge "A" -> "B"
            edge "C" -> "D"
            edge "A" -> "C"
            """, on: editor)
        expectEqual(links(in: editor), ["A -> B on wire", "C -> D on pipe", "A -> C on wire"])
        expectEqual(edgeRows(result).map { $0["channel"] }, ["wire", "pipe", "wire"])
        expectEqual(edgeRows(result).map { $0["did"] }, ["connected", "connected", "connected"])
        expectEqual(requests.made.map(\.channel), [Wire.id, Pipe.id, Wire.id])
    },
    test("with none shared it's no_channel, saying what each end connects on; channel: none draws a plain one anyway") {
        let editor = try edgesEditor()
        _ = try drawn(board, on: editor)
        let error = try refused(#"edge "C" -> "A""#, on: editor)
        expectEqual(error["reason"], "no_channel")
        expectEqual(error["message"], #""C" and "A" share no channel: a card connects on pipe and wire, a tile on wire"#)
        expectEqual(error["hint"], "channel: none draws a plain arrow between them anyway")
        expectEqual(error["line"], 1)
        let plain = try drawn(#"edge "C" -> "A" channel: none"#, on: editor)
        expectEqual(links(in: editor), ["C -> A"])
        expectEqual(edgeRows(plain).first?["channel"], nil, "no channel to say")
    },
    test("between kinds with no ports at all, an edge is plain without asking") {
        let editor = try edgesEditor(cards: false)
        _ = try drawn(board, on: editor)
        _ = try drawn(#"edge "C" -> "D""#, on: editor)
        expectEqual(links(in: editor), ["C -> D"])
        expectEqual(try refused(#"edge "C" -> "A""#, on: editor)["reason"], "no_channel", "a tile has ports, so it isn't plain by itself")
    },
    test("written, the channel must be declared, dotted on the start's kind and taken by the end's") {
        let editor = try edgesEditor()
        _ = try drawn(board, on: editor)
        let undeclared = try refused(#"edge "A" -> "B" channel: gas"#, on: editor)
        expectEqual(undeclared["reason"], "invalid_value")
        expectEqual(undeclared["hint"], "channel: takes wire|pipe|none")
        let pipe = try refused(#"edge "A" -> "B" channel: pipe"#, on: editor)
        expectEqual(pipe["reason"], "no_channel")
        expectEqual(pipe["message"], #""A" -> "B" can't be on pipe: a tile has wire ports on its top, right, bottom and left"#)
        let backwards = try refused(#"edge "C" -> "A" channel: wire"#, on: editor)
        expectEqual(backwards["reason"], "no_channel", "a card takes the wire, but has no dot on it to start one")
        _ = try drawn(#"edge "A" -> "C" channel: wire"#, on: editor)
        expectEqual(links(in: editor), ["A -> C on wire"])
    },
    test("a side named where the kind has no port: invalid_value with the channel written, no_channel with it worked out") {
        let editor = try edgesEditor()
        _ = try drawn(board, on: editor)
        let written = try refused(#"edge "C" -> "D" channel: pipe from: left"#, on: editor)
        expectEqual(written["reason"], "invalid_value")
        expectEqual(written["message"], "from: left: a card has pipe ports on its right and bottom")
        expectEqual(written["hint"], "from: takes right|bottom")
        let worked = try refused(#"edge "C" -> "D" from: left"#, on: editor)
        expectEqual(worked["reason"], "no_channel")
        expect(worked["message"]?.stringValue?.hasPrefix(#""C" and "D" (from: left) share no channel: a card has pipe ports on its right and bottom"#) == true,
               "\(worked)")
        let target = try refused(#"edge "A" -> "C" to: right"#, on: editor)
        expectEqual(target["reason"], "no_channel", "a card takes the wire only on its left")
        _ = try drawn(#"edge "A" -> "C" from: bottom to: left"#, on: editor)
        expectEqual(links(in: editor), ["A -> C on wire aimed bottom left"])
    },
    test("a side named narrows the channels: the first left that the end takes") {
        let editor = try edgesEditor()
        _ = try drawn(board, on: editor)
        _ = try drawn(#"edge "C" -> "D" from: bottom to: right"#, on: editor)
        expectEqual(links(in: editor), ["C -> D on pipe aimed bottom right"])
    },
    test("an edge on a channel can't end where it starts; a plain one can") {
        let editor = try edgesEditor()
        _ = try drawn(board, on: editor)
        let loop = try refused(#"edge "A" -> "A""#, on: editor)
        expectEqual(loop["reason"], "no_channel")
        expectEqual(loop["message"], "a connection on wire can't end where it starts")
        _ = try drawn(#"edge "A" -> "A" channel: none"#, on: editor)
        expectEqual(links(in: editor), ["A -> A"])
    },
    test("an end the connector can't connect is cannot_connect, naming it") {
        let editor = try edgesEditor()
        _ = try drawn(board, on: editor)
        _ = try drawn(#"tile "B" finish: glossy"#, on: editor)
        let error = try refused(#"edge "A" -> "B""#, on: editor)
        expectEqual(error["reason"], "cannot_connect")
        expect(error["message"]?.stringValue?.hasPrefix(#""B" can't be connected"#) == true, "\(error)")
        expectEqual(links(in: editor), [])
    },
    test("either end may be new in the script: the connector asks of the board as the script leaves it") {
        let editor = try edgesEditor()
        _ = try drawn(board, on: editor)
        _ = try drawn("""
            tile "E" right of "B"
            edge "B" -> "E"
            """, on: editor)
        expectEqual(links(in: editor), ["B -> E on wire"])
    },
])

@MainActor let upsertTests = Suite("An edge drawn again", [
    test("written again as it is, it's unchanged; named sides or other heads change it, and nothing else") {
        let requests = Requests()
        let editor = try edgesEditor(requests)
        _ = try drawn(board, on: editor)
        _ = try drawn(#"edge "A" -> "B""#, on: editor)
        let again = try drawn(#"edge "A" -> "B""#, on: editor)
        expectEqual(edgeRows(again).map { $0["did"] }, ["unchanged"])
        let aimed = try drawn(#"edge "A" -> "B" from: right"#, on: editor)
        expectEqual(edgeRows(aimed).map { $0["did"] }, ["reconnected"])
        expectEqual(links(in: editor), ["A -> B on wire aimed right -"])
        let both = try drawn(#"edge "A" <-> "B" to: left"#, on: editor)
        expectEqual(edgeRows(both).map { $0["did"] }, ["reconnected"])
        expectEqual(links(in: editor), ["A -> B on wire aimed right left both heads"])
        expectEqual(requests.made.last?.channel, Wire.id, "asked on the channel it's on")
        let one = try drawn(#"edge "A" -> "B""#, on: editor)
        expectEqual(edgeRows(one).map { $0["did"] }, ["reconnected"], "-> takes the start's head away")
        expectEqual(links(in: editor), ["A -> B on wire aimed right left"])
    },
    test("it keeps its channel: another written is invalid_value, with the hint to delete it first; the same is fine") {
        let editor = try edgesEditor()
        _ = try drawn(board, on: editor)
        _ = try drawn(#"edge "A" -> "B""#, on: editor)
        let other = try refused(#"edge "A" -> "B" channel: none"#, on: editor)
        expectEqual(other["reason"], "invalid_value")
        expectEqual(other["message"], #"the edge from "A" to "B" is on wire, not plain, on no channel"#)
        expectEqual(other["hint"], #"delete edge "A" -> "B" above this line to draw it plain, on no channel"#)
        expectEqual(edgeRows(try drawn(#"edge "A" -> "B" channel: wire"#, on: editor)).map { $0["did"] }, ["unchanged"])
        _ = try drawn("""
            delete edge "A" -> "B"
            edge "A" -> "B" channel: none
            """, on: editor)
        expectEqual(links(in: editor), ["A -> B"])
        let plain = try refused(#"edge "A" -> "B" from: top channel: wire"#, on: editor)
        expectEqual(plain["reason"], "invalid_value", "a plain one stays plain")
        _ = try drawn(#"edge "A" -> "B" from: top"#, on: editor)
        expectEqual(links(in: editor), ["A -> B aimed top -"], "a plain edge leaves by any side")
    },
    test("a side it names must have a port on its channel") {
        let editor = try edgesEditor()
        _ = try drawn(board, on: editor)
        _ = try drawn(#"edge "C" -> "D""#, on: editor)
        expectEqual(try refused(#"edge "C" -> "D" from: top"#, on: editor)["reason"], "no_channel")
        expectEqual(try refused(#"edge "C" -> "D" from: top channel: pipe"#, on: editor)["reason"], "invalid_value")
    },
    test("<-> finds an edge drawn the other way, and asks in its direction") {
        let requests = Requests()
        let editor = try edgesEditor(requests)
        _ = try drawn(board, on: editor)
        _ = try drawn(#"edge "B" -> "A""#, on: editor)
        let result = try drawn(#"edge "A" <-> "B""#, on: editor)
        expectEqual(edgeRows(result).map { $0["did"] }, ["reconnected"])
        expectEqual(links(in: editor), ["B -> A on wire both heads"])
    },
])

@MainActor let edgesPointTests = Suite("What the bridge tells canvas draw", [
    test("canvas kinds lists the channels an edge may leave each kind by, side by side") {
        let editor = try edgesEditor()
        let kinds = try run(["kinds"], on: editor).get().arrayValue ?? []
        func edges(_ kind: ShapeKind) -> JSON? { kinds.first { $0["kind"]?.stringValue == kind.rawValue }?["edges"] }
        expectEqual(edges(Tile.kind), ["top": ["wire"], "right": ["wire"], "bottom": ["wire"], "left": ["wire"]])
        expectEqual(edges(Card.kind), ["right": ["pipe"], "bottom": ["pipe"]], "no dot where it only takes the wire")
        expectEqual(edges(Box.kind), nil)
        let link = kinds.first { $0["kind"]?.stringValue == Link.kind.rawValue }
        expectEqual(link?["drawable"], false)
        expect(link?["why"]?.stringValue?.contains("edge") == true, "links are edges")
    },
    test("with a connector that only draws from a port, or without the bridge, there are no edges") {
        let dragOnly = try edgesEditor(makes: false)
        _ = try drawn(board, on: dragOnly)
        expectEqual(try refused(#"edge "A" -> "B""#, on: dragOnly)["reason"], "no_edges")
        let none = try edgesEditor(bridge: false)
        _ = try drawn(board, on: none)
        expectEqual(try refused(#"edge "A" -> "B""#, on: none)["reason"], "no_edges")
    },
    test("deleting a shape deletes the connections the connector says end on it") {
        let editor = try edgesEditor()
        _ = try drawn(board, on: editor)
        _ = try drawn("""
            edge "A" -> "B"
            edge "C" -> "D"
            """, on: editor)
        let result = try drawn(#"delete "B""#, on: editor)
        expectEqual(links(in: editor), ["C -> D on pipe"])
        expectEqual(result["changes"]?.arrayValue?.map { $0["did"] }, ["deleted", "deleted"])
    },
])
