import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasRPC
import CanvasUI
import Foundation
import Publishing
import References
import ShippedTesting
import SkillTesting
import Subboards
import TestKit
import Titles
import Types

// The canvas-digest skill (.claude/skills/canvas-digest), end to end. The tool's own unit tests run under the system jsc (the runtime the
// skill is built for): SkillToolsTests. Here `digest all` runs as an agent runs it, with `canvas` as built (CANVAS_CLI) against this test's own
// command server (CANVAS_SOCKET), on the graph documents the tool's tests read (tool/test/fixtures/*.graph.json): the tool measures them with
// `canvas measure -`, lays them out into drawing.json, and `canvas apply -` draws it in one step. Each test holds the board to drawing.json:
// every node's shape where its `place.at` says, every edge an arrow or through a pill where the plan says, and what the app answered.

/// Whether to print what `digest` said in each run (DIGEST_DUMP=1).
private let dumpsDigest = ProcessInfo.processInfo.environment["DIGEST_DUMP"] == "1"

private func fixture(_ name: String) -> URL { digestSkill("tool/test/fixtures/\(name).graph.json") }

/// What the driver prints and where it put its files.
private struct DigestRun {
    let process: ProcessOutput
    let out: URL

    var said: String { process.output + process.error }
    var drawing: JSON { get throws { try json(out.appendingPathComponent("drawing.json")) } }
    var report: JSON { get throws { try json(out.appendingPathComponent("report.json")) } }
    var apply: JSON { get throws { try json(out.appendingPathComponent("results/apply.json")) } }
    var measure: JSON { get throws { try json(out.appendingPathComponent("measure.json")) } }
}

/// `digest <command> <graph>` as an agent runs it, for the server named; `canvas` is the one it runs, else `canvas` as built.
@MainActor private func runDigest(_ command: String, _ graph: URL, server: CommandServer, target: [String] = [], extra: [String] = [],
                                  out: URL, canvas: URL? = nil, timeout: TimeInterval = 280) throws -> DigestRun {
    let process = try run(digestSkill("digest"), [command, graph.path] + target + ["--out", out.path] + extra,
                          environment: ["CANVAS_CLI": (canvas ?? builtExecutable("CanvasCLI")).path, "CANVAS_SOCKET": server.path], timeout: timeout)
    if dumpsDigest { print("── digest \(command) \(graph.lastPathComponent)\n\(process.output)\(process.error)") }
    return DigestRun(process: process, out: out)
}

/// A graph document written to a file of the folder.
private func graphFile(_ name: String, _ value: JSON, in folder: URL) throws -> URL {
    let file = folder.appendingPathComponent("\(name).graph.json")
    try value.compactText.write(to: file, atomically: true, encoding: .utf8)
    return file
}

