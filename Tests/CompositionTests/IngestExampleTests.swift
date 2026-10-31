import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasUI
import Foundation
import Mentions
import ShippedTesting
import TestKit
import Titles

// canvas-ingest's worked examples (.claude/skills/canvas-ingest/examples): orders, a small TypeScript monorepo drawn as its own
// things (workflows, activities, Lambdas, tables) and its files, and bookshelf, one drawn the usual way, the default lens's
// packages and files with every file a File. Each has its own settings and lens, and is copied into a scratch git repository,
// committed, and drawn by `ingest` from its checked-in scan (`--scan`, so its scip command, which would reach the network, never
// runs), with `canvas` as built against this test's own command server, and a cache of its own. Then `canvas query` is asked
// what its README says it answers.

/// An example's folder, or a path in it, absolute (tests run from the repository's root).
private func example(_ path: String = "", in name: String = "orders") -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".claude/skills/canvas-ingest/examples/\(name)").appendingPathComponent(path)
}

private let jsc = "/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc"

private func json(_ url: URL) throws -> JSON { try JSON(text: String(contentsOf: url, encoding: .utf8)) }

/// `git` on a scratch repository, with no configuration of the user's.
@MainActor @discardableResult private func git(_ repo: URL, _ arguments: [String]) throws -> ProcessOutput {
    let done = try run(URL(fileURLWithPath: "/usr/bin/git"),
                       ["-C", repo.path, "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"] + arguments,
                       environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"], timeout: 60)
    expectEqual(done.status, 0, "git \(arguments.joined(separator: " ")): \(done.output)\(done.error)")
    return done
}

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
    expect(drawn.output.contains("verify ok"), drawn.output)
    expect(!drawn.error.contains("lens: "), "the lens warns of nothing in its own example: \(drawn.error)")
    let where_ = try run(ingest, [repo.path, "--where"], environment: environment)
    let kept = URL(fileURLWithPath: where_.output.trimmingCharacters(in: .whitespacesAndNewlines))
    let runs = try FileManager.default.contentsOfDirectory(atPath: kept.appendingPathComponent("runs").path).sorted()
    return (drawn, kept.appendingPathComponent("runs/\(try require(runs.last, "a run was kept"))"))
}

/// A run's digest checks with nothing wrong and no frame or board over what reads well, and its drawing warned only of what a
/// typed drawing gives by design and pushed nothing past anything. Returns what the drawing said.
@MainActor private func expectDrawnByDesign(_ runFolder: URL) throws -> [String] {
    let checked = try run(URL(fileURLWithPath: jsc), [URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".claude/skills/canvas-digest/tool/main.js").path, "--", "check", runFolder.appendingPathComponent("digest.json").path], timeout: 120)
    expectEqual(checked.status, 0, checked.output + checked.error)
    let verdict = try JSON(text: checked.output)
    expectEqual(verdict["errors"], .array([]), checked.output)
    expectEqual(verdict["warnings"], .array([]), checked.output)
    let plan = try json(runFolder.appendingPathComponent("out/plan.json"))
    var said: [String] = []
    for name in plan["runs"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
        let result = try json(runFolder.appendingPathComponent("out/results/\(name.replacingOccurrences(of: ".draw", with: "")).json"))
        for message in (result["warnings"]?.arrayValue ?? []).compactMap({ $0["message"]?.stringValue }) where !message.contains("landed outside the view") {
            expect(isByDesign(message), "\(name) warned of more than a typed drawing does: \(message)")
            said.append(message)
        }
        for change in result["changes"]?.arrayValue ?? [] {
            expect(change["pushedPast"] == nil, "\(name) pushed a shape past another: \(change)")
            for problem in change["problems"]?.arrayValue ?? [] {
                let message = problem["message"]?.stringValue ?? ""
                expect(isByDesign(message), "\(name): \(change["title"] ?? .null) has a problem not by design: \(message)")
                said.append("\(change["title"]?.stringValue ?? "?"): \(message)")
            }
        }
    }
    return said
}

