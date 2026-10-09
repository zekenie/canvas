import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasUI
import Composition
import Connections
import Foundation
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
        for promotion in try require(report["promotions"]?.arrayValue) {
            let hub = try require(promotion["node"]?.stringValue)
            let after = try queried(server, promoted, #":edge-to("\#(hub)")"#)
            let before = try queried(server, plain, #":edge-to("\#(hub)")"#)
            expectEqual(after.sorted(), before.sorted(), "what points at \(hub), with and without its pills")
            expectEqual(after.sorted(), Set(sources(of: hub, in: digest)).sorted(), "and the digest's own edges")
            expect(!after.isEmpty, "\(hub) is pointed at")
        }
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
        let commands = ShippedPlugins.commands(in: try require(BoardDocument.configuration).registry)
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
        let commands = ShippedPlugins.commands(in: try require(BoardDocument.configuration).registry)
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
])
