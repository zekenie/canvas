import Adornments
import AppKit
import Canvas
import LineRows
import Palette
import TextEditing
import Titles

// A table's columns and an enum's values written as lines (LineRows): the column grammar and the enum's, as a line being
// typed reads them (the spans its words are drawn in, the gutter's mark, what fits at the caret), and the models that
// write a commit to the shape and name its step. One reader each, the Grammar part's, shared with `canvas draw`.

// MARK: The file's enums

/// The file's enums by name, for a column's type that names one: kept until the file changes (`editor.revision`), so a
/// keystroke on a board of thousands of shapes reads a list. Nearest first: one on the shape's board, then any other.
@MainActor
final class KitNames {
    unowned let editor: CanvasEditor
    private var revision = -1
    private var kept: [(id: ShapeID, name: String, board: BoardID)] = []

    init(editor: CanvasEditor) {
        self.editor = editor
    }

    /// Every enum of the file that has a name, the board shown's first, then the root's, then the others'.
    var enums: [(id: ShapeID, name: String, board: BoardID)] {
        if revision != editor.revision {
            revision = editor.revision
            let file = editor.file, registry = editor.registry, shown = editor.board
            let boards = [shown] + file.everyBoard.filter { $0 != shown }.sorted { ($0.owner?.description ?? "") < ($1.owner?.description ?? "") }
            kept = boards.flatMap { board in
                file[board].shapes.compactMap { record -> (id: ShapeID, name: String, board: BoardID)? in
                    guard record.kind == DatabaseEnum.kind, let name = registry.title(of: record) else { return nil }
                    return (record.id, name, board)
                }
            }
        }
        return kept
    }

    /// The enum called `name` nearest `shape`: on its board, else anywhere in the file.
    func enumNamed(_ name: String, near shape: ShapeID) -> ShapeID? {
        let board = editor.file.board(containing: shape)
        let named = enums.filter { $0.name == name }
        return (named.first { $0.board == board } ?? named.first)?.id
    }

    /// An enum's name now, if it's still one of the file's.
    func name(of id: ShapeID) -> String? {
        enums.first { $0.id == id }?.name
    }
}

extension KitNames: EditorService {}

// MARK: Columns

/// The column grammar as a line reads: its name in the line's font, its type in code (an enum's name in its purple pill,
/// standing for that enum), the grammar's words in grey code, what it can't place plain; a primary key's key or a unique
/// column's "1" in the gutter. After a name it offers SQL's types and the file's enums; after a type, null, unique,
/// default, pk and →.
struct ColumnLineGrammar: LineGrammar {
    typealias Row = Column

    func read(_ line: LineText, id: PartID, in context: LineContext) -> LineReading<Column> {
        let scan = ColumnGrammar.scan(line.string, id: id)
        guard var column = scan.column else { return LineReading(row: nil) }
        var spans: [LineSpan] = []
        for word in scan.words {
            switch word.role {
            case .name: spans.append(LineSpan(word.range, .name))
            case .type:
                let words = column.type.words
                // A run the line carries stands for its enum whatever else is called so; a name typed afresh is found.
                let named: ShapeID? = if let target = line.reference(at: NSRange(location: word.range.location, length: (words as NSString).length)),
                                         context.editor.shape(inFile: target.shape)?.kind == DatabaseEnum.kind {
                    target.shape
                } else {
                    context.editor.service(KitNames.self)?.enumNamed(words, near: context.shape)
                }
                column.type.shape = named
                spans.append(LineSpan(word.range, named == nil ? .code : .pill(LineLooks.enumFill, ink: LineLooks.enumInk)))
            case .keyword, .arrow: spans.append(LineSpan(word.range, .keyword))
            case .defaultValue: spans.append(LineSpan(word.range, .code))
            case .unread: spans.append(LineSpan(word.range, .plain))
            }
        }
        let mark: LineMark? = column.primaryKey ? LineMark(symbol: TableStyle.keySymbol, color: NSColor(TableStyle.keyColor))
            : column.unique ? LineMark(symbol: TableStyle.uniqueSymbol, color: NSColor(TableStyle.uniqueColor)) : nil
        return LineReading(row: column, spans: spans, mark: mark)
    }

    /// The line as the grammar prints it, an enum's name as it's called now, standing for it.
    func print(_ column: Column, in context: LineContext) -> LineText {
        var column = column
        if let id = column.type.shape, let name = context.editor.service(KitNames.self)?.name(of: id) { column.type.words = name }
        let string = ColumnGrammar.print(column)
        guard let id = column.type.shape, !column.type.words.isEmpty,
              let type = ColumnGrammar.placedWords(of: string).dropFirst().first, type.text == column.type.words else { return LineText(string) }
        return LineText(string, references: [LineReference(range: type.range, target: PartAddress(id))])
    }

