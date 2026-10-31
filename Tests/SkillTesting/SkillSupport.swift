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

/// The newest run's folder: its `digest.json`, and the driver's `out/`.
@MainActor public func lastRun(in cacheFolder: URL) throws -> URL { try require(runFolders(in: cacheFolder).last, "no run was kept in \(cacheFolder.path)") }

/// The lens runner as `ingest` runs it (`runner/run.py`): the repository's lens, else the default lens, run twice in isolation.
@MainActor public func lensRunner(_ repo: URL, scan: URL, digest: URL, lens: URL? = nil, timeout: TimeInterval = 280) throws -> ProcessOutput {
    try run(URL(fileURLWithPath: python), [ingestSkill("runner/run.py").path, repo.path, scan.path, digest.path] + (lens.map { ["--lens", $0.path] } ?? []), timeout: timeout)
}

/// How the digest at `digest` names its nodes, read as canvas-digest reads them (`namingScript`): the problems it finds, none when every
/// title is unique in its container (spaces folded, case aside), a node has an `id` exactly where another node has its title, ids are
/// unique, and each `in`, `from` and `to` names its node by its id where it has one, else by its title. Given `old`, a digest from
/// when titles were given out once in the whole digest, also the ways it differs from that one which the rules of titles don't
/// explain (the same nodes in the same order, every field but the title, the id and the container the same, the same edges in the
/// same order, each reference naming the node it named), and how often each rule changed a title: "a file's name in place of a longer
/// end of its path", "a (…) fallback gone", "a number gone"; any other change of a title is a problem.
@MainActor public func namingReport(_ digest: URL, against old: URL? = nil) throws -> (problems: [String], rules: [String: Int]) {
    let done = try run(URL(fileURLWithPath: python), ["-c", namingScript, digest.path] + (old.map { [$0.path] } ?? []), timeout: 120)
    expectEqual(done.status, 0, done.error)
    let report = try JSON(text: done.output)
    return ((report["problems"]?.arrayValue ?? []).compactMap(\.stringValue), (report["rules"]?.objectValue ?? [:]).compactMapValues(\.intValue))
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
