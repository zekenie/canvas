import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Geometry
@_spi(Host) import CanvasUI
import Keyboard
import LineRows
import Selection
import TestKit
import TextEditing

// The fixture LineRows is held over, a kind of its own as TypesTests' `Memo` is: a tally, a box of entries written a line
// each, `label [count] [name of another tally] [anything]`. Its count is a number; a name of another tally stands for it
// (a reference, as an enum's name in a column does), printed as that tally is called now. It offers numbers and the
// other tallies' names after a label, each tally lit while its name is highlighted.

/// A tally: its name (its own, so the fixture needs no Titles) and its entries.
struct Tally: BoxShapeProps {
    static let kind: ShapeKind = "tally"
    static let properties = Properties<Tally> {
        Property("frame", \.frame).required()
        Property("name", \.name)
        Property("rows", \.rows)
    }
    var frame: CGRect
    var name: String
    var rows: [TallyRow]

    init(_ frame: CGRect = CGRect(x: 0, y: 0, width: 240, height: 40), name: String = "", rows: [TallyRow] = []) {
        self.frame = frame
        self.name = name
        self.rows = rows
    }

    init() { self.init(name: "") }

    static let head: CGFloat = 10
    static let rowHeight: CGFloat = 20
}

/// An entry: its label, its count, the tally it names, and the words nothing read.
struct TallyRow: SchemaDefined, Hashable, Sendable {
    static let properties = Properties<TallyRow>(definition: "tally-row") {
        Property("id", \.id).required()
        Property("label", \.label)
        Property("count", \.count)
        Property("ref", \.ref)
        Property("unread", \.unread)
    }
    var id: PartID
    var label: String
    var count: Int?
    var ref: ShapeID?
    var unread: String

    init(id: PartID = PartID(), _ label: String, count: Int? = nil, ref: ShapeID? = nil, unread: String = "") {
        self.id = id
        self.label = label
        self.count = count
        self.ref = ref
        self.unread = unread
    }

    init() { self.init("") }
}

/// What tallies drew: each entry's label as its render drew it, in order.
@MainActor
final class TallyLog {
    var drawn: [String] = []
}

struct TallyDefinition: ShapeDefinition, LaidOutBox {
    let log: TallyLog

    func render(_ shape: ShapeRecord<Tally>, in context: RenderContext) {
        context.cg.setFillColor(NSColor.white.cgColor)
        context.cg.fill(context.shapes.frame(of: shape))
        let focused = context.shapes.layoutInput(LineRowsLayout.focused, of: shape)
        let shown = context.shapes.layoutInput(LineRowsLayout.shown, of: shape)
        for (index, row) in shape.props.rows.enumerated() where row.id != focused && shown?.isShown(index) != false { log.drawn.append(row.label) }
        if let more = shown?.more { log.drawn.append("+\(more.count)") }
    }

    func laidOutSize(of shape: ShapeRecord<Tally>, in context: ShapeContext) -> CGSize {
        let shown = context.layoutInput(LineRowsLayout.shown, of: shape)
        let lines = shown?.count ?? shape.props.rows.count + (context.layoutInput(LineRowsLayout.waiting, of: shape) == nil ? 0 : 1)
        let width = max(shape.frame.width, context.layoutInput(LineRowsLayout.width, of: shape) ?? 0)
        return CGSize(width: width, height: Tally.head * 2 + Tally.rowHeight * CGFloat(max(lines, 1)))
    }

    func geometry(of shape: ShapeRecord<Tally>, in context: ShapeContext) -> ShapeGeometry {
        let frame = context.frame(of: shape), waiting = context.layoutInput(LineRowsLayout.waiting, of: shape)
        let shown = context.layoutInput(LineRowsLayout.shown, of: shape)
        let parts = shape.props.rows.enumerated().map { index, row in
            PartFrame(id: row.id, rect: TallyLines.line(shown?.line(standingFor: index) ?? LineRowsLayout.line(of: index, waiting: waiting), in: frame))
        }
        return ShapeGeometry(outline: frame.polygon, bounds: frame, parts: PartFrames(parts))
    }
}

extension TallyDefinition: Editable {
    func makeEditingView(for shape: ShapeRecord<Tally>, context: EditContext<Tally>) -> EditingView {
        LineRowsView.make(shape, context: context, model: TallyLines(), title: nil)
    }
}

extension TallyDefinition: PartedShape {
    func parts(of shape: ShapeRecord<Tally>) -> [PartName] {
        shape.props.rows.map { PartName(id: $0.id, name: $0.label, kindWord: "Entry") }
    }
}

/// The other tallies by name, in the document's order.
@MainActor
func tallies(named name: String, in editor: CanvasEditor) -> [ShapeID] {
    editor.document.shapes.compactMap { $0.typed(as: Tally.self) }.filter { $0.props.name == name }.map(\.id)
}

/// An entry's line: `label [count] [tally] [rest]`.
struct TallyGrammar: LineGrammar {
    typealias Row = TallyRow

    func read(_ line: LineText, id: PartID, in context: LineContext) -> LineReading<TallyRow> {
        let words = Self.words(line.string)
        guard let label = words.first else { return LineReading(row: nil) }
        var row = TallyRow(id: id, label.text)
        var spans = [LineSpan(label.range, .name)]
        var rest = words.dropFirst()
        if let second = rest.first {
            if let count = Int(second.text) {
                row.count = count
                spans.append(LineSpan(second.range, .code))
                rest = rest.dropFirst()
            } else if let target = line.reference(at: second.range)?.shape ?? tallies(named: second.text, in: context.editor).first {
                row.ref = target
                spans.append(LineSpan(second.range, .pill(.systemPurple.withAlphaComponent(0.2), ink: .systemPurple)))
                rest = rest.dropFirst()
            }
        }
        for word in rest { spans.append(LineSpan(word.range, word.text == "!" ? .keyword : .plain)) }
        row.unread = rest.map(\.text).joined(separator: " ")
        return LineReading(row: row, spans: spans, mark: row.count == 0 ? LineMark(symbol: "circle", color: .systemRed) : nil)
    }

