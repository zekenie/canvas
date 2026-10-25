import AppKit
import CryptoKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasUI
import Foundation
import Mentions
import ShippedTesting
import TestKit
import Titles

// The canvas-ingest skill (.claude/skills/canvas-ingest): a repository drawn as boards by `ingest`, run as an agent runs it, with
// `canvas` as built (CANVAS_CLI) against this test's own command server (CANVAS_SOCKET), and, where a test is about what `ingest`
// passes the driver or refuses before it asks the app, with a driver of its own beside a copy of the skill that logs its arguments
// and draws nothing. Every test gives `ingest` a cache of its own (CANVAS_INGEST_CACHE) in a scratch folder, and the repositories
// it ingests are scratch git repositories there, never this one.

private let python = "/usr/bin/python3"

/// The skill's folder, absolute (tests run from the repository's root).
private func ingestSkill(_ path: String = "") -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".claude/skills/canvas-ingest").appendingPathComponent(path)
}

private func json(_ url: URL) throws -> JSON { try JSON(text: String(contentsOf: url, encoding: .utf8)) }

private func scratchFolder(_ name: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("IngestTests-\(UUID().uuidString)-\(name)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// A path with every link in it resolved, as `git` and `ingest` give it (Foundation's `resolvingSymlinksInPath` leaves /private off).
private func realPath(_ url: URL) -> String {
    guard let resolved = realpath(url.path, nil) else { return url.path }
    defer { free(resolved) }
    return String(cString: resolved)
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

/// `git` on a scratch repository, with no configuration of the user's (a commit needs none, and signs nothing).
@MainActor @discardableResult private func git(_ repo: URL, _ arguments: [String]) throws -> ProcessOutput {
    let done = try run(URL(fileURLWithPath: "/usr/bin/git"),
                       ["-C", repo.path, "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"] + arguments,
                       environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"], timeout: 60)
    expectEqual(done.status, 0, "git \(arguments.joined(separator: " ")): \(done.output)\(done.error)")
    return done
}

/// A scratch git repository named `name` in `folder`, with `files` (path in the repository: text) committed.
@MainActor private func makeRepository(_ name: String, in folder: URL, files: [String: String] = [:]) throws -> URL {
    let made = folder.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
    let repo = URL(fileURLWithPath: realPath(made))
    try git(repo, ["init", "-q"])
    for (path, text) in files { try write(text, to: repo.appendingPathComponent(path)) }
    try write("scratch\n", to: repo.appendingPathComponent("README.md"))
    try git(repo, ["add", "-A"])
    try git(repo, ["commit", "-q", "-m", "scratch"])
    return repo
}

/// The environment `ingest` runs in: its own cache, and the app's command server when there is one (else a socket nothing answers).
@MainActor private func environment(cache: URL, server: CommandServer? = nil, extra: [String: String] = [:]) -> [String: String] {
    var environment = ["CANVAS_CLI": builtExecutable("CanvasCLI").path, "CANVAS_SOCKET": server?.path ?? temporarySocketPath(), "CANVAS_INGEST_CACHE": cache.path,
                       "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
    for (key, value) in extra { environment[key] = value }
    return environment
}

/// `ingest <arguments>` as an agent runs it.
@MainActor private func ingest(_ arguments: [String], with ingest: URL = ingestSkill("ingest"), environment: [String: String], timeout: TimeInterval = 280) throws -> ProcessOutput {
    try run(ingest, arguments, environment: environment, timeout: timeout)
}

/// The folder `ingest` keeps a repository's scan, index, runs and drawing records in.
@MainActor private func cacheFolder(of repo: URL, cache: URL, with script: URL = ingestSkill("ingest")) throws -> URL {
    let where_ = try ingest([repo.path, "--where"], with: script, environment: environment(cache: cache))
    expectEqual(where_.status, 0, where_.output + where_.error)
    return URL(fileURLWithPath: where_.output.trimmingCharacters(in: .whitespacesAndNewlines))
}

/// A scan written by hand (beside the cache's own folders), for `ingest --scan` to draw from: `handScan(cacheFolder)` is its path.
private func putScan(_ text: String, in cacheFolder: URL) throws {
    try write(text, to: cacheFolder.appendingPathComponent("hand.scan.json"))
}

private func handScan(_ cacheFolder: URL) -> String { cacheFolder.appendingPathComponent("hand.scan.json").path }

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

/// The runs `ingest` kept, oldest first.
private func runFolders(in cacheFolder: URL) -> [URL] {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: cacheFolder.appendingPathComponent("runs").path)) ?? []).sorted()
    return names.map { cacheFolder.appendingPathComponent("runs/\($0)") }
}

/// The newest run's folder: its `digest.json`, and the driver's `out/`.
@MainActor private func lastRun(in cacheFolder: URL) throws -> URL { try require(runFolders(in: cacheFolder).last, "no run was kept in \(cacheFolder.path)") }

/// A copy of the skill with a driver of its own beside it (`<skills>/canvas-ingest`, `<skills>/canvas-digest/digest`), where `ingest`
/// looks for it: the driver logs the line of arguments it was given to the file STUB_LOG and draws nothing (with STUB_LOCK, the folder
/// of the lock, it also says whose lock is held and who its parent is; with STUB_FAIL set it refuses, as an app that isn't running does).
@MainActor private func stubbedSkill(in folder: URL) throws -> (ingest: URL, log: URL) {
    let skills = folder.appendingPathComponent("skills")
    try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: ingestSkill(), to: skills.appendingPathComponent("canvas-ingest"))
    let driver = skills.appendingPathComponent("canvas-digest/digest")
    try write("#!/bin/sh\necho \"$*\" >> \"$STUB_LOG\"\n[ -z \"${STUB_LOCK:-}\" ] || echo \"held $(cat \"$STUB_LOCK/pid\" 2>/dev/null) by $PPID\" >> \"$STUB_LOG\"\n[ -z \"${STUB_FAIL:-}\" ] || exit 1\nexit 0\n", to: driver)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: driver.path)
    return (skills.appendingPathComponent("canvas-ingest/ingest"), folder.appendingPathComponent("driver.log"))
}

/// How many of a commit's objects a partial clone hasn't fetched: its files, and a treeless clone's folders.
@MainActor private func unfetched(_ clone: URL, _ sha: String) throws -> Int {
    try git(clone, ["rev-list", "--objects", "--missing=print", "--no-walk", sha]).output.split(separator: "\n").filter { $0.hasPrefix("?") }.count
}

/// The lines the stub driver logged.
private func driverCalls(_ log: URL) -> [String] {
    ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
}

/// The lens runner as `ingest` runs it (`runner/run.py`): the repository's lens, else the default lens, run twice in isolation.
@MainActor private func lensRunner(_ repo: URL, scan: URL, digest: URL, lens: URL? = nil, timeout: TimeInterval = 280) throws -> ProcessOutput {
    try run(URL(fileURLWithPath: python), [ingestSkill("runner/run.py").path, repo.path, scan.path, digest.path] + (lens.map { ["--lens", $0.path] } ?? []), timeout: timeout)
}

/// What the default lens makes of a scan: the digest it writes, and what it says on standard error (its `lens:` lines).
/// `ingest-lens/<name>.digest.json` and `.said`, first the old `to_digest.py`'s, recorded when lenskit replaced it, and recorded again
/// from the default lens when the first board's About note went (its summary of the whole, and the 74 characters a card's title kept
/// for `About <card>`), then with a module card's `Imports` and `Imported by` lines taken out by a script when the lens stopped writing them.
/// Never edited by hand: the lens has since given titles out per container, and the test below holds the digest to differing from them only by that.
private func lensFixture(_ name: String, _ kind: String) -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/CompositionTests/Fixtures/ingest-lens/\(name).\(kind)")
}

/// How the digest at `digest` names its nodes, read as canvas-digest reads them (`namingScript`): the problems it finds, none when every
/// title is unique in its container (spaces folded, case aside), a node has an `id` exactly where another node has its title, ids are
/// unique, and each `in`, `from` and `to` names its node by its id where it has one, else by its title. Given `old`, a digest from
/// when titles were given out once in the whole digest, also the ways it differs from that one which the rules of titles don't
/// explain (the same nodes in the same order, every field but the title, the id and the container the same, the same edges in the
/// same order, each reference naming the node it named), and how often each rule changed a title: "a file's name in place of a longer
/// end of its path", "a (…) fallback gone", "a number gone"; any other change of a title is a problem.
@MainActor private func namingReport(_ digest: URL, against old: URL? = nil) throws -> (problems: [String], rules: [String: Int]) {
    let done = try run(URL(fileURLWithPath: python), ["-c", namingScript, digest.path] + (old.map { [$0.path] } ?? []), timeout: 120)
    expectEqual(done.status, 0, done.error)
    let report = try JSON(text: done.output)
    return ((report["problems"]?.arrayValue ?? []).compactMap(\.stringValue), (report["rules"]?.objectValue ?? [:]).compactMapValues(\.intValue))
}

