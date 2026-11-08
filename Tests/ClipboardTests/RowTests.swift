import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Clipboard
import CoreGraphics
import Geometry
import LineRows
import Selection
import TestKit

// Rows on the canvas through Clipboard's commands: with rows selected as items (Selection's), ⌘C and ⌘X put the rows on the
// pasteboard (a cut taking the straps bound to them, counted), and ⌘V puts rows down after the last row selected, or out on
// their own beside the selection; a cut's paste is a move. Over a docket of the test's own, a box of lines a line each.

/// A docket: lines of text, a row each, 20 apart under a 10-point head.
struct Docket: BoxShapeProps {
    static let kind: ShapeKind = "docket"
    static let properties = Properties<Docket> {
        Property("frame", \.frame).required()
        Property("rows", \.rows)
    }
    var frame: CGRect
    var rows: [DocketRow]

    init(_ frame: CGRect = CGRect(x: 0, y: 0, width: 200, height: 40), _ lines: [String] = []) {
        self.frame = frame
        rows = lines.map { DocketRow(text: $0) }
    }

    init() { self.init(.zero, []) }
}

struct DocketRow: SchemaDefined, Hashable, Sendable {
    static let properties = Properties<DocketRow>(definition: "docket-row") {
        Property("id", \.id).required()
        Property("text", \.text)
    }
    var id = PartID()
    var text = ""
}

struct DocketDefinition: ShapeDefinition, PartedShape {
    func render(_ shape: ShapeRecord<Docket>, in context: RenderContext) {}

    func geometry(of shape: ShapeRecord<Docket>, in context: ShapeContext) -> ShapeGeometry {
        let frame = shape.frame
        let parts = shape.props.rows.enumerated().map { PartFrame(id: $1.id, rect: DocketLines.line($0, in: frame)) }
        return ShapeGeometry(outline: frame.polygon, bounds: frame, parts: PartFrames(parts))
    }

    func parts(of shape: ShapeRecord<Docket>) -> [PartName] { shape.props.rows.map { PartName(id: $0.id, name: $0.text, kindWord: "Line") } }
}

struct DocketGrammar: LineGrammar {
    typealias Row = DocketRow
    func read(_ line: LineText, id: PartID, in context: LineContext) -> LineReading<DocketRow> {
        let text = line.string.trimmingCharacters(in: .whitespaces)
        return LineReading(row: text.isEmpty ? nil : DocketRow(id: id, text: text))
    }
    func print(_ row: DocketRow, in context: LineContext) -> LineText { LineText(row.text) }
    func spoken(_ row: DocketRow, in context: LineContext) -> String { row.text }
}

struct DocketLines: LineModel {
    typealias Props = Docket
    typealias Row = DocketRow
    var noun: LineNoun { LineNoun("line") }
    var style: LineStyle {
        LineStyle(font: .systemFont(ofSize: 13), codeFont: .monospacedSystemFont(ofSize: 12, weight: .regular), ink: .black, secondaryInk: .gray,
                  textInset: 8, trailingInset: 8, gutterMiddle: 4, markSize: 10)
    }
    func rows(of props: Docket) -> [DocketRow] { props.rows }
    func setRows(_ rows: [DocketRow], in props: inout Docket) { props.rows = rows }
    func id(of row: DocketRow) -> PartID { row.id }
    func renaming(_ row: DocketRow, to id: PartID) -> DocketRow { DocketRow(id: id, text: row.text) }
    func role(of row: DocketRow) -> LineRole { "line" }
    func roleOfNewRow(at index: Int, in props: Docket) -> LineRole { "line" }
    func grammar(for role: LineRole) -> any LineGrammar<DocketRow> { DocketGrammar() }
    func lineRect(_ line: Int, in frame: CGRect) -> CGRect { Self.line(line, in: frame) }
    func stepName(of change: LineChange<DocketRow>) -> String { "Change Line" }

    static func line(_ line: Int, in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: frame.minY + 10 + CGFloat(line) * 20, width: frame.width, height: 20)
    }
}

struct DocketsPlugin: CanvasPlugin {
    var id: PluginID { "dockets" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(DocketDefinition()) { docket in
            docket.label("Docket", systemImage: "list.bullet")
            docket.lineRows(DocketLines())
        }
    }
}

/// Clipboard and LineRows over dockets and straps, on a pasteboard of the test's own.
@MainActor private func rowHarness(_ pasteboard: NSPasteboard, log: RefusalLog = RefusalLog()) throws -> EditorHarness {
    let h = try harness(pasteboard, [LineRowsPlugin(), DocketsPlugin(), StrapsPlugin(), FreezingPlugin(log: log)])
    h.editor.viewportDidResize(to: CGSize(width: 900, height: 700))
    return h
}

extension EditorHarness {
    func lines(_ id: ShapeID) -> [String] { editor.document[id]?.typed(as: Docket.self)?.props.rows.map(\.text) ?? [] }
    func rowIDs(_ id: ShapeID, _ texts: String...) -> [PartID] {
        texts.compactMap { text in editor.document[id]?.typed(as: Docket.self)?.props.rows.first { $0.text == text }?.id }
    }
    func selectRows(_ id: ShapeID, _ texts: String...) {
        editor.selectItems(texts.compactMap { text in editor.document[id]?.typed(as: Docket.self)?.props.rows.first { $0.text == text }.map { AnyHashable($0.id) } },
                           of: id)
    }
}