    func print(_ row: TallyRow, in context: LineContext) -> LineText {
        var words = [row.label]
        if let count = row.count { words.append(String(count)) }
        var reference: LineReference?
        if let ref = row.ref, let name = context.editor.document[ref]?.typed(as: Tally.self)?.props.name {
            let start = (words.joined(separator: " ") as NSString).length + 1
            reference = LineReference(range: NSRange(location: start, length: (name as NSString).length), target: PartAddress(ref))
            words.append(name)
        }
        if !row.unread.isEmpty { words.append(row.unread) }
        return LineText(words.joined(separator: " "), references: reference.map { [$0] } ?? [])
    }

    /// After a label: numbers, then the other tallies' names, each lit.
    func offers(at caret: Int, in line: LineText, reading: LineReading<TallyRow>, context: LineContext) -> LineOffers? {
        let words = Self.words(line.string)
        let at = words.firstIndex { caret >= $0.range.location && caret <= NSMaxRange($0.range) }
        let index = at ?? words.filter { NSMaxRange($0.range) < caret }.count
        guard index == 1 else { return nil }
        let range = at.map { words[$0].range } ?? NSRange(location: caret, length: 0)
        let typed = at.map { (words[$0].text as NSString).substring(to: caret - words[$0].range.location) } ?? ""
        let names = context.editor.document.shapes.compactMap { $0.typed(as: Tally.self) }.filter { $0.id != context.shape && !$0.props.name.isEmpty }
        let items = ["1", "2", "10"].map { LineOffer(CaretCompletion(label: $0, insert: $0)) }
            + names.map { LineOffer(CaretCompletion(label: $0.props.name, insert: $0.props.name, chip: .systemPurple), light: PartAddress($0.id)) }
        return LineOffers(range: range, query: typed, items: items)
    }

    var substitutions: [LineSubstitution] { [LineSubstitution("->", becomes: "→")] }

    func spoken(_ row: TallyRow, in context: LineContext) -> String {
        ([row.label] + (row.count.map { ["\($0)"] } ?? [])).joined(separator: ", ")
    }

    static func words(_ line: String) -> [(text: String, range: NSRange)] {
        var words: [(text: String, range: NSRange)] = []
        let text = line as NSString
        var start: Int?
        for index in 0...text.length {
            let isSpace = index == text.length || text.character(at: index) == 32
            if isSpace, let begun = start {
                words.append((text.substring(with: NSRange(location: begun, length: index - begun)), NSRange(location: begun, length: index - begun)))
                start = nil
            } else if !isSpace, start == nil {
                start = index
            }
        }
        return words
    }
}

/// A tally written as lines.
struct TallyLines: LineModel {
    typealias Props = Tally
    typealias Row = TallyRow

    var noun: LineNoun { LineNoun("entry", plural: "entries") }
    var style: LineStyle {
        LineStyle(font: .systemFont(ofSize: 13), codeFont: .monospacedSystemFont(ofSize: 12, weight: .regular), ink: .black, secondaryInk: .gray,
                  textInset: 24, trailingInset: 8, gutterMiddle: 12, markSize: 10)
    }
    func rows(of props: Tally) -> [TallyRow] { props.rows }
    func setRows(_ rows: [TallyRow], in props: inout Tally) { props.rows = rows }
    func id(of row: TallyRow) -> PartID { row.id }
    func role(of row: TallyRow) -> LineRole { "entry" }
    func roleOfNewRow(at index: Int, in props: Tally) -> LineRole { "entry" }
    func grammar(for role: LineRole) -> any LineGrammar<TallyRow> { TallyGrammar() }
    func lineRect(_ line: Int, in frame: CGRect) -> CGRect { Self.line(line, in: frame) }
    /// A fold keeps the entries that have a count; a header is an entry whose label ends in "/".
    func marked(_ shape: ShapeRecord<Tally>, in reading: LayoutReading) -> Set<PartID> {
        Set(shape.props.rows.filter { $0.count != nil }.map(\.id))
    }
    func isHeader(_ row: TallyRow) -> Bool { row.label.hasSuffix("/") }

    static func line(_ line: Int, in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: frame.minY + Tally.head + CGFloat(line) * Tally.rowHeight, width: frame.width, height: Tally.rowHeight)
    }

    func stepName(of change: LineChange<TallyRow>) -> String {
        switch change {
        case .add(let rows, _): rows.count == 1 ? "Add Entry" : "Paste Entries"
        case .change(let from, let to): from.label != to.label && { var renamed = from; renamed.label = to.label; return renamed == to }() ? "Rename Entry" : "Change Entry"
        case .delete: "Delete Entry"
        case .move: "Move Entry"
        }
    }
}

/// Tallies, with a tool (so ⇧↩ and hops have a kind to put down and walk), written as lines.
struct TalliesPlugin: CanvasPlugin {
    let log: TallyLog
    var id: PluginID { "tallies" }

    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(TallyDefinition(log: log)) { tally in
            tally.label("Tally", systemImage: "number")
            tally.tool(label: "Tally", systemImage: "number", placing: tally.editingPlacement(size: CGSize(width: 240, height: 40)) { Tally() })
            tally.lineRows(TallyLines())
        }
    }
}