@MainActor let ingestTests = Suite("canvas-ingest: a repository drawn as boards by `ingest`", [
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

    test("lenskit's Digest gives a title out once in its container, lets a name repeat in another, and names nodes by an id where a title repeats; the same under another hash seed") {
        let folder = try scratchFolder("builder")
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("builder.py")
        try write(builderScript(skill: ingestSkill().path), to: script)
        let seeds = try ["1", "2"].map { try run(URL(fileURLWithPath: python), ["-s", "-B", script.path], environment: ["PYTHONHASHSEED": $0], timeout: 60) }
        for seed in seeds { expectEqual(seed.status, 0, seed.output + seed.error) }
        expectEqual(seeds[0].output, seeds[1].output, "the same digest and words under another hash seed")
        let out = try JSON(text: seeds[0].output)
        func strings(_ key: String) -> [String] { (out[key]?.arrayValue ?? []).compactMap(\.stringValue) }
        // a title is given out once in its container (spaces folded, case aside), and may repeat in another
        expectEqual(strings("container"), ["index.ts", "index.ts", "Index.ts (2)", "other.ts"])
        expectEqual(strings("container_said"), ["z is titled \"Index.ts (2)\": \"Index.ts\" is another shape's title in \"A\" too",
                                                "w is titled \"other.ts\": \"  index.ts \" is another shape's title in \"A\" too"])
        // with no container there is one scope for the whole digest, as there always was
        expectEqual(strings("whole"), ["Core", "core (layer)", "CORE (2)", "Core (3)"])
        expectEqual(strings("whole_taken"), ["core", "core (2)", "core (3)", "core (layer)"])
        expectEqual(strings("whole_said").first, "y is titled \"core (layer)\": \"core\" is another shape's title too")
        // alone: no other shape has the title, in any container, whichever came first
        expectEqual(strings("alone"), ["Core", "core (layer)", "x", "Core (2)"])
        expectEqual(strings("alone_said").first, "band is titled \"core (layer)\": \"core\" is the card Core's title, which no other shape may have")
        expectEqual(strings("alone_after"), ["Shared", "shared (card)"])
        // type: unique among types in any container, shared with a note that is no type
        expectEqual(strings("types"), ["Table", "Table", "TABLE (type)"])
        expectEqual(strings("types_said"), ["t2 is titled \"TABLE (type)\": \"TABLE\" is another type's title too"])
        // within a title names the one node that has it
        expectEqual(strings("by_title"), ["x", "x", "x (2)"])
        expect(out["unknown"]?.stringValue?.contains("no node has that title") == true, "\(out["unknown"] ?? .null)")
        expect(out["ambiguous"]?.stringValue?.contains("2 nodes have that title") == true, "\(out["ambiguous"] ?? .null)")
        // a digest of titles that are all unique comes out as it was written, strings and nodes alike, with no id
        expectEqual(out["plain"], ["title": "plain", "nodes": [["title": "F", "kind": "frame", "rank": 0], ["title": "N", "kind": "sticky-note", "in": "F", "text": "words", "source": "n.py"],
                                                              ["title": "M", "kind": "sticky-note", "in": "F"]],
                                   "edges": [["from": "N", "to": "F"], ["from": "M", "to": "N", "weight": 2]], "warnings": []])
        // a title two nodes have: an id for each, the title then the containers (the digest's own way to tell them apart), and every
        // reference to either is its id; a node whose title is unique is still named by it, as a string or as a node
        let shop = try require(out["digest"])
        let ids = (shop["nodes"]?.arrayValue ?? []).map { $0["id"]?.stringValue ?? "-" }
        expectEqual(ids, ["-", "-", "-", "index.ts  in Top > app", "index.ts  in Top > lib", "-"])
        expectEqual((shop["edges"]?.arrayValue ?? []).map { "\($0["from"]?.stringValue ?? "?") > \($0["to"]?.stringValue ?? "?")" },
                    ["index.ts  in Top > app > index.ts  in Top > lib", "index.ts  in Top > lib > Only", "Only > index.ts  in Top > app", "Only > lib"])
        expectEqual((shop["nodes"]?.arrayValue ?? []).first { $0["id"] == "index.ts  in Top > app" }?.objectValue?.keys.sorted(), ["id", "in", "kind", "source", "text", "title"])
        expectEqual((shop["nodes"]?.arrayValue ?? []).compactMap { $0["in"]?.stringValue }, ["Top", "Top", "app", "lib", "lib"], "a container is named by its title where that is its own")
        expectEqual(out["again"], true, "and finishing again changes nothing")
        // what is refused: a string that names several nodes, a node of another digest, and two types of one title
        expect(out["ambiguous_ref"]?.stringValue?.contains("\"Same\" is the title of 2 nodes") == true && out["ambiguous_ref"]?.stringValue?.contains("give the nodes ids") == true, "\(out["ambiguous_ref"] ?? .null)")
        expect(out["foreign"]?.stringValue?.contains("a node this digest doesn't have") == true, "\(out["foreign"] ?? .null)")
        expect(out["two_types"]?.stringValue?.contains("2 types are called \"Table\"") == true && out["two_types"]?.stringValue?.contains("type=True") == true, "\(out["two_types"] ?? .null)")
        // an id the lens gave stays; a title that is another node's id gets an id, so it is named by it; two ids that would be one get a number
        expectEqual((out["ids"]?.arrayValue ?? []).map { ($0.arrayValue ?? []).compactMap(\.stringValue).joined(separator: " | ") },
                    ["P", "Q", "X | mine | P", "X | X  in Q | Q", "mine | mine  in Q | Q", "Y | Y  in P | Q", "Y | Y  in P (2) | P"])
        expectEqual((out["id_edges"]?.arrayValue ?? []).map { ($0.arrayValue ?? []).compactMap(\.stringValue).joined(separator: " > ") },
                    ["mine > X  in Q", "mine  in Q > Y  in P", "X  in Q > Y  in P (2)"])
        expectEqual(out["order_broken"], 0, "ids sort as titles do: no two titles, over 2,400 random ones, come out of order by key")
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

    test("a package whose product is a list of plugins, as this one is: a line that ends + shipped type-checks against the plugins' modules, and the scan keeps the line's own dependencies") {
        let folder = try scratchFolder("shipped")
        defer { try? FileManager.default.removeItem(at: folder) }
        let repo = folder.appendingPathComponent("repo"), scratch = folder.appendingPathComponent("index"), model = folder.appendingPathComponent("scan.json")
        func put(_ path: String, _ text: String) throws { try write(text, to: repo.appendingPathComponent(path)) }
        // App names no plugin and is made of the list; its tests call Kit, which their line doesn't write
        try put("Package.swift", listedPackage(testsShip: true))
        try put("Sources/Core/Core.swift", "public func core() -> Int { 1 }\n")
        try put("Sources/Kit/Kit.swift", "import Core\n\npublic struct KitPlugin {\n    public init() {}\n    public var count: Int { core() + 1 }\n}\n")
        try put("Sources/App/main.swift", "import Core\n\nprint(core())\n")
        try put("Tests/AppTests/AppTests.swift", "import Core\nimport Kit\n\nfunc both() -> Int { core() + KitPlugin().count }\n")
        let scanners = ingestSkill("scanners")
        let sdk = (try? String(contentsOfFile: "build/.sdk", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        @MainActor func scanner(_ script: String, _ arguments: [String]) throws -> ProcessOutput {
            try run(URL(fileURLWithPath: python), [scanners.appendingPathComponent(script).path] + arguments,
                    environment: sdk.map { ["SDKROOT": $0] } ?? [:], timeout: 280)
        }
        let built = try scanner("swift_index_build.py", [repo.path, scratch.path])
        expectEqual(built.status, 0, built.output + built.error)
        expect(built.output.contains("interfaces: made 2 of 2 (Core, Kit)\n") && built.output.contains("indexes: made 4 of 4 (App, AppTests, Core, Kit)\n"), built.output)

        // what the board draws its arrows from is what each line writes: the app's card points at Core, never at every plugin
        let analyzed = try scanner("swift_analyze.py", [repo.path, model.path])
        expectEqual(analyzed.status, 0, analyzed.output + analyzed.error)
        let modules = try json(model)["modules"]?.arrayValue ?? []
        func deps(_ name: String) -> [String] { (modules.first { $0["name"] == .string(name) }?["deps"]?.arrayValue ?? []).compactMap(\.stringValue) }
        expectEqual(deps("App"), ["Core"])
        expectEqual(deps("AppTests"), ["Core"])
        expectEqual(deps("Kit"), ["Core"])

        // without + shipped, a line's own dependencies are all a compile of it reads
        try put("Package.swift", listedPackage(testsShip: false))
        let undeclared = try scanner("swift_index_build.py", [repo.path, scratch.path])
        expect(undeclared.status != 0 && undeclared.output.contains("index AppTests: failed") && undeclared.output.contains("no such module 'Kit'"), undeclared.output + undeclared.error)
    },

    test("the settings: keys read and handed to the driver, each beaten by its option, an unknown key warned, a bad value refused naming its key") {
        let folder = try scratchFolder("settings")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("cache")
        let (script, log) = try stubbedSkill(in: folder)
        let repo = try makeRepository("repo", in: folder)
        let kept = try cacheFolder(of: repo, cache: cache, with: script)
        try putScan(tinyModel, in: kept)
        let env = environment(cache: cache, extra: ["STUB_LOG": log.path])
        let settings = repo.appendingPathComponent(".canvas/ingest.json")
        @MainActor func ingestLine(_ arguments: [String] = []) throws -> (process: ProcessOutput, line: String) {
            let before = driverCalls(log).count
            let process = try ingest([repo.path, "--scan", handScan(kept)] + arguments, with: script, environment: env)
            expectEqual(process.status, 0, process.output + process.error)
            let calls = driverCalls(log)
            expectEqual(calls.count, before + 2, "the driver is asked if it could draw, then to draw: \(calls)")
            return (process, calls.last ?? "")
        }

        // the keys, as the driver takes them; the scan is made into a digest in the run's folder, and drawn from there, into the cache's records
        try write(#"{"scanner": "swift", "mess": 0.5, "ranks": "columns", "window": [1000, 700], "colour": "red"}"#, to: settings)
        let read = try ingestLine()
        expect(read.line.hasPrefix("all ") && read.line.contains("--board front --replace") && read.line.contains("--records \(kept.path)/drawn"), read.line)
        expect(read.line.contains("--mess 0.5") && read.line.contains("--ranks columns") && read.line.contains("--view 1000x700"), "the settings are the driver's options: \(read.line)")
        expect(read.line.contains("\(kept.path)/runs/") && read.line.contains("/digest.json") && read.line.contains("/out"), "a run's own folder holds its digest and its out: \(read.line)")
        expect(read.process.error.contains("unknown key \"colour\""), "an unknown key is said: \(read.process.error)")
        expect(FileManager.default.fileExists(atPath: try lastRun(in: kept).appendingPathComponent("digest.json").path), "the digest is made in the run's folder")

        // an option given beats the setting it is for, and only that one
        let beaten = try ingestLine(["--mess", "0.9", "--ranks", "rows", "--window", "900x600"])
        expect(beaten.line.contains("--mess 0.9") && beaten.line.contains("--ranks rows") && beaten.line.contains("--view 900x600"), beaten.line)
        expect(!beaten.line.contains("0.5") && !beaten.line.contains("columns") && !beaten.line.contains("1000x700"), "and the settings' are not passed as well: \(beaten.line)")
        let partly = try ingestLine(["--ranks", "rows"])
        expect(partly.line.contains("--mess 0.5") && partly.line.contains("--ranks rows") && partly.line.contains("--view 1000x700"), partly.line)

        // no window: the driver is not told one, and asks the app's
        try write(#"{"scanner": "swift"}"#, to: settings)
        let bare = try ingestLine()
        expect(!bare.line.contains("--view") && !bare.line.contains("--mess") && !bare.line.contains("--ranks"), "no setting, no option: \(bare.line)")
        try FileManager.default.removeItem(at: settings)
        let none = try ingestLine()
        expect(!none.line.contains("--view"), "with no settings file at all: \(none.line)")

        // a bad value is refused, naming its key, before the driver is asked anything
        let calls = driverCalls(log).count
        let bad: [(key: String, settings: String)] = [
            ("scanner", #"{"scanner": "ruby"}"#), ("window", #"{"window": [1440]}"#), ("window", #"{"window": [0, 700]}"#), ("window", #"{"window": "big"}"#),
            ("mess", #"{"mess": 2}"#), ("mess", #"{"mess": true}"#), ("ranks", #"{"ranks": "diagonal"}"#), ("scip", #"{"scip": "make an index"}"#),
            ("prepare", #"{"prepare": 3}"#), ("window", #"{"window": [1e400, 5]}"#), ("window", #"{"window": [5, 99999999999]}"#),
            ("window", #"{"window": [NaN, 5]}"#), ("mess", #"{"mess": 1e400}"#),
        ]
        for (key, text) in bad {
            try write(text, to: settings)
            let refused = try ingest([repo.path, "--scan", handScan(kept)], with: script, environment: env)
            expectEqual(refused.status, 1, "\(text): \(refused.output)")
            expect(refused.error.contains("\"\(key)\""), "\(text) is refused naming \(key): \(refused.error)")
            expect(!refused.error.contains("Traceback"), "\(text) is refused in words, not with a traceback: \(refused.error)")
        }
        try write("{not json", to: settings)
        let broken = try ingest([repo.path, "--scan", handScan(kept)], with: script, environment: env)
        expectEqual(broken.status, 1, broken.output)
        expect(broken.error.contains("ingest.json"), broken.error)
        expectEqual(driverCalls(log).count, calls, "none of them got as far as the driver")
    },

    test("what to scan with: a Package.swift is Swift's without settings, anything else is refused with what to write, scip runs its command at the checkout's root, and prepare runs first") {
        let folder = try scratchFolder("scanner")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("cache")
        let (script, log) = try stubbedSkill(in: folder)
        let env = environment(cache: cache, extra: ["STUB_LOG": log.path])
        let repo = try makeRepository("repo", in: folder)
        let kept = try cacheFolder(of: repo, cache: cache, with: script)
        let settings = repo.appendingPathComponent(".canvas/ingest.json")

        // a folder that is no repository is named, not "the current folder"
        let away = folder.appendingPathComponent("no/such/folder").path
        let notThere = try ingest([away], with: script, environment: env)
        expectEqual(notThere.status, 1, notThere.output)
        expect(notThere.error.contains("\(away) is not in a git repository") && !notThere.error.contains("the current folder"), notThere.error)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("plain"), withIntermediateDirectories: true)
        let notGit = try ingest([folder.appendingPathComponent("plain").path], with: script, environment: env)
        expect(notGit.error.contains("plain is not in a git repository"), notGit.error)

        // no settings, no Package.swift: nothing to go by, and nothing asked of the app
        let nothing = try ingest([repo.path], with: script, environment: env)
        expectEqual(nothing.status, 1, nothing.output)
        expect(nothing.error.contains(".canvas/ingest.json") && nothing.error.contains("\"scanner\"") && nothing.error.contains("scip"), "it says what to write: \(nothing.error)")
        expect(driverCalls(log).isEmpty && runFolders(in: kept).isEmpty, "refused before anything was asked or made")
        // settings that name a scanner it can't use
        try write(#"{"scanner": "swift"}"#, to: settings)
        let noPackage = try ingest([repo.path], with: script, environment: env)
        expectEqual(noPackage.status, 1, noPackage.output)
        expect(noPackage.error.contains("Package.swift"), noPackage.error)
        try write(#"{"scanner": "scip"}"#, to: settings)
        let noCommand = try ingest([repo.path], with: script, environment: env)
        expectEqual(noCommand.status, 1, noCommand.output)
        expect(noCommand.error.contains("\"scip\""), noCommand.error)
        expect(driverCalls(log).isEmpty, "and none of them asked the driver")

        // scip: the command runs at the checkout's root, with {index} the file the scan is read from (this one writes none that
        // means anything, so the scan has no module in it)
        try write(#"{"scanner": "scip", "scip": "pwd > where.txt; echo made > {index}"}"#, to: settings)
        let scip = try ingest([repo.path], with: script, environment: env)
        expectEqual(scip.status, 0, scip.output + scip.error)
        expect(scip.output.contains("modules 0"), "the index was scanned: \(scip.output)")
        expectEqual(try String(contentsOf: kept.appendingPathComponent("index/index.scip"), encoding: .utf8), "made\n")
        let checkout = kept.appendingPathComponent("checkout")
        let ranIn = try String(contentsOf: checkout.appendingPathComponent("where.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        expectEqual(realPath(URL(fileURLWithPath: ranIn)), realPath(checkout), "at the checkout's root, the commit's code and never the working tree")
        expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent("where.txt").path), "nothing is written in the repository")
        let sha = try git(repo, ["rev-parse", "HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let scans = try FileManager.default.contentsOfDirectory(atPath: kept.appendingPathComponent("scans").path)
        expect(scans.count == 1 && scans[0].hasSuffix(".json") && scans[0].contains("-scip-") && !scans[0].hasPrefix(sha), "and the scan is kept by the commit's code and the scanner: \(scans)")
        expect(scip.output.contains("checking out \(sha.prefix(12))"), scip.output)

        // the command runs in a shell of its own, as prepare does: none of ingest's variables are in it (CACHE is ingest's; a name nobody
        // set is empty there, where in ingest's own shell, which stops on one, it would end the run)
        try write(#"{"scanner": "scip", "scip": "printf '%s' \"${CACHE-unset}\" > env.txt; echo \"$NOBODY_SET_THIS\"; echo made > {index}"}"#, to: settings)
        let own = try ingest([repo.path], with: script, environment: env)
        expectEqual(own.status, 0, own.output + own.error)
        expectEqual(try String(contentsOf: checkout.appendingPathComponent("env.txt"), encoding: .utf8), "unset", "ingest's variables are not the command's")
        // the last index is never read as the next commit's: a command that exits 0 and writes none is refused, and nothing is kept
        let scansBefore = try FileManager.default.contentsOfDirectory(atPath: kept.appendingPathComponent("scans").path)
        try git(repo, ["commit", "-q", "--allow-empty", "-m", "next"])
        let next = try git(repo, ["rev-parse", "HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        try write(#"{"scanner": "scip", "scip": "true # {index}"}"#, to: settings)
        let stale = try ingest([repo.path], with: script, environment: env)
        expectEqual(stale.status, 1, stale.output + stale.error)
        expect(stale.error.contains("wrote no index"), stale.error)
        expect(!FileManager.default.fileExists(atPath: kept.appendingPathComponent("index/index.scip").path), "the old index was removed before the command")
        let keptScans = try FileManager.default.contentsOfDirectory(atPath: kept.appendingPathComponent("scans").path)
        expectEqual(keptScans.sorted(), scansBefore.sorted(), "and no scan is kept for the commit: \(keptScans) (\(next))")

        // prepare runs first, and a failing one stops the run before the scanner
        try write(#"{"scanner": "scip", "prepare": "echo ready > prepared.txt; exit 3", "scip": "echo ran > scanned.txt; echo made > {index}"}"#, to: settings)
        let prepared = try ingest([repo.path], with: script, environment: env)
        expectEqual(prepared.status, 1, prepared.output)
        expect(prepared.error.contains("prepare"), prepared.error)
        expect(FileManager.default.fileExists(atPath: checkout.appendingPathComponent("prepared.txt").path) && !FileManager.default.fileExists(atPath: checkout.appendingPathComponent("scanned.txt").path), "prepare ran, and the scanner did not")
    },

    test("one cache a repository, whatever worktree it is run from: two worktrees of a repository share its scan, its runs and its records, and the last five runs are kept") {
        let folder = try scratchFolder("worktrees")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("cache")
        let (script, log) = try stubbedSkill(in: folder)
        let env = environment(cache: cache, extra: ["STUB_LOG": log.path])
        let repo = try makeRepository("repo", in: folder)
        let worktree = folder.appendingPathComponent("worktree")
        try git(repo, ["worktree", "add", "-q", worktree.path, "-b", "elsewhere"])
        let again = try makeRepository("again", in: folder)

        let main = try cacheFolder(of: repo, cache: cache, with: script)
        let other = try cacheFolder(of: worktree, cache: cache, with: script)
        expectEqual(other.path, main.path, "a worktree of the repository keeps what it makes where the repository does")
        let digest = SHA256.hash(data: Data(realPath(repo.appendingPathComponent(".git")).utf8)).map { String(format: "%02x", $0) }.joined().prefix(12)
        expectEqual(main.lastPathComponent, "repo-\(digest)", "named for the folder the git directory is in, and a hash of its path")
        expectEqual(realPath(main.deletingLastPathComponent()), realPath(cache))
        expect(try cacheFolder(of: again, cache: cache, with: script).path != main.path, "and another repository has its own")
        let inside = try run(URL(fileURLWithPath: "/bin/sh"), ["-c", #"mkdir -p "$0/Sources/deep" && cd "$0/Sources/deep" && exec "$@""#, worktree.path, script.path, "--where"], environment: env)
        expectEqual(inside.output.trimmingCharacters(in: .whitespacesAndNewlines), main.path, "from inside a folder of the worktree, without naming it")
        expect(!FileManager.default.fileExists(atPath: worktree.appendingPathComponent(".canvas").path) && !FileManager.default.fileExists(atPath: repo.appendingPathComponent(".canvas").path), "ingest writes nothing into either")

        // a scan the repository's own checkout made is the worktree's to draw from, and a run from the worktree is the repository's
        try putScan(tinyModel, in: main)
        let drawn = try run(URL(fileURLWithPath: "/bin/sh"), ["-c", #"cd "$0" && exec "$@""#, worktree.path, script.path, "--scan", handScan(main)], environment: env)
        expectEqual(drawn.status, 0, drawn.output + drawn.error)
        let digestFile = try lastRun(in: main).appendingPathComponent("digest.json")
        expectEqual(try json(digestFile)["title"], "TinyPackage")
        expect(driverCalls(log).contains { $0.hasPrefix("all ") && $0.contains("--records \(main.path)/drawn") }, "drawn with the repository's records: \(driverCalls(log))")

        // the last five runs are kept
        for number in 1...6 { try write("{}", to: main.appendingPathComponent("runs/2020010\(number)-000000-1/digest.json")) }
        let more = try ingest([repo.path, "--scan", handScan(main)], with: script, environment: env)
        expectEqual(more.status, 0, more.output + more.error)
        let names = runFolders(in: main).map(\.lastPathComponent)
        expectEqual(names.count, 5, "\(names)")
        expect(!names.contains("20200101-000000-1") && !names.contains("20200102-000000-1") && names.contains("20200106-000000-1"), "the oldest went: \(names)")
        expect(names.last?.hasPrefix("20200106") == false, "and the newest is this run's: \(names)")
    },

    test("one ingest a repository at a time: a lock held by a live process refuses a second run at once, a dead process's is taken over, and it is held for the whole run and freed on any exit") {
        let folder = try scratchFolder("lock")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("cache")
        let (script, log) = try stubbedSkill(in: folder)
        let repo = try makeRepository("repo", in: folder)
        let kept = try cacheFolder(of: repo, cache: cache, with: script)
        try putScan(tinyModel, in: kept)
        let lock = kept.appendingPathComponent("lock")
        let env = environment(cache: cache, extra: ["STUB_LOG": log.path, "STUB_LOCK": lock.path])

        // held by a live process (this one): refused, naming it, and the lock is still its own
        try write("\(getpid())\n", to: lock.appendingPathComponent("pid"))
        let started = Date()
        let refused = try ingest([repo.path, "--scan", handScan(kept)], with: script, environment: env)
        expectEqual(refused.status, 1, refused.output)
        expect(refused.error.contains("pid \(getpid())"), "it names the holder: \(refused.error)")
        expect(Date().timeIntervalSince(started) < 10, "and refuses at once")
        expect(driverCalls(log).isEmpty && runFolders(in: kept).isEmpty, "before it asked the app or made anything")
        expectEqual(try String(contentsOf: lock.appendingPathComponent("pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "\(getpid())", "the holder's lock is left alone")

        // held by a process that is gone: taken over, held while the run draws, and freed when it ends
        let gone = Process()
        gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try gone.run()
        gone.waitUntilExit()
        try write("\(gone.processIdentifier)\n", to: lock.appendingPathComponent("pid"))
        let taken = try ingest([repo.path, "--scan", handScan(kept)], with: script, environment: env)
        expectEqual(taken.status, 0, taken.output + taken.error)
        let held = driverCalls(log).filter { $0.hasPrefix("held ") }
        expectEqual(held.count, 2, "asked twice, with the lock held both times: \(driverCalls(log))")
        for line in held {
            let words = line.split(separator: " ").map(String.init)
            expect(words.count == 4 && words[1] == words[3] && words[1] != "\(gone.processIdentifier)", "the lock is the run's own, not the dead process's: \(line)")
        }
        expect(!FileManager.default.fileExists(atPath: lock.path), "freed when the run ended")

        // freed on any exit: a driver that refuses (as an app that isn't running does), and a stop by a signal
        let failing = try ingest([repo.path, "--scan", handScan(kept)], with: script, environment: environment(cache: cache, extra: ["STUB_LOG": log.path, "STUB_LOCK": lock.path, "STUB_FAIL": "1"]))
        expectEqual(failing.status, 1, failing.output)
        expect(!FileManager.default.fileExists(atPath: lock.path), "freed when the driver refused")
        expect(runFolders(in: kept).count == 1, "and the refused run left no folder: \(runFolders(in: kept))")
        try write("#!/bin/sh\necho started >> \"$STUB_LOG\"\nexec sleep 30\n", to: script.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("canvas-digest/digest"))
        let slow = Process()
        slow.executableURL = script
        slow.arguments = [repo.path, "--scan", handScan(kept)]
        slow.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        try slow.run()
        defer { if slow.isRunning { slow.terminate() } }
        let begun = Date(timeIntervalSinceNow: 60)
        while !driverCalls(log).contains("started"), Date() < begun { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        expect(FileManager.default.fileExists(atPath: lock.path), "held while the run is under way")
        let second = try ingest([repo.path, "--scan", handScan(kept)], with: script, environment: env)
        expectEqual(second.status, 1, second.output)
        expect(second.error.contains("pid \(slow.processIdentifier)"), "a run under way is the holder: \(second.error)")
        // stopped as a terminal stops a run: the signal goes to the run, and to what it waits for (which the run, a shell, sees first)
        slow.terminate()
        let pause = Date(timeIntervalSinceNow: 0.5)
        while Date() < pause { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        _ = try run(URL(fileURLWithPath: "/usr/bin/pkill"), ["-TERM", "-P", "\(slow.processIdentifier)"])
        let deadline = Date(timeIntervalSinceNow: 30)
        while slow.isRunning, Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        expect(!FileManager.default.fileExists(atPath: lock.path), "freed when the run was stopped")
    },

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

    test("one checkout in the cache, moved to each commit: borrowing the repository's objects, never a worktree of the user's, untracked files removed and ignored ones kept, and made again when it is broken") {
        let folder = try scratchFolder("checkout")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("cache")
        let (script, log) = try stubbedSkill(in: folder)
        let counter = folder.appendingPathComponent("scans.count")
        let repo = try makeRepository("repo", in: folder, files: [".gitignore": "node_modules/\n", "a.txt": "one\n"])
        @MainActor func head() throws -> String { try git(repo, ["rev-parse", "HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines) }
        @MainActor func commit(_ text: String) throws -> String {
            try write(text, to: repo.appendingPathComponent("a.txt"))
            try git(repo, ["commit", "-q", "-a", "-m", "a is \(text)"])
            return try head()
        }
        let kept = try cacheFolder(of: repo, cache: cache, with: script)
        let checkout = kept.appendingPathComponent("checkout")
        try write(#"{"scanner": "scip", "scip": "echo scanned >> \#(counter.path); echo made > {index}"}"#, to: repo.appendingPathComponent(".canvas/ingest.json"))
        let env = environment(cache: cache, extra: ["STUB_LOG": log.path])
        @MainActor func ingestIt(_ more: [String] = []) throws -> ProcessOutput {
            let done = try ingest([repo.path] + more, with: script, environment: env)
            expectEqual(done.status, 0, done.output + done.error)
            return done
        }
        func scans() -> Int { ((try? String(contentsOf: counter, encoding: .utf8)) ?? "").split(separator: "\n").count }
        @MainActor func checkedOut() throws -> (sha: String, a: String) {
            let sha = try run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", checkout.path, "rev-parse", "HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
            return (sha, try String(contentsOf: checkout.appendingPathComponent("a.txt"), encoding: .utf8))
        }
        let c1 = try head()

        // made once, borrowing the repository's objects (every commit of it is there, with no fetch), and nothing in the user's own worktree list
        let made = try ingestIt()
        expect(made.output.contains("checking out \(c1.prefix(12))"), made.output)
        let alternates = try String(contentsOf: checkout.appendingPathComponent(".git/objects/info/alternates"), encoding: .utf8)
        expectEqual(realPath(URL(fileURLWithPath: alternates.trimmingCharacters(in: .whitespacesAndNewlines))), realPath(repo.appendingPathComponent(".git/objects")), "the checkout borrows the repository's objects")
        expectEqual(try checkedOut().sha, c1)
        expectEqual(try git(repo, ["worktree", "list"]).output.split(separator: "\n").count, 1, "no worktree is added to the repository")
        expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent("where.txt").path), "nothing is written into the repository")
        expectEqual(scans(), 1)

        // moved to the next commit: what git doesn't know is removed, what it ignores stays (node_modules)
        try write("x\n", to: checkout.appendingPathComponent("node_modules/dep/x.js"))
        try write("x\n", to: checkout.appendingPathComponent("stray.txt"))
        let c2 = try commit("two\n")
        let moved = try ingestIt()
        expect(moved.output.contains("checking out \(c2.prefix(12))"), moved.output)
        expectEqual(try checkedOut().sha, c2)
        expectEqual(try checkedOut().a, "two\n")
        expect(FileManager.default.fileExists(atPath: checkout.appendingPathComponent("node_modules/dep/x.js").path), "an ignored file stays")
        expect(!FileManager.default.fileExists(atPath: checkout.appendingPathComponent("stray.txt").path), "an untracked one goes")
        expectEqual(scans(), 2)

        // a scan made already is not made again, and the checkout is not moved for it
        try write("dirty\n", to: repo.appendingPathComponent("a.txt"))
        let kept1 = try ingestIt(["--commit", c1])
        expect(kept1.output.contains("the scan of \(c1.prefix(12)) is kept, so nothing is scanned") && !kept1.output.contains("checking out"), kept1.output)
        expectEqual(scans(), 2)
        expectEqual(try checkedOut().sha, c2, "nothing was checked out")
        // --rescan scans it again, and the code is the commit's, not the working tree's
        let rescanned = try ingestIt(["--commit", c1, "--rescan"])
        expect(rescanned.output.contains("checking out \(c1.prefix(12))"), rescanned.output)
        expectEqual(scans(), 3)
        expectEqual(try checkedOut().a, "one\n", "the commit's file, though the working tree's is changed")
        expectEqual(try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8), "dirty\n", "and the working tree is as it was")
        // a revision is resolved once to a sha, as HEAD is
        let named = try ingestIt(["--commit", "HEAD~0"])
        expect(named.output.contains("the scan of \(c2.prefix(12)) is kept"), named.output)

        // the scan is kept by the commit's code, the scanner and what made it: another scip command is another scan
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: kept.appendingPathComponent("scans").path)) ?? []).sorted()
        expectEqual(names.count, 2, "\(names)")
        for name in names {
            let parts = name.dropLast(".json".count).split(separator: "-")
            expect(parts.count == 3 && parts[0].count == 40 && parts[0].allSatisfy { $0.isHexDigit } && ![c1, c2].contains(String(parts[0])) && parts[1] == "scip" && parts[2].count == 12 && parts[2].allSatisfy { $0.isHexDigit }, "<hash of the code>-<scanner>-<12 hex>: \(name)")
        }
        expectEqual(try json(kept.appendingPathComponent("scans/\(names[0])"))["name"], "repo", "the scan is named for the repository, never the checkout")
        try write(#"{"scanner": "scip", "scip": "echo scanned >> \#(counter.path); echo again > {index}"}"#, to: repo.appendingPathComponent(".canvas/ingest.json"))
        _ = try ingestIt(["--commit", c2])
        expectEqual(scans(), 4, "a different command is a different scan")
        expectEqual(((try? FileManager.default.contentsOfDirectory(atPath: kept.appendingPathComponent("scans").path)) ?? []).count, 3)

        // the last 20 scans are kept, the most recently made or used
        for number in 1...21 {
            let old = kept.appendingPathComponent("scans/\(String(format: "%040d", number))-scip-000000000000.json")
            try write("{}", to: old)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(1_000 + number))], ofItemAtPath: old.path)
        }
        _ = try ingestIt(["--commit", c2])
        let pruned = ((try? FileManager.default.contentsOfDirectory(atPath: kept.appendingPathComponent("scans").path)) ?? []).sorted()
        expectEqual(pruned.count, 20, "\(pruned)")
        expectEqual(pruned.filter { !$0.hasPrefix("0000") }.count, 3, "the scans made or used lately are kept: \(pruned)")
        expect(!pruned.contains { $0.hasPrefix(String(format: "%040d", 1)) } && pruned.contains { $0.hasPrefix(String(format: "%040d", 21)) }, "the oldest went: \(pruned)")

        // a checkout the repository's objects no longer cover (the source pruned one it lent) is made again, and said
        try FileManager.default.removeItem(at: checkout.appendingPathComponent(".git/objects/info/alternates"))
        let c3 = try commit("three\n")
        let healed = try ingestIt()
        expect(healed.error.contains("the checkout in the cache is broken") && healed.error.contains("making it again"), healed.error)
        expectEqual(try checkedOut().sha, c3)
        expectEqual(try checkedOut().a, "three\n")
        expect(!FileManager.default.fileExists(atPath: checkout.appendingPathComponent("node_modules").path), "made again from nothing")
        // ... and so is a folder that is no checkout at all, and one with its git directory gone, without taking some other repository's for it
        try FileManager.default.removeItem(at: checkout.appendingPathComponent(".git"))
        let c4 = try commit("four\n")
        let gone = try ingestIt()
        expect(gone.error.contains("broken"), gone.error)
        expectEqual(try checkedOut().sha, c4)
        expectEqual(try git(repo, ["status", "--porcelain", "--untracked-files=no"]).output, "", "the repository was not touched")

        // a commit that is not one is said, with nothing asked of the app
        let calls = driverCalls(log).count
        let nothing = try ingest([repo.path, "--commit", "no-such-branch"], with: script, environment: env)
        expectEqual(nothing.status, 1, nothing.output)
        expect(nothing.error.contains("can't find the commit no-such-branch"), nothing.error)
        expectEqual(driverCalls(log).count, calls, "refused before the driver was asked")
    },

    test("a partial clone draws a commit whose files it hasn't fetched (what the commit lacks is fetched from its remote first, as git fetches it), and a shallow clone refuses a commit it doesn't have, saying it is shallow") {
        let folder = try scratchFolder("clones")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("cache")
        let (script, log) = try stubbedSkill(in: folder)
        // the remote: two commits, serving partial clones and the objects they ask for by name over file://, as a host serves them
        let origin = try makeRepository("origin", in: folder, files: ["src/a.txt": "one\n", "src/deep/b.txt": "bee\n"])
        try git(origin, ["config", "uploadpack.allowFilter", "true"])
        try git(origin, ["config", "uploadpack.allowAnySHA1InWant", "true"])
        let c1 = try git(origin, ["rev-parse", "HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        try write("two\n", to: origin.appendingPathComponent("src/a.txt"))
        try write("cee\n", to: origin.appendingPathComponent("src/deep/c.txt"))
        try git(origin, ["add", "-A"])
        try git(origin, ["commit", "-q", "-m", "two"])
        let env = environment(cache: cache, extra: ["STUB_LOG": log.path])
        // a lens that reads the commit's files through repo, so the digest's title says which commit it read
        let lens = """
            from lenskit import Digest

            def digest(scan, repo):
                return Digest("a is " + repo.read("src/a.txt").strip() + ", b is " + repo.read("src/deep/b.txt").strip()).finish()
            """
        for filter in ["blob:none", "tree:0"] {
            let clone = folder.appendingPathComponent("partial-" + filter.replacingOccurrences(of: ":", with: "-"))
            try git(folder, ["clone", "-q", "--filter=\(filter)", "file://\(origin.path)", clone.path])
            let counter = folder.appendingPathComponent("\(clone.lastPathComponent).scans")
            try write(#"{"scanner": "scip", "scip": "cat src/a.txt >> \#(counter.path); echo made > {index}"}"#, to: clone.appendingPathComponent(".canvas/ingest.json"))
            try write(lens, to: clone.appendingPathComponent(".canvas/lens.py"))
            let kept = try cacheFolder(of: clone, cache: cache, with: script)
            // HEAD, which the clone checked out, is whole: nothing is fetched
            let head = try ingest([clone.path], with: script, environment: env)
            expectEqual(head.status, 0, "\(filter): \(head.output)\(head.error)")
            expect(!head.output.contains("fetching"), "\(filter): \(head.output)")
            expectEqual(try json(lastRun(in: kept).appendingPathComponent("digest.json"))["title"], "a is two, b is bee")
            // the first commit's files (and, treeless, its folders) were never fetched, and are now, from the clone's remote
            expect(try unfetched(clone, c1) > 0, "\(filter): the clone lacks the first commit's files to begin with")
            let older = try ingest([clone.path, "--commit", c1], with: script, environment: env)
            expectEqual(older.status, 0, "\(filter): \(older.output)\(older.error)")
            expect(older.output.contains("fetching the") && older.output.contains("of \(c1.prefix(12)) that this partial clone hasn't fetched, from its remote origin"), "\(filter): \(older.output)")
            expectEqual(try unfetched(clone, c1), 0, "\(filter): nothing of the commit is missing now")
            expectEqual(try String(contentsOf: counter, encoding: .utf8), "two\none\n", "\(filter): the scan of each commit ran on that commit's files")
            expectEqual(try json(lastRun(in: kept).appendingPathComponent("digest.json"))["title"], "a is one, b is bee", "\(filter): the lens read the commit")
            // drawn again, the commit is whole: nothing is fetched
            let again = try ingest([clone.path, "--commit", c1, "--rescan"], with: script, environment: env)
            expectEqual(again.status, 0, again.error)
            expect(!again.output.contains("fetching"), "\(filter): \(again.output)")
        }

        // a shallow clone has only its latest commit: an older one is refused, saying why, with nothing asked of the app
        let shallow = folder.appendingPathComponent("shallow")
        try git(folder, ["clone", "-q", "--depth", "1", "file://\(origin.path)", shallow.path])
        let calls = driverCalls(log).count
        let refused = try ingest([shallow.path, "--commit", c1], with: script, environment: env)
        expectEqual(refused.status, 1, refused.output)
        expect(refused.error.contains("can't find the commit \(c1)") && refused.error.contains("a shallow clone") && refused.error.contains("git fetch --unshallow"), refused.error)
        expectEqual(driverCalls(log).count, calls, "refused before the driver was asked")
    },

    test("what a run's commands say is kept, not said: prepare's and the indexer's output go to the run's folder, said only when they fail (their end), a lens's warnings past twenty go to a file, and the scan says what the index left out") {
        let folder = try scratchFolder("quiet")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("cache")
        let (script, log) = try stubbedSkill(in: folder)
        let repo = try makeRepository("repo", in: folder)
        let kept = try cacheFolder(of: repo, cache: cache, with: script)
        let env = environment(cache: cache, extra: ["STUB_LOG": log.path])
        // an install that prints a line a package, as a yarn install does
        let chatty = folder.appendingPathComponent("chatty.sh")
        try write("i=0; while [ $i -lt 300 ]; do echo \"fetching package $i\"; i=$((i+1)); done\n", to: chatty)
        let settings = repo.appendingPathComponent(".canvas/ingest.json")
        try write(#"{"scanner": "scip", "prepare": "sh \#(chatty.path)", "scip": "sh \#(chatty.path) && echo made > {index}"}"#, to: settings)
        let quiet = try ingest([repo.path], with: script, environment: env)
        expectEqual(quiet.status, 0, quiet.output + quiet.error)
        expect(!quiet.output.contains("fetching package") && !quiet.error.contains("fetching package"), "what the commands print is not said: \(quiet.output)\(quiet.error)")
        expect(quiet.output.contains("prepare.log") && quiet.output.contains("scip.log"), "the steps say where it goes: \(quiet.output)")
        let newest = try lastRun(in: kept)
        for name in ["prepare.log", "scip.log"] {
            expect(try String(contentsOf: newest.appendingPathComponent(name), encoding: .utf8).contains("fetching package 299"), "\(name) holds all of it")
        }
        // a prepare that fails says the end of what it said, and where the rest is
        try write(#"{"scanner": "scip", "prepare": "sh \#(chatty.path) && echo the last words && exit 3", "scip": "echo made > {index}"}"#, to: settings)
        let failed = try ingest([repo.path], with: script, environment: env)
        expectEqual(failed.status, 1, failed.output)
        expect(failed.error.contains("fetching package 299") && failed.error.contains("the last words") && !failed.error.contains("fetching package 0\n"), "its last 40 lines: \(failed.error)")
        expect(failed.error.contains("prepare command failed") && failed.error.contains("prepare.log"), failed.error)

        // a lens that warns 25 times: the first 20 said, all of them in a file beside the digest
        try putScan(tinyModel, in: kept)
        try write("from lenskit import Digest\n\ndef digest(scan, repo):\n    d = Digest('warned')\n    for i in range(25):\n        d.warn('warning %02d' % i)\n    return d.finish()\n", to: repo.appendingPathComponent(".canvas/lens.py"))
        let warned = try ingest([repo.path, "--scan", handScan(kept)], with: script, environment: env)
        expectEqual(warned.status, 0, warned.output + warned.error)
        let file = try lastRun(in: kept).appendingPathComponent("lens-warnings.txt")
        expect(warned.error.contains("lens: warning 19\n") && !warned.error.contains("lens: warning 20") && warned.error.contains("lens: and 5 more warnings (all 25: \(file.path))"), warned.error)
        expectEqual(try String(contentsOf: file, encoding: .utf8).split(separator: "\n").count, 25)

        // the scan says what the index left out: a source file no project took in (one config file in .js a project took in doesn't make the
        // scripts in .js sources), and packages whose declared dependencies on each other it has no use of
        let tree = try makeRepository("tree", in: folder, files: [
            "packages/a/package.json": #"{"name": "@x/a", "dependencies": {"@x/b": "1", "@x/c": "1"}}"#,
            "packages/b/package.json": #"{"name": "@x/b", "dependencies": {"@x/c": "1"}}"#,
            "packages/c/package.json": #"{"name": "@x/c"}"#,
            "packages/a/src/a.ts": "export const a = 1\n", "packages/b/src/b.ts": "export const b = 1\n", "packages/c/src/c.ts": "export const c = 1\n",
            "packages/d/src/d.ts": "export const d = 1\n", "packages/a/src/a.test.ts": "it('works')\n",
            "jest.config.js": "module.exports = {}\n", "scripts/release.js": "run()\n", "scripts/clean.js": "run()\n"])
        let said = try run(URL(fileURLWithPath: python), ["-B", "-c", """
            import sys
            sys.path.insert(0, sys.argv[1])
            from scip_read import not_indexed, unconnected
            ix = {'documents': [{'path': 'packages/%s/src/%s.ts' % (p, p)} for p in 'abc'] + [{'path': 'jest.config.js'}]}
            paths = {'@x/a': 'packages/a/src', '@x/b': 'packages/b/src', '@x/c': 'packages/c/src'}
            print(not_indexed(sys.argv[2], ix))
            print(unconnected(sys.argv[2], paths, {}))
            print(unconnected(sys.argv[2], paths, {'@x/a': {'@x/b'}}))
            """, ingestSkill("scanners").path, tree.path])
        expectEqual(said.status, 0, said.error)
        let lines = said.output.split(separator: "\n").map(String.init)
        expectEqual(lines.first, "scan: not in the index: 1 of the commit's 4 .ts files, tests aside (no project the indexer read takes them in), in packages/d/src (1)")
        expect(lines.count == 3 && lines[1].hasPrefix("scan: the index barely connects the packages: of the 3 dependencies their package.json files declare on each other, the index found a use of 0."), "\(lines)")
        expectEqual(lines.last, "None", "a fifth of them used is enough")
    },

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

    test("prepare runs in the checkout when a lockfile of the commit, or the command, has changed, and not for any other move") {
        let folder = try scratchFolder("prepare")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("cache")
        let (script, log) = try stubbedSkill(in: folder)
        let counter = folder.appendingPathComponent("prepare.count"), ready = folder.appendingPathComponent("ready")
        let repo = try makeRepository("repo", in: folder, files: ["package-lock.json": "{\"v\": 1}\n", "web/app.js": "1\n"])
        @MainActor func commit(_ files: [String: String]) throws -> String {
            for (path, text) in files { try write(text, to: repo.appendingPathComponent(path)); try git(repo, ["add", path]) }
            try git(repo, ["commit", "-q", "-m", files.keys.sorted().joined(separator: " ")])
            return try git(repo, ["rev-parse", "HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let kept = try cacheFolder(of: repo, cache: cache, with: script)
        let settings = repo.appendingPathComponent(".canvas/ingest.json")
        // the counter is outside the checkout: what git doesn't know is removed with each move
        func configure(_ prepare: String) throws {
            try write(#"{"scanner": "scip", "scip": "echo made > {index}", "prepare": "\#(prepare)"}"#, to: settings)
        }
        try configure("echo run >> \(counter.path)")
        let env = environment(cache: cache, extra: ["STUB_LOG": log.path])
        func runs() -> Int { ((try? String(contentsOf: counter, encoding: .utf8)) ?? "").split(separator: "\n").count }
        @MainActor func ingestIt(_ more: [String] = [], status: Int32 = 0) throws -> ProcessOutput {
            let done = try ingest([repo.path] + more, with: script, environment: env)
            expectEqual(done.status, status, done.output + done.error)
            return done
        }
        func prepared() -> Bool { FileManager.default.fileExists(atPath: kept.appendingPathComponent("checkout.prepared").path) }

        _ = try ingestIt()
        expectEqual(runs(), 1, "the first time")
        expect(prepared(), "and the stamp is beside the checkout")
        _ = try commit(["web/app.js": "2\n"])
        let quiet = try ingestIt()
        expectEqual(runs(), 1, "a commit that changes no lockfile")
        expect(quiet.output.contains("not preparing"), quiet.output)
        _ = try commit(["package-lock.json": "{\"v\": 2}\n"])
        _ = try ingestIt()
        expectEqual(runs(), 2, "a lockfile changed")
        _ = try commit(["web/yarn.lock": "# yarn\n"])
        _ = try ingestIt()
        expectEqual(runs(), 3, "a lockfile at depth, added")
        _ = try commit(["api/requirements-dev.txt": "requests==1\n"])
        _ = try ingestIt()
        expectEqual(runs(), 4, "requirements*.txt at depth")
        _ = try commit(["go.mod": "module x\n", "notes/lock.txt": "x\n", "web/package-lock.json.bak": "x\n"])
        _ = try ingestIt()
        expectEqual(runs(), 4, "files that are not lockfiles")
        let sameCommit = try ingestIt(["--rescan"])
        expectEqual(runs(), 4, "the same commit scanned again: nothing it reads has changed. \(sameCommit.output)")

        // the command is part of it
        try configure("echo run again >> \(counter.path)")
        _ = try ingestIt(["--rescan"])
        expectEqual(runs(), 5, "another command")
        // a prepare that fails stops the run and leaves no stamp, so the next run tries it again though no lockfile has changed since
        try configure("echo failing >> \(counter.path); [ -f \(ready.path) ]")
        _ = try commit(["package-lock.json": "{\"v\": 3}\n"])
        let failed = try ingestIt(status: 1)
        expect(failed.error.contains("prepare"), failed.error)
        expectEqual(runs(), 6)
        try write("", to: ready)
        _ = try ingestIt()
        expectEqual(runs(), 7, "tried again")
        _ = try ingestIt(["--rescan"])
        expectEqual(runs(), 7, "and then it holds")
        // a checkout made again has nothing prepared in it
        try FileManager.default.removeItem(at: kept.appendingPathComponent("checkout/.git/HEAD"))
        _ = try ingestIt(["--rescan"])
        expectEqual(runs(), 8, "a new checkout is prepared")
        // the other lockfiles and manifests, and a path that git would quote (a space, a quote, letters outside ASCII)
        var most = 8
        for path in ["package.json", "api/Cargo.lock", "go.sum", "php/composer.lock", "py/Pipfile.lock", "jvm/gradle.lockfile", "bun/bun.lock",
                     "we b/ünï \"quoted\"/Gemfile.lock"] {
            _ = try commit([path: "one\n"])
            _ = try ingestIt()
            most += 1
            expectEqual(runs(), most, "\(path) is a file prepare reads")
            _ = try commit([path: "two\n"])
            _ = try ingestIt()
            most += 1
            expectEqual(runs(), most, "and \(path), changed, has it run again")
        }
    },

    test("the default lens makes the digest its fixtures hold but for how it names nodes: every fixture scan, and the overrides a spec.py gave") {
        // the digests and words are checked in (Fixtures/ingest-lens), first the old lens's, then the default lens's once the About note went,
        // when it gave every title out once in the whole digest. It gives each out once in its container now, so a file is titled by its
        // name, however many others have it. The new digest is the fixture's: the same nodes in the same order with every field the same but
        // the title, the id (a node whose title another has gets one) and the container, as the same node; the same edges, naming the
        // same nodes; and a title changed only by one of three rules (namingReport), each said where it was used
        let folder = try scratchFolder("parity")
        defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try makeRepository("project", in: folder)
        let long = "@my-company/" + String(repeating: "very-long-package-name-", count: 4) + "x"
        let scans = ["tiny": tinyModel, "awkward": awkwardModel(long: long, big: false), "awkward-big": awkwardModel(long: long, big: true)]
        // the rules a title may change by are three (namingReport); the fixtures use two: a band that a module has the name of, and a frame that
        // a module's card has the name of, still give way to the card, whose title is the digest's alone (the third rule, "a (…) fallback
        // gone", would be one of them taking its own name)
        let byName = "a file's name in place of a longer end of its path", byNumber = "a number gone"
        let changed: [String: [String: Int]] = ["tiny": [:], "awkward": [byName: 5, byNumber: 1], "awkward-big": [byName: 7, byNumber: 1]]
        for (name, scan) in scans.sorted(by: { $0.key < $1.key }) {
            let scanFile = folder.appendingPathComponent("\(name).scan.json")
            try write(scan, to: scanFile)
            let after = try lensRunner(repo, scan: scanFile, digest: folder.appendingPathComponent("\(name).new.json"))
            expectEqual(after.status, 0, after.output + after.error)
            let report = try namingReport(folder.appendingPathComponent("\(name).new.json"), against: lensFixture(name, "digest.json"))
            expectEqual(report.problems, [], "\(name): the digest differs from its fixture's but by titles, ids and the references that name them")
            expectEqual(report.rules, changed[name], "\(name): the titles that changed, by the rule that explains each")
            // what it said of the code on standard error, it says still, but for the titles it reworded
            for line in try String(contentsOf: lensFixture(name, "said"), encoding: .utf8).split(separator: "\n") where line.hasPrefix("lens: ") && !line.contains(" is titled \"") {
                expect(after.error.contains(line), "\(name): \(line) is said by the lens: \(after.error)")
            }
        }
        // a spec.py's names (BANDS, GROUPS, PURPOSES, FOLDER_BOARDS, BY_MODULE, LAYER_NAMES and TITLE, as the old lens read them), as the
        // arguments of default.digest
        let scanFile = folder.appendingPathComponent("tiny.scan.json")
        let specRepo = try makeRepository("spec", in: folder)
        try write("""
            from lenskit import default

            def digest(scan, repo):
                return default.digest(scan, repo, bands=[("Apps", ["App", "Ghost"]), ("Foundations", ["Core"])],
                                      groups={"App": [("Screens", ["Screen.swift"], [])]},
                                      purposes={"App": "Draws the screens @[x]", "Core": "Keeps the models", "Nowhere": "x"},
                                      folder_boards={"Core": ["Hidden"]}, by_module=[("Core", "Store.swift")],
                                      layer_names={"x": "y"}, title="Spec title")
            """, to: specRepo.appendingPathComponent(".canvas/lens.py"))
        let lensed = try lensRunner(specRepo, scan: scanFile, digest: folder.appendingPathComponent("spec.new.json"),
                                    lens: specRepo.appendingPathComponent(".canvas/lens.py"))
        expectEqual(lensed.status, 0, lensed.output + lensed.error)
        let specReport = try namingReport(folder.appendingPathComponent("spec.new.json"), against: lensFixture("spec", "digest.json"))
        expectEqual(specReport.problems, [], "the overrides make the same digest")
        expectEqual(specReport.rules, [:], "and name every node as it was named")
        let specified = try String(contentsOf: lensFixture("spec", "said"), encoding: .utf8)
        for said in ["Ghost", "Nowhere", "Hidden", "leave out Main.swift"] {
            expect(lensed.error.contains(said) && specified.contains(said), "said by both: \(said)\n\(specified)\n\(lensed.error)")
        }
        // an argument the default lens has not got is a TypeError that says which are
        try write("from lenskit import default\n\ndef digest(scan, repo):\n    return default.digest(scan, repo, colour='red')\n", to: specRepo.appendingPathComponent(".canvas/typo.py"))
        let typo = try lensRunner(specRepo, scan: scanFile, digest: folder.appendingPathComponent("typo.json"), lens: specRepo.appendingPathComponent(".canvas/typo.py"))
        expectEqual(typo.status, 1, typo.output)
        expect(typo.error.contains("colour") && typo.error.contains("bands, purposes"), typo.error)
    },

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

    test("a lens that gives two digests is refused, naming where they differ and the usual causes: a set of strings, the clock, the environment") {
        let folder = try scratchFolder("refused")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("cache")
        let (script, log) = try stubbedSkill(in: folder)
        let repo = try makeRepository("repo", in: folder)
        let kept = try cacheFolder(of: repo, cache: cache, with: script)
        try putScan(tinyModel, in: kept)
        let env = environment(cache: cache, extra: ["STUB_LOG": log.path])
        let lens = repo.appendingPathComponent(".canvas/lens.py")
        let cases: [(name: String, lens: String, says: [String])] = [
            ("a set of strings", """
                def digest(scan, repo):
                    names = {"alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa", "lambda", "mu"}
                    return {"title": "T", "nodes": [{"title": n} for n in names], "edges": []}
                """, ["two different digests", "node that differs is number 1", "a set"]),
            ("the clock", """
                import time
                def digest(scan, repo):
                    return {"title": "T", "nodes": [{"title": "made", "text": str(int(time.time()))}], "edges": []}
                """, ["two different digests", "\"made\"", "the clock"]),
            ("the date", """
                import datetime
                def digest(scan, repo):
                    return {"title": "T", "nodes": [{"title": "made", "text": str(datetime.date.today())}], "edges": []}
                """, ["two different digests", "the clock"]),
            ("datetime.now", """
                from datetime import datetime
                def digest(scan, repo):
                    return {"title": "T", "nodes": [], "edges": [{"from": "a", "to": "b", "text": datetime.now().isoformat()}]}
                """, ["two different digests", "first edge that differs is number 1"]),
            ("strftime without a time", """
                import time
                def digest(scan, repo):
                    return {"title": "T", "nodes": [{"title": "made", "text": time.strftime("%Y")}], "edges": []}
                """, ["two different digests", "the clock"]),
            ("asctime", """
                import time
                def digest(scan, repo):
                    return {"title": "T", "nodes": [{"title": "made", "text": time.asctime()}], "edges": []}
                """, ["two different digests", "the clock"]),
            ("ctime", """
                import time
                def digest(scan, repo):
                    return {"title": "T", "nodes": [{"title": "made", "text": time.ctime()}], "edges": []}
                """, ["two different digests", "the clock"]),
            ("localtime", """
                import time
                def digest(scan, repo):
                    return {"title": "T", "nodes": [{"title": "made", "text": str(time.localtime().tm_year)}], "edges": []}
                """, ["two different digests", "the clock"]),
            ("gmtime", """
                import time
                def digest(scan, repo):
                    return {"title": "T", "nodes": [{"title": "made", "text": str(time.gmtime().tm_year)}], "edges": []}
                """, ["two different digests", "the clock"]),
            ("the real-time clock", """
                import time
                def digest(scan, repo):
                    return {"title": "T", "nodes": [{"title": "made", "text": str(int(time.clock_gettime(time.CLOCK_REALTIME)))}], "edges": []}
                """, ["two different digests", "the clock"]),
            ("the environment", """
                import os
                def digest(scan, repo):
                    return {"title": "T", "nodes": [{"title": "home", "text": os.environ["HOME"]}], "edges": []}
                """, ["two different digests", "the environment", "HOME"]),
            ("the current folder", """
                import os
                def digest(scan, repo):
                    return {"title": "T", "nodes": [{"title": "here", "text": os.getcwd()}], "edges": []}
                """, ["two different digests"]),
        ]
        for (name, text, says) in cases {
            try write(text, to: lens)
            let refused = try ingest([repo.path, "--scan", handScan(kept)], with: script, environment: env)
            expectEqual(refused.status, 1, "\(name): \(refused.output)")
            for word in says { expect(refused.error.contains(word), "\(name) is refused saying \(word): \(refused.error)") }
            expect(!driverCalls(log).contains { $0.hasPrefix("all ") }, "\(name): nothing was drawn")
            expect(!FileManager.default.fileExists(atPath: try lastRun(in: kept).appendingPathComponent("digest.json").path), "\(name): no digest was kept")
        }
        // the same lens with its set sorted is accepted, and writes the digest the run keeps
        try write("""
            def digest(scan, repo):
                names = {"alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa", "lambda", "mu"}
                return {"title": "T", "nodes": [{"title": n} for n in sorted(names)], "edges": []}
            """, to: lens)
        let accepted = try ingest([repo.path, "--scan", handScan(kept)], with: script, environment: env)
        expectEqual(accepted.status, 0, accepted.output + accepted.error)
        expectEqual(try json(lastRun(in: kept).appendingPathComponent("digest.json"))["nodes"]?.arrayValue?.count, 12)
        // a digest without its basic shape is refused before anything is drawn
        for (text, says) in [("def digest(scan, repo):\n    return [1]\n", "not a dict"), ("def digest(scan, repo):\n    return {\"nodes\": [], \"edges\": []}\n", "\"title\""),
                             ("def digest(scan, repo):\n    return {\"title\": \"T\", \"nodes\": {}, \"edges\": []}\n", "\"nodes\""),
                             ("def digest(scan, repo):\n    return {\"title\": \"T\", \"nodes\": [{\"title\": \"a\", \"x\": {1}}], \"edges\": []}\n", "JSON"),
                             ("x = 1\n", "no function digest")] {
            try write(text, to: lens)
            let refused = try ingest([repo.path, "--scan", handScan(kept)], with: script, environment: env)
            expectEqual(refused.status, 1, refused.output)
            expect(refused.error.contains(says), "\(text) is refused saying \(says): \(refused.error)")
        }
        expect(!driverCalls(log).contains { $0.hasPrefix("all ") && $0.contains("--mess") && false }, "")
    },

    test("a lens that raises stops the run with its traceback, before anything is drawn") {
        let folder = try scratchFolder("raises")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("cache")
        let (script, log) = try stubbedSkill(in: folder)
        let repo = try makeRepository("repo", in: folder)
        let kept = try cacheFolder(of: repo, cache: cache, with: script)
        try putScan(tinyModel, in: kept)
        try write("def digest(scan, repo):\n    raise ValueError('the lens broke on ' + scan.name)\n", to: repo.appendingPathComponent(".canvas/lens.py"))
        let broken = try ingest([repo.path, "--scan", handScan(kept)], with: script, environment: environment(cache: cache, extra: ["STUB_LOG": log.path]))
        expectEqual(broken.status, 1, broken.output)
        expect(broken.error.contains("Traceback") && broken.error.contains("ValueError: the lens broke on TinyPackage") && broken.error.contains("lens.py"), broken.error)
        expect(!driverCalls(log).contains { $0.hasPrefix("all ") }, "nothing was drawn: \(driverCalls(log))")
        expect(!FileManager.default.fileExists(atPath: try lastRun(in: kept).appendingPathComponent("digest.json").path), "and no digest was written")
        expect(!FileManager.default.fileExists(atPath: kept.appendingPathComponent("lock").path), "the lock is freed")
    },

    test("repo reads the commit and never the working tree; the lens is the checkout's, never the commit's; and a spec.py is refused") {
        let folder = try scratchFolder("repo")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("cache")
        let (script, log) = try stubbedSkill(in: folder)
        let repo = try makeRepository("repo", in: folder, files: ["notes.txt": "committed\n", "src/a.txt": "a", "src/deep/b.txt": "b", "src/deep/c.md": "c", "x y/space.txt": "s"])
        func lens(_ title: String) -> String {
            """
            import json
            def digest(scan, repo):
                seen = {"notes": repo.read("notes.txt"), "all": repo.files(), "deep": repo.files("src/**/*.txt"), "top": repo.files("*.txt"),
                        "any": repo.files("**/*.md"), "one": repo.files("src/*"), "gone": repo.exists("src/a.txt"), "new": repo.exists("untracked.txt"),
                        "bytes": len(repo.read_bytes("notes.txt")), "sha": len(repo.commit)}
                try:
                    repo.read("untracked.txt")
                except FileNotFoundError:
                    seen["missing"] = True
                return {"title": "\(title)", "seen": json.dumps(seen), "nodes": [], "edges": []}
            """
        }
        let lensFile = repo.appendingPathComponent(".canvas/lens.py")
        try write(lens("committed lens"), to: lensFile)
        try git(repo, ["add", "-A"])
        try git(repo, ["commit", "-q", "-m", "a lens"])
        let kept = try cacheFolder(of: repo, cache: cache, with: script)
        try putScan(tinyModel, in: kept)
        // edits no commit holds: a file changed, one added, one removed, and the lens itself
        try write("edited\n", to: repo.appendingPathComponent("notes.txt"))
        try write("new", to: repo.appendingPathComponent("untracked.txt"))
        try FileManager.default.removeItem(at: repo.appendingPathComponent("src/a.txt"))
        try write(lens("working lens"), to: lensFile)
        let env = environment(cache: cache, extra: ["STUB_LOG": log.path])
        let ran = try ingest([repo.path, "--scan", handScan(kept)], with: script, environment: env)
        expectEqual(ran.status, 0, ran.output + ran.error)
        let digest = try json(lastRun(in: kept).appendingPathComponent("digest.json"))
        expectEqual(digest["title"], "working lens", "the lens is the checkout's, whatever the commit holds")
        let seen = try JSON(text: digest["seen"]?.stringValue ?? "{}")
        expectEqual(seen["notes"], "committed\n", "the file as committed, not as edited")
        expectEqual(seen["gone"], true, "a file removed from the working tree is still in the commit")
        expectEqual(seen["new"], false, "and one that was never committed is not")
        expectEqual(seen["bytes"], 10)
        expectEqual(seen["sha"], 40)
        expectEqual(seen["missing"], true, "reading what the commit lacks raises FileNotFoundError")
        let paths = (seen["all"]?.arrayValue ?? []).compactMap(\.stringValue)
        expectEqual(paths, [".canvas/lens.py", "README.md", "notes.txt", "src/a.txt", "src/deep/b.txt", "src/deep/c.md", "x y/space.txt"], "the commit's paths, sorted")
        expectEqual((seen["deep"]?.arrayValue ?? []).compactMap(\.stringValue), ["src/a.txt", "src/deep/b.txt"], "** crosses folders, and matches none")
        expectEqual((seen["top"]?.arrayValue ?? []).compactMap(\.stringValue), ["notes.txt"], "* stays in a folder")
        expectEqual((seen["any"]?.arrayValue ?? []).compactMap(\.stringValue), ["README.md", "src/deep/c.md"])
        expectEqual((seen["one"]?.arrayValue ?? []).compactMap(\.stringValue), ["src/a.txt"])

        // a spec.py is the old way: refused before anything is asked of the app, saying where its names go
        try write("TITLE = 'x'\n", to: repo.appendingPathComponent(".canvas/spec.py"))
        let calls = driverCalls(log).count
        let refused = try ingest([repo.path, "--scan", handScan(kept)], with: script, environment: env)
        expectEqual(refused.status, 1, refused.output)
        expect(refused.error.contains("spec.py") && refused.error.contains(".canvas/lens.py") && refused.error.contains("lenskit.default.digest"), refused.error)
        expectEqual(driverCalls(log).count, calls, "the driver was not asked")
    },

    test("lenskit's readers: YAML (block and flow, quoted, comments, block scalars; refusing anchors, tags, documents) and SQL (CREATE TABLE and ALTER TABLE, skipping the rest)") {
        let folder = try scratchFolder("readers")
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("readers.py")
        try write(readersScript(skill: ingestSkill().path), to: script)
        let done = try run(URL(fileURLWithPath: python), ["-s", "-B", script.path], timeout: 60)
        expectEqual(done.status, 0, done.output + done.error)
        let out = try JSON(text: done.output)
        let compose = try require(out["compose"], done.output)
        expectEqual(compose["version"], "3.8", "a quoted string stays text")
        expectEqual(compose["services"]?["web"]?["image"], "nginx:1.2", "a trailing comment is not the value")
        expectEqual(compose["services"]?["web"]?["ports"], ["80:80", 443], "a quoted number is text, a plain one a number")
        expectEqual(compose["services"]?["web"]?["environment"]?.arrayValue?.last, ["B": "two", "C": [1, 2, ["x": "y"]]], "a mapping in a list, a flow list and mapping inside it")
        expectEqual(compose["services"]?["web"]?["command"], "echo hi\necho there\n", "a literal block scalar")
        expectEqual(compose["services"]?["web"]?["note"], "one two three\n", "a folded one")
        expectEqual(compose["services"]?["web"]?["flag"], true)
        expectEqual(compose["services"]?["web"]?["empty"], .null)
        expectEqual(compose["services"]?["web"]?["words"], ["yes", "on", "no"], "yes and on are text, as in YAML 1.2")
        expectEqual(compose["services"]?["db"], ["image": "pg", "size": 3.5, "quoted": "it's # not a comment"], "a flow mapping, a float, a # inside quotes")
        expectEqual(compose["list"], ["a", "b", ["nested"], .null], "a list at its key's indent, a nested list, an empty item")
        expectEqual(compose["after"], "last", "and a key after a block scalar")
        for label in ["anchor", "alias", "tag", "documents", "flow", "twice", "tab", "indent", "complex", "merge", "plain"] {
            expect(out["refused"]?[label]?.stringValue?.hasPrefix("line ") == true, "\(label) is refused, naming its line: \(out["refused"]?[label] ?? .null)")
        }
        expect(out["refused"]?["anchor"]?.stringValue?.contains("anchor") == true && out["refused"]?["documents"]?.stringValue?.contains("more than one document") == true)
        expectEqual(out["single_document"], ["a": 1], "one document with its --- is read")

        let tables = try require(out["tables"], done.output)
        expectEqual(tables["users"]?["columns"]?.arrayValue?.compactMap { $0["name"]?.stringValue }, ["id", "email", "created", "tags", "name", "age"], "CREATE TABLE's columns, then ALTER TABLE ... ADD COLUMN's")
        expectEqual(tables["users"]?["columns"]?.arrayValue?.compactMap { $0["type"]?.stringValue }, ["bigserial", "character varying(255)", "timestamp with time zone", "text[]", "text", "int"])
        expectEqual(tables["users"]?["columns"]?.arrayValue?.compactMap { $0["nullable"]?.boolValue }, [false, false, true, true, false, true], "NOT NULL and PRIMARY KEY say not null")
        expectEqual(tables["users"]?["columns"]?.arrayValue?.first?["primary_key"], true)
        expectEqual(tables["orders"]?["columns"]?.arrayValue?.compactMap { $0["name"]?.stringValue }, ["id", "uid"], "a column dropped, one renamed")
        expectEqual(tables["orders"]?["columns"]?.arrayValue?.first?["primary_key"], true, "a table-level PRIMARY KEY (id)")
        expectEqual(tables["app.audit"]?["columns"]?.arrayValue?.count, 1, "a schema before the name is kept (public. is none)")
        expectEqual(out["table_names"], ["users", "orders", "app.audit", "renamed"], "tables in the order created; dropped ones gone, a rename kept")
    },

    test("a codebase of 5,000 files is drawn as at most 4,000 notes: folders are collapsed deepest first, then biggest, then by path, their edges merged up to weight 4") {
        let folder = try scratchFolder("scale")
        defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try makeRepository("repo", in: folder)
        let scan = folder.appendingPathComponent("scan.json"), digest = folder.appendingPathComponent("digest.json")
        try write(bigScan(modules: 50, folders: 5, subfolders: 4, files: 5), to: scan)
        let made = try lensRunner(repo, scan: scan, digest: digest)
        expectEqual(made.status, 0, made.output + made.error)
        let json = try json(digest)
        let nodes = json["nodes"]?.arrayValue ?? [], edges = json["edges"]?.arrayValue ?? []
        let notes = nodes.filter { $0["kind"] == "sticky-note" }
        expectEqual(notes.count, 4000, "5,000 files, 250 folders of five collapsed to a note each")
        expect(made.error.contains("250 folders were collapsed"), "the warning says how many: \(made.error)")
        let titles = Set(notes.compactMap { $0["title"]?.stringValue })
        expect(titles.contains("Mod00/d0/s0/"), "the first folders by path are collapsed, titled for the folder: \(titles.sorted().prefix(3))")
        expect(titles.contains("Mod12/d2/s1/") && !titles.contains("Mod12/d2/s2/"), "250 folders end in Mod12's tenth: \(titles.filter { $0.hasPrefix("Mod12/") }.sorted())")
        expect(notes.contains { $0["source"] == "src/Mod12/d2/s2/File0.ts" } && notes.contains { $0["source"] == "src/Mod49/d4/s3/File4.ts" }, "and the files of the rest are notes of their own")
        let collapsed = try require(notes.first { $0["title"] == "Mod00/d0/s0/" }, "a collapsed folder's note")
        let text = collapsed["text"]?.stringValue ?? ""
        expect(text.hasPrefix("5 files, 50 lines") && text.contains("File3.ts: Thing3"), "its text lists its files and what each declares: \(text)")
        expectEqual(collapsed["source"], "src/Mod00/d0/s0", "and says what it was made from")
        expect(edges.allSatisfy { ($0["weight"]?.intValue ?? 1) >= 1 && ($0["weight"]?.intValue ?? 1) <= 4 }, "merged weights stop at 4")
        expect(edges.contains { $0["weight"]?.intValue == 4 }, "and reach it")
        // a title is given out once in its container: File0.ts is in every folder, and its note is told apart by an id, which names it in an edge
        let naming = try namingReport(digest)
        expectEqual(naming.problems, [], "every title is its container's alone, an id is where a title repeats, and every edge has its ends")
        expect(notes.filter { $0["id"] != nil }.count > 3000, "the files of one name in many folders have ids: \(notes.filter { $0["id"] != nil }.count)")
        expect(notes.filter { $0["title"] == "File0.ts" }.count > 500, "and keep the name they have in their folder")
        let pairs = edges.map { "\($0["from"]?.stringValue ?? "") > \($0["to"]?.stringValue ?? "")" }
        expectEqual(Set(pairs).count, pairs.count, "and one edge to a pair of ends")
        // canvas-digest's own check finds nothing wrong
        let checked = try run(URL(fileURLWithPath: "/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc"),
                              [URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".claude/skills/canvas-digest/tool/main.js").path, "--", "check", digest.path],
                              timeout: 240)
        expectEqual(checked.status, 0, String(checked.output.prefix(2000)) + checked.error)
        expectEqual(try JSON(text: checked.output)["errors"], .array([]), "check finds nothing wrong")
        // the lens's CPU time, the two runs and git's, is held to a budget: the processes' own, never the wall clock
        let cpu = made.output.range(of: #"[0-9.]+(?= s of cpu)"#, options: .regularExpression).flatMap { Double(made.output[$0]) }
        expect((cpu ?? 1000) < 8, "the lens ran twice in \(cpu.map { "\($0)" } ?? "an unknown time") s of cpu: \(made.output)")
        // a scan that fits is not touched
        let small = folder.appendingPathComponent("small.json")
        try write(bigScan(modules: 4, folders: 2, subfolders: 2, files: 3), to: small)
        let kept = try lensRunner(repo, scan: small, digest: folder.appendingPathComponent("small.digest.json"))
        expectEqual(kept.status, 0, kept.output + kept.error)
        expect(!kept.error.contains("collapsed"), kept.error)
    },

    test("the collapse rule: folders of two files or more, the deepest first, then the biggest, then by path, until at most the most are left") {
        let folder = try scratchFolder("collapse")
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("collapse.py")
        try write("""
            import json, sys
            sys.path.insert(0, \(pythonString(ingestSkill().path)))
            from lenskit import default
            rels = ["x/y/1", "x/y/2", "x/y/3", "x/1", "x/2", "p/1", "p/2", "p/3", "p/4", "1", "2"]
            files = {("A", r): None for r in rels}
            files[("B", "q/1")] = None
            files[("B", "q/2")] = None
            out = {}
            for most in (13, 12, 9, 8, 7, 6, 5, 1):
                out[str(most)] = [list(f) for f in default.collapse(files, most)]
            print(json.dumps(out))
            """, to: script)
        let done = try run(URL(fileURLWithPath: python), ["-s", "-B", script.path], timeout: 60)
        expectEqual(done.status, 0, done.output + done.error)
        let out = try JSON(text: done.output)
        func folders(_ most: String) -> [String] { (out[most]?.arrayValue ?? []).map { ($0.arrayValue ?? []).compactMap(\.stringValue).joined(separator: ":") } }
        expectEqual(folders("13"), [], "13 files fit in 13")
        expectEqual(folders("12"), ["A:x/y"], "one over: the deepest folder")
        expectEqual(folders("9"), ["A:x/y", "A:p"], "then, at one depth, the one with more files (p has four, x two)")
        expectEqual(folders("8"), ["A:x/y", "A:p"], "and it stops as soon as the notes fit")
        expectEqual(folders("7"), ["A:x/y", "A:p", "A:x"], "then equal depth and size: by path, A's x before B's q")
        expectEqual(folders("6"), ["A:x/y", "A:p", "A:x", "B:q"])
        expectEqual(folders("5"), ["A:x/y", "A:p", "A:x", "B:q", "A:"], "a module's own files last")
        expectEqual(folders("1"), ["A:x/y", "A:p", "A:x", "B:q", "A:"], "and when that is not enough, all of them (a folder of one file saves nothing)")
    },

    test("the SQL and YAML readers on the words, strings and shapes that used to fool them, and a chain of modules a recursion could not hold") {
        let folder = try scratchFolder("readers-gaps")
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("gaps.py")
        try write(gapsScript(skill: ingestSkill().path), to: script)
        let done = try run(URL(fileURLWithPath: python), ["-s", "-B", script.path], timeout: 60)
        expectEqual(done.status, 0, done.output + done.error)
        let out = try JSON(text: done.output)
        func strings(_ key: String) -> [String] { (out[key]?.arrayValue ?? []).compactMap(\.stringValue) }
        // a column named for a word that can start a constraint is a column
        expectEqual(strings("key_columns"), ["key:text:not null:pk", "value:text:null"], "key text PRIMARY KEY")
        expectEqual(strings("soft_words"), ["index:int:null", "period:text:null", "exclude:bool:null", "fulltext:text:null", "like:varchar(9):null"], "and the constraints beside them are none")
        expectEqual(strings("alter_key"), ["a:int:null", "key:text:null", "index:int:null"], "ADD key text, ADD COLUMN index int; ADD INDEX and ADD KEY are none")
        // a string is read before a comment
        expectEqual(strings("dashes"), ["a:text:null", "b:int:not null"], "DEFAULT '--' keeps the rest of its line")
        expectEqual(strings("slash"), ["t", "u"], "DEFAULT '/*' with a real comment after it: both tables")
        expectEqual(strings("dollar"), ["t", "u"], "DEFAULT '$$' and a real $$ body")
        expectEqual(strings("dollar_columns"), ["a:text:null", "b:int:null"])
        expectEqual(strings("comments"), ["a:text:null", "b:int:null"], "comments between the pieces of a definition")
        // what says a column is not null
        expectEqual(strings("check"), ["x:int:null", "y:int:not null", "z:int:null"], "CHECK (x IS NOT NULL) says nothing of x; NOT NULL does")
        expectEqual(strings("alter_column"), ["x:bigint:not null", "y:text:not null:pk"], "ALTER COLUMN SET NOT NULL, TYPE (USING), SET DATA TYPE, and DROP NOT NULL on a primary key")
        expectEqual(strings("t_sql"), ["x:varchar(10):not null"], "T-SQL's ALTER COLUMN x varchar(10) NOT NULL")
        expectEqual(strings("unicode"), ["naïve:int:null", "größe:text:null"], "letters outside ASCII stay in a name")
        expectEqual(out["unicode_table"], true)
        expectEqual(strings("after"), ["a:int:null", "b:int:null", "c:text:null"], "AFTER x and FIRST are no part of a type")
        expectEqual(strings("temp"), ["d"], "a temporary table is none")
        expectEqual(strings("modify"), ["a:bigint:not null", "c:text:null"], "MODIFY and CHANGE define a column again, in its place")
        // YAML
        expectEqual(out["bom"], ["key": 1, "other": 2], "a byte order mark is no part of the first key")
        expectEqual(out["keep"], ["a": "x\n\n\n", "b": "y\n", "c": "z", "d": 1], "|+ keeps the blank lines, | clips them, |- strips the line break")
        expectEqual(out["keep_end"], ["a": "x\n\n"], "and at the end of the text")
        expect(out["escape"]?.stringValue?.hasPrefix("line 1: ") == true && out["escape"]?.stringValue?.contains("U00110000") == true, "an escape that is no character is a YamlError naming its line: \(out["escape"] ?? .null)")
        expectEqual(out["surrogate"]?.stringValue?.hasPrefix("line 1: "), true)
        // a chain of 500 modules, the first the deepest user: a level for each, with no recursion
        expectEqual(out["chain"], [499, 0], "levels of a reverse-ordered chain")
        expectEqual(out["levels"], ["A": 1, "B": 1, "C": 0, "D": 2], "a cycle shares a level")
    },

    test("a lens's own modules come first and the skill's are not importable by name; the clock a lens reads keeps isinstance true and every reading of it moves; Repo keeps no root to read") {
        let folder = try scratchFolder("lens-imports")
        defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try makeRepository("repo", in: folder)
        let scan = folder.appendingPathComponent("scan.json"), digest = folder.appendingPathComponent("digest.json")
        try write(tinyModel, to: scan)
        let lens = folder.appendingPathComponent("lens/lens.py")
        try write("WHO = \"the lens's own settings\"\n", to: folder.appendingPathComponent("lens/settings.py"))
        try write("""
            import datetime, importlib.util, json, settings
            from lenskit import default

            def digest(scan, repo):
                d = default.digest(scan, repo)
                said = {
                    "who": settings.WHO,
                    "skill_modules": [name for name in ("stamp", "run", "child", "ingest", "scanners") if importlib.util.find_spec(name) is not None],
                    "has_root": hasattr(repo, "root"),
                    "now_is_date": isinstance(datetime.datetime.now(), datetime.date),
                    "today_is_date": isinstance(datetime.date.today(), datetime.date),
                    "today_is_datetime": isinstance(datetime.date.today(), datetime.datetime),
                    "made_is_datetime": isinstance(datetime.datetime(2020, 1, 2), datetime.datetime),
                    "made_is_date": isinstance(datetime.datetime(2020, 1, 2), datetime.date),
                    "sum_is_datetime": isinstance(datetime.datetime.now() + datetime.timedelta(days=1), datetime.datetime),
                    "subclass": issubclass(datetime.datetime, datetime.date),
                    "json": json.dumps({"t": datetime.datetime(2020, 1, 2, 3, 4, 5)}, default=lambda o: o.isoformat() if isinstance(o, datetime.date) else None),
                }
                d["said"] = json.dumps(said, sort_keys=True)
                return d
            """, to: lens)
        let made = try lensRunner(repo, scan: scan, digest: digest, lens: lens)
        expectEqual(made.status, 0, made.output + made.error)
        let said = try JSON(text: try require(try json(digest)["said"]?.stringValue, "what the lens said"))
        expectEqual(said["who"], "the lens's own settings", "a helper beside the lens, named as one of the skill's, is the lens's")
        expectEqual(said["skill_modules"], [], "and none of the skill's is importable by its name")
        expectEqual(said["has_root"], false, "Repo has no root to read")
        for key in ["now_is_date", "today_is_date", "made_is_datetime", "made_is_date", "sum_is_datetime", "subclass"] {
            expectEqual(said[key], true, "\(key)")
        }
        expectEqual(said["today_is_datetime"], false)
        expectEqual(said["json"], #"{"t": "2020-01-02T03:04:05"}"#, "a default= hook that asks isinstance(x, datetime.date) is called")
        // settings.py is a program, not a module: importing it runs nothing
        let imported = try run(URL(fileURLWithPath: python), ["-s", "-B", "-c", "import sys; sys.path.insert(0, \(pythonString(ingestSkill().path))); import settings; print(settings.KEYS[0])"])
        expectEqual(imported.status, 0, imported.output + imported.error)
        expectEqual(imported.output.trimmingCharacters(in: .whitespacesAndNewlines), "scanner")
    },

    test("a codebase of 30,000 files in 2,000 modules is drawn in the time a person waits: no board looks at every file or every module to find its own") {
        let folder = try scratchFolder("many-modules")
        defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try makeRepository("repo", in: folder)
        let scan = folder.appendingPathComponent("scan.json"), digest = folder.appendingPathComponent("digest.json")
        try write(bigScan(modules: 2000, folders: 1, subfolders: 1, files: 15), to: scan)
        let made = try lensRunner(repo, scan: scan, digest: digest)
        expectEqual(made.status, 0, made.output + made.error)
        expectEqual(try json(digest)["nodes"]?.arrayValue?.filter { $0["kind"] == "subboard" }.count, 2000, "a card for each module")
        let cpu = made.output.range(of: #"[0-9.]+(?= s of cpu)"#, options: .regularExpression).flatMap { Double(made.output[$0]) }
        expect((cpu ?? 1000) < 12, "the lens ran twice in \(cpu.map { "\($0)" } ?? "an unknown time") s of cpu (it took ten times that, a run, when each module looked through every file): \(made.output)")
    },

    test("a repository's long command is stopped with the run: a signal frees the lock at once, and nothing it started is left running") {
        let folder = try scratchFolder("stopped")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("cache")
        let (script, log) = try stubbedSkill(in: folder)
        let repo = try makeRepository("repo", in: folder)
        let kept = try cacheFolder(of: repo, cache: cache, with: script)
        let begun = folder.appendingPathComponent("begun")
        try write(#"{"scanner": "scip", "scip": "echo made > {index}", "prepare": "echo begun > \#(begun.path); sleep 47"}"#, to: repo.appendingPathComponent(".canvas/ingest.json"))
        let slow = Process()
        slow.executableURL = script
        slow.arguments = [repo.path]
        slow.environment = ProcessInfo.processInfo.environment.merging(environment(cache: cache, extra: ["STUB_LOG": log.path])) { _, new in new }
        try slow.run()
        defer { if slow.isRunning { slow.terminate() } }
        let waitUntil = Date(timeIntervalSinceNow: 90)
        while !FileManager.default.fileExists(atPath: begun.path), Date() < waitUntil { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        expect(FileManager.default.fileExists(atPath: begun.path), "prepare began")
        expect(FileManager.default.fileExists(atPath: kept.appendingPathComponent("lock").path), "the lock is held while it runs")
        let signalled = Date()
        // the signal goes to ingest alone (Process.terminate reaches what it waits for too, as a terminal's does)
        _ = try run(URL(fileURLWithPath: "/bin/kill"), ["-TERM", "\(slow.processIdentifier)"])
        let deadline = Date(timeIntervalSinceNow: 30)
        while slow.isRunning, Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
        expect(!slow.isRunning && Date().timeIntervalSince(signalled) < 15, "ingest ended at the signal, not when prepare did: \(Date().timeIntervalSince(signalled)) s")
        if !slow.isRunning { expectEqual(slow.terminationStatus, 143) }
        expect(!FileManager.default.fileExists(atPath: kept.appendingPathComponent("lock").path), "the lock is freed")
        let left = try run(URL(fileURLWithPath: "/usr/bin/pgrep"), ["-f", "sleep 47"])
        expectEqual(left.status, 1, "the sleep prepare started is gone: \(left.output)")
    },
])

/// A package whose product is a list of plugins, written as this repository's is: the table of what ships, a module a plugin is in
/// (Kit, on Core), an app made of the list that names no plugin, and its tests, made of the list too unless `testsShip` is false.
private func listedPackage(testsShip: Bool) -> String {
    """
    // swift-tools-version: 5.9
    import PackageDescription

    let ships = [
        // the one plugin
        "Kit.KitPlugin",
    ]
    let shipped = ships.map { Target.Dependency(stringLiteral: String($0.prefix { $0 != "." })) }

    let package = Package(name: "Listed", targets: [
        .target(name: "Core"),
        .target(name: "Kit", dependencies: ["Core"]),
        .executableTarget(name: "App", dependencies: ["Core"] + shipped),
        .testTarget(name: "AppTests", dependencies: ["Core"]\(testsShip ? " + shipped" : "")),
    ])

    """
}

/// A package of three modules and a test target, as `Package.swift` declares them: Kit depends on Core, KitTests on Kit, and Loose
/// (when asked for) on nothing.
private func tinyPackage(loose: Bool) -> String {
    let targets = [#".target(name: "Core")"#, #".target(name: "Kit", dependencies: ["Core"])"#] + (loose ? [#".target(name: "Loose")"#] : [])
        + [#".testTarget(name: "KitTests", dependencies: ["Kit"])"#]
    return "// swift-tools-version: 5.9\nimport PackageDescription\n\nlet package = Package(name: \"Tiny\", targets: [\n"
        + targets.map { "    \($0),\n" }.joined() + "])\n"
}

/// A codebase whose names are awkward, as a scanner writes the scan: a module called what a band is ("Level 1"), ones with a
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

/// Two modules, App over Core, as a scanner writes the scan: App's Main.swift and Screen.swift use Core's Store.swift.
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

/// A lens that is the default lens with overrides: a band for each layer (one module it names is not there), and App's frame.
private let tinyLens = """
from lenskit import default

def digest(scan, repo):
    return default.digest(scan, repo, bands=[("Apps", ["App", "Ghost"]), ("Foundations", ["Core"])],
                          groups={"App": [("Screens", ["Screen.swift"], [])]})
"""

/// A Python string literal for `text`.
private func pythonString(_ text: String) -> String {
    "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

/// A scan of `modules` modules, each with `folders` folders of `subfolders` folders of `files` files (`d0/s0/File0.ts`), as a scanner writes it:
/// each file declares a type and uses three others, one in the next file's place, with more names the later it is.
private func bigScan(modules: Int, folders: Int, subfolders: Int, files: Int) -> String {
    func q(_ s: String) -> String { "\"" + s + "\"" }
    var moduleLines: [String] = [], fileLines: [String] = [], keys: [(module: String, rel: String)] = []
    for i in 0..<modules {
        let name = "Mod" + String(format: "%02d", i)
        var rels: [String] = []
        for f in 0..<folders { for s in 0..<subfolders { for n in 0..<files { rels.append("d\(f)/s\(s)/File\(n).ts") } } }
        keys += rels.map { (name, $0) }
        moduleLines.append(#"{"name": \#(q(name)), "path": \#(q("src/" + name)), "deps": [\#(i > 0 ? q("Mod" + String(format: "%02d", i - 1)) : "")], "test": false, "layer": null, "files": [\#(rels.map(q).joined(separator: ", "))], "lines": \#(10 * rels.count), "doc": "", "folders": {}}"#)
        for (n, rel) in rels.enumerated() {
            fileLines.append(#"{"module": \#(q(name)), "rel": \#(q(rel)), "path": \#(q("src/\(name)/\(rel)")), "lines": 10, "doc": "", "api": true, "decls": [{"name": "Thing\#(n % files)", "kind": "type", "visibility": "public", "line": 1}]}"#)
        }
    }
    var useLines: [String] = []
    let count = keys.count
    for g in 0..<count {
        for target in [(g * 7 + 13) % count, (g * 31 + 5) % count, (g + 1) % count] where target != g {
            let names = (0..<(g % 5 + 1)).map { q("Thing\($0)") }
            useLines.append(#"{"from": [\#(q(keys[g].module)), \#(q(keys[g].rel))], "to": [\#(q(keys[target].module)), \#(q(keys[target].rel))], "names": [\#(names.joined(separator: ", "))]}"#)
        }
    }
    return #"{"language": "typescript", "name": "Big", "modules": [\#(moduleLines.joined(separator: ",\n"))], "files": [\#(fileLines.joined(separator: ",\n"))], "uses": [\#(useLines.joined(separator: ",\n"))]}"#
}

/// A Python script that reads the SQL, the YAML and the module levels that used to go wrong, and prints what it made, as JSON.
private func gapsScript(skill: String) -> String {
    #"""
    import json, sys
    sys.path.insert(0, \#(pythonString(skill)))
    from lenskit import derive, sql, yaml

    def table(text, name):
        found = sql.tables(text).get(name)
        return None if found is None else [f"{c.name}:{c.type}:{'null' if c.nullable else 'not null'}{':pk' if c.primary_key else ''}" for c in found.columns]

    out = {}
    out["key_columns"] = table("CREATE TABLE settings (key text PRIMARY KEY, value text)", "settings")
    out["soft_words"] = table("CREATE TABLE t (index int, period text, exclude bool, fulltext text, like varchar(9), key idx_k (index), INDEX i2 (index), "
                              "EXCLUDE USING gist (period WITH =), PERIOD FOR SYSTEM_TIME (a, b), FULLTEXT KEY ft (fulltext), LIKE other INCLUDING ALL)", "t")
    out["alter_key"] = table("CREATE TABLE t (a int); ALTER TABLE t ADD key text, ADD COLUMN index int, ADD INDEX i (a), ADD KEY k (a)", "t")
    out["dashes"] = table("CREATE TABLE t (a text DEFAULT '--', b int NOT NULL); -- a real comment\n", "t")
    out["slash"] = list(sql.tables("CREATE TABLE t (a text DEFAULT '/*', b int);\n/* a real one */\nCREATE TABLE u (x int);"))
    dollar = "CREATE TABLE t (a text DEFAULT '$$', b int); CREATE FUNCTION f() RETURNS int AS $$ CREATE TABLE inside (z int); $$ LANGUAGE sql; CREATE TABLE u (x int);"
    out["dollar"] = list(sql.tables(dollar))
    out["dollar_columns"] = table(dollar, "t")
    out["comments"] = table("CREATE TABLE t (a text DEFAULT 'x' -- note\n, b int /* the b */);", "t")
    out["check"] = table("CREATE TABLE t (x int CHECK (x IS NOT NULL), y int NOT NULL CHECK (y > 0), z int DEFAULT (1))", "t")
    out["alter_column"] = table("CREATE TABLE t (x int, y int PRIMARY KEY); ALTER TABLE t ALTER COLUMN x SET NOT NULL, ALTER COLUMN y DROP NOT NULL; "
                                "ALTER TABLE t ALTER COLUMN x TYPE bigint USING x::bigint; ALTER TABLE t ALTER y SET DATA TYPE text", "t")
    out["t_sql"] = table("CREATE TABLE t (x int); ALTER TABLE t ALTER COLUMN x varchar(10) NOT NULL", "t")
    out["unicode"] = table('CREATE TABLE "größe" (naïve int, größe text)', "größe")
    out["unicode_table"] = "größe" in sql.tables('CREATE TABLE "größe" (naïve int)')
    out["after"] = table("CREATE TABLE t (a int); ALTER TABLE t ADD COLUMN b int NULL AFTER a, ADD c text FIRST", "t")
    out["temp"] = list(sql.tables("CREATE TEMP TABLE a (x int); CREATE TEMPORARY TABLE b (x int); CREATE GLOBAL TEMPORARY TABLE c (x int); CREATE TABLE d (x int);"))
    out["modify"] = table("CREATE TABLE t (a int, b int NOT NULL); ALTER TABLE t MODIFY a bigint NOT NULL, CHANGE COLUMN b c text", "t")

    out["bom"] = yaml.load("﻿key: 1\nother: 2\n")
    out["keep"] = yaml.load("a: |+\n  x\n\n\nb: |\n  y\n\n\nc: |-\n  z\n\nd: 1\n")
    out["keep_end"] = yaml.load("a: |+\n  x\n\n")
    for label, text in (("escape", 'a: "\\U00110000"'), ("surrogate", 'a: "\\ud800"')):
        try:
            yaml.load(text)
            out[label] = "NOT REFUSED"
        except yaml.YamlError as e:
            out[label] = str(e)
        except Exception as e:
            out[label] = "NOT A YamlError: " + type(e).__name__

    n = 500
    prod = ["M%d" % i for i in range(n)]
    mods = {m: {"deps": ["M%d" % (i + 1)] if i + 1 < n else []} for i, m in enumerate(prod)}
    levels = derive.levels(prod, mods)
    out["chain"] = [levels["M0"], levels["M%d" % (n - 1)]]
    cycle = {"A": {"deps": ["B"]}, "B": {"deps": ["A", "C"]}, "C": {"deps": []}, "D": {"deps": ["A", "C"]}}
    out["levels"] = derive.levels(list(cycle), cycle)
    print(json.dumps(out))
    """#
}

/// A Python script that reads YAML and SQL with lenskit's readers and prints what they made, as JSON.
private func readersScript(skill: String) -> String {
    #"""
    import json, sys
    sys.path.insert(0, \#(pythonString(skill)))
    from lenskit import sql, yaml

    compose = yaml.load("""
    # a comment
    version: "3.8"
    services:
      web:
        image: nginx:1.2   # a trailing comment
        ports:
          - "80:80"
          - 443
        environment:
          - A=1
          - B: two
            C: [1, 2, {x: y}]
        command: |
          echo hi
          echo there
        note: >
          one
          two
          three
        flag: true
        empty:
        words: [yes, on, no]
      db: {image: pg, size: 3.5, quoted: 'it''s # not a comment'}
    list:
    - a
    - b
    -
      - nested
    -
    after: last
    """)

    refused = {}
    for label, text in {
        "anchor": "a: &x 1", "alias": "a: *x", "tag": "a: !!str b", "documents": "a: 1\n---\nb: 2", "flow": "a: [1,\n 2]",
        "twice": "a: 1\na: 2", "tab": "a:\n\tb: 1", "indent": "a:\n  b: 1\n c: 2", "complex": "? x\n: y", "merge": "<<: z",
        "plain": "a: one\n  two",
    }.items():
        try:
            yaml.load(text)
            refused[label] = "NOT REFUSED"
        except yaml.YamlError as e:
            refused[label] = str(e)

    found = sql.tables(["""
    -- users, and their orders
    CREATE TABLE IF NOT EXISTS public.users (
      id bigserial PRIMARY KEY,
      email character varying(255) NOT NULL UNIQUE,
      created timestamp with time zone DEFAULT now(),
      tags text[],
      CONSTRAINT positive CHECK (id > 0)
    );
    CREATE INDEX users_email ON users (email);
    CREATE TABLE "orders" (id int, user_id int REFERENCES users (id), amount numeric(10, 2) NOT NULL, PRIMARY KEY (id));
    INSERT INTO users (email) VALUES ('a;b');
    CREATE FUNCTION f() RETURNS int AS $$ BEGIN CREATE TABLE inside (a int); END $$ LANGUAGE plpgsql;
    CREATE TABLE soon_gone (a int);
    """, """
    ALTER TABLE users ADD COLUMN IF NOT EXISTS name text NOT NULL, ADD COLUMN age int;
    ALTER TABLE orders DROP COLUMN amount;
    ALTER TABLE orders RENAME COLUMN user_id TO uid;
    DROP TABLE IF EXISTS soon_gone;
    CREATE TABLE view_like AS SELECT 1;
    ALTER TABLE never_created ADD COLUMN x int;
    CREATE TABLE app.audit (id int);
    CREATE TABLE temp_name (b int);
    ALTER TABLE temp_name RENAME TO renamed;
    """])

    print(json.dumps({
        "compose": compose, "refused": refused, "single_document": yaml.load("---\na: 1\n"),
        "tables": {k: {"columns": [{"name": c.name, "type": c.type, "nullable": c.nullable, "primary_key": c.primary_key} for c in t.columns]} for k, t in found.items()},
        "table_names": list(found),
    }))
    """#
}

/// A Python script that reads a digest as canvas-digest does, and prints, as JSON, the problems with how it names its nodes (see
/// `namingReport`) and, given the digest an older default lens made too, how it differs from that one by the rules of titles.
private let namingScript = #"""
import json, re, sys

RULES = ("a file's name in place of a longer end of its path", "a (…) fallback gone", "a number gone")


def spaced(title):
    return ' '.join(title.split())


problems, used = [], {}
new = json.load(open(sys.argv[1], encoding='utf-8'))
nodes, edges = new['nodes'], new['edges']

# what a reference names: a node's id, else the one node that has that title (None: no node, or several)
ids, titles = {}, {}
for position, node in enumerate(nodes):
    if 'id' in node:
        ids.setdefault(node['id'], []).append(position)
    titles.setdefault(spaced(node['title']), []).append(position)


def at(reference, by_id=ids, by_title=titles):
    if len(by_id.get(reference, [])) == 1:
        return by_id[reference][0]
    return by_title[spaced(reference)][0] if len(by_title.get(spaced(reference), [])) == 1 else None


# a title is unique in its container (spaces folded, case aside); a node has an id exactly when another node has its title, ids are
# unique, and a reference names a node by its id where it has one, else by its title
held = {}
for position, node in enumerate(nodes):
    container = at(node['in']) if 'in' in node else -1
    if 'in' in node and container is None:
        problems.append(f"node {position} ({node['title']!r}) is in {node['in']!r}, which names no one node")
    key = (container, spaced(node['title']).lower())
    if key in held:
        problems.append(f"nodes {held[key]} and {position} are both called {node['title']!r} in one container")
    held[key] = position
    if ('id' in node) != (len(titles[spaced(node['title'])]) > 1):
        problems.append(f"node {position} ({node['title']!r}) " + ("has an id, though no other node has its title" if 'id' in node else "lacks an id, though another node has its title"))
if any(len(positions) > 1 for positions in ids.values()):
    problems.append("two nodes have one id")


def named(position):
    return nodes[position].get('id', nodes[position]['title'])


for position, node in enumerate(nodes):
    if 'in' in node and at(node['in']) is not None and node['in'] != named(at(node['in'])):
        problems.append(f"node {position}: its in is {node['in']!r}, which is not how its container is named ({named(at(node['in']))!r})")
for position, edge in enumerate(edges):
    for end in ('from', 'to'):
        target = at(edge[end])
        if target is None:
            problems.append(f"edge {position}: its {end} {edge[end]!r} names no one node")
        elif edge[end] != named(target):
            problems.append(f"edge {position}: its {end} is {edge[end]!r}, which is not how its node is named ({named(target)!r})")

if len(sys.argv) > 2:
    old = json.load(open(sys.argv[2], encoding='utf-8'))
    old_nodes, old_edges = old['nodes'], old['edges']
    for key in sorted(set(old) | set(new)):
        if key not in ('nodes', 'edges') and old.get(key) != new.get(key):
            problems.append(f"the digest's {key} differs")
    if (len(old_nodes), len(old_edges)) != (len(nodes), len(edges)):
        problems.append(f"{len(old_nodes)} nodes and {len(old_edges)} edges became {len(nodes)} and {len(edges)}")
        print(json.dumps({'problems': problems, 'rules': used}))
        sys.exit(0)
    old_titles = {}
    for position, node in enumerate(old_nodes):
        old_titles.setdefault(spaced(node['title']), []).append(position)
    old_at = lambda reference: at(reference, {}, old_titles)

    # the rules by which the title `was` may have become `now`, each at most once, in this order; None if no rules do
    def rules(was, now, source):
        steps = [(was, [])]
        number = re.fullmatch(r'(.*) \(\d+\)', was)
        if number:
            steps.append((number.group(1), [RULES[2]]))
        for title, by in list(steps):
            fallback = re.fullmatch(r'(.*?) \([^()]*\)', title)
            if fallback and not re.fullmatch(r'.* \(\d+\)', title):
                steps.append((fallback.group(1), by + [RULES[1]]))
        name = source.rsplit('/', 1)[-1] if source else None
        for title, by in list(steps):
            if name and (title == name or title.endswith('/' + name)):
                steps.append((name, by + [RULES[0]]))
        return next((by for title, by in steps if title == now), None)

    for position, (was, now) in enumerate(zip(old_nodes, nodes)):
        rest_was = {k: v for k, v in was.items() if k not in ('title', 'in', 'source')}
        rest_now = {k: v for k, v in now.items() if k not in ('title', 'in', 'id', 'source')}
        if json.dumps(rest_was) != json.dumps(rest_now):
            problems.append(f"node {position} ({was['title']!r}): a field but its title, id and container differs: {json.dumps(rest_was)[:160]} became {json.dumps(rest_now)[:160]}")
        if ('in' in was) != ('in' in now) or ('in' in was and old_at(was['in']) != at(now['in'])):
            problems.append(f"node {position} ({was['title']!r}) is in another node than before")
        if was['title'] != now['title']:
            by = rules(was['title'], now['title'], now.get('source'))
            if by is None:
                problems.append(f"node {position}: the title {was['title']!r} became {now['title']!r}, which no rule explains")
            for rule in by or []:
                used[rule] = used.get(rule, 0) + 1
    for position, (was, now) in enumerate(zip(old_edges, edges)):
        if json.dumps({k: v for k, v in was.items() if k not in ('from', 'to')}) != json.dumps({k: v for k, v in now.items() if k not in ('from', 'to')}):
            problems.append(f"edge {position}: a field but its ends differs")
        for end in ('from', 'to'):
            if old_at(was[end]) != at(now[end]):
                problems.append(f"edge {position} ({was['from']!r} to {was['to']!r}): its {end} names another node than before")
print(json.dumps({'problems': problems, 'rules': used}))
"""#

/// A Python script that builds small digests with lenskit's `Digest` and prints what they are and what was refused, as JSON.
private func builderScript(skill: String) -> String {
    #"""
    import json, sys
    sys.path.insert(0, \#(pythonString(skill)))
    from lenskit import Digest, Titles

    def refused(call):
        try:
            call()
            return "NOT REFUSED"
        except ValueError as e:
            return str(e)

    out = {}
    a, b, c = {"title": "A"}, {"title": "B"}, {"title": "C"}

    # a title is given out once in its container, case aside and spaces folded, and may repeat in another
    said = []
    titles = Titles(said.append)
    out["container"] = [titles.claim("x", "index.ts", within=a), titles.claim("y", "index.ts", within=b), titles.claim("z", "Index.ts", within=a),
                        titles.claim("w", "  index.ts ", "other.ts", within=a)]
    out["container_said"] = said

    # with no container, one scope for all: the digest's titles each given out once, as before
    said = []
    titles = Titles(said.append)
    out["whole"] = [titles.claim("x", "Core"), titles.claim("y", "core", "core (layer)"), titles.claim("z", "CORE"), titles.claim("w", "Core")]
    out["whole_said"] = said
    out["whole_taken"] = sorted(titles.taken)

    # alone: the title is the digest's, in every container, whichever claim comes first
    said = []
    titles = Titles(said.append)
    out["alone"] = [titles.claim("the card Core", "Core", alone=True), titles.claim("band", "core", "core (layer)", within=a), titles.claim("frame", "CORE", "x", within=b),
                    titles.claim("card2", "Core", "Core (2)", alone=True)]
    out["alone_said"] = said
    out["alone_after"] = [titles.claim("note", "Shared", within=a), titles.claim("card", "shared", "shared (card)", alone=True)]

    # type: unique among types in any container, and no matter to a shape that is no type
    said = []
    titles = Titles(said.append)
    out["types"] = [titles.claim("t1", "Table", within=a, type=True), titles.claim("n", "Table", within=b), titles.claim("t2", "TABLE", "TABLE (type)", within=c, type=True)]
    out["types_said"] = said

    # within is a node, or the title of the one node that has it
    d = Digest("by title")
    band = d.frame("Band")
    one, two = d.frame("One", band), d.frame("Two", band)
    d.frame("Dup", one)
    d.frame("Dup", two)
    out["by_title"] = [d.claim("c", "x", within="One"), d.claim("c", "x", within="Two"), d.claim("c", "x", within="One")]
    out["unknown"] = refused(lambda: d.claim("c", "x", within="Nowhere"))
    out["ambiguous"] = refused(lambda: d.claim("c", "x", within="Dup"))

    # titles that are all unique: the digest is as it was written, whether a lens named a node by its title or passed the node
    d = Digest("plain")
    frame = d.frame("F", rank=0)
    n = d.note("N", "F", "words", source="n.py")
    m = d.note("M", frame)
    d.edge("N", frame)
    d.edge(m, n, 2)
    out["plain"] = d.finish()

    # a title two nodes have: an id for each, and every reference to either is its id
    d = Digest("shop")
    top = d.frame("Top", rank=0)
    app = d.subboard("app", top, "App")
    lib = d.subboard("lib", top, "Lib")
    f1 = d.note(d.claim("f", "index.ts", within=app), app, "one", source="app/index.ts")
    f2 = d.note(d.claim("f", "index.ts", within=lib), lib, "two", source="lib/index.ts")
    only = d.note("Only", lib, "three")
    d.edge(f1, f2, 2)
    d.edge(f2, "Only")
    d.edge("Only", f1, text="back")
    d.edge(only, lib)
    done = d.finish()
    out["digest"] = done
    out["again"] = d.finish() == done

    # refused: a title several nodes have, named by that string; a node of another digest; two types of one title
    d = Digest("bad")
    p, q = d.frame("P"), d.frame("Q")
    d.note("Same", p)
    d.note("Same", q)
    d.edge("Same", "P")
    out["ambiguous_ref"] = refused(d.finish)
    d = Digest("foreign")
    d.note("Here")
    d.edge(Digest("other").note("Elsewhere"), "Here")
    out["foreign"] = refused(d.finish)
    d = Digest("types")
    p, q = d.frame("P"), d.frame("Q")
    d.note("Table", p, schema={"type": "object"})
    d.note("Table", q, schema={"type": "object"})
    out["two_types"] = refused(d.finish)

    # an id a lens gave stays; a title that is another node's id needs one; ids that would be one get a number
    d = Digest("ids")
    p, q = d.frame("P"), d.frame("Q")
    a1 = d.note("X", p, id="mine")
    a2 = d.note("X", q)
    a3 = d.note("mine", q)
    a4 = d.note("Y", q, id="Y  in P")
    a5 = d.note("Y", p)
    d.edge(a1, a2)
    d.edge(a3, a4)
    d.edge(a2, a5)
    out["ids"] = [[node["title"], node.get("id", "-"), node.get("in", "-")] if "in" in node else [node["title"]] for node in d.finish()["nodes"]]
    out["id_edges"] = [[e["from"], e["to"]] for e in d.edges]

    # ids sort as titles do: of two nodes whose titles differ, the smaller title has the smaller key (its id, else its title), so a
    # row the digest orders by key stays in title order (printable titles, which have spaces folded, as the digest's own are)
    import random
    rng = random.Random(7)
    alphabet = [chr(code) for code in range(0x20, 0x7f)] + list("éüß…λ中")
    def made():
        return " ".join("".join(rng.choice(alphabet) for _ in range(rng.randint(1, 5))).split()) or "x"
    broken = 0
    for _ in range(60):
        d = Digest("order")
        frames = [d.frame(made()) for _ in range(3)]
        for _ in range(40):
            d.note(made(), rng.choice(frames))
        d.finish()
        keys = [(node["title"], node.get("id", node["title"])) for node in d.nodes if node["kind"] == "sticky-note"]
        broken += sum(1 for a in keys for b in keys if a[0] < b[0] and not a[1] < b[1])
    out["order_broken"] = broken
    print(json.dumps(out, indent=1))
    """#
}
