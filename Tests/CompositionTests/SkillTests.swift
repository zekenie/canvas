import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasUI
import Composition
import Foundation
import LanguageModels
import TestKit

// The canvas skill (.claude/skills/canvas) teaches agents `canvas draw` by example, so its examples
// must run: each file's blocks, in order, on a fresh board of its own in a 1440 × 900 window,
// through `canvas` as built, against the app's command server. A block tagged `draw` runs for real
// and must succeed, pushing nothing aside (an example says where things go); one tagged
// `draw-error` runs as a dry run and must fail, with the reason its first line names
// (`// reason: <reason>`), changing nothing. SKILL_DUMP=1 prints what each example said, for
// checking the prose around it.

/// Where the skill is, from the repository's root (where tests run).
let skillFolder = ".claude/skills/canvas"

/// A fenced example in a skill file.
struct SkillExample {
    let file: String
    /// The line its fence opens on.
    let line: Int
    let fails: Bool
    let script: String
    /// The reason a failing one names.
    var reason: String? {
        guard let first = script.split(separator: "\n", omittingEmptySubsequences: false).first,
              let range = first.range(of: "// reason:") else { return nil }
        return first[range.upperBound...].trimmingCharacters(in: .whitespaces)
    }
    var place: String { "\(file):\(line)" }
}

/// The skill's files: SKILL.md, then its references.
func skillFiles() throws -> [String] {
    let references = try FileManager.default.contentsOfDirectory(atPath: "\(skillFolder)/reference").filter { $0.hasSuffix(".md") }.sorted()
    return ["\(skillFolder)/SKILL.md"] + references.map { "\(skillFolder)/reference/\($0)" }
}

/// A file's ```draw and ```draw-error blocks, in order.
func skillExamples(in path: String) throws -> [SkillExample] {
    let lines = try String(contentsOfFile: path, encoding: .utf8).components(separatedBy: "\n")
    var examples: [SkillExample] = []
    var open: (line: Int, fails: Bool, body: [String])?
    for (index, line) in lines.enumerated() {
        if var block = open {
            if line.hasPrefix("```") {
                examples.append(SkillExample(file: path, line: block.line, fails: block.fails, script: block.body.joined(separator: "\n")))
                open = nil
            } else {
                block.body.append(line)
                open = block
            }
        } else if line == "```draw" || line == "```draw-error" {
            open = (index + 1, line == "```draw-error", [])
        }
    }
    return examples
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

@MainActor let skillTests = Suite("The canvas skill", [
    test("every example in the skill runs as it says: each file's blocks in order on a board of its own") {
        try configureBoards()
        let files = try skillFiles()
        expect(files.count >= 2, "SKILL.md and a reference: \(files)")
        var ran = 0
        for file in files {
            let board = windowedBoard()
            let server = try startCommandServer(boards: [board], frontmost: board)
            defer { server.stop() }
            let examples = try skillExamples(in: file)
            expect(!examples.isEmpty, "\(file) has examples")
            for example in examples {
                ran += 1
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
        }
        expect(ran > 30, "the skill has its examples: \(ran)")
    },
    test("the skill's tables of kinds are what canvas kinds says: every drawable kind, its size, its attributes, its channels by side") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let listed = try ShippedPlugins.commands(in: registry).run("kinds", [:], nil).arrayValue ?? []
        var kinds: [String: JSON] = [:]
        for kind in listed where kind["drawable"] == true { kinds[kind["kind"]?.stringValue ?? "?"] = kind }
        expect(kinds.count >= 4, "the shipped kinds: \(kinds.keys.sorted())")
        /// A kind's channels, each with the sides an edge may leave it by on it.
        @MainActor func channels(_ kind: String) -> [String: Set<String>] {
            var sides: [String: Set<String>] = [:]
            for (side, on) in kinds[kind]?["edges"]?.objectValue ?? [:] {
                for channel in on.arrayValue?.compactMap(\.stringValue) ?? [] { sides[channel, default: []].insert(side) }
            }
            return sides
        }
        /// What a cell says of a kind's channels: `none…`, or a channel in backticks and its sides.
        @MainActor func said(_ cell: String, channel: String? = nil) -> [String: Set<String>] {
            guard let channel = channel ?? backticked(cell).first, !cell.hasPrefix("none") else { return [:] }
            return [channel: sideWords(cell)]
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
        let ports = try require(tables.first { $0.first == ["kind", "channel", "sides"] }, "the reference's table of channels")
        var inPorts: Set<String> = []
        for row in ports.dropFirst() where row.count == 3 {
            for kind in backticked(row[0]) {
                inPorts.insert(kind)
                expectEqual(row[1] == "none" ? [:] : [backticked(row[1]).first ?? "?": sideWords(row[2])], channels(kind), "the reference: \(kind)'s channels")
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
    },
])

/// A Markdown file's tables, each its rows (the header first), each row its cells, trimmed; the
/// line under the header left out.
func markdownTables(in text: String) -> [[[String]]] {
    var tables: [[[String]]] = [], table: [[String]] = []
    for line in text.components(separatedBy: "\n") {
        guard line.hasPrefix("|") else {
            if !table.isEmpty { tables.append(table) }
            table = []
            continue
        }
        let cells = line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast().map { $0.trimmingCharacters(in: .whitespaces) }
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