    func offers(at caret: Int, in line: LineText, reading: LineReading<Column>, context: LineContext) -> LineOffers? {
        let words = ColumnGrammar.placedWords(of: line.string)
        // The word the caret is in or at the end of, and how many come before it.
        let at = words.firstIndex { caret >= $0.range.location && caret <= NSMaxRange($0.range) }
        let index = at ?? words.filter { NSMaxRange($0.range) < caret }.count
        guard index > 0 else { return nil }
        let range = at.map { words[$0].range } ?? NSRange(location: caret, length: 0)
        let typed = at.map { String(words[$0].text.utf16.prefix(caret - words[$0].range.location)) ?? "" } ?? ""
        let before = words.prefix(index).map(\.text)
        if index == 1 {
            return LineOffers(range: range, query: typed, items: typeOffers(context))
        }
        // Nothing after a default's word, a key's arrow or a word nothing reads.
        let previous = before.last?.lowercased() ?? ""
        if previous == ColumnGrammar.default || before.contains(where: { $0 == ColumnGrammar.arrow || $0 == ColumnGrammar.typedArrow }) { return nil }
        do {
            let said = Set(before.map { $0.lowercased() })
            let items = LineLooks.flags.filter { !said.contains($0.word) }.map { flag in
                LineOffer(CaretCompletion(label: flag.label, insert: flag.insert))
            }
            return items.isEmpty ? nil : LineOffers(range: range, query: typed, items: items)
        }
    }

    /// SQL's types, then the file's enums, each in its purple chip and lit while it's highlighted.
    private func typeOffers(_ context: LineContext) -> [LineOffer] {
        let types = LineLooks.sqlTypes.map { LineOffer(CaretCompletion(label: $0, insert: $0)) }
        let enums = (context.editor.service(KitNames.self)?.enums ?? []).reduce(into: [(id: ShapeID, name: String)]()) { list, found in
            if !list.contains(where: { $0.name == found.name }) { list.append((found.id, found.name)) }
        }
        return types + enums.map { LineOffer(CaretCompletion(label: $0.name, detail: EnumStyle.label, insert: $0.name, chip: LineLooks.enumChip), light: PartAddress($0.id)) }
    }

    var substitutions: [LineSubstitution] { [LineSubstitution(ColumnGrammar.typedArrow, becomes: ColumnGrammar.arrow)] }

    /// "customer_id, uuid, unique": its name, its type, and what it is.
    func spoken(_ column: Column, in context: LineContext) -> String {
        var words = [column.name]
        if !column.type.words.isEmpty {
            let type = column.type.shape.flatMap { context.editor.service(KitNames.self)?.name(of: $0) } ?? column.type.words
            words.append(column.type.shape == nil ? type : "\(type) enum")
        }
        if column.primaryKey { words.append("primary key") }
        if column.unique { words.append("unique") }
        if column.nullable { words.append("null") }
        if let value = column.default { words.append("default \(value)") }
        if !column.unread.isEmpty { words.append(column.unread) }
        return words.joined(separator: ", ")
    }
}

/// A table written as lines: its columns, the column grammar, and its steps.
struct TableLines: LineModel {
    typealias Props = DatabaseTable
    typealias Row = Column

    var noun: LineNoun { LineNoun("column") }
    var style: LineStyle { LineLooks.table }
    func rows(of props: DatabaseTable) -> [Column] { props.columns }
    func setRows(_ rows: [Column], in props: inout DatabaseTable) { props.columns = rows }
    func id(of row: Column) -> PartID { row.id }
    func role(of row: Column) -> LineRole { LineLooks.column }
    func roleOfNewRow(at index: Int, in props: DatabaseTable) -> LineRole { LineLooks.column }
    func grammar(for role: LineRole) -> any LineGrammar<Column> { ColumnLineGrammar() }
    func lineRect(_ line: Int, in frame: CGRect) -> CGRect { KitStyle.rowRect(line, in: frame) }

    /// What a line doesn't say stays: on delete, on update.
    func merged(_ read: Column, onto held: Column) -> Column {
        var column = read
        column.id = held.id
        column.onDelete = held.onDelete
        column.onUpdate = held.onUpdate
        return column
    }

    /// Add Column, Paste Columns, Rename Column (only its name changed), Change Column, Delete Column, Move Column.
    func stepName(of change: LineChange<Column>) -> String {
        switch change {
        case .add(let rows, _): rows.count == 1 ? TableStyle.addColumnStep : TableStyle.pasteColumnsStep
        case .change(let from, let to): Self.onlyRenamed(from, to) ? TableStyle.renameColumnStep : TableStyle.changeColumnStep
        case .delete(let rows): rows.count == 1 ? TableStyle.deleteColumnStep : TableStyle.deleteColumnsStep
        case .move: TableStyle.moveColumnStep
        }
    }

    /// Whether `to` is `from` with only its name changed.
    static func onlyRenamed(_ from: Column, _ to: Column) -> Bool {
        var renamed = from
        renamed.name = to.name
        return renamed == to && from.name != to.name
    }
}

// MARK: Values

