import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasUI
import Draw
import Drawings
import Foundation
import Mentions
import ShippedTesting
import SkillTesting
import TestKit
import Titles

// canvas-ingest's worked examples (.claude/skills/canvas-ingest/examples): orders, a small TypeScript monorepo drawn as its own
// things (workflows, activities, Lambdas, tables) and its files, and bookshelf, one drawn the usual way, the default lens's
// packages and files with every file a File. Each has its own settings and lens, and is copied into a scratch git repository,
// committed, and drawn by `ingest` from its checked-in scan (`--scan`, so its scip command, which would reach the network, never
// runs), with `canvas` as built against this test's own command server, and a cache of its own. Then `canvas query` is asked
// what its README says it answers.

/// An example as a repository: its files (but the scan, which a scanner makes and a repository doesn't keep) copied into
/// `folder/<name>` and committed. Returns the repository.
@MainActor private func exampleRepository(_ name: String, in folder: URL) throws -> URL {
    let repo = folder.appendingPathComponent(name)
    try FileManager.default.copyItem(at: example(in: name), to: repo)
    try FileManager.default.removeItem(at: repo.appendingPathComponent("scan.json"))
    try git(repo, ["init", "-q"])
    try git(repo, ["add", "-A"])
    try git(repo, ["commit", "-q", "-m", "the \(name) example"])
    return repo
}

/// An example drawn by `ingest` from the scan checked in beside it (never its scip command), as the board in front of the test's
/// own server, with a cache of its own in `folder`: what `ingest` said, and the run's folder in the cache. The lens warns of
/// nothing in its own example.
@MainActor private func drawExample(_ name: String, in folder: URL, server: CommandServer) throws -> (drawn: ProcessOutput, run: URL) {
    let repo = try exampleRepository(name, in: folder)
    let environment = ["CANVAS_CLI": builtExecutable("CanvasCLI").path, "CANVAS_SOCKET": server.path,
                       "CANVAS_INGEST_CACHE": folder.appendingPathComponent("cache").path,
                       "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
    let ingest = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".claude/skills/canvas-ingest/ingest")
    let drawn = try run(ingest, [repo.path, "--scan", example("scan.json", in: name).path], environment: environment, timeout: 280)
    expectEqual(drawn.status, 0, drawn.output + drawn.error)
    expect(drawn.output.contains("drawing from the scan given by hand") && !drawn.output.contains("making the SCIP index"), drawn.output)
    expect(drawn.output.contains("applied ") && drawn.output.contains(": shapes "), drawn.output)
    expect(!drawn.error.contains("lens: "), "the lens warns of nothing in its own example: \(drawn.error)")
    let where_ = try run(ingest, [repo.path, "--where"], environment: environment)
    let kept = URL(fileURLWithPath: where_.output.trimmingCharacters(in: .whitespacesAndNewlines))
    let runs = try FileManager.default.contentsOfDirectory(atPath: kept.appendingPathComponent("runs").path).sorted()
    return (drawn, kept.appendingPathComponent("runs/\(try require(runs.last, "a run was kept"))"))
}

/// A run's graph document checks with nothing wrong, and `canvas apply` of it warned only of what a typed drawing gives by design (a
/// Needed row still empty, a relationship that doesn't fit its ends). Returns what the drawing said.
@MainActor private func expectDrawnByDesign(_ runFolder: URL) throws -> [String] {
    let checked = try digestCheck(runFolder.appendingPathComponent("graph.json"), timeout: 120)
    expectEqual(checked.status, 0, checked.output + checked.error)
    let verdict = try JSON(text: checked.output)
    expectEqual(verdict["errors"], .array([]), checked.output)
    expectEqual(verdict["warnings"], .array([]), checked.output)
    let result = try json(runFolder.appendingPathComponent("out/results/apply.json"))
    var said: [String] = []
    for message in (result["warnings"]?.arrayValue ?? []).compactMap({ $0["message"]?.stringValue }) {
        expect(isByDesign(message), "apply warned of more than a typed drawing does: \(message)")
        said.append(message)
    }
    for node in result["nodes"]?.arrayValue ?? [] {
        for problem in node["problems"]?.arrayValue ?? [] {
            let message = problem["message"]?.stringValue ?? problem.stringValue ?? ""
            expect(isByDesign(message), "\(node["key"] ?? .null) has a problem not by design: \(message)")
            said.append("\(node["key"]?.stringValue ?? "?"): \(message)")
        }
    }
    return said
}

