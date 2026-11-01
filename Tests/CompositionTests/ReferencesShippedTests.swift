import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import Clipboard
import Connections
import CoreGraphics
import Foundation
import Frames
import Geometry
import LanguageModels
import Mentions
import Publishing
import Queries
import References
import Selection
import ShippedTesting
import StickyNotes
import Subboards
import SwiftUI
import TableOfContents
import TestKit
import Topology
import Validation

// References as shipped: its tool, a note's arrow into a pill read as an arrow into what it stands
// for (the graph, a query, the table of contents), what copy, cut and paste do to it, another file's,
// and what `canvas draw` makes of one.

@MainActor private func emptyBoard(_ pasteboard: NSPasteboard) -> EditorHarness {
    EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0, pasteboard: pasteboard, model: ScriptedLanguageModel()) }
}

@MainActor private func note(_ h: EditorHarness, _ title: String, at origin: CGPoint, isPublic: Bool = false) -> ShapeID {
    let id = h.editor.add(StickyNote(frame: CGRect(origin: origin, size: CGSize(width: 200, height: 200)), text: MentionText(plain: title)), title: title)
    if isPublic { h.editor.makePublic([id]) }
    return id
}

/// A channel-less arrow from `from` to `to`, bound at the middle of each: what a script of edges
/// can't make (no arrow tool exists), and a port drag always puts on a channel.
@MainActor private func arrow(_ h: EditorHarness, from: ShapeID, to: ShapeID) -> ShapeID {
    func bound(_ id: ShapeID) -> ArrowTerminal {
        .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
    }
    return h.editor.add(Arrow(start: bound(from), end: bound(to)))
}

@MainActor private func reference(_ h: EditorHarness, to target: ShapeID, label: String, at origin: CGPoint) -> ShapeID {
    var props = Reference(frame: CGRect(origin: origin, size: Reference.defaultSize))
    ReferenceEdits.pick(&props, ReferenceTarget(id: target, label: label))
    return h.editor.add(props)
}


/// A dot of a shape, 12 points out from the middle of a side: the right one's by default.
private func rightDot(of frame: CGRect) -> CGPoint { CGPoint(x: frame.maxX + 12, y: frame.midY) }

/// Hovers the shape at `frame`, then drags from its right dot to `point` and releases, as a person does.
@MainActor private func drag(_ h: EditorHarness, fromRightOf frame: CGRect, to point: CGPoint) {
    h.move(to: CGPoint(x: frame.midX, y: frame.midY))
    h.move(to: rightDot(of: frame))
    h.press()
    h.drag(to: point, speed: 3)
    h.release()
}

@MainActor private func frame(of id: ShapeID, in h: EditorHarness) throws -> CGRect {
    try require(h.editor.shapeContext.geometry(of: id)?.bounds)
}

@MainActor private func arrows(_ h: EditorHarness) -> [ShapeRecord<Arrow>] {
    h.editor.document.shapes.compactMap { $0.typed(as: Arrow.self) }
}

@MainActor private func subboard(_ h: EditorHarness, _ title: String, at origin: CGPoint, isPublic: Bool = true) -> ShapeID {
    let id = h.editor.add(Subboard(frame: CGRect(origin: origin, size: Subboard.defaultSize)), title: title)
    if isPublic { h.editor.makePublic([id]) }
    return id
}

/// A frame, which takes frame links and no note link.
@MainActor private func frameShape(_ h: EditorHarness, _ title: String, at origin: CGPoint, isPublic: Bool = true) -> ShapeID {
    let id = h.editor.add(Frame(frame: CGRect(origin: origin, size: CGSize(width: 240, height: 160))), title: title)
    if isPublic { h.editor.makePublic([id]) }
    return id
}