/// What a typed drawing says by design: a Needed row still empty, a relationship that doesn't fit its ends, a row past Only one.
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
        let digest = try json(runFolder.appendingPathComponent("digest.json"))

        // the drawing's warnings are only those its types give by design: an activity's Needed "run by" row, empty while its notes are
        // drawn and before the arrows that fill it are (in the end only one is left empty: the query for :incomplete, below)
        let said = try expectDrawnByDesign(runFolder)
        expect(said.contains("sendReceipt: run by is needed"), "what the drawing says of its types: \(said)")

        // the root holds the services, the tables and the types, and no note of what the whole is
        let editor = board.editor
        expect(!editor.document.shapes.contains { editor.registry.title(of: $0)?.hasPrefix("About ") == true }, "no About note")

        @MainActor func ask(_ query: String) throws -> (titles: [String], count: Int) {
            let answer = try canvas(server, ["query", "--board", "\(board.number)", "--brief", "--limit", "10000", query])
            expectEqual(answer.status, 0, "\(query): \(answer.error)")
            let result = try JSON(text: answer.output)
            return ((result["rows"]?.arrayValue ?? []).compactMap { $0["title"]?.stringValue }, Int(result["count"]?.numberValue ?? -1))
        }

        // the notes of each type, and the arrows of each relationship type, as the digest says them
        let nodes = digest["nodes"]?.arrayValue ?? [], edges = digest["edges"]?.arrayValue ?? []
        for type in ["Workflow", "Activity", "Lambda", "Table", "File"] {
            let typed = nodes.filter { $0["is"] == .string(type) }.compactMap { $0["title"]?.stringValue }
            expectEqual(try ask(#":is-a("\#(type)")"#).titles.sorted(), typed.sorted(), "the notes of \(type)")
        }
        expectEqual(try ask("sticky-note[relationship]").titles.sorted(), ["declared in", "reads", "runs", "writes"])
        for relation in ["runs", "reads", "writes", "declared in"] {
            expectEqual(try ask(#"arrow:is-a("\#(relation)")"#).count, edges.filter { $0["is"] == .string(relation) }.count, "the arrows of \(relation)")
        }
        // who reads or writes each table, in one hop (an activity or a Lambda), and which workflows write it, in two
        func starts(_ relation: String, at ends: Set<String>) -> Set<String> {
            Set(edges.filter { $0["is"] == .string(relation) && ends.contains($0["to"]?.stringValue ?? "") }.compactMap { $0["from"]?.stringValue })
        }
        for table in ["customers", "orders", "payments", "refunds"] {
            for relation in ["reads", "writes"] {
                let oneHop = #":start-of(arrow:is-a("\#(relation)"):ends-at("\#(table)"))"#
                expectEqual(Set(try ask(oneHop).titles), starts(relation, at: [table]), "who \(relation) \(table)")
                let twoHops = #":start-of(arrow:is-a("runs"):ends-at(\#(oneHop)))"#
                expectEqual(Set(try ask(twoHops).titles), starts("runs", at: starts(relation, at: [table])), "the workflows that \(relation) \(table), through their activities")
            }
        }
        // every file of a service is a File, and each workflow, activity and Lambda is declared in the one its source is
        let files = nodes.filter { $0["is"] == "File" }
        expectEqual(files.count, 11, "the services' files")
        let fileOf = Dictionary(uniqueKeysWithValues: files.compactMap { file in file["source"]?.stringValue.map { ($0, file["id"]?.stringValue ?? file["title"]?.stringValue ?? "?") } })
        let things = nodes.filter { ["Workflow", "Activity", "Lambda"].contains($0["is"]?.stringValue ?? "") }
        expectEqual(things.count, 12, "two workflows, eight activities and two Lambdas")
        for thing in things {
            let name = thing["id"]?.stringValue ?? thing["title"]?.stringValue ?? "?"
            let declared = edges.filter { $0["is"] == "declared in" && $0["from"] == .string(name) }.compactMap { $0["to"]?.stringValue }
            expectEqual(declared, [fileOf[thing["source"]?["path"]?.stringValue ?? ""] ?? "no file"], "the file \(name) is declared in")
        }
        expectEqual(try ask(":incomplete").titles, ["sendReceipt"], "the activity no workflow runs")
        expectEqual(try ask("arrow:misfit").count, 0)

        // and the README's questions answer as it says
        let questions = try readmeQueries(of: "orders")
        expect(questions.count >= 5, "the README asks its questions: \(questions.count)")
        for question in questions {
            let answer = try ask(question.query)
            if let matches = question.matches { expectEqual(answer.titles.sorted(), matches.sorted(), question.query) }
            if let count = question.count { expectEqual(answer.count, count, question.query) }
        }
    },
    test("the orders lens passes over what its conventions don't read and says so where it can: a serverless.yml that is no mapping, SQL words that are no tables, a proxy made in a helper, a multi-line JSDoc, a service outside services/") {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("IngestExampleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repo = folder.appendingPathComponent("shop")
        func put(_ text: String, _ path: String) throws {
            let url = repo.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try put("CREATE TABLE payments (id text PRIMARY KEY);\nCREATE TABLE orders (id text PRIMARY KEY);\n", "db/migrations/001_init.sql")
        // line 8 is the workflow: a JSDoc of several lines over it, and its calls through a namespace
        try put("""
            import { proxyActivities } from "@temporalio/workflow";
            const acts = proxyActivities<any>({ startToCloseTimeout: "1 minute" });

            /**
             * Pays an order through the provider. The rest of the comment
             * is for people reading the code.
             */
            export async function payWorkflow(): Promise<void> {
              await acts.pay();
              await acts.audit();
            }

            """, "services/shop/src/workflows/pay.ts")
        // the SDK imported as a namespace (`wf.proxyActivities`), as half of Temporal's own samples do: read
        try put("""
            import * as wf from "@temporalio/workflow";
            const { pay } = wf.proxyActivities<any>({});

            export async function nsWorkflow(): Promise<void> {
              await pay();
            }

            """, "services/shop/src/workflows/ns.ts")
        // a form the lens doesn't read: the proxy is made in a helper
        try put("""
            import { proxyActivities } from "@temporalio/workflow";
            function make() { return proxyActivities<any>({}); }
            const acts = make();

            export async function lostWorkflow(): Promise<void> {
              await acts.pay();
            }

            """, "services/shop/src/workflows/lost.ts")
        // words that are no tables: EXTRACT(.. FROM ..), prose, a WITH's name, FOR UPDATE OF
        try put("""
            /** Takes the money. */
            export async function pay(): Promise<void> {
              await query(`SELECT EXTRACT(epoch FROM created_at) FROM payments`);
              await query("cannot read from stream");
              await query(`WITH recent AS (SELECT id FROM orders) SELECT id FROM recent`);
              await query(`SELECT id FROM orders WHERE id = $1 FOR UPDATE OF orders`);
            }

            /** Logs. */
            export async function audit(): Promise<void> {}

            /** An exported helper no workflow runs. */
            export async function helper(): Promise<void> {}

            """, "services/shop/src/activities/pay.ts")
        try put("functions: ${file(./functions.yml)}\n", "services/shop/serverless.yml")
        try put("- a\n- b\n", "apps/legacy/serverless.yml")
        try put("export async function oldWorkflow(): Promise<void> {}\n", "apps/legacy/src/workflows/old.ts")
        try put(try String(contentsOf: example(".canvas/lens.py"), encoding: .utf8), ".canvas/lens.py")
        try git(repo, ["init", "-q"])
        try git(repo, ["add", "-A"])
        try git(repo, ["commit", "-q", "-m", "a service outside the example's conventions"])
        let sha = try git(repo, ["rev-parse", "HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        func file(_ module: String, _ rel: String, _ path: String, decls: [(String, String, String, Int)]) -> String {
            let decls = decls.map { #"{"name": "\#($0.0)", "kind": "\#($0.1)", "visibility": "\#($0.2)", "line": \#($0.3)}"# }.joined(separator: ", ")
            return #"{"module": "\#(module)", "rel": "\#(rel)", "path": "\#(path)", "lines": 12, "doc": null, "api": true, "decls": [\#(decls)]}"#
        }
        let scan = """
            {"language": "typescript", "name": "shop",
             "modules": [
              {"name": "@shop/shop", "path": "services/shop/src", "deps": [], "test": false, "layer": null, "lines": 40, "doc": null, "folders": {},
               "files": ["workflows/pay.ts", "workflows/ns.ts", "workflows/lost.ts", "activities/pay.ts"]},
              {"name": "@shop/legacy", "path": "apps/legacy/src", "deps": [], "test": false, "layer": null, "lines": 1, "doc": null, "folders": {}, "files": ["workflows/old.ts"]}],
             "files": [
              \(file("@shop/shop", "workflows/pay.ts", "services/shop/src/workflows/pay.ts", decls: [("acts", "value", "private", 2), ("payWorkflow", "function", "public", 8)])),
              \(file("@shop/shop", "workflows/ns.ts", "services/shop/src/workflows/ns.ts", decls: [("nsWorkflow", "function", "public", 4)])),
              \(file("@shop/shop", "workflows/lost.ts", "services/shop/src/workflows/lost.ts", decls: [("make", "function", "private", 2), ("acts", "value", "private", 3), ("lostWorkflow", "function", "public", 5)])),
              \(file("@shop/shop", "activities/pay.ts", "services/shop/src/activities/pay.ts", decls: [("pay", "function", "public", 2), ("audit", "function", "public", 10), ("helper", "function", "public", 13)])),
              \(file("@shop/legacy", "workflows/old.ts", "apps/legacy/src/workflows/old.ts", decls: [("oldWorkflow", "function", "public", 1)]))],
             "uses": []}
            """
        try scan.write(to: folder.appendingPathComponent("scan.json"), atomically: true, encoding: .utf8)
        let runner = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".claude/skills/canvas-ingest/runner/run.py")
        let digestFile = folder.appendingPathComponent("digest.json")
        let made = try run(URL(fileURLWithPath: "/usr/bin/python3"), [runner.path, repo.path, folder.appendingPathComponent("scan.json").path, digestFile.path,
                                                                    "--lens", repo.appendingPathComponent(".canvas/lens.py").path, "--commit", sha], timeout: 120)
        expectEqual(made.status, 0, made.output + made.error)
        let said = made.error
        // what it can tell it says, naming the file
        expect(said.contains("services/shop/serverless.yml: functions is not a mapping here"), said)
        expect(said.contains("apps/legacy/serverless.yml is not a mapping at its top level"), said)
        expect(said.contains("services/shop/src/workflows/lost.ts mentions proxyActivities and none of its workflows runs an activity"), said)
        expect(said.contains("@shop/legacy (apps/legacy/src) has a workflows/ or activities/ folder but is not under services/"), said)
        expect(!said.contains("which no migration makes"), "words that are no tables are not tables: \(said)")
        expect(!said.contains("payWorkflow") && !said.contains("ns.ts"), "the namespace forms are read: \(said)")
        let digest = try json(digestFile)
        let nodes = digest["nodes"]?.arrayValue ?? [], edges = digest["edges"]?.arrayValue ?? []
        func targets(_ relation: String, from: String) -> [String] {
            edges.filter { $0["is"] == .string(relation) && $0["from"] == .string(from) }.compactMap { $0["to"]?.stringValue }.sorted()
        }
        // the namespace forms give runs, with their steps; the SQL words give the reads they should, and no write
        expectEqual(targets("runs", from: "payWorkflow"), ["audit", "pay"])
        expectEqual(targets("runs", from: "nsWorkflow"), ["pay"])
        expectEqual(edges.first { $0["is"] == "runs" && $0["to"] == "pay" }?["fieldValues"]?["step"]?.numberValue, 1)
        expectEqual(targets("runs", from: "lostWorkflow"), [])
        expectEqual(targets("reads", from: "pay"), ["orders", "payments"])
        expectEqual(targets("writes", from: "pay"), [])
        // a multi-line JSDoc gives its first sentence
        expectEqual(nodes.first { $0["title"] == "payWorkflow" }?["text"], "Pays an order through the provider.")
        expectEqual(nodes.first { $0["title"] == "pay" }?["text"], "Takes the money.")
        // an exported helper in activities/ that no workflow runs is a note nothing runs: :incomplete in the drawing
        expect(nodes.contains { $0["title"] == "helper" && $0["is"] == "Activity" } && !edges.contains { $0["is"] == "runs" && $0["to"] == "helper" })
        // no Lambda was drawn from a config the reader took for a string
        expectEqual(nodes.filter { $0["is"] == "Lambda" }.count, 0)
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
        let digest = try json(runFolder.appendingPathComponent("digest.json"))
        expectEqual(try expectDrawnByDesign(runFolder), [], "a File has no row that is needed, so the drawing says nothing")

        // every file the scan has is a note of the one type, File, its path and length its values, and the length said once
        let nodes = digest["nodes"]?.arrayValue ?? []
        let scanned = try json(example("scan.json", in: "bookshelf"))["files"]?.arrayValue ?? []
        let lines = Dictionary(uniqueKeysWithValues: scanned.compactMap { f in f["path"]?.stringValue.map { ($0, f["lines"]?.numberValue ?? -1) } })
        let files = nodes.filter { $0["is"] == "File" }
        expectEqual(files.count, 20)
        expectEqual(Set(files.compactMap { $0["source"]?.stringValue }), Set(lines.keys), "a File for each file of the scan")
        for file in files {
            let path = file["source"]?.stringValue ?? "?"
            expectEqual(file["fieldValues"]?["path"]?.stringValue, path)
            expectEqual(file["fieldValues"]?["lines"]?.numberValue, lines[path], "\(path)'s length")
            expect(!(file["text"]?.stringValue ?? "").hasSuffix(" lines"), "\(path)'s note says its length as a value alone: \(file["text"] ?? .null)")
        }
        expectEqual(nodes.filter { $0["schema"] != nil }.compactMap { $0["title"]?.stringValue }, ["File"])

        @MainActor func ask(_ query: String) throws -> (titles: [String], count: Int) {
            let answer = try canvas(server, ["query", "--board", "\(board.number)", "--brief", "--limit", "10000", query])
            expectEqual(answer.status, 0, "\(query): \(answer.error)")
            let result = try JSON(text: answer.output)
            return ((result["rows"]?.arrayValue ?? []).compactMap { $0["title"]?.stringValue }, Int(result["count"]?.numberValue ?? -1))
        }
        expectEqual(try ask(#":is-a("File")"#).titles.sorted(), files.compactMap { $0["title"]?.stringValue }.sorted(), "the File notes, as the digest says them")
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
    test("the orders lens gives each thing the name its container knows it by: two services with a workflow and an activity of one name are drawn, told apart by id, and asked for by where they are") {
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
        expect(drawn.output.contains("verify ok"), drawn.output)
        expect(!drawn.error.contains("lens: "), "no name is reworded for another service's: \(drawn.error)")
        let where_ = try run(ingest, [repo.path, "--where"], environment: environment)
        let kept = URL(fileURLWithPath: where_.output.trimmingCharacters(in: .whitespacesAndNewlines))
        let runFolder = kept.appendingPathComponent("runs/\(try require(try FileManager.default.contentsOfDirectory(atPath: kept.appendingPathComponent("runs").path).sorted().last))")
        let digest = try json(runFolder.appendingPathComponent("digest.json"))
        let nodes = digest["nodes"]?.arrayValue ?? [], edges = digest["edges"]?.arrayValue ?? []
        // each service's board has the frames and notes every service's has, under the same names; each gets an id, where its title repeats
        func ids(_ title: String) -> [String] { nodes.filter { $0["title"] == .string(title) }.compactMap { $0["id"]?.stringValue }.sorted() }
        expectEqual(ids("syncWorkflow"), ["syncWorkflow  in Services > @shop/billing > Workflows", "syncWorkflow  in Services > @shop/orders > Workflows"])
        expectEqual(ids("notify"), ["notify  in Services > @shop/billing > Activities", "notify  in Services > @shop/orders > Activities"])
        expectEqual(ids("Workflows"), ["Workflows  in Services > @shop/billing", "Workflows  in Services > @shop/orders"])
        expectEqual(ids("Activities"), ["Activities  in Services > @shop/billing", "Activities  in Services > @shop/orders"])
        expectEqual(ids("sync.ts"), ["sync.ts  in Services > @shop/billing > Files", "sync.ts  in Services > @shop/orders > Files"])
        expectEqual(ids("Files"), ["Files  in Services > @shop/billing", "Files  in Services > @shop/orders"])
        expect(nodes.filter { $0["id"] != nil }.count == 14 && ids("outbox").isEmpty && ids("Types").isEmpty,
               "an id where a title repeats, and nowhere else: two workflows, two activities, four files, and the two frames of each")
        // a workflow is declared in its own service's file
        expectEqual(edges.filter { $0["is"] == "declared in" && $0["from"] == "syncWorkflow  in Services > @shop/orders > Workflows" }.compactMap { $0["to"]?.stringValue },
                    ["sync.ts  in Services > @shop/orders > Files"])
        // a typed arrow runs between the notes it names by id
        let runs = edges.filter { $0["is"] == "runs" }
        expectEqual(runs.compactMap { "\($0["from"]?.stringValue ?? "?") > \($0["to"]?.stringValue ?? "?")" }.sorted(),
                    ["syncWorkflow  in Services > @shop/billing > Workflows > notify  in Services > @shop/billing > Activities",
                     "syncWorkflow  in Services > @shop/orders > Workflows > notify  in Services > @shop/orders > Activities"])
        let checked = try run(URL(fileURLWithPath: jsc), [URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".claude/skills/canvas-digest/tool/main.js").path, "--", "check", runFolder.appendingPathComponent("digest.json").path], timeout: 120)
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