/// The driver as the skill is installed somewhere else: a copy in a folder of its own, three levels down, so that the repository it
/// looks in for `build/canvas` is the folder, which has none, and run from that folder. `canvas` is found only on the PATH, which is
/// `bin` in the folder (with `canvas` linked into it when `canvasOnPath`) and the system's; `CANVAS_CLI` is empty.
@MainActor private func runIsolatedDriver(_ arguments: [String], folder: URL, canvasOnPath: Bool, server: CommandServer) throws -> ProcessOutput {
    let fileManager = FileManager.default
    let home = folder.appendingPathComponent("skill/a/b")
    try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
    let driver = home.appendingPathComponent("digest")
    if !fileManager.fileExists(atPath: driver.path) {
        try fileManager.copyItem(at: digestSkill("digest"), to: driver)
        try fileManager.createSymbolicLink(at: home.appendingPathComponent("tool"), withDestinationURL: digestSkill("tool"))
        let bin = folder.appendingPathComponent("bin")
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        if canvasOnPath { try fileManager.createSymbolicLink(at: bin.appendingPathComponent("canvas"), withDestinationURL: builtExecutable("CanvasCLI")) }
    }
    let process = try run(URL(fileURLWithPath: "/bin/sh"), ["-c", #"cd "$0" && exec "$@""#, folder.path, driver.path] + arguments,
                          environment: ["PATH": folder.appendingPathComponent("bin").path + ":/usr/bin:/bin", "CANVAS_CLI": "", "CANVAS_SOCKET": server.path])
    if dumpsDigest { print("── isolated digest \(arguments.joined(separator: " "))\n\(process.output)\(process.error)") }
    return process
}

/// The tool, as the driver runs it.
@MainActor private func tool(_ arguments: [String], timeout: TimeInterval = 120) throws -> ProcessOutput {
    try run(URL(fileURLWithPath: jsc), [digestSkill("tool/main.js").path, "--"] + arguments, timeout: timeout)
}

/// Every shape of every board of the file.
@MainActor private func allRecords(_ editor: CanvasEditor) -> [AnyShapeRecord] {
    editor.file.root.shapes + editor.file.children.values.flatMap(\.shapes)
}

private func shapeID(_ text: String?) -> ShapeID? { text.flatMap(UUID.init(uuidString:)).map(ShapeID.init) }

/// The ids `canvas apply` answered, by the nodes' keys.
private func idsOf(_ apply: JSON) -> [String: ShapeID] {
    var ids: [String: ShapeID] = [:]
    for verdict in apply["nodes"]?.arrayValue ?? [] {
        if let key = verdict["key"]?.stringValue, let id = shapeID(verdict["id"]?.stringValue) { ids[key] = id }
    }
    return ids
}

/// What the file holds, held to the plan (drawing.json) and to what the app answered (results/apply.json): every node's shape in its frame or on its
/// board where its `place.at` says (from its frame's top-left, else from its board's origin) within a unit, a frame at its planned size, every
/// edge an arrow between its ends (`pillsFollow: false`: a pill an earlier drawing made stays where it is, as the app leaves it, so only that there is one), or through a pill where `place.pill` says, every pill where planned, and no arrow or pill more. `top` is the
/// board the drawing's top went on. Returns the shapes' ids by key.
@MainActor @discardableResult private func expectDrawn(_ run: DigestRun, in board: BoardDocument, top: BoardID = .root, fresh: Bool = true, pillsFollow: Bool = true, _ label: String) throws -> [String: ShapeID] {
    let editor = board.editor
    let drawing = try run.drawing, apply = try run.apply
    let nodes = drawing["nodes"]?.arrayValue ?? [], edges = drawing["edges"]?.arrayValue ?? []
    expect(!nodes.isEmpty, "\(label): nodes planned")
    let ids = idsOf(apply)
    expectEqual(ids.count, nodes.count, "\(label): an id for every node")
    var kinds: [String: String] = [:], holders: [String: String] = [:]
    for node in nodes {
        guard let key = node["key"]?.stringValue else { continue }
        kinds[key] = node["kind"]?.stringValue
        holders[key] = node["in"]?.stringValue
    }
    let records = allRecords(editor)
    func record(_ key: String) -> AnyShapeRecord? { ids[key].flatMap { editor.file.record($0) } }
    func boardOf(_ key: String) -> BoardID {
        guard let holder = holders[key] else { return top }
        if kinds[holder] == "subboard", let id = ids[holder] { return BoardID(owner: id) }
        return boardOf(holder)
    }
    func near(_ a: CGFloat, _ b: Double) -> Bool { abs(Double(a) - b) <= 1 }

    if fresh { for verdict in apply["nodes"]?.arrayValue ?? [] { expectEqual(verdict["did"], "created", "\(label): \(verdict["key"] ?? .null)") } }
    for node in nodes {
        guard let key = node["key"]?.stringValue, let shape = record(key), let box = shape.box else {
            expect(false, "\(label): \(node["key"] ?? .null) is on the board")
            continue
        }
        let at = (node["place"]?["at"]?.arrayValue ?? []).compactMap(\.numberValue)
        guard at.count == 2 else { expect(false, "\(label): \(key) has a place"); continue }
        var origin = CGPoint.zero
        if let holder = holders[key], kinds[holder] == "frame" {
            origin = record(holder)?.box?.origin ?? .zero
            expectEqual(shape.container, ids[holder], "\(label): \(key) is in its frame")
        } else {
            expectEqual(shape.container, nil, "\(label): \(key) is in no frame")
        }
        expectEqual(editor.file.board(containing: shape.id), boardOf(key), "\(label): \(key) is on its board")
        expect(near(box.minX, Double(origin.x) + at[0]) && near(box.minY, Double(origin.y) + at[1]),
               "\(label): \(key) is at \(box.origin), planned \(at) from \(origin)")
        if kinds[key] == "frame", let size = node["place"]?["size"]?.arrayValue?.compactMap(\.numberValue), size.count == 2 {
            expect(near(box.width, size[0]) && near(box.height, size[1]), "\(label): frame \(key) is \(box.size), planned \(size)")
        }
    }

    // the pills: the references on the file, each stood for by a pill-making edge of the plan
    let pills = records.filter { $0.typed(as: Reference.self) != nil }
    let makers = edges.filter { $0["place"]?["pill"]?["at"] != nil }
    expectEqual(pills.count, makers.count, "\(label): the pills planned, no more")
    var unmatched = pills
    for edge in makers {
        guard let pill = edge["place"]?["pill"], let at = pill["at"]?.arrayValue?.compactMap(\.numberValue), at.count == 2,
              let from = edge["from"]?.stringValue, let to = edge["to"]?.stringValue else { continue }
        var origin = CGPoint.zero
        if let holder = pill["in"]?.stringValue { origin = record(holder)?.box?.origin ?? .zero }
        let ends = [from, to].compactMap { ids[$0] }
        let found = unmatched.firstIndex { candidate in
            guard let target = candidate.typed(as: Reference.self)?.props.target?.id, ends.contains(target), let box = candidate.box else { return false }
            return !pillsFollow || near(box.minX, Double(origin.x) + at[0]) && near(box.minY, Double(origin.y) + at[1])
        }
        if let found { unmatched.remove(at: found) } else { expect(false, "\(label): a pill for \(from) -> \(to) at \(at) from \(origin)") }
    }

    // the arrows: each edge an arrow between its ends, an end a pill that stands for it; an edge that shares a pill, an arrow into it
    var arrows = records.compactMap { shape -> (start: ShapeID?, end: ShapeID?)? in
        shape.typed(as: Arrow.self).map { ($0.props.start.binding?.shapeID, $0.props.end.binding?.shapeID) }
    }
    let pillTargets = Dictionary(uniqueKeysWithValues: pills.compactMap { pill in pill.typed(as: Reference.self)?.props.target.map { (pill.id, $0.id) } })
    expectEqual(arrows.count, edges.count, "\(label): an arrow for each edge, no more")
    for edge in edges {
        guard let from = edge["from"]?.stringValue.flatMap({ ids[$0] }), let to = edge["to"]?.stringValue.flatMap({ ids[$0] }) else {
            expect(false, "\(label): the ends of an edge are drawn")
            continue
        }
        let throughPill = edge["place"]?["pill"] != nil
        func standsFor(_ id: ShapeID?, _ original: ShapeID) -> Bool { id == original || (id.flatMap { pillTargets[$0] } == original) }
        let found = arrows.firstIndex { arrow in
            standsFor(arrow.start, from) && standsFor(arrow.end, to) && (!throughPill || arrow.start != from || arrow.end != to)
        }
        if let found { arrows.remove(at: found) } else { expect(false, "\(label): an arrow \(edge["from"] ?? .null) -> \(edge["to"] ?? .null)\(throughPill ? " through a pill" : "")") }
    }

    if fresh {
        for verdict in apply["edges"]?.arrayValue ?? [] { expectEqual(verdict["did"], "created", "\(label): edge \(verdict["from"] ?? .null) -> \(verdict["to"] ?? .null)") }
        expectEqual(apply["deleted"]?.arrayValue ?? [], [], "\(label): nothing deleted from a fresh board")
    }
    expectEqual(apply["edges"]?.arrayValue?.count, edges.count, "\(label): a verdict for every edge")
    return ids
}

/// Whether a shape is public is the person's: the digest draws nothing private (every shape is public until a
/// person says otherwise), and its report says nothing of what is public.
@MainActor private func expectNothingPrivate(_ run: DigestRun, in editor: CanvasEditor, _ label: String) throws {
    expectEqual(allRecords(editor).filter { $0[PrivateProperty.self] == true }.count, 0, "\(label): nothing is private")
    expect(try run.report["public"] == nil, "\(label): the report says nothing of public")
}

/// The whole file, to say a redraw changed nothing: every shape's record.
@MainActor private func snapshot(_ editor: CanvasEditor) -> [ShapeID: AnyShapeRecord] {
    Dictionary(uniqueKeysWithValues: allRecords(editor).map { ($0.id, $0) })
}

/// A board with a subboard called "Home" drawn first; the digest is drawn on that subboard's board (`--on Home`).
@MainActor private func boardWithHome(_ server: CommandServer, _ board: BoardDocument) throws -> BoardID {
    let made = try canvas(server, ["draw", #"subboard "Home""#, "--board", "\(board.number)"])
    expectEqual(made.status, 0, made.error)
    let home = try require(allRecords(board.editor).first { $0.kind == Subboard.kind }, "the subboard is drawn")
    return BoardID(owner: home.id)
}

/// What the run said of the edges it left out, and the report's warnings, together.
private func warnings(_ run: DigestRun) -> String {
    ((try? run.report)?["warnings"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: "\n") + "\n" + run.said
}

@MainActor let digestSmallTests = Suite("canvas-digest: digest all on Acme, a tree, a spine and arrows at frames, into a subboard", [
    test("digest all on Acme into a subboard of an open board: every node, pill and arrow where the plan says, all created, nothing private, one undo step takes it back") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("acme")
        defer { try? FileManager.default.removeItem(at: folder) }
        let top = try boardWithHome(server, board)
        let before = board.editor.file.shapeCount

        let run = try runDigest("all", fixture("acme"), server: server, target: ["--board", "\(board.number)", "--on", "Home"], out: folder)
        expectEqual(run.process.status, 0, run.said)
        let ids = try expectDrawn(run, in: board, top: top, "Acme")
        expect(try (run.drawing["edges"]?.arrayValue ?? []).contains { $0["place"]?["pill"] != nil }, "Acme has hubs worth a pill")
        expectEqual(board.editor.file.shapeCount, before + ids.count + (try (run.drawing["edges"]?.arrayValue ?? []).filter { $0["place"]?["pill"]?["at"] != nil }.count)
                    + (try (run.drawing["edges"]?.arrayValue ?? []).count), "the shapes of the drawing, its pills and its arrows")
        // every shape is public, so a pill stands for its target as it is: nothing is made public or private
        try expectNothingPrivate(run, in: board.editor, "Acme")
        // one step takes the whole drawing back
        board.editor.undo()
        expectEqual(board.editor.file.shapeCount, before, "one undo step takes the drawing back")
        expect(board.editor.canUndo, "the subboard drawn first is still there to undo")
    },

    test("digest all on a 3-level tree: a subboard holding a frame holding a frame, edges across boards through pills, the subboard's text mentioning shapes by key") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("tree")
        defer { try? FileManager.default.removeItem(at: folder) }
        let top = try boardWithHome(server, board)
        let before = board.editor.file.shapeCount

        let run = try runDigest("all", fixture("tree"), server: server, target: ["--board", "\(board.number)", "--on", "Home"], out: folder)
        expectEqual(run.process.status, 0, run.said)
        let ids = try expectDrawn(run, in: board, top: top, "tree")
        expect(Set(try run.drawing["nodes"]?.arrayValue?.compactMap { $0["kind"]?.stringValue } ?? []).isSuperset(of: ["subboard", "frame", "sticky-note"]), "a subboard, frames and notes")
        try expectNothingPrivate(run, in: board.editor, "tree")
        // the subboard's text names two notes by key; the app wrote it as mentions of them
        let backend = try require(ids["Backend"].flatMap { board.editor.file.record($0) })
        let description = backend.propertiesJSON?["description"]?.stringValue ?? backend.propertiesJSON?["text"]?.stringValue ?? ""
        for key in ["Gateway", "Login"] {
            expect(description.contains(try require(ids[key]).description), "the text mentions \(key) by its id: \(description)")
        }
        board.editor.undo()
        expectEqual(board.editor.file.shapeCount, before, "one undo step takes the drawing back")
    },

    test("digest all with arrows at frames: frames and a subboard joined, every node and arrow on its plan; an edge the app won't draw is left out, saying both keys, in the app's words") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("frames")
        defer { try? FileManager.default.removeItem(at: folder) }
        let top = try boardWithHome(server, board)

        let run = try runDigest("all", fixture("frames"), server: server, target: ["--board", "\(board.number)", "--on", "Home"], out: folder)
        expectEqual(run.process.status, 0, run.said)
        // the app lists what it would refuse to draw, by the edge's place in the document; the plan leaves it out
        let refused = try require(run.measure["edges"]?.arrayValue, "measure lists edges")
        expectEqual(refused.count, 1, "one edge the app won't draw: \(refused)")
        expectEqual(refused.first?["from"], "Gateway")
        expectEqual(refused.first?["to"], "web")
        let message = try require(refused.first?["refused"]?["message"]?.stringValue)
        let said = warnings(run)
        expect(said.contains("Gateway") && said.contains("web") && said.contains(message), "the edge is left out saying both keys and the app's words: \(said)")
        try expectDrawn(run, in: board, top: top, "frames")
        let graph = try json(fixture("frames"))
        expectEqual(try run.drawing["edges"]?.arrayValue?.count, (graph["edges"]?.arrayValue?.count ?? 0) - 1, "every edge but that one is in the plan")
    },

    test("digest all on a spine: a band of cards pointing at the same notes, the pills they share, every node, pill and arrow on its plan") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("spine")
        defer { try? FileManager.default.removeItem(at: folder) }
        let top = try boardWithHome(server, board)

        let run = try runDigest("all", fixture("spine"), server: server, target: ["--board", "\(board.number)", "--on", "Home"], out: folder)
        expectEqual(run.process.status, 0, run.said)
        let ids = try expectDrawn(run, in: board, top: top, "spine")
        let edges = try run.drawing["edges"]?.arrayValue ?? []
        expect(edges.contains { $0["place"]?["pill"]?["share"] != nil }, "a pill the band's cards share")
        // a shared pill is one shape: one pill for X, however many cards point at it
        let pills = allRecords(board.editor).compactMap { $0.typed(as: Reference.self) }.filter { $0.props.target?.id == ids["X"] }
        expectEqual(pills.count, 1, "one pill for X")
        try expectNothingPrivate(run, in: board.editor, "spine")
    },

    test("digest all on a typed graph: types, notes of a type and relationship arrows pass through as the app takes them, every node and arrow on its plan") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("typed")
        defer { try? FileManager.default.removeItem(at: folder) }
        let top = try boardWithHome(server, board)

        let run = try runDigest("all", fixture("typed"), server: server, target: ["--board", "\(board.number)", "--on", "Home"], out: folder)
        expectEqual(run.process.status, 0, run.said)
        _ = try expectDrawn(run, in: board, top: top, "typed")
        // the types are found by the app: a note of a type answers for it
        let types = try require(JSON(text: canvas(server, ["query", "--board", "\(board.number)", "--brief", "--limit", "10000", ":is-a(*)"]).output)["rows"]?.arrayValue)
        expect(!types.isEmpty, "notes of a type, as the app reads is: by key")
        try expectNothingPrivate(run, in: board.editor, "typed")
    },
])

