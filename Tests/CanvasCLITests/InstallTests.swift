import CanvasRPC
import Foundation
import TestKit

// `canvas install` as built, run as an agent runs it: a temporary home, a PATH of the test's own with
// a stand-in `claude` that records its arguments, a folder laid out like the app's
// Contents/Resources/agents (`--from`), and a socket that nothing listens on.

/// A home folder, a PATH and the files a run of `canvas install` touches, all in one temporary folder.
private struct Scene {
    let root: URL
    let home: URL
    /// The folder the stand-in `claude` is in, first on the PATH.
    let tools: URL
    /// Where the stand-in `claude` writes what it was run with, a line a run.
    let log: URL

    init(claude: Bool = true, localBin: Bool = true) throws {
        let fileManager = FileManager.default
        root = fileManager.temporaryDirectory.appendingPathComponent("InstallTests-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        tools = root.appendingPathComponent("tools")
        log = root.appendingPathComponent("claude.log")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: tools, withIntermediateDirectories: true)
        if localBin { try fileManager.createDirectory(at: home.appendingPathComponent(".local/bin"), withIntermediateDirectories: true) }
        if claude {
            try write("#!/bin/sh\necho \"$*\" >> \"$CLAUDE_LOG\"\n", to: tools.appendingPathComponent("claude"), executable: true)
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// The environment of a run: this home, and a PATH of the stand-in `claude`'s folder, the home's `.local/bin` and the system's.
    /// `CANVAS_SOCKET` is a path nothing listens at.
    var environment: [String: String] {
        ["HOME": home.path, "PATH": "\(tools.path):\(home.path)/.local/bin:/usr/bin:/bin", "CLAUDE_LOG": log.path,
         "CANVAS_SOCKET": root.appendingPathComponent("nothing.sock").path]
    }

    var skills: URL { home.appendingPathComponent(".agents/skills") }

    /// The arguments the stand-in `claude` was run with, a run a line.
    var claudeRuns: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// A folder laid out like the app's Contents/Resources/agents: two skills, one with a program in it, built as `build`.
    func agents(build: String, named name: String = "agents", alpha: String = "alpha") throws -> URL {
        let folder = root.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: folder)
        try write("\(build)\n", to: folder.appendingPathComponent("build-id"))
        try write("{\"name\": \"infinite-canvas\"}\n", to: folder.appendingPathComponent(".claude-plugin/marketplace.json"))
        try write("{\"name\": \"canvas\"}\n", to: folder.appendingPathComponent("canvas/.claude-plugin/plugin.json"))
        let skills = folder.appendingPathComponent("canvas/skills")
        try write("---\nname: alpha\ndescription: first\n---\n\(alpha)\n", to: skills.appendingPathComponent("alpha/SKILL.md"))
        try write("\(build)\n", to: skills.appendingPathComponent("alpha/build-id"))
        try write("#!/bin/sh\necho alpha\n", to: skills.appendingPathComponent("alpha/tool/run"), executable: true)
        try write("---\nname: beta\ndescription: second\n---\nbeta\n", to: skills.appendingPathComponent("beta/SKILL.md"))
        return folder
    }
}

/// A stand-in `claude` that keeps the one marketplace it knows in `$CLAUDE_STATE` (its path): `list --json` says it, `add` is refused
/// while another path is registered under the name, `remove` forgets it.
private let statefulClaude = """
#!/bin/sh
echo "$*" >> "$CLAUDE_LOG"
state="$CLAUDE_STATE"
case "$1 $2 $3" in
"plugin marketplace list")
    if [ -f "$state" ]; then printf '[{"name":"infinite-canvas","installLocation":"%s"}]\\n' "$(cat "$state")"; else echo '[]'; fi ;;
"plugin marketplace add")
    if [ -f "$state" ] && [ "$(cat "$state")" != "$4" ]; then echo "Marketplace infinite-canvas already exists at $(cat "$state")"; exit 1; fi
    printf %s "$4" > "$state" ;;
"plugin marketplace remove") rm -f "$state" ;;
esac
exit 0

"""

/// Every item under a folder (the folder too), and its modes set: `directory` for the folders, `file` for the rest.
private func setModes(under folder: URL, directory: Int, file: Int) {
    let fileManager = FileManager.default
    var all = [folder]
    if let walker = fileManager.enumerator(atPath: folder.path) {
        for case let path as String in walker { all.append(folder.appendingPathComponent(path)) }
    }
    for url in all.reversed() {
        guard let type = (try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType, type != .typeSymbolicLink else { continue }
        try? fileManager.setAttributes([.posixPermissions: type == .typeDirectory ? directory : file], ofItemAtPath: url.path)
    }
}

/// An app's bundle at `url` (an `.app` folder) with a `canvas` in its Helpers, and `identifier` in its Info.plist.
private func makeApp(at url: URL, identifier: String?) throws -> URL {
    if let identifier {
        let plist: [String: Any] = ["CFBundleIdentifier": identifier]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
    }
    let helper = url.appendingPathComponent("Contents/Helpers/canvas")
    try write("#!/bin/sh\n", to: helper, executable: true)
    return helper
}

private func write(_ text: String, to url: URL, executable: Bool = false) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
    if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
}

private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

/// Where a link points, as written.
private func destination(_ link: URL) -> String? { try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) }

