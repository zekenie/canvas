import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import DrawScript
import Foundation
import Geometry
import HostSlots
import LanguageModels
import ShippedTesting
import StickyNotes
import TestKit
import Titles

// `canvas measure`, as shipped: the size draw makes each shape of a script and each reference an edge
// says `via:`, how far a shape's title row reaches above it, and the constants placement is done with,
// each held to what a draw of the same script makes on a board, or to the source it is read from; and
// that it reads no board, changes none and opens no undo step.

/// The shipped editor over an empty board in a 1440 × 900 window.
@MainActor private func shippedEditor() -> CanvasEditor {
    let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
    editor.viewportDidResize(to: CGSize(width: 1440, height: 900))
    return editor
}

/// `measure`, as the app's command server runs it (an app command: no board).
@MainActor private func measured(_ script: String, in editor: CanvasEditor) -> Result<JSON, RPCError> {
    let commands = editor.registry.hostCommands
    let result = try? awaitResult { () async -> Result<JSON, RPCError> in
        do throws(RPCError) {
            return .success(try await commands.run("measure", ["script": .string(script)], nil))
        } catch {
            return .failure(error)
        }
    }
    return result ?? .failure(RPCError(RPCError.internalError, reason: "timed_out", "measure didn't answer."))
}

/// The script with every shape statement after the first placed below it, as a draw of many shapes needs
/// (measure ignores placements, and takes the script without them).
private func placed(_ script: String, below first: String) -> String {
    var seen = false
    return script.split(separator: "\n", omittingEmptySubsequences: false).map { line in
        guard !line.hasPrefix("edge "), !line.isEmpty else { return String(line) }
        defer { seen = true }
        return seen ? "\(line) below \(quoted(first)) (gap: tight)" : String(line)
    }.joined(separator: "\n")
}

private func quoted(_ title: String) -> String { "\"\(title)\"" }

private func size(_ json: JSON?) -> [Double]? { json?.arrayValue?.compactMap(\.numberValue) }

/// A row's size, from its `at`: `[[x, y], [width, height]]`.
private func drawnSize(_ row: JSON) -> [Double]? { size(row["at"]?.arrayValue?.last) }

