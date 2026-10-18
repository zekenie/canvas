import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import DrawScript
import Foundation
import Geometry
import LanguageModels
import ShippedTesting
import StickyNotes
import TestKit
import Titles

// `canvas measure`, as shipped: the size draw makes each shape of a script and each reference an edge
// says `via:`, how far a shape's title row reaches above it, and the constants placement is done with,
// each held to what a draw of the same script makes on a board, or to the source it is read from; and
// that it changes no board and opens no undo step; and, given a board, what it reads of that file (its types and names).

/// The shipped editor over an empty board in a 1440 × 900 window.
@MainActor private func shippedEditor() -> CanvasEditor {
    let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
    editor.viewportDidResize(to: CGSize(width: 1440, height: 900))
    return editor
}

/// `measure`, as the app's command server runs it with no board open.
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
    test("each shape is the size draw makes it: a note 300 wide with text as tall as its text, a type (a note that holds a schema), a subboard, a frame") {
        let schema = #"{"type": "object", "properties": {"name": {"type": "string"}, "email": {"type": "string"}}}"#
        let long = String(repeating: "The checkout takes a basket and a card, charges it, and sends the receipt. ", count: 3)
        let script = """
            sticky-note "Checkout v2" size: 300x text: "\(long)"
            sticky-note "Plain"
            sticky-note "Wide" size: 420x text: "short"
            sticky-note "Exact" size: 250x90
            sticky-note "Person" text: "A person who buys things, with the details we keep for them and why we keep each." schema: "\(scripted(schema))"
            sticky-note "Simple" schema: "\(scripted(schema))"
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
            expectEqual(measure["title"], row["title"], "\(measure["line"] ?? .null): the title draw reports, a type's the one written")
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
            sticky-note "Five" public: true
            edge "One" -> "Five" via: reference in "Nowhere" right of "Nobody" left (gap: 20)
            edge "One" -> "Two" below "Nobody"
            """)
        expectEqual(ignored.status, 0, ignored.error)
        let answer = try JSON(text: ignored.output)
        let rows = try require(answer["shapes"]?.arrayValue)
        expectEqual(rows.map { $0["title"] }, ["One", "Two", "Three", "Four", "Five"])
        expectEqual(rows.map { $0["line"] }, [1, 2, 3, 6, 7])
        expectEqual(size(rows[3]["size"])?.first, 400, "a style's size still applies")
        // And so are an edge's, where its reference goes: the reference is sized all the same.
        expectEqual(answer["references"]?.arrayValue?.map { $0["line"] }, [8])
        expectEqual(answer["warnings"], nil)
        // No board named, none in front: it still runs, on none, and names no board.
        let apart = try run(builtExecutable("CanvasCLI"), ["--socket", server.path, "help", "measure"])
        expectEqual(apart.status, 0, apart.error)
        expect(apart.output.contains("measure"), apart.output)
        expect(apart.output.contains("the board in front, if any."), apart.output)
        let loose = try startCommandServer(boards: [board], frontmost: nil)
        defer { loose.stop() }
        let none = try canvas(loose, ["measure", "-", "--board", "99"], input: "sticky-note \"A\"")
        expect(none.status != 0, "a board named that isn't open is refused as for any board command")
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
            "board": ["id": .number(Double(board.number)), "name": .string(board.displayName), "shows": "root", "showsPath": ["root"]],
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
    test("with a board it reads the file's types, as draw finds a title: an is: measures the note with its rows, equal to a draw of it; with none open, without") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let schema = scripted(#"{"type": "object", "properties": {"name": {"type": "string"}, "email": {"type": "string"}, "role": {"type": "string"}}}"#)
        expectEqual(try canvas(server, ["draw", #"sticky-note "Person" text: "A person" schema: "\#(schema)""#]).status, 0)
        let script = #"sticky-note "Ann" is: "Person""#
        let before = board.editor.file, revision = board.editor.revision, step = board.editor.undoHistory.undoName
        let withBoard = try canvas(server, ["measure", "-"], input: script)
        expectEqual(withBoard.status, 0, withBoard.error)
        let json = try JSON(text: withBoard.output)
        let roomy = try require(size(json["shapes"]?.arrayValue?.first?["size"]))
        expectEqual(json["warnings"], nil, "the type is found")
        expect(try require(json["board"]?["shows"]?.stringValue) == "root")
        // No board: the type isn't there, so a note without rows.
        let without = try measured(script, in: shippedEditor()).get()
        let plain = try require(size(without["shapes"]?.arrayValue?.first?["size"]))
        expect(roomy != plain && roomy[0] >= plain[0] && roomy[1] >= plain[1], "rows give it room: \(roomy) against \(plain)")
        expectEqual(without["warnings"]?.arrayValue?.first?["message"], #""Ann": is: there's no shape called "Person"; measured without it"#)
        expectEqual(without["board"], nil, "no board, none named")
        // Nothing changed, no step, and every statement's shape is new: a title the file has is no restatement.
        expect(board.editor.file == before && board.editor.revision == revision && board.editor.undoHistory.undoName == step, "the board is as it was")
        // The size is the size a draw of it makes.
        let drew = try canvas(server, ["draw", script])
        expectEqual(drew.status, 0, drew.error)
        let row = try require(try JSON(text: drew.output)["changes"]?.arrayValue?.first)
        expectEqual(drawnSize(row), roomy, "measured as drawn")
        // A type the script draws gives its note rows, with no board and with one.
        let both = #"""
            sticky-note "Order" text: "An order" schema: "\#(schema)"
            sticky-note "O1" is: "Order"
            """#
        for answered in [try measured(both, in: shippedEditor()).get(), try JSON(text: canvas(server, ["measure", "-"], input: both).output)] {
            let rows = try require(answered["shapes"]?.arrayValue)
            expect(try require(size(rows[1]["size"])) == roomy, "a type of the same script gives rows")
            expectEqual(answered["warnings"], nil)
        }
    },
    test("--board names the board it reads, whatever is in front; an is: it can't find is a warning and the note is measured without it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let typed = newBoard(), front = newBoard()
        defer { typed.close(); front.close() }
        let server = try startCommandServer(boards: [typed, front], frontmost: front)
        defer { server.stop() }
        let schema = scripted(#"{"type": "object", "properties": {"name": {"type": "string"}, "email": {"type": "string"}}}"#)
        let drawn = try canvas(server, ["draw", "--board", "\(typed.number)", #"sticky-note "Person" schema: "\#(schema)""#])
        expectEqual(drawn.status, 0, drawn.error)
        expectEqual(typed.editor.document.shapes.count, 1)
        let named = try canvas(server, ["measure", "--board", "\(typed.number)", "-"], input: #"sticky-note "Ann" is: "Person""#)
        let elsewhere = try canvas(server, ["measure", "-"], input: #"sticky-note "Ann" is: "Person""#)
        expectEqual(named.status, 0, named.error)
        expectEqual(elsewhere.status, 0, elsewhere.error)
        let withRows = try JSON(text: named.output), plain = try JSON(text: elsewhere.output)
        expectEqual(withRows["board"]?["id"], .number(Double(typed.number)))
        expectEqual(plain["board"]?["id"], .number(Double(front.number)))
        expect(try require(size(withRows["shapes"]?.arrayValue?.first?["size"])) != (try require(size(plain["shapes"]?.arrayValue?.first?["size"]))))
        expectEqual(plain["warnings"]?.arrayValue?.count, 1, "the front board has no Person")
        // Nothing, two, or a note that is no type: warned of, measured as a plain note.
        let script = """
            sticky-note "Plain"
            sticky-note "A" is: "Nobody"
            sticky-note "B" is: "Plain"
            sticky-note "C" text: "see @[Nobody]"
            """
        let several = try canvas(server, ["measure", "--board", "\(front.number)", "-"], input: script)
        expectEqual(several.status, 0, several.error)
        let answered = try JSON(text: several.output)
        let warnings = try require(answered["warnings"]?.arrayValue)
        expectEqual(warnings.map { $0["line"] }, [2, 3, 4])
        expect(warnings[0]["message"]?.stringValue?.hasSuffix("measured without it") == true, "\(warnings[0])")
        expect(warnings[1]["message"]?.stringValue?.contains("isn't a type") == true, "\(warnings[1])")
        expect(warnings[2]["message"]?.stringValue?.hasPrefix(#""C": text: "#) == true, "\(warnings[2])")
        let sizes = try require(answered["shapes"]?.arrayValue).map { size($0["size"]) }
        expectEqual(sizes[1], sizes[0], "A is measured as a plain note")
        expectEqual(sizes[2], sizes[0])
        // A format's own refusal, a blank mention, still refuses the whole script.
        let blank = try canvas(server, ["measure", "-"], input: #"sticky-note "D" text: "@[]""#)
        expect(blank.status != 0, "a blank @[] is refused")
    },
    test("an id finds a shape of the open file as a title does: an edge's end by id is laid with the script, and with none open, or for an id nothing has, it is a warning and the edge is left out") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let schema = scripted(#"{"type": "object", "properties": {"name": {"type": "string"}}}"#)
        let model = try canvas(server, ["draw", """
            sticky-note "Person" schema: "\(schema)"
            sticky-note "Company" schema: "\(schema)" right of "Person"
            sticky-note is: "Company" fieldValues: {"name": "Acme"} below "Company"
            """])
        expectEqual(model.status, 0, model.error)
        let acme = try require(board.editor.document.shapes.last).id
        let script = """
            sticky-note "Ann" is: "Person"
            edge "Ann" -> #\(acme)
            """
        let before = board.editor.file, revision = board.editor.revision
        let found = try JSON(text: canvas(server, ["measure", "-"], input: script).output)
        expectEqual(found["warnings"], nil, "the shape of the open file is found by its id")
        expectEqual(found["shapes"]?.arrayValue?.count, 1)
        // With no board open, or an id nothing has: said as a name it can't find is, the edge left out.
        let none = try measured(script, in: shippedEditor()).get()
        let edgeWarning = try require(none["warnings"]?.arrayValue?.first { $0["line"] == 2 })
        expectEqual(edgeWarning["message"], .string("there's no shape with the id #\(acme); measured without it"))
        expectEqual(none["warnings"]?.arrayValue?.map { $0["line"] }, [1, 2], "Person is not found either, with no board")
        let unknown = try JSON(text: canvas(server, ["measure", "-"], input: "sticky-note \"Ann\" is: \"Person\"\nedge #\(ShapeID()) -> \"Ann\"").output)
        expectEqual(unknown["warnings"]?.arrayValue?.map { $0["line"] }, [2])
        expect(unknown["warnings"]?.arrayValue?.first?["message"]?.stringValue?.hasSuffix("measured without it") == true, "\(unknown)")
        // A shape statement that names an id is measured as a new shape of its kind with no title, as a title the file has is.
        let restated = try JSON(text: canvas(server, ["measure", "-"], input: "sticky-note #\(acme) text: \"Acme, in full\"").output)
        expectEqual(restated["shapes"]?.arrayValue?.first?["title"], nil)
        expectEqual(restated["shapes"]?.arrayValue?.first?["kind"], "sticky-note")
        // A via: edge to an id is sized, for a pill called what the open file's shape is called.
        let via = try JSON(text: canvas(server, ["measure", "-"], input: "sticky-note \"Ann\" is: \"Person\"\nedge \"Ann\" -> #\(acme) via: reference").output)
        expectEqual(via["references"]?.arrayValue?.count, 1)
        expect(board.editor.file == before && board.editor.revision == revision, "nothing changed")
    },
])
