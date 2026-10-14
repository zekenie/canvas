import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasUI
import DrawScript
import Foundation
import LanguageModels
import QueryLanguage
import ShippedTesting
import TestKit

// The canvas skill (.claude/skills/canvas) teaches agents `canvas draw` and `canvas query` by
// example, so its examples must run: each file's blocks, in order, through `canvas` as built,
// against the app's command server, on a board of the file's own: a fresh one in a 1440 × 900
// window, or, for a file whose first line is `<!-- board: query-story -->`, the story file every
// query example is about (`QueryStory`), as the app opens it, in the same view (and `<!-- board:
// reference-story -->`, the story of reference/references.md, `QueryReferenceStory`). A block tagged
// `draw` runs for real and must succeed, pushing nothing aside (an example says where things go);
// one tagged `draw-error` runs as a dry run and must fail, with the reason its first line names
// (`// reason: <reason>`), changing nothing. A block tagged `query` is a query, run as the skill
// has an agent run one (`canvas query - --board <n>`, the block on standard input), and must answer
// exactly what its first line, a comment, says: `/* matches: "Title", (kind) */`, the shapes it
// lists, in order (an untitled one by its kind in brackets, nothing after the colon for none), or
// `/* count: N */`; one tagged `query-error` must be refused with the reason its first line names
// (`/* reason: <reason> */`). A query block leaves the board as it was: the same file, no more
// edited, and no step to undo. A page whose first line is `<!-- ids: <sample>, <sample> -->` writes ids as a reader
// sees them in its blocks, ids a block cannot know before the board is drawn (a shape with no title is named by its
// id): each sample stands for the id of the same row of the last query that answered that many (`SampleIDs`).
// SKILL_DUMP=1 prints what each example said, for checking the prose around it.

/// Where the skill is, from the repository's root (where tests run).
let skillFolder = ".claude/skills/canvas"

/// A fenced example in a skill file.
struct SkillExample {
    /// The command it's for: its fence's tag, less `-error`.
    enum Command: String {
        case draw
        case query
    }

    let file: String
    /// The line its fence opens on.
    let line: Int
    let command: Command
    let fails: Bool
    let script: String

    /// What its first line says as `name: value`, in a comment (`// name: value` for a script,
    /// `/* name: value */` for a query); nil when it says nothing by that name.
    func directive(_ name: String) -> String? {
        guard let first = script.split(separator: "\n", omittingEmptySubsequences: false).first else { return nil }
        var said = first.trimmingCharacters(in: .whitespaces)
        switch command {
        case .draw:
            guard said.hasPrefix("//") else { return nil }
            said = String(said.dropFirst(2))
        case .query:
            guard said.hasPrefix("/*"), said.hasSuffix("*/") else { return nil }
            said = String(said.dropFirst(2).dropLast(2))
        }
        said = said.trimmingCharacters(in: .whitespaces)
        guard said.hasPrefix(name + ":") else { return nil }
        return said.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces)
    }

    /// The reason a failing one names.
    var reason: String? { directive("reason") }

    /// The shapes a query lists, in order, as `matches:` writes them (`skillLabel`); empty for
    /// none. Nil when it doesn't say, and `["?"]` for what can't be read.
    var matches: [String]? {
        guard let said = directive("matches") else { return nil }
        var rest = Substring(said)
        var shapes: [String] = []
        while let first = rest.first {
            switch first {
            case " ", ",":
                rest = rest.dropFirst()
            case "\"", "(":
                let close: Character = first == "(" ? ")" : "\""
                guard let end = rest.dropFirst().firstIndex(of: close) else { return ["?"] }
                shapes.append(String(rest[...end]))
                rest = rest[rest.index(after: end)...]
            default:
                return ["?"]
            }
        }
        return shapes
    }

    /// How many a query matches, as `count:` says.
    var count: Int? { directive("count").flatMap { Int($0) } }

    var place: String { "\(file):\(line)" }
}