@MainActor let measureTests = Suite("canvas measure: what draw would make, read from the source", [
    test("each shape is the size draw makes it: a note 300 wide with text as tall as its text, a schema card, a subboard, a frame") {
        let schema = #"{"title": "Person", "type": "object", "properties": {"name": {"type": "string"}, "email": {"type": "string"}}}"#
        let long = String(repeating: "The checkout takes a basket and a card, charges it, and sends the receipt. ", count: 3)
        let script = """
            sticky-note "Checkout v2" size: 300x text: "\(long)"
            sticky-note "Plain"
            sticky-note "Wide" size: 420x text: "short"
            sticky-note "Exact" size: 250x90
            schema-card schema: "\(scripted(schema))" prompt: "A person who buys things, with the details we keep for them and why we keep each."
            schema-card schema: "\(scripted(schema.replacingOccurrences(of: "Person", with: "Plain")))"
            subboard "Payments"
            subboard "Big" size: 500x300
            frame "Region" size: 400x300
            frame "Least" size: 96x64
            """
        let measureEditor = shippedEditor()
        let asked = try measured(script, in: measureEditor).get()
        let shapes = try require(asked["shapes"]?.arrayValue)
        expectEqual(shapes.count, 10)
        // The same script drawn on a board of its own: every row's size is the one measure said.
        let drawEditor = shippedEditor()
        let drew = try drawnInProcess(placed(script, below: "Checkout v2"), on: drawEditor)
        let drawn = try require(drew["changes"]?.arrayValue)
        expectEqual(drawn.count, 10)
        for (measure, row) in zip(shapes, drawn) {
            expectEqual(measure["line"], row["line"])
            expectEqual(measure["kind"], row["kind"])
            expectEqual(measure["title"], row["title"], "\(measure["line"] ?? .null): the title draw reports, a card's from its schema")
            expectEqual(size(measure["size"]), drawnSize(row), "line \(measure["line"] ?? .null)")
        }
        let tall = try require(size(shapes[0]["size"]))
        expectEqual(tall[0], 300)
        expect(tall[1] > 112, "tall as its text at 300 wide, not the default height: \(tall)")
        expectEqual(size(shapes[3]["size"]), [250, 90], "a size written is the size")
        expectEqual(shapes[4]["title"], "Person")
        expectEqual(size(shapes[6]["size"]), try require(size(drawn[6]["at"]?.arrayValue?.last)))
        expectEqual(size(shapes[9]["size"]), [96, 64].map(Double.init), "a frame is never smaller than its least")
        expectEqual(drawEditor.document.shapes.count, 10)
        expectEqual(measureEditor.document.shapes.count, 0, "measured on a board of its own")
    },
    test("a reference is the pill draw makes for its end's title: three labels, the longest at the 280 clamp") {
        let titles = ["Auth", "Fraud review", Array(repeating: "A very long title for a note a pill stands for.", count: 4).joined(separator: " ")]
        var script = ""
        for (index, title) in titles.enumerated() {
            script += "sticky-note \"Start \(index)\"\nsticky-note \"\(title)\" public: true\n"
            script += "edge \"Start \(index)\" -> \"\(title)\" via: reference\n"
        }
        let asked = try measured(script, in: shippedEditor()).get()
        let references = try require(asked["references"]?.arrayValue)
        expectEqual(references.map { $0["for"] }, titles.map { JSON.string($0) })
        expectEqual(references.map { $0["line"] }, [3, 6, 9])
        let drawEditor = shippedEditor()
        let drew = try drawnInProcess(placed(script, below: "Start 0"), on: drawEditor)
        let pills = try require(drew["changes"]?.arrayValue).filter { $0["kind"] == "reference" }
        expectEqual(pills.count, 3)
        for (reference, pill) in zip(references, pills) {
            expectEqual(reference["line"], pill["line"])
            expectEqual(size(reference["size"]), drawnSize(pill), "the pill for \(reference["for"] ?? .null)")
        }
        let widths = references.compactMap { size($0["size"])?.first }
        expect(widths[0] < widths[1] && widths[1] < widths[2], "wider for a longer title: \(widths)")
        expectEqual(widths[2], 280, "clamped")
        expectEqual(references.compactMap { size($0["size"])?.last }, [32, 32, 32])
        // An edge that doesn't say via: is no reference to measure: whether it goes through one depends on the boards.
        let none = try measured("sticky-note \"A\"\nsticky-note \"B\"\nedge \"A\" -> \"B\"\n", in: shippedEditor()).get()
        expectEqual(none["references"]?.arrayValue?.count, 0)
    },
    test("above is how far the title row reaches over the shape: what draw draws, in world units at 100%") {
        let script = """
            sticky-note "Titled" size: 300x text: "Some text"
            sticky-note "Narrow" size: 40x40
            subboard "Boards"
            frame "Region" size: 400x300
            sticky-note
            """
        let editor = shippedEditor()
        let asked = try measured(script, in: editor).get()
        let drawEditor = shippedEditor()
        _ = try drawnInProcess(placed(script, below: "Titled"), on: drawEditor)
        expectEqual(drawEditor.camera.zoom, 1)
        let shapes = try require(asked["shapes"]?.arrayValue)
        var reaches: [Double] = []
        for (shape, record) in zip(shapes, drawEditor.document.shapes) {
            let top = try require(record.box).minY
            let reach = drawEditor.adornmentFrames(of: record.id).map { Double(top - $0.rect.minY) }.max() ?? 0
            expectEqual(shape["above"]?.numberValue, max(0, reach), "line \(shape["line"] ?? .null): \(shape["title"] ?? .null)")
            reaches.append(reach)
        }
        expect(reaches[0] > 0, "a titled note shows its pill above it")
        expectEqual(shapes[0]["above"]?.numberValue, 27, "the row: 9 above the top edge, 18 tall")
        expectEqual(shapes[4]["above"]?.numberValue, 0, "an untitled note shows nothing")
    },
    test("the constants are the source's: the gaps, the reference step, how far in a frame's content sits, the least sizes") {
        let asked = try measured("sticky-note \"A\"", in: shippedEditor()).get()
        let constants = try require(asked["constants"])
        let gaps = try require(constants["gaps"]?.objectValue)
        expectEqual(Set(gaps.keys), Set(GapName.allCases.map(\.rawValue)), "every named gap")
        for name in GapName.allCases { expectEqual(gaps[name.rawValue]?.numberValue, Double(name.value), name.rawValue) }
        expectEqual(constants["referenceStep"]?.numberValue, Double(LayoutProblem.impliedListStep))
        expectEqual(constants["defaultGap"]?.numberValue, Double(LayoutProblem.defaultGap))
        expectEqual(constants["listStep"]?.numberValue, Double(LayoutProblem.listStep))
        expectEqual(constants["horizontalClearance"]?.numberValue, Double(LayoutProblem.horizontalClearance))
        expectEqual(constants["verticalClearance"]?.numberValue, Double(LayoutProblem.verticalClearance))
        expectEqual(constants["frameInset"]?.numberValue, Double(LayoutProblem.insideGap))
        expectEqual(size(constants["smallest"]?["frame"]), [96, 64].map(Double.init))
        expectEqual(constants["smallest"]?.objectValue?.keys.sorted(), ["frame"], "the kinds that have a least")
        // And a draw does what they say: references 16 apart and 80 right of the start, content 40 in from a frame's top-left.
        let editor = shippedEditor()
        _ = try drawnInProcess("""
            sticky-note "Start"
            subboard "Other" below "Start"
            frame "Region" size: 400x300 below "Other"
            """, on: editor)
        _ = try drawnInProcess("""
            sticky-note "Far one" in "Other" public: true
            sticky-note "Far two" in "Other" public: true below "Far one"
            """, on: editor)
        _ = try drawnInProcess("""
            edge "Start" -> "Far one"
            edge "Start" -> "Far two"
            sticky-note "Inside" in "Region"
            """, on: editor)
        @MainActor func box(_ title: String) throws -> CGRect { try require(editor.document.shapes.first { editor.registry.title(of: $0) == title }?.box) }
        let start = try box("Start")
        let pills = editor.document.shapes.filter { $0.kind.rawValue == "reference" }.compactMap(\.box).sorted { $0.minY < $1.minY }
        expectEqual(pills.count, 2)
        expectEqual(pills[0].minX, start.maxX + (constants["defaultGap"]?.numberValue).map { CGFloat($0) }!)
        expectEqual(pills[1].minY - pills[0].maxY, (constants["referenceStep"]?.numberValue).map { CGFloat($0) }!)
        let region = try box("Region"), inside = try box("Inside")
        let inset = CGFloat(try require(constants["frameInset"]?.numberValue))
        expectEqual(inside.minX - region.minX, inset)
        expectEqual(inside.minY - region.minY, inset)
    },
    test("it reads nothing on the board and changes nothing: a title the board has is a new shape's, no undo step opens, and no board is needed") {
        try configureBoards()
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        expectEqual(try canvas(server, ["draw", #"sticky-note "Checkout v2" text: "Already here""#]).status, 0)
        let before = board.editor.file, revision = board.editor.revision, step = board.editor.undoHistory.undoName
        let result = try canvas(server, ["measure", "-"], input: "sticky-note \"Checkout v2\" size: 300x text: \"A new one\"\n")
        expectEqual(result.status, 0, result.error)
        let json = try JSON(text: result.output)
        expectEqual(json["shapes"]?.arrayValue?.count, 1)
        expectEqual(json["shapes"]?.arrayValue?.first?["title"], "Checkout v2")
        expect(board.editor.file == before, "the file is as it was")
        expectEqual(board.editor.revision, revision)
        expectEqual(board.editor.undoHistory.undoName, step)
        expect(!board.editor.undoHistory.isPressHeld)
        // Placements are ignored: against a shape nothing has, in a frame nothing has.
        let ignored = try canvas(server, ["measure", "-"], input: """
            sticky-note "One" right of "Nobody" (gap: wide)
            sticky-note "Two" in "Nowhere" below "One"
            sticky-note "Three" inside view top-left
            delete "Gone"
            style loud size: 400x
            sticky-note "Four" style: loud
            """)
        expectEqual(ignored.status, 0, ignored.error)
        let rows = try require(try JSON(text: ignored.output)["shapes"]?.arrayValue)
        expectEqual(rows.map { $0["title"] }, ["One", "Two", "Three", "Four"])
        expectEqual(rows.map { $0["line"] }, [1, 2, 3, 6])
        expectEqual(size(rows[3]["size"])?.first, 400, "a style's size still applies")
        // No board named, none in front: an app command, like kinds.
        let apart = try run(builtExecutable("CanvasCLI"), ["--socket", server.path, "help", "measure"])
        expectEqual(apart.status, 0, apart.error)
        expect(apart.output.contains("measure"), apart.output)
    },
    test("the answer, whole, through canvas as built: the JSON a tool reads") {
        try configureBoards()
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let result = try canvas(server, ["measure", "-"], input: """
            sticky-note "Checkout v2" size: 300x text: "Takes a basket and a card, charges it, and sends the receipt."
            frame "Region" size: 400x300
            sticky-note "Hub" public: true
            edge "Checkout v2" -> "Hub" via: reference
            """)
        expectEqual(result.status, 0, result.error)
        expectEqual(try JSON(text: result.output), [
            "shapes": [
                ["line": 1, "title": "Checkout v2", "kind": "sticky-note", "size": [300, 200], "above": 27],
                ["line": 2, "title": "Region", "kind": "frame", "size": [400, 300], "above": 27],
                ["line": 3, "title": "Hub", "kind": "sticky-note", "size": [200, 200], "above": 27],
            ],
            "references": [["line": 4, "for": "Hub", "size": [91, 32]]],
            "constants": [
                "gaps": ["none": 0, "tight": 40, "normal": 80, "wide": 160],
                "defaultGap": 80, "listStep": 64, "referenceStep": 16, "horizontalClearance": 40, "verticalClearance": 64,
                "frameInset": 40, "smallest": ["frame": [96, 64]],
            ],
        ])
    },
    test("an unreadable script is refused with draw's messages, a via: with draw's, and a title is as draw's: once") {
        let editor = shippedEditor()
        let scripts = [
            "sticky-note \"A\" size: wide",
            "blob \"A\"",
            "sticky-note \"A\" bogus: 1",
            "sticky-note \"A\" text: \"x\"\nsticky-note \"A\" text: \"y\"",
            "sticky-note \"A\"\nsticky-note \"B\"\nedge \"A\" -> \"B\" via: tile",
            "sticky-note \"A\"\nsticky-note \"B\"\nedge \"A\" -> \"B\" via: rference",
            "sticky-note \"A\" size: 1000000x",
        ]
        for script in scripts {
            guard case .failure(let measure) = measured(script, in: editor) else {
                expect(false, "\(script) should be refused")
                continue
            }
            guard case .failure(let draw) = drawInProcess(script, on: editor) else {
                // via: is the one measure takes alone.
                expectEqual(measure.reason, "invalid_value", script)
                continue
            }
            expectEqual(measure.code, draw.code, script)
            expectEqual(measure.reason, draw.reason, script)
            expectEqual(measure.message, draw.message, script)
            expectEqual(measure.hint, draw.hint, script)
            expectEqual(measure.data?["line"], draw.data?["line"], script)
        }
        guard case .failure(let via) = measured("sticky-note \"A\"\nsticky-note \"B\"\nedge \"A\" -> \"B\" via: rference", in: editor) else { throw RequireFailed() }
        expectEqual(via.reason, "invalid_value")
        expectEqual(via.hint, "did you mean reference? via: takes reference")
    },
])