/// What a typed drawing says by design: a Needed row still empty, a relationship that doesn't fit its ends, a row past Only one. (Two
/// files of one name in a service's Files frame are titled by the ends of their paths that tell them apart, files-are-typed, so no
/// path is two shapes'.)
private func isByDesign(_ message: String) -> Bool {
    message.hasSuffix(" is needed") || message.contains("should have at most") || message.contains(" runs from ") || message.contains(" runs to ")
}

/// A query block of the README: the query, and what its first line says it answers (`/* matches: "a", "b" */` or `/* count: N */`).
private struct ReadmeQuery {
    let query: String
    let matches: [String]?
    let count: Int?
}

@MainActor private func readmeQueries(of name: String) throws -> [ReadmeQuery] {
    let text = try String(contentsOf: example("README.md", in: name), encoding: .utf8)
    var out: [ReadmeQuery] = []
    var block: [String]? = nil
    for line in text.components(separatedBy: "\n") {
        if block == nil, line == "```query" { block = []; continue }
        guard var lines = block else { continue }
        if line == "```" {
            let head = lines.removeFirst()
            let said = head.replacingOccurrences(of: "/*", with: "").replacingOccurrences(of: "*/", with: "").trimmingCharacters(in: .whitespaces)
            let query = lines.joined(separator: "\n")
            if said.hasPrefix("matches:") {
                let titles = said.dropFirst("matches:".count).components(separatedBy: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }.filter { !$0.isEmpty }
                out.append(ReadmeQuery(query: query, matches: titles, count: nil))
            } else if said.hasPrefix("count:") {
                out.append(ReadmeQuery(query: query, matches: nil, count: Int(said.dropFirst("count:".count).trimmingCharacters(in: .whitespaces))))
            } else {
                expect(false, "a README query says what it answers on its first line: \(head)")
            }
            block = nil
            continue
        }
        lines.append(line)
        block = lines
    }
    return out
}

