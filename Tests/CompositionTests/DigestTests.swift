import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasUI
import Composition
import Connections
import Foundation
import HostSlots
import Publishing
import References
import Subboards
import TestKit
import Titles

// The canvas-digest skill (.claude/skills/canvas-digest), end to end. The tool's own unit tests run
// under the system jsc (the runtime the skill is built for). Then `digest all` runs as an agent runs
// it, with `canvas` as built (CANVAS_CLI) against this test's own command server (CANVAS_SOCKET), on
// three digests: Acme, drawn into a subboard of an open board and held to what the tool planned and
// to a drawing of the same digest with nothing promoted (a query for what points at a hub answers the
// same either way); a 3-level tree (a subboard holding a frame holding a frame, edges across boards);
// and a flat graph of 60 notes with no container, drawn into a new file. Each shape and pill must
// land on its plan, each arrow be drawn, and no run warn.

/// Whether to print what `digest` said in each run (DIGEST_DUMP=1).
private let dumpsDigest = ProcessInfo.processInfo.environment["DIGEST_DUMP"] == "1"

private let jsc = "/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc"

/// The skill's folder, absolute (tests run from the repository's root).
private func skillURL(_ path: String = "") -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".claude/skills/canvas-digest").appendingPathComponent(path)
}

private func fixture(_ name: String) -> URL { skillURL("tool/test/fixtures/\(name).digest.json") }

private func json(_ url: URL) throws -> JSON { try JSON(text: String(contentsOf: url, encoding: .utf8)) }

/// What the driver prints and where it put its files.
private struct DigestRun {
    let process: ProcessOutput
    let out: URL

    var plan: JSON { get throws { try json(out.appendingPathComponent("plan.json")) } }
    var report: JSON { get throws { try json(out.appendingPathComponent("report.json")) } }

    /// What `canvas draw` said of each real run, in the order they ran.
    func results() throws -> [(name: String, result: JSON)] {
        try plan["runs"]?.arrayValue?.compactMap(\.stringValue).map { name in
            (name, try json(out.appendingPathComponent("results/\(name.replacingOccurrences(of: ".draw", with: "")).json")))
        } ?? []
    }
}

/// `digest <command> <fixture>` as an agent runs it, for the server and the board named.
@MainActor private func runDigest(_ command: String, _ fixtureName: String, server: CommandServer, target: [String], extra: [String] = [],
                               out: URL, timeout: TimeInterval = 280) throws -> DigestRun {
    try runDigest(command, file: fixture(fixtureName), server: server, target: target, extra: extra, out: out, timeout: timeout)
}

/// `digest <command> <digest file>`, the same.
@MainActor private func runDigest(_ command: String, file: URL, server: CommandServer, target: [String], extra: [String] = [],
                               out: URL, timeout: TimeInterval = 280) throws -> DigestRun {
    let process = try run(skillURL("digest"), [command, file.path] + target + ["--out", out.path] + extra,
                          environment: ["CANVAS_CLI": builtExecutable("CanvasCLI").path, "CANVAS_SOCKET": server.path], timeout: timeout)
    if dumpsDigest { print("── digest \(command) \(file.lastPathComponent)\n\(process.output)\(process.error)") }
    return DigestRun(process: process, out: out)
}

/// A digest written to a file of the folder.
private func digestFile(_ name: String, _ text: String, in folder: URL) throws -> URL {
    let file = folder.appendingPathComponent("\(name).digest.json")
    try text.write(to: file, atomically: true, encoding: .utf8)
    return file
}

