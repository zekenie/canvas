import CanvasRPC
import CryptoKit
import Foundation
import SkillTesting
import TestKit

// The canvas-ingest skill (.claude/skills/canvas-ingest) where no app is needed: `ingest` run as an agent runs it but with a driver
// of its own that logs its arguments and draws nothing (`stubbedSkill`), the lens runner and the scanners on scratch git
// repositories, and lenskit's readers and builder as scripts of Python. Every test gives `ingest` a cache of its own
// (CANVAS_INGEST_CACHE) in a scratch folder, and the repositories it ingests are scratch git repositories there, never this one. The
// tests that draw into the app's command server are CompositionTests' IngestTests.

@MainActor let ingestScriptsTests = Suite("canvas-ingest: lenskit's readers, builder and collapse run as scripts, a lens's own modules, and the repository's settings and what to scan with", [
    test("the SQL and YAML readers on the words, strings and shapes that used to fool them, and a chain of modules a recursion could not hold") {
        let done = try pythonScript("gaps.py")
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
    test("lenskit's readers: YAML (block and flow, quoted, comments, block scalars; refusing anchors, tags, documents) and SQL (CREATE TABLE and ALTER TABLE, skipping the rest)") {
        let done = try pythonScript("readers.py")
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
    test("lenskit's Digest gives a title out once in its container, lets a name repeat in another, and names nodes by an id where a title repeats; the same under another hash seed") {
        let seeds = try ["1", "2"].map { try pythonScript("builder.py", environment: ["PYTHONHASHSEED": $0]) }
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
        let env = ingestEnvironment(cache: cache, extra: ["STUB_LOG": log.path])
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
    test("the settings: keys read and handed to the driver, each beaten by its option, an unknown key warned, a bad value refused naming its key") {
        let folder = try scratchFolder("settings")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("cache")
        let (script, log) = try stubbedSkill(in: folder)
        let repo = try makeRepository("repo", in: folder)
        let kept = try cacheFolder(of: repo, cache: cache, with: script)
        try putScan(tinyModel, in: kept)
        let env = ingestEnvironment(cache: cache, extra: ["STUB_LOG": log.path])
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
        let env = ingestEnvironment(cache: cache, extra: ["STUB_LOG": log.path])
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
    test("what a run's commands say is kept, not said: prepare's and the indexer's output go to the run's folder, said only when they fail (their end), a lens's warnings past twenty go to a file, and the scan says what the index left out") {
        let folder = try scratchFolder("quiet")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("cache")
        let (script, log) = try stubbedSkill(in: folder)
        let repo = try makeRepository("repo", in: folder)
        let kept = try cacheFolder(of: repo, cache: cache, with: script)
        let env = ingestEnvironment(cache: cache, extra: ["STUB_LOG": log.path])
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
])

@MainActor let ingestLensTests = Suite("canvas-ingest: the default lens against its fixtures, and lenses refused or raising", [
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
    test("a lens that gives two digests is refused, naming where they differ and the usual causes: a set of strings, the clock, the environment") {
        let folder = try scratchFolder("refused")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("cache")
        let (script, log) = try stubbedSkill(in: folder)
        let repo = try makeRepository("repo", in: folder)
        let kept = try cacheFolder(of: repo, cache: cache, with: script)
        try putScan(tinyModel, in: kept)
        let env = ingestEnvironment(cache: cache, extra: ["STUB_LOG": log.path])
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
        let broken = try ingest([repo.path, "--scan", handScan(kept)], with: script, environment: ingestEnvironment(cache: cache, extra: ["STUB_LOG": log.path]))
        expectEqual(broken.status, 1, broken.output)
        expect(broken.error.contains("Traceback") && broken.error.contains("ValueError: the lens broke on TinyPackage") && broken.error.contains("lens.py"), broken.error)
        expect(!driverCalls(log).contains { $0.hasPrefix("all ") }, "nothing was drawn: \(driverCalls(log))")
        expect(!FileManager.default.fileExists(atPath: try lastRun(in: kept).appendingPathComponent("digest.json").path), "and no digest was written")
        expect(!FileManager.default.fileExists(atPath: kept.appendingPathComponent("lock").path), "the lock is freed")
    },
])

@MainActor let ingestBigScanTests = Suite("canvas-ingest: big scans through the lens runner, and what a lens passes over", [
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

@MainActor let ingestPrepareTests = Suite("canvas-ingest: prepare runs in the checkout when what it reads has changed, one ingest at a time, and a run stopped", [
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
        let env = ingestEnvironment(cache: cache, extra: ["STUB_LOG": log.path])
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
        let env = ingestEnvironment(cache: cache, extra: ["STUB_LOG": log.path, "STUB_LOCK": lock.path])

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
        let failing = try ingest([repo.path, "--scan", handScan(kept)], with: script, environment: ingestEnvironment(cache: cache, extra: ["STUB_LOG": log.path, "STUB_LOCK": lock.path, "STUB_FAIL": "1"]))
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
        slow.environment = ProcessInfo.processInfo.environment.merging(ingestEnvironment(cache: cache, extra: ["STUB_LOG": log.path])) { _, new in new }
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

@MainActor let ingestLockfilesTests = Suite("canvas-ingest: prepare for each of the other lockfiles, and one cache for a repository's worktrees", [
    test("prepare runs in the checkout for each of the other lockfiles and manifests, and a path that git would quote (a space, a quote, letters outside ASCII), added and changed") {
        let folder = try scratchFolder("prepare")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("cache")
        let (script, log) = try stubbedSkill(in: folder)
        let counter = folder.appendingPathComponent("prepare.count")
        let repo = try makeRepository("repo", in: folder, files: ["package-lock.json": "{\"v\": 1}\n", "web/app.js": "1\n"])
        @MainActor func commit(_ files: [String: String]) throws -> String {
            for (path, text) in files { try write(text, to: repo.appendingPathComponent(path)); try git(repo, ["add", path]) }
            try git(repo, ["commit", "-q", "-m", files.keys.sorted().joined(separator: " ")])
            return try git(repo, ["rev-parse", "HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try cacheFolder(of: repo, cache: cache, with: script)
        let settings = repo.appendingPathComponent(".canvas/ingest.json")
        // the counter is outside the checkout: what git doesn't know is removed with each move
        func configure(_ prepare: String) throws {
            try write(#"{"scanner": "scip", "scip": "echo made > {index}", "prepare": "\#(prepare)"}"#, to: settings)
        }
        try configure("echo run >> \(counter.path)")
        let env = ingestEnvironment(cache: cache, extra: ["STUB_LOG": log.path])
        func runs() -> Int { ((try? String(contentsOf: counter, encoding: .utf8)) ?? "").split(separator: "\n").count }
        @MainActor func ingestIt(_ more: [String] = [], status: Int32 = 0) throws -> ProcessOutput {
            let done = try ingest([repo.path] + more, with: script, environment: env)
            expectEqual(done.status, status, done.output + done.error)
            return done
        }

        _ = try ingestIt()
        var most = 1
        expectEqual(runs(), most, "the first time")
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
    test("one cache a repository, whatever worktree it is run from: two worktrees of a repository share its scan, its runs and its records, and the last five runs are kept") {
        let folder = try scratchFolder("worktrees")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("cache")
        let (script, log) = try stubbedSkill(in: folder)
        let env = ingestEnvironment(cache: cache, extra: ["STUB_LOG": log.path])
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
])

@MainActor let ingestCheckoutTests = Suite("canvas-ingest: the checkout moved to each commit, partial clones, and the Swift index of a package that ships a list", [
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
        let env = ingestEnvironment(cache: cache, extra: ["STUB_LOG": log.path])
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
        let env = ingestEnvironment(cache: cache, extra: ["STUB_LOG": log.path])
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
])
