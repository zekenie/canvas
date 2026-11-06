import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Draw
import Drawings
import Foundation
import Frames
import ShippedTesting
import SkillTesting
import TestKit
import Titles

// The four contracts of drawing a codebase hold at once, as one test: a plugin adds a property to frames, a lens sets it, `ingest`
// draws it, and the frame has it, with no file outside the plugin changed.
//
//   1. a plugin's kinds and attributes are what `canvas kinds` says (the app is the only place that knows them);
//   2. the render layer (canvas-digest) passes a node's `props` through unread: it never names an attribute;
//   3. a lens writes what it wants into `props` (lenskit's Graph checks structure, never attributes);
//   4. the app keeps the drawing's record in the file, by the drawing's name, and updates it by key.
//
// The test plugin below is the only code that knows `motto`; the test's lens is the only thing that sets it. Nothing in the app, canvas
// or the two skills names it, so a change that taught any of them about one attribute would fail here.

/// What a frame may say about itself: an added property of a plugin the shipped list has never heard of.
enum Motto {}
extension Motto: ShapeProperty {
    static let key: PropertyKey = "motto"
    static var defaultValue: String? { nil }
}

/// A plugin written inline, after the shipped list: declares the property and opts the shipped frame kind into it.
private let mottoPlugin = Contributor(id: "motto") { registrar in
    registrar.declare(Motto.self)
    registrar.optIn(Frame.self, to: Motto.self)
}

@MainActor let contractsTests = Suite("the four contracts: a plugin adds a property to frames, a lens sets it, ingest draws it, and the frame has it", [
    test("a test plugin's property on frames is listed by canvas kinds, set by a lens, passed through the render layer unread, drawn by ingest, and kept with the drawing's record in the file") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard, extra: [mottoPlugin])
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }

        // 1. the app says it: `canvas kinds` lists the attribute for frames, and for no other kind
        let kinds = try canvas(server, ["kinds"])
        expectEqual(kinds.status, 0, kinds.error)
        let listed = try JSON(text: kinds.output).arrayValue ?? []
        let attributes = { (kind: String) -> [String] in (listed.first { $0["kind"] == .string(kind) }?["attributes"]?.objectValue?.keys.sorted()) ?? [] }
        expect(attributes("frame").contains("motto"), "frame: \(attributes("frame"))")
        expect(!attributes("sticky-note").contains("motto"), "and only the kind that opted in: \(attributes("sticky-note"))")
        let one = try canvas(server, ["kinds", "frame"])
        expect(one.status == 0 && one.output.contains("motto"), one.output + one.error)

        // 3. a lens (a scratch repository's own) puts the attribute in a frame's props, as any attribute from `canvas kinds`
        let folder = try scratchFolder("contracts")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("cache")
        let repo = try makeRepository("repo", in: folder)
        let kept = try cacheFolder(of: repo, cache: cache)
        try putScan(tinyModel, in: kept)
        try write("""
            from lenskit import Graph

            def digest(scan, repo):
                g = Graph("contracts")
                home = g.node("frame:Home", "frame", {"title": "Home", "motto": "Carpe diem"})
                g.node("note:Hello", "sticky-note", {"title": "Hello", "text": "In the frame"}, in_=home)
                return g.finish()
            """, to: repo.appendingPathComponent(".canvas/lens.py"))
        let env = ingestEnvironment(cache: cache, socket: server.path)

        // 2. ingest draws it: the lens's document, the render layer's plan and the app's apply all carry the attribute without reading it
        let drawn = try ingest([repo.path, "--scan", handScan(kept)], environment: env)
        expectEqual(drawn.status, 0, drawn.output + drawn.error)
        expect(drawn.output.contains("applied contracts: shapes"), drawn.output)
        let run = try lastRun(in: kept)
        func props(_ file: String) throws -> JSON? {
            try json(run.appendingPathComponent(file))["nodes"]?.arrayValue?.first { $0["key"] == "frame:Home" }?["props"]
        }
        expectEqual(try props("graph.json")?["motto"], "Carpe diem", "the lens's document")
        expectEqual(try props("out/drawing.json")?["motto"], "Carpe diem", "the render layer's drawing, which it passed through")
        expectEqual(try props("graph.json"), try props("out/drawing.json"), "props untouched")

        // the frame has it
        let record = board.editor.file[DrawingsProperty.self].drawings["contracts"]
        let frameID = try require(record?.idsByKey["frame:Home"], "the frame is drawn")
        let frame = try require(board.editor.file.record(frameID), "the frame is in the file")
        expectEqual(frame.addedJSON(for: "motto"), "Carpe diem", "the frame has the property, as the plugin declared it")
        expectEqual(frame.propertiesJSON?["title"]?.stringValue ?? board.editor.registry.title(of: frame), "Home")

        // 4. the file keeps the drawing's record by its name, and drawing again updates it by key
        expectEqual(board.editor.file[DrawingsProperty.self].drawings.keys.sorted(), ["contracts"])
        expectEqual(record?.shapes.values.map(\.key).sorted(), ["frame:Home", "note:Hello"])
        let again = try ingest([repo.path, "--scan", handScan(kept)], environment: env)
        expectEqual(again.status, 0, again.output + again.error)
        expect(again.output.contains("unchanged"), again.output)
        expectEqual(board.editor.file[DrawingsProperty.self].drawings["contracts"]?.idsByKey["frame:Home"], frameID, "the same frame")
    },
])