@MainActor let referencesShippedTests = Suite("References, as shipped", [
    test("R is the Reference tool's key, after the Frame tool") {
        let h = emptyBoard(.withUniqueName())
        expect(h.key("r"))
        expectEqual(h.editor.currentToolID, ToolID(placing: Reference.kind))
    },
    test("an arrow into a pill is an arrow into what it stands for: in the graph, in a query, with the stand-in named") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = emptyBoard(pasteboard)
        let shapes = note(h, "shapes", at: CGPoint(x: 100, y: 100), isPublic: true)
        let stickies = note(h, "stickies", at: CGPoint(x: 100, y: 400))
        let pill = reference(h, to: shapes, label: "shapes", at: CGPoint(x: 500, y: 300))
        let into = arrow(h, from: stickies, to: pill)
        let topology = try require(h.editor.topology)
        let resolved = try require(topology.edges(of: shapes, .incoming, types: .within(ArrowEdge.id)).first)
        expectEqual(resolved.source, stickies)
        expectEqual(resolved.literalTarget, pill, "drawn into the pill")
        expectEqual(resolved.carrier, into)
        let queries = try require(h.editor.queries)
        let rows = try storyAnswer(#"arrow:ends-at("shapes")"#, on: queries).get().rows
        expectEqual(rows.map(\.id), [into], "the arrow ends at what the pill stands for")
        expectEqual(rows.first?.connection?.to.id, shapes)
        expectEqual(rows.first?.connection?.via?.to?.id, pill, "through the pill")
        expectEqual(try storyAnswer(#"sticky-note:edge-to("shapes")"#, on: queries).get().rows.map(\.id), [stickies])
        expectEqual(try storyAnswer(#"sticky-note:connected-to("shapes")"#, on: queries).get().rows.map(\.id), [stickies])
        // The shape holds public what stands for it: refused, and nothing written.
        expectEqual(h.editor.makePrivate([shapes]), [shapes])
        expect(h.editor.publishing?.isHeld(shapes) == true)
        // Not public any more (an unguarded path), the arrow is into the pill again.
        h.editor.transact { $0.update(shapes) { $0[PublicProperty.self] = nil } }
        expectEqual(try storyAnswer(#"arrow:ends-at("shapes")"#, on: queries).get().rows.map(\.id), [], "a private shape isn't stood for")
    },
    test("a port drag from a note ends on a pill standing for a note, and not on one standing for a frame: the pill takes what it stands for takes") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = emptyBoard(pasteboard)
        let orders = note(h, "orders", at: CGPoint(x: 100, y: 100), isPublic: true)
        let stickies = note(h, "stickies", at: CGPoint(x: 100, y: 400))
        let order = frameShape(h, "Order", at: CGPoint(x: 100, y: 700))
        let forNote = reference(h, to: orders, label: "orders", at: CGPoint(x: 500, y: 100))
        let forCard = reference(h, to: order, label: "Order", at: CGPoint(x: 500, y: 300))
        let from = try frame(of: stickies, in: h)
        drag(h, fromRightOf: from, to: try frame(of: forCard, in: h).center)
        expect(arrows(h).isEmpty, "a frame takes no note links: nothing is drawn")
        drag(h, fromRightOf: from, to: try frame(of: forNote, in: h).center)
        let drawn = try require(arrows(h).first)
        expectEqual(arrows(h).count, 1)
        expectEqual(drawn.props.start.binding?.shapeID, stickies)
        expectEqual(drawn.props.end.binding?.shapeID, forNote)
        expectEqual(drawn[ChannelProperty.self], NoteLink.id, "the pill's note-link, as a drag to the note itself would draw")
        // The same pill standing for the frame instead: its arrow is let be, and its panel says why it's wrong.
        h.editor.transact { $0.update(forNote, as: Reference.self) { ReferenceEdits.pick(&$0.props, ReferenceTarget(id: order, label: "Order")) } }
        expectEqual(h.editor.references?.channelMismatch(of: forNote), ChannelMismatch(channel: NoteLink.id, target: order))
        expectEqual(h.editor.references?.mismatchLine(of: forNote), "“Order” doesn’t take note links.")
        expectEqual(drawn.id, arrows(h).first?.id, "the arrow is let be")
    },
    test("a pill that stands for a subboard draws as the subboard does: its dots in the subboard's color, a subboard-link to a subboard and a note-link to a note, and what's drawn into it on the same channels") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = emptyBoard(pasteboard)
        let backend = subboard(h, "Backend", at: CGPoint(x: 100, y: 100))
        let frontend = subboard(h, "Frontend", at: CGPoint(x: 900, y: 100), isPublic: false)
        let orders = note(h, "orders", at: CGPoint(x: 900, y: 350), isPublic: true)
        let forSubboard = reference(h, to: backend, label: "Backend", at: CGPoint(x: 400, y: 100))
        let forNote = reference(h, to: orders, label: "orders", at: CGPoint(x: 400, y: 300))
        // A dot lit is its channel's color at full strength, whatever's under it.
        let size = CGSize(width: 1200, height: 800)
        @MainActor func litDot(of id: ShapeID) throws -> [Int] {
            let frame = try frame(of: id, in: h)
            h.move(to: frame.center)
            h.move(to: rightDot(of: frame))
            return pixel(renderBitmap(h.editor, size: size), at: rightDot(of: frame))
        }
        let subboardDot = try litDot(of: backend), noteDot = try litDot(of: orders)
        expectEqual(try litDot(of: forSubboard), subboardDot, "the pill's dot is the subboard's")
        expectEqual(try litDot(of: forNote), noteDot, "and a pill for a note's, the note's")
        expect(subboardDot != noteDot, "which are two colors")

        // From the pill, on the channel the shape it ends on takes, first of the subboard's: its own.
        let pill = try frame(of: forSubboard, in: h)
        drag(h, fromRightOf: pill, to: try frame(of: frontend, in: h).center)
        drag(h, fromRightOf: pill, to: try frame(of: orders, in: h).center)
        expectEqual(arrows(h).map { [$0.props.start.binding?.shapeID, $0.props.end.binding?.shapeID] },
                    [[forSubboard, frontend], [forSubboard, orders]])
        expectEqual(arrows(h).map { $0[ChannelProperty.self] }, [SubboardLink.id, NoteLink.id])
        // Into the pill, as into the subboard: from a subboard and a note, each on its own.
        let from = [frontend, orders]
        for id in from { drag(h, fromRightOf: try frame(of: id, in: h), to: pill.center) }
        expectEqual(arrows(h).dropFirst(2).map { [$0.props.start.binding?.shapeID, $0.props.end.binding?.shapeID] }, from.map { [$0, forSubboard] })
        expectEqual(arrows(h).dropFirst(2).map { $0[ChannelProperty.self] }, [SubboardLink.id, NoteLink.id])
    },
    test("an arrow drawn by hand into a pill reads as into the original: the graph, a query, with the pill named, and the table of contents under it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = emptyBoard(pasteboard)
        let orders = note(h, "orders", at: CGPoint(x: 100, y: 100), isPublic: true)
        let stickies = note(h, "stickies", at: CGPoint(x: 100, y: 400))
        let target = note(h, "target", at: CGPoint(x: 700, y: 500))
        let pill = reference(h, to: orders, label: "orders", at: CGPoint(x: 500, y: 100))
        drag(h, fromRightOf: try frame(of: stickies, in: h), to: try frame(of: pill, in: h).center)
        let into = try require(arrows(h).first?.id)
        let topology = try require(h.editor.topology)
        let resolved = try require(topology.edges(of: orders, .incoming, types: .within(ArrowEdge.id)).first)
        expectEqual(resolved.source, stickies)
        expectEqual(resolved.type, EdgeTypeID(rawValue: String(describing: NoteLink.id)), "typed as its channel, as a drag to the note would be")
        expectEqual(resolved.literalTarget, pill)
        expectEqual(resolved.carrier, into)
        let queries = try require(h.editor.queries)
        let rows = try storyAnswer(#"arrow:ends-at("orders")"#, on: queries).get().rows
        expectEqual(rows.map(\.id), [into])
        expectEqual(rows.first?.connection?.to.id, orders)
        expectEqual(rows.first?.connection?.via?.to?.id, pill)
        expectEqual(try storyAnswer(#"sticky-note:edge-to("orders")"#, on: queries).get().rows.map(\.id), [stickies])
        // And out of it: from the pill's dot, to a note; its row is listed under the original.
        drag(h, fromRightOf: try frame(of: pill, in: h), to: try frame(of: target, in: h).center)
        let out = try require(arrows(h).first { $0.id != into })
        expectEqual(out.props.start.binding?.shapeID, pill)
        expectEqual(out.props.end.binding?.shapeID, target)
        expectEqual(out[ChannelProperty.self], NoteLink.id)
        let outgoing = try require(topology.edges(of: target, .incoming, types: .within(ArrowEdge.id)).first)
        expectEqual(outgoing.source, orders, "an arrow from the pill runs from what it stands for")
        expectEqual(outgoing.literalSource, pill)
        let contents = try require(h.editor.tableOfContents)
        let under = contents.entries.first { $0.id == orders }?.children?.map(\.id)
        expectEqual(under, [out.id], "its row is under the original")
    },
    test("an arrow that starts at a pill is listed under what the pill stands for, where that is on the board shown; else under the pill") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = emptyBoard(pasteboard)
        let shapes = note(h, "shapes", at: CGPoint(x: 100, y: 100), isPublic: true)
        let other = note(h, "other", at: CGPoint(x: 100, y: 400), isPublic: true)
        let target = note(h, "target", at: CGPoint(x: 700, y: 100))
        let pill = reference(h, to: shapes, label: "shapes", at: CGPoint(x: 500, y: 300))
        let out = arrow(h, from: pill, to: target)
        let contents = try require(h.editor.tableOfContents)
        @MainActor func parent(of id: ShapeID) -> ShapeID? {
            func find(_ entries: [ContentsEntry], under: ShapeID?) -> ShapeID?? {
                for entry in entries {
                    if entry.id == id { return .some(under) }
                    if let found = find(entry.children ?? [], under: entry.id) { return found }
                }
                return nil
            }
            return find(contents.entries, under: nil) ?? nil
        }
        expectEqual(parent(of: out), shapes, "the arrow reads as starting from the shape the pill stands for")
        expectEqual(parent(of: pill), nil, "the pill's own row stays where it is")
        h.editor.transact { $0.update(pill, as: Reference.self) { ReferenceEdits.pick(&$0.props, ReferenceTarget(id: other, label: "other")) } }
        expectEqual(parent(of: out), other, "re-pointed, its row moves in the same commit")
        h.editor.transact { $0.update(other) { $0[PublicProperty.self] = nil } }
        expectEqual(parent(of: out), pill, "a private shape isn't stood for: under the pill, as for any shape")
        h.editor.undo()
        expectEqual(parent(of: out), other)
    },
    test("an arrow's row under a shape that isn't on the board shown stays under the pill") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = emptyBoard(pasteboard)
        let target = note(h, "target", at: CGPoint(x: 700, y: 100))
        let subboard = h.editor.add(Subboard(frame: CGRect(x: 100, y: 500, width: 240, height: 160)))
        expect(h.editor.showBoard(BoardID(owner: subboard)))
        let inside = note(h, "inside", at: CGPoint(x: 100, y: 100), isPublic: true)
        expect(h.editor.showBoard(.root))
        let pill = reference(h, to: inside, label: "inside", at: CGPoint(x: 500, y: 300))
        let out = arrow(h, from: pill, to: target)
        let entries = try require(h.editor.tableOfContents).entries
        expectEqual(entries.first { $0.id == pill }?.children?.map(\.id), [out], "the shape is on another board, so the pill keeps it")
    },
    test("copy, cut and paste, as the behavior table says: alone it names the same original; with it, the copy; a cut original is missing until it's pasted, with its id") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = emptyBoard(pasteboard)
        let shapes = note(h, "shapes", at: CGPoint(x: 100, y: 100), isPublic: true)
        let pill = reference(h, to: shapes, label: "shapes", at: CGPoint(x: 500, y: 300))
        let state = try require(h.editor.references)
        // R alone: a second reference to the same shape.
        h.editor.selectedShapeIDs = [pill]
        h.editor.copySelection()
        var before = h.editor.document
        h.editor.paste()
        let alone = try require(h.editor.shapes(since: before).first)
        expectEqual(alone.typed(as: Reference.self)?.props.target, ReferenceTarget(id: shapes, label: "shapes"))
        expectEqual(state.directReferences(naming: [shapes]), [pill, alone.id])
        // R with A: the copy names the copy of A, which is public too.
        h.editor.selectedShapeIDs = [shapes, pill]
        h.editor.copySelection()
        before = h.editor.document
        h.editor.paste()
        let copies = h.editor.shapes(since: before)
        let copyOfShapes = try require(copies.first { $0.copiedFrom == shapes }?.id)
        let copyOfPill = try require(copies.first { $0.copiedFrom == pill }?.typed(as: Reference.self))
        expectEqual(copyOfPill.props.target?.id, copyOfShapes, "renamed with what was copied along")
        expect(h.editor.document[copyOfShapes]?[PublicProperty.self] == true, "pasted public, as every added property is")
        // A cut and pasted keeps its id, so a reference to it heals.
        h.editor.selectedShapeIDs = [shapes]
        h.editor.cutSelection()
        expect(h.editor.document[shapes] == nil)
        expectEqual(h.editor.references?.state(of: pill), .missing(label: "shapes"), "between cut and paste, missing")
        h.editor.paste()
        expect(h.editor.document[shapes] != nil, "pasted with its id")
        expect(h.editor.references?.state(of: pill)?.appearance != nil, "healed")
        // R cut and pasted keeps its target.
        h.editor.selectedShapeIDs = [pill]
        h.editor.cutSelection()
        h.editor.paste()
        let pasted = try require(h.editor.selectedShapeIDs.first.flatMap { h.editor.document[$0]?.typed(as: Reference.self) })
        expectEqual(pasted.props.target?.id, shapes)
    },
    test("pasted into another file, a direct reference names what isn't there: missing, dashed, with the name it held") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = emptyBoard(pasteboard)
        let shapes = note(h, "shapes", at: CGPoint(x: 100, y: 100), isPublic: true)
        let pill = reference(h, to: shapes, label: "shapes", at: CGPoint(x: 500, y: 300))
        h.editor.selectedShapeIDs = [pill]
        h.editor.copySelection()
        let other = emptyBoard(pasteboard)
        other.editor.paste()
        let pasted = try require(other.editor.selectedShapeIDs.first)
        expectEqual(other.editor.references?.state(of: pasted), .missing(label: "shapes"))
        expectEqual(other.editor.topology?.forwarding(of: pasted), .record([]))
    },
    test("canvas draw makes a reference from a query: 120 by 32 or as wide as it says; a query the app can't read is refused, and what a script can't write is unknown") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = emptyBoard(pasteboard)
        let drawn = try drawnInProcess(#"reference query: "sticky-note" all: true"#, on: h.editor)
        _ = drawn
        let made = try require(h.editor.document.shapes.first { $0.kind == Reference.kind }?.typed(as: Reference.self))
        expectEqual(made.props.query, "sticky-note")
        expectEqual(made.props.all, true)
        expectEqual(made.props.target, nil)
        expectEqual(made.frame.height, 32)
        expectEqual(made.frame.width, ReferenceEdits.width(of: made.props), "fitted as the writers fit it")
        let bad = try refusedInProcess(#"reference query: "sticky-note[""#, on: h.editor)
        expectEqual(bad.reason, "invalid_value", "\(bad)")
        expectEqual(try refusedInProcess(#"reference words: "x""#, on: h.editor).reason, "unknown_attribute")
        expectEqual(try refusedInProcess(#"reference target: "x""#, on: h.editor).reason, "unknown_attribute")
        expectEqual(h.editor.document.shapes.filter { $0.kind == Reference.kind }.count, 1, "nothing else was drawn")
    },
    test("a drawn query stands for what it finds, public notes alone; a query that reads edges, run just after, waits for the answer and reads through it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        // Real time: the answer comes after the wait for quiet, as in the app.
        let h = EditorHarness { _ in ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: TaskScheduler(), pasteboard: pasteboard, model: ScriptedLanguageModel()) }
        let auth = note(h, "Auth", at: CGPoint(x: 0, y: 0), isPublic: true)
        let login = note(h, "Login", at: CGPoint(x: 300, y: 0), isPublic: true)
        _ = note(h, "Draft", at: CGPoint(x: 600, y: 0))
        let checkout = note(h, "Checkout", at: CGPoint(x: 0, y: 400))
        _ = try drawnInProcess(#"reference right of "Checkout" query: "sticky-note[public]" all: true"#, on: h.editor)
        let pill = try require(h.editor.document.shapes.first { $0.kind == Reference.kind }?.id)
        _ = arrow(h, from: checkout, to: pill)
        let topology = try require(h.editor.topology), queries = try require(h.editor.queries)
        expect(topology.isSettling, "drawn and wired, its answer is on its way")
        let result = try awaitResult { try await queries.run(QueryRequest(#"sticky-note:edge-to("Login")"#, settle: QueryBudget.settleWait)) }
        expectEqual(result.rows.map(\.id), [checkout], "the arrow into the pill reads as into each note it stands for")
        expectEqual(result.warnings, [], "nothing pending: it waited")
        expectEqual(topology.forwards(of: pill), [auth, login])
        guard case .found(_, let found)? = h.editor.references?.state(of: pill) else { return expect(false, "found") }
        expectEqual(found.count, 2)
    },
    test("a script names a reference drawn by its query by the id its row gives: an edge into it, a run again, its query restated, its delete; :edge-from(#id, stands-for) says what it stands for") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        // Real time: the answer comes after the wait for quiet, as in the app.
        let h = EditorHarness { _ in ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: TaskScheduler(), pasteboard: pasteboard, model: ScriptedLanguageModel()) }
        let auth = note(h, "Auth", at: CGPoint(x: 0, y: 0), isPublic: true)
        let login = note(h, "Login", at: CGPoint(x: 300, y: 0), isPublic: true)
        _ = note(h, "Draft", at: CGPoint(x: 600, y: 0))
        let checkout = note(h, "Checkout", at: CGPoint(x: 0, y: 400))
        let made = try drawnInProcess(#"reference right of "Checkout" query: "sticky-note[public]" all: true"#, on: h.editor)
        let pill = try require(h.editor.document.shapes.first { $0.kind == Reference.kind }?.id)
        expectEqual(made["changes"]?.arrayValue?.first?["id"], .string(pill.description), "its row gives the id a later script names it by")
        let mark = "#\(pill)"
        let edge = try drawnInProcess("edge \"Checkout\" -> \(mark)", on: h.editor)
        let row = try require(edge["changes"]?.arrayValue?.first)
        expectEqual(row["did"], "connected")
        expectEqual(row["from"], "Checkout")
        expectEqual(row["to"], .string(mark), "called by the id as written")
        expectEqual(row["toId"], .string(pill.description))
        expectEqual(row["via"], nil, "drawn straight into it: no reference is made for a reference")
        expectEqual(row["channel"], "note-link", "a pill takes every channel, so the note's own")
        expectEqual(h.editor.document.shapes.filter { $0.kind == Reference.kind }.count, 1)
        // What it stands for, and an arrow into it read as into each: both wait for its answer.
        let queries = try require(h.editor.queries)
        let stands = try awaitResult { try await queries.run(QueryRequest(":edge-from(\(mark), stands-for)", settle: QueryBudget.settleWait)) }
        expectEqual(stands.rows.map(\.id), [auth, login], "the public notes, in file order: Draft isn't public")
        expectEqual(stands.warnings, [], "nothing pending: it waited")
        let through = try awaitResult { try await queries.run(QueryRequest(#"sticky-note:edge-to("Login")"#, settle: QueryBudget.settleWait)) }
        expectEqual(through.rows.map(\.id), [checkout], "the arrow into the pill reads as into each note it stands for")
        // Again, it's the edge.
        let again = try drawnInProcess("edge \"Checkout\" -> \(mark)", on: h.editor)
        expectEqual((again["changes"]?.arrayValue ?? []).map { $0["did"] }, ["unchanged"])
        // Restated by its id: the first match only.
        let restated = try drawnInProcess("reference \(mark) all: false", on: h.editor)
        expectEqual(restated["changes"]?.arrayValue?.first?["did"], "updated")
        expectEqual(h.editor.document[pill]?.typed(as: Reference.self)?.props.all, false)
        let first = try awaitResult { try await queries.run(QueryRequest(":edge-from(\(mark), stands-for)", settle: QueryBudget.settleWait)) }
        expectEqual(first.rows.map(\.id), [auth], "the first in file order")
        // A reference picked for one shape is still named by that shape, not its id.
        let direct = reference(h, to: auth, label: "Auth", at: CGPoint(x: 0, y: 800))
        expectEqual(try refusedInProcess("edge \"Checkout\" -> #\(direct)", on: h.editor).reason, "invalid_value")
        // Its delete takes the arrow into it.
        _ = try drawnInProcess("delete \(mark)", on: h.editor)
        expectEqual(h.editor.document[pill], nil)
        expect(!h.editor.document.shapes.contains { $0.kind == Arrow.kind }, "the arrow into it went with it")
        expect(h.editor.document[checkout] != nil && h.editor.document[auth] != nil)
    },
    test("a query whose notes aren't public stands for none and says how many; Make Public in its panel makes them public in one step, and the arrow into it then reaches each") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = emptyBoard(pasteboard)
        let billing = (0..<3).map { note(h, "Billing \($0)", at: CGPoint(x: CGFloat($0) * 300, y: 0)) }
        let checkout = note(h, "Checkout", at: CGPoint(x: 0, y: 400))
        var props = Reference(frame: CGRect(origin: CGPoint(x: 400, y: 400), size: Reference.defaultSize), all: true)
        ReferenceEdits.find(&props, words: "billing notes", query: #"sticky-note:contains("billing")"#)
        let pill = h.editor.add(props)
        _ = arrow(h, from: checkout, to: pill)
        let state = try require(h.editor.references)
        h.wait(0)
        _ = spinRunLoop(until: { !state.isFinding })
        expectEqual(state.state(of: pill), .privateMatches(text: "billing notes", count: 3), "new notes start private")
        let held = try require(h.editor.document[pill]?.typed(as: Reference.self)?.props)
        expectEqual(state.header(of: held, id: pill).subtitle, "Not public")
        expectEqual(state.queryContent(of: held, id: pill).status?.text, "3 not public")
        expectEqual(h.editor.topology?.forwards(of: pill), [])
        state.makeMatchesPublic(of: pill)
        _ = spinRunLoop(until: { billing.allSatisfy { h.editor.document[$0]?[PublicProperty.self] == true } })
        expectEqual(h.editor.undoHistory.undoName, "Make Public")
        h.wait(250)
        _ = spinRunLoop(until: { !state.isFinding })
        expectEqual(h.editor.topology?.forwards(of: pill), billing)
        let queries = try require(h.editor.queries)
        let result = try awaitResult { try await queries.run(QueryRequest(#"sticky-note:edge-to("Billing 2")"#, settle: QueryBudget.settleWait)) }
        expectEqual(result.rows.map(\.id), [checkout], "the arrow into the pill reads as into each")
    },
    test("a reference may search notes' text (mention text reads only the file), and not what the person has selected") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = emptyBoard(pasteboard)
        let auth = h.editor.add(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: MentionText(plain: "JWT, 15 min expiry")), title: "Auth")
        h.editor.makePublic([auth])
        _ = note(h, "Checkout", at: CGPoint(x: 300, y: 0), isPublic: true)
        @MainActor func pill(_ query: String, at x: CGFloat) -> ShapeID {
            var props = Reference(frame: CGRect(origin: CGPoint(x: x, y: 400), size: Reference.defaultSize))
            ReferenceEdits.find(&props, words: "", query: query)
            return h.editor.add(props)
        }
        let text = pill(#"sticky-note:contains("jwt")"#, at: 0)
        let selected = pill("sticky-note:selected", at: 300)
        h.wait(0)
        let state = try require(h.editor.references)
        _ = spinRunLoop(until: { !state.isFinding })
        expectEqual(h.editor.topology?.forwards(of: text), [auth])
        expectEqual(state.status(of: selected), .refused("“:selected” can’t be used here."))
    },
    test("a query a reference can't use is warned of in its panel's issues: pasted, or written by hand into a board") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = emptyBoard(pasteboard)
        var props = Reference(frame: CGRect(origin: .zero, size: Reference.defaultSize))
        ReferenceEdits.find(&props, words: "", query: "sticky-note[")
        let pill = h.editor.add(props)
        let issues = try require(h.editor.validation?.result(for: pill)).issues
        expectEqual(issues.map(\.severity), [.warning])
        expectEqual(issues.first?.field, "query")
    },
    test("in the sidebar, a frame lists the shapes it holds, then its pills' rows under one closed \"References\" row with their count") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = emptyBoard(pasteboard)
        let originals = ["Canvas", "Geometry", "Selection"].enumerated().map { note(h, $1, at: CGPoint(x: 1000, y: 300 * $0), isPublic: true) }
        let layer = frameShape(h, "Product layer", at: .zero)
        let held = [subboard(h, "Arrows", at: CGPoint(x: 20, y: 20)), subboard(h, "Frames", at: CGPoint(x: 300, y: 20))]
            + zip(originals, ["Canvas", "Geometry", "Selection"]).enumerated().map { reference(h, to: $1.0, label: $1.1, at: CGPoint(x: 600, y: 40 * $0)) }
        h.editor.put(held, in: layer)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: TableOfContentsView(editor: h.editor))
        hosting.frame = CGRect(x: 0, y: 0, width: 300, height: 600)
        window.contentView = hosting
        window.settle()
        /// The list's rows, less its header, each indented two spaces a level.
        @MainActor func shown() -> [String] {
            guard let outline = hosting.descendants(NSOutlineView.self).first, outline.numberOfRows > 1 else { return [] }
            return (1..<outline.numberOfRows).map { String(repeating: "  ", count: outline.level(forRow: $0)) + String(describing: outline.item(atRow: $0)!) }
        }
        window.spin { shown().count == 7 }
        expectEqual(shown(), ["Product layer", "  Frames", "  Arrows", "  References · 3", "Selection", "Geometry", "Canvas"])
        let outline = try require(hosting.descendants(NSOutlineView.self).first)
        outline.expandItem(outline.item(atRow: 4))
        window.spin { shown().count == 10 }
        expectEqual(shown(), ["Product layer", "  Frames", "  Arrows", "  References · 3", "    Selection", "    Geometry", "    Canvas",
                              "Selection", "Geometry", "Canvas"])
    },
])
