import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasUI
import Foundation
import Mentions
import ShippedTesting
import SkillTesting
import TestKit
import Titles

// The canvas-ingest skill (.claude/skills/canvas-ingest): a repository drawn as boards by `ingest`, run as an agent runs it, with
// `canvas` as built (CANVAS_CLI) against this test's own command server (CANVAS_SOCKET). The tests that start no app (what `ingest`
// passes a driver of its own that logs its arguments and draws nothing, what it refuses, the lens runner, the scanners, the readers)
// are SkillToolsTests'. Every test gives `ingest` a cache of its own (CANVAS_INGEST_CACHE) in a scratch folder, and the repositories
// it ingests are scratch git repositories there, never this one.

/// The environment `ingest` runs in: its own cache, and the app's command server when there is one (else a socket nothing answers).
@MainActor private func environment(cache: URL, server: CommandServer? = nil, extra: [String: String] = [:]) -> [String: String] {
    ingestEnvironment(cache: cache, socket: server?.path, extra: extra)
}

/// The plan and the run scripts of a run, by file: what the boards are made from.
@MainActor private func drawing(_ run: URL) throws -> [String: String] {
    let out = run.appendingPathComponent("out")
    var files = ["plan.json": try String(contentsOf: out.appendingPathComponent("plan.json"), encoding: .utf8)]
    for name in try FileManager.default.contentsOfDirectory(atPath: out.appendingPathComponent("runs").path) where name.hasSuffix(".draw") {
        files["runs/\(name)"] = try String(contentsOf: out.appendingPathComponent("runs/\(name)"), encoding: .utf8)
    }
    expect(files.count > 1, "the scripts: \(files.keys.sorted())")
    return files
}

@MainActor let ingestFrontBoardTests = Suite("canvas-ingest: a scan drawn as the board in front with a lens of overrides, then again in its place", [
    test("ingest draws a codebase from its scan in one command, a lens.py of overrides for the default lens, and a rerun draws it again in place") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("ingest")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("cache")
        let repo = try makeRepository("project", in: folder)
        let kept = try cacheFolder(of: repo, cache: cache)
        try putScan(tinyModel, in: kept)
        // a lens that calls the default lens with overrides: this one puts App's files in a frame but leaves out Main.swift, and names a module the code lacks
        try write(tinyLens, to: repo.appendingPathComponent(".canvas/lens.py"))
        let env = environment(cache: cache, server: server)
        @MainActor func runIngest(_ arguments: [String] = []) throws -> ProcessOutput {
            try ingest([repo.path, "--scan", handScan(kept)] + arguments, environment: env)
        }

        let first = try runIngest()
        expectEqual(first.status, 0, first.output + first.error)
        expect(first.output.contains("verify ok"), first.output)
        expect(first.error.contains("leave out Main.swift") && first.error.contains("Ghost"), "what the lens leaves out or lacks is said: \(first.error)")
        let editor = board.editor
        let titles = Set(editor.document.shapes.compactMap { editor.registry.title(of: $0) })
        expect(titles.isSuperset(of: ["Apps", "Foundations", "App", "Core"]), "the root: the bands, the modules: \(titles.sorted())")
        expect(!titles.contains { $0.hasPrefix("About ") }, "and no note of what the whole is: \(titles.sorted())")
        let apps = try json(lastRun(in: kept).appendingPathComponent("digest.json"))
        expectEqual(apps["title"], "TinyPackage")
        let nodes = apps["nodes"]?.arrayValue ?? []
        expectEqual(nodes.first { $0["title"] == "Main.swift" }?["in"], "App/", "a file the lens leaves out is in a frame of its own, never dropped")
        expectEqual(nodes.first { $0["title"] == "Screen.swift" }?["source"], "Sources/App/Screen.swift", "a file's note says what it was made from")
        expectEqual(nodes.first { $0["title"] == "App" }?["source"], "Sources/App", "and a module's card")
        expect(apps["warnings"] == nil, "the lens's warnings are said, never kept in the digest")
        expectEqual(nodes.first { $0["title"] == "Apps" }?["rank"], 0)
        expectEqual(nodes.first { $0["title"] == "Foundations" }?["rank"], 1)
        let drawn = editor.file.shapeCount

        let second = try runIngest()
        expectEqual(second.status, 0, second.output + second.error)
        expect(second.output.contains("ready: board") && second.output.contains("replaces"), "it says up front that it replaces: \(second.output)")
        expect(second.output.contains("replace: took back the last drawing") && second.output.contains("verify ok"), second.output)
        expectEqual(editor.file.shapeCount, drawn, "drawn again in its place, once")

        // --ranks says which way the root's bands run, through the driver to the plan: rows, then columns, each drawn in the last one's place
        for way in ["rows", "columns"] {
            let ranked = try runIngest(["--ranks", way])
            expectEqual(ranked.status, 0, ranked.output + ranked.error)
            let report = try json(lastRun(in: kept).appendingPathComponent("out/report.json"))
            let root = report["boards"]?["root"]?["algorithms"]?.arrayValue?.first { $0["container"] == "root" }
            expectEqual(root?["how"], .string(way), "the root's bands as \(way)")
            @MainActor func box(_ title: String) -> CGRect? { editor.document.shapes.first { editor.registry.title(of: $0) == title }?.box }
            let apps = try require(box("Apps")), foundations = try require(box("Foundations"))
            expect(way == "rows" ? apps.maxY < foundations.minY : apps.maxX < foundations.minX, "\(way): Apps \(apps), Foundations \(foundations)")
        }
        let sideways = try runIngest(["--ranks", "sideways"])
        expectEqual(sideways.status, 1, sideways.output)
        expect(sideways.error.contains("--ranks is rows or columns"), sideways.error)

        // what would stop a draw is said before anything slow, and before a digest is made: a board that holds another drawing
        // (another repository's ingestion has no record of this one), and a file that is there already
        let other = try makeRepository("other", in: folder)
        let otherKept = try cacheFolder(of: other, cache: cache)
        try putScan(tinyModel, in: otherKept)
        let refused = try ingest([other.path, "--scan", handScan(otherKept)], environment: env)
        expectEqual(refused.status, 1, refused.output)
        expect(refused.error.contains("isn't empty"), refused.error)
        expect(refused.error.contains("ingest --new-file PATH"), "and what to do about it, in ingest's own options: \(refused.error)")
        expect(runFolders(in: otherKept).isEmpty, "refused before the digest was made")
        expectEqual(editor.file.shapeCount, drawn, "nothing drawn or taken back")
        let there = folder.appendingPathComponent("there.canvasboard")
        try "x".write(to: there, atomically: true, encoding: .utf8)
        let taken = try ingest([other.path, "--scan", handScan(otherKept), "--new-file", there.path], environment: env)
        expectEqual(taken.status, 1, taken.output)
        expect(taken.error.contains("there is a file at"), taken.error)
        let down = try ingest([other.path, "--scan", handScan(otherKept)], environment: environment(cache: cache))
        expectEqual(down.status, 1, down.output)
        expect(down.error.contains("isn't running"), "an app that isn't running is said, with how to start it: \(down.error)")
    },
])