@MainActor let digestBoardTests = Suite("canvas-digest: digest all onto an empty board itself, and into a new file", [
    test("digest all onto an empty board, with no --on: the drawing's top is on the board itself") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("onboard")
        defer { try? FileManager.default.removeItem(at: folder) }

        let run = try runDigest("all", fixture("acme"), server: server, target: ["--board", "\(board.number)"], out: folder)
        expectEqual(run.process.status, 0, run.said)
        _ = try expectDrawn(run, in: board, top: .root, "Acme on the board")
        try expectNothingPrivate(run, in: board.editor, "Acme on the board")
        board.editor.undo()
        expectEqual(board.editor.file.shapeCount, 0, "one undo step takes the drawing back")
        expect(!board.editor.canUndo, "and it was the only step")
    },

    test("digest all on a flat graph of 60 notes, into a new file (canvas new, then --board its id): hubs promoted, every node, pill and arrow on its plan") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let first = newBoard()
        defer { first.close() }
        let opened = Opened()
        defer { for board in opened.boards { board.close() } }
        let commands = try require(BoardDocument.configuration).registry.hostCommands
        let server = CommandServer(path: temporarySocketPath(), commands: CommandServer.Commands(specs: commands.specs, run: commands.run),
                                   boards: { [first] + opened.boards }, frontmost: { opened.boards.last ?? first }, show: { opened.boards.append($0) })
        try server.start()
        defer { server.stop() }
        let folder = try scratchFolder("flat")
        defer { try? FileManager.default.removeItem(at: folder) }

        let file = folder.appendingPathComponent("Flat")
        let made = try canvas(server, ["new", file.path])
        expectEqual(made.status, 0, made.error)
        let board = try require(opened.boards.first)
        expectEqual(board.fileURL?.lastPathComponent, "Flat.canvasboard")
        let id = try require(JSON(text: made.output)["id"]?.intValue, "canvas new says the board's id")

        let run = try runDigest("all", fixture("flat60"), server: server, target: ["--board", "\(id)"], out: folder.appendingPathComponent("out"))
        expectEqual(run.process.status, 0, run.said)
        let ids = try expectDrawn(run, in: board, top: .root, "flat60")
        expectEqual(ids.count, 60)
        expect(try (run.drawing["edges"]?.arrayValue ?? []).contains { $0["place"]?["pill"] != nil }, "hubs promoted")
        try expectNothingPrivate(run, in: board.editor, "flat60")
        expectEqual(first.editor.file.shapeCount, 0, "the other board is as it was")
    },
])

