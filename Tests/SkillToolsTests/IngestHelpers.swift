import CanvasRPC
import Foundation
import SkillTesting
import TestKit

// What the tests of `ingest` that never start the app share, beside SkillTesting's: a copy of the skill with a driver of its own
// that logs its arguments and draws nothing, the lens fixtures checked in, and the scans and scripts several tests run.

/// A copy of the skill with a driver of its own beside it (`<skills>/canvas-ingest`, `<skills>/canvas-digest/digest`), where `ingest`
/// looks for it: the driver logs the line of arguments it was given to the file STUB_LOG and draws nothing (with STUB_LOCK, the folder
/// of the lock, it also says whose lock is held and who its parent is; with STUB_FAIL set it refuses, as an app that isn't running does).
@MainActor func stubbedSkill(in folder: URL) throws -> (ingest: URL, log: URL) {
    let skills = folder.appendingPathComponent("skills")
    try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: ingestSkill(), to: skills.appendingPathComponent("canvas-ingest"))
    let driver = skills.appendingPathComponent("canvas-digest/digest")
    try write("#!/bin/sh\necho \"$*\" >> \"$STUB_LOG\"\n[ -z \"${STUB_LOCK:-}\" ] || echo \"held $(cat \"$STUB_LOCK/pid\" 2>/dev/null) by $PPID\" >> \"$STUB_LOG\"\n[ -z \"${STUB_FAIL:-}\" ] || exit 1\nexit 0\n", to: driver)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: driver.path)
    return (skills.appendingPathComponent("canvas-ingest/ingest"), folder.appendingPathComponent("driver.log"))
}

/// How many of a commit's objects a partial clone hasn't fetched: its files, and a treeless clone's folders.
@MainActor func unfetched(_ clone: URL, _ sha: String) throws -> Int {
    try git(clone, ["rev-list", "--objects", "--missing=print", "--no-walk", sha]).output.split(separator: "\n").filter { $0.hasPrefix("?") }.count
}

/// A script of Python kept in Scripts/ beside these tests, run as the tests ran them when they were written out for each run: without the
/// user's site packages or a byte-code cache (-s, -B), and given the canvas-ingest skill's folder, where lenskit is.
@MainActor func pythonScript(_ name: String, arguments: [String] = [], environment: [String: String] = [:], timeout: TimeInterval = 60) throws -> ProcessOutput {
    let script = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/SkillToolsTests/Scripts/\(name)")
    return try run(URL(fileURLWithPath: python), ["-s", "-B", script.path, ingestSkill().path] + arguments, environment: environment, timeout: timeout)
}

/// The lines the stub driver logged.
func driverCalls(_ log: URL) -> [String] {
    ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
}

/// What the default lens makes of a scan: the graph document the runner writes, and what it says on standard error (its `lens:` lines).
/// `ingest-lens/<name>.graph.json` and `.said`, written by the lens test itself (CANVAS_WRITE_INGEST_LENS=1) from the scans in
/// SkillTesting (`tinyModel`, `awkwardModel`) and the overrides a spec.py once gave, never by hand.
func lensFixture(_ name: String, _ kind: String) -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/CompositionTests/Fixtures/ingest-lens/\(name).\(kind)")
}

/// A package whose product is a list of plugins, written as this repository's is: the table of what ships, a module a plugin is in
/// (Kit, on Core), an app made of the list that names no plugin, and its tests, made of the list too unless `testsShip` is false.
func listedPackage(testsShip: Bool) -> String {
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

/// A Python string literal for `text`.
func pythonString(_ text: String) -> String {
    "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

/// A scan of `modules` modules, each with `folders` folders of `subfolders` folders of `files` files (`d0/s0/File0.ts`), as a scanner writes it:
/// each file declares a type and uses three others, one in the next file's place, with more names the later it is.
func bigScan(modules: Int, folders: Int, subfolders: Int, files: Int) -> String {
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
