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

// The canvas-ingest skill (.claude/skills/canvas-ingest): a repository drawn as boards by `ingest`, run as an agent runs it, with
// `canvas` as built (CANVAS_CLI) against this test's own command server (CANVAS_SOCKET). The tests that start no app (what `ingest`
// passes a driver of its own that logs its arguments and draws nothing, what it refuses, the lens runner, the scanners, the readers)
// are SkillToolsTests'. Every test gives `ingest` a cache of its own (CANVAS_INGEST_CACHE) in a scratch folder, and the repositories
// it ingests are scratch git repositories there, never this one.

/// The environment `ingest` runs in: its own cache, and the app's command server when there is one (else a socket nothing answers).
@MainActor private func environment(cache: URL, server: CommandServer? = nil, extra: [String: String] = [:]) -> [String: String] {
    ingestEnvironment(cache: cache, socket: server?.path, extra: extra)
}

/// What a run was made from: its graph document (`graph.json`), which the same commit, lens, app and macOS make the same of.
@MainActor private func drawing(_ run: URL) throws -> String {
    try String(contentsOf: run.appendingPathComponent("graph.json"), encoding: .utf8)
}

/// The ids of the shapes a drawing made, by key, from the file's record of it (the drawing named for the repository, `project`, unless given).
@MainActor private func drawn(_ board: BoardDocument, _ name: String) -> [String: ShapeID] {
    board.editor.file[DrawingsProperty.self].drawings[name]?.idsByKey ?? [:]
}

/// Where each shape of the drawing named for the repository is, by key: the plan's account of the whole, as the file holds it.
@MainActor private func places(_ board: BoardDocument) -> [String: CGRect] {
    drawn(board, "project").compactMapValues { board.editor.file.record($0)?.box }
}

@MainActor private func drawn_(_ board: BoardDocument, _ name: String = "project") -> [String: ShapeID] { drawn(board, name) }

@MainActor let ingestFrontBoardTests = Suite("canvas-ingest: a scan drawn as the board in front with a lens of overrides, then again in its place", [
    test("ingest draws a codebase from its scan in one command, a lens.py of overrides for the default lens, and a rerun updates the drawing in place, by key") {
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
        expect(first.error.contains("leave out Main.swift") && first.error.contains("Ghost"), "what the lens leaves out or lacks is said: \(first.error)")
        let editor = board.editor
        let titles = Set(editor.document.shapes.compactMap { editor.registry.title(of: $0) })
        expect(titles.isSuperset(of: ["Apps", "Foundations", "App", "Core"]), "the root: the bands, the modules: \(titles.sorted())")
        expect(!titles.contains { $0.hasPrefix("About ") }, "and no note of what the whole is: \(titles.sorted())")
        let graph = try json(lastRun(in: kept).appendingPathComponent("graph.json"))
        expectEqual(graph["drawing"], "project", "the drawing is named for the repository")
        expect(graph["warnings"] == nil, "the lens's warnings are said, never kept in the document")
        let nodes = graph["nodes"]?.arrayValue ?? []
        func node(_ key: String) -> JSON? { nodes.first { $0["key"] == .string(key) } }
        expectEqual(node("file:Sources/App/Main.swift")?["in"], "dir:Sources/App", "a file the lens leaves out is in a frame of its own, never dropped")
        expectEqual(node("file:Sources/App/Screen.swift")?["in"], "group:App/Screens")
        expectEqual(node("band:Apps")?["layout"]?["rank"], 0)
        expectEqual(node("band:Foundations")?["layout"]?["rank"], 1)
        // the file holds the drawing, by key: one record, every node and the arrows between
        let ids = drawn(board, "project")
        expect(Set(ids.keys).isSuperset(of: Set(nodes.compactMap { $0["key"]?.stringValue })), "a shape for every node, by key: \(ids.keys.sorted())")
        expectEqual(editor.file[DrawingsProperty.self].drawings.keys.sorted(), ["project"])
        expectEqual(editor.undoHistory.undoName, "Draw", "all of it one step")
        let shapes = editor.file.shapeCount

        // drawn again: the same drawing, so the app updates it by key, shape by shape, and makes nothing new
        let second = try runIngest()
        expectEqual(second.status, 0, second.output + second.error)
        expect(!second.output.contains("replace"), "nothing is taken back first: \(second.output)")
        expectEqual(editor.file.shapeCount, shapes, "drawn again in its place, once")
        expectEqual(drawn(board, "project"), ids, "every shape the same shape")

        // --ranks says which way the root's bands run, through the dial in the document to the layout: rows, then columns, each drawn in the last one's place
        for way in ["rows", "columns"] {
            let ranked = try runIngest(["--ranks", way])
            expectEqual(ranked.status, 0, ranked.output + ranked.error)
            expectEqual(try json(lastRun(in: kept).appendingPathComponent("graph.json"))["layout"]?["ranks"], .string(way))
            @MainActor func box(_ title: String) -> CGRect? { editor.document.shapes.first { editor.registry.title(of: $0) == title }?.box }
            let apps = try require(box("Apps")), foundations = try require(box("Foundations"))
            expect(way == "rows" ? apps.maxY < foundations.minY : apps.maxX < foundations.minX, "\(way): Apps \(apps), Foundations \(foundations)")
            expectEqual(drawn(board, "project"), ids, "\(way): still the same shapes")
        }
        let sideways = try runIngest(["--ranks", "sideways"])
        expectEqual(sideways.status, 1, sideways.output)
        expect(sideways.error.contains("--ranks is rows or columns"), sideways.error)

        // the options of the old way are gone, and an app that isn't running is said, with how to start it, before anything is made
        for gone in ["--new-file", "--replace", "--records"] {
            let refused = try runIngest([gone, "x"])
            expectEqual(refused.status, 2, "\(gone): \(refused.output)")
            expect(refused.error.contains("unknown option \(gone)"), "\(gone): \(refused.error)")
        }
        let down = try ingest([repo.path, "--scan", handScan(kept)], environment: environment(cache: cache))
        expectEqual(down.status, 1, down.output)
        expect(down.error.contains("isn't running"), "an app that isn't running is said, with how to start it: \(down.error)")
        expectEqual(editor.file.shapeCount, shapes, "nothing drawn or taken back")
    },
])