@MainActor let digestRedrawTests = Suite("canvas-digest: drawing again with the same document, a changed one, and one with a node gone", [
    test("drawing the same document again changes nothing and makes no undo step; one node's text changed is updated alone; a node gone is deleted with its edges, and a shape the test drew on that board stays") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("redraw")
        defer { try? FileManager.default.removeItem(at: folder) }
        let top = try boardWithHome(server, board)
        let mine = try canvas(server, ["draw", #"sticky-note "Mine" right of origin (gap: 3000)"#, "--board", "\(board.number)"])
        expectEqual(mine.status, 0, mine.error)
        let baseline = board.editor.file.shapeCount
        let target = ["--board", "\(board.number)", "--on", "Home"]

        let first = try runDigest("all", fixture("tree"), server: server, target: target, out: folder.appendingPathComponent("one"))
        expectEqual(first.process.status, 0, first.said)
        let ids = try expectDrawn(first, in: board, top: top, "first")
        let drawn = snapshot(board.editor)

        // the same document: every verdict unchanged, nothing on the board changes, no new step
        let second = try runDigest("all", fixture("tree"), server: server, target: target, out: folder.appendingPathComponent("two"))
        expectEqual(second.process.status, 0, second.said)
        let verdicts = try second.apply
        let nodeVerdicts = verdicts["nodes"]?.arrayValue ?? []
        expectEqual(nodeVerdicts.count, ids.count)
        expectEqual(nodeVerdicts.map { $0["did"]?.stringValue }, Array(repeating: "unchanged", count: ids.count), "every node unchanged")
        expectEqual(Set((verdicts["edges"]?.arrayValue ?? []).compactMap { $0["did"]?.stringValue }), ["unchanged"], "every edge unchanged")
        expectEqual(snapshot(board.editor), drawn, "nothing on the board changed")
        expectEqual(board.editor.undoHistory.undoName, "Draw")
        board.editor.undo()
        expectEqual(board.editor.file.shapeCount, baseline, "the one step is still the first drawing")
        board.editor.redo()
        expectEqual(snapshot(board.editor), drawn, "and redone it is as it was")

        // one node's text changed: that node is updated, and nothing else
        var graph = try json(fixture("tree"))
        let nodes = graph["nodes"]?.arrayValue ?? []
        let changed = try require(nodes.first { $0["kind"]?.stringValue == "sticky-note" && $0["props"]?["text"] != nil && $0["key"]?.stringValue == "Sessions" }?["key"]?.stringValue)
        graph["nodes"] = .array(nodes.map { node in
            guard node["key"]?.stringValue == changed else { return node }
            var node = node
            node["props"]?["text"] = "Holds who is signed in, and for how long."
            return node
        })
        let third = try runDigest("all", try graphFile("changed", graph, in: folder), server: server, target: target, out: folder.appendingPathComponent("three"))
        expectEqual(third.process.status, 0, third.said)
        let didByKey = Dictionary(uniqueKeysWithValues: try (third.apply["nodes"]?.arrayValue ?? []).compactMap { v in v["key"]?.stringValue.map { ($0, v["did"]?.stringValue ?? "?") } })
        expectEqual(didByKey[changed], "updated", "the node whose text changed")
        expectEqual(didByKey.filter { $0.value != "unchanged" }.keys.sorted(), [changed], "and only it")
        expectEqual(board.editor.file.record(try require(ids[changed]))?.propertiesJSON?["text"], "Holds who is signed in, and for how long.")

        // a node gone: deleted, its edges with it
        let gone = "Passwords"
        let edgesOfGone = (graph["edges"]?.arrayValue ?? []).filter { $0["from"]?.stringValue == gone || $0["to"]?.stringValue == gone }.count
        expect(edgesOfGone > 0, "the node has edges")
        graph["nodes"] = .array((graph["nodes"]?.arrayValue ?? []).filter { $0["key"]?.stringValue != gone })
        graph["edges"] = .array((graph["edges"]?.arrayValue ?? []).filter { $0["from"]?.stringValue != gone && $0["to"]?.stringValue != gone })
        let fourth = try runDigest("all", try graphFile("removed", graph, in: folder), server: server, target: target, out: folder.appendingPathComponent("four"))
        expectEqual(fourth.process.status, 0, fourth.said)
        let deleted = try (fourth.apply["deleted"]?.arrayValue ?? []).compactMap { $0["key"]?.stringValue }
        expect(deleted.contains(gone), "the node is deleted: \(deleted)")
        // and its edges and pills with it; anything else deleted is an edge the new plan draws otherwise (straight now, through a
        // pill now, or into a pill its group shares otherwise), drawn anew with its key, or the pill such an edge left
        let created = Set((try fourth.apply["edges"]?.arrayValue ?? []).filter { $0["did"] == "created" }.compactMap { verdict -> String? in
            guard let from = verdict["from"]?.stringValue, let to = verdict["to"]?.stringValue else { return nil }
            return "edge \(from) -> \(to)"
        })
        let others = deleted.filter { $0 != gone && !$0.contains(gone) }
        expectEqual(others.filter { !($0.hasPrefix("edge ") || $0.hasPrefix("pill ")) }, [], "no node but the one gone")
        expectEqual(others.filter { $0.hasPrefix("edge ") && !created.contains($0) }, [], "an edge deleted is drawn anew: \(deleted)")
        expect(board.editor.file.record(try require(ids[gone])) == nil, "the shape is gone")
        let boundToGone = allRecords(board.editor).filter { $0.typed(as: Arrow.self).map { $0.props.start.binding?.shapeID == ids[gone] || $0.props.end.binding?.shapeID == ids[gone] } ?? false }
        expectEqual(boundToGone.count, 0, "and its arrows")
        // the board is the new document, drawn
        try expectDrawn(fourth, in: board, top: top, fresh: false, "fourth")   // every pill where the new plan puts it: the app moves those drawn before
        expect(allRecords(board.editor).contains { $0.propertiesJSON?["title"]?.stringValue == "Mine" }, "the shape the test drew stays")
    },
])

@MainActor let digestFieldsTests = Suite("canvas-digest: props the tool doesn't read reach the app", [
    test("a note's, a frame's and an arrow's color, written in props and read by no one but the app, are on the board as drawn") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("fields")
        defer { try? FileManager.default.removeItem(at: folder) }
        let colors: JSON = ["drawing": "colors", "nodes": [
            ["key": "blue", "kind": "sticky-note", "props": ["title": "Blue note", "text": "Blue", "color": "blue"]],
            ["key": "region", "kind": "frame", "props": ["title": "Region", "color": "green"]],
            ["key": "inside", "in": "region", "kind": "sticky-note", "props": ["title": "Inside", "text": "In"]],
            ["key": "plain", "kind": "sticky-note", "props": ["title": "Plain", "text": "No color"]]],
            "edges": [["from": "blue", "to": "plain", "props": ["color": "red"]]]]
        let drawn = try runDigest("all", try graphFile("colors", colors, in: folder), server: server, target: ["--board", "\(board.number)"], out: folder.appendingPathComponent("colors"))
        expectEqual(drawn.process.status, 0, drawn.said)
        try expectDrawn(drawn, in: board, "colors")
        let records = allRecords(board.editor)
        func title(_ record: AnyShapeRecord) -> String? { record.propertiesJSON?["title"]?.stringValue }
        expectEqual(records.filter { $0.propertiesJSON?["color"] == "blue" }.compactMap(title), ["Blue note"])
        expectEqual(records.filter { $0.kind.rawValue == "frame" && $0.propertiesJSON?["color"] == "green" }.compactMap(title), ["Region"])
        expectEqual(records.filter { $0.typed(as: Arrow.self) != nil && $0.propertiesJSON?["color"] == "red" }.count, 1, "the arrow's")
        expectEqual(records.filter { $0.kind.rawValue == "sticky-note" && $0.propertiesJSON?["color"] == nil }.compactMap(title).sorted(), ["Inside", "Plain"], "and nothing else is colored")
    },
])

