import CanvasRPC
import Foundation
import TestKit

// What the tests of the skills (.claude/skills/canvas-digest and canvas-ingest) share, whichever executable they are in:
// SkillToolsTests, whose tests never start the app, and CompositionTests, whose tests draw into it. The skills' folders, scratch
// git repositories and a cache for `ingest` to keep its runs in, `ingest` and the lens runner as an agent runs them, and the two
// scans the tests of both draw from. It imports no plugin: a test of the tools must not be rerun by an edit to one.

/// The Python the skills run under.
public let python = "/usr/bin/python3"

/// The system's jsc, the runtime the canvas-digest tool is built for.
public let jsc = "/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc"

/// The canvas-digest skill's folder, or a path in it, absolute (tests run from the repository's root).
public func digestSkill(_ path: String = "") -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".claude/skills/canvas-digest").appendingPathComponent(path)
}

/// The canvas-ingest skill's folder, or a path in it, absolute (tests run from the repository's root).
public func ingestSkill(_ path: String = "") -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".claude/skills/canvas-ingest").appendingPathComponent(path)
}

/// A worked example's folder, or a path in it, absolute (`.claude/skills/canvas-ingest/examples`).
public func example(_ path: String = "", in name: String = "orders") -> URL {
    ingestSkill("examples/\(name)").appendingPathComponent(path)
}

public func json(_ url: URL) throws -> JSON { try JSON(text: String(contentsOf: url, encoding: .utf8)) }

/// The app's kinds as the canvas-digest tool reads them (`canvas kinds`, through the tool's `extract kinds`), which the tool's own tests read the
/// kinds by, and so does a test that runs the tool with no app. CompositionTests' DigestTests hold it to what the app answers.
public func digestKinds() -> URL { digestSkill("tool/test/fixtures/kinds.json") }

/// The canvas-digest tool's `check` of the digest at `digest`, under jsc, over the app's kinds as the tool reads them (`digestKinds()`).
@MainActor public func digestCheck(_ digest: URL, timeout: TimeInterval = 240) throws -> ProcessOutput {
    try run(URL(fileURLWithPath: jsc), [digestSkill("tool/main.js").path, "--", "check", digest.path, "--kinds", digestKinds().path], timeout: timeout)
}

/// A new folder in this user's temporary folder, named for the test that makes it; the test removes it.
public func scratchFolder(_ name: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SkillTests-\(UUID().uuidString)-\(name)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// A path with every link in it resolved, as `git` and `ingest` give it (Foundation's `resolvingSymlinksInPath` leaves /private off).
public func realPath(_ url: URL) -> String {
    guard let resolved = realpath(url.path, nil) else { return url.path }
    defer { free(resolved) }
    return String(cString: resolved)
}

public func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

/// `git` on a scratch repository, with no configuration of the user's (a commit needs none, and signs nothing).
@MainActor @discardableResult public func git(_ repo: URL, _ arguments: [String]) throws -> ProcessOutput {
    let done = try run(URL(fileURLWithPath: "/usr/bin/git"),
                       ["-C", repo.path, "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"] + arguments,
                       environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"], timeout: 60)
    expectEqual(done.status, 0, "git \(arguments.joined(separator: " ")): \(done.output)\(done.error)")
    return done
}

/// A scratch git repository named `name` in `folder`, with `files` (path in the repository: text) committed.
@MainActor public func makeRepository(_ name: String, in folder: URL, files: [String: String] = [:]) throws -> URL {
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

/// The environment `ingest` runs in: its own cache, and the app's command server's socket when there is one (else a socket nothing answers).
@MainActor public func ingestEnvironment(cache: URL, socket: String? = nil, extra: [String: String] = [:]) -> [String: String] {
    var environment = ["CANVAS_CLI": builtExecutable("CanvasCLI").path, "CANVAS_SOCKET": socket ?? temporarySocketPath(), "CANVAS_INGEST_CACHE": cache.path,
                       "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
    for (key, value) in extra { environment[key] = value }
    return environment
}

/// `ingest <arguments>` as an agent runs it.
@MainActor public func ingest(_ arguments: [String], with ingest: URL = ingestSkill("ingest"), environment: [String: String], timeout: TimeInterval = 280) throws -> ProcessOutput {
    try run(ingest, arguments, environment: environment, timeout: timeout)
}

/// The folder `ingest` keeps a repository's scan, index, runs and drawing records in.
@MainActor public func cacheFolder(of repo: URL, cache: URL, with script: URL = ingestSkill("ingest")) throws -> URL {
    let where_ = try ingest([repo.path, "--where"], with: script, environment: ingestEnvironment(cache: cache))
    expectEqual(where_.status, 0, where_.output + where_.error)
    return URL(fileURLWithPath: where_.output.trimmingCharacters(in: .whitespacesAndNewlines))
}

/// A scan written by hand (beside the cache's own folders), for `ingest --scan` to draw from: `handScan(cacheFolder)` is its path.
public func putScan(_ text: String, in cacheFolder: URL) throws {
    try write(text, to: cacheFolder.appendingPathComponent("hand.scan.json"))
}

public func handScan(_ cacheFolder: URL) -> String { cacheFolder.appendingPathComponent("hand.scan.json").path }

/// The runs `ingest` kept, oldest first.
public func runFolders(in cacheFolder: URL) -> [URL] {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: cacheFolder.appendingPathComponent("runs").path)) ?? []).sorted()
    return names.map { cacheFolder.appendingPathComponent("runs/\($0)") }
}

/// The newest run's folder: its `graph.json`, and the driver's `out/`.
@MainActor public func lastRun(in cacheFolder: URL) throws -> URL { try require(runFolders(in: cacheFolder).last, "no run was kept in \(cacheFolder.path)") }

/// The lens runner as `ingest` runs it (`runner/run.py`): the repository's lens, else the default lens, run twice in isolation, the graph
/// document written to `graph`. The drawing is named `repo` unless the lens or `extra` (`--drawing NAME`, `--mess`, ...) names it.
@MainActor public func lensRunner(_ repo: URL, scan: URL, graph: URL, lens: URL? = nil, extra: [String] = [], timeout: TimeInterval = 280) throws -> ProcessOutput {
    try run(URL(fileURLWithPath: python), [ingestSkill("runner/run.py").path, repo.path, scan.path, graph.path, "--drawing-default", "repo"] + (lens.map { ["--lens", $0.path] } ?? []) + extra, timeout: timeout)
}

/// Two modules, App over Core, as a scanner writes the scan: App's Main.swift and Screen.swift use Core's Store.swift.
public let tinyModel = #"""
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

/// A codebase whose names are awkward, as a scanner writes the scan: a module called what a band is ("Level 1"), ones with a
/// bracket and a backslash in their names, one whose name is over 80 characters, files whose paths differ only by case, a file whose
/// name isn't whole text, a doc with an `@[` in it, and, with `big`, a module of 63 files in two folders that differ only by case and
/// a third named as another module is.
public func awkwardModel(long: String, big: Bool) -> String {
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
