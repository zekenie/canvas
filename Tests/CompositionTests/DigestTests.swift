import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasRPC
import CanvasUI
import Foundation
import Publishing
import References
import ShippedTesting
import Subboards
import TestKit
import Titles
import Types

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

/// A script moved off its plan: the first of its shapes that isn't hard against its container's corner (a gap of 45 or more, so
/// that 5 nearer is still inside the 40 a frame keeps clear, and draw places it) is 5 units nearer it. Nil when it has none.
private func nudged(_ script: String) -> String? {
    var text = script
    var from = text.startIndex
    while let gap = text.range(of: #"\(gap: [0-9]+\)"#, options: .regularExpression, range: from..<text.endIndex) {
        if let before = Int(text[gap].dropFirst(6).dropLast()), before >= 45 {
            text.replaceSubrange(gap, with: "(gap: \(before - 5))")
            return text
        }
        from = gap.upperBound
    }
    return nil
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
/// `{board, in, title, kind, x, y, w, h, for, from, to, is}`. A shape says where it is as a query's row does: `board` is the
/// containers of the board it is on (the subboards, as titles, outermost first, so beginning with the subboard the digest was drawn
/// into, when there is one) and `in` the frames it is in on that board, so two shapes of one title are told apart by their places. An arrow's
/// `from` and `to` are the places of its ends (each an array: the containers, then the title), and `pill` is true when its end is a
/// reference, whose `to` is then its label; its `is` the titles of the relationship types it is of (when it is of any).
@MainActor private func landedRows(in editor: CanvasEditor) throws -> String {
    let containing = editor.registry.containingKinds
    func title(of record: AnyShapeRecord) -> String { editor.registry.title(of: record) ?? record.kind.rawValue }
    func titled(_ id: ShapeID?) -> String {
        guard let record = id.flatMap({ editor.file.record($0) }) else { return "?" }
        return title(of: record)
    }
    // every board, outermost first, with the containers of its board; and where each shape is
    var queue: [(chain: [String], board: BoardID)] = [([], .root)]
    var places: [ShapeID: [String]] = [:], frames: [ShapeID: [String]] = [:]
    var next = 0
    while next < queue.count {
        let (chain, board) = queue[next]
        next += 1
        let document = editor.contents(of: board)
        for record in document.shapes {
            var above: [String] = []
            var current = record
            while let holder = document.container(of: current, containingKinds: containing), let held = editor.file.record(holder) {
                above.insert(title(of: held), at: 0)
                current = held
            }
            frames[record.id] = above
            places[record.id] = chain + above + [title(of: record)]
            if record.kind == Subboard.kind { queue.append((chain + above + [title(of: record)], BoardID(owner: record.id))) }
        }
    }
    var rows: [[String: Any]] = []
    for (chain, board) in queue {
        for record in editor.contents(of: board).shapes {
            let name = editor.registry.title(of: record)
            var row: [String: Any] = ["board": chain, "kind": record.kind.rawValue, "in": frames[record.id] ?? []]
            if let name { row["title"] = name }
            if let box = record.box { row["x"] = box.minX; row["y"] = box.minY; row["w"] = box.width; row["h"] = box.height }
            if let reference = record.typed(as: Reference.self) {
                row["for"] = reference.props.target?.label ?? "?"
            } else if let arrow = record.typed(as: Arrow.self)?.props {
                row["kind"] = "arrow"
                row["from"] = arrow.start.binding.flatMap { places[$0.shapeID] } ?? ["?"]
                if let end = arrow.end.binding?.shapeID, let target = editor.file.record(end)?.typed(as: Reference.self) {
                    row["to"] = [target.props.target?.label ?? "?"]
                    row["pill"] = true
                } else {
                    row["to"] = arrow.end.binding.flatMap { places[$0.shapeID] } ?? ["?"]
                }
                if let types = record[IsAProperty.self]?.map(\.shape), !types.isEmpty { row["is"] = types.map(titled) }
            }
            rows.append(row)
        }
    }
    return try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }.joined(separator: "\n")
}