@MainActor let ingestNamesTests = Suite("canvas-ingest: names that clash, repeat or are a band's, drawn and found by where they are", [
    test("ingest draws a codebase whose names clash, run long or hold brackets: each title is given out once in its container, said, and nothing stops the run") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("names")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("cache")
        let repo = try makeRepository("project", in: folder)
        let kept = try cacheFolder(of: repo, cache: cache)
        let long = "@my-company/" + String(repeating: "very-long-package-name-", count: 4) + "x"
        try putScan(awkwardModel(long: long, big: false), in: kept)
        let drawn = try ingest([repo.path, "--scan", handScan(kept)], environment: environment(cache: cache, server: server))
        expectEqual(drawn.status, 0, drawn.output + drawn.error)
        expect(drawn.output.contains("verify ok"), drawn.output)
        let editor = board.editor
        let titles = Set(editor.document.shapes.compactMap { editor.registry.title(of: $0) })
        // a module called what a band is keeps its name and the band gives way (a card's title is the digest's alone: its folders' cards'
        // descriptions mention it by that title, which would name a band called so as well); a name over a title's longest keeps its end
        expect(titles.isSuperset(of: ["[locale]", "Level 1", "Level 1 (layer)", #"back\slash"#]), "\(titles.sorted())")
        expect(titles.contains { $0.hasPrefix("…") && $0.hasSuffix("very-long-package-name-x") && $0.utf16.count == 80 }, "a card's title is as long as any: \(titles.sorted())")
        expect(!titles.contains(long), "the long name itself is nobody's title")
        for said in ["the band Level 1 is titled \"Level 1 (layer)\"", "the module \(long) is titled \"…", "is over 80 characters", "the frame c on C is titled \"c (C)\""] {
            expect(drawn.error.contains(said), "said: \(said) in \(drawn.error)")
        }
        // a file is titled by its name, wherever it is: three files called main.swift (in C's own frame, in a frame of a frame, in another)
        // and two called index.ts (in two modules) are five notes of two titles, each with an id that says where it is, which names it
        // in the arrows and the frames that hold it
        let awkwardDigest = try lastRun(in: kept).appendingPathComponent("digest.json")
        let digest = try json(awkwardDigest)
        let nodes = digest["nodes"]?.arrayValue ?? []
        func ids(_ title: String) -> [String] { nodes.filter { $0["title"] == .string(title) }.compactMap { $0["id"]?.stringValue }.sorted() }
        expectEqual(ids("main.swift"), ["main.swift  in Level 1 (layer) > C > C/", "main.swift  in Level 1 (layer) > C > a > c (C)", "main.swift  in Level 1 (layer) > C > b"],
                    "three files of one name: \(nodes.compactMap { $0["title"]?.stringValue })")
        expectEqual(ids("index.ts").map { String($0.prefix(35)) }, ["index.ts  in Level 1 (layer) > …age", "index.ts  in Level 2 > app"], "two, in two modules")
        expectEqual(nodes.filter { $0["in"] == "C/" }.compactMap { $0["title"]?.stringValue }.sorted(), ["half\u{FFFD}.swift", "main.swift"],
                    "a name that isn't whole text is drawn with U+FFFD where it breaks, and the one note of a title has no id")
        expect(nodes.first { $0["title"] == "half\u{FFFD}.swift" }?["id"] == nil, "a title only one note has is its name")
        expect(nodes.contains { $0["title"] == "main.swift" && $0["in"] == "c (C)" } && nodes.contains { $0["title"] == "main.swift" && $0["in"] == "b" },
               "the frames that hold them are named by title, which no other node has")
        let edges = digest["edges"]?.arrayValue ?? []
        expect(edges.contains { $0["from"] == "index.ts  in Level 2 > app" && $0["to"] == "main.swift  in Level 1 (layer) > C > a > c (C)" },
               "app's index.ts uses the main.swift two frames down in C, an arrow named by ids: \(edges)")
        let naming = try namingReport(awkwardDigest)
        expectEqual(naming.problems, [], "every title is its container's alone, and an id is where a title repeats")
        // the app has them as the digest says: the notes called main.swift are three, each inside the frames it is in, as a query says it
        let found = try canvas(server, ["query", "--board", "\(board.number)", "--limit", "100", #"sticky-note"main.swift""#])
        expectEqual(found.status, 0, found.error)
        let rows = try JSON(text: found.output)["rows"]?.arrayValue ?? []
        expectEqual(rows.map { ($0["inside"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: " > ") }.sorted(),
                    ["Level 1 (layer) > C > C/", "Level 1 (layer) > C > a > c (C)", "Level 1 (layer) > C > b"], "main.swift, three times, by where each is: \(found.output)")
        // a description mentions a card by its title (a folder's, its module and the folders it uses): a ] and a \\ in one are written so the
        // mention names its shape. app's description mentions nothing: what it imports are its arrows
        let mentioned = try run(URL(fileURLWithPath: python), ["-s", "-B", "-c", "import sys; sys.path.insert(0, sys.argv[1]); from lenskit.text import mention; print(mention('[locale]'), mention(sys.argv[2]))",
                                                                ingestSkill().path, #"back\slash"#], timeout: 60)
        expectEqual(mentioned.output, #"@[[locale\]] @[back\\slash]"# + "\n", mentioned.error)
        let app = nodes.first { $0["title"] == "app" }?["text"]?.stringValue ?? ""
        expect(app.hasSuffix(#"About \@[nothing] here."# + "\n\n1 files, 10 lines"), "its purpose (a @[ in it written as text) and its size: \(app)")
        expect(digest["text"] == nil, "and the digest has no text of its own: no board has a note of what it is")

        // a module big enough for its folders to have boards, two of them the same but for their case: the digest passes check
        let big = folder.appendingPathComponent("big")
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        try awkwardModel(long: long, big: true).write(to: big.appendingPathComponent("scan.json"), atomically: true, encoding: .utf8)
        let bigRepo = try makeRepository("bigrepo", in: folder)
        let made = try lensRunner(bigRepo, scan: big.appendingPathComponent("scan.json"), digest: big.appendingPathComponent("digest.json"))
        expectEqual(made.status, 0, made.output + made.error)
        expect(made.error.contains("the folder Big/utils is titled \"Big/utils (2)\""), made.error)
        expect(made.error.contains("Big/x: a module has that name, so the folder gets no board of its own"), made.error)
        let bigNodes = try json(big.appendingPathComponent("digest.json"))["nodes"]?.arrayValue ?? []
        expectEqual(bigNodes.filter { $0["title"] == "Big/x" }.count, 1, "the module Big/x is one card, and Big's folder x is not another")
        expectEqual(bigNodes.first { $0["title"] == "its.ts" }?["in"], "Big/x", "the module's file is on its board")
        expectEqual(bigNodes.filter { $0["title"] == "one.ts" }.compactMap { $0["in"]?.stringValue }.sorted(), ["Level 1", "x"],
                    "the folder's files stay on Big's, in its frame x, and the module Level 1 has a one.ts of its own")
        // paths that differ only by case are one container's clash: two files, and two folders, that a case-insensitive title can't tell apart
        let cases = folder.appendingPathComponent("cases")
        try FileManager.default.createDirectory(at: cases, withIntermediateDirectories: true)
        try caseModel.write(to: cases.appendingPathComponent("scan.json"), atomically: true, encoding: .utf8)
        let caseMade = try lensRunner(bigRepo, scan: cases.appendingPathComponent("scan.json"), digest: cases.appendingPathComponent("digest.json"))
        expectEqual(caseMade.status, 0, caseMade.output + caseMade.error)
        expect(caseMade.error.contains("Cases/readme.md is titled \"Cases/readme.md\": \"readme.md\" is another shape's title in \"Cases/\" too"), caseMade.error)
        expect(caseMade.error.contains("the frame util on Cases is titled \"util (Cases)\": \"util\" is another shape's title in \"Cases\" too"), caseMade.error)
        let caseNodes = try json(cases.appendingPathComponent("digest.json"))["nodes"]?.arrayValue ?? []
        expectEqual(caseNodes.compactMap { $0["title"]?.stringValue }.filter { $0.lowercased().contains("readme") || $0.lowercased().hasPrefix("util") }.sorted(),
                    ["Cases/readme.md", "README.md", "Util", "util (Cases)"], "each pair of names is told apart in its container")
        expectEqual(caseNodes.compactMap { $0["title"]?.stringValue }.filter { $0 == "a.ts" || $0 == "b.ts" }.sorted(), ["a.ts", "b.ts"], "and the files in the folders keep their names")
        for (digestFile, label) in [(big.appendingPathComponent("digest.json"), "big"), (cases.appendingPathComponent("digest.json"), "cases"), (awkwardDigest, "awkward")] {
            let checked = try run(URL(fileURLWithPath: "/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc"),
                                  [URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".claude/skills/canvas-digest/tool/main.js").path, "--", "check", digestFile.path],
                                  timeout: 120)
            expectEqual(checked.status, 0, checked.output + checked.error)
            expectEqual(try JSON(text: checked.output)["errors"], .array([]), "\(label): check finds nothing wrong: \(checked.output)")
        }
    },
    test("the default lens draws a codebase whose folders repeat names: each board keeps the names of its folders and files, the digest tells them apart by id, and the app has each by where it is") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("repeats")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("cache")
        let repo = try makeRepository("project", in: folder)
        let kept = try cacheFolder(of: repo, cache: cache)
        try putScan(repeatsModel, in: kept)
        let env = environment(cache: cache, server: server)
        let drawn = try ingest([repo.path, "--scan", handScan(kept)], environment: env)
        expectEqual(drawn.status, 0, drawn.output + drawn.error)
        expect(drawn.output.contains("verify ok"), drawn.output)
        expect(!drawn.error.contains(" is titled "), "no title is reworded for a name another board has: \(drawn.error)")
        // web, api and core each have a folder src, and every one of them a file index.ts and a util.ts (web has a second util.ts, in test)
        let digest = try json(lastRun(in: kept).appendingPathComponent("digest.json"))
        let nodes = digest["nodes"]?.arrayValue ?? []
        func titled(_ title: String) -> [JSON] { nodes.filter { $0["title"] == .string(title) } }
        expectEqual([titled("src").count, titled("index.ts").count, titled("util.ts").count, titled("Page.ts").count, titled("test").count], [3, 3, 4, 2, 1])
        expect(titled("src").allSatisfy { $0["id"] != nil } && titled("util.ts").allSatisfy { $0["id"] != nil } && titled("test").allSatisfy { $0["id"] == nil },
               "an id wherever a title repeats, and nowhere else")
        expect(nodes.filter { $0["id"] != nil }.count == 12 && titled("web").first?["id"] == nil, "twelve ids: three folders, three index.ts, four util.ts, two Page.ts")
        let naming = try namingReport(lastRun(in: kept).appendingPathComponent("digest.json"))
        expectEqual(naming.problems, [])
        // in the app, a title names every shape that has it, each inside the boards and frames it is in
        @MainActor func inside(_ query: String) throws -> [String] {
            let found = try canvas(server, ["query", "--board", "\(board.number)", "--limit", "100", query])
            expectEqual(found.status, 0, "\(query): \(found.error)")
            return try (JSON(text: found.output)["rows"]?.arrayValue ?? []).map { ($0["inside"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: " > ") }.sorted()
        }
        expectEqual(try inside(#"sticky-note"util.ts""#), ["Level 1 > core > src", "Level 2 > api > src", "Level 2 > web > src", "Level 2 > web > test"])
        expectEqual(try inside(#"frame"src""#), ["Level 1 > core", "Level 2 > api", "Level 2 > web"])
        // and a path asks for one of them: the util.ts in web's src, which three arrows end at (from web's index.ts, its Page.ts and its test's util.ts)
        let users = try canvas(server, ["query", "--board", "\(board.number)", "--brief", "--limit", "100", #":start-of(arrow:ends-at("web" > "src" > "util.ts"))"#])
        expectEqual(users.status, 0, users.error)
        expectEqual(try (JSON(text: users.output)["rows"]?.arrayValue ?? []).compactMap { $0["title"]?.stringValue }.sorted(), ["Page.ts", "index.ts", "util.ts"], users.output)
        // drawn again, it takes its own drawing back and draws it in the same place
        let shapes = board.editor.file.shapeCount
        let again = try ingest([repo.path, "--scan", handScan(kept)], environment: env)
        expectEqual(again.status, 0, again.output + again.error)
        expect(again.output.contains("replace: took back the last drawing") && again.output.contains("verify ok"), again.output)
        expectEqual(board.editor.file.shapeCount, shapes, "drawn again in its place, once")
    },
    test("a module called what its band is, with folder boards that mention it, is drawn: the band gives way to the card, whose title a mention names alone") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("same-name")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("cache")
        let repo = try makeRepository("project", in: folder)
        let kept = try cacheFolder(of: repo, cache: cache)
        // Top imports Level 1, so Level 1 is the band of the modules that import none; it has 60 files in two folders, so each folder has a
        // board whose card's description mentions its module (`@[Level 1]`), from the module's board
        func q(_ s: String) -> String { "\"" + s + "\"" }
        let rels = (0..<30).map { "a/f\($0).ts" } + (0..<30).map { "b/g\($0).ts" }
        let files = rels.map { #"{"module": "Level 1", "rel": \#(q($0)), "path": \#(q("src/L1/" + $0)), "lines": 10, "doc": "", "api": false, "decls": []}"# }
        try putScan(#"{"language": "typescript", "name": "Same", "modules": [{"name": "Top", "path": "src/Top", "deps": ["Level 1"], "test": false, "layer": null, "files": ["main.ts"], "lines": 10, "doc": "", "folders": {}}, {"name": "Level 1", "path": "src/L1", "deps": [], "test": false, "layer": null, "files": [\#(rels.map(q).joined(separator: ", "))], "lines": 600, "doc": "", "folders": {}}], "files": [{"module": "Top", "rel": "main.ts", "path": "src/Top/main.ts", "lines": 10, "doc": "", "api": false, "decls": []}, \#(files.joined(separator: ", "))], "uses": []}"#, in: kept)
        let drawn = try ingest([repo.path, "--scan", handScan(kept)], environment: environment(cache: cache, server: server))
        expectEqual(drawn.status, 0, drawn.output + drawn.error)
        expect(drawn.output.contains("verify ok") && drawn.output.contains("descriptions 4/4"), drawn.output)
        expect(drawn.error.contains("the band Level 1 is titled \"Level 1 (layer)\": \"Level 1\" is the module Level 1's title, which no other shape may have"), drawn.error)
        // had the band kept the name, draw would refuse the folders' descriptions: the root would have two shapes called Level 1, a frame
        // and a subboard, and "a text names a shape by its title alone"
        let mentioners = try canvas(server, ["query", "--board", "\(board.number)", "--brief", "--limit", "100", #"subboard:mentions(subboard"Level 1")"#])
        expectEqual(mentioners.status, 0, mentioners.error)
        expectEqual(try (JSON(text: mentioners.output)["rows"]?.arrayValue ?? []).compactMap { $0["title"]?.stringValue }.sorted(), ["Level 1/a", "Level 1/b"],
                    "the card is what the two folders mention, and not Top, whose import of it is an arrow: \(mentioners.output)")
    },
])

@MainActor let ingestSwiftIndexTests = Suite("canvas-ingest: Swift's index kept from run to run", [
    test("Swift's index is kept from run to run: a module is type-checked again only when its sources or the interfaces it reads changed, and its uses are read from a store a module") {
        let folder = try scratchFolder("index")
        defer { try? FileManager.default.removeItem(at: folder) }
        // the index where ingest keeps a repository's: <cache>/index
        let cache = folder.appendingPathComponent("cache")
        let repo = try makeRepository("repo", in: folder)
        let kept = try cacheFolder(of: repo, cache: cache)
        let scratch = kept.appendingPathComponent("index"), model = folder.appendingPathComponent("scan.json")
        func put(_ path: String, _ text: String) throws { try write(text, to: repo.appendingPathComponent(path)) }
        // Kit uses Core, KitTests uses Kit, and Loose uses nothing and nothing uses it
        let core = "public func core() -> Int {\n    let one = 1\n    return one\n}\n", kit = "import Core\n\npublic func kit() -> Int { core() + 1 }\n"
        try put("Package.swift", tinyPackage(loose: true))
        try put("Sources/Core/Core.swift", core)
        try put("Sources/Kit/Kit.swift", kit)
        try put("Sources/Loose/Loose.swift", "public func loose() {}\n")
        try put("Tests/KitTests/KitTests.swift", "import Kit\n\nfunc twice() -> Int { kit() * 2 }\n")
        let scanners = ingestSkill("scanners")
        // the SDK build.sh chose for this build, so the index build needn't ask the compiler about one it rejects (ten seconds)
        let sdk = (try? String(contentsOfFile: "build/.sdk", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        @MainActor func scanner(_ script: String, _ arguments: [String]) throws -> ProcessOutput {
            try run(URL(fileURLWithPath: python), [scanners.appendingPathComponent(script).path] + arguments,
                    environment: sdk.map { ["SDKROOT": $0] } ?? [:], timeout: 280)
        }
        /// What a build of the index says it made.
        @MainActor func build() throws -> String {
            let built = try scanner("swift_index_build.py", [repo.path, scratch.path])
            expectEqual(built.status, 0, built.output + built.error)
            return built.output
        }
        /// Which file uses which, as the scanners write the scan from the stores there are.
        @MainActor func uses(store: String = "store") throws -> Set<String> {
            let analyzed = try scanner("swift_analyze.py", [repo.path, model.path])
            expectEqual(analyzed.status, 0, analyzed.output + analyzed.error)
            let read = try scanner("swift_index_read.py", [scratch.appendingPathComponent(store).path, model.path])
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
        try put("Sources/Core/Core.swift", core.replacingOccurrences(of: "one = 1", with: "one = 2 - 1"))
        made = try build()
        expect(made.contains("interfaces: made 1 of 2 (Core)\n") && made.contains("indexes: made 1 of 4 (Core)\n"), made)

        // an edit to what it declares: the modules that depend on it too, directly or through another, and none that doesn't
        try put("Sources/Core/Core.swift", core + "\npublic func more() {}\n")
        made = try build()
        expect(made.contains("interfaces: made 2 of 2 (Core, Kit)\n") && made.contains("indexes: made 3 of 4 (Core, Kit, KitTests)\n"), made)

        // a compile that fails is said and changes nothing: the index kept is still whole, and still what its sources make once
        // they are back as they last compiled (the interface, which skips the body that was wrong, was made from each edit)
        try put("Sources/Kit/Kit.swift", kit.replacingOccurrences(of: "+ 1", with: "+ \"one\""))
        let failed = try scanner("swift_index_build.py", [repo.path, scratch.path])
        expect(failed.status != 0 && failed.output.contains("index Kit: failed") && failed.error.contains("indexes failed: Kit"), failed.output + failed.error)
        expectEqual(try uses(), both, "the last index that worked is what is read")
        try put("Sources/Kit/Kit.swift", kit)
        made = try build()
        expect(made.contains("interfaces: made 1 of 2 (Kit)\n") && made.contains("indexes: made 0 of 4\n"), made)
        expectEqual(try uses(), both)

        // an import Package.swift doesn't declare fails, as it does in a build: a compile reads only the interfaces its mark
        // covers, so no index is kept that an edit to an undeclared module would leave stale
        try put("Sources/Loose/Loose.swift", "import Core\n\npublic func loose() -> Int { core() }\n")
        let undeclared = try scanner("swift_index_build.py", [repo.path, scratch.path])
        expect(undeclared.status != 0 && undeclared.output.contains("index Loose: failed") && undeclared.output.contains("no such module 'Core'"), undeclared.output + undeclared.error)

        // a module that is gone leaves nothing behind: its store would be read as code that is there
        try put("Package.swift", tinyPackage(loose: false))
        try FileManager.default.removeItem(at: repo.appendingPathComponent("Sources/Loose"))
        made = try build()
        expect(made.contains("interfaces: made 0 of 2\n") && made.contains("indexes: made 0 of 3\n"), made)
        let stores = try FileManager.default.contentsOfDirectory(atPath: scratch.appendingPathComponent("store").path).sorted()
        expectEqual(stores, ["Core", "Kit", "KitTests"])
        expectEqual(try uses(), both)

        // and ingest, reading the commit for itself, in a checkout of its own in the cache: its settings say only what to run first, so
        // the Package.swift makes the scanner Swift's. The checkout's path is not the repository's, so the index the steps above made
        // (their marks hold the sources' paths) doesn't cover it and every module is type-checked once; then none is
        try git(repo, ["add", "-A"])
        try git(repo, ["commit", "-q", "-m", "the package"])
        try put(".canvas/ingest.json", #"{"prepare": "echo prepared > prepared.txt"}"#)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let env = environment(cache: cache, server: server, extra: sdk.map { ["SDKROOT": $0] } ?? [:])
        let drawn = try ingest([repo.path], environment: env)
        expectEqual(drawn.status, 0, drawn.output + drawn.error)
        expect(drawn.output.contains("ingest: type-checked 3 of 3 modules") && drawn.output.contains("verify ok"), drawn.output)
        expect(FileManager.default.fileExists(atPath: kept.appendingPathComponent("checkout/prepared.txt").path), "the prepare command ran at the checkout's root")
        expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent("prepared.txt").path), "and not in the repository")
        let titles = Set(board.editor.document.shapes.compactMap { board.editor.registry.title(of: $0) })
        expect(titles.isSuperset(of: ["Core", "Kit"]), "the package as the board in front: \(titles.sorted())")
        let edges = try json(lastRun(in: kept).appendingPathComponent("digest.json"))["edges"]?.arrayValue ?? []
        expect(edges.contains { $0["from"] == "Kit.swift" && $0["to"] == "Core.swift" }, "Kit.swift's use of Core.swift is an edge of the digest: \(edges)")
        let scans = try FileManager.default.contentsOfDirectory(atPath: kept.appendingPathComponent("scans").path)
        expectEqual(scans.count, 1, "the scan is in the cache, by commit: \(scans)")
        let again = try ingest([repo.path, "--rescan"], environment: env)
        expectEqual(again.status, 0, again.output + again.error)
        expect(again.output.contains("ingest: no module changed: none of the 3 type-checked"), "the index is as the code is: \(again.output)")
        expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent(".index").path) && !FileManager.default.fileExists(atPath: repo.appendingPathComponent("model.json").path), "and nothing of ingest's is in the repository")
    },
])

@MainActor let ingestRegroupTests = Suite("canvas-ingest: a lens that regroups the files, and a scan given by hand drawn the same whatever the lens's state", [
    test("a repository's lens regroups its files as it likes, and is drawn; the digest it makes is the repository's own picture") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("regroup")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("cache")
        let repo = try makeRepository("project", in: folder)
        let kept = try cacheFolder(of: repo, cache: cache)
        try putScan(tinyModel, in: kept)
        // by a naming convention: the files that end in Screen, Store or Model are views and data, wherever they are, in frames of
        // their module's board; each note says what its file was made from
        try write("""
            from lenskit import Digest, text

            GROUPS = [("Screen", "Views"), ("Store", "Data"), ("Model", "Data")]

            def digest(scan, repo):
                d = Digest(scan.name + " by convention")
                cards, frames, titles = {}, {}, {}
                for m in scan.production:
                    cards[m] = d.claim("the module " + m, m)
                    d.subboard(cards[m], text=text.as_text(scan.module(m)["doc"]), source=scan.module(m)["path"])
                for (m, rel), f in sorted(scan.files.items()):
                    group = next((g for suffix, g in GROUPS if rel.endswith(suffix + ".swift")), "Entry points")
                    if (m, group) not in frames:
                        frames[(m, group)] = d.claim("the frame " + group, group + " (" + m + ")")
                        d.frame(frames[(m, group)], cards[m])
                    titles[(m, rel)] = d.claim(rel, rel)
                    d.note(titles[(m, rel)], frames[(m, group)], text.file_text(f, scan.language), source=f["path"])
                for a, b, names in scan.uses:
                    if a in scan.files and b in scan.files and a != b:
                        d.edge(titles[a], titles[b], weight=len(names))
                return d.finish()
            """, to: repo.appendingPathComponent(".canvas/lens.py"))
        let drawn = try ingest([repo.path, "--scan", handScan(kept)], environment: environment(cache: cache, server: server))
        expectEqual(drawn.status, 0, drawn.output + drawn.error)
        expect(drawn.output.contains("verify ok"), drawn.output)
        let editor = board.editor
        let titles = Set(editor.document.shapes.compactMap { editor.registry.title(of: $0) })
        expect(titles.isSuperset(of: ["App", "Core"]), "the boards the lens made: \(titles.sorted())")
        let digest = try json(lastRun(in: kept).appendingPathComponent("digest.json"))
        let nodes = digest["nodes"]?.arrayValue ?? []
        expectEqual(nodes.first { $0["title"] == "Screen.swift" }?["in"], "Views (App)")
        expectEqual(nodes.first { $0["title"] == "Main.swift" }?["in"], "Entry points (App)")
        expectEqual(Set(nodes.filter { $0["in"] == "Data (Core)" }.compactMap { $0["title"]?.stringValue }), ["Store.swift", "Model.swift"], "files by what they are called")
        expectEqual(nodes.first { $0["title"] == "Store.swift" }?["source"], "Sources/Core/Store.swift")
        expect(digest["warnings"] == nil, "warnings are said, never kept in the digest")
        // a rerun draws it in place of the last
        let again = try ingest([repo.path, "--scan", handScan(kept)], environment: environment(cache: cache, server: server))
        expectEqual(again.status, 0, again.output + again.error)
        expect(again.output.contains("replace: took back the last drawing") && again.output.contains("verify ok"), again.output)
    },
    test("a board from a scan given by hand: the same commit draws the same plan and scripts whether the lens is committed or not, or the working tree has edits") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("hand")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("cache")
        let repo = try makeRepository("project", in: folder, files: ["notes.txt": "one\n"])
        let sha = try git(repo, ["rev-parse", "HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let kept = try cacheFolder(of: repo, cache: cache)
        try putScan(tinyModel, in: kept)
        let env = environment(cache: cache, server: server)
        @MainActor func draw(_ more: [String] = []) throws -> (process: ProcessOutput, run: URL) {
            let done = try ingest([repo.path, "--commit", sha, "--scan", handScan(kept)] + more, environment: env)
            expectEqual(done.status, 0, done.output + done.error)
            return (done, try lastRun(in: kept))
        }

        let plain = try draw()
        expect(plain.process.output.contains("drawing from the scan given by hand"), plain.process.output)
        expect(!FileManager.default.fileExists(atPath: kept.appendingPathComponent("checkout").path), "a scan given by hand scans nothing, so there is no checkout")
        let plainFiles = try drawing(plain.run)

        // a lens that is not committed, and the same once committed (the commit drawn is the same), with the working tree edited
        let lens = "from lenskit import default\n\ndef digest(scan, repo):\n    return default.digest(scan, repo)\n"
        try write(lens, to: repo.appendingPathComponent(".canvas/lens.py"))
        let uncommitted = try draw()
        let uncommittedFiles = try drawing(uncommitted.run)
        expectEqual(uncommittedFiles, plainFiles, "a lens that calls the default lens draws what the default lens draws")
        try git(repo, ["add", ".canvas/lens.py"])
        try git(repo, ["commit", "-q", "-m", "the lens"])
        try write("two\n", to: repo.appendingPathComponent("notes.txt"))      // and the working tree has an edit
        let committedLens = try draw()
        expectEqual(try drawing(committedLens.run), uncommittedFiles, "committing the lens changes nothing: the same plan and the same scripts")
        expectEqual(try String(contentsOf: committedLens.run.appendingPathComponent("digest.json"), encoding: .utf8),
                    try String(contentsOf: uncommitted.run.appendingPathComponent("digest.json"), encoding: .utf8))

        // what the options do together
        let both = try ingest([repo.path, "--scan", handScan(kept), "--rescan"], environment: env)
        expectEqual(both.status, 1, both.output)
        expect(both.error.contains("--scan") && both.error.contains("--rescan"), both.error)
        let missing = try ingest([repo.path, "--scan", folder.appendingPathComponent("nothing.json").path], environment: env)
        expectEqual(missing.status, 1, missing.output)
        expect(missing.error.contains("there is no scan at"), missing.error)
        let old = try ingest([repo.path, "--skip-read"], environment: env)
        expectEqual(old.status, 2, "--skip-read is gone: \(old.output)")
    },
])

@MainActor let ingestRecordsTests = Suite("canvas-ingest: a drawing record for each file drawn in", [
    test("drawing records are kept for each file drawn in: a proposal drawn into a new file leaves the board in front's record alone, and each board is drawn again in place of its own last drawing") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let front = windowedBoard()
        defer { front.close() }
        let opened = Opened()
        defer { for board in opened.boards { board.close() } }
        let commands = try require(BoardDocument.configuration).registry.hostCommands
        // the board in front stays the first one: a new file opens beside it
        let server = CommandServer(path: temporarySocketPath(), commands: CommandServer.Commands(specs: commands.specs, run: commands.run),
                                   boards: { [front] + opened.boards }, frontmost: { front }, show: { opened.boards.append($0) })
        try server.start()
        defer { server.stop() }
        let folder = try scratchFolder("records")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("cache")
        let repo = try makeRepository("repo", in: folder)
        let kept = try cacheFolder(of: repo, cache: cache)
        try putScan(tinyModel, in: kept)
        let env = environment(cache: cache, server: server)
        let records = kept.appendingPathComponent("drawn")
        func recordNames() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: records.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted() }

        // the board in front, drawn as it
        let first = try ingest([repo.path, "--scan", handScan(kept)], environment: env)
        expectEqual(first.status, 0, first.output + first.error)
        let drawn = front.editor.file.shapeCount
        expect(drawn > 0 && recordNames().count == 1, "one drawing, one record: \(recordNames())")

        // a proposal, drawn into a new file: another record, and the board in front is as it was
        let proposal = folder.appendingPathComponent("Proposal.canvasboard")
        let second = try ingest([repo.path, "--scan", handScan(kept), "--new-file", proposal.path], environment: env)
        expectEqual(second.status, 0, second.output + second.error)
        let board = try require(opened.boards.first, "the new file is open")
        expect(second.output.contains("verify ok") && board.editor.file.shapeCount > 0, second.output)
        expectEqual(recordNames().count, 2, "one record for each file: \(recordNames())")
        expectEqual(front.editor.file.shapeCount, drawn, "the board in front was not touched")

        // the board in front again: it is drawn in place of its own last drawing, which the proposal's record did not replace
        let third = try ingest([repo.path, "--scan", handScan(kept)], environment: env)
        expectEqual(third.status, 0, third.output + third.error)
        expect(third.output.contains("replace: took back the last drawing") && third.output.contains("verify ok"), third.output)
        expectEqual(front.editor.file.shapeCount, drawn, "the same drawing, once")
        // ... and the proposal's board, in place of the proposal, from a run of its own
        let proposalShapes = board.editor.file.shapeCount
        let fourth = try ingest([repo.path, "--scan", handScan(kept), "--board", "\(board.number)"], environment: env)
        expectEqual(fourth.status, 0, fourth.output + fourth.error)
        expect(fourth.output.contains("replace: took back the last drawing") && fourth.output.contains("verify ok"), fourth.output)
        expectEqual(board.editor.file.shapeCount, proposalShapes, "the proposal drawn again in its place")
        expectEqual(front.editor.file.shapeCount, drawn, "the board in front is as it was")
        expectEqual(recordNames().count, 2, "still one record for each file: \(recordNames())")
        let paths = try recordNames().map { try json(records.appendingPathComponent($0))["path"]?.stringValue }
        expect(paths.filter { $0?.hasSuffix("Proposal.canvasboard") == true }.count == 1, "the proposal's record is of its file: \(paths)")

        // a record that is no board's file's does not stop a board that is empty: a file with a record of its own that is gone
        let empty = windowedBoard()
        opened.boards.append(empty)
        let fifth = try ingest([repo.path, "--scan", handScan(kept), "--board", "\(empty.number)"], environment: env)
        expectEqual(fifth.status, 0, fifth.output + fifth.error)
        expectEqual(recordNames().count, 3, "a third file, a third record: \(recordNames())")
    },
])

@MainActor let ingestCommitsTests = Suite("canvas-ingest: each commit its own board", [
    test("a commit is what is drawn, never the working tree: each commit its own board, one drawn twice the same plan and scripts, the second commit type-checks only the module that changed, the code scanned once") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("commits")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("cache")
        let kit = "import Core\n\npublic func kit() -> Int {\n    core() + 1\n}\n"
        let repo = try makeRepository("pkg", in: folder, files: [
            "Package.swift": tinyPackage(loose: false), "Sources/Core/Core.swift": "public func core() -> Int { 1 }\n",
            "Sources/Kit/Kit.swift": kit, "Tests/KitTests/KitTests.swift": "import Kit\n\nfunc twice() -> Int { kit() * 2 }\n",
        ])
        let first = try git(repo, ["rev-parse", "HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        // the second commit changes a function's body in Kit, so Kit's interface is as it was: no other module is made again
        try write("import Core\n\npublic func kit() -> Int {\n    let more = 2\n    return core() + more\n}\n", to: repo.appendingPathComponent("Sources/Kit/Kit.swift"))
        try git(repo, ["commit", "-q", "-a", "-m", "a longer body"])
        let second = try git(repo, ["rev-parse", "HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let kept = try cacheFolder(of: repo, cache: cache)
        // the SDK build.sh chose for this build, so the index build needn't ask the compiler about one it rejects (ten seconds)
        let sdk = (try? String(contentsOfFile: "build/.sdk", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let env = environment(cache: cache, server: server, extra: sdk.map { ["SDKROOT": $0] } ?? [:])
        @MainActor func draw(_ commit: String, _ more: [String] = []) throws -> (process: ProcessOutput, run: URL) {
            let done = try ingest([repo.path, "--commit", commit] + more, environment: env)
            expectEqual(done.status, 0, done.output + done.error)
            expect(done.output.contains("verify ok"), done.output)
            return (done, try lastRun(in: kept))
        }
        @MainActor func noteText(_ folder: URL, _ title: String) throws -> String? {
            let digest = try json(folder.appendingPathComponent("digest.json"))
            return (digest["nodes"]?.arrayValue ?? []).first { $0["title"] == .string(title) }?["text"]?.stringValue
        }

        let one = try draw(first)
        expect(one.process.output.contains("checking out \(first.prefix(12))") && one.process.output.contains("ingest: type-checked 3 of 3 modules"), "everything, the first time: \(one.process.output)")
        let oneFiles = try drawing(one.run), oneKit = try noteText(one.run, "Kit.swift")
        let digestOne = try String(contentsOf: one.run.appendingPathComponent("digest.json"), encoding: .utf8)

        // the next commit: its own board, and only the module that changed is type-checked (its interface is as it was, so the others
        // aren't), though the same checkout is moved to it: the index's marks hold the sources' paths, which don't change
        let two = try draw(second)
        expect(two.process.output.contains("ingest: type-checked 1 of 3 modules"), two.process.output)
        expect(try String(contentsOf: two.run.appendingPathComponent("index.log"), encoding: .utf8).contains("indexes: made 1 of 3 (Kit)"), "Kit alone")
        let twoKit = try noteText(two.run, "Kit.swift")
        expect(twoKit != oneKit, "Kit.swift is longer in the second commit: \(oneKit ?? "") / \(twoKit ?? "")")
        let twoFiles = try drawing(two.run)
        expect(twoFiles != oneFiles, "the plan differs between commits")

        // an edit in the working tree, and a file git doesn't know, never show: the commit is drawn, and a scan made already isn't made again
        try write("import Core\n\npublic func kit() -> Int {\n    let more = 3\n    let dirty = more * 2\n    return core() + dirty\n}\n", to: repo.appendingPathComponent("Sources/Kit/Kit.swift"))
        try write("public func working() {}\n", to: repo.appendingPathComponent("Sources/Kit/Working.swift"))
        let again = try draw(second)
        expect(again.process.output.contains("the scan of \(second.prefix(12)) is kept") && !again.process.output.contains("type-checked") && !again.process.output.contains("checking out"),
               "a second run on a commit goes straight to the lens: \(again.process.output)")
        expectEqual(try drawing(again.run), twoFiles, "the same commit, the same plan and scripts, whatever the working tree holds")
        expectEqual(try String(contentsOf: again.run.appendingPathComponent("digest.json"), encoding: .utf8), try String(contentsOf: two.run.appendingPathComponent("digest.json"), encoding: .utf8))
        // ... and scanned again, from the checkout, it is the same too: nothing of the working tree is in the checkout
        let rescanned = try draw(second, ["--rescan"])
        expect(rescanned.process.output.contains("ingest: no module changed: none of the 3 type-checked"), "the index is as the commit's code is: \(rescanned.process.output)")
        expectEqual(try drawing(rescanned.run), twoFiles, "scanned again, the same")
        expect(!FileManager.default.fileExists(atPath: kept.appendingPathComponent("checkout/Sources/Kit/Working.swift").path), "a file git doesn't know is not in the checkout")

        // back to the first commit: the board is of it as it was the first time
        let back = try draw(first)
        expectEqual(try drawing(back.run), oneFiles, "the first commit again, the first plan")
        expectEqual(try String(contentsOf: back.run.appendingPathComponent("digest.json"), encoding: .utf8), digestOne)
        expect(back.process.output.contains("is kept"), back.process.output)
        expect(try git(repo, ["worktree", "list"]).output.split(separator: "\n").count == 1, "the user's own worktree list is as it was")
    },
])

@MainActor let ingestCodeKeyTests = Suite("canvas-ingest: a scan kept by the commit's code, .canvas left out", [
    test("a scan is kept by the commit's code, .canvas left out: a commit that changes only the lens or the settings scans nothing and draws the new lens's picture, and a commit that changes code scans again") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("code-key")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("cache")
        let counter = folder.appendingPathComponent("scans.count"), prepared = folder.appendingPathComponent("prepare.count")
        let repo = try makeRepository("repo", in: folder, files: ["src/a.txt": "one\n"])
        let kept = try cacheFolder(of: repo, cache: cache)
        func lens(_ label: String) -> String {
            """
            from lenskit import Digest

            def digest(scan, repo):
                d = Digest("picture")
                d.frame("Files")
                for path in repo.files("src/*.txt"):
                    d.note("\(label) " + path.rpartition("/")[2], "Files", "A file.", source=path)
                return d.finish()
            """
        }
        try write(#"{"scanner": "scip", "prepare": "echo prepared >> \#(prepared.path)", "scip": "echo scanned >> \#(counter.path); echo made > {index}"}"#, to: repo.appendingPathComponent(".canvas/ingest.json"))
        try write(lens("first"), to: repo.appendingPathComponent(".canvas/lens.py"))
        try git(repo, ["add", "-A"])
        try git(repo, ["commit", "-q", "-m", "a lens"])
        @MainActor func head() throws -> String { try git(repo, ["rev-parse", "HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines) }
        func count(_ file: URL) -> Int { ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").count }
        @MainActor func draw() throws -> ProcessOutput {
            let done = try ingest([repo.path], environment: environment(cache: cache, server: server))
            expectEqual(done.status, 0, done.output + done.error)
            expect(done.output.contains("verify ok"), done.output)
            return done
        }
        @MainActor func titles() -> Set<String> { Set(board.editor.document.shapes.compactMap { board.editor.registry.title(of: $0) }) }
        @MainActor func checkedOut() throws -> String {
            try run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", kept.appendingPathComponent("checkout").path, "rev-parse", "HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        @MainActor func scanNames() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: kept.appendingPathComponent("scans").path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        }

        // the first commit is scanned, prepared and drawn
        let first = try head()
        let one = try draw()
        expect(one.output.contains("checking out \(first.prefix(12))") && one.output.contains("preparing"), one.output)
        expectEqual(count(counter), 1)
        expectEqual(count(prepared), 1)
        expect(titles().contains("first a.txt"), "\(titles().sorted())")
        expectEqual(scanNames().count, 1)
        // the key is the code's: 40 hex digits that are no commit's sha
        let parts = scanNames()[0].dropLast(".json".count).split(separator: "-")
        expect(parts.count == 3 && parts[0].count == 40 && parts[0] != Substring(first) && parts[1] == "scip", "\(scanNames())")

        // a commit that changes only .canvas/ (the lens, and the settings' window): the same code, so nothing is checked out, prepared or
        // scanned, and the new lens's picture is drawn in place of the first
        try write(lens("second"), to: repo.appendingPathComponent(".canvas/lens.py"))
        try write(#"{"scanner": "scip", "prepare": "echo prepared >> \#(prepared.path)", "scip": "echo scanned >> \#(counter.path); echo made > {index}", "window": [1200, 800]}"#, to: repo.appendingPathComponent(".canvas/ingest.json"))
        try git(repo, ["commit", "-q", "-a", "-m", "only .canvas changes"])
        let second = try head()
        expect(second != first)
        let two = try draw()
        expect(two.output.contains("the scan of \(second.prefix(12)) is kept") && two.output.contains("nothing is scanned"), two.output)
        expect(!two.output.contains("checking out") && !two.output.contains("preparing"), "the checkout stays where it was: \(two.output)")
        expectEqual(try checkedOut(), first, "the checkout was not moved")
        expectEqual(count(counter), 1, "nothing was scanned")
        expectEqual(count(prepared), 1, "nothing was prepared")
        expectEqual(scanNames().count, 1, "the one scan is both commits'")
        expect(two.output.contains("replace: took back the last drawing"), two.output)
        expect(titles().contains("second a.txt") && !titles().contains("first a.txt"), "the new lens's picture: \(titles().sorted())")
        // the lens is the working tree's, committed or not: an edit not committed draws too, and still scans nothing
        try write(lens("third"), to: repo.appendingPathComponent(".canvas/lens.py"))
        let three = try draw()
        expect(three.output.contains("nothing is scanned"), three.output)
        expect(titles().contains("third a.txt"), "\(titles().sorted())")
        try git(repo, ["commit", "-q", "-a", "-m", "the third lens"])
        expectEqual(count(counter), 1)

        // a commit that changes code is another scan
        try write("two\n", to: repo.appendingPathComponent("src/a.txt"))
        try write("more\n", to: repo.appendingPathComponent("src/b.txt"))
        try git(repo, ["add", "-A"])
        try git(repo, ["commit", "-q", "-m", "code changes"])
        let code = try head()
        let four = try draw()
        expect(four.output.contains("checking out \(code.prefix(12))") && !four.output.contains("is kept"), four.output)
        expectEqual(count(counter), 2)
        expectEqual(try checkedOut(), code)
        expectEqual(scanNames().count, 2)
        expect(titles().isSuperset(of: ["third a.txt", "third b.txt"]), "\(titles().sorted())")
        // and the old commit draws from its own scan, which is kept: nothing is scanned
        let back = try ingest([repo.path, "--commit", first], environment: environment(cache: cache, server: server))
        expectEqual(back.status, 0, back.output + back.error)
        expect(back.output.contains("nothing is scanned"), back.output)
        expectEqual(count(counter), 2)
        // --rescan still scans it again
        let rescanned = try ingest([repo.path, "--commit", second, "--rescan"], environment: environment(cache: cache, server: server))
        expectEqual(rescanned.status, 0, rescanned.output + rescanned.error)
        expect(rescanned.output.contains("checking out \(second.prefix(12))"), rescanned.output)
        expectEqual(count(counter), 3)
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

/// One module whose names differ only by case, in one container: two files, README.md and readme.md, and two folders, Util and util
/// (the folders hold a.ts and b.ts).
private let caseModel = #"""
{"language": "typescript", "name": "Cases",
 "modules": [
  {"name": "Cases", "path": "src/Cases", "deps": [], "test": false, "layer": null, "files": ["README.md", "readme.md", "Util/a.ts", "util/b.ts"], "lines": 40, "doc": "", "folders": {}}],
 "files": [
  {"module": "Cases", "rel": "README.md", "path": "src/Cases/README.md", "lines": 10, "doc": "", "api": false, "decls": []},
  {"module": "Cases", "rel": "readme.md", "path": "src/Cases/readme.md", "lines": 10, "doc": "", "api": false, "decls": []},
  {"module": "Cases", "rel": "Util/a.ts", "path": "src/Cases/Util/a.ts", "lines": 10, "doc": "", "api": false, "decls": []},
  {"module": "Cases", "rel": "util/b.ts", "path": "src/Cases/util/b.ts", "lines": 10, "doc": "", "api": false, "decls": []}],
 "uses": []}
"""#

/// Three packages whose folders repeat names, as a monorepo's do: each has a src with an index.ts and a util.ts, web and api a folder of
/// pages (views, routes) holding a Page.ts, and web a test folder with a util.ts of its own. Files use each other across them.
private let repeatsModel: String = {
    let layout = [("web", ["src/index.ts", "src/util.ts", "src/views/Page.ts", "test/util.ts"], ["core"]),
                  ("api", ["src/index.ts", "src/util.ts", "src/routes/Page.ts"], ["core"]), ("core", ["src/index.ts", "src/util.ts"], [])]
    func q(_ s: String) -> String { "\"" + s + "\"" }
    let modules = layout.map { name, rels, deps in
        #"{"name": \#(q(name)), "path": \#(q("packages/" + name)), "deps": [\#(deps.map(q).joined(separator: ", "))], "test": false, "layer": null, "files": [\#(rels.map(q).joined(separator: ", "))], "lines": \#(10 * rels.count), "doc": "", "folders": {}}"#
    }
    let files = layout.flatMap { name, rels, _ in
        rels.map { #"{"module": \#(q(name)), "rel": \#(q($0)), "path": \#(q("packages/\(name)/\($0)")), "lines": 10, "doc": "", "api": true, "decls": [{"name": "Thing", "kind": "type", "visibility": "public", "line": 1}]}"# }
    }
    let uses = [("web", "src/index.ts", "core", "src/index.ts"), ("api", "src/index.ts", "core", "src/index.ts"), ("web", "src/index.ts", "web", "src/util.ts"),
                ("web", "src/views/Page.ts", "web", "src/util.ts"), ("api", "src/util.ts", "core", "src/util.ts"), ("web", "test/util.ts", "web", "src/util.ts"),
                ("api", "src/routes/Page.ts", "api", "src/util.ts")].map {
        #"{"from": [\#(q($0.0)), \#(q($0.1))], "to": [\#(q($0.2)), \#(q($0.3))], "names": ["Thing"]}"#
    }
    return #"{"language": "typescript", "name": "Repeats", "modules": [\#(modules.joined(separator: ",\n"))], "files": [\#(files.joined(separator: ",\n"))], "uses": [\#(uses.joined(separator: ",\n"))]}"#
}()

/// A lens that is the default lens with overrides: a band for each layer (one module it names is not there), and App's frame.
private let tinyLens = """
from lenskit import default

def digest(scan, repo):
    return default.digest(scan, repo, bands=[("Apps", ["App", "Ghost"]), ("Foundations", ["Core"])],
                          groups={"App": [("Screens", ["Screen.swift"], [])]})
"""