@MainActor let digestRefusalTests = Suite("canvas-digest: what is refused by key, with nothing drawn", [
    test("a kind the app doesn't have is refused by check, naming the key; a prop no kind takes, and a value its type refuses, are the app's refusals, printed with the key, exit 1, the board as it was") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("refusals")
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = ["--board", "\(board.number)"]
        let before = snapshot(board.editor)

        // a kind the app doesn't have: check refuses it, naming the node, and so does all
        let gizmo = try graphFile("gizmo", ["drawing": "gizmo", "nodes": [["key": "g1", "kind": "gizmo", "props": ["title": "Gadget"]]], "edges": []], in: folder)
        for command in ["check", "all"] {
            let refused = try runDigest(command, gizmo, server: server, target: target, out: folder.appendingPathComponent("gizmo-\(command)"))
            expectEqual(refused.process.status, 1, "\(command): \(refused.said)")
            expect(refused.said.contains("g1") && refused.said.contains("gizmo"), "\(command) names the node and the kind: \(refused.said)")
        }

        // a prop no kind takes: the app refuses it, by key
        let sparkle = try graphFile("sparkle", ["drawing": "sparkle", "nodes": [["key": "n1", "kind": "sticky-note", "props": ["title": "Shiny", "sparkle": "lots"]]], "edges": []], in: folder)
        let odd = try runDigest("all", sparkle, server: server, target: target, out: folder.appendingPathComponent("sparkle"))
        expectEqual(odd.process.status, 1, odd.said)
        expect(odd.process.error.contains("n1") && odd.process.error.contains("sparkle"), "the app's refusal, naming the key: \(odd.process.error)")

        // fieldValues that are no object of values: the app refuses them, by key
        let shape: JSON = ["drawing": "shape", "nodes": [["key": "task:two", "kind": "sticky-note", "props": ["title": "Two", "fieldValues": ["points", "many"]]]], "edges": []]
        let malformed = try runDigest("all", try graphFile("shape", shape, in: folder), server: server, target: target, out: folder.appendingPathComponent("shape"))
        expectEqual(malformed.process.status, 1, malformed.said)
        expect(malformed.process.error.contains("task:two") && malformed.process.error.contains("fieldValues"), "the app's refusal, naming the key: \(malformed.process.error)")

        expectEqual(snapshot(board.editor), before, "the board is as it was")
        expect(!board.editor.canUndo, "and no step was made")

        // a value its type refuses is the app's to say, as it says it of a note drawn by hand: a warning with the key, the note drawn
        let typed: JSON = ["drawing": "typed", "nodes": [
            ["key": "type:Task", "kind": "sticky-note", "props": ["title": "Task", "schema": ["type": "object", "properties": ["points": ["type": "integer"]]]]],
            ["key": "task:one", "kind": "sticky-note", "props": ["title": "One", "is": ["type:Task"], "fieldValues": ["points": "many"]]]], "edges": []]
        let wrong = try runDigest("all", try graphFile("wrong", typed, in: folder), server: server, target: target, out: folder.appendingPathComponent("wrong"))
        expectEqual(wrong.process.status, 0, wrong.said)
        expect(wrong.process.output.contains("task:one") && wrong.process.output.contains("points should be a whole number"), "the app's warning, with the key: \(wrong.process.output)")
        let warned = try require(try wrong.apply["warnings"]?.arrayValue?.first)
        expectEqual(warned["key"], "task:one")
        try expectDrawn(wrong, in: board, "wrong")
    },

    test("a document with a cycle in `in` is refused by check, naming the keys, and the tool's failure reaches standard error behind the driver's redirects") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("loop")
        defer { try? FileManager.default.removeItem(at: folder) }
        let loop = try graphFile("loop", ["drawing": "loop", "nodes": [["key": "a", "in": "b", "kind": "frame"], ["key": "b", "in": "a", "kind": "frame"]], "edges": []], in: folder)
        for command in ["check", "measure", "plan", "all"] {
            let failed = try runDigest(command, loop, server: server, target: ["--board", "\(board.number)"], out: folder.appendingPathComponent("loop-\(command)"))
            expectEqual(failed.process.status, 1, "\(command): \(failed.said)")
            expect(failed.said.contains("a") && failed.said.contains("b"), "\(command) names the keys: \(failed.said)")
            expect(!failed.said.contains("Maximum call stack"), "\(command): \(failed.said)")
        }
        let checked = try runDigest("check", loop, server: server, out: folder.appendingPathComponent("loop-check-text"))
        expect(checked.said.contains("error:"), checked.said)
        // check reads the tool's answer, not its words: a note titled with "error: " is no error
        let words = try graphFile("words", ["drawing": "words", "nodes": [["key": "p", "kind": "sticky-note", "props": ["title": "Parse error: unexpected token"]], ["key": "o", "kind": "sticky-note", "props": ["title": "Other"]]],
                                            "edges": [["from": "o", "to": "p"]]], in: folder)
        let fine = try runDigest("check", words, server: server, out: folder.appendingPathComponent("words"))
        expectEqual(fine.process.status, 0, fine.said)
    },
])