@MainActor let ingestExampleTests = Suite("canvas-ingest's worked examples: TypeScript monorepos drawn by their own lenses, and asked what they hold", [
    test("the orders example is drawn from its scan by its lens, checks and verifies with only the warnings its types give by design, has no About note, and canvas query answers its questions as drawn") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("IngestExampleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (_, runFolder) = try drawExample("orders", in: folder, server: server)
        let graph = try json(runFolder.appendingPathComponent("graph.json"))
        expectEqual(graph["drawing"], "orders", "the drawing is named for the repository's folder")

        // the drawing's warnings are only those its types give by design: an activity's Needed "run by" row, empty while its notes are
        // drawn and before the arrows that fill it are (in the end only one is left empty: the query for :incomplete, below)
        let said = try expectDrawnByDesign(runFolder)
        expect(said.contains { $0.hasSuffix("sendReceipt\": run by is needed") || $0.hasSuffix("#sendReceipt: run by is needed") }, "what the drawing says of its types: \(said)")

        // the root holds the services, the tables and the types, and no note of what the whole is
        let editor = board.editor
        expect(!editor.document.shapes.contains { editor.registry.title(of: $0)?.hasPrefix("About ") == true }, "no About note")

        @MainActor func ask(_ query: String) throws -> (titles: [String], count: Int) {
            let answer = try canvas(server, ["query", "--board", "\(board.number)", "--brief", "--limit", "10000", query])
            expectEqual(answer.status, 0, "\(query): \(answer.error)")
            let result = try JSON(text: answer.output)
            return ((result["rows"]?.arrayValue ?? []).compactMap { $0["title"]?.stringValue }, Int(result["count"]?.numberValue ?? -1))
        }

        // the notes of each type, and the arrows of each relationship type, as the graph document says them (a type by its key, `type:Workflow`)
        let nodes = graph["nodes"]?.arrayValue ?? [], edges = graph["edges"]?.arrayValue ?? []
        func title(_ node: JSON) -> String { node["props"]?["title"]?.stringValue ?? "?" }
        func isA(_ node: JSON) -> [String] { (node["props"]?["is"]?.arrayValue ?? []).compactMap(\.stringValue) }
        func relation(_ edge: JSON) -> String? { (edge["props"]?["is"]?.arrayValue ?? []).compactMap(\.stringValue).first.map { String($0.dropFirst("type:".count)) } }
        let titleOf = Dictionary(uniqueKeysWithValues: nodes.compactMap { n in n["key"]?.stringValue.map { ($0, title(n)) } })
        for type in ["Workflow", "Activity", "Lambda", "Table", "File", "Collection"] {
            let typed = nodes.filter { isA($0) == ["type:\(type)"] }.map(title)
            expect(!typed.isEmpty, "\(type) has notes")
            expectEqual(try ask(#":is-a("\#(type)")"#).titles.sorted(), typed.sorted(), "the notes of \(type)")
        }
        // the frames of the type Collection: a frame can be of a type, as a note is
        let collections = nodes.filter { isA($0) == ["type:Collection"] }
        expectEqual(collections.count, 5, "each service's frames of workflows, activities, Lambdas and files")
        expect(collections.allSatisfy { $0["kind"] == "frame" && $0["props"]?["fieldValues"]?["holds"]?.stringValue?.isEmpty == false }, "typed frames, each with a `holds`")
        expectEqual(try ask(#":is-a("Collection")"#).count, 5)
        expectEqual(try ask(#":is-a("Collection")[fieldValues.holds="Lambda"]"#).titles, ["Lambdas"], "the frame that holds Lambdas, found by its value")
        expectEqual(try ask("sticky-note[relationship]").titles.sorted(), ["declared in", "reads", "runs", "writes"])
        for kind in ["runs", "reads", "writes", "declared in"] {
            expectEqual(try ask(#"arrow:is-a("\#(kind)")"#).count, edges.filter { relation($0) == kind }.count, "the arrows of \(kind)")
        }
        // who reads or writes each table, in one hop (an activity or a Lambda), and which workflows write it, in two
        func starts(_ kind: String, at ends: Set<String>) -> Set<String> {
            Set(edges.filter { relation($0) == kind && ends.contains(titleOf[$0["to"]?.stringValue ?? ""] ?? "") }.compactMap { titleOf[$0["from"]?.stringValue ?? ""] })
        }
        for table in ["customers", "orders", "payments", "refunds"] {
            for kind in ["reads", "writes"] {
                let oneHop = #":start-of(arrow:is-a("\#(kind)"):ends-at("\#(table)"))"#
                expectEqual(Set(try ask(oneHop).titles), starts(kind, at: [table]), "who \(kind) \(table)")
                let twoHops = #":start-of(arrow:is-a("runs"):ends-at(\#(oneHop)))"#
                expectEqual(Set(try ask(twoHops).titles), starts("runs", at: starts(kind, at: [table])), "the workflows that \(kind) \(table), through their activities")
            }
        }
        // every file of a service is a File, and each workflow, activity and Lambda is declared in the one its key says
        let files = nodes.filter { isA($0) == ["type:File"] }
        expectEqual(files.count, 11, "the services' files")
        expect(files.allSatisfy { $0["key"]?.stringValue?.hasPrefix("file:") == true && $0["props"]?["fieldValues"]?["path"]?.stringValue == String($0["key"]?.stringValue?.dropFirst("file:".count) ?? "") }, "keyed by the code, with the path as a value")
        // files-are-typed: titled by its name, else by the end of its path that tells it from another in its Files frame
        expectEqual(titleOf["file:services/orders/src/activities/index.ts"], "activities/index.ts")
        expectEqual(titleOf["file:services/orders/src/workflows/index.ts"], "workflows/index.ts")
        expectEqual(titleOf["file:services/orders/src/worker.ts"], "worker.ts", "a name no other file of the frame has stays bare")
        let things = nodes.filter { ["type:Workflow", "type:Activity", "type:Lambda"].contains(isA($0).first ?? "") }
        expectEqual(things.count, 12, "two workflows, eight activities and two Lambdas")
        for thing in things {
            let key = thing["key"]?.stringValue ?? "?"
            let declared = edges.filter { relation($0) == "declared in" && $0["from"] == .string(key) }.compactMap { $0["to"]?.stringValue }
            // workflow:<path>#<name>, activity:<path>#<name>, lambda:<config>#<name>: the file is the one the key names (a Lambda's is its handler's)
            expectEqual(declared.count, 1, "\(key) is declared in one file: \(declared)")
            if !key.hasPrefix("lambda:") { expectEqual(declared.first, "file:" + (key.split(separator: ":", maxSplits: 1).last?.split(separator: "#").first.map(String.init) ?? ""), "the file \(key) is declared in") }
        }
        expectEqual(try ask(":incomplete").titles, ["sendReceipt"], "the activity no workflow runs")
        expectEqual(try ask("arrow:misfit").count, 0)
        // the app holds the drawing by key, so drawing it again moves nothing: every node is a shape of the file's record
        let ids = board.editor.file[DrawingsProperty.self].drawings["orders"]?.idsByKey ?? [:]
        expect(Set(ids.keys).isSuperset(of: Set(nodes.compactMap { $0["key"]?.stringValue })), "a shape for every key")

        // and the README's questions answer as it says
        let questions = try readmeQueries(of: "orders")
        expect(questions.count >= 5, "the README asks its questions: \(questions.count)")
        for question in questions {
            let answer = try ask(question.query)
            if let matches = question.matches { expectEqual(answer.titles.sorted(), matches.sorted(), question.query) }
            if let count = question.count { expectEqual(answer.count, count, question.query) }
        }
    },
])

@MainActor let ingestExampleTests2 = Suite("canvas-ingest's worked examples, the bookshelf and the orders lens's names", [
    test("the bookshelf example is drawn the usual way, the default lens's packages and files with every file a File, checks and verifies with nothing said, and canvas query answers its questions as drawn") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("IngestExampleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (_, runFolder) = try drawExample("bookshelf", in: folder, server: server)
        let graph = try json(runFolder.appendingPathComponent("graph.json"))
        expectEqual(graph["drawing"], "bookshelf")
        expectEqual(try expectDrawnByDesign(runFolder), [], "a File has no row that is needed, so the drawing says nothing")

        // every file the scan has is a note of the one type, File, keyed by its path, its path and length its values, and the length said once
        let nodes = graph["nodes"]?.arrayValue ?? []
        let scanned = try json(example("scan.json", in: "bookshelf"))["files"]?.arrayValue ?? []
        let lines = Dictionary(uniqueKeysWithValues: scanned.compactMap { f in f["path"]?.stringValue.map { ($0, f["lines"]?.numberValue ?? -1) } })
        let files = nodes.filter { $0["props"]?["is"] == ["type:File"] }
        expectEqual(files.count, 20)
        expectEqual(Set(files.compactMap { $0["key"]?.stringValue }), Set(lines.keys.map { "file:" + $0 }), "a File for each file of the scan, keyed by its path")
        for file in files {
            let path = String((file["key"]?.stringValue ?? "?").dropFirst("file:".count))
            expectEqual(file["props"]?["fieldValues"]?["path"]?.stringValue, path)
            expectEqual(file["props"]?["fieldValues"]?["lines"]?.numberValue, lines[path], "\(path)'s length")
            expect(!(file["props"]?["text"]?.stringValue ?? "").hasSuffix(" lines"), "\(path)'s note says its length as a value alone: \(file["props"]?["text"] ?? .null)")
        }
        expectEqual(nodes.filter { $0["props"]?["schema"] != nil }.compactMap { $0["props"]?["title"]?.stringValue }, ["File"])
        expectEqual(Set(nodes.compactMap { $0["key"]?.stringValue }).count, nodes.count, "three index.ts are three notes of one title, told apart by their keys")
        expectEqual(files.filter { $0["props"]?["title"] == "index.ts" }.count, 3)

        @MainActor func ask(_ query: String) throws -> (titles: [String], count: Int) {
            let answer = try canvas(server, ["query", "--board", "\(board.number)", "--brief", "--limit", "10000", query])
            expectEqual(answer.status, 0, "\(query): \(answer.error)")
            let result = try JSON(text: answer.output)
            return ((result["rows"]?.arrayValue ?? []).compactMap { $0["title"]?.stringValue }, Int(result["count"]?.numberValue ?? -1))
        }
        expectEqual(try ask(#":is-a("File")"#).titles.sorted(), files.compactMap { $0["props"]?["title"]?.stringValue }.sorted(), "the File notes, as the graph says them")
        expectEqual(try ask(":incomplete, :invalid, :warned").count, 0)

        // and the README's questions answer as it says
        let questions = try readmeQueries(of: "bookshelf")
        expect(questions.count >= 5, "the README asks its questions: \(questions.count)")
        for question in questions {
            let answer = try ask(question.query)
            if let matches = question.matches { expectEqual(answer.titles.sorted(), matches.sorted(), question.query) }
            if let count = question.count { expectEqual(answer.count, count, question.query) }
        }
    },
    test("the orders lens gives each thing the name the code does: two services with a workflow and an activity of one name are drawn under that name, told apart by key, and asked for by where they are") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("IngestExampleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // orders and billing each run a syncWorkflow, which runs a notify, which writes the outbox table
        let repo = folder.appendingPathComponent("shop")
        func put(_ text: String, _ path: String) throws {
            let url = repo.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try put("CREATE TABLE outbox (id text PRIMARY KEY);\n", "db/migrations/001_outbox.sql")
        for service in ["orders", "billing"] {
            try put("""
                import { proxyActivities } from "@temporalio/workflow";
                const { notify } = proxyActivities<any>({ startToCloseTimeout: "1 minute" });

                /** Sends what is waiting. */
                export async function syncWorkflow(): Promise<void> {
                  await notify();
                }

                """, "services/\(service)/src/workflows/sync.ts")
            try put("""
                /** Tells the customer. */
                export async function notify(): Promise<void> {
                  await query(`INSERT INTO outbox (id) VALUES ($1)`);
                }

                """, "services/\(service)/src/activities/notify.ts")
        }
        try put(try String(contentsOf: example(".canvas/lens.py"), encoding: .utf8), ".canvas/lens.py")
        try git(repo, ["init", "-q"])
        try git(repo, ["add", "-A"])
        try git(repo, ["commit", "-q", "-m", "two services that repeat a name"])
        func module(_ service: String) -> String {
            #"{"name": "@shop/\#(service)", "path": "services/\#(service)/src", "deps": [], "test": false, "layer": null, "lines": 12, "doc": null, "folders": {}, "files": ["workflows/sync.ts", "activities/notify.ts"]}"#
        }
        func file(_ service: String, _ rel: String, name: String, line: Int) -> String {
            #"{"module": "@shop/\#(service)", "rel": "\#(rel)", "path": "services/\#(service)/src/\#(rel)", "lines": 6, "doc": null, "api": true, "decls": [{"name": "\#(name)", "kind": "function", "visibility": "public", "line": \#(line)}]}"#
        }
        let scan = """
            {"language": "typescript", "name": "shop", "modules": [\(module("orders")), \(module("billing"))],
             "files": [\(file("orders", "workflows/sync.ts", name: "syncWorkflow", line: 5)), \(file("orders", "activities/notify.ts", name: "notify", line: 2)),
                       \(file("billing", "workflows/sync.ts", name: "syncWorkflow", line: 5)), \(file("billing", "activities/notify.ts", name: "notify", line: 2))],
             "uses": []}
            """
        let scanFile = folder.appendingPathComponent("scan.json")
        try scan.write(to: scanFile, atomically: true, encoding: .utf8)
        let environment = ["CANVAS_CLI": builtExecutable("CanvasCLI").path, "CANVAS_SOCKET": server.path,
                           "CANVAS_INGEST_CACHE": folder.appendingPathComponent("cache").path,
                           "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        let ingest = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".claude/skills/canvas-ingest/ingest")
        let drawn = try run(ingest, [repo.path, "--scan", scanFile.path], environment: environment, timeout: 280)
        expectEqual(drawn.status, 0, drawn.output + drawn.error)
        expect(drawn.output.contains("applied shop: shapes"), drawn.output)
        expect(!drawn.error.contains("lens: "), "no name is reworded for another service's: \(drawn.error)")
        let where_ = try run(ingest, [repo.path, "--where"], environment: environment)
        let kept = URL(fileURLWithPath: where_.output.trimmingCharacters(in: .whitespacesAndNewlines))
        let runFolder = kept.appendingPathComponent("runs/\(try require(try FileManager.default.contentsOfDirectory(atPath: kept.appendingPathComponent("runs").path).sorted().last))")
        let graph = try json(runFolder.appendingPathComponent("graph.json"))
        let nodes = graph["nodes"]?.arrayValue ?? [], edges = graph["edges"]?.arrayValue ?? []
        // each service's board has the frames and notes every service's has, under the same names, and each is a node of its own key
        func keys(_ title: String) -> [String] { nodes.filter { $0["props"]?["title"] == .string(title) }.compactMap { $0["key"]?.stringValue }.sorted() }
        expectEqual(keys("syncWorkflow"), ["workflow:services/billing/src/workflows/sync.ts#syncWorkflow", "workflow:services/orders/src/workflows/sync.ts#syncWorkflow"])
        expectEqual(keys("notify"), ["activity:services/billing/src/activities/notify.ts#notify", "activity:services/orders/src/activities/notify.ts#notify"])
        expectEqual(keys("Workflows"), ["frame:@shop/billing/Workflows", "frame:@shop/orders/Workflows"])
        expectEqual(keys("sync.ts").count, 2)
        expectEqual(keys("outbox"), ["table:outbox"])
        expect(nodes.allSatisfy { $0["id"] == nil && $0["props"]?["id"] == nil }, "no node is named by an id: a key is its name")
        // a workflow is declared in its own service's file
        expectEqual(edges.filter { $0["props"]?["is"] == ["type:declared in"] && $0["from"] == "workflow:services/orders/src/workflows/sync.ts#syncWorkflow" }.compactMap { $0["to"]?.stringValue },
                    ["file:services/orders/src/workflows/sync.ts"])
        // a typed arrow runs between the notes it names by key
        let runs = edges.filter { $0["props"]?["is"] == ["type:runs"] }
        expectEqual(runs.compactMap { "\($0["from"]?.stringValue ?? "?") > \($0["to"]?.stringValue ?? "?")" }.sorted(),
                    ["workflow:services/billing/src/workflows/sync.ts#syncWorkflow > activity:services/billing/src/activities/notify.ts#notify",
                     "workflow:services/orders/src/workflows/sync.ts#syncWorkflow > activity:services/orders/src/activities/notify.ts#notify"])
        let checked = try digestCheck(runFolder.appendingPathComponent("graph.json"), timeout: 120)
        expectEqual(checked.status, 0, checked.output + checked.error)
        expectEqual(try JSON(text: checked.output), ["errors": [], "warnings": []])
        // and the app answers for each by where it is
        @MainActor func ask(_ query: String) throws -> [(title: String, inside: String)] {
            let answer = try canvas(server, ["query", "--board", "\(board.number)", "--limit", "100", query])
            expectEqual(answer.status, 0, "\(query): \(answer.error)")
            return try (JSON(text: answer.output)["rows"]?.arrayValue ?? []).map {
                ($0["title"]?.stringValue ?? "?", ($0["inside"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: " > "))
            }.sorted { $0.inside < $1.inside }
        }
        func said(_ rows: [(title: String, inside: String)]) -> [String] { rows.map { "\($0.title) in \($0.inside)" } }
        expectEqual(said(try ask(#":is-a("Workflow")"#)), ["syncWorkflow in Services > @shop/billing > Workflows", "syncWorkflow in Services > @shop/orders > Workflows"])
        expectEqual(try ask(#"arrow:is-a("runs")"#).count, 2)
        expectEqual(said(try ask(#":start-of(arrow:is-a("writes"):ends-at("outbox"))"#)), ["notify in Services > @shop/billing > Activities", "notify in Services > @shop/orders > Activities"],
                    "who writes the outbox: both services' notify")
        expectEqual(said(try ask(#":end-of(arrow:is-a("runs"):starts-at("@shop/orders" > "Workflows" > "syncWorkflow"))"#)), ["notify in Services > @shop/orders > Activities"],
                    "what orders' workflow runs, asked for by its path")
        expectEqual(said(try ask(":incomplete")), [], "every notify is run by a workflow")
    },
])
