import Foundation
@_spi(Host) import Canvas
import CanvasRPC
import LanguageModels
import ShippedTesting
import SkillTesting
import TestKit

// The canvas skill's page of kinds (.claude/skills/canvas/reference/kinds.md), the digest tool's copy of the kinds it
// reads (.claude/skills/canvas-digest/tool/test/fixtures/kinds.json) and the answer whole, which the tool's names guard
// reads every name of the app from (kinds.answer.json) are written from `canvas kinds`, the shipped plugins' answer, never
// by hand. The test holds each byte for byte; with CANVAS_WRITE_KIND_PAGES=1 it writes them instead (`mise run skill:kinds`).

private let kindsPage = ".claude/skills/canvas/reference/kinds.md"
private let writeKindPages = ProcessInfo.processInfo.environment["CANVAS_WRITE_KIND_PAGES"] == "1"

/// `canvas kinds`' answer, as the shipped registry gives it to the host command.
@MainActor private func shippedKinds() throws -> [JSON] {
    let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
    let commands = registry.hostCommands
    return try awaitResult { try await commands.run("kinds", [:], nil) }.arrayValue ?? []
}

private func code(_ text: String) -> String { "`\(text)`" }
/// A table cell: a `|` in it escaped.
private func cell(_ text: String) -> String { text.replacingOccurrences(of: "|", with: "\\|") }

private let sideOrder = ["top", "right", "bottom", "left"]

/// The page of kinds: a section for each drawable kind by name, then the kind edges are (the arrow), each as
/// `canvas kinds` says it.
private func renderKindsPage(_ answer: [JSON]) -> String {
    var out = """
    # The kinds

    <!-- Generated from `canvas kinds` by the kind-pages test (Tests/CompositionTests/KindPagesTests.swift).
    Don't edit it: `mise run skill:kinds` writes it again. -->

    Generated from `canvas kinds`, the app's own answer, so it is what the installed plugins say today; `mise run skill:kinds` writes it again. [language.md](language.md)
    says what the words in it do; `canvas kinds <kind> --schema` adds a kind's JSON Schema.

    """
    func section(_ kind: JSON) {
        let name = kind["kind"]?.stringValue ?? "?"
        out += "\n## \(code(name))\n\n"
        var lead: [String] = []
        if let title = kind["title"]?.stringValue { lead.append("called \(title)") }
        if let tool = kind["tool"]?.stringValue { lead.append("placed by the \(tool) tool") }
        if !lead.isEmpty { out += lead.joined(separator: ", ").prefix(1).uppercased() + lead.joined(separator: ", ").dropFirst() + "\n\n" }
        if kind["drawable"] == false, let why = kind["why"]?.stringValue { out += "Not drawn on its own: \(why).\n\n" }
        var facts: [String] = []
        if let size = kind["size"]?.stringValue { facts.append("- **size**: \(code(size))") }
        if let smallest = kind["smallest"]?.stringValue { facts.append("- **smallest**: \(code(smallest)); a `size:` under it is refused") }
        if let holds = kind["holds"]?.stringValue { facts.append("- **holds**: \(code(holds)); `in \"X\"` names it") }
        if let names = kind["names"]?.stringValue { facts.append("- **named**: \(code(names))") }
        if !facts.isEmpty { out += facts.joined(separator: "\n") + "\n\n" }
        let attributes = kind["attributes"]?.objectValue ?? [:]
        if !attributes.isEmpty {
            out += "| attribute | takes |\n|---|---|\n"
            for key in attributes.keys.sorted() { out += "| \(code(key)) | \(cell(attributes[key]?.stringValue ?? "")) |\n" }
            out += "\n"
        }
        let edges = kind["edges"]?.objectValue ?? [:]
        if edges.isEmpty {
            out += "**edges**: none\n"
        } else {
            out += "| edges leave by | channels |\n|---|---|\n"
            for side in sideOrder + edges.keys.filter({ !sideOrder.contains($0) }).sorted() {
                guard let channels = edges[side]?.arrayValue?.compactMap(\.stringValue) else { continue }
                out += "| \(side) | \(channels.map(code).joined(separator: ", ")) |\n"
            }
        }
        if let via = kind["via"]?.arrayValue, !via.isEmpty {
            out += "\n**via**: " + via.map { pill in
                let needs = pill["needs"]?.stringValue.map { " (needs \(code($0)))" } ?? ""
                return code(pill["kind"]?.stringValue ?? "?") + needs
            }.joined(separator: ", ") + " can stand for it\n"
        }
    }
    let sorted = answer.sorted { ($0["kind"]?.stringValue ?? "") < ($1["kind"]?.stringValue ?? "") }
    for kind in sorted where kind["drawable"] == true { section(kind) }
    for kind in sorted where kind["drawable"] == false && kind["why"]?.stringValue?.hasPrefix("it joins two shapes") == true { section(kind) }
    return out
}

/// A JSON list of objects on one line, as a list with an object a line: `[` and `]` on lines of their own, the objects as they were written.
private func oneKindALine(_ list: String) -> String {
    var objects: [String] = [], depth = 0, inString = false, escaped = false, start = list.startIndex
    for index in list.indices {
        let character = list[index]
        if inString {
            if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
        } else if character == "\"" {
            inString = true
        } else if character == "{" {
            if depth == 0 { start = index }
            depth += 1
        } else if character == "}" {
            depth -= 1
            if depth == 0 { objects.append(String(list[start...index])) }
        }
    }
    return "[\n" + objects.map { " " + $0 }.joined(separator: ",\n") + "\n]\n"
}

let kindPageTestName = "the skill's page of kinds and the digest tool's copies of them are what canvas kinds says, byte for byte"

@MainActor let kindPagesTests = Suite("Kind pages", [
    test(kindPageTestName) {
        let answer = try shippedKinds()
        expect(answer.contains { $0["kind"] == "sticky-note" && $0["drawable"] == true }, "the shipped kinds: \(answer.compactMap { $0["kind"]?.stringValue })")

        // The tool's reading of the answer (`extract kinds`), as the file holds it: the tool's own text (its keys in its order, which its
        // tests compare), a kind a line, a last newline.
        let folder = try scratchFolder("kind-pages")
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("kinds.json")
        try JSONEncoder().encode(JSON.array(answer)).write(to: raw)
        let read = try run(URL(fileURLWithPath: jsc), [digestSkill("tool/main.js").path, "--", "extract", "kinds", raw.path], timeout: 120)
        expectEqual(read.status, 0, read.output + read.error)
        let fixture = oneKindALine(read.output.trimmingCharacters(in: .whitespacesAndNewlines))

        // The answer whole, a kind a line with its keys sorted: every kind, attribute, pill and channel name the render layer must not write.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let sorted = answer.sorted { ($0["kind"]?.stringValue ?? "") < ($1["kind"]?.stringValue ?? "") }
        let whole = oneKindALine(String(decoding: try encoder.encode(JSON.array(sorted)), as: UTF8.self))

        let page = renderKindsPage(answer)
        let files = [(kindsPage, page), (digestKinds().path, fixture), (digestSkill("tool/test/fixtures/kinds.answer.json").path, whole)]
        if writeKindPages {
            for (path, text) in files { try write(text, to: URL(fileURLWithPath: path)) }
            return
        }
        for (path, text) in files {
            let held = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            expect(held == text, "\(path) is not what canvas kinds says: write it again with `mise run skill:kinds`")
        }
    },
])
