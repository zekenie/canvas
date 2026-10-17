import CanvasRPC
import Foundation
import TestKit

// The skills the app carries for agents: the folder `./build.sh agents <dir>` puts together (a Claude
// Code plugin marketplace holding the shipped skills), and how the canvas-digest driver finds `canvas`
// from where it is: `$CANVAS_CLI`; the app's, or a checkout's, beside it; the PATH; never the current
// folder's. Tests run from the repository's root.

private let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

private func scratch(_ name: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AgentsTests-\(UUID().uuidString)-\(name)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func write(_ text: String, to url: URL, executable: Bool = false) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
    if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
}

private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

/// Every file under a folder, as paths from it (dotfiles and the files in dot-folders included).
private func files(under folder: URL) -> [String] {
    guard let walker = FileManager.default.enumerator(atPath: folder.path) else { return [] }
    return walker.compactMap { $0 as? String }.filter { path in
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }.sorted()
}

/// `./build.sh agents <folder>`, in the repository.
@MainActor private func assemble(into folder: URL, from repository: URL = root) throws -> ProcessOutput {
    try run(URL(fileURLWithPath: "/bin/zsh"), ["-c", #"cd "$0" && exec ./build.sh agents "$1""#, repository.path, folder.path], timeout: 120)
}

@MainActor let agentsTests = Suite("agents folder and driver", [
    test("build.sh agents makes a plugin marketplace of the shipped skills: the plugin and marketplace files, each skill without its tests or dotfiles (but an example repository's .canvas), and the build id") {
        let folder = try scratch("agents")
        defer { try? FileManager.default.removeItem(at: folder) }
        let agents = folder.appendingPathComponent("agents")
        let made = try assemble(into: agents)
        expectEqual(made.status, 0, made.output + made.error)

        let marketplace = try JSON(text: try require(read(agents.appendingPathComponent(".claude-plugin/marketplace.json"))))
        expectEqual(marketplace["name"], "infinite-canvas")
        expect(marketplace["owner"]?["name"]?.stringValue?.isEmpty == false, "an owner")
        let plugins = try require(marketplace["plugins"]?.arrayValue)
        expectEqual(plugins.count, 1)
        expectEqual(plugins.first?["name"], "canvas")
        expectEqual(plugins.first?["source"], "./canvas")
        let plugin = try JSON(text: try require(read(agents.appendingPathComponent("canvas/.claude-plugin/plugin.json"))))
        expectEqual(plugin["name"], "canvas")
        // Claude Code may keep a copy of a plugin in a cache named by its version, so the version is the build: a new build is a new version.
        let id = try require(read(agents.appendingPathComponent("build-id"))).trimmingCharacters(in: .whitespacesAndNewlines)
        expectEqual(plugin["version"]?.stringValue, id, "plugin.json says the build as its version")
        expectEqual(plugins.first?["version"]?.stringValue, id, "so does the marketplace's entry")

        let skills = try FileManager.default.contentsOfDirectory(atPath: agents.appendingPathComponent("canvas/skills").path).sorted()
        for shipped in ["canvas", "canvas-digest"] { expect(skills.contains(shipped), "\(shipped) is carried: \(skills)") }
        for skill in skills { expect(exists(agents.appendingPathComponent("canvas/skills/\(skill)/SKILL.md")), "\(skill) has a SKILL.md") }

        let all = files(under: agents.appendingPathComponent("canvas/skills"))
        expect(!all.contains { $0.contains("tool/test/") }, "canvas-digest's tests stay out")
        expect(all.contains("canvas-digest/tool/vendor/elk.bundled.js"), "its vendored layout engine stays in")
        expect(all.contains("canvas-digest/digest") && all.contains("canvas-digest/tool/main.js"), "the driver and the tool are there")
        expect(FileManager.default.isExecutableFile(atPath: agents.appendingPathComponent("canvas/skills/canvas-digest/digest").path), "the driver is still a program")
        expect(!all.contains { path in
            path.split(separator: "/").contains { $0.hasPrefix(".") && !(path.hasPrefix("canvas-ingest/examples/") && $0 == ".canvas") }
        }, "no dotfiles: \(all.filter { $0.contains("/.") })")
        expect(all.contains("canvas-ingest/examples/orders/.canvas/lens.py") && all.contains("canvas-ingest/examples/orders/.canvas/ingest.json"),
               "but the example repository's settings and lens, which a repository keeps in .canvas")
        expect(!all.contains { $0.hasSuffix(".pyc") || $0.contains("__pycache__") }, "no Python caches")

        let build = try require(read(agents.appendingPathComponent("build-id"))).trimmingCharacters(in: .whitespacesAndNewlines)
        expect(!build.isEmpty && !build.contains(" "), "a build id: \(build)")
        for skill in skills { expectEqual(read(agents.appendingPathComponent("canvas/skills/\(skill)/build-id")), build + "\n", "\(skill) carries the build") }

        // Again over the same folder: made anew, with nothing left from before.
        try write("left\n", to: agents.appendingPathComponent("canvas/skills/canvas/left.txt"))
        let again = try assemble(into: agents)
        expectEqual(again.status, 0, again.output + again.error)
        expect(!exists(agents.appendingPathComponent("canvas/skills/canvas/left.txt")), "a second run empties the folder first")
        // A folder with other things in it is not emptied.
        let other = folder.appendingPathComponent("other")
        try write("mine\n", to: other.appendingPathComponent("notes.txt"))
        let refused = try assemble(into: other)
        expectEqual(refused.status, 1, refused.output)
        expect(refused.error.contains("not an agents folder"), refused.error)
        expectEqual(read(other.appendingPathComponent("notes.txt")), "mine\n")
    },
    test("build.sh agents empties a folder only if it is an agents folder this build made (the infinite-canvas marketplace and a build-id at its root); someone's own marketplace is refused whole, with its .git; an empty DIR and / are refused") {
        let folder = try scratch("guard")
        defer { try? FileManager.default.removeItem(at: folder) }
        // Another marketplace checkout: has .claude-plugin/marketplace.json, as an agents folder does.
        let theirs = folder.appendingPathComponent("theirs")
        try write("{\"name\": \"theirs\"}\n", to: theirs.appendingPathComponent(".claude-plugin/marketplace.json"))
        try write("ref: refs/heads/main\n", to: theirs.appendingPathComponent(".git/HEAD"))
        try write("mine\n", to: theirs.appendingPathComponent("README.md"))
        let refused = try assemble(into: theirs)
        expectEqual(refused.status, 1, refused.output + refused.error)
        expect(refused.error.contains("not an agents folder"), refused.error)
        expectEqual(read(theirs.appendingPathComponent("README.md")), "mine\n")
        expect(exists(theirs.appendingPathComponent(".git/HEAD")), "its .git stays")
        expect(!exists(theirs.appendingPathComponent("canvas")), "nothing is put in it")
        // The same name but no build-id: not one this build made either.
        let almost = folder.appendingPathComponent("almost")
        try write("{\"name\": \"infinite-canvas\"}\n", to: almost.appendingPathComponent(".claude-plugin/marketplace.json"))
        try write("mine\n", to: almost.appendingPathComponent("README.md"))
        let noBuild = try assemble(into: almost)
        expectEqual(noBuild.status, 1, noBuild.output + noBuild.error)
        expectEqual(read(almost.appendingPathComponent("README.md")), "mine\n")
        // An empty DIR is the root's, once made absolute; / is never written to.
        for dir in ["", "/"] {
            let result = try run(URL(fileURLWithPath: "/bin/zsh"), ["-c", #"cd "$0" && exec ./build.sh agents "$1""#, root.path, dir], timeout: 60)
            expectEqual(result.status, 1, "DIR '\(dir)': \(result.output + result.error)")
            expect(result.error.contains("agents:"), "DIR '\(dir)' is refused in words: \(result.error)")
            expect(!result.error.contains("mkdir"), "DIR '\(dir)' never reaches mkdir: \(result.error)")
        }
        expect(!exists(URL(fileURLWithPath: "/canvas")))
    },
    test("the build id is the commit, and with changes also a hash of them, the contents of untracked files included") {
        let folder = try scratch("buildid")
        defer { try? FileManager.default.removeItem(at: folder) }
        // A repository of its own, with build.sh and stub skills.
        let repository = folder.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appendingPathComponent("build.sh"), to: repository.appendingPathComponent("build.sh"))
        for skill in ["canvas", "canvas-digest", "canvas-ingest"] {
            try write("---\nname: \(skill)\ndescription: x\n---\n", to: repository.appendingPathComponent(".claude/skills/\(skill)/SKILL.md"))
        }
        @MainActor func git(_ arguments: String...) throws {
            let result = try run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", repository.path, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"] + arguments,
                                 environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"], timeout: 60)
            expectEqual(result.status, 0, result.output + result.error)
        }
        try git("init", "-q")
        try git("add", ".")
        try git("commit", "-q", "-m", "x")
        @MainActor func build(_ name: String) throws -> String {
            let out = folder.appendingPathComponent(name)
            let made = try assemble(into: out, from: repository)
            expectEqual(made.status, 0, made.output + made.error)
            return try require(read(out.appendingPathComponent("build-id"))).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let clean = try build("clean")
        expect(!clean.contains("dirty"), clean)
        try write("one\n", to: repository.appendingPathComponent("notes/new.txt"))
        let one = try build("one")
        expect(one.hasPrefix(clean + "-dirty-"), "\(one) is the commit and a hash of the changes")
        expectEqual(try build("one-again"), one, "the same changes, the same id")
        try write("two\n", to: repository.appendingPathComponent("notes/new.txt"))
        let two = try build("two")
        expect(two != one, "an untracked file's contents are in the id: \(one) and \(two)")
        // The build leaves git's index as it found it: no optional lock is taken for a status.
        expect(!exists(repository.appendingPathComponent(".git/index.lock")), "no lock is left")
    },
    test("build.sh agents keeps a .canvas folder only in canvas-ingest's examples, one folder down, and every other dotfile goes") {
        let folder = try scratch("dotcanvas")
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = folder.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appendingPathComponent("build.sh"), to: repository.appendingPathComponent("build.sh"))
        for skill in ["canvas", "canvas-digest", "canvas-ingest"] {
            try write("---\nname: \(skill)\ndescription: x\n---\n", to: repository.appendingPathComponent(".claude/skills/\(skill)/SKILL.md"))
        }
        let skills = repository.appendingPathComponent(".claude/skills")
        for path in ["canvas-ingest/examples/orders/.canvas/lens.py", "canvas-ingest/examples/orders/.canvas/ingest.json",   // kept
                     "canvas-ingest/examples/orders/deeper/.canvas/lens.py", "canvas-ingest/examples/.canvas/lens.py", "canvas-ingest/.canvas/lens.py",
                     "canvas/.canvas/lens.py", "canvas-digest/tool/.canvas/lens.py", "canvas-ingest/examples/orders/.hidden/x.txt", "canvas-ingest/examples/orders/.env"] {
            try write("x\n", to: skills.appendingPathComponent(path))
        }
        @MainActor func git(_ arguments: String...) throws {
            let result = try run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", repository.path, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"] + arguments,
                                 environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"], timeout: 60)
            expectEqual(result.status, 0, result.output + result.error)
        }
        try git("init", "-q")
        try git("add", "-A")
        try git("commit", "-q", "-m", "x")
        let out = folder.appendingPathComponent("out")
        let made = try assemble(into: out, from: repository)
        expectEqual(made.status, 0, made.output + made.error)
        let kept = files(under: out.appendingPathComponent("canvas/skills")).filter { $0.contains("/.") }
        expectEqual(kept, ["canvas-ingest/examples/orders/.canvas/ingest.json", "canvas-ingest/examples/orders/.canvas/lens.py"])
    },
    test("build.sh agents stops, saying which, when a skill it lists is missing") {
        let folder = try scratch("missing")
        defer { try? FileManager.default.removeItem(at: folder) }
        // A repository with build.sh and a skill of the shipped list but not the others.
        try FileManager.default.copyItem(at: root.appendingPathComponent("build.sh"), to: folder.appendingPathComponent("build.sh"))
        try write("---\nname: canvas\ndescription: x\n---\n", to: folder.appendingPathComponent(".claude/skills/canvas/SKILL.md"))
        let made = try assemble(into: folder.appendingPathComponent("out"), from: folder)
        expectEqual(made.status, 1, made.output)
        expect(made.error.contains("canvas-digest is listed in AGENT_SKILLS") && made.error.contains(".claude/skills/canvas-digest/SKILL.md"), made.error)
        expect(!exists(folder.appendingPathComponent("out")), "nothing is made")
    },

    test("the driver finds canvas: $CANVAS_CLI first; then the app's beside it, or build/canvas beside it in a checkout of this repository; then the PATH; never the current folder's build/canvas") {
        let folder = try scratch("driver")
        defer { try? FileManager.default.removeItem(at: folder) }
        let driver = root.appendingPathComponent(".claude/skills/canvas-digest/digest")
        let log = folder.appendingPathComponent("ran.log")

        func standIn(_ tag: String, at url: URL, build: String? = nil) throws {
            let status = build.map { "if [ \"$1\" = status ]; then printf 'build: %s\\n' '\($0)'; fi\n" } ?? ""
            try write("#!/bin/sh\necho \"\(tag)\" >> \"$CANVAS_TEST_LOG\"\n\(status)", to: url, executable: true)
        }
        /// A copy of the driver at `home` (with the tool beside it), run with `ready` from `cwd`; the tags of the stand-ins that ran.
        @MainActor func ran(driverAt home: URL, cwd: URL, path: [URL], cli: URL? = nil, buildID: String? = nil) throws -> (tags: Set<String>, output: ProcessOutput) {
            let copy = home.appendingPathComponent("digest")
            if !exists(copy) {
                try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: driver, to: copy)
                try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("tool"), withDestinationURL: root.appendingPathComponent(".claude/skills/canvas-digest/tool"))
            }
            if let buildID { try write(buildID + "\n", to: home.appendingPathComponent("build-id")) }
            try? FileManager.default.removeItem(at: log)
            try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
            let output = try run(URL(fileURLWithPath: "/bin/sh"),
                                 ["-c", #"cd "$0" && exec "$@""#, cwd.path, copy.path, "ready", "graph.json", "--new-file", folder.appendingPathComponent("new.canvasboard").path,
                                  "--out", folder.appendingPathComponent("out-\(UUID().uuidString)").path],
                                 environment: ["PATH": (path.map(\.path) + ["/usr/bin", "/bin"]).joined(separator: ":"), "CANVAS_CLI": cli?.path ?? "",
                                               "CANVAS_TEST_LOG": log.path])
            let tags = Set((read(log) ?? "").split(separator: "\n").map(String.init))
            return (tags, output)
        }

        let pathBin = folder.appendingPathComponent("path-bin")
        try standIn("path", at: pathBin.appendingPathComponent("canvas"))

        // $CANVAS_CLI wins over everything
        let cli = folder.appendingPathComponent("cli/canvas")
        try standIn("cli", at: cli)
        expectEqual(try ran(driverAt: folder.appendingPathComponent("plain-a"), cwd: folder.appendingPathComponent("cwd-a"), path: [pathBin], cli: cli).tags, ["cli"])

        // the app's: the driver is in the app's Resources/agents, and canvas is in its Helpers
        let app = folder.appendingPathComponent("Infinite Canvas.app/Contents")
        try standIn("app", at: app.appendingPathComponent("Helpers/canvas"))
        expectEqual(try ran(driverAt: app.appendingPathComponent("Resources/agents/canvas/skills/canvas-digest"), cwd: folder.appendingPathComponent("cwd-b"), path: [pathBin]).tags, ["app"])

        // a checkout of this repository: build/canvas at its root
        let checkout = folder.appendingPathComponent("checkout")
        try write("", to: checkout.appendingPathComponent("build.sh"))
        try write("", to: checkout.appendingPathComponent("Sources/CanvasCLI/main.swift"))
        try standIn("checkout", at: checkout.appendingPathComponent("build/canvas"))
        let inCheckout = checkout.appendingPathComponent(".claude/skills/canvas-digest")
        expectEqual(try ran(driverAt: inCheckout, cwd: folder.appendingPathComponent("cwd-c"), path: [pathBin]).tags, ["checkout"])

        // a repository that is not this one (or a folder that only looks like one) is not trusted for its build/canvas
        let stranger = folder.appendingPathComponent("stranger")
        try standIn("stranger", at: stranger.appendingPathComponent("build/canvas"))
        expectEqual(try ran(driverAt: stranger.appendingPathComponent(".claude/skills/canvas-digest"), cwd: folder.appendingPathComponent("cwd-d"), path: [pathBin]).tags, ["path"])

        // the PATH, from a copy anywhere, and not the current folder's build/canvas, whatever the folder is
        let here = folder.appendingPathComponent("somewhere")
        try standIn("cwd", at: here.appendingPathComponent("build/canvas"))
        let onPath = try ran(driverAt: folder.appendingPathComponent("plain-b"), cwd: here, path: [pathBin])
        expectEqual(onPath.tags, ["path"], onPath.output.error)
        let none = try ran(driverAt: folder.appendingPathComponent("plain-b"), cwd: here, path: [])
        expectEqual(none.tags, [], "the current folder's build/canvas is not run")
        expectEqual(none.output.status, 1, none.output.error)
        expect(none.output.error.contains("digest: can't find canvas: set CANVAS_CLI"), none.output.error)
        // ... nor the one in the folder the repository's own driver is run from
        let repositoryDriver = try ran(driverAt: folder.appendingPathComponent("plain-c"), cwd: checkout, path: [])
        expectEqual(repositoryDriver.tags, [], "a copy run from the checkout's folder does not run its build/canvas")
    },
    test("the driver warns once, on standard error, when the skills it runs from are of another build than the app answering; not when they are the same, when the app does not say, or in a checkout") {
        let folder = try scratch("stale")
        defer { try? FileManager.default.removeItem(at: folder) }
        let driver = root.appendingPathComponent(".claude/skills/canvas-digest/digest")
        func standIn(build: String?, at url: URL) throws {
            let status = build.map { "if [ \"$1\" = status ]; then printf 'app:     x\\nbuild:   %s\\n' '\($0)'; fi\n" } ?? ""
            try write("#!/bin/sh\n\(status)", to: url, executable: true)
        }
        @MainActor func driverRun(build id: String?, app: String?, name: String) throws -> ProcessOutput {
            let home = folder.appendingPathComponent(name)
            let bin = folder.appendingPathComponent("\(name)-bin")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: driver, to: home.appendingPathComponent("digest"))
            try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("tool"), withDestinationURL: root.appendingPathComponent(".claude/skills/canvas-digest/tool"))
            if let id { try write(id + "\n", to: home.appendingPathComponent("build-id")) }
            try standIn(build: app, at: bin.appendingPathComponent("canvas"))
            return try run(URL(fileURLWithPath: "/bin/sh"),
                                   ["-c", #"cd "$0" && exec "$@""#, folder.path, home.appendingPathComponent("digest").path, "ready", "graph.json", "--new-file",
                                    folder.appendingPathComponent("\(name).canvasboard").path, "--out", folder.appendingPathComponent("\(name)-out").path],
                                   environment: ["PATH": "\(bin.path):/usr/bin:/bin", "CANVAS_CLI": ""])
        }
        let stale = try driverRun(build: "old-1", app: "new-2", name: "stale")
        expectEqual(stale.status, 0, stale.error)
        expectEqual(stale.error.components(separatedBy: "warning").count - 1, 1, "said once: \(stale.error)")
        expect(stale.error.contains("build old-1") && stale.error.contains("build new-2") && stale.error.contains("canvas install"), stale.error)
        expect(!stale.output.contains("warning"), "on standard error only")
        for (name, id, app) in [("same", "b-1", "b-1"), ("silent", "b-1", nil), ("checkout", nil, "b-2")] as [(String, String?, String?)] {
            let quiet = try driverRun(build: id, app: app, name: name)
            expectEqual(quiet.status, 0, "\(name): \(quiet.error)")
            expect(!quiet.error.contains("warning"), "\(name): \(quiet.error)")
        }
    },
])
