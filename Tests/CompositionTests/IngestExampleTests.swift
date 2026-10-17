import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasUI
import Foundation
import Mentions
import ShippedTesting
import StickyNotes
import TestKit
import Titles

// canvas-ingest's worked example (.claude/skills/canvas-ingest/examples/orders): a small TypeScript monorepo with its own
// settings and lens, copied into a scratch git repository, committed, and drawn by `ingest` from its checked-in scan (`--scan`,
// so its scip command, which would reach the network, never runs), with `canvas` as built against this test's own command
// server, and a cache of its own. Then `canvas query` is asked what the README says it answers.

/// The example's folder, absolute (tests run from the repository's root).
private func example(_ path: String = "") -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".claude/skills/canvas-ingest/examples/orders").appendingPathComponent(path)
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

/// The example as a repository: its files (but the scan, which a scanner makes and a repository doesn't keep) copied into
/// `folder/shop` and committed. Returns the repository and the commit.
@MainActor private func exampleRepository(in folder: URL) throws -> (repo: URL, sha: String) {
    let repo = folder.appendingPathComponent("shop")
    try FileManager.default.copyItem(at: example(), to: repo)
    try FileManager.default.removeItem(at: repo.appendingPathComponent("scan.json"))
    try git(repo, ["init", "-q"])
    try git(repo, ["add", "-A"])
    try git(repo, ["commit", "-q", "-m", "the orders example"])
    let sha = try git(repo, ["rev-parse", "HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
    return (repo, sha)
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

@MainActor private func readmeQueries() throws -> [ReadmeQuery] {
    let text = try String(contentsOf: example("README.md"), encoding: .utf8)
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

@MainActor let ingestExampleTests = Suite("canvas-ingest's worked example: a TypeScript monorepo drawn by its own lens, and asked what it holds", [
    test("the orders example is drawn from its scan by its lens, checks and verifies with only the warnings its types give by design, ends its header with what drew it, and canvas query answers its questions as drawn") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board, build: "test-build-7")
        defer { server.stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("IngestExampleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (repo, sha) = try exampleRepository(in: folder)
        let environment = ["CANVAS_CLI": builtExecutable("CanvasCLI").path, "CANVAS_SOCKET": server.path,
                           "CANVAS_INGEST_CACHE": folder.appendingPathComponent("cache").path,
                           "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        let ingest = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".claude/skills/canvas-ingest/ingest")

        // drawn from the scan checked in beside it, never its scip command
        let drawn = try run(ingest, [repo.path, "--scan", example("scan.json").path], environment: environment, timeout: 280)
        expectEqual(drawn.status, 0, drawn.output + drawn.error)
        expect(drawn.output.contains("drawing from the scan given by hand") && !drawn.output.contains("making the SCIP index"), drawn.output)
        expect(drawn.output.contains("verify ok"), drawn.output)
        expect(!drawn.error.contains("lens: "), "the lens warns of nothing in its own example: \(drawn.error)")
        let where_ = try run(ingest, [repo.path, "--where"], environment: environment)
        let kept = URL(fileURLWithPath: where_.output.trimmingCharacters(in: .whitespacesAndNewlines))
        let runs = try FileManager.default.contentsOfDirectory(atPath: kept.appendingPathComponent("runs").path).sorted()
        let runFolder = kept.appendingPathComponent("runs/\(try require(runs.last, "a run was kept"))")
        let digest = try json(runFolder.appendingPathComponent("digest.json"))

        // the digest checks: nothing wrong, and no frame or board over what reads well
        let checked = try run(URL(fileURLWithPath: jsc), [URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".claude/skills/canvas-digest/tool/main.js").path, "--", "check", runFolder.appendingPathComponent("digest.json").path], timeout: 120)
        expectEqual(checked.status, 0, checked.output + checked.error)
        let verdict = try JSON(text: checked.output)
        expectEqual(verdict["errors"], .array([]), checked.output)
        expectEqual(verdict["warnings"], .array([]), checked.output)

        // the drawing's warnings are only those its types give by design: an activity's Needed "run by" row, empty while its notes are
        // drawn and before the arrows that fill it are (in the end only one is left empty: the query for :incomplete, below)
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
        expect(said.contains("sendReceipt: run by is needed"), "what the drawing says of its types: \(said)")

        // the root's header ends with what drew it: this commit, the lens, the app's build
        let editor = board.editor
        let header = editor.document.shapes.first { editor.registry.title(of: $0) == "About shop" }?.typed(as: StickyNote.self)?.props.text.stored ?? ""
        let last = try require(header.split(separator: "\n").last.map(String.init), "the header: \(header)")
        let lensHash = try git(repo, ["hash-object", ".canvas/lens.py"]).output.prefix(12)
        expect(last.hasPrefix("Drawn from commit \(sha.prefix(12)) (") && last.contains(" with lens \(lensHash), app build test-build-7, macOS "), last)
        expect(header.hasPrefix("shop: 2 services, 2 workflows, 8 activities, 2 Lambdas and 4 tables."), header)

        @MainActor func ask(_ query: String) throws -> (titles: [String], count: Int) {
            let answer = try canvas(server, ["query", "--board", "\(board.number)", "--brief", "--limit", "10000", query])
            expectEqual(answer.status, 0, "\(query): \(answer.error)")
            let result = try JSON(text: answer.output)
            return ((result["rows"]?.arrayValue ?? []).compactMap { $0["title"]?.stringValue }, Int(result["count"]?.numberValue ?? -1))
        }

        // the notes of each type, and the arrows of each relationship type, as the digest says them
        let nodes = digest["nodes"]?.arrayValue ?? [], edges = digest["edges"]?.arrayValue ?? []
        for type in ["Workflow", "Activity", "Lambda", "Table"] {
            let typed = nodes.filter { $0["is"] == .string(type) }.compactMap { $0["title"]?.stringValue }
            expectEqual(try ask(#":is-a("\#(type)")"#).titles.sorted(), typed.sorted(), "the notes of \(type)")
        }
        expectEqual(try ask("sticky-note[relationship]").titles.sorted(), ["reads", "runs", "writes"])
        for relation in ["runs", "reads", "writes"] {
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
        expectEqual(try ask(":incomplete").titles, ["sendReceipt"], "the activity no workflow runs")
        expectEqual(try ask("arrow:misfit").count, 0)

        // and the README's questions answer as it says
        let questions = try readmeQueries()
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