@MainActor let digestReadyTests = Suite("canvas-digest: ready, and no canvas", [
    test("ready is fine with an app answering and a board open; a canvas that doesn't know apply is refused, saying what to do; a canvas that can't be found is said on standard error") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("ready")
        defer { try? FileManager.default.removeItem(at: folder) }
        let environment = ["CANVAS_CLI": builtExecutable("CanvasCLI").path, "CANVAS_SOCKET": server.path]

        let ready = try run(digestSkill("digest"), ["ready", "--out", folder.appendingPathComponent("ready").path], environment: environment)
        expectEqual(ready.status, 0, ready.output + ready.error)
        expect(ready.output.contains("canvas apply is there"), ready.output)

        // a canvas from before apply: `canvas help apply` is not answered
        let stub = folder.appendingPathComponent("canvas-old")
        try ##"""
            #!/bin/sh
            if [ "$1" = help ]; then echo "unknown command: $2" >&2; exit 1; fi
            exec "\##(builtExecutable("CanvasCLI").path)" "$@"

            """##.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let old = try run(digestSkill("digest"), ["ready", "--out", folder.appendingPathComponent("old").path], environment: ["CANVAS_CLI": stub.path, "CANVAS_SOCKET": server.path])
        expectEqual(old.status, 1, old.output + old.error)
        expect(old.error.contains("canvas apply doesn't answer") && old.error.contains("canvas install"), old.error)

        // canvas on the PATH, and nowhere else: found
        let lone = folder.appendingPathComponent("on-path")
        let tiny = try graphFile("tiny", ["drawing": "tiny", "nodes": [["key": "a", "kind": "sticky-note", "props": ["title": "Tiny A"]], ["key": "b", "kind": "sticky-note", "props": ["title": "Tiny B"]]],
                                          "edges": [["from": "a", "to": "b"]]], in: folder)
        let found = try runIsolatedDriver(["measure", tiny.path, "--out", lone.appendingPathComponent("out").path], folder: lone, canvasOnPath: true, server: server)
        expectEqual(found.status, 0, found.output + found.error)
        expect(((try? String(contentsOf: lone.appendingPathComponent("out/measure.json"), encoding: .utf8)) ?? "").contains("nodes"), "measure.json is the app's answer")

        // and nowhere at all: said on standard error, whatever the failing command's output was going to
        let none = folder.appendingPathComponent("nowhere")
        for command in [["measure", tiny.path], ["check", tiny.path], ["plan", tiny.path], ["all", tiny.path], ["ready"]] {
            let lost = try runIsolatedDriver(command + ["--out", none.appendingPathComponent("out-\(command[0])").path], folder: none, canvasOnPath: false, server: server)
            expectEqual(lost.status, 1, "\(command[0]): \(lost.output) \(lost.error)")
            expect(lost.error.contains("digest: can't find canvas: set CANVAS_CLI"), "\(command[0]): \(lost.error)")
        }
    },
])

@MainActor let digestKindsTests = Suite("canvas-digest: the app's kinds, as the tool reads them", [
    test("the kinds the tool's own tests read (tool/test/fixtures/kinds.json) are what it reads of canvas kinds: the shipped kinds, what each holds, the pills that stand for it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let server = try startCommandServer(boards: [], frontmost: nil)
        defer { server.stop() }
        let folder = try scratchFolder("kinds")
        defer { try? FileManager.default.removeItem(at: folder) }
        let answered = try canvas(server, ["kinds"])
        expectEqual(answered.status, 0, answered.error)
        let answer = folder.appendingPathComponent("kinds.json")
        try answered.output.write(to: answer, atomically: true, encoding: .utf8)
        let read = try tool(["extract", "kinds", answer.path])
        expectEqual(read.status, 0, read.output + read.error)
        expectEqual(try JSON(text: read.output), try json(digestKinds()),
                    "the fixture is what the tool reads of canvas kinds: write it again from this answer\n\(read.output)")
    },
])