/// What the file holds, held to the plan by the tool's `verify`: every shape and pill within a unit
/// of its place and its width, in its frame, every arrow drawn, and nothing more.
@MainActor private func expectOnPlan(_ run: DigestRun, board: BoardDocument, _ label: String) throws {
    let rows = run.out.appendingPathComponent("rows.jsonl")
    try landedRows(in: board.editor).write(to: rows, atomically: true, encoding: .utf8)
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

/// No run warned but to say a big drawing is bigger than the window (the camera is the user's), and none pushed a shape past another. A digest whose
/// titles repeat (or repeat the file's) is also told that a title is another shape's too, which is the data (`titlesRepeat`).
@MainActor private func expectNoWarnings(_ run: DigestRun, _ label: String, titlesRepeat: Bool = false) throws {
    for (name, result) in try run.results() {
        let warnings = result["warnings"]?.arrayValue ?? []
        let said = warnings.compactMap { $0["message"]?.stringValue }.filter { !$0.contains("landed outside the view") && !(titlesRepeat && $0.contains("is another shape’s title too")) }
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

/// The subboards whose text (their description) mentions `title`.
private func mentioners(of title: String, in digest: JSON) -> [String] {
    (digest["nodes"]?.arrayValue ?? []).filter { $0["kind"]?.stringValue == "subboard" && ($0["text"]?.stringValue ?? "").contains("@[\(title)]") }.compactMap { $0["title"]?.stringValue }
}

/// The titles a digest says point at `hub`, from the digest itself.
private func sources(of hub: String, in digest: JSON) -> [String] {
    (digest["edges"]?.arrayValue ?? []).filter { $0["to"]?.stringValue == hub }.compactMap { $0["from"]?.stringValue }
}

/// What a typed drawing says by design: a Needed row still empty, a relationship that doesn't fit its ends, a row past Only one. Not that a run is off its plan.
private func isByDesign(_ message: String) -> Bool {
    message.hasSuffix(" is needed") || message.contains("should have at most") || message.contains(" runs from ") || message.contains(" runs to ")
}

/// Every warning of the real runs, but the out-of-view one: each must be one a typed drawing gives by design, and no run pushed a shape past another.
/// Returns them (the runs' warnings of the typed shapes, in order).
@MainActor private func expectOnlyTypedWarnings(_ run: DigestRun, _ label: String) throws -> [String] {
    var said: [String] = []
    for (name, result) in try run.results() {
        let messages = (result["warnings"]?.arrayValue ?? []).compactMap { $0["message"]?.stringValue }.filter { !$0.contains("landed outside the view") }
        for message in messages { expect(isByDesign(message), "\(label): \(name) warned of more than a typed drawing does: \(message)") }
        expect(!(result["changes"]?.arrayValue ?? []).contains { $0["pushedPast"] != nil }, "\(label): \(name) pushed a shape past another")
        said += messages
        // and what a row says of its own shape (a Needed row left empty is `problems` on the note, not a warning of the run)
        for change in result["changes"]?.arrayValue ?? [] {
            for problem in change["problems"]?.arrayValue ?? [] { said.append("\(change["title"]?.stringValue ?? "?"): \(problem["message"]?.stringValue ?? "")") }
        }
    }
    return said
}

/// The frame the app lays the shape called `title` out in, on whichever board of the file it is.
@MainActor private func laidOut(_ title: String, in board: BoardDocument) throws -> CGRect {
    let editor = board.editor
    let all = editor.file.root.shapes + editor.file.children.values.flatMap(\.shapes)
    let record = try require(all.first { editor.registry.title(of: $0) == title }, "no shape called \(title)")
    let reading = try require(editor.file.board(containing: record.id).flatMap { editor.reading(of: $0) }, "no board holds \(title)")
    return try require(reading.shapes.frame(of: record.id))
}

/// How many rows `canvas query` answers for a query on a board.
@MainActor private func queriedCount(_ server: CommandServer, _ board: BoardDocument, _ query: String) throws -> Int {
    let answer = try canvas(server, ["query", "--board", "\(board.number)", "--brief", "--limit", "10000", query])
    expectEqual(answer.status, 0, answer.error)
    return Int(try require(JSON(text: answer.output)["count"]?.numberValue))
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
        // every board is laid out for the window it is drawn in: the room `canvas boards` says the target's has (1440 x 900, less a fit's margin)
        let room = [1440 - 2 * Double(CanvasEditor.firstVisitInset), 900 - 2 * Double(CanvasEditor.firstVisitInset)]
        expectEqual(report["view"], ["w": .number(room[0]), "h": .number(room[1]), "from": "given"], "the plan is for the board's window")
        expect(run.process.output.contains("laid out for a view of \(Int(room[0])) x \(Int(room[1]))\n"), run.process.output)
        expectEqual(plan["runs"]?.arrayValue?.first, "00-into.draw")
        try expectOnPlan(run, board: promoted, "Acme")
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
        try expectOnPlan(run, board: board, "tree")
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
            // a card's description that mentions a shape is an edge to it too (a `mention` edge)
            expectEqual(try queried(server, board, #":edge-to("\#(hub)")"#).sorted(), Set(sources(of: hub, in: digest) + mentioners(of: hub, in: digest)).sorted(), "what points at \(hub)")
        }
        // a subboard's text is its description, written once every shape is drawn (it names one on the root board and one on its own board, which a
        // later run draws), and no board has a note of what it is
        let titles = try queried(server, board, "[title]")
        expectEqual(titles.filter { $0.hasPrefix("About ") }, [], "no About note on any board")
        expectEqual(try queried(server, board, #"[description*="Gateway"]"#), ["Backend"], "the card holds the text as its description")
        expectEqual(try queried(server, board, #"[description*="Login"]"#), ["Backend"], "and a mention of a shape on its own board, drawn after the card")
        expect(run.process.output.contains("descriptions 1/1"), "verify counts it: \(run.process.output)")
    },

    test("digest all on a spine: a band of cards that point at the same notes, the pills they share between its columns, each placed by its edge, every shape and pill on its plan") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("spine")
        defer { try? FileManager.default.removeItem(at: folder) }

        let run = try runDigest("all", "spine", server: server, target: ["--board", "\(board.number)", "--into", "Spine map"], out: folder)
        expectEqual(run.process.status, 0, run.process.output + run.process.error)
        expect(run.process.output.contains("verify ok"), run.process.output)
        try expectOnPlan(run, board: board, "spine")
        try expectNoWarnings(run, "spine")
        let plan = try run.plan, report = try run.report
        let algorithms = report["boards"]?["root"]?["algorithms"]?.arrayValue ?? []
        expectEqual(algorithms.first { $0["container"] == "Band" }?["algorithm"], "spine", "the band is a spine")
        // a pill the band's cards share is made by its first card's edge, which says where it goes; the others share it, and a left card's own are on its left
        let runs = plan["runs"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let edgeRun = try require(runs.first { $0.hasSuffix("-root-edges.draw") }, "the root's edge run: \(runs)")
        let script = try String(contentsOf: run.out.appendingPathComponent("runs/\(edgeRun)"), encoding: .utf8)
        for line in [#"edge "A" -> "X" via: reference in "Band" right of "Band" left (gap: "#, #"edge "B" -> "X" via: reference share: "A""#,
                     #"edge "D" -> "Z" via: reference share: "C""#, #"edge "A" -> "W" via: reference from: left"#] {
            expect(script.contains(line), "\(line) in \(script)")
        }
        // one pill for X, in the band, read as each card's arrow into X
        let rows = try landedRows(in: board.editor).split(separator: "\n").map { try JSON(text: String($0)) }
        let forX = rows.filter { $0["kind"] == "reference" && $0["for"] == "X" }
        expectEqual(forX.count, 1, "one pill for X")
        expectEqual(forX.first?["in"], ["Band"], "in the band")
        expectEqual(try queried(server, board, #":edge-to("X")"#).sorted(), ["A", "B", "C", "D"])
        expectEqual(publicTitles(in: board.editor, digestRoot: "Spine map"), Set(report["public"]?.arrayValue?.compactMap(\.stringValue) ?? []))
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
        // the window in front has no size here (and the new file's isn't open as the plan is made): a view is assumed, and said
        expectEqual(report["view"]?["from"], "assumed")
        expect(run.process.output.contains("(assumed: no view was given)"), run.process.output)
        try expectOnPlan(run, board: board, "flat60")
        try expectNoWarnings(run, "flat60")
        expect((report["promotions"]?.arrayValue?.count ?? 0) > 0, "hubs promoted")
        expectEqual(publicTitles(in: board.editor, digestRoot: nil), Set(report["public"]?.arrayValue?.compactMap(\.stringValue) ?? []))
        let digest = try json(fixture("flat60"))
        for promotion in try require(report["promotions"]?.arrayValue).prefix(3) {
            let hub = try require(promotion["node"]?.stringValue)
            expectEqual(try queried(server, board, #":edge-to("\#(hub)")"#).sorted(), Set(sources(of: hub, in: digest)).sorted(), "what points at \(hub)")
        }
    },

    test("digest all on a typed digest: types and their ends in one script, the notes of a type after it, every arrow the relationship it is; warnings a typed drawing gives are reported and fail nothing") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("typed")
        defer { try? FileManager.default.removeItem(at: folder) }

        let run = try runDigest("all", "typed", server: server, target: ["--board", "\(board.number)", "--into", "Platform"], out: folder)
        expectEqual(run.process.status, 0, run.process.output + run.process.error)
        expect(run.process.output.contains("verify ok"), run.process.output)
        expect(run.process.output.contains("types: 2 type(s), 2 relationship type(s), 7 note(s) of a type, 8 arrow(s) of a relationship type"), run.process.output)
        expect(run.process.output.contains("by design"), "the warnings of a typed drawing are said, as expected: \(run.process.output)")
        let plan = try run.plan
        try expectOnPlan(run, board: board, "typed")

        // The order of the runs: the types, the relationship types and their ends in one script of the board that holds them (here the run of the
        // frame "Model", the deepest of them), every note of a type after every such script, the arrows of the relationships last.
        let runs = try require(plan["runs"]?.arrayValue?.compactMap(\.stringValue))
        let results = try run.results()
        func script(_ name: String) throws -> String { try String(contentsOf: run.out.appendingPathComponent("runs/\(name)"), encoding: .utf8) }
        let typesRun = try require(runs.first { $0.contains("-root-in-1") })
        let typesScript = try script(typesRun)
        for title in ["Workflow", "Table", "writes", "reads"] { expect(typesScript.contains("sticky-note \"\(title)\""), "\(title) is drawn in the types' script") }
        expect(typesScript.contains(#"edge "Workflow" -> "writes" text: "tables" endRule: {"needed":true}"#), "an end is in the script of its types: \(typesScript)")
        expect(typesScript.contains(#"edge "writes" -> "Table""#))
        expect(!typesScript.contains("is: "), "no note of a type in it")
        let notesRuns = runs.filter { $0.contains("-notes.") }
        expectEqual(notesRuns.count, 2, "a script of notes for each service's board")
        for name in notesRuns { expect(runs.firstIndex(of: name)! > runs.firstIndex(of: typesRun)!, "\(name) comes after the types") }
        for name in runs.filter({ $0.contains("-edges.") }) { expect(runs.firstIndex(of: name)! > runs.lastIndex(of: notesRuns.last!)!, "\(name) comes after every note") }
        // a note is drawn at the size it has with the ends there already, in the run that made it
        for (name, result) in results where notesRuns.contains(name) || name == typesRun {
            for change in result["changes"]?.arrayValue ?? [] where change["kind"]?.stringValue == "sticky-note" {
                expectEqual(change["did"], "created", "\(name): \(change["title"] ?? .null)")
            }
        }
        // the sizes the plan stated are the sizes the app made them: a typed note keeps the width the digest
        // draws it at (the tool's 300 for a title this short), since rows never widen a note
        let shapes = (try require(plan["boards"]?.arrayValue)).flatMap { $0["shapes"]?.arrayValue ?? [] }
        for title in ["Workflow", "Table", "OrderWorkflow", "orders"] {
            let shape = try require(shapes.first { $0["title"]?.stringValue == title })
            expectEqual(shape["w"]?.numberValue, 300, "\(title) is as wide as the digest drew it: \(shape)")
        }
        let tall = { (t: String) -> Double in shapes.first { $0["title"]?.stringValue == t }?["h"]?.numberValue ?? 0 }
        expect(tall("Workflow") > tall("OrderWorkflow") - 100 && tall("Workflow") >= 200, "the type's note has its fields' rows and its ends'")

        // The warnings are by design, said, and fail nothing: AuditSweep writes no table, and its `tables` row is Needed
        let said = try expectOnlyTypedWarnings(run, "typed")
        expect(said.contains { $0.contains("AuditSweep") && $0.hasSuffix("tables is needed") }, "the Needed row left empty is said: \(said)")
        expect(said.contains { $0.contains("reads runs to a Table") }, "so is the relationship that doesn't fit its ends (AuditSweep reads a Workflow): \(said)")
        expectEqual(try queriedCount(server, board, "arrow:misfit"), 1)

        // What the app answers of what was drawn: the notes of a type, and the arrows of a relationship type, with the one through a pill
        expectEqual(try queried(server, board, #":is-a("Table")"#).sorted(), ["orders", "refunds", "rollup"])
        expectEqual(try queried(server, board, #":is-a("Workflow")"#).sorted(), ["AuditSweep", "NightlyRollup", "OrderWorkflow", "RefundWorkflow"])
        expectEqual(try queriedCount(server, board, #"arrow:is-a("writes")"#), 5, "the writes of the digest, the one through a pill too")
        expectEqual(try queriedCount(server, board, #"arrow:is-a("reads")"#), 3, "NightlyRollup reads orders and refunds, and AuditSweep (wrongly) a workflow")
        expectEqual(try queried(server, board, #":incomplete"#), ["AuditSweep"])
        expectEqual(try queried(server, board, #"sticky-note[relationship]"#).sorted(), ["reads", "writes"])
        expectEqual(try queriedCount(server, board, #"arrow:between("Workflow", "writes")"#), 1, "the end")
        // the two arrows NightlyRollup has to orders are a pill's worth: one reference, two relationships
        expectEqual(try queriedCount(server, board, #"reference"#), 2, "a pill for orders and one for refunds, though NightlyRollup has two arrows at orders")
        // which workflows write the orders table?
        let writers = try queried(server, board, #":start-of(arrow:is-a("writes"):ends-at("orders"))"#)
        expectEqual(writers.sorted(), ["NightlyRollup", "OrderWorkflow", "RefundWorkflow"], "who writes orders, the one through a pill read through it")

        // drawn again in place: a typed digest is replaced like any other, types, ends and arrows with the rest
        let again = try runDigest("all", "typed", server: server, target: ["--board", "\(board.number)", "--into", "Platform"], extra: ["--replace"], out: folder)
        expectEqual(again.process.status, 0, again.process.output + again.process.error)
        expect(again.process.output.contains("replace: took back"), again.process.output)
        expect(again.process.output.contains("verify ok"), again.process.output)
        try expectOnPlan(again, board: board, "typed again")
        expectEqual(try queriedCount(server, board, #"arrow:is-a("writes")"#), 5)
    },

    test("a typed digest whose types are on a board of their own: the card first, then the types and their ends in the board's script, then the notes of the first board, which relate to a note on another through a pill") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("typed-board")
        defer { try? FileManager.default.removeItem(at: folder) }
        // the fixture with Model a subboard, and a workflow on the first board that writes a table on another
        var text = try String(contentsOf: fixture("typed"), encoding: .utf8)
        text = text.replacingOccurrences(of: #""kind": "frame""#, with: #""kind": "subboard""#)
        text = text.replacingOccurrences(of: #""nodes": ["#, with: #""nodes": [{"title": "Loose", "is": "Workflow", "fieldValues": {"name": "Loose"}}, "#)
        text = text.replacingOccurrences(of: #""edges": ["#, with: #""edges": [{"from": "Loose", "to": "orders", "is": "writes", "fieldValues": {"mode": "insert"}}, "#)
        let file = try digestFile("typed-board", text, in: folder)
        let run = try runDigest("all", file: file, server: server, target: ["--board", "\(board.number)", "--into", "Platform"], out: folder.appendingPathComponent("out"))
        expectEqual(run.process.status, 0, run.process.output + run.process.error)
        expect(run.process.output.contains("verify ok"), run.process.output)
        try expectOnPlan(run, board: board, "typed on a board")
        _ = try expectOnlyTypedWarnings(run, "typed on a board")
        let runs = try require(run.plan["runs"]?.arrayValue?.compactMap(\.stringValue))
        let index = { (part: String) -> Int in runs.firstIndex { $0.contains(part) } ?? -1 }
        expect(index("-root-top") < index("-model-top"), "the card of Model is drawn before its board's shapes: \(runs)")
        expect(index("-model-top") < index("-root-notes"), "the types before the first board's notes: \(runs)")
        expect(index("-root-notes") < index("-checkout-notes") && index("-checkout-notes") < index("-root-edges"), "the notes, then the arrows: \(runs)")
        let typesScript = try String(contentsOf: run.out.appendingPathComponent("runs/\(runs[index("-model-top")])"), encoding: .utf8)
        expect(typesScript.contains(#"edge "Workflow" -> "writes""#) && typesScript.contains(#"sticky-note "Table""#), typesScript)
        expectEqual(try queriedCount(server, board, #"arrow:is-a("writes")"#), 6)
        expectEqual(try queried(server, board, #":start-of(arrow:is-a("writes"):ends-at("orders"))"#).sorted(), ["Loose", "NightlyRollup", "OrderWorkflow", "RefundWorkflow"])
    },

    test("a digest of types built on types, on three boards: each type drawn after what it builds on (a round later for another board's) at the size its inherited fields and rows give it, the notes holding the fields their types build on, and what is of a type found however far") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("inherit")
        defer { try? FileManager.default.removeItem(at: folder) }

        let run = try runDigest("all", "inherit", server: server, target: ["--board", "\(board.number)", "--into", "Garage"], out: folder)
        expectEqual(run.process.status, 0, run.process.output + run.process.error)
        expect(run.process.output.contains("verify ok"), run.process.output)
        expect(run.process.output.contains("types: 7 type(s), 4 relationship type(s) (5 built on others), 6 note(s) of a type, 4 arrow(s) of a relationship type"), run.process.output)
        try expectOnPlan(run, board: board, "inherit")

        // The runs: the first board's types of the first round in its frame's script, as ever, and the later rounds after every board's shapes,
        // a script a board a round. Truck (Fleet) waits for Vehicle (the first board), tows (Fleet) and powers (Parts) for uses (the first
        // board), Rechargeable and Cell for powers, whose ends they are, and Electric (the first board) for Rechargeable, Hybrid with it.
        let plan = try run.plan
        let runs = try require(plan["runs"]?.arrayValue?.compactMap(\.stringValue))
        let steps = runs.map { $0.replacingOccurrences(of: #"^[0-9]+-"#, with: "", options: .regularExpression).replacingOccurrences(of: ".draw", with: "") }
        expectEqual(steps.filter { $0.contains("types") || $0 == "root-in-1" }, ["root-in-1", "fleet-types-1", "parts-types-1", "root-types-2"], "\(runs)")
        for (name, result) in try run.results() where name.contains("-types") || name.contains("-root-in-1") {
            for change in result["changes"]?.arrayValue ?? [] where change["kind"]?.stringValue == "sticky-note" {
                expectEqual(change["did"], "created", "\(name): \(change["title"] ?? .null)")
            }
        }
        // once everything is drawn, every note is the size it was planned at: a type has the fields and rows of the types it builds on, wherever
        // they are, and nothing drawn after a type changes it
        let shapes = try require(plan["boards"]?.arrayValue).flatMap { $0["shapes"]?.arrayValue ?? [] }
        for shape in shapes where shape["kind"]?.stringValue == "sticky-note" {
            let title = try require(shape["title"]?.stringValue)
            let frame = try laidOut(title, in: board)
            expect(abs(frame.width - (shape["w"]?.numberValue ?? 0)) <= 1 && abs(frame.height - (shape["h"]?.numberValue ?? 0)) <= 1,
                   "\(title) is laid out at \(frame.size), and was planned at \(shape["w"] ?? .null) x \(shape["h"] ?? .null)")
        }
        let tall = { (t: String) -> Double in shapes.first { $0["title"]?.stringValue == t }?["h"]?.numberValue ?? 0 }
        expect(tall("Truck") > tall("Cell"), "Truck has Vehicle's fields and its owner row besides its own: \(tall("Truck")) against \(tall("Cell"))")

        // What the drawing says is by design: Trailer truck has no owner, a row Vehicle's end gives every Truck, and Needed. No value is wrong:
        // Rig's wheels are text, as Truck says, where Vehicle says a number, and the type that restates a field is the one.
        let said = try expectOnlyTypedWarnings(run, "inherit")
        expect(said.contains { $0.hasPrefix("Trailer truck") && $0.hasSuffix("owner is needed") }, "\(said)")
        expect(!said.contains { $0.contains("wheels") }, "\(said)")

        // What the app answers of what was drawn
        expectEqual(try queried(server, board, #"[schema]:is-a("Vehicle")"#).sorted(), ["Electric", "Hybrid", "Truck"], "the types built on Vehicle, however far")
        expectEqual(try queried(server, board, #":is-a("Vehicle"):not([schema])"#).sorted(), ["Leaf", "Rig", "Trailer truck"], "and the notes that are Vehicles through them")
        expectEqual(try queried(server, board, #":is-a("Rechargeable"):not([schema])"#).sorted(), ["Leaf", "Pack 1"], "Leaf through Hybrid and Electric, a board away")
        expectEqual(try queriedCount(server, board, #"arrow:is-a("uses")"#), 2, "an arrow of tows or powers is one of uses")
        expectEqual(try queriedCount(server, board, #"arrow:is-a("owns")"#), 2)
        expectEqual(try queriedCount(server, board, "arrow:misfit"), 0, "Ann owns a Hybrid and a Truck, which are Vehicles")
        expectEqual(try queried(server, board, ":incomplete"), ["Trailer truck"])
    },

    test("digest check refuses what a typed digest cannot be drawn with, naming the shape: an is with no type, is on a frame, a relationship without a schema, an endRule that is no end, a $ref to an id, values that don't fit, ends on another board, a type built on itself") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("typed-refusals")
        defer { try? FileManager.default.removeItem(at: folder) }
        let digest = """
            {"title": "Bad", "nodes": [
              {"title": "Thing", "schema": {"type": "object", "properties": {"n": {"type": "integer"}}, "required": ["n"]}, "text": "A thing"},
              {"title": "Links", "relationship": true, "schema": {"type": "object"}, "text": "Links"},
              {"title": "Orphan", "relationship": true, "text": "no schema"},
              {"title": "Region", "kind": "frame", "is": "Thing"},
              {"title": "Ghost", "is": "Nobody"},
              {"title": "Odd", "is": "Thing", "fieldValues": {"n": "three"}},
              {"title": "Refd", "schema": {"type": "object", "properties": {"x": {"$ref": "urn:uuid:7c1e2a04-4b9e-4e0c-9d8c-5b0e7f3a2c11"}}}, "text": "Refs an id"},
              {"title": "Far", "kind": "subboard"},
              {"title": "Remote", "in": "Far", "schema": {"type": "object"}, "text": "On another board"},
              {"title": "Loop", "schema": {"type": "object"}, "text": "Built on Knot", "is": "Knot"},
              {"title": "Knot", "schema": {"type": "object"}, "text": "Built on Loop", "is": "Loop"}
            ], "edges": [
              {"from": "Ghost", "to": "Odd", "endRule": {"needed": true}},
              {"from": "Thing", "to": "Links"},
              {"from": "Links", "to": "Remote"}
            ]}
            """
        let file = try digestFile("bad", digest, in: folder)
        let checked = try runDigest("check", file: file, server: server, target: ["--board", "\(board.number)", "--into", "Bad map"], out: folder.appendingPathComponent("out"))
        expect(checked.process.status != 0, "check refuses")
        let said = checked.process.output
        for expected in [
            #""Orphan": relationship: true needs a schema"#,
            #""Region": a frame can't be a type's instance"#,
            #""Ghost": is "Nobody", which names no type in the digest"#,
            #""Odd": fieldValues.n is "three", and the schema wants integer"#,
            #""Refd": the schema has a $ref to urn:uuid:"#,
            #"edge "Ghost" -> "Odd": endRule is only for an end of a relationship type"#,
            #"edge "Links" -> "Remote": an end of the relationship type "Links""#,
            #""Knot": builds on "Loop", which builds on "Knot": a type can't build on itself, however far"#,
        ] { expect(said.contains(expected), "check says \(expected):\n\(said)") }
        // and plan, which is not check, will not measure what it refuses
        let planned = try runDigest("plan", file: file, server: server, target: [], extra: ["--into", "Bad map"], out: folder.appendingPathComponent("out2"))
        expect(planned.process.status != 0 && planned.process.error.contains("names no type in the digest"), planned.process.output + planned.process.error)
    },

    test("measuring a typed digest is the same whatever board is in front: a front board that holds types of the same titles, with other fields and ends, changes no size") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let clean = windowedBoard(), polluted = windowedBoard(), spare = windowedBoard()
        defer { clean.close(); polluted.close(); spare.close() }
        let folder = try scratchFolder("typed-measure")
        defer { try? FileManager.default.removeItem(at: folder) }
        // a board in front that holds a Workflow, a Table and a writes with other fields and ends, and notes of them
        let fields = (0..<9).map { "\"f\($0)\": {\"type\": \"string\"}" }.joined(separator: ", ")
        let schema = scripted("{\"type\": \"object\", \"properties\": {\(fields)}}")
        let others = try startCommandServer(boards: [polluted, clean], frontmost: polluted)
        defer { others.stop() }
        let drawn = try canvas(others, ["draw", """
            sticky-note "Workflow" text: "Another" schema: "\(schema)"
            sticky-note "Table" text: "Another" schema: "\(schema)" right of "Workflow"
            sticky-note "writes" text: "Another" relationship: true schema: "{}" right of "Table"
            edge "Workflow" -> "writes" text: "x" endRule: {"needed": true}
            edge "writes" -> "Table" text: "y"
            sticky-note "OrderWorkflow" is: "Workflow" below "Workflow"
            """])
        expectEqual(drawn.status, 0, drawn.output + drawn.error)
        let alone = try startCommandServer(boards: [clean, spare], frontmost: nil)
        defer { alone.stop() }
        let withFront = try runDigest("measure", "typed", server: others, target: [], out: folder.appendingPathComponent("front"))
        let without = try runDigest("measure", "typed", server: alone, target: [], out: folder.appendingPathComponent("none"))
        expectEqual(withFront.process.status, 0, withFront.process.output + withFront.process.error)
        expectEqual(without.process.status, 0, without.process.output + without.process.error)
        let a = try json(withFront.out.appendingPathComponent("measure.json")), b = try json(without.out.appendingPathComponent("measure.json"))
        expect(a["board"] != nil && b["board"] == nil, "the first was measured on the board in front, the second on none")
        for key in ["shapes", "references", "constants"] { expectEqual(a[key], b[key], "\(key) measured the same") }
        expectEqual(a["warnings"], nil, "and said nothing of the front board's titles")
        // the types' sizes carry their ends: the rows an end gives a note of its type are in the measure
        let sizes = Dictionary(uniqueKeysWithValues: (a["shapes"]?.arrayValue ?? []).compactMap { shape in
            shape["title"]?.stringValue.map { ($0, shape["size"]?.arrayValue?.compactMap(\.numberValue) ?? []) }
        })
        expect(sizes["Workflow"]?.first == 300 && sizes["OrderWorkflow"]?.first == 300, "a typed note keeps the width the digest gives it: \(sizes)")
        expect((sizes["Workflow"]?.last ?? 0) > 200, "a type with fields and ends grows past the least: \(sizes)")
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
        // the second script moved off the plan: a note of it is 5 units nearer its frame's corner
        let script = out.appendingPathComponent("runs/02-root-in-1.draw")
        try require(nudged(String(contentsOf: script, encoding: .utf8))).write(to: script, atomically: true, encoding: .utf8)

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
        expect(titles.contains("Acme map") && titles.contains("Engineering"), "what ran before stays: \(titles)")
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
        try require(nudged(String(contentsOf: script, encoding: .utf8))).write(to: script, atomically: true, encoding: .utf8)

        let file = folder.appendingPathComponent("Tampered")
        let drawn = try runDigest("draw", "acme", server: server, target: ["--new-file", file.path], out: out)
        expectEqual(drawn.process.status, 4, drawn.process.output + drawn.process.error)
        expect(drawn.process.error.contains("drawn already, 1 script(s): 01-root-top.draw"), drawn.process.error)
        expect(drawn.process.error.contains("close the new file's window without saving and delete \(file.path)"), drawn.process.error)
        expect(!drawn.process.error.contains("subboard"), "no subboard to delete: \(drawn.process.error)")
    },

    test("a draw of a plan whose scripts rely on a title the file now has stops before anything is drawn, and a plan made beside that title names its shape by a path; a plan drawn once is not drawn again; plan checks the --into title too") {
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

        // the plan was made before the title came to the file, and its scripts name CTO bare: draw looks at the file's titles again
        let out = folder.appendingPathComponent("acme")
        let planned = try runDigest("plan", "acme", server: server, target: ["--into", "Acme map"], out: out)
        expectEqual(planned.process.status, 0, planned.process.output + planned.process.error)
        let clash = try runDigest("draw", "acme", server: server, target: ["--board", "\(board.number)"], out: out)
        expectEqual(clash.process.status, 1, clash.process.output + clash.process.error)
        expect(clash.process.error.contains(#"error: "CTO" is on a board in the file now, and the scripts name shapes on the understanding that it is not"#), clash.process.error)
        expect(clash.process.error.contains("nothing was drawn"), clash.process.error)
        expectEqual(board.editor.document.shapes.count, before, "nothing drawn")
        // a plan made given the board knows the title, and names that shape by a path: the file's CTO is never the one meant, and the digest is drawn beside it
        let replanned = try runDigest("all", "acme", server: server, target: ["--board", "\(board.number)", "--into", "Acme map"], out: folder.appendingPathComponent("replanned"))
        expectEqual(replanned.process.status, 0, replanned.process.output + replanned.process.error)
        expect(replanned.process.output.contains("verify ok"), replanned.process.output)
        expectEqual(try queried(server, board, #"[title="CTO"]"#).count, 2, "the board's CTO, and the digest's")
        expectEqual(try queriedCount(server, board, #"sticky-note[text="Already here"]"#), 1, "the board's own is as it was")

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

    test("digest refuses what it should before drawing: the --into title the file has, a kind the app lacks, a plan made for another target, a missing --into") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("refuse")
        defer { try? FileManager.default.removeItem(at: folder) }
        let drawn = try canvas(server, ["draw", #"sticky-note "Acme map" text: "Already here""#, "--board", "\(board.number)"])
        expectEqual(drawn.status, 0, drawn.error)
        let before = board.editor.document.shapes.count

        // the subboard's title is the file's alone (draw finds it anywhere): refused, and nothing is drawn. The nodes' titles may be the file's: they are named so that nothing in the file can be meant
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
        try expectOnPlan(first, board: board, "tree, first")
        let drawn = board.editor.file.shapeCount
        expect(drawn > 0, "drawn")

        // again: the first drawing is taken back, in one step, and drawn anew in its place
        let second = try runDigest("all", "tree", server: server, target: ["--board", "front", "--replace"], out: out)
        expectEqual(second.process.status, 0, second.process.output + second.process.error)
        expect(second.process.output.contains("replace: took back the last drawing"), second.process.output)
        expect(second.process.output.contains("verify ok"), second.process.output)
        expectEqual(board.editor.file.shapeCount, drawn, "the same drawing, once")
        try expectOnPlan(second, board: board, "tree, second")
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
                guard let text = nudged(try String(contentsOf: script, encoding: .utf8)) else { continue }
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
    test("drawing records (--records): a file in the folder that is no record is said once and skipped, and the file's titles are asked for only when the path does not tell the record") {
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
        let folder = try scratchFolder("records")
        defer { try? FileManager.default.removeItem(at: folder) }
        let records = folder.appendingPathComponent("records")
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        // a canvas that counts what it is asked to do, to hold what the driver asks of the app
        let counting = folder.appendingPathComponent("canvas-counting")
        try "#!/bin/sh\necho \"$1\" >> \"$CANVAS_COUNT_LOG\"\nexec \"\(builtExecutable("CanvasCLI").path)\" \"$@\"\n".write(to: counting, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: counting.path)
        func asked(_ log: URL, _ command: String) -> Int {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0 == command }.count
        }
        @MainActor func ready(out: URL, records: URL?, log: URL, board: BoardDocument) throws -> ProcessOutput {
            let tiny = try digestFile("tiny", #"{"title": "Tiny", "nodes": [{"title": "Tiny A", "text": "a"}, {"title": "Tiny B", "text": "b"}], "edges": [{"from": "Tiny A", "to": "Tiny B"}]}"#, in: folder)
            var arguments = ["ready", tiny.path, "--board", "\(board.number)", "--replace", "--out", out.path]
            if let records { arguments += ["--records", records.path] }
            return try run(skillURL("digest"), arguments, environment: ["CANVAS_CLI": counting.path, "CANVAS_SOCKET": server.path, "CANVAS_COUNT_LOG": log.path])
        }

        // drawn into a new file, with a record of its path; then strays in the folder: a file that is not JSON, and JSON that is no record
        let tiny = try digestFile("tiny", #"{"title": "Tiny", "nodes": [{"title": "Tiny A", "text": "a"}, {"title": "Tiny B", "text": "b"}], "edges": [{"from": "Tiny A", "to": "Tiny B"}]}"#, in: folder)
        let made = try runDigest("all", file: tiny, server: server, target: ["--new-file", folder.appendingPathComponent("Tiny").path], extra: ["--records", records.path], out: folder.appendingPathComponent("made"))
        expectEqual(made.process.status, 0, made.process.output + made.process.error)
        try "{\"titles\": [".write(to: records.appendingPathComponent("stray.json"), atomically: true, encoding: .utf8)
        try #"{"hello": "world"}"#.write(to: records.appendingPathComponent("other.json"), atomically: true, encoding: .utf8)
        let board = try require(opened.boards.first)

        // ready with the records, and with the record of the same out alone: the same questions of the app, but for the strays' one warning
        let plainLog = folder.appendingPathComponent("plain.log"), recordsLog = folder.appendingPathComponent("records.log")
        let plain = try ready(out: folder.appendingPathComponent("made"), records: nil, log: plainLog, board: board)
        expectEqual(plain.status, 0, plain.output + plain.error)
        expect(plain.output.contains("which the new one replaces"), plain.output)
        let kept = try ready(out: folder.appendingPathComponent("elsewhere"), records: records, log: recordsLog, board: board)
        expectEqual(kept.status, 0, kept.output + kept.error)
        expect(kept.output.contains("which the new one replaces"), "the record of the file's path is found: \(kept.output)\(kept.error)")
        expectEqual(kept.error.components(separatedBy: "ignored").count - 1, 1, "one warning: \(kept.error)")
        expect(kept.error.contains("stray.json") && kept.error.contains("other.json") && !kept.error.contains("file-"), kept.error)
        expectEqual(asked(recordsLog, "query"), asked(plainLog, "query"), "the titles are not asked for to find a record the path tells")
        expect(asked(plainLog, "query") > 0, "the file's titles are asked for to tell what the drawing made")
    },

    test("two digests drawn into one unsaved board have a record each, and drawing one again in its place takes back that one") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("unsaved")
        defer { try? FileManager.default.removeItem(at: folder) }
        let records = folder.appendingPathComponent("records")
        func digest(_ name: String) throws -> URL {
            try digestFile(name, #"{"title": "\#(name)", "nodes": [{"title": "\#(name) A", "text": "a"}, {"title": "\#(name) B", "text": "b"}], "edges": [{"from": "\#(name) A", "to": "\#(name) B"}]}"#, in: folder)
        }
        let alpha = try digest("Alpha"), beta = try digest("Beta")
        let target = ["--board", "\(board.number)"]
        let one = try runDigest("all", file: alpha, server: server, target: target + ["--into", "Alpha map"], extra: ["--records", records.path], out: folder.appendingPathComponent("alpha"))
        expectEqual(one.process.status, 0, one.process.output + one.process.error)
        let two = try runDigest("all", file: beta, server: server, target: target + ["--into", "Beta map"], extra: ["--records", records.path], out: folder.appendingPathComponent("beta"))
        expectEqual(two.process.status, 0, two.process.output + two.process.error)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: records.path)) ?? []).filter { $0.hasSuffix(".json") }
        expectEqual(names.count, 2, "a record each: \(names)")
        let held = board.editor.file.shapeCount
        // Beta again, in its place, from an out of its own: its record is the one of this run's digest (by its title), not the first by name
        for _ in 0..<2 {
            let again = try runDigest("all", file: beta, server: server, target: target + ["--into", "Beta map", "--replace"], extra: ["--records", records.path], out: folder.appendingPathComponent("beta-again"))
            expectEqual(again.process.status, 0, again.process.output + again.process.error)
            expect(again.process.output.contains("replace: took back the last drawing") && again.process.output.contains("verify ok"), again.process.output)
            expectEqual(board.editor.file.shapeCount, held, "Beta drawn in its own place")
            let titles = try queried(server, board, "[title]")
            expectEqual(titles.filter { $0 == "Alpha A" }.count, 1, "Alpha's drawing is as it was")
            expectEqual(titles.filter { $0 == "Beta A" }.count, 1, "and Beta's is there once")
        }
    },

    test("a digest whose titles repeat, drawn into a subboard of a board that already holds shapes with those titles: every shape and pill on its plan, the board's own shapes untouched, each shape found by its path; drawn again in its place") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("repeats")
        defer { try? FileManager.default.removeItem(at: folder) }

        // the board's own shapes: a frame called components with an index.ts in it, a frame called Billing with a Checkout in it, a loose Config and app
        for script in [
            """
            frame "components" right of origin (gap: 0) below origin (gap: 0) size: 700x400
            frame "Billing" right of origin (gap: 800) below origin (gap: 0) size: 700x400
            sticky-note "Config" text: "The user's own config." right of origin (gap: 0) below origin (gap: 600) size: 300x200
            sticky-note "app" text: "The user's own app note." right of origin (gap: 400) below origin (gap: 600) size: 300x200
            """,
            """
            sticky-note "index.ts" in "components" text: "The user's own index." right of "components" left (gap: 40) below "components" top (gap: 40) size: 300x200
            sticky-note "Checkout" in "Billing" text: "The user's own checkout." right of "Billing" left (gap: 40) below "Billing" top (gap: 40) size: 300x200
            """,
        ] {
            let own = try canvas(server, ["draw", script])
            expectEqual(own.status, 0, own.output + own.error)
        }
        let ownRows = try landedRows(in: board.editor).split(separator: "\n").map(String.init)
        let ownCount = board.editor.file.shapeCount
        expectEqual(ownCount, 6, "the board's own shapes")

        let run = try runDigest("all", "repeats", server: server, target: ["--board", "\(board.number)", "--into", "Repeats map"], out: folder.appendingPathComponent("out"))
        expectEqual(run.process.status, 0, run.process.output + run.process.error)
        expect(run.process.output.contains("verify ok"), run.process.output)
        let plan = try run.plan, report = try run.report
        let shapes = (plan["boards"]?.arrayValue ?? []).flatMap { $0["shapes"]?.arrayValue ?? [] }
        expectEqual(shapes.count, 15, "every node is a shape")
        expectEqual(shapes.filter { $0["title"] == "index.ts" }.count, 5, "five shapes called index.ts, each its own: \(shapes.map { $0["title"] ?? .null })")
        try expectOnPlan(run, board: board, "repeats")
        try expectNoWarnings(run, "repeats", titlesRepeat: true)
        expect((plan["boards"]?.arrayValue ?? []).flatMap { $0["pills"]?.arrayValue ?? [] }.count > 0, "an edge to a note of the same title on another board is a pill")

        // measured on the board that holds the titles, as on none: the same sizes, each row read by its line (two statements of a title are two shapes)
        let spare = windowedBoard(), other = windowedBoard()
        defer { spare.close(); other.close() }
        let alone = try startCommandServer(boards: [spare, other], frontmost: nil)
        defer { alone.stop() }
        let bare = try runDigest("measure", "repeats", server: alone, target: [], out: folder.appendingPathComponent("measure-none"))
        expectEqual(bare.process.status, 0, bare.process.output + bare.process.error)
        let withTitles = try json(run.out.appendingPathComponent("measure.json")), without = try json(bare.out.appendingPathComponent("measure.json"))
        expect(withTitles["board"] != nil && without["board"] == nil, "the first was measured on the board that holds the titles, the second on none")
        for key in ["shapes", "references", "constants"] { expectEqual(withTitles[key], without[key], "\(key) measured the same") }
        expectEqual(withTitles["warnings"], nil, "and said nothing of the board's titles")

        // the scripts name a shape by a path wherever its title is the file's or repeats, and bare only where nothing else can be meant
        let runs = try require(plan["runs"]?.arrayValue?.compactMap(\.stringValue))
        var scripts = ""
        for name in runs { scripts += try String(contentsOf: run.out.appendingPathComponent("runs/\(name)"), encoding: .utf8) }
        expect(scripts.contains(#"sticky-note "Repeats map" > "app" > "index.ts""#) || scripts.contains(#"sticky-note "lib" > "index.ts""#), "a path names a note whose title repeats: \(scripts)")
        expect(scripts.contains(#"edge "Invoice" -> "Billing" > "Checkout""#) || scripts.contains(#"edge "Invoice" -> "Repeats map" > "Billing" > "Checkout""#), "and an edge's end: \(scripts)")
        // ... and never a title the board has where draw would take it for the board's: as an edge's end, or the container a shape is `in`
        for title in ["components", "Billing", "Config", "app", "Checkout", "index.ts"] {
            expect(!scripts.contains(#"in "\#(title)""#) && !scripts.contains(#"edge "\#(title)""#) && !scripts.contains(#"-> "\#(title)""#) && !scripts.contains(#"of "\#(title)""#),
                   "\(title) is the board's: it is named by a path where a script means the digest's: \(scripts)")
        }

        // the board's own shapes are as they were, and the digest's are all in the subboard it was drawn into
        let rows = try landedRows(in: board.editor).split(separator: "\n").map(String.init)
        for row in ownRows { expect(rows.contains(row), "the board's own shape is as it was: \(row)") }
        expectEqual(try queriedCount(server, board, #"sticky-note[text*="The user's own"]"#), 4, "the board's own notes, and none of the digest's")
        expectEqual(try queried(server, board, #"sticky-note:top-level"#).sorted(), ["Config", "app"], "on the board itself: its own two")

        // each shape is found by its path
        @MainActor func found(_ query: String) throws -> [String] {
            let answer = try canvas(server, ["query", "--board", "\(board.number)", "--fields", "text", "--limit", "10000", query])
            expectEqual(answer.status, 0, answer.error)
            return try require(JSON(text: answer.output)["rows"]?.arrayValue).compactMap { $0["properties"]?["text"]?.stringValue }
        }
        expectEqual(try found(#""Repeats map" > "app" > "index.ts""#), ["The app's entry point."])
        expectEqual(try found(#""Repeats map" > "components" > "index.ts""#), ["The shared components."])
        expectEqual(try found(#""Repeats map" > "admin" > "components" > "index.ts""#), ["The admin's components."])
        expectEqual(try found(#""Repeats map" > "Billing" > "index.ts""#), ["Billing's entry point."])
        expectEqual(try found(#""Repeats map" > "Billing" > "Checkout""#), ["Takes payment for an order."])
        expectEqual(try found(#""Repeats map" > "Checkout""#), ["The storefront's checkout."])
        expectEqual(try queriedCount(server, board, #"[title="index.ts"]"#), 6, "six shapes called index.ts in the file, five of them the digest's")
        // what points at the Checkout on the subboard's board: its note, through the pill, and the others on that board
        expectEqual(try queried(server, board, #":edge-to("Repeats map" > "Billing" > "Checkout")"#).sorted(), ["Checkout", "Invoice", "index.ts", "index.ts"], "who points at the Checkout the subboard holds: the first board's, through the pill, and the notes on its own board")

        // drawn again in its place: the subboard goes, and what the board had stays
        let again = try runDigest("all", "repeats", server: server, target: ["--board", "\(board.number)", "--into", "Repeats map"], extra: ["--replace"], out: folder.appendingPathComponent("out"))
        expectEqual(again.process.status, 0, again.process.output + again.process.error)
        expect(again.process.output.contains("replace: took back") && again.process.output.contains("verify ok"), again.process.output)
        try expectOnPlan(again, board: board, "repeats again")
        let after = try landedRows(in: board.editor).split(separator: "\n").map(String.init)
        for row in ownRows { expect(after.contains(row), "the board's own shape is as it was: \(row)") }
        expectEqual(try queriedCount(server, board, #"[title="index.ts"]"#), 6, "and the digest is there once")
    },

    test("a digest whose titles repeat, drawn into a new file: told apart by paths from the top of the first board, every shape and pill on its plan") {
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
        let folder = try scratchFolder("repeats-file")
        defer { try? FileManager.default.removeItem(at: folder) }

        let file = folder.appendingPathComponent("Repeats")
        let run = try runDigest("all", "repeats", server: server, target: ["--new-file", file.path], out: folder.appendingPathComponent("out"))
        expectEqual(run.process.status, 0, run.process.output + run.process.error)
        expect(run.process.output.contains("verify ok"), run.process.output)
        let board = try require(opened.boards.first)
        try expectOnPlan(run, board: board, "repeats in a new file")
        try expectNoWarnings(run, "repeats in a new file", titlesRepeat: true)
        expectEqual(try queriedCount(server, board, #"[title="index.ts"]"#), 5)
        expectEqual(try queriedCount(server, board, #""admin" > "components" > "index.ts""#), 1)
    },

    test("a digest whose titles repeat, drawn as the board itself (and again in its place), is told apart by paths from the top of the first board") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("repeats-board")
        defer { try? FileManager.default.removeItem(at: folder) }

        let out = folder.appendingPathComponent("out")
        let run = try runDigest("all", "repeats", server: server, target: ["--board", "front"], out: out)
        expectEqual(run.process.status, 0, run.process.output + run.process.error)
        expect(run.process.output.contains("verify ok"), run.process.output)
        try expectOnPlan(run, board: board, "repeats as the board")
        try expectNoWarnings(run, "repeats as the board", titlesRepeat: true)
        let drawn = board.editor.file.shapeCount
        expect(drawn > 15, "the shapes and their arrows: \(drawn)")
        expectEqual(try queried(server, board, #"sticky-note:top-level"#).sorted(), ["Checkout"], "the Checkout on the first board is the only note in no container")
        for _ in 0..<2 {
            let again = try runDigest("all", "repeats", server: server, target: ["--board", "front", "--replace"], out: out)
            expectEqual(again.process.status, 0, again.process.output + again.process.error)
            expect(again.process.output.contains("replace: took back") && again.process.output.contains("verify ok"), again.process.output)
            try expectOnPlan(again, board: board, "repeats as the board, again")
            expectEqual(board.editor.file.shapeCount, drawn, "the same drawing, once")
        }
        // a shape the drawing didn't make, with a title the drawing has, is not taken for the drawing's: the take-back refuses it
        let added = try canvas(server, ["draw", #"sticky-note board > "index.ts" text: "Added by hand" right of board"#, "--board", "\(board.number)"])
        expectEqual(added.status, 0, added.output + added.error)
        let refused = try runDigest("all", "repeats", server: server, target: ["--board", "front", "--replace"], out: out)
        expectEqual(refused.process.status, 1, refused.process.output + refused.process.error)
        expect(refused.process.error.contains("holds shapes this digest's last drawing didn't make (index.ts)"), refused.process.error)
        expectEqual(board.editor.file.shapeCount, drawn + 1, "nothing was taken back")
    },
])