/// The `canvas` that was built, with its links resolved: what `canvas install` links to.
private func builtCanvas() -> String { builtExecutable("CanvasCLI").resolvingSymlinksInPath().path }

/// The step a run (as JSON) says it took, by name.
private func step(_ name: String, in result: ProcessOutput) -> JSON? {
    (try? JSON(text: result.output))?["steps"]?.arrayValue?.first { $0["step"]?.stringValue == name }
}

/// What the stand-in `claude` is run with by one `canvas install`, when no marketplace of the name is registered: the list (is the name
/// registered at another place?), the add, a refresh of the marketplace, the install, and an update of the plugin.
private func claudeSequence(_ agents: String) -> [String] {
    ["plugin marketplace list --json", "plugin marketplace add \(agents)", "plugin marketplace update infinite-canvas",
     "plugin install canvas@infinite-canvas -y", "plugin update canvas@infinite-canvas -y"]
}

@MainActor let installTests = Suite("canvas install", [
    test("it copies each skill into ~/.agents/skills, installs the plugin for Claude Code, links canvas, and says each step; run again it replaces its copies and nothing else") {
        let scene = try Scene()
        defer { scene.remove() }
        let agents = try scene.agents(build: "build-1")
        let first = try canvas(["install", "--from", agents.path], environment: scene.environment)
        expectEqual(first.status, 0, first.error + first.output)
        let answer = try JSON(text: first.output)
        expectEqual(answer["build"], "build-1")
        expectEqual(answer["steps"]?.arrayValue?.compactMap { $0["step"]?.stringValue },
                    ["skill alpha", "skill beta", "claude marketplace", "claude plugin", "claude update", "link"])
        for skill in ["alpha", "beta"] {
            expectEqual(read(scene.skills.appendingPathComponent("\(skill)/SKILL.md")), read(agents.appendingPathComponent("canvas/skills/\(skill)/SKILL.md")))
        }
        let marker = try require(read(scene.skills.appendingPathComponent("alpha/.canvas-install")))
        expect(marker.hasPrefix("build: build-1\n"), marker)
        expect(FileManager.default.isExecutableFile(atPath: scene.skills.appendingPathComponent("alpha/tool/run").path), "a program in a skill stays one")
        expectEqual(read(scene.skills.appendingPathComponent("alpha/build-id")), "build-1\n", "the build the skill carries is the one it was made in")
        expectEqual(scene.claudeRuns, claudeSequence(agents.path))
        expectEqual(destination(scene.home.appendingPathComponent(".local/bin/canvas")), builtCanvas())

        // The app is updated; the copy has a file of its own in it, which a run again takes with the rest.
        try write("stale\n", to: scene.skills.appendingPathComponent("alpha/stale.txt"))
        try write("not a skill's\n", to: scene.skills.appendingPathComponent("elsewhere/notes.txt"))
        let newer = try scene.agents(build: "build-2", alpha: "changed")
        let second = try canvas(["install", "--from", newer.path], environment: scene.environment)
        expectEqual(second.status, 0, second.error + second.output)
        expect(read(scene.skills.appendingPathComponent("alpha/SKILL.md"))?.contains("changed") == true, "replaced")
        expect(!exists(scene.skills.appendingPathComponent("alpha/stale.txt")), "the old copy goes whole")
        expect(read(scene.skills.appendingPathComponent("alpha/.canvas-install"))?.hasPrefix("build: build-2\n") == true)
        expectEqual(read(scene.skills.appendingPathComponent("elsewhere/notes.txt")), "not a skill's\n", "a folder canvas install did not make is not touched")
        expect(step("skill alpha", in: second)?["message"]?.stringValue?.hasPrefix("replaced") == true, second.output)
        expectEqual(step("link", in: second)?["did"], "unchanged", "the link is there already")
        expectEqual(scene.claudeRuns.count, 10, "the plugin commands run each time")
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: scene.skills.path).sorted(), ["alpha", "beta", "elsewhere"], "no staging folder is left")
    },
    test("it asks no app: with a socket nothing listens at it succeeds, and with a fake app listening the app is never asked") {
        let scene = try Scene()
        defer { scene.remove() }
        let agents = try scene.agents(build: "b")
        let gone = try canvas(["install", "--from", agents.path, "--no-claude"], environment: scene.environment)
        expectEqual(gone.status, 0, gone.error + gone.output)
        expect(!gone.error.contains("not_running"), gone.error)
        let app = try FakeApp()
        defer { app.stop() }
        let near = try canvas(["--socket", app.path, "install", "--from", agents.path, "--no-claude"], environment: scene.environment)
        expectEqual(near.status, 0, near.error + near.output)
        expectEqual(app.methods, [], "nothing was asked of the app")
    },
    test("a folder in the way that canvas install did not make is refused, named and left as it is; the other skills go in") {
        let scene = try Scene()
        defer { scene.remove() }
        let agents = try scene.agents(build: "b")
        try write("my own alpha\n", to: scene.skills.appendingPathComponent("alpha/SKILL.md"))
        let result = try canvas(["install", "--from", agents.path, "--no-claude"], environment: scene.environment)
        expectEqual(result.status, 1, result.output)
        expectEqual(read(scene.skills.appendingPathComponent("alpha/SKILL.md")), "my own alpha\n")
        expect(!exists(scene.skills.appendingPathComponent("alpha/.canvas-install")), "no marker in a folder it did not make")
        let refused = try require(step("skill alpha", in: result))
        expectEqual(refused["did"], "refused")
        expect(refused["message"]?.stringValue?.contains(scene.skills.appendingPathComponent("alpha").path) == true, "names the folder: \(refused)")
        expect(exists(scene.skills.appendingPathComponent("beta/SKILL.md")), "beta is installed all the same")
        // A file, or a link, where a skill goes is not its to replace either.
        try FileManager.default.removeItem(at: scene.skills.appendingPathComponent("beta"))
        try FileManager.default.createSymbolicLink(at: scene.skills.appendingPathComponent("beta"), withDestinationURL: scene.root)
        let link = try canvas(["install", "--from", agents.path, "--no-claude"], environment: scene.environment)
        expectEqual(step("skill beta", in: link)?["did"], "refused", link.output)
        expectEqual(destination(scene.skills.appendingPathComponent("beta")), scene.root.path)
    },
    test("--to puts the skills in another folder, and the home's is not made") {
        let scene = try Scene()
        defer { scene.remove() }
        let agents = try scene.agents(build: "b")
        let there = scene.root.appendingPathComponent("elsewhere/skills")
        let result = try canvas(["install", "--from", agents.path, "--to", there.path, "--no-claude"], environment: scene.environment)
        expectEqual(result.status, 0, result.error + result.output)
        expect(exists(there.appendingPathComponent("alpha/SKILL.md")) && exists(there.appendingPathComponent("beta/SKILL.md")))
        expect(!exists(scene.skills), "the default is not made")
        let equals = try canvas(["install", "--from", agents.path, "--to=\(there.path)-two", "--no-claude"], environment: scene.environment)
        expectEqual(equals.status, 0, equals.error)
        expect(exists(URL(fileURLWithPath: there.path + "-two/alpha/SKILL.md")))
    },
    test("for Claude Code it runs the marketplace and plugin commands when claude is on the PATH, prints them when it is not, and --no-claude skips both") {
        let with = try Scene()
        defer { with.remove() }
        let agents = try with.agents(build: "b")
        let skipped = try canvas(["install", "--from", agents.path, "--no-claude"], environment: with.environment)
        expectEqual(skipped.status, 0, skipped.error)
        expectEqual(with.claudeRuns, [], "claude is not run")
        expectEqual(step("claude", in: skipped)?["did"], "skipped")
        let ran = try canvas(["install", "--from", agents.path], environment: with.environment)
        expectEqual(ran.status, 0, ran.error)
        expectEqual(with.claudeRuns, claudeSequence(agents.path))

        let without = try Scene(claude: false)
        defer { without.remove() }
        let other = try without.agents(build: "b")
        let said = try canvas(["install", "--from", other.path], environment: without.environment)
        expectEqual(said.status, 0, said.error + said.output)
        let message = try require(step("claude", in: said)?["message"]?.stringValue)
        expect(message.contains("claude plugin marketplace add \(other.path)") && message.contains("claude plugin install canvas@infinite-canvas"), message)
        expectEqual(without.claudeRuns, [])

        // A claude that fails: said, and the exit status is not 0.
        let failing = try Scene()
        defer { failing.remove() }
        try write("#!/bin/sh\necho \"boom: $2\"\nexit 1\n", to: failing.tools.appendingPathComponent("claude"), executable: true)
        let broke = try canvas(["install", "--from", try failing.agents(build: "b").path], environment: failing.environment)
        expectEqual(broke.status, 1, broke.output)
        expect(step("claude plugin", in: broke)?["message"]?.stringValue?.contains("boom") == true, broke.output)
        expect(exists(failing.skills.appendingPathComponent("alpha/SKILL.md")), "the skills are copied all the same")
    },
    test("canvas is linked into --bin, else into the first folder of ~/.local/bin, /opt/homebrew/bin and /usr/local/bin that is on the PATH and writable; it replaces a link it made and nothing else") {
        let scene = try Scene(localBin: false)
        defer { scene.remove() }
        let agents = try scene.agents(build: "b")
        let bin = scene.root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        // none of the usual folders is on the PATH, or there: said, how to do it, and not a failure
        let none = try canvas(["install", "--from", agents.path, "--no-claude"], environment: scene.environment)
        expectEqual(none.status, 0, none.error + none.output)
        let said = try require(step("link", in: none))
        expectEqual(said["did"], "skipped")
        expect(said["message"]?.stringValue?.contains("--bin") == true && said["message"]?.stringValue?.contains("ln -s") == true, none.output)

        // --bin, even when that folder is not on the PATH (said)
        let named = try canvas(["install", "--from", agents.path, "--no-claude", "--bin", bin.path], environment: scene.environment)
        expectEqual(named.status, 0, named.error)
        expectEqual(destination(bin.appendingPathComponent("canvas")), builtCanvas())
        expect(step("link", in: named)?["message"]?.stringValue?.contains("not on your PATH") == true, named.output)

        // a link an earlier app made is replaced, a link to anything else and a file are not
        try FileManager.default.removeItem(at: bin.appendingPathComponent("canvas"))
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("canvas").path, withDestinationPath: "/gone/Infinite Canvas.app/Contents/Helpers/canvas")
        let replaced = try canvas(["install", "--from", agents.path, "--no-claude", "--bin", bin.path], environment: scene.environment)
        expectEqual(replaced.status, 0, replaced.error + replaced.output)
        expectEqual(destination(bin.appendingPathComponent("canvas")), builtCanvas())
        try FileManager.default.removeItem(at: bin.appendingPathComponent("canvas"))
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("canvas").path, withDestinationPath: "/usr/bin/true")
        let foreign = try canvas(["install", "--from", agents.path, "--no-claude", "--bin", bin.path], environment: scene.environment)
        expectEqual(foreign.status, 1, foreign.output)
        expectEqual(destination(bin.appendingPathComponent("canvas")), "/usr/bin/true")
        try FileManager.default.removeItem(at: bin.appendingPathComponent("canvas"))
        try write("my own\n", to: bin.appendingPathComponent("canvas"))
        let file = try canvas(["install", "--from", agents.path, "--no-claude", "--bin", bin.path], environment: scene.environment)
        expectEqual(file.status, 1, file.output)
        expectEqual(read(bin.appendingPathComponent("canvas")), "my own\n")
        let notAFolder = try canvas(["install", "--from", agents.path, "--no-claude", "--bin", scene.root.appendingPathComponent("missing").path], environment: scene.environment)
        expectEqual(notAFolder.status, 1, notAFolder.output)

        // the home's .local/bin, on the PATH once it is there
        try FileManager.default.createDirectory(at: scene.home.appendingPathComponent(".local/bin"), withIntermediateDirectories: true)
        let local = try canvas(["install", "--from", agents.path, "--no-claude"], environment: scene.environment)
        expectEqual(local.status, 0, local.error + local.output)
        expectEqual(destination(scene.home.appendingPathComponent(".local/bin/canvas")), builtCanvas())
        // ... but not when the PATH does not name it
        try FileManager.default.removeItem(at: scene.home.appendingPathComponent(".local/bin/canvas"))
        var environment = scene.environment
        environment["PATH"] = "/usr/bin:/bin"
        let off = try canvas(["install", "--from", agents.path, "--no-claude"], environment: environment)
        expectEqual(step("link", in: off)?["did"], "skipped", off.output)
        expect(!exists(scene.home.appendingPathComponent(".local/bin/canvas")))
    },
    test("without --from it takes the skills from the app it is in, and says so when it is not in one; unknown options are usage errors; help says what it takes") {
        let scene = try Scene()
        defer { scene.remove() }
        let lone = try canvas(["install", "--no-claude"], environment: scene.environment)
        expectEqual(lone.status, 1, lone.output)
        expect(step("skills", in: lone)?["message"]?.stringValue?.contains("--from") == true, lone.output)
        let empty = try canvas(["install", "--from", scene.root.path, "--no-claude"], environment: scene.environment)
        expectEqual(empty.status, 1, empty.output)
        let usage = try canvas(["install", "--frm", "x"], environment: scene.environment)
        expectEqual(usage.status, 2, usage.error)
        expectEqual(try JSON(text: usage.error)["error"]?["reason"], "usage")
        let missing = try canvas(["install", "--to"], environment: scene.environment)
        expectEqual(missing.status, 2, missing.error)
        // the app's folder: a canvas in Contents/Helpers has its skills in Contents/Resources/agents
        let app = scene.root.appendingPathComponent("Fake.app/Contents")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Helpers"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: builtExecutable("CanvasCLI"), to: app.appendingPathComponent("Helpers/canvas"))
        let agents = try scene.agents(build: "in-app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: agents, to: app.appendingPathComponent("Resources/agents"))
        let inApp = try run(app.appendingPathComponent("Helpers/canvas"), ["install", "--no-claude"], environment: scene.environment)
        expectEqual(inApp.status, 0, inApp.error + inApp.output)
        expect(read(scene.skills.appendingPathComponent("alpha/.canvas-install"))?.hasPrefix("build: in-app\n") == true)
        expectEqual(destination(scene.home.appendingPathComponent(".local/bin/canvas")), app.appendingPathComponent("Helpers/canvas").resolvingSymlinksInPath().path,
                    "the link is to the app's own canvas")
        let help = try canvas(["help", "install"], environment: scene.environment)
        expectEqual(help.status, 0, help.error)
        for word in ["--to", "--bin", "--from", "--no-claude", "~/.agents/skills"] { expect(help.output.contains(word), "help says \(word)") }
        expect(try canvas(["--socket", scene.root.appendingPathComponent("none.sock").path, "help"]).output.contains("canvas install"), "general help lists it")
    },
    test("canvas install means this app's skills: a marketplace of the name registered at another place (a worktree's app, or the main one) is removed and added again from this app's folder, and the line says so") {
        let scene = try Scene()
        defer { scene.remove() }
        try write(statefulClaude, to: scene.tools.appendingPathComponent("claude"), executable: true)
        var environment = scene.environment
        let state = scene.root.appendingPathComponent("claude.state")
        environment["CLAUDE_STATE"] = state.path
        let elsewhere = try scene.agents(build: "old", named: "other-app/agents")
        _ = try canvas(["install", "--from", elsewhere.path, "--no-claude"], environment: environment)
        try write(elsewhere.path, to: state)
        let agents = try scene.agents(build: "new")
        let result = try canvas(["install", "--from", agents.path], environment: environment)
        expectEqual(result.status, 0, result.error + result.output)
        let marketplace = try require(step("claude marketplace", in: result))
        expectEqual(marketplace["did"], "done", result.output)
        expect(marketplace["message"]?.stringValue?.contains("another place") == true && marketplace["message"]?.stringValue?.contains(agents.path) == true, "\(marketplace)")
        expectEqual(read(state), agents.path, "Claude Code is pointed at this app's folder")
        expect(scene.claudeRuns.contains("plugin marketplace remove infinite-canvas"), "\(scene.claudeRuns)")
        // Again: it is this app's already, nothing is removed.
        try? FileManager.default.removeItem(at: scene.log)
        let again = try canvas(["install", "--from", agents.path], environment: environment)
        expectEqual(again.status, 0, again.error + again.output)
        expect(!scene.claudeRuns.contains { $0.contains("remove") }, "\(scene.claudeRuns)")
    },
    test("a marketplace add that fails is a warning with claude's words, never \"unchanged\"; so are failed refreshes; a failed install is a failure; a claude that hangs is a failure, after the timeout") {
        let scene = try Scene()
        defer { scene.remove() }
        let agents = try scene.agents(build: "b")
        // add fails (and so does the remove that would make way for it), the rest works
        try write("#!/bin/sh\necho \"$*\" >> \"$CLAUDE_LOG\"\ncase \"$3\" in add|remove) echo \"no luck with $3\"; exit 1;; esac\n", to: scene.tools.appendingPathComponent("claude"), executable: true)
        let added = try canvas(["install", "--from", agents.path], environment: scene.environment)
        expectEqual(added.status, 0, "the plugin did install: \(added.output)")
        let warned = try require(step("claude marketplace", in: added))
        expectEqual(warned["did"], "warning", added.output)
        expect(warned["message"]?.stringValue?.contains("no luck with add") == true, "\(warned)")
        // the refreshes fail
        try write("#!/bin/sh\ncase \"$2 $3\" in \"marketplace update\"|\"update canvas@infinite-canvas\") echo \"stale $2\"; exit 1;; esac\n", to: scene.tools.appendingPathComponent("claude"), executable: true)
        let refresh = try canvas(["install", "--from", agents.path], environment: scene.environment)
        expectEqual(refresh.status, 0, refresh.output)
        let refreshed = try require(step("claude update", in: refresh))
        expectEqual(refreshed["did"], "warning", refresh.output)
        expect(refreshed["message"]?.stringValue?.contains("stale") == true, "\(refreshed)")
        // a hang
        try write("#!/bin/sh\nexec sleep 30\n", to: scene.tools.appendingPathComponent("claude"), executable: true)
        var environment = scene.environment
        environment["CANVAS_INSTALL_CLAUDE_TIMEOUT"] = "1"
        let hung = try canvas(["install", "--from", agents.path, "--bin", scene.root.path], environment: environment)
        expectEqual(hung.status, 1, hung.output)
        let install = try require(step("claude plugin", in: hung))
        expectEqual(install["did"], "failed")
        expect(install["message"]?.stringValue?.contains("timed out") == true, "\(install)")
        expect(exists(scene.skills.appendingPathComponent("alpha/SKILL.md")), "the skills are copied all the same")
    },
    test("an option's value is not another option or empty: --to --no-claude is a usage error, and makes no folder") {
        let scene = try Scene()
        defer { scene.remove() }
        let agents = try scene.agents(build: "b")
        let stray = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("--no-claude")
        defer { try? FileManager.default.removeItem(at: stray) }
        for words in [["--to", "--no-claude"], ["--bin", "--no-claude"], ["--from", "--no-claude"], ["--to="], ["--to", ""], ["--bin=-x"]] {
            let result = try canvas(["install", "--from", agents.path] + words, environment: scene.environment)
            expectEqual(result.status, 2, "\(words): \(result.output + result.error)")
            expectEqual(try JSON(text: result.error)["error"]?["reason"], "usage")
        }
        expect(!exists(stray), "no folder named --no-claude")
        expect(!exists(scene.skills), "nothing was installed")
        // a folder that starts with a dash is still given as ./-x
        let dashed = try canvas(["install", "--from", agents.path, "--no-claude", "--to", scene.root.appendingPathComponent("-x").path], environment: scene.environment)
        expectEqual(dashed.status, 0, dashed.error)
    },
    test("a source that is read-only installs and installs again, a leftover staging folder (read-only too) is cleared, and none is left behind") {
        let scene = try Scene()
        let agents = try scene.agents(build: "b")
        defer { setModes(under: scene.root, directory: 0o755, file: 0o644); scene.remove() }
        setModes(under: agents, directory: 0o555, file: 0o444)
        try write("old\n", to: scene.skills.appendingPathComponent(".alpha.canvas-install-new/notes.txt"))
        setModes(under: scene.skills.appendingPathComponent(".alpha.canvas-install-new"), directory: 0o555, file: 0o444)
        for _ in 0..<2 {
            let result = try canvas(["install", "--from", agents.path, "--no-claude"], environment: scene.environment)
            expectEqual(result.status, 0, result.error + result.output)
        }
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: scene.skills.path).sorted(), ["alpha", "beta"], "no staging folder is left")
        expect(exists(scene.skills.appendingPathComponent("alpha/.canvas-install")))
        let mode = (try FileManager.default.attributesOfItem(atPath: scene.skills.appendingPathComponent("alpha").path)[.posixPermissions] as? Int) ?? 0
        expect(mode & 0o200 != 0, "the copy is writable by its owner: \(String(mode, radix: 8))")
    },
    test("a source skill that is a symbolic link is refused, named, and the folder it points to is not written to") {
        let scene = try Scene()
        defer { scene.remove() }
        let agents = try scene.agents(build: "b")
        let real = scene.root.appendingPathComponent("real-gamma")
        try write("---\nname: gamma\ndescription: third\n---\n", to: real.appendingPathComponent("SKILL.md"))
        try FileManager.default.createSymbolicLink(at: agents.appendingPathComponent("canvas/skills/gamma"), withDestinationURL: real)
        let result = try canvas(["install", "--from", agents.path, "--no-claude"], environment: scene.environment)
        expectEqual(result.status, 1, result.output)
        let refused = try require(step("skill gamma", in: result))
        expectEqual(refused["did"], "refused")
        expect(refused["message"]?.stringValue?.contains("symbolic link") == true, "\(refused)")
        expect(!exists(real.appendingPathComponent(".canvas-install")), "the source is not written to")
        expect(!exists(scene.skills.appendingPathComponent("gamma")), "nothing is copied")
        expect(exists(scene.skills.appendingPathComponent("alpha/SKILL.md")), "the others go in")
    },
    test("a copy that can't be made leaves the skill that was there; a link that can't be replaced stays") {
        let scene = try Scene()
        defer { setModes(under: scene.root, directory: 0o755, file: 0o644); scene.remove() }
        let agents = try scene.agents(build: "one")
        _ = try canvas(["install", "--from", agents.path, "--no-claude"], environment: scene.environment)
        let before = read(scene.skills.appendingPathComponent("alpha/SKILL.md"))
        let newer = try scene.agents(build: "two", alpha: "changed")
        // the skills folder can't be written to: the new copy can't be staged
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: scene.skills.path)
        let result = try canvas(["install", "--from", newer.path, "--no-claude"], environment: scene.environment)
        expectEqual(result.status, 1, result.output)
        expectEqual(read(scene.skills.appendingPathComponent("alpha/SKILL.md")), before, "the skill that was there is still there")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scene.skills.path)
        // the link: a read-only folder keeps the old link
        let link = scene.home.appendingPathComponent(".local/bin/canvas")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/gone/Infinite Canvas.app/Contents/Helpers/canvas")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: link.deletingLastPathComponent().path)
        let stuck = try canvas(["install", "--from", newer.path, "--no-claude", "--bin", link.deletingLastPathComponent().path], environment: scene.environment)
        expectEqual(step("link", in: stuck)?["did"], "failed", stuck.output)
        expectEqual(destination(link), "/gone/Infinite Canvas.app/Contents/Helpers/canvas", "the old link is still there")
    },
    test("a link is ours to replace only if it is to this app's canvas: a bundle with this app's identifier (or a worktree copy's), or an app that is gone and was called Infinite Canvas; another app's helper is left") {
        let scene = try Scene()
        defer { scene.remove() }
        let agents = try scene.agents(build: "b")
        let bin = scene.root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = bin.appendingPathComponent("canvas")
        @MainActor func installing() throws -> ProcessOutput { try canvas(["install", "--from", agents.path, "--no-claude", "--bin", bin.path], environment: scene.environment) }
        func pointing(at target: URL) throws {
            try? FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        }
        // Another app's helper of the same name
        let canva = try makeApp(at: scene.root.appendingPathComponent("Canva.app"), identifier: "com.canva.Canva")
        try pointing(at: canva)
        let foreign = try installing()
        expectEqual(step("link", in: foreign)?["did"], "refused", foreign.output)
        expectEqual(destination(link), canva.path)
        // ... one that is gone, and was not ours
        try pointing(at: scene.root.appendingPathComponent("Gone/Canva.app/Contents/Helpers/canvas"))
        let gone = try installing()
        expectEqual(step("link", in: gone)?["did"], "refused", gone.output)
        // ... this app's identifier, a worktree copy's
        for (name, id) in [("Infinite Canvas.app", "com.example.InfiniteCanvas"), ("Infinite Canvas (x).app", "com.example.InfiniteCanvas.worktree.x")] {
            try pointing(at: try makeApp(at: scene.root.appendingPathComponent(name), identifier: id))
            let ours = try installing()
            expectEqual(ours.status, 0, ours.output)
            expectEqual(step("link", in: ours)?["did"], "done", ours.output)
            expectEqual(destination(link), builtCanvas())
        }
        // ... a lookalike identifier is not this app's
        try pointing(at: try makeApp(at: scene.root.appendingPathComponent("Lookalike.app"), identifier: "com.example.InfiniteCanvasFake"))
        expectEqual(step("link", in: try installing())?["did"], "refused")
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: bin.path), ["canvas"], "no temporary link is left")
    },
    test("run from a disk image it says that the links and the plugin point into one that will go away, and to move the app to Applications first; from anywhere else it does not") {
        let scene = try Scene()
        defer { scene.remove() }
        var environment = scene.environment
        environment["CANVAS_INSTALL_VOLUMES"] = scene.root.appendingPathComponent("Volumes").path
        let mounted = try scene.agents(build: "b", named: "Volumes/Infinite Canvas/agents")
        let on = try canvas(["install", "--from", mounted.path, "--no-claude"], environment: environment)
        expectEqual(on.status, 0, on.error + on.output)
        let said = try require(step("disk image", in: on))
        expectEqual(said["did"], "warning")
        expect(said["message"]?.stringValue?.contains("Applications") == true, "\(said)")
        let off = try canvas(["install", "--from", try scene.agents(build: "b").path, "--no-claude"], environment: environment)
        expect(step("disk image", in: off) == nil, off.output)
    },
])