/// A shape a query's answer lists, as `matches:` writes it: its title in double quotes, or its kind
/// in brackets.
func skillLabel(_ row: JSON) -> String {
    row["title"]?.stringValue.map { "\"\($0)\"" } ?? "(\(row["kind"]?.stringValue ?? "?"))"
}

/// The skill's files: SKILL.md, then its references.
func skillFiles() throws -> [String] {
    let references = try FileManager.default.contentsOfDirectory(atPath: "\(skillFolder)/reference").filter { $0.hasSuffix(".md") }.sorted()
    return ["\(skillFolder)/SKILL.md"] + references.map { "\(skillFolder)/reference/\($0)" }
}

/// A file's ```draw, ```draw-error, ```query and ```query-error blocks, in order.
func skillExamples(in path: String) throws -> [SkillExample] {
    let lines = try String(contentsOfFile: path, encoding: .utf8).components(separatedBy: "\n")
    var examples: [SkillExample] = []
    var open: (line: Int, command: SkillExample.Command, fails: Bool, body: [String])?
    for (index, line) in lines.enumerated() {
        if var block = open {
            if line.hasPrefix("```") {
                examples.append(SkillExample(file: path, line: block.line, command: block.command, fails: block.fails,
                                             script: block.body.joined(separator: "\n")))
                open = nil
            } else {
                block.body.append(line)
                open = block
            }
        } else if line.hasPrefix("```") {
            let tag = line.dropFirst(3)
            let fails = tag.hasSuffix("-error")
            if let command = SkillExample.Command(rawValue: String(fails ? tag.dropLast("-error".count) : tag)) {
                open = (index + 1, command, fails, [])
            }
        }
    }
    return examples
}

/// The boards a skill file's examples may run on, by the name its first line gives (`<!-- board:
/// query-story -->`): a story, as the app opens it. A file with no such line runs on a new board.
/// Each is the board of exactly one file.
@MainActor let skillStories: [String: @MainActor () throws -> BoardDocument] = [
    "query-story": { try QueryStory.document(windowed: false) },
    "reference-story": { try QueryReferenceStory.document(windowed: false) },
]

/// The sample ids a skill file writes in its first line (`<!-- ids: 7C1E…, B3D9… -->`): ids a block can't know before the board
/// is drawn, written in the blocks of the page as a reader would see them. A block is run with each sample replaced by the id of
/// the shape the same place of the last query that found as many (`SampleIDs`): the first sample is the first row's.
func skillSampleIDs(in text: String) -> [String] {
    guard let first = text.components(separatedBy: "\n").first, first.hasPrefix("<!-- ids: "), first.hasSuffix(" -->") else { return [] }
    return first.dropFirst("<!-- ids: ".count).dropLast(" -->".count).components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
}

/// What a page's sample ids stand for as the page runs: the ids of the rows the last query that listed enough of them answered,
/// in order.
struct SampleIDs {
    let samples: [String]
    private(set) var bound: [String] = []

    init(_ samples: [String]) { self.samples = samples }

    /// A query that answered these rows, which names none of the samples: the samples stand for them from now on, if there are enough.
    mutating func found(_ ids: [String], by example: SkillExample) {
        guard !samples.isEmpty, ids.count >= samples.count, !samples.contains(where: { example.script.contains($0) }) else { return }
        bound = ids
    }

    /// The example with each sample id replaced by the id it stands for.
    func resolved(_ example: SkillExample) -> SkillExample {
        guard !bound.isEmpty else { return example }
        var script = example.script
        for (sample, id) in zip(samples, bound) { script = script.replacingOccurrences(of: sample, with: id) }
        return SkillExample(file: example.file, line: example.line, command: example.command, fails: example.fails, script: script)
    }
}