/// The driver as the skill is installed somewhere else: a copy in a folder of its own, three levels down, so that the repository it
/// looks in for `build/canvas` is the folder, which has none, and run from that folder. `canvas` is found only on the PATH, which is
/// `bin` in the folder (with `canvas` linked into it when `canvasOnPath`) and the system's; `CANVAS_CLI` is empty.
@MainActor private func runIsolatedDriver(_ command: String, _ file: URL, folder: URL, canvasOnPath: Bool, server: CommandServer, out: URL) throws -> ProcessOutput {
    let fileManager = FileManager.default
    let home = folder.appendingPathComponent("skill/a/b")
    try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
    let driver = home.appendingPathComponent("digest")
    if !fileManager.fileExists(atPath: driver.path) {
        try fileManager.copyItem(at: skillURL("digest"), to: driver)
        try fileManager.createSymbolicLink(at: home.appendingPathComponent("tool"), withDestinationURL: skillURL("tool"))
        let bin = folder.appendingPathComponent("bin")
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        if canvasOnPath { try fileManager.createSymbolicLink(at: bin.appendingPathComponent("canvas"), withDestinationURL: builtExecutable("CanvasCLI")) }
    }
    let process = try run(URL(fileURLWithPath: "/bin/sh"), ["-c", #"cd "$0" && exec "$@""#, folder.path, driver.path, command, file.path, "--out", out.path],
                          environment: ["PATH": folder.appendingPathComponent("bin").path + ":/usr/bin:/bin", "CANVAS_CLI": "", "CANVAS_SOCKET": server.path])
    if dumpsDigest { print("── isolated digest \(command) \(file.lastPathComponent)\n\(process.output)\(process.error)") }
    return process
}

/// The tool, as the driver runs it.
@MainActor private func tool(_ arguments: [String], timeout: TimeInterval = 120) throws -> ProcessOutput {
    try run(URL(fileURLWithPath: jsc), [skillURL("tool/main.js").path, "--"] + arguments, timeout: timeout)
}

private func scratchFolder(_ name: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DigestTests-\(UUID().uuidString)-\(name)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// Every shape, pill and arrow of the file as the tool's `verify` reads them, one JSON object a line:
/// `{board, title, kind, x, y, w, h, in, for, from, to}`. A board is `root` (the digest's own: the
/// file's root, or the board of the subboard called `digestRoot`) or the title of the subboard that
/// holds it; an arrow's `to` is `pill:<label>` for a reference.
@MainActor private func landedRows(in editor: CanvasEditor, digestRoot: String?) throws -> String {
    let containing = editor.registry.containingKinds
    func titled(_ id: ShapeID?) -> String {
        guard let record = id.flatMap({ editor.file.record($0) }) else { return "?" }
        return editor.registry.title(of: record) ?? record.kind.rawValue
    }
    var rows: [[String: Any]] = []
    var queue: [(name: String, board: BoardID)] = [(digestRoot == nil ? "root" : "file", .root)]
    var next = 0
    while next < queue.count {
        let (name, board) = queue[next]
        next += 1
        let document = editor.contents(of: board)
        for record in document.shapes {
            let title = editor.registry.title(of: record)
            if record.kind == Subboard.kind {
                let child = name == "file" && title == digestRoot ? "root" : (title ?? "?")
                queue.append((child, BoardID(owner: record.id)))
            }
            var row: [String: Any] = ["board": name, "kind": record.kind.rawValue]
            if let title { row["title"] = title }
            if let box = record.box { row["x"] = box.minX; row["y"] = box.minY; row["w"] = box.width; row["h"] = box.height }
            if let holder = document.container(of: record, containingKinds: containing) { row["in"] = titled(holder) }
            if let reference = record.typed(as: Reference.self) {
                row["for"] = reference.props.target?.label ?? "?"
            } else if let arrow = record.typed(as: Arrow.self)?.props {
                row["kind"] = "arrow"
                row["from"] = titled(arrow.start.binding?.shapeID)
                if let end = arrow.end.binding?.shapeID, let target = editor.file.record(end)?.typed(as: Reference.self) {
                    row["to"] = "pill:" + (target.props.target?.label ?? "?")
                } else {
                    row["to"] = titled(arrow.end.binding?.shapeID)
                }
            }
            rows.append(row)
        }
    }
    return try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }.joined(separator: "\n")
}

/// What the file holds, held to the plan by the tool's `verify`: every shape and pill within a unit
/// of its place and its width, in its frame, every arrow drawn, and nothing more.
@MainActor private func expectOnPlan(_ run: DigestRun, board: BoardDocument, digestRoot: String?, _ label: String) throws {
    let rows = run.out.appendingPathComponent("rows.jsonl")
    try landedRows(in: board.editor, digestRoot: digestRoot).write(to: rows, atomically: true, encoding: .utf8)
    let verified = try tool(["verify", run.out.appendingPathComponent("plan.json").path, rows.path, "--json"])
    expectEqual(verified.status, 0, "\(label): \(verified.output) \(verified.error)")
    let summary = try require(JSON(text: verified.output)["summary"])
    expect((summary["shapes"]?.numberValue ?? 0) > 0, "\(label): shapes planned")
    expectEqual(summary["shapesWithin1"], summary["shapes"], "\(label): every shape within 1 unit of its place, worst \(summary["worstShape"] ?? .null)")
    expect((summary["pills"]?.numberValue ?? 0) > 0, "\(label): pills planned")
    expectEqual(summary["pillsWithin1"], summary["pills"], "\(label): every pill within 1 unit of its place, worst \(summary["worstPill"] ?? .null)")
    expect((summary["pillWidthError"]?["max"]?.numberValue ?? 99) <= 1, "\(label): every pill as wide as planned: \(summary["pillWidthError"] ?? .null)")
    expectEqual(summary["missing"], [], "\(label): nothing missing")
    expectEqual(summary["wrongFrame"], [], "\(label): every shape in its frame")
    expectEqual(summary["edgesMissing"], [], "\(label): every arrow drawn")
    expectEqual(summary["extraPills"], 0, "\(label): no pill the plan didn't make")
}

/// No run warned but to say a big drawing is bigger than the window (the camera is the user's), and none pushed a shape past another.
@MainActor private func expectNoWarnings(_ run: DigestRun, _ label: String) throws {
    for (name, result) in try run.results() {
        let warnings = result["warnings"]?.arrayValue ?? []
        let said = warnings.compactMap { $0["message"]?.stringValue }.filter { !$0.contains("landed outside the view") }
        expectEqual(said, [], "\(label): \(name) warned")
        expect(!(result["changes"]?.arrayValue ?? []).contains { $0["pushedPast"] != nil }, "\(label): \(name) pushed a shape past another")
    }
}

/// The shapes of the file that are public, by title.
@MainActor private func publicTitles(in editor: CanvasEditor, digestRoot: String?) -> Set<String> {
    var found = Set<String>()
    var boards: [BoardID] = [.root]
    var next = 0
    while next < boards.count {
        let board = boards[next]
        next += 1
        for record in editor.contents(of: board).shapes {
            if record.kind == Subboard.kind { boards.append(BoardID(owner: record.id)) }
            if record[PublicProperty.self] == true, let title = editor.registry.title(of: record) { found.insert(title) }
        }
    }
    return found
}

/// The titles `canvas query` answers for a query on a board, in order.
@MainActor private func queried(_ server: CommandServer, _ board: BoardDocument, _ query: String) throws -> [String] {
    let answer = try canvas(server, ["query", "--board", "\(board.number)", "--brief", "--limit", "10000", query])
    expectEqual(answer.status, 0, answer.error)
    return try require(JSON(text: answer.output)["rows"]?.arrayValue).compactMap { $0["title"]?.stringValue }
}

/// The titles a digest says point at `hub`, from the digest itself.
private func sources(of hub: String, in digest: JSON) -> [String] {
    (digest["edges"]?.arrayValue ?? []).filter { $0["to"]?.stringValue == hub }.compactMap { $0["from"]?.stringValue }
}

@MainActor let digestTests = Suite("canvas-digest: the skill's tool under jsc, and `digest all` against the app's command server", [
    test("the tool's unit tests pass under jsc") {
        let result = try run(URL(fileURLWithPath: jsc), [skillURL("tool/test/run.js").path], timeout: 280)
        expectEqual(result.status, 0, result.output + result.error)
        let failures = result.output.split(separator: "\n").filter { $0.hasPrefix("FAIL") || $0.hasPrefix("ERROR") }
        expectEqual(failures.map(String.init), [], "no test failed")
        let tally = result.output.split(separator: "\n").last { $0.contains(" passed, ") }.map(String.init) ?? ""
        expect(tally.hasSuffix(" passed, 0 failed"), "the tally: \(tally)")
        expect((Int(tally.split(separator: " ").first ?? "") ?? 0) >= 30, "the tests ran: \(tally)")
    },

    test("digest all on Acme: into a subboard of an open board, every shape and pill on its plan, nothing warned, only what the run made public, and what points at a hub answers as it does with nothing promoted") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let promoted = windowedBoard(), plain = windowedBoard()
        defer { promoted.close(); plain.close() }
        let server = try startCommandServer(boards: [promoted, plain], frontmost: promoted)
        defer { server.stop() }
        let folder = try scratchFolder("acme")
        defer { try? FileManager.default.removeItem(at: folder) }

        let run = try runDigest("all", "acme", server: server, target: ["--board", "\(promoted.number)", "--into", "Acme map"], out: folder.appendingPathComponent("promoted"))
        expectEqual(run.process.status, 0, run.process.output + run.process.error)
        expect(run.process.output.contains("verify ok"), run.process.output)
        expect(run.process.output.contains("public ("), "the summary says what is public: \(run.process.output)")
        let plan = try run.plan, report = try run.report
        expectEqual(plan["into"], "Acme map")
        expectEqual(plan["runs"]?.arrayValue?.first, "00-into.draw")
        try expectOnPlan(run, board: promoted, digestRoot: "Acme map", "Acme")
        try expectNoWarnings(run, "Acme")
        expect((report["promotions"]?.arrayValue?.count ?? 0) > 0, "Acme has hubs worth a pill")

        // D11: public is what the report names, every one made by this run
        let reported = Set(report["public"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        expectEqual(publicTitles(in: promoted.editor, digestRoot: "Acme map"), reported, "the public shapes are the report's")
        expect(!reported.isEmpty)
        for title in reported { expect(report["publicWhy"]?[title]?.stringValue?.isEmpty == false, "\(title) has a reason") }

        // the same digest with nothing promoted, on another board
        let off = try runDigest("all", "acme", server: server, target: ["--board", "\(plain.number)", "--into", "Acme map"], extra: ["--promote", "off"], out: folder.appendingPathComponent("plain"))
        expectEqual(off.process.status, 0, off.process.output + off.process.error)
        expectEqual(try off.report["promotions"]?.arrayValue?.count, 0, "nothing promoted")
        try expectNoWarnings(off, "Acme, nothing promoted")

        let digest = try json(fixture("acme"))
        // a move changes how an edge is drawn, never what it says: what points at a promoted shape, and at each shape a
        // fanned-out one points at, answers the same with the pills and without
        var moved = 0
        for promotion in try require(report["promotions"]?.arrayValue) {
            let node = try require(promotion["node"]?.stringValue)
            let ends = promotion["mode"] == "out"
                ? (digest["edges"]?.arrayValue ?? []).filter { $0["from"]?.stringValue == node }.compactMap { $0["to"]?.stringValue }
                : [node]
            for end in Set(ends).sorted() {
                let after = try queried(server, promoted, #":edge-to("\#(end)")"#)
                let before = try queried(server, plain, #":edge-to("\#(end)")"#)
                expectEqual(after.sorted(), before.sorted(), "what points at \(end), with and without the pills of \(node)")
                expectEqual(after.sorted(), Set(sources(of: end, in: digest)).sorted(), "and the digest's own edges")
                expect(!after.isEmpty, "\(end) is pointed at")
                moved += 1
            }
        }
        expect(moved > 0, "a move was checked")
        expect((try require(report["totals"]?["pills"]?.numberValue)) > (try require(off.report["totals"]?["pills"]?.numberValue)), "promotion made pills")
    },

    test("digest all on a 3-level tree: a subboard holding a frame holding a frame, edges across boards through public shapes and pills") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("tree")
        defer { try? FileManager.default.removeItem(at: folder) }

        let run = try runDigest("all", "tree", server: server, target: ["--board", "\(board.number)", "--into", "Tree map"], out: folder)
        expectEqual(run.process.status, 0, run.process.output + run.process.error)
        expect(run.process.output.contains("verify ok"), run.process.output)
        let plan = try run.plan, report = try run.report
        expect((plan["boards"]?.arrayValue?.count ?? 0) >= 2, "the subboard has a board of its own")
        try expectOnPlan(run, board: board, digestRoot: "Tree map", "tree")
        try expectNoWarnings(run, "tree")
        expectEqual(publicTitles(in: board.editor, digestRoot: "Tree map"), Set(report["public"]?.arrayValue?.compactMap(\.stringValue) ?? []))
        // an edge across boards is read as it was written
        let digest = try json(fixture("tree"))
        let crossing = (digest["edges"]?.arrayValue ?? []).compactMap { edge -> (String, String)? in
            guard let from = edge["from"]?.stringValue, let to = edge["to"]?.stringValue else { return nil }
            return (from, to)
        }
        let hubs = Set(crossing.map(\.1)).intersection(Set(report["public"]?.arrayValue?.compactMap(\.stringValue) ?? []))
        expect(!hubs.isEmpty, "the tree has public ends")
        for hub in hubs.sorted() {
            expectEqual(try queried(server, board, #":edge-to("\#(hub)")"#).sorted(), Set(sources(of: hub, in: digest)).sorted(), "what points at \(hub)")
        }
    },

    test("digest all on a flat graph of 60 notes, into a new file: packed, hubs promoted, every shape and pill on its plan") {
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
        let run = try runDigest("all", "flat60", server: server, target: ["--new-file", file.path], out: folder.appendingPathComponent("out"))
        expectEqual(run.process.status, 0, run.process.output + run.process.error)
        expect(run.process.output.contains("verify ok"), run.process.output)
        let board = try require(opened.boards.first)
        expectEqual(board.fileURL?.lastPathComponent, "Flat.canvasboard")
        let plan = try run.plan, report = try run.report
        expectEqual(plan["boards"]?.arrayValue?.count, 1)
        expectEqual(plan["into"], .null, "the digest is the new file's board")
        try expectOnPlan(run, board: board, digestRoot: nil, "flat60")
        try expectNoWarnings(run, "flat60")
        expect((report["promotions"]?.arrayValue?.count ?? 0) > 0, "hubs promoted")
        expectEqual(publicTitles(in: board.editor, digestRoot: nil), Set(report["public"]?.arrayValue?.compactMap(\.stringValue) ?? []))
        let digest = try json(fixture("flat60"))
        for promotion in try require(report["promotions"]?.arrayValue).prefix(3) {
            let hub = try require(promotion["node"]?.stringValue)
            expectEqual(try queried(server, board, #":edge-to("\#(hub)")"#).sorted(), Set(sources(of: hub, in: digest)).sorted(), "what points at \(hub)")
        }
    },

    test("a script that is not the plan stops the run before it draws, naming the shape; what was drawn before it stays") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("mismatch")
        defer { try? FileManager.default.removeItem(at: folder) }

        let out = folder.appendingPathComponent("out")
        let planned = try runDigest("plan", "acme", server: server, target: ["--into", "Acme map"], out: out)
        expectEqual(planned.process.status, 0, planned.process.output + planned.process.error)
        // the second script moved off the plan: its first note is 5 units nearer its frame's corner
        let script = out.appendingPathComponent("runs/02-root-in-1.draw")
        var text = try String(contentsOf: script, encoding: .utf8)
        let gap = try require(text.range(of: #"\(gap: [0-9]+\)"#, options: .regularExpression))
        let before = Int(text[gap].dropFirst(6).dropLast()) ?? 0
        text.replaceSubrange(gap, with: "(gap: \(max(0, before - 5)))")
        try text.write(to: script, atomically: true, encoding: .utf8)

        let drawn = try runDigest("draw", "acme", server: server, target: ["--board", "\(board.number)"], out: out)
        expectEqual(drawn.process.status, 4, drawn.process.output + drawn.process.error)
        expect(drawn.process.error.contains("MISMATCH 02-root-in-1"), drawn.process.error)
        expect(drawn.process.error.contains("delta"), "the shape that is off is named: \(drawn.process.error)")
        expect(drawn.process.error.contains("stopped before drawing 02-root-in-1.draw"), drawn.process.error)
        expect(drawn.process.error.contains("drawn already, 2 script(s): 00-into.draw 01-root-top.draw"), "it says what is on the board: \(drawn.process.error)")
        expect(drawn.process.error.contains(#"delete the subboard "Acme map""#), "and how to take it back, for a subboard: \(drawn.process.error)")
        let fileManager = FileManager.default
        expect(fileManager.fileExists(atPath: out.appendingPathComponent("results/01-root-top.json").path), "the script before it was drawn")
        expect(fileManager.fileExists(atPath: out.appendingPathComponent("results/02-root-in-1.dry.json").path), "its dry run was made")
        expect(!fileManager.fileExists(atPath: out.appendingPathComponent("results/02-root-in-1.json").path), "and it was not drawn")
        let titles = try queried(server, board, "[title]")
        expect(titles.contains("Acme map") && titles.contains("About Acme"), "what ran before stays: \(titles)")
        expect(!titles.contains("Platform team") && !titles.contains("CTO"), "and nothing of the script that stopped: \(titles)")
    },

    test("a script that is not the plan, drawn into a new file, says to close and delete the file, not to delete a subboard") {
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
        let folder = try scratchFolder("mismatch-file")
        defer { try? FileManager.default.removeItem(at: folder) }

        let out = folder.appendingPathComponent("out")
        let planned = try runDigest("plan", "acme", server: server, target: [], out: out)
        expectEqual(planned.process.status, 0, planned.process.output + planned.process.error)
        let script = out.appendingPathComponent("runs/02-root-in-1.draw")
        var text = try String(contentsOf: script, encoding: .utf8)
        let gap = try require(text.range(of: #"\(gap: [0-9]+\)"#, options: .regularExpression))
        text.replaceSubrange(gap, with: "(gap: \(max(0, (Int(text[gap].dropFirst(6).dropLast()) ?? 0) - 5)))")
        try text.write(to: script, atomically: true, encoding: .utf8)

        let file = folder.appendingPathComponent("Tampered")
        let drawn = try runDigest("draw", "acme", server: server, target: ["--new-file", file.path], out: out)
        expectEqual(drawn.process.status, 4, drawn.process.output + drawn.process.error)
        expect(drawn.process.error.contains("drawn already, 1 script(s): 01-root-top.draw"), drawn.process.error)
        expect(drawn.process.error.contains("close the new file's window without saving and delete \(file.path)"), drawn.process.error)
        expect(!drawn.process.error.contains("subboard"), "no subboard to delete: \(drawn.process.error)")
    },

    test("a draw of a plan whose titles the file has stops before anything is drawn; a plan drawn once is not drawn again; plan checks the file's titles too") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard(), clean = windowedBoard()
        defer { board.close(); clean.close() }
        let server = try startCommandServer(boards: [board, clean], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("standalone")
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try {
            let drawn = try canvas(server, ["draw", #"sticky-note "CTO" text: "Already here""#, "--board", "\(board.number)"])
            expectEqual(drawn.status, 0, drawn.error)
            return board.editor.document.shapes.count
        }()

        // the plan was made before the title came to the file: draw checks them again, as check does
        let out = folder.appendingPathComponent("acme")
        let planned = try runDigest("plan", "acme", server: server, target: ["--into", "Acme map"], out: out)
        expectEqual(planned.process.status, 0, planned.process.output + planned.process.error)
        let clash = try runDigest("draw", "acme", server: server, target: ["--board", "\(board.number)"], out: out)
        expectEqual(clash.process.status, 1, clash.process.output + clash.process.error)
        expect(clash.process.error.contains(#"error: "CTO" is already on a board in the file"#), clash.process.error)
        expect(clash.process.error.contains("nothing was drawn"), clash.process.error)
        expectEqual(board.editor.document.shapes.count, before, "nothing drawn")
        // and plan, given the board, refuses at once
        let replanned = try runDigest("plan", "acme", server: server, target: ["--board", "\(board.number)", "--into", "Acme map"], out: folder.appendingPathComponent("replanned"))
        expectEqual(replanned.process.status, 1, replanned.process.output + replanned.process.error)
        expect(replanned.process.output.contains(#"error: "CTO" is already on a board in the file"#), replanned.process.output)

        // a plan is drawn once
        let tiny = try digestFile("tiny", #"{"title": "Tiny", "nodes": [{"title": "Tiny A", "text": "a"}, {"title": "Tiny B", "text": "b"}], "edges": [{"from": "Tiny A", "to": "Tiny B"}]}"#, in: folder)
        let tinyOut = folder.appendingPathComponent("tiny")
        let first = try runDigest("all", file: tiny, server: server, target: ["--board", "\(clean.number)", "--into", "Tiny map"], out: tinyOut)
        expectEqual(first.process.status, 0, first.process.output + first.process.error)
        expect(first.process.output.contains("verify ok"), first.process.output)
        let count = clean.editor.document.shapes.count
        let again = try runDigest("draw", file: tiny, server: server, target: ["--board", "\(clean.number)"], out: tinyOut)
        expectEqual(again.process.status, 1, again.process.output + again.process.error)
        expect(again.process.error.contains("already drawn"), again.process.error)
        expectEqual(clean.editor.document.shapes.count, count, "nothing drawn the second time")
        let titles = try queried(server, clean, "[title]")
        expectEqual(titles.filter { $0 == "Tiny A" }.count, 1, "the shapes are not drawn twice")
        // plan again over a drawing, and its titles are the file's
        let second = try runDigest("plan", file: tiny, server: server, target: ["--board", "\(clean.number)", "--into", "Tiny map"], out: tinyOut)
        expectEqual(second.process.status, 1, second.process.output + second.process.error)
        expect(second.process.output.contains("already on a board in the file"), second.process.output)
    },

    test("a failure is said on standard error, with a status that is not 0: no canvas to be found, and a tool error behind a redirect; canvas is found on the PATH, and a title with \"error: \" in it is no error") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("errors")
        defer { try? FileManager.default.removeItem(at: folder) }
        let tiny = try digestFile("tiny", #"{"title": "Tiny", "nodes": [{"title": "Tiny A"}, {"title": "Tiny B"}], "edges": [{"from": "Tiny A", "to": "Tiny B"}]}"#, in: folder)

        // canvas on the PATH, and nowhere else: the driver finds it, though it has a function of its own by that name
        let lone = folder.appendingPathComponent("on-path")
        let found = try runIsolatedDriver("measure", tiny, folder: lone, canvasOnPath: true, server: server, out: lone.appendingPathComponent("out"))
        expectEqual(found.status, 0, found.output + found.error)
        expect(found.output.contains("statements measured by canvas measure"), found.output)
        expect(((try? String(contentsOf: lone.appendingPathComponent("out/measure.json"), encoding: .utf8)) ?? "").contains("shapes"), "measure.json is the app's answer")

        // and nowhere at all: said on standard error, whatever the failing command's output was going to
        let none = folder.appendingPathComponent("nowhere")
        for command in ["measure", "check", "plan"] {
            let lost = try runIsolatedDriver(command, tiny, folder: none, canvasOnPath: false, server: server, out: none.appendingPathComponent("out-\(command)"))
            expectEqual(lost.status, 1, "\(command): \(lost.output) \(lost.error)")
            expect(lost.error.contains("digest: can't find canvas: set CANVAS_CLI"), "\(command): \(lost.error)")
        }

        // a tool that fails writes into a file: what it said still reaches standard error (a cycle in `in`)
        let loop = try digestFile("loop", #"{"title": "Loop", "nodes": [{"title": "A", "kind": "frame", "in": "B"}, {"title": "B", "kind": "frame", "in": "A"}], "edges": []}"#, in: folder)
        for command in ["measure", "plan"] {
            let failed = try runDigest(command, file: loop, server: server, target: [], out: folder.appendingPathComponent("loop-\(command)"))
            expectEqual(failed.process.status, 1, "\(command): \(failed.process.output) \(failed.process.error)")
            expect(failed.process.error.contains(#""A" is in "B" is in "A""#) || failed.process.error.contains(#""B" is in "A" is in "B""#), "\(command): \(failed.process.error)")
            expect(!failed.process.error.contains("Maximum call stack"), "\(command): \(failed.process.error)")
        }
        let checked = try runDigest("check", file: loop, server: server, target: [], out: folder.appendingPathComponent("loop-check"))
        expectEqual(checked.process.status, 1, checked.process.output + checked.process.error)
        expect(checked.process.output.contains("error:") && checked.process.output.contains("circle"), checked.process.output)

        // check reads the tool's answer, not its words: a note titled with "error: " is no error
        let words = try digestFile("words", #"{"title": "Words", "nodes": [{"title": "Parse error: unexpected token"}, {"title": "Other"}], "edges": [{"from": "Other", "to": "Parse error: unexpected token"}]}"#, in: folder)
        let fine = try runDigest("check", file: words, server: server, target: ["--board", "\(board.number)", "--into", "Words map"], out: folder.appendingPathComponent("words"))
        expectEqual(fine.process.status, 0, fine.process.output + fine.process.error)
    },

    test("digest refuses what it should before drawing: a title the file has, a kind the app lacks, a plan made for another target, a missing --into") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("refuse")
        defer { try? FileManager.default.removeItem(at: folder) }
        let drawn = try canvas(server, ["draw", #"sticky-note "CTO" text: "Already here""#, "--board", "\(board.number)"])
        expectEqual(drawn.status, 0, drawn.error)
        let before = board.editor.document.shapes.count

        // Acme has a CTO: the file's title is refused, and nothing is drawn
        let clash = try runDigest("all", "acme", server: server, target: ["--board", "\(board.number)", "--into", "Acme map"], out: folder.appendingPathComponent("clash"))
        expectEqual(clash.process.status, 1, clash.process.output)
        expect(clash.process.output.contains("error:") && clash.process.output.contains("already on a board in the file"), clash.process.output)
        expectEqual(board.editor.document.shapes.count, before, "nothing drawn")

        // a plan made for a new file isn't drawn among the shapes of a board that is open
        let made = try runDigest("plan", "acme", server: server, target: [], out: folder.appendingPathComponent("bare"))
        expectEqual(made.process.status, 0, made.process.output + made.process.error)
        let bare = try runDigest("draw", "acme", server: server, target: ["--board", "\(board.number)"], out: folder.appendingPathComponent("bare"))
        expectEqual(bare.process.status, 1)
        expect(bare.process.error.contains("--into"), bare.process.error)
        expectEqual(board.editor.document.shapes.count, before, "nothing drawn")
        let missing = try runDigest("plan", "acme", server: server, target: ["--board", "\(board.number)"], out: folder.appendingPathComponent("bare"))
        expectEqual(missing.process.status, 1)
        expect(missing.process.error.contains("--into TITLE"), missing.process.error)

        // a digest of an unknown kind
        let bad = folder.appendingPathComponent("bad.digest.json")
        try #"{"title": "Bad", "nodes": [{"title": "A", "kind": "hexagon"}], "edges": []}"#.write(to: bad, atomically: true, encoding: .utf8)
        let kind = try run(skillURL("digest"), ["check", bad.path, "--out", folder.appendingPathComponent("bad").path],
                           environment: ["CANVAS_CLI": builtExecutable("CanvasCLI").path, "CANVAS_SOCKET": server.path])
        expectEqual(kind.status, 1)
        expect(kind.output.contains("hexagon"), kind.output)
    },

    test("digest drawn as the empty board in front, then again in its place (--replace), never among shapes it didn't make") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("replace")
        defer { try? FileManager.default.removeItem(at: folder) }
        let out = folder.appendingPathComponent("tree")

        // the board in front is empty: the digest is drawn as it, and what it made is kept for the next run
        let first = try runDigest("all", "tree", server: server, target: ["--board", "front", "--replace"], out: out)
        expectEqual(first.process.status, 0, first.process.output + first.process.error)
        expect(first.process.output.contains("verify ok"), first.process.output)
        expectEqual(try first.plan["into"], .null, "the digest is the board's own")
        try expectOnPlan(first, board: board, digestRoot: nil, "tree, first")
        let drawn = board.editor.file.shapeCount
        expect(drawn > 0, "drawn")

        // again: the first drawing is taken back, in one step, and drawn anew in its place
        let second = try runDigest("all", "tree", server: server, target: ["--board", "front", "--replace"], out: out)
        expectEqual(second.process.status, 0, second.process.output + second.process.error)
        expect(second.process.output.contains("replace: took back the last drawing"), second.process.output)
        expect(second.process.output.contains("verify ok"), second.process.output)
        expectEqual(board.editor.file.shapeCount, drawn, "the same drawing, once")
        try expectOnPlan(second, board: board, digestRoot: nil, "tree, second")
        try expectNoWarnings(second, "tree, second")

        // a drawing in place of the last one that stops part way: until it is whole its record is of both drawings, so the next run
        // knows the board for its own whichever it holds. First as it was left: part of the new drawing
        @MainActor func stopPartWay() throws -> DigestRun {
            let planned = try runDigest("plan", "tree", server: server, target: ["--board", "front", "--replace"], out: out)
            expectEqual(planned.process.status, 0, planned.process.output + planned.process.error)
            // a script after the first moved off the plan: a note 5 units nearer its frame's corner
            let names = try planned.plan["runs"]?.arrayValue?.compactMap(\.stringValue) ?? []
            var moved = false
            for name in names.dropFirst() where !moved {
                let script = out.appendingPathComponent("runs/\(name)")
                var text = try String(contentsOf: script, encoding: .utf8)
                guard let gap = text.range(of: #"\(gap: [0-9]+\)"#, options: .regularExpression) else { continue }
                text.replaceSubrange(gap, with: "(gap: \(max(0, (Int(text[gap].dropFirst(6).dropLast()) ?? 0) - 5)))")
                try text.write(to: script, atomically: true, encoding: .utf8)
                moved = true
            }
            expect(moved, "a script to move off the plan")
            let stopped = try runDigest("draw", "tree", server: server, target: ["--board", "front", "--replace"], out: out)
            expect(stopped.process.status == 1 || stopped.process.status == 4, "the dry run is refused, or is not the plan: \(stopped.process.status) \(stopped.process.output)\(stopped.process.error)")
            expect(stopped.process.output.contains("replace: took back the last drawing"), stopped.process.output)
            expect(stopped.process.error.contains("drawn already") && stopped.process.error.contains("brings back the drawing this one replaced"), stopped.process.error)
            expect(board.editor.file.shapeCount > 0 && board.editor.file.shapeCount < drawn, "part of the new drawing is on the board")
            let record = try json(out.appendingPathComponent("drawn.json"))
            expectEqual(record["shapes"]?.intValue, board.editor.file.shapeCount, "the record is of both drawings: how many shapes the file holds as this one stopped")
            expectEqual(record["was"]?.intValue, drawn, "and how many it held before the last one was taken back")
            return stopped
        }
        @MainActor func drawnAgain(_ label: String) throws {
            let again = try runDigest("all", "tree", server: server, target: ["--board", "front", "--replace"], out: out)
            expectEqual(again.process.status, 0, "\(label): \(again.process.output)\(again.process.error)")
            expect(again.process.output.contains("replace: took back the last drawing") && again.process.output.contains("verify ok"), "\(label): \(again.process.output)")
            expectEqual(board.editor.file.shapeCount, drawn, "\(label): the same drawing, once")
            expectEqual(try json(out.appendingPathComponent("drawn.json"))["shapes"]?.intValue, drawn, "\(label): a whole drawing's record has its count again")
            expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("drawn.prev.json").path), "\(label): and the last one's record is let go")
        }
        _ = try stopPartWay()
        try drawnAgain("over part of a drawing")
        // then undone, as the driver says: each script, and once more for the drawing it replaced, which is back whole
        _ = try stopPartWay()
        for _ in 0..<20 where board.editor.file.shapeCount != drawn { board.editor.undo() }
        expectEqual(board.editor.file.shapeCount, drawn, "Undo Draw brought the last drawing back")
        // an arrow the user draws on it now is still a shape the drawing didn't make: nothing is taken back
        let added = try canvas(server, ["draw", #"edge "Runbook" -> "Web app""#, "--board", "\(board.number)"])
        expectEqual(added.status, 0, added.error)
        let kept = try runDigest("all", "tree", server: server, target: ["--board", "front", "--replace"], out: out)
        expectEqual(kept.process.status, 1, kept.process.output)
        expect(kept.process.error.contains("1 shape(s) more than"), kept.process.error)
        expectEqual(board.editor.file.shapeCount, drawn + 1, "nothing taken back, nothing drawn")
        let removed = try canvas(server, ["draw", #"delete edge "Runbook" -> "Web app""#, "--board", "\(board.number)"])
        expectEqual(removed.status, 0, removed.error)
        try drawnAgain("over the last drawing, undone back")

        // ready says before any work what the take-back would be refused for: a shape of the drawing the user locked
        let locked = try canvas(server, ["draw", #"sticky-note "Gateway" locked: true"#, "--board", "\(board.number)"])
        expectEqual(locked.status, 0, locked.error)
        let unready = try runDigest("ready", "tree", server: server, target: ["--board", "front", "--replace"], out: out)
        expectEqual(unready.process.status, 1, unready.process.output)
        expect(unready.process.error.contains("would refuse to take back the last drawing"), unready.process.error)
        expectEqual(board.editor.file.shapeCount, drawn, "nothing taken back")
        let unlocked = try canvas(server, ["draw", #"sticky-note "Gateway" locked: false"#, "--board", "\(board.number)"])
        expectEqual(unlocked.status, 0, unlocked.error)
        // ... and from a window that shows a board inside the drawing it shows the root first, as the draw does: the app deletes no
        // shape that holds the board shown, which is no reason to refuse
        let inside = try canvas(server, ["show", "Backend", "--board", "\(board.number)"])
        expectEqual(inside.status, 0, inside.error)
        let ready = try runDigest("ready", "tree", server: server, target: ["--board", "front", "--replace"], out: out)
        expectEqual(ready.process.status, 0, ready.process.output + ready.process.error)
        expect(ready.process.output.contains("shows the board's root now") && ready.process.output.contains("which the new one replaces"), ready.process.output)
        expectEqual(board.editor.file.shapeCount, drawn, "ready takes nothing back")
        try drawnAgain("from a board inside the drawing")
        // a canvas, or an app, from before the skill's newest command is said by ready, not at the measuring step: here a canvas
        // that answers everything but measure
        let old = folder.appendingPathComponent("canvas-old")
        try "#!/bin/sh\nif [ \"$1\" = measure ]; then echo 'unknown command: measure' >&2; exit 2; fi\nexec \"\(builtExecutable("CanvasCLI").path)\" \"$@\"\n".write(to: old, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: old.path)
        let stale = try run(skillURL("digest"), ["ready", fixture("tree").path, "--board", "front", "--replace", "--out", out.path],
                            environment: ["CANVAS_CLI": old.path, "CANVAS_SOCKET": server.path])
        expectEqual(stale.status, 1, stale.output)
        expect(stale.error.contains("older than this skill needs") && stale.error.contains("unknown command: measure"), stale.error)
        // a drawing into a subboard is drawn again in its place too, from a window that shows the subboard's own board: the app deletes
        // no shape that holds the board shown, and the subboard is on the root, so the root is shown first
        do {
            let second = windowedBoard()
            defer { second.close() }
            let other = try startCommandServer(boards: [second], frontmost: second)
            defer { other.stop() }
            let into = folder.appendingPathComponent("into")
            let made = try runDigest("all", "tree", server: other, target: ["--board", "front", "--into", "Map", "--replace"], out: into)
            expectEqual(made.process.status, 0, made.process.output + made.process.error)
            let held = second.editor.file.shapeCount
            let opened = try canvas(other, ["show", "Map", "--board", "\(second.number)"])
            expectEqual(opened.status, 0, opened.error)
            let remade = try runDigest("all", "tree", server: other, target: ["--board", "front", "--into", "Map", "--replace"], out: into)
            expectEqual(remade.process.status, 0, remade.process.output + remade.process.error)
            expect(remade.process.output.contains("shows the board's root now") && remade.process.output.contains("replace: took back the last drawing") && remade.process.output.contains("verify ok"), remade.process.output)
            expectEqual(second.editor.file.shapeCount, held, "the same drawing, once")
        }
        // a subboard titled as a shape of the file, and a new file in a folder that isn't there, are said by ready too
        let titled = try runDigest("ready", "tree", server: server, target: ["--board", "\(board.number)", "--into", "gateway"], out: folder.appendingPathComponent("titled"))
        expectEqual(titled.process.status, 1, titled.process.output)
        expect(titled.process.error.contains(#"has a shape titled "gateway" already"#), titled.process.error)
        let nowhere = try runDigest("ready", "tree", server: server, target: ["--new-file", folder.appendingPathComponent("no/such/board").path], out: folder.appendingPathComponent("nowhere"))
        expectEqual(nowhere.process.status, 1, nowhere.process.output)
        expect(nowhere.process.error.contains("there's no folder"), nowhere.process.error)

        // an arrow the user drew between two of the digest's notes: a shape more than the drawing made, so nothing is taken back or drawn
        let arrow = try canvas(server, ["draw", #"edge "Runbook" -> "Web app""#, "--board", "\(board.number)"])
        expectEqual(arrow.status, 0, arrow.error)
        expectEqual(board.editor.file.shapeCount, drawn + 1, "the arrow is a shape of its own")
        let crowded = try runDigest("all", "tree", server: server, target: ["--board", "front", "--replace"], out: out)
        expectEqual(crowded.process.status, 1, crowded.process.output)
        expect(crowded.process.error.contains("1 shape(s) more than"), crowded.process.error)
        expectEqual(board.editor.file.shapeCount, drawn + 1, "nothing taken back, nothing drawn")
        let unarrow = try canvas(server, ["draw", #"delete edge "Runbook" -> "Web app""#, "--board", "\(board.number)"])
        expectEqual(unarrow.status, 0, unarrow.error)

        // a shape the user drew, titled as the digest's "Runbook" but for its case: another shape, so nothing is taken back or drawn
        let mine = try canvas(server, ["draw", #"sticky-note "runbook" text: "Not the digest's""#, "--board", "\(board.number)"])
        expectEqual(mine.status, 0, mine.error)
        let withMine = board.editor.file.shapeCount
        let third = try runDigest("all", "tree", server: server, target: ["--board", "front", "--replace"], out: out)
        expectEqual(third.process.status, 1, third.process.output)
        expect(third.process.error.contains("didn't make") && third.process.error.contains("runbook"), third.process.error)
        expectEqual(board.editor.file.shapeCount, withMine, "nothing taken back, nothing drawn")

        // without --replace, a board that isn't empty is never drawn as the digest
        let bare = try runDigest("all", "tree", server: server, target: ["--board", "\(board.number)"], out: folder.appendingPathComponent("bare"))
        expectEqual(bare.process.status, 1, bare.process.output)
        expect(bare.process.error.contains("isn't empty") && bare.process.error.contains("--into TITLE"), bare.process.error)
        expectEqual(board.editor.file.shapeCount, withMine, "nothing drawn")
    },

    test("ingest draws a codebase from its model in one command, spec.py as overrides, and a rerun draws it again in place") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("ingest")
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = folder.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try tinyModel.write(to: project.appendingPathComponent("model.json"), atomically: true, encoding: .utf8)
        // a spec is optional overrides: this one puts App's files in a frame but leaves out Main.swift, and names a module the code lacks
        try tinySpec.write(to: project.appendingPathComponent("spec.py"), atomically: true, encoding: .utf8)
        let ingest = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dogfood/model/ingest")
        @MainActor func runIngest() throws -> ProcessOutput {
            try run(ingest, ["--skip-read"], environment: ["CANVAS_CLI": builtExecutable("CanvasCLI").path, "CANVAS_SOCKET": server.path, "PROJECT": project.path],
                    timeout: 280)
        }

        let first = try runIngest()
        expectEqual(first.status, 0, first.output + first.error)
        expect(first.output.contains("verify ok"), first.output)
        expect(first.error.contains("leave out Main.swift") && first.error.contains("Ghost"), "what the spec leaves out or lacks is said: \(first.error)")
        let editor = board.editor
        let titles = Set(editor.document.shapes.compactMap { editor.registry.title(of: $0) })
        expect(titles.isSuperset(of: ["About TinyPackage", "Apps", "Foundations", "App", "Core"]), "the root: its header (the name the reader found), the bands, the modules: \(titles.sorted())")
        let apps = try json(project.appendingPathComponent("digest.json"))
        expectEqual(apps["title"], "TinyPackage")
        let nodes = apps["nodes"]?.arrayValue ?? []
        expectEqual(nodes.first { $0["title"] == "Main.swift" }?["in"], "App/", "a file the spec leaves out is in a frame of its own, never dropped")
        expectEqual(nodes.first { $0["title"] == "Apps" }?["rank"], 0)
        expectEqual(nodes.first { $0["title"] == "Foundations" }?["rank"], 1)
        let drawn = editor.file.shapeCount

        let second = try runIngest()
        expectEqual(second.status, 0, second.output + second.error)
        expect(second.output.contains("ready: board") && second.output.contains("replaces"), "it says up front that it replaces: \(second.output)")
        expect(second.output.contains("replace: took back the last drawing") && second.output.contains("verify ok"), second.output)
        expectEqual(editor.file.shapeCount, drawn, "drawn again in its place, once")

        // what would stop a draw is said before anything slow, and before a digest is made: a board that holds another drawing
        // (another project's ingestion has no record of this one), and a file that is there already
        let other = folder.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try tinyModel.write(to: other.appendingPathComponent("model.json"), atomically: true, encoding: .utf8)
        let refused = try run(ingest, ["--skip-read"], environment: ["CANVAS_CLI": builtExecutable("CanvasCLI").path, "CANVAS_SOCKET": server.path, "PROJECT": other.path], timeout: 280)
        expectEqual(refused.status, 1, refused.output)
        expect(refused.error.contains("isn't empty"), refused.error)
        expect(refused.error.contains("ingest --new-file PATH"), "and what to do about it, in ingest's own options: \(refused.error)")
        expect(!FileManager.default.fileExists(atPath: other.appendingPathComponent("digest.json").path), "refused before the digest was made")
        expectEqual(editor.file.shapeCount, drawn, "nothing drawn or taken back")
        let there = folder.appendingPathComponent("there.canvasboard")
        try "x".write(to: there, atomically: true, encoding: .utf8)
        let taken = try run(ingest, ["--skip-read", "--new-file", there.path], environment: ["CANVAS_CLI": builtExecutable("CanvasCLI").path, "CANVAS_SOCKET": server.path, "PROJECT": other.path], timeout: 280)
        expectEqual(taken.status, 1, taken.output)
        expect(taken.error.contains("there is a file at"), taken.error)
        let down = try run(ingest, ["--skip-read"], environment: ["CANVAS_CLI": builtExecutable("CanvasCLI").path, "CANVAS_SOCKET": temporarySocketPath(), "PROJECT": other.path], timeout: 280)
        expectEqual(down.status, 1, down.output)
        expect(down.error.contains("isn't running"), "an app that isn't running is said, with how to start it: \(down.error)")
    },

    test("ingest draws a codebase whose names clash, run long or hold brackets: each title is given out once, said, and nothing stops the run") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("names")
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = folder.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let long = "@my-company/" + String(repeating: "very-long-package-name-", count: 4) + "x"
        try awkwardModel(long: long, big: false).write(to: project.appendingPathComponent("model.json"), atomically: true, encoding: .utf8)
        let ingest = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dogfood/model/ingest")
        let drawn = try run(ingest, ["--skip-read"], environment: ["CANVAS_CLI": builtExecutable("CanvasCLI").path, "CANVAS_SOCKET": server.path, "PROJECT": project.path], timeout: 280)
        expectEqual(drawn.status, 0, drawn.output + drawn.error)
        expect(drawn.output.contains("verify ok"), drawn.output)
        let editor = board.editor
        let titles = Set(editor.document.shapes.compactMap { editor.registry.title(of: $0) })
        // a module called what a band is keeps its name and the band gives way; a name over a card's longest keeps its end
        expect(titles.isSuperset(of: ["[locale]", "Level 1", "Level 1 (layer)", #"back\slash"#]), "\(titles.sorted())")
        expect(titles.contains { $0.hasPrefix("…") && $0.hasSuffix("very-long-package-name-x") && $0.count <= 74 }, "\(titles.sorted())")
        expect(!titles.contains(long), "the long name itself is nobody's title")
        for said in ["the band Level 1 is titled \"Level 1 (layer)\"", "is over 74 characters", "C/main.swift is titled \"C/main.swift (2)\""] {
            expect(drawn.error.contains(said), "said: \(said) in \(drawn.error)")
        }
        // app's header mentions what it imports, each by its card's title: a ] and a \\ in one are written so the mention names its shape
        let digest = try json(project.appendingPathComponent("digest.json"))
        let mains = (digest["nodes"]?.arrayValue ?? []).filter { $0["in"] == "C" || $0["in"] == "a" || $0["in"] == "b" || $0["in"] == "c (C)" || $0["in"] == "C/" }.compactMap { $0["title"]?.stringValue }
        expect(Set(mains).isSuperset(of: ["c/main.swift", "b/main.swift", "C/main.swift (2)"]), "paths that differ only by case are two titles: \(mains)")
        expect(mains.contains("half\u{FFFD}.swift"), "a name that isn't whole text is drawn with U+FFFD where it breaks: \(mains)")
        let app = digest["nodes"]?.arrayValue?.first { $0["title"] == "app" }?["text"]?.stringValue ?? ""
        expect(app.contains(#"@[[locale\]]"#) && app.contains(#"@[back\\slash]"#), app)
        expect(digest["text"]?.stringValue?.hasPrefix(#"Awkward \@[names]"#) == true, "the repository's own name is text, never a mention: \(digest["text"] ?? .null)")

        // a module big enough for its folders to have boards, two of them the same but for their case: the digest passes check
        let big = folder.appendingPathComponent("big")
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        try awkwardModel(long: long, big: true).write(to: big.appendingPathComponent("model.json"), atomically: true, encoding: .utf8)
        let made = try run(URL(fileURLWithPath: "/usr/bin/env"), ["python3", ingest.deletingLastPathComponent().appendingPathComponent("to_digest.py").path, big.appendingPathComponent("digest.json").path],
                           environment: ["PROJECT": big.path], timeout: 120)
        expectEqual(made.status, 0, made.output + made.error)
        expect(made.error.contains("the folder Big/utils is titled \"Big/utils (2)\""), made.error)
        expect(made.error.contains("Big/x: a module has that name, so the folder gets no board of its own"), made.error)
        let bigNodes = try json(big.appendingPathComponent("digest.json"))["nodes"]?.arrayValue ?? []
        expectEqual(bigNodes.filter { $0["title"] == "Big/x" }.count, 1, "the module Big/x is one card, and Big's folder x is not another")
        expectEqual(bigNodes.first { $0["title"] == "its.ts" }?["in"], "Big/x", "the module's file is on its board")
        expect(bigNodes.first { $0["title"] == "one.ts" }?["in"] != "Big/x", "and the folder's files stay on Big's: \(String(describing: bigNodes.first { $0["title"] == "one.ts" }?["in"]))")
        let checked = try tool(["check", big.appendingPathComponent("digest.json").path])
        expectEqual(checked.status, 0, checked.output + checked.error)
        expectEqual(try JSON(text: checked.output)["errors"], .array([]), "check finds nothing wrong: \(checked.output)")
    },

    test("Swift's index is kept from run to run: a module is type-checked again only when its sources or the interfaces it reads changed, and its uses are read from a store a module") {
        let folder = try scratchFolder("index")
        defer { try? FileManager.default.removeItem(at: folder) }
        // the index where ingest keeps a project's: <PROJECT>/.index
        let repo = folder.appendingPathComponent("repo"), project = folder.appendingPathComponent("project")
        let scratch = project.appendingPathComponent(".index"), model = folder.appendingPathComponent("model.json")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        func write(_ path: String, _ text: String) throws {
            let file = repo.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        // Kit uses Core, KitTests uses Kit, and Loose uses nothing and nothing uses it
        let core = "public func core() -> Int {\n    let one = 1\n    return one\n}\n", kit = "import Core\n\npublic func kit() -> Int { core() + 1 }\n"
        try write("Package.swift", tinyPackage(loose: true))
        try write("Sources/Core/Core.swift", core)
        try write("Sources/Kit/Kit.swift", kit)
        try write("Sources/Loose/Loose.swift", "public func loose() {}\n")
        try write("Tests/KitTests/KitTests.swift", "import Kit\n\nfunc twice() -> Int { kit() * 2 }\n")
        let scripts = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dogfood/model")
        // the SDK build.sh chose for this build, so the index build needn't ask the compiler about one it rejects (ten seconds)
        let sdk = (try? String(contentsOfFile: "build/.sdk", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        @MainActor func python(_ script: String, _ arguments: [String]) throws -> ProcessOutput {
            try run(URL(fileURLWithPath: "/usr/bin/env"), ["python3", scripts.appendingPathComponent(script).path] + arguments,
                    environment: sdk.map { ["SDKROOT": $0] } ?? [:], timeout: 280)
        }
        /// What a build of the index says it made.
        @MainActor func build() throws -> String {
            let built = try python("swift_index_build.py", [repo.path, scratch.path])
            expectEqual(built.status, 0, built.output + built.error)
            return built.output
        }
        /// Which file uses which, as the readers write the model from the stores there are.
        @MainActor func uses(store: String = "store") throws -> Set<String> {
            let analyzed = try python("swift_analyze.py", [repo.path, model.path])
            expectEqual(analyzed.status, 0, analyzed.output + analyzed.error)
            let read = try python("swift_index_read.py", [scratch.appendingPathComponent(store).path, model.path])
            expectEqual(read.status, 0, read.output + read.error)
            func file(_ end: JSON?) -> String { (end?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: "/") }
            return Set((try json(model)["uses"]?.arrayValue ?? []).map { "\(file($0["from"])) > \(file($0["to"]))" })
        }
        let both: Set = ["Kit/Kit.swift > Core/Core.swift", "KitTests/KitTests.swift > Kit/Kit.swift"]

        var made = try build()
        expect(made.contains("interfaces: made 2 of 2 (Core, Kit)\n") && made.contains("indexes: made 4 of 4 (Core, Kit, KitTests, Loose)\n"), made)
        expectEqual(try uses(), both)
        expectEqual(try uses(store: "store/Kit"), [], "one store is read as one (Xcode's, or swift build's): Kit's alone has no file that defines what Kit uses")
        made = try build()
        expect(made.contains("interfaces: made 0 of 2\n") && made.contains("indexes: made 0 of 4\n") && made.contains("no module changed"), "nothing changed, nothing compiled: \(made)")

        // an edit inside a function: its module again and no other, since its interface comes out the same bytes
        try write("Sources/Core/Core.swift", core.replacingOccurrences(of: "one = 1", with: "one = 2 - 1"))
        made = try build()
        expect(made.contains("interfaces: made 1 of 2 (Core)\n") && made.contains("indexes: made 1 of 4 (Core)\n"), made)

        // an edit to what it declares: the modules that depend on it too, directly or through another, and none that doesn't
        try write("Sources/Core/Core.swift", core + "\npublic func more() {}\n")
        made = try build()
        expect(made.contains("interfaces: made 2 of 2 (Core, Kit)\n") && made.contains("indexes: made 3 of 4 (Core, Kit, KitTests)\n"), made)

        // a compile that fails is said and changes nothing: the index kept is still whole, and still what its sources make once
        // they are back as they last compiled (the interface, which skips the body that was wrong, was made from each edit)
        try write("Sources/Kit/Kit.swift", kit.replacingOccurrences(of: "+ 1", with: "+ \"one\""))
        let failed = try python("swift_index_build.py", [repo.path, scratch.path])
        expect(failed.status != 0 && failed.output.contains("index Kit: failed") && failed.error.contains("indexes failed: Kit"), failed.output + failed.error)
        expectEqual(try uses(), both, "the last index that worked is what is read")
        try write("Sources/Kit/Kit.swift", kit)
        made = try build()
        expect(made.contains("interfaces: made 1 of 2 (Kit)\n") && made.contains("indexes: made 0 of 4\n"), made)
        expectEqual(try uses(), both)

        // an import Package.swift doesn't declare fails, as it does in a build: a compile reads only the interfaces its mark
        // covers, so no index is kept that an edit to an undeclared module would leave stale
        try write("Sources/Loose/Loose.swift", "import Core\n\npublic func loose() -> Int { core() }\n")
        let undeclared = try python("swift_index_build.py", [repo.path, scratch.path])
        expect(undeclared.status != 0 && undeclared.output.contains("index Loose: failed") && undeclared.output.contains("no such module 'Core'"), undeclared.output + undeclared.error)

        // a module that is gone leaves nothing behind: its store would be read as code that is there
        try write("Package.swift", tinyPackage(loose: false))
        try FileManager.default.removeItem(at: repo.appendingPathComponent("Sources/Loose"))
        made = try build()
        expect(made.contains("interfaces: made 0 of 2\n") && made.contains("indexes: made 0 of 3\n"), made)
        let stores = try FileManager.default.contentsOfDirectory(atPath: scratch.appendingPathComponent("store").path).sorted()
        expectEqual(stores, ["Core", "Kit", "KitTests"])
        expectEqual(try uses(), both)

        // and ingest, reading the package for itself: it type-checks nothing, the index being as the code is, and draws what it read
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        var environment = ["CANVAS_CLI": builtExecutable("CanvasCLI").path, "CANVAS_SOCKET": server.path, "PROJECT": project.path]
        if let sdk { environment["SDKROOT"] = sdk }
        let drawn = try run(scripts.appendingPathComponent("ingest"), [repo.path], environment: environment, timeout: 280)
        expectEqual(drawn.status, 0, drawn.output + drawn.error)
        expect(drawn.output.contains("ingest: no module changed: none of the 3 type-checked") && drawn.output.contains("verify ok"), drawn.output)
        let titles = Set(board.editor.document.shapes.compactMap { board.editor.registry.title(of: $0) })
        expect(titles.isSuperset(of: ["About Tiny", "Core", "Kit"]), "the package as the board in front: \(titles.sorted())")
        let edges = try json(project.appendingPathComponent("digest.json"))["edges"]?.arrayValue ?? []
        expect(edges.contains { $0["from"] == "Kit.swift" && $0["to"] == "Core.swift" }, "Kit.swift's use of Core.swift is an edge of the digest: \(edges)")
    },
])

/// A package of three modules and a test target, as `Package.swift` declares them: Kit depends on Core, KitTests on Kit, and Loose
/// (when asked for) on nothing.
private func tinyPackage(loose: Bool) -> String {
    let targets = [#".target(name: "Core")"#, #".target(name: "Kit", dependencies: ["Core"])"#] + (loose ? [#".target(name: "Loose")"#] : [])
        + [#".testTarget(name: "KitTests", dependencies: ["Kit"])"#]
    return "// swift-tools-version: 5.9\nimport PackageDescription\n\nlet package = Package(name: \"Tiny\", targets: [\n"
        + targets.map { "    \($0),\n" }.joined() + "])\n"
}

/// A codebase whose names are awkward, as a reader writes model.json: a module called what a band is ("Level 1"), ones with a
/// bracket and a backslash in their names, one whose name is over 80 characters, files whose paths differ only by case, a file whose
/// name isn't whole text, a doc with an `@[` in it, and, with `big`, a module of 63 files in two folders that differ only by case and
/// a third named as another module is.
private func awkwardModel(long: String, big: Bool) -> String {
    var modules: [String] = [], files: [String] = []
    func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\") + "\"" }
    func module(_ name: String, _ deps: [String], _ rels: [String]) {
        modules.append(#"{"name": \#(q(name)), "path": \#(q("src/" + name)), "deps": [\#(deps.map(q).joined(separator: ", "))], "test": false, "layer": null, "files": [\#(rels.map(q).joined(separator: ", "))], "lines": \#(10 * rels.count), "doc": "About @[nothing] here.", "folders": {}}"#)
        for rel in rels {
            files.append(#"{"module": \#(q(name)), "rel": \#(q(rel)), "path": \#(q("src/\(name)/\(rel)")), "lines": 10, "doc": "", "api": false, "decls": []}"#)
        }
    }
    module("app", ["[locale]", "Level 1", long, "C", #"back\slash"#], ["index.ts"])
    module("[locale]", [], ["page.ts"])
    module("Level 1", [], ["one.ts"])
    module(long, [], ["src/components/Select/index.ts"])
    module("C", [], ["main.swift", "a/c/main.swift", "b/main.swift", "halfSURROGATE.swift"])
    module(#"back\slash"#, [], ["b.ts"])
    if big {
        module("Big", ["Big/x"], (0..<30).map { "Utils/u\($0).ts" } + (0..<30).map { "utils/v\($0).ts" } + ["x/one.ts", "x/two.ts", "top.ts"])
        module("Big/x", [], ["its.ts"])
    }
    let uses = [#"{"from": ["app", "index.ts"], "to": ["[locale]", "page.ts"], "names": ["Page"]}"#,
                #"{"from": ["app", "index.ts"], "to": ["C", "a/c/main.swift"], "names": ["x", "y"]}"#]
    // a file's name that isn't UTF-8 reaches the model as half a character, which JSON writes as an escape
    return #"{"language": "typescript", "name": "Awkward @[names]", "modules": [\#(modules.joined(separator: ",\n"))], "files": [\#(files.joined(separator: ",\n"))], "uses": [\#(uses.joined(separator: ", "))]}"#
        .replacingOccurrences(of: "SURROGATE", with: #"\udcff"#)
}

/// Two modules, App over Core, as a reader writes model.json: App's Main.swift and Screen.swift use Core's Store.swift.
private let tinyModel = #"""
{"language": "swift", "name": "TinyPackage",
 "modules": [
  {"name": "App", "path": "Sources/App", "deps": ["Core"], "test": false, "layer": null, "files": ["Main.swift", "Screen.swift"], "lines": 60, "doc": "The app.", "folders": {}},
  {"name": "Core", "path": "Sources/Core", "deps": [], "test": false, "layer": null, "files": ["Store.swift", "Model.swift"], "lines": 90, "doc": "What the app keeps.", "folders": {}}],
 "files": [
  {"module": "App", "rel": "Main.swift", "path": "Sources/App/Main.swift", "lines": 20, "doc": "Starts the app.", "api": false, "decls": []},
  {"module": "App", "rel": "Screen.swift", "path": "Sources/App/Screen.swift", "lines": 40, "doc": "Shows the store.", "api": false, "decls": [{"name": "Screen", "kind": "type", "visibility": "internal", "line": 3}]},
  {"module": "Core", "rel": "Store.swift", "path": "Sources/Core/Store.swift", "lines": 50, "doc": "Holds the models.", "api": true, "decls": [{"name": "Store", "kind": "type", "visibility": "public", "line": 2}]},
  {"module": "Core", "rel": "Model.swift", "path": "Sources/Core/Model.swift", "lines": 40, "doc": "One model.", "api": true, "decls": [{"name": "Model", "kind": "type", "visibility": "public", "line": 2}]}],
 "uses": [
  {"from": ["App", "Main.swift"], "to": ["App", "Screen.swift"], "names": ["Screen"]},
  {"from": ["App", "Main.swift"], "to": ["Core", "Store.swift"], "names": ["Store"]},
  {"from": ["App", "Screen.swift"], "to": ["Core", "Store.swift"], "names": ["Store"]},
  {"from": ["Core", "Store.swift"], "to": ["Core", "Model.swift"], "names": ["Model"]}]}
"""#

private let tinySpec = """
BANDS = [("Apps", ["App", "Ghost"]), ("Foundations", ["Core"])]
GROUPS = {"App": [("Screens", ["Screen.swift"], [])]}
"""