@MainActor let ingestNamesTests = Suite("canvas-ingest: names that clash, repeat or are a band's, drawn as the code names them and found by where they are", [
    test("ingest draws a codebase whose names clash, run long or hold brackets: every title is the code's, nothing is reworded, and nothing stops the run") {
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
        expect(drawn.output.contains("applied project: shapes"), drawn.output)
        expect(!drawn.error.contains(" is titled "), "no title is reworded for a name another shape has: \(drawn.error)")
        let editor = board.editor
        let titles = editor.document.shapes.compactMap { editor.registry.title(of: $0) }
        // a module called what a band is keeps its name, and so does the band: the titles are the code's, the keys tell them apart
        expect(Set(titles).isSuperset(of: ["[locale]", "Level 1", #"back\slash"#, long]), "\(titles.sorted())")
        expectEqual(titles.filter { $0 == "Level 1" }.count, 2, "the band and the module")
        expect(!titles.contains { $0.hasPrefix("…") } && !titles.contains("Level 1 (layer)"), "a long name is not cut, a band's is not made over: \(titles.sorted())")
        // a file is titled by its name, wherever it is: three files called main.swift (in C's own frame, in a frame of a frame, in another)
        // and the notes of one name in two modules are different notes, told apart by their keys
        let graphFile = try lastRun(in: kept).appendingPathComponent("graph.json")
        let graph = try json(graphFile)
        let nodes = graph["nodes"]?.arrayValue ?? []
        func keys(_ title: String) -> [String] { nodes.filter { $0["props"]?["title"] == .string(title) }.compactMap { $0["key"]?.stringValue }.sorted() }
        expectEqual(keys("main.swift"), ["file:src/C/a/c/main.swift", "file:src/C/b/main.swift", "file:src/C/main.swift"])
        expectEqual(keys("index.ts").count, 2, "the two index.ts, in two modules")
        expect(keys("half\u{FFFD}.swift").count == 1, "a name that isn't whole text is titled with U+FFFD where it breaks: \(nodes.compactMap { $0["props"]?["title"]?.stringValue })")
        expect(Set(drawn_(board).keys).isSuperset(of: Set(nodes.compactMap { $0["key"]?.stringValue })), "a shape for each node, by its key")
        // the app has them as the document says: the notes called main.swift are three, each inside the frames it is in, as a query says it
        @MainActor func titled(_ title: String) throws -> [JSON] {
            let found = try canvas(server, ["query", "--board", "\(board.number)", "--limit", "100", #"sticky-note"\#(title)""#])
            expectEqual(found.status, 0, found.error)
            return try JSON(text: found.output)["rows"]?.arrayValue ?? []
        }
        expectEqual(try titled("index.ts").count, 2, "the app has both index.ts")
        expectEqual(try titled("half\u{FFFD}.swift").count, 1, "and the note whose name isn't whole text")
        let found = try canvas(server, ["query", "--board", "\(board.number)", "--limit", "100", #"sticky-note"main.swift""#])
        expectEqual(found.status, 0, found.error)
        let rows = try JSON(text: found.output)["rows"]?.arrayValue ?? []
        expectEqual(rows.map { ($0["inside"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: " > ") }.sorted(),
                    ["Level 1 > C > C", "Level 1 > C > a > c", "Level 1 > C > b"], "main.swift, three times, by where each is: \(found.output)")
        // a mention of a card is by its key; a ] and a \ in a key are written so the mention names its shape. app's description mentions
        // nothing: what it imports are its arrows
        let mentioned = try run(URL(fileURLWithPath: python), ["-s", "-B", "-c", "import sys; sys.path.insert(0, sys.argv[1]); from lenskit.text import mention; print(mention('module:[locale]'), mention(sys.argv[2]))",
                                                                ingestSkill().path, #"module:back\slash"#], timeout: 60)
        expectEqual(mentioned.output, #"@[module:[locale\]] @[module:back\\slash]"# + "\n", mentioned.error)
        let app = nodes.first { $0["key"] == "module:app" }?["props"]?["description"]?.stringValue ?? ""
        expect(app.hasSuffix(#"About \@[nothing] here."# + "\n\n1 files, 10 lines"), "its purpose (a @[ in it written as text) and its size: \(app)")
        expect(graph["text"] == nil, "and the document has no text of its own: no board has a note of what it is")

        // a module big enough for its folders to have boards, two of them the same but for their case: the document passes check
        let big = folder.appendingPathComponent("big")
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        try awkwardModel(long: long, big: true).write(to: big.appendingPathComponent("scan.json"), atomically: true, encoding: .utf8)
        let bigRepo = try makeRepository("bigrepo", in: folder)
        let made = try lensRunner(bigRepo, scan: big.appendingPathComponent("scan.json"), graph: big.appendingPathComponent("graph.json"))
        expectEqual(made.status, 0, made.output + made.error)
        expect(made.error.contains("Big/x: a module has that name, so the folder gets no board of its own"), made.error)
        let bigNodes = try json(big.appendingPathComponent("graph.json"))["nodes"]?.arrayValue ?? []
        func bigKeys(_ title: String) -> [String] { bigNodes.filter { $0["props"]?["title"] == .string(title) }.compactMap { $0["key"]?.stringValue }.sorted() }
        expectEqual(bigKeys("Big/x"), ["module:Big/x"], "the module Big/x is one card, and Big's folder x is not another")
        expectEqual(bigNodes.first { $0["key"] == "file:src/Big/x/its.ts" }?["in"], "module:Big/x", "the module's file is on its board")
        expectEqual(bigKeys("one.ts"), ["file:src/Big/x/one.ts", "file:src/Level 1/one.ts"], "the folder's files stay on Big's, in its frame x, and the module Level 1 has a one.ts of its own")
        expectEqual(bigNodes.filter { $0["props"]?["title"]?.stringValue?.lowercased() == "utils" }.compactMap { $0["key"]?.stringValue }.sorted(), ["module:Big/Utils", "module:Big/utils"],
                    "two folders that differ only by case, two cards: a title is no key")
        // paths that differ only by case are two nodes: two files, and two folders
        let cases = folder.appendingPathComponent("cases")
        try FileManager.default.createDirectory(at: cases, withIntermediateDirectories: true)
        try caseModel.write(to: cases.appendingPathComponent("scan.json"), atomically: true, encoding: .utf8)
        let caseMade = try lensRunner(bigRepo, scan: cases.appendingPathComponent("scan.json"), graph: cases.appendingPathComponent("graph.json"))
        expectEqual(caseMade.status, 0, caseMade.output + caseMade.error)
        expect(!caseMade.error.contains(" is titled "), caseMade.error)
        let caseNodes = try json(cases.appendingPathComponent("graph.json"))["nodes"]?.arrayValue ?? []
        expectEqual(caseNodes.compactMap { $0["props"]?["title"]?.stringValue }.filter { $0.lowercased().contains("readme") || $0.lowercased().hasPrefix("util") }.sorted(),
                    ["README.md", "Util", "readme.md", "util"], "each pair of names is the code's own, told apart by its key")
        for (graphDocument, label) in [(big.appendingPathComponent("graph.json"), "big"), (cases.appendingPathComponent("graph.json"), "cases"), (graphFile, "awkward")] {
            let checked = try digestCheck(graphDocument, timeout: 120)
            expectEqual(checked.status, 0, checked.output + checked.error)
            expectEqual(try JSON(text: checked.output)["errors"], .array([]), "\(label): check finds nothing wrong: \(checked.output)")
        }
    },
    test("the default lens draws a codebase whose folders repeat names: each board keeps the names of its folders and files, the keys tell them apart, and the app has each by where it is") {
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
        expect(drawn.output.contains("applied project: shapes"), drawn.output)
        expect(!drawn.error.contains(" is titled "), "no title is reworded for a name another board has: \(drawn.error)")
        // web, api and core each have a folder src, and every one of them a file index.ts and a util.ts (web has a second util.ts, in test)
        let graph = try json(lastRun(in: kept).appendingPathComponent("graph.json"))
        let nodes = graph["nodes"]?.arrayValue ?? []
        func titled(_ title: String) -> [JSON] { nodes.filter { $0["props"]?["title"] == .string(title) } }
        expectEqual([titled("src").count, titled("index.ts").count, titled("util.ts").count, titled("Page.ts").count, titled("test").count], [3, 3, 4, 2, 1])
        expectEqual(Set(nodes.compactMap { $0["key"]?.stringValue }).count, nodes.count, "a key for each, though the names repeat")
        expect(nodes.allSatisfy { $0["id"] == nil && $0["props"]?["id"] == nil }, "and no id or title claim")
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
        // drawn again, it updates its own drawing by key: the same shapes, once
        let ids = drawn_(board), shapes = board.editor.file.shapeCount
        let again = try ingest([repo.path, "--scan", handScan(kept)], environment: env)
        expectEqual(again.status, 0, again.output + again.error)
        expect(again.output.contains("applied project: shapes") && again.output.contains("unchanged"), again.output)
        expectEqual(board.editor.file.shapeCount, shapes, "drawn again in its place, once")
        expectEqual(drawn_(board), ids, "every shape the same shape")
    },
    test("a module called what its band is, with folder boards that mention it, is drawn: the band keeps its name beside the card's, and a mention names the card by its key") {
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
        // board whose card's description mentions its module (`@[module:Level 1]`), from the module's board
        func q(_ s: String) -> String { "\"" + s + "\"" }
        let rels = (0..<30).map { "a/f\($0).ts" } + (0..<30).map { "b/g\($0).ts" }
        let files = rels.map { #"{"module": "Level 1", "rel": \#(q($0)), "path": \#(q("src/L1/" + $0)), "lines": 10, "doc": "", "api": false, "decls": []}"# }
        try putScan(#"{"language": "typescript", "name": "Same", "modules": [{"name": "Top", "path": "src/Top", "deps": ["Level 1"], "test": false, "layer": null, "files": ["main.ts"], "lines": 10, "doc": "", "folders": {}}, {"name": "Level 1", "path": "src/L1", "deps": [], "test": false, "layer": null, "files": [\#(rels.map(q).joined(separator: ", "))], "lines": 600, "doc": "", "folders": {}}], "files": [{"module": "Top", "rel": "main.ts", "path": "src/Top/main.ts", "lines": 10, "doc": "", "api": false, "decls": []}, \#(files.joined(separator: ", "))], "uses": []}"#, in: kept)
        let drawn = try ingest([repo.path, "--scan", handScan(kept)], environment: environment(cache: cache, server: server))
        expectEqual(drawn.status, 0, drawn.output + drawn.error)
        expect(drawn.output.contains("applied project: shapes"), drawn.output)
        expect(!drawn.error.contains(" is titled "), drawn.error)
        let editor = board.editor
        expectEqual(editor.document.shapes.compactMap { editor.registry.title(of: $0) }.filter { $0 == "Level 1" }.count, 2, "the band and the card, both called Level 1")
        let mentioners = try canvas(server, ["query", "--board", "\(board.number)", "--brief", "--limit", "100", #"subboard:mentions(subboard"Level 1")"#])
        expectEqual(mentioners.status, 0, mentioners.error)
        expectEqual(try (JSON(text: mentioners.output)["rows"]?.arrayValue ?? []).compactMap { $0["title"]?.stringValue }.sorted(), ["a", "b"],
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
        expect(drawn.output.contains("ingest: type-checked 3 of 3 modules") && drawn.output.contains("applied "), drawn.output)
        expect(FileManager.default.fileExists(atPath: kept.appendingPathComponent("checkout/prepared.txt").path), "the prepare command ran at the checkout's root")
        expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent("prepared.txt").path), "and not in the repository")
        let titles = Set(board.editor.document.shapes.compactMap { board.editor.registry.title(of: $0) })
        expect(titles.isSuperset(of: ["Core", "Kit"]), "the package as the drawing on the board in front: \(titles.sorted())")
        let edges = try json(lastRun(in: kept).appendingPathComponent("graph.json"))["edges"]?.arrayValue ?? []
        expect(edges.contains { $0["from"] == "file:Sources/Kit/Kit.swift" && $0["to"] == "file:Sources/Core/Core.swift" }, "Kit.swift's use of Core.swift is an edge of the graph: \(edges)")
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
        // their module's board
        try write("""
            from lenskit import Graph, text

            GROUPS = [("Screen", "Views"), ("Store", "Data"), ("Model", "Data")]

            def digest(scan, repo):
                g = Graph(scan.name + " by convention")
                cards, frames = {}, {}
                for m in scan.production:
                    cards[m] = g.node("module:" + m, "subboard", {"title": m, "description": text.as_text(scan.module(m)["doc"])})
                for (m, rel), f in sorted(scan.files.items()):
                    group = next((name for suffix, name in GROUPS if rel.endswith(suffix + ".swift")), "Entry points")
                    if (m, group) not in frames:
                        frames[(m, group)] = g.node("group:" + m + "/" + group, "frame", {"title": group}, in_=cards[m])
                    g.node("file:" + f["path"], "sticky-note", {"title": rel, "text": text.file_text(f, scan.language)}, in_=frames[(m, group)])
                for a, b, names in scan.uses:
                    if a in scan.files and b in scan.files and a != b:
                        g.edge("file:" + scan.files[a]["path"], "file:" + scan.files[b]["path"], layout={"weight": len(names)})
                return g.finish()
            """, to: repo.appendingPathComponent(".canvas/lens.py"))
        let drawn = try ingest([repo.path, "--scan", handScan(kept)], environment: environment(cache: cache, server: server))
        expectEqual(drawn.status, 0, drawn.output + drawn.error)
        expect(drawn.output.contains("applied TinyPackage by convention: shapes"), drawn.output)
        let editor = board.editor
        let titles = Set(editor.document.shapes.compactMap { editor.registry.title(of: $0) })
        expect(titles.isSuperset(of: ["App", "Core"]), "the boards the lens made: \(titles.sorted())")
        let graph = try json(lastRun(in: kept).appendingPathComponent("graph.json"))
        expectEqual(graph["drawing"], "TinyPackage by convention", "a lens names its drawing")
        let nodes = graph["nodes"]?.arrayValue ?? []
        func node(_ key: String) -> JSON? { nodes.first { $0["key"] == .string(key) } }
        expectEqual(node("file:Sources/App/Screen.swift")?["in"], "group:App/Views")
        expectEqual(node("file:Sources/App/Main.swift")?["in"], "group:App/Entry points")
        expectEqual(Set(nodes.filter { $0["in"] == "group:Core/Data" }.compactMap { $0["props"]?["title"]?.stringValue }), ["Store.swift", "Model.swift"], "files by what they are called")
        expect(graph["warnings"] == nil, "warnings are said, never kept in the document")
        let ids = drawn_(board, "TinyPackage by convention")
        expect(Set(ids.keys).isSuperset(of: Set(nodes.compactMap { $0["key"]?.stringValue })), "the file's record of the drawing is by the lens's keys: \(ids.keys.sorted())")
        // a rerun updates the drawing in place
        let again = try ingest([repo.path, "--scan", handScan(kept)], environment: environment(cache: cache, server: server))
        expectEqual(again.status, 0, again.output + again.error)
        expect(again.output.contains("unchanged"), again.output)
        expectEqual(drawn_(board, "TinyPackage by convention"), ids)
    },
    test("a board from a scan given by hand: the same commit draws the same graph and the same shapes whether the lens is committed or not, or the working tree has edits") {
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
        let plainGraph = try String(contentsOf: plain.run.appendingPathComponent("graph.json"), encoding: .utf8), plainPlaces = places(board)
        expect(!plainPlaces.isEmpty, "something is drawn")

        // a lens that is not committed, and the same once committed (the commit drawn is the same), with the working tree edited
        let lens = "from lenskit import default\n\ndef digest(scan, repo):\n    return default.digest(scan, repo)\n"
        try write(lens, to: repo.appendingPathComponent(".canvas/lens.py"))
        let uncommitted = try draw()
        expectEqual(try String(contentsOf: uncommitted.run.appendingPathComponent("graph.json"), encoding: .utf8), plainGraph, "a lens that calls the default lens makes what the default lens makes")
        expectEqual(places(board), plainPlaces, "and draws it where it was")
        try git(repo, ["add", ".canvas/lens.py"])
        try git(repo, ["commit", "-q", "-m", "the lens"])
        try write("two\n", to: repo.appendingPathComponent("notes.txt"))      // and the working tree has an edit
        let committedLens = try draw()
        expectEqual(places(board), plainPlaces, "committing the lens changes nothing: the same shapes in the same places")
        expectEqual(try String(contentsOf: committedLens.run.appendingPathComponent("graph.json"), encoding: .utf8), plainGraph)

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

@MainActor let ingestRecordsTests = Suite("canvas-ingest: a drawing record in the file for each drawing name", [
    test("the file keeps a record for each drawing: a second name is a second drawing beside the first, each drawn again updates its own by key, a change in the code deletes only what the code lost, and --on draws on a subboard's board") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let folder = try scratchFolder("records")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("cache")
        let repo = try makeRepository("repo", in: folder)
        let kept = try cacheFolder(of: repo, cache: cache)
        try putScan(tinyModel, in: kept)
        let env = environment(cache: cache, server: server)
        let editor = board.editor
        @MainActor func drawIt(_ more: [String] = []) throws -> ProcessOutput {
            let done = try ingest([repo.path, "--scan", handScan(kept)] + more, environment: env)
            expectEqual(done.status, 0, done.output + done.error)
            return done
        }
        @MainActor func records() -> [String: DrawingRecord] { editor.file[DrawingsProperty.self].drawings }

        // the code's own drawing, named for the repository
        _ = try drawIt()
        let own = drawn(board, "repo")
        expect(own.count > 5 && records().keys.sorted() == ["repo"], "one drawing, one record: \(records().keys.sorted())")
        expectEqual(records()["repo"]?.board, "root")
        let alone = editor.file.shapeCount

        // --on draws on a subboard's board (while one card is called Core): the record says which board, and drawn again without saying where, the
        // drawing is updated where it is
        let core = try require(own["module:Core"], "the Core card")
        let deep = try drawIt(["--drawing", "deep", "--on", "Core"])
        expect(deep.output.contains("applied deep: shapes"), deep.output)
        expectEqual(records()["deep"]?.board, core.description, "the record is of the board of Core's card")
        let deepIDs = drawn(board, "deep")
        let deepAgain = try drawIt(["--drawing", "deep"])
        expectEqual(deepAgain.status, 0, deepAgain.output + deepAgain.error)
        expectEqual(records()["deep"]?.board, core.description)
        expectEqual(drawn(board, "deep"), deepIDs, "updated where it is")
        expect(deepAgain.output.contains("unchanged"), deepAgain.output)
        expectEqual(drawn(board, "repo"), own)

        // a proposal: another name, another record, drawn into the same file, and the first drawing is as it was
        let proposal = try drawIt(["--drawing", "proposal"])
        expect(proposal.output.contains("applied proposal: shapes"), proposal.output)
        expectEqual(records().keys.sorted(), ["deep", "proposal", "repo"])
        expectEqual(drawn(board, "repo"), own, "the code's drawing is untouched")
        expect(Set(drawn(board, "proposal").values).isDisjoint(with: Set(own.values)) && editor.file.shapeCount > alone, "and the proposal's shapes are its own")
        // a person's note beside them
        _ = try draw(script: #"sticky-note "Mine" right of origin (gap: 3000) below origin (gap: 0)"#, dryRun: false, reveal: false, program: "canvas", in: editor)
        let withMine = editor.file.shapeCount

        // each again: its own shapes, by key; the person's note stays; nothing is made twice
        let again = try drawIt()
        expect(again.output.contains("unchanged"), again.output)
        expectEqual(drawn(board, "repo"), own)
        expectEqual(editor.file.shapeCount, withMine)
        let proposalAgain = try drawIt(["--drawing", "proposal"])
        expectEqual(proposalAgain.status, 0, proposalAgain.output + proposalAgain.error)
        expectEqual(editor.file.shapeCount, withMine)

        // the code loses a file: the lens leaves it out, and the drawing takes back that shape and no other
        let mainID = try require(own["file:Sources/App/Main.swift"], "Main.swift was drawn")
        try write("""
            from lenskit import default

            def digest(scan, repo):
                g = default.build(scan, repo)
                g.nodes[:] = [n for n in g.nodes if n["key"] != "file:Sources/App/Main.swift"]
                g.edges[:] = [e for e in g.edges if "file:Sources/App/Main.swift" not in (e["from"], e["to"])]
                del g.by_key["file:Sources/App/Main.swift"]
                return g.finish()
            """, to: repo.appendingPathComponent(".canvas/lens.py"))
        let lost = try drawIt()
        expect(lost.output.contains("1 deleted") || lost.output.contains("deleted"), lost.output)
        expect(editor.file.record(mainID) == nil, "the shape of the file the code lost is gone")
        let nodeKeys = Set(try json(lastRun(in: kept).appendingPathComponent("graph.json"))["nodes"]?.arrayValue?.compactMap { $0["key"]?.stringValue } ?? [])
        expect(!nodeKeys.contains("file:Sources/App/Main.swift") && drawn(board, "repo")["file:Sources/App/Main.swift"] == nil, "no longer in the drawing")
        expect(own.filter { nodeKeys.contains($0.key) }.allSatisfy { drawn(board, "repo")[$0.key] == $0.value }, "and every other shape is the same shape")
        expect(editor.file.shapeCount < withMine, "it and its arrows are gone, and the proposal still has its Main.swift: \(drawn(board, "proposal")["file:Sources/App/Main.swift"] != nil)")
        expect(drawn(board, "proposal")["file:Sources/App/Main.swift"] != nil)

    },
])

@MainActor let ingestCommitsTests = Suite("canvas-ingest: each commit its own board", [
    test("a commit is what is drawn, never the working tree: each commit drawn as the same drawing, updated in place, one drawn twice the same graph and drawing, the second commit type-checks only the module that changed, the code scanned once") {
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
            expect(done.output.contains("applied pkg: shapes"), done.output)
            return (done, try lastRun(in: kept))
        }
        @MainActor func noteText(_ folder: URL, _ title: String) throws -> String? {
            let graph = try json(folder.appendingPathComponent("graph.json"))
            return (graph["nodes"]?.arrayValue ?? []).first { $0["props"]?["title"] == .string(title) }?["props"]?["text"]?.stringValue
        }

        let one = try draw(first)
        expect(one.process.output.contains("checking out \(first.prefix(12))") && one.process.output.contains("ingest: type-checked 3 of 3 modules"), "everything, the first time: \(one.process.output)")
        let oneFiles = try drawing(one.run), oneKit = try noteText(one.run, "Kit.swift"), oneIDs = drawn(board, "pkg")
        expect(!oneIDs.isEmpty, "drawn as pkg, the repository's name: \(board.editor.file[DrawingsProperty.self].drawings.keys.sorted())")
        let digestOne = try String(contentsOf: one.run.appendingPathComponent("graph.json"), encoding: .utf8)

        // the next commit: its own board, and only the module that changed is type-checked (its interface is as it was, so the others
        // aren't), though the same checkout is moved to it: the index's marks hold the sources' paths, which don't change
        let two = try draw(second)
        expect(two.process.output.contains("ingest: type-checked 1 of 3 modules"), two.process.output)
        expect(try String(contentsOf: two.run.appendingPathComponent("index.log"), encoding: .utf8).contains("indexes: made 1 of 3 (Kit)"), "Kit alone")
        let twoKit = try noteText(two.run, "Kit.swift")
        // ... drawn in the first commit's place: the same shapes, by key, and the note of the file that grew says so
        let kitID = try require(drawn(board, "pkg")["file:Sources/Kit/Kit.swift"], "Kit.swift is drawn")
        expectEqual(kitID, oneIDs["file:Sources/Kit/Kit.swift"], "the same note")
        expectEqual(board.editor.file.record(kitID)?.propertiesJSON?["text"]?.stringValue, twoKit, "and it says what the second commit says")
        expect(twoKit != oneKit, "Kit.swift is longer in the second commit: \(oneKit ?? "") / \(twoKit ?? "")")
        let twoFiles = try drawing(two.run)
        expect(twoFiles != oneFiles, "the graph differs between commits")

        // an edit in the working tree, and a file git doesn't know, never show: the commit is drawn, and a scan made already isn't made again
        try write("import Core\n\npublic func kit() -> Int {\n    let more = 3\n    let dirty = more * 2\n    return core() + dirty\n}\n", to: repo.appendingPathComponent("Sources/Kit/Kit.swift"))
        try write("public func working() {}\n", to: repo.appendingPathComponent("Sources/Kit/Working.swift"))
        let again = try draw(second)
        expect(again.process.output.contains("the scan of \(second.prefix(12)) is kept") && !again.process.output.contains("type-checked") && !again.process.output.contains("checking out"),
               "a second run on a commit goes straight to the lens: \(again.process.output)")
        expectEqual(try drawing(again.run), twoFiles, "the same commit, the same graph, whatever the working tree holds")
        expectEqual(try String(contentsOf: again.run.appendingPathComponent("graph.json"), encoding: .utf8), try String(contentsOf: two.run.appendingPathComponent("graph.json"), encoding: .utf8))
        // ... and scanned again, from the checkout, it is the same too: nothing of the working tree is in the checkout
        let rescanned = try draw(second, ["--rescan"])
        expect(rescanned.process.output.contains("ingest: no module changed: none of the 3 type-checked"), "the index is as the commit's code is: \(rescanned.process.output)")
        expectEqual(try drawing(rescanned.run), twoFiles, "scanned again, the same")
        expect(!FileManager.default.fileExists(atPath: kept.appendingPathComponent("checkout/Sources/Kit/Working.swift").path), "a file git doesn't know is not in the checkout")

        // back to the first commit: the board is of it as it was the first time
        let back = try draw(first)
        expectEqual(try drawing(back.run), oneFiles, "the first commit again, the first graph")
        expectEqual(try String(contentsOf: back.run.appendingPathComponent("graph.json"), encoding: .utf8), digestOne)
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
            from lenskit import Graph

            def digest(scan, repo):
                g = Graph("picture")
                files = g.node("frame:Files", "frame", {"title": "Files"})
                for path in repo.files("src/*.txt"):
                    g.node("file:" + path, "sticky-note", {"title": "\(label) " + path.rpartition("/")[2], "text": "A file."}, in_=files)
                return g.finish()
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
            expect(done.output.contains("applied picture: shapes"), done.output)
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
        let aID = try require(drawn(board, "picture")["file:src/a.txt"], "a.txt is drawn")
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
        expect(two.output.contains("1 updated") || two.output.contains("updated"), "the same drawing, updated in place: \(two.output)")
        expect(titles().contains("second a.txt") && !titles().contains("first a.txt"), "the new lens's picture: \(titles().sorted())")
        expectEqual(drawn(board, "picture")["file:src/a.txt"], aID, "in the first one's shape, by key")
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