@MainActor let rowTests = Suite("Rows cut, copied and pasted", [
    test("⌘X with rows selected cuts them and the straps bound to them, counted; ⌘V with another docket's rows selected pastes after the last, a move: the straps back under their ids; again, copies") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try rowHarness(pasteboard)
        let a = h.add(Docket(CGRect(x: 100, y: 100, width: 200, height: 40), ["one", "two", "three"]))
        let b = h.add(Docket(CGRect(x: 400, y: 100, width: 200, height: 40), ["x", "y"]))
        let other = h.add(Docket(CGRect(x: 100, y: 400, width: 200, height: 40), ["z"]))
        let two = h.rowIDs(a, "two")[0]
        let strap = h.add(Strap(from: PartAddress(a, part: two), to: PartAddress(other, part: h.rowIDs(other, "z")[0])))
        h.editor.undoHistory.seal()
        h.selectRows(a, "two")
        expect(h.command("x"))
        expectEqual(h.lines(a), ["one", "three"])
        expectEqual(h.editor.document[strap], nil)
        expectEqual(h.editor.undoHistory.undoName, "Cut Line and 1 strap", "the step counts what went with it")
        expectEqual(pasteboard.string(forType: .string), "two", "the line beside them, as text")
        expect(pasteboard.data(forType: NSPasteboard.PasteboardType("com.example.InfiniteCanvas.shapes")) == nil, "rows, not shapes")
        h.selectRows(b, "x")
        expect(h.command("v"))
        expectEqual(h.lines(b), ["x", "two", "y"], "after the last row selected")
        expectEqual(h.rowIDs(b, "two"), [two], "the same row")
        expectEqual(h.editor.undoHistory.undoName, "Paste Line")
        expectEqual(h.editor.document[strap]?.typed(as: Strap.self)?.props.from, PartAddress(b, part: two), "back under its id")
        expectEqual(h.editor.selectedItems?.ids, [AnyHashable(two)], "what landed selected")
        expect(h.command("v"))
        expectEqual(h.lines(b), ["x", "two", "two", "y"], "pasted again")
        expectEqual(h.editor.document.shapes.filter { $0.kind == Strap.kind }.count, 2, "the strap copied, under a new id")
    },
    test("⌘C with rows selected copies them, no strap ending at them; ⌘V with nothing selected puts a docket of their own down in view; with a shape selected, beside it; selected") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try rowHarness(pasteboard)
        let a = h.add(Docket(CGRect(x: 100, y: 100, width: 200, height: 40), ["one", "two"]))
        let other = h.add(Docket(CGRect(x: 100, y: 400, width: 200, height: 40), ["z"]))
        h.add(Strap(from: PartAddress(other, part: h.rowIDs(other, "z")[0]), to: PartAddress(a, part: h.rowIDs(a, "two")[0])))
        h.selectRows(a, "one", "two")
        expect(h.command("c"))
        expectEqual(h.lines(a), ["one", "two"], "a copy changes nothing")
        expectEqual(h.editor.pasteboardRows?.bound.count, 0, "a strap ending at a row isn't the row's")
        h.editor.selectedShapeIDs = []
        expect(h.command("v"))
        let out = try require(h.editor.selectedShapeIDs.first)
        expect(out != a && out != other)
        expectEqual(h.lines(out), ["one", "two"])
        expectEqual(h.editor.undoHistory.undoName, "Paste Lines", "a copy pasted out")
        h.editor.selectedShapeIDs = [a]
        expect(h.command("v"))
        let beside = try require(h.editor.selectedShapeIDs.first)
        expect(beside != a && beside != out)
        let frame = try require(h.editor.document[beside]?.box), next = try require(h.editor.document[a]?.box)
        expect(!frame.intersects(next), "beside the selection, not over it")
    },
    test("A read-only docket takes no rows: ⌘V with its rows selected pastes nothing, no step, and it shakes; a read-only source cuts nothing") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let log = RefusalLog()
        let h = try rowHarness(pasteboard, log: log)
        let a = h.add(Docket(CGRect(x: 100, y: 100, width: 200, height: 40), ["one", "two"]))
        let b = h.add(Docket(CGRect(x: 400, y: 100, width: 200, height: 40), ["x"]))
        h.selectRows(a, "one")
        expect(h.command("c"))
        h.editor.freeze([b])
        h.editor.undoHistory.seal()
        let step = h.editor.undoHistory.undoName
        h.selectRows(b, "x")
        h.command("v")
        expectEqual(h.lines(b), ["x"])
        expectEqual(h.editor.undoHistory.undoName, step)
        expect(log.refusals.last?.contains(b) == true, "it shakes")
        h.editor.freeze([a])
        h.selectRows(a, "two")
        h.command("x")
        expectEqual(h.lines(a), ["one", "two"], "a locked docket keeps its rows")
    },
])