/// The story a skill file names in its first line: nil for none.
func skillStoryName(in text: String) -> String? {
    guard let first = text.components(separatedBy: "\n").first, first.hasPrefix("<!-- board: "), first.hasSuffix(" -->") else { return nil }
    return String(first.dropFirst("<!-- board: ".count).dropLast(" -->".count))
}

/// A board as the app makes a new one, in a window of 1440 × 900 points: its view is (0, 0) to
/// (1440, 900).
@MainActor func windowedBoard() -> BoardDocument {
    let board = newBoard()
    board.editor.viewportDidResize(to: CGSize(width: 1440, height: 900))
    return board
}

/// `canvas draw -` with `script` on standard input, on `board`.
@MainActor func draw(_ script: String, on board: BoardDocument, _ server: CommandServer, _ options: [String] = []) throws -> ProcessOutput {
    try canvas(server, ["draw", "-", "--board", "\(board.number)"] + options, input: script)
}

/// Whether to print what each example said (SKILL_DUMP=1).
let dumpsExamples = ProcessInfo.processInfo.environment["SKILL_DUMP"] == "1"

/// Runs a skill file's query example on `board`, and holds it to what it says it answers, or the
/// reason it says it's refused, and to changing nothing.
@MainActor @discardableResult func runQueryExample(_ example: SkillExample, on board: BoardDocument, _ server: CommandServer) throws -> [String] {
    let file = board.editor.file, edited = board.isDocumentEdited
    let undo = (board.editor.undoHistory.canUndo, board.editor.undoHistory.undoName, board.editor.undoHistory.canRedo)
    let result = try canvas(server, ["query", "-", "--board", "\(board.number)"], input: example.script)
    if dumpsExamples { print("== \(example.place)\n\(example.script)\n\(result.output)\(result.error)") }
    if example.fails {
        expectEqual(result.status, 1, "\(example.place) should be refused: \(result.output)\(result.error)")
        let reason = (try? JSON(text: result.error))?["error"]?["reason"]?.stringValue
        expect(example.reason != nil, "\(example.place) says the reason it's refused: /* reason: … */")
        expectEqual(reason, example.reason, "\(example.place): \(result.error)")
    } else {
        expectEqual(result.status, 0, "\(example.place) should answer: \(result.error)")
        let answer = (try? JSON(text: result.output)) ?? .null
        let rows = answer["rows"]?.arrayValue ?? []
        switch (example.matches, example.count) {
        case (let matches?, nil):
            expectEqual(rows.map(skillLabel), matches, "\(example.place) matches")
            expectEqual(answer["count"], .number(Double(matches.count)), "\(example.place): every shape it matches, listed")
        case (nil, let count?):
            expectEqual(answer["count"], .number(Double(count)), "\(example.place) counts")
        default:
            expect(false, "\(example.place) says what it answers, on its first line: /* matches: … */ or /* count: N */")
        }
    }
    expectEqual(board.editor.file, file, "\(example.place) changed nothing")
    expectEqual(board.isDocumentEdited, edited, "\(example.place) edited nothing")
    expect(board.editor.undoHistory.canUndo == undo.0 && board.editor.undoHistory.undoName == undo.1 && board.editor.undoHistory.canRedo == undo.2,
           "\(example.place) made no step to undo")
    return ((try? JSON(text: result.output))?["rows"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
}

@MainActor let skillTests = Suite("The canvas skill", [
    test("every example in the skill runs as it says: each file's blocks in order on a board of its own") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let files = try skillFiles()
        expect(files.count >= 3, "SKILL.md and the references: \(files)")
        var ran = 0, filesOnStory: [String: [String]] = [:]
        for file in files {
            let text = try String(contentsOfFile: file, encoding: .utf8)
            let story = skillStoryName(in: text)
            var samples = SampleIDs(skillSampleIDs(in: text))
            let make = story.flatMap { skillStories[$0] }
            expect(story == nil || make != nil, "\(file) names a story that isn't one: \(story ?? "")")
            let onStory = make != nil
            let board = try make?() ?? windowedBoard()
            defer { board.close() }
            if let story, onStory {
                filesOnStory[story, default: []].append(file)
                expect(!board.isDocumentEdited && !board.editor.undoHistory.canUndo, "\(file): the story as the app opens it")
            }
            let server = try startCommandServer(boards: [board], frontmost: board)
            defer { server.stop() }
            let examples = try skillExamples(in: file)
            expect(!examples.isEmpty, "\(file) has examples")
            for written in examples {
                ran += 1
                // A page's sample ids stand for the shapes its last query found, wherever the blocks write them.
                let example = samples.resolved(written)
                guard example.command == .draw else {
                    let found = try runQueryExample(example, on: board, server)
                    samples.found(found, by: written)
                    continue
                }
                let before = board.editor.document
                let result = try draw(example.script, on: board, server, example.fails ? ["--dry-run"] : [])
                if dumpsExamples { print("== \(example.place)\n\(example.script)\n\(result.output)\(result.error)") }
                if example.fails {
                    expectEqual(result.status, 1, "\(example.place) should fail: \(result.output)\(result.error)")
                    if let reason = example.reason {
                        expectEqual((try? JSON(text: result.error))?["error"]?["reason"]?.stringValue, reason, "\(example.place): \(result.error)")
                    }
                    expectEqual(board.editor.document, before, "\(example.place) changed nothing")
                } else {
                    expectEqual(result.status, 0, "\(example.place) should draw: \(result.error)")
                    guard result.status == 0 else { continue }
                    let pushed = (try JSON(text: result.output)["changes"]?.arrayValue ?? []).filter { $0["pushedPast"] != nil }
                    expectEqual(pushed, [], "\(example.place) pushes nothing aside")
                }
            }
            if !samples.samples.isEmpty {
                expect(samples.bound.count >= samples.samples.count, "\(file): a query on the page answers the shapes its sample ids stand for")
                expect(Set(samples.bound).isDisjoint(with: samples.samples), "\(file): the sample ids are not the board's own")
            }
            if onStory {
                expect(!board.isDocumentEdited && !board.editor.undoHistory.canUndo, "\(file): its queries left the story as it was")
            }
        }
        expect(ran > 30, "the skill has its examples: \(ran)")
        for story in skillStories.keys.sorted() {
            expectEqual(filesOnStory[story]?.map { ($0 as NSString).lastPathComponent }.count, 1, "\(story) is the board of exactly one file: \(filesOnStory[story] ?? [])")
        }
        expectEqual((filesOnStory["query-story"] ?? []).map { ($0 as NSString).lastPathComponent }, ["query.md"], "reference/query.md runs on the story")
        expectEqual((filesOnStory["reference-story"] ?? []).map { ($0 as NSString).lastPathComponent }, ["references.md"], "reference/references.md runs on its story")
    },
    test("SKILL.md's description fits the frontmatter's 1,024 characters, and says both what draws and what reads") {
        let skill = try String(contentsOfFile: "\(skillFolder)/SKILL.md", encoding: .utf8)
        let lines = skill.components(separatedBy: "\n")
        expectEqual(lines.first, "---")
        let end = try require(lines.dropFirst().firstIndex(of: "---"), "the frontmatter ends")
        let description = try require(lines[1..<end].first { $0.hasPrefix("description: ") }, "the frontmatter's description")
            .dropFirst("description: ".count)
        expect(description.count <= 1_024, "\(description.count) characters")
        expect(description.contains("`canvas draw`") && description.contains("`canvas query`"), String(description))
    },
    test("every endRule the skill writes in its prose is a JSON object, as canvas draw reads it") {
        for file in try skillFiles() {
            let text = try String(contentsOfFile: file, encoding: .utf8)
            let pattern = try NSRegularExpression(pattern: #"endRule: (\{[^}]*\})"#)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let written = (text as NSString).substring(with: match.range(at: 1))
                let object = try? JSONSerialization.jsonObject(with: Data(written.utf8))
                expect(object is [String: Any], "\(file): \(written) is not a JSON object")
            }
        }
    },
    test("the reference's table of an edge's keys has a row for each key the language keeps for edges, and its measure section names every member canvas measure answers") {
        let reference = try String(contentsOfFile: "\(skillFolder)/reference/language.md", encoding: .utf8)
        let skill = try String(contentsOfFile: "\(skillFolder)/SKILL.md", encoding: .utf8)
        let edgeKeys = try require(markdownTables(in: reference).first { table in table.contains { backticked($0[0]) == ["from:"] } }, "the table of an edge's keys")
        let written = Set(edgeKeys.dropFirst().compactMap { backticked($0[0]).first })
        for key in EdgeKey.allCases { expect(written.contains("\(key.rawValue):"), "the reference's table of an edge's keys has \(key.rawValue):") }
        expect(skill.contains("share: true") && skill.contains(#"share: "Checkout""#), "SKILL.md teaches share:")
        expect(skill.contains("build/canvas measure -"), "SKILL.md points to measure")

        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let commands = registry.hostCommands
        let script = "sticky-note \"A\" text: \"x\"\nsticky-note \"B\" public: true\nedge \"A\" -> \"B\" via: reference\nsticky-note \"C\" is: \"Nobody\""
        let answer = try awaitResult { try await commands.run("measure", ["script": .string(script)], nil) }
        let start = try require(reference.range(of: "## Measuring a script")), end = try require(reference.range(of: "## Errors"))
        let section = String(reference[start.lowerBound..<end.lowerBound])
        var members = Set(answer.objectValue?.keys.map { $0 } ?? [])
        for row in answer["shapes"]?.arrayValue ?? [] { members.formUnion(row.objectValue?.keys.map { $0 } ?? []) }
        for row in answer["references"]?.arrayValue ?? [] { members.formUnion(row.objectValue?.keys.map { $0 } ?? []) }
        for row in answer["warnings"]?.arrayValue ?? [] { members.formUnion(row.objectValue?.keys.map { $0 } ?? []) }
        expect(members.contains("warnings"), "a name measure can't find is a warning: \(members.sorted())")
        // `board` is the app's, for a board command run on one; held by MeasureTests, where a board is in front.
        expect(section.contains("`board`"), "...and it says the board it read")
        members.formUnion(answer["constants"]?.objectValue?.keys.map { $0 } ?? [])
        expect(members.count >= 15, "measure answers: \(members.sorted())")
        for member in members.sorted() { expect(section.contains("`\(member)`"), "the reference's section on measure names \(member)") }
        for name in GapName.allCases { expect(section.contains(name.rawValue), "...and the gap \(name.rawValue)") }
    },
    test("the reference's table of an edge's keys has a row for each key an edge is written with, and for no other: the language's own and the arrow's attributes as canvas kinds says them, its heads aside") {
        let reference = try String(contentsOfFile: "\(skillFolder)/reference/language.md", encoding: .utf8)
        let table = try require(markdownTables(in: reference).first { table in table.contains { backticked($0[0]) == ["from:"] } }, "the table of an edge's keys")
        let written = Set(table.dropFirst().compactMap { backticked($0[0]).first })
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let listed = try awaitResult { try await registry.hostCommands.run("kinds", [:], nil) }.arrayValue ?? []
        let arrow = try require(listed.first { $0["kind"]?.stringValue == "arrow" }, "canvas kinds lists the arrow")
        let heads: Set<String> = ["startArrowhead", "endArrowhead"]
        var keys = Set(EdgeKey.allCases.map(\.rawValue))
        keys.formUnion((arrow["attributes"]?.objectValue?.keys.map { $0 } ?? []).filter { !heads.contains($0) })
        for key in ["is", "fieldValues", "endRule", "channel", "text"] { expect(keys.contains(key), "an edge is written with \(key): \(keys.sorted())") }
        for key in keys.sorted() { expect(written.contains("\(key):"), "the reference's table of an edge's keys has \(key):") }
        for row in written.sorted() { expect(keys.contains(String(row.dropLast())), "...and \(row) is a key an edge is written with") }
    },
    test("the query reference has every construct of the design's table as a block, answering or refused as the table says") {
        let examples = try skillExamples(in: "\(skillFolder)/reference/query.md")
        /// How `matches:` writes each of the story's shapes.
        let labels = ["P": #""Payments""#, "A": #""API gateway""#, "U": #""Auth""#, "N1": "(sticky-note)", "W": #""Warehouse""#,
                      "S": #""Order""#, "V": "(sticky-note)", "R1": "(arrow)", "R2": "(arrow)", "L": #""Ledger""#, "T1": #""Person""#, "T2": #""Employee card""#, "I": #""Ann""#, "C": #""Checkout""#,
                      "F": #""Refunds""#, "N2": "(sticky-note)", "Y": #""Refund policy""#]
        for row in StoryQuery.table {
            let said = "row \(row.number), \(row.query)"
            let block = examples.first { example in
                example.command == .query && example.script.components(separatedBy: "\n").dropFirst().joined(separator: "\n") == row.query
            }
            guard let block else {
                expect(false, "\(said) is a block of reference/query.md")
                continue
            }
            switch row.answer {
            case .shapes(let letters):
                expect(!block.fails, "\(block.place): \(said) answers")
                let shapes = letters.split(separator: ",").map { labels[$0.trimmingCharacters(in: .whitespaces)] ?? "?" }
                expect(block.matches == shapes || block.count == shapes.count, "\(block.place): \(said) answers \(shapes)")
            case .refused(let reason):
                expect(block.fails, "\(block.place): \(said) is refused")
                expectEqual(block.reason, reason.rawValue, "\(block.place): \(said)")
            }
        }
    },
    test("the query reference's tables of plugins' words and edge types are what canvas query-vocabulary says") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let registry = try ShippedPlugins.registry(pasteboard: pasteboard, model: ScriptedLanguageModel())
        let commands = registry.hostCommands
        let vocabulary = try awaitResult { try await commands.run("query-vocabulary", [:], nil) }
        let reference = try String(contentsOfFile: "\(skillFolder)/reference/query.md", encoding: .utf8)
        let tables = markdownTables(in: reference)

        // Each word a plugin adds: its form in backticks (`:mentions(S)`), the plugin whose it is,
        // and what it means, in the vocabulary's order.
        let words = try require(tables.first { $0.first == ["pseudo-class", "from", "means"] }, "the reference's table of plugins' words")
        let listed = words.dropFirst().map { row -> [String] in
            let form = backticked(row[0]).first ?? row[0]
            let word = form.drop { $0 == ":" }.prefix { $0 != "(" }
            return [String(word), backticked(row[1]).first ?? row[1], row[2]]
        }
        let added = (vocabulary["words"]?.arrayValue ?? []).filter { $0["from"] != "queries" }.map { word in
            [word["word"]?.stringValue ?? "?", word["from"]?.stringValue ?? "?", word["summary"]?.stringValue ?? "?"]
        }
        expect(!added.isEmpty, "the shipped plugins add words")
        expectEqual(listed, added, "the reference's plugins' words")

        // Each edge type, the type it's under (— for a root) and what it means, in the tree's order.
        let types = try require(tables.first { $0.first == ["edge type", "under", "means"] }, "the reference's table of edge types")
        let written = types.dropFirst().map { row in [backticked(row[0]).first ?? row[0], backticked(row[1]).first ?? "", row[2]] }
        let declared = (vocabulary["edgeTypes"]?.arrayValue ?? []).map { type in
            [type["type"]?.stringValue ?? "?", type["under"]?.stringValue ?? "", type["summary"]?.stringValue ?? ""]
        }
        expectEqual(written, declared, "the reference's edge types")
    },
    test("the skill's tables of kinds are what canvas kinds says: every drawable kind, its size, its attributes, its channels by side, and its smallest") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let commands = registry.hostCommands
        let listed = try awaitResult { try await commands.run("kinds", [:], nil) }.arrayValue ?? []
        var kinds: [String: JSON] = [:]
        for kind in listed where kind["drawable"] == true { kinds[kind["kind"]?.stringValue ?? "?"] = kind }
        expect(kinds.count >= 3, "the shipped kinds: \(kinds.keys.sorted())")
        /// A kind's channels, each with the sides an edge may leave it by on it.
        @MainActor func channels(_ kind: String) -> [String: Set<String>] {
            var sides: [String: Set<String>] = [:]
            for (side, on) in kinds[kind]?["edges"]?.objectValue ?? [:] {
                for channel in on.arrayValue?.compactMap(\.stringValue) ?? [] { sides[channel, default: []].insert(side) }
            }
            return sides
        }
        /// What a cell says of a kind's channels: `none…`, or each channel in backticks, on the sides it names.
        @MainActor func said(_ cell: String) -> [String: Set<String>] {
            guard !cell.hasPrefix("none") else { return [:] }
            return Dictionary(backticked(cell).map { ($0, sideWords(cell)) }) { first, _ in first }
        }
        @MainActor func attributes(_ kind: String) -> Set<String> { Set(kinds[kind]?["attributes"]?.objectValue?.keys.map { $0 } ?? []) }

        let skill = try String(contentsOfFile: "\(skillFolder)/SKILL.md", encoding: .utf8)
        let tour = try require(markdownTables(in: skill).first { $0.first?.first == "kind" }, "SKILL.md's table of kinds")
        expectEqual(Set(tour.dropFirst().compactMap { backticked($0[0]).first }), Set(kinds.keys), "SKILL.md lists every drawable kind")
        for row in tour.dropFirst() where row.count == 4 {
            let kind = backticked(row[0]).first ?? "?"
            expectEqual(row[1], kinds[kind]?["size"]?.stringValue, "SKILL.md: \(kind)'s size")
            let written = attributeList(row[2])
            expectEqual(Set(written.map(\.name)), attributes(kind), "SKILL.md: \(kind)'s attributes")
            for (name, choices) in written {
                guard let choices, let takes = kinds[kind]?["attributes"]?[name]?.stringValue, takes.contains("|") else { continue }
                expectEqual(choices, takes.components(separatedBy: "|"), "SKILL.md: \(kind)'s \(name)")
            }
            expectEqual(said(row[3]), channels(kind), "SKILL.md: \(kind)'s edges")
        }

        let reference = try String(contentsOfFile: "\(skillFolder)/reference/language.md", encoding: .utf8)
        let tables = markdownTables(in: reference).filter { $0.first?.first == "kind" }
        let shapes = try require(tables.first { $0.first?.count == 5 }, "the reference's table of kinds")
        expectEqual(Set(shapes.dropFirst().compactMap { backticked($0[0]).first }), Set(kinds.keys), "the reference lists every drawable kind")
        for row in shapes.dropFirst() where row.count == 5 {
            let kind = backticked(row[0]).first ?? "?"
            expectEqual(row[1], kinds[kind]?["size"]?.stringValue, "the reference: \(kind)'s size")
            expectEqual(said(row[4]), channels(kind), "the reference: \(kind)'s edges")
        }
        let ports = try require(tables.first { $0.first == ["kind", "channels", "sides"] }, "the reference's table of channels")
        var inPorts: Set<String> = []
        for row in ports.dropFirst() where row.count == 3 {
            for kind in backticked(row[0]) {
                inPorts.insert(kind)
                expectEqual(row[1] == "none" ? [:] : Dictionary(backticked(row[1]).map { ($0, sideWords(row[2])) }) { first, _ in first }, channels(kind),
                            "the reference: \(kind)'s channels")
            }
        }
        expectEqual(inPorts, Set(kinds.keys), "the reference's channels, for every drawable kind")
        var inBullets: Set<String> = []
        for line in reference.components(separatedBy: "\n") where line.hasPrefix("- **") {
            guard let colon = line.range(of: ": ") else { continue }
            let named = boldWords(String(line[..<colon.lowerBound])).filter { kinds[$0] != nil }
            for kind in named {
                inBullets.insert(kind)
                expectEqual(Set(attributeList(String(line[colon.upperBound...])).map(\.name)), attributes(kind), "the reference: \(kind)'s attributes")
            }
        }
        expectEqual(inBullets, Set(kinds.keys), "the reference's attributes, for every drawable kind")

        // The smallest a kind is drawn, where it has one, as both pages say it.
        let smallest = kinds.compactMapValues { $0["smallest"]?.stringValue }
        expect(!smallest.isEmpty, "a shipped kind has a smallest size (a frame)")
        for (kind, size) in smallest {
            expect(skill.contains("\(kind) is at least \(size)"), "SKILL.md: a \(kind) is at least \(size)")
            expect(reference.contains("\(kind) is at least \(size)"), "the reference: a \(kind) is at least \(size)")
        }
    },
])

/// A Markdown file's tables, each its rows (the header first), each row its cells, trimmed; the
/// line under the header left out. A `|` escaped (`\|`, in a cell's code) is the cell's.
func markdownTables(in text: String) -> [[[String]]] {
    var tables: [[[String]]] = [], table: [[String]] = []
    for line in text.components(separatedBy: "\n") {
        guard line.hasPrefix("|") else {
            if !table.isEmpty { tables.append(table) }
            table = []
            continue
        }
        let escaped = "\u{0}"
        let cells = line.replacingOccurrences(of: "\\|", with: escaped).split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast()
            .map { $0.replacingOccurrences(of: escaped, with: "|").trimmingCharacters(in: .whitespaces) }
        if cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { continue }
        table.append(cells)
    }
    if !table.isEmpty { tables.append(table) }
    return tables
}

/// What's in backticks, in order.
func backticked(_ text: String) -> [String] {
    text.components(separatedBy: "`").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
}

/// What's in bold, in order.
func boldWords(_ text: String) -> [String] {
    text.components(separatedBy: "**").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
}

/// The sides a cell names: `top`, `right`, `bottom`, `left`, or all four.
func sideWords(_ text: String) -> Set<String> {
    let all: Set<String> = ["top", "right", "bottom", "left"]
    if text.contains("all four") { return all }
    return all.filter { side in text.split(whereSeparator: { !$0.isLetter }).contains { $0 == side } }
}

/// Attributes as the skill lists them: each a name in backticks, and its choices in brackets after
/// it (`status` (todo, doing, blocked, done)), if the brackets hold only words; backticks inside
/// brackets are what the attribute takes, not attributes.
func attributeList(_ text: String) -> [(name: String, choices: [String]?)] {
    var found: [(name: String, choices: [String]?)] = []
    var rest = Substring(text), depth = 0, bracket = ""
    while let character = rest.popFirst() {
        switch character {
        case "(":
            depth += 1
            bracket = ""
        case ")":
            depth -= 1
            if depth == 0, !found.isEmpty, found[found.count - 1].choices == nil {
                let words = bracket.components(separatedBy: ", ")
                if words.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isLetter) }) { found[found.count - 1].choices = words }
            }
        case "`" where depth == 0:
            guard let end = rest.firstIndex(of: "`") else { return found }
            found.append((String(rest[..<end]), nil))
            rest = rest[rest.index(after: end)...]
        default:
            if depth > 0 { bracket.append(character) }
        }
    }
    return found
}