/// The enum grammar as a line reads: one value a line, as typed, trimmed.
struct EnumLineGrammar: LineGrammar {
    typealias Row = EnumValue

    func read(_ line: LineText, id: PartID, in context: LineContext) -> LineReading<EnumValue> {
        let text = line.string.trimmingCharacters(in: .whitespaces)
        return LineReading(row: text.isEmpty ? nil : EnumValue(id: id, text: text))
    }

    func print(_ value: EnumValue, in context: LineContext) -> LineText { LineText(value.text) }

    func spoken(_ value: EnumValue, in context: LineContext) -> String { value.text }
}

/// An enum written as lines: its values, a value a line, and its steps.
struct EnumLines: LineModel {
    typealias Props = DatabaseEnum
    typealias Row = EnumValue

    var noun: LineNoun { LineNoun("value") }
    var style: LineStyle { LineLooks.enumValues }
    func rows(of props: DatabaseEnum) -> [EnumValue] { props.values }
    func setRows(_ rows: [EnumValue], in props: inout DatabaseEnum) { props.values = rows }
    func id(of row: EnumValue) -> PartID { row.id }
    func role(of row: EnumValue) -> LineRole { LineLooks.value }
    func roleOfNewRow(at index: Int, in props: DatabaseEnum) -> LineRole { LineLooks.value }
    func grammar(for role: LineRole) -> any LineGrammar<EnumValue> { EnumLineGrammar() }
    func lineRect(_ line: Int, in frame: CGRect) -> CGRect { KitStyle.rowRect(line, in: frame) }

    /// Add Value, Paste Values, Rename Value, Delete Value, Move Value.
    func stepName(of change: LineChange<EnumValue>) -> String {
        switch change {
        case .add(let rows, _): rows.count == 1 ? EnumStyle.addValueStep : EnumStyle.pasteValuesStep
        case .change: EnumStyle.renameValueStep
        case .delete(let rows): rows.count == 1 ? EnumStyle.deleteValueStep : EnumStyle.deleteValuesStep
        case .move: EnumStyle.moveValueStep
        }
    }
}

/// The kit's line grammars, for what reads a line as typing does (a test's corpus).
@MainActor
public enum EngineeringLines {
    /// A column's line.
    public static var columns: any LineGrammar<Column> { ColumnLineGrammar() }
    /// An enum's value's line.
    public static var values: any LineGrammar<EnumValue> { EnumLineGrammar() }
}

// MARK: Looks

/// How the kit's lines look while typed, and what they offer: the kit's fonts and inks at rest, so nothing moves as editing
/// starts.
@MainActor
enum LineLooks {
    static let column: LineRole = "column"
    static let value: LineRole = "value"

    /// A table's line: names in the names' font, types in the types'.
    static let table = LineStyle(font: KitStyle.nameFont, codeFont: KitStyle.typeFont, ink: NSColor(KitStyle.ink),
                                 secondaryInk: NSColor(KitStyle.secondaryInk), textInset: KitStyle.nameInset,
                                 trailingInset: KitStyle.trailingInset, gutterMiddle: KitStyle.gutterMiddle, markSize: TableStyle.markSize)
    /// An enum's line: its value in the values' monospaced font.
    static let enumValues = LineStyle(font: KitStyle.valueFont, codeFont: KitStyle.valueFont, ink: NSColor(KitStyle.ink),
                                      secondaryInk: NSColor(KitStyle.secondaryInk), textInset: KitStyle.nameInset,
                                      trailingInset: KitStyle.trailingInset, gutterMiddle: KitStyle.gutterMiddle, markSize: TableStyle.markSize)

    /// An enum's name in a line: the pill its column draws at rest, faint purple behind its name in the purple's ink.
    static let enumFill = TableStyle.enumPill.color.withAlphaComponent(TableStyle.enumPillFill)
    static let enumInk = TableStyle.enumPill.ink
    /// An enum offered in the list: a chip in the purple.
    static let enumChip = EnumStyle.titleTint.color

    /// What's offered after a type: each flag's word, what the list says, what a pick puts in.
    static let flags: [(word: String, label: String, insert: String)] = [
        (ColumnGrammar.null, "null", "null"),
        (ColumnGrammar.unique, "unique", "unique"),
        (ColumnGrammar.default, "default", "default "),
        (ColumnGrammar.primaryKey, "pk", "pk"),
        (ColumnGrammar.arrow, ColumnGrammar.arrow, ColumnGrammar.arrow + " "),
    ]

    /// SQL's types (Postgres's), the common first: what a type's word is offered from.
    static let sqlTypes = [
        "uuid", "text", "int", "int8", "integer", "interval", "inet", "bigint", "smallint", "serial", "bigserial", "numeric", "decimal",
        "real", "float8", "bool", "boolean", "date", "time", "timestamp", "timestamptz", "json", "jsonb", "bytea", "varchar", "char",
        "citext", "money", "cidr",
    ]
}
