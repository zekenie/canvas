import Adornments
import AppKit
import Canvas
import Draw
import LineRows
import Mentions
import Palette
import TextEditing
import Titles

// A table's columns and an enum's values written as lines (LineRows): the column grammar and the enum's, as a line being
// typed reads them (the spans its words are drawn in, the gutter's mark, what fits at the caret), and the models that
// write a commit to the shape and name its step. One reader each, the Grammar part's, shared with `canvas draw`.

// MARK: The file's enums and tables

/// The file's enums and tables by name, for a column's type that names an enum and a key's `→` that names a table: kept until the
/// file changes (`editor.revision`), so a keystroke on a board of thousands of shapes reads a list. Nearest first: one on the shape's
/// board, then any other.
@MainActor
final class KitNames {
    unowned let editor: CanvasEditor
    private var revision = -1
    private var keptEnums: [(id: ShapeID, name: String, board: BoardID)] = []
    private var keptTables: [(id: ShapeID, name: String, board: BoardID)] = []

    init(editor: CanvasEditor) {
        self.editor = editor
    }

    private func read() {
        guard revision != editor.revision else { return }
        revision = editor.revision
        let file = editor.file, registry = editor.registry, shown = editor.board
        let boards = [shown] + file.everyBoard.filter { $0 != shown }.sorted { ($0.owner?.description ?? "") < ($1.owner?.description ?? "") }
        keptEnums = []
        keptTables = []
        for board in boards {
            for record in file[board].shapes where record.kind == DatabaseEnum.kind || record.kind == DatabaseTable.kind {
                guard let name = registry.title(of: record) else { continue }
                if record.kind == DatabaseEnum.kind { keptEnums.append((record.id, name, board)) } else { keptTables.append((record.id, name, board)) }
            }
        }
    }

    /// Every enum of the file that has a name, the board shown's first, then the root's, then the others'.
    var enums: [(id: ShapeID, name: String, board: BoardID)] {
        read()
        return keptEnums
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

    /// The table called `name` on `shape`'s board: what a key's `→` names (a key reaches a table on its own board until pills stand
    /// for rows). The first in the board's order of two alike.
    func tableNamed(_ name: String, besides shape: ShapeID) -> ShapeID? {
        read()
        let board = editor.file.board(containing: shape)
        // As `canvas draw` finds a table by its title: with its whitespace folded.
        let folded = TitleProperty.folded(name) ?? name
        return keptTables.first { $0.board == board && $0.name == folded }?.id
    }
}

extension KitNames: EditorService {}

// MARK: Columns

/// A column as a line of a table being written says it: the column, and its key, which isn't the column's (a key is its arrow) but
/// what the line says of it.
public struct ColumnLine: Equatable, Sendable {
    public var column: Column
    public var key: ColumnKey

    public init(_ column: Column, key: ColumnKey = .stored) {
        self.column = column
        self.key = key
    }
}

/// What a line says of its column's key.
public enum ColumnKey: Hashable, Sendable {
    /// What the board has: a column as stored, read with no line.
    case stored
    /// No key: the line has no `→`, or one that names no table's row (its words then stay in the column, plain).
    case none
    /// A key to this row.
    case to(PartAddress)
}

/// The column grammar as a line reads: its name in the line's font, its type in code (an enum's name in its purple pill, standing
/// for that enum), the grammar's words in grey code, a key's target in the link's blue pill once it names a table's row, what it
/// can't place plain; a primary key's key or a unique column's "1" in the gutter. After a name it offers SQL's types and the
/// file's enums; after a type, null, unique, default, pk and →; after `→`, the key columns of the tables on the board (Mentions'
/// search with the table kind), and after `customers.` that table's, each lit on the board while it's highlighted.
struct ColumnLineGrammar: LineGrammar {
    typealias Row = ColumnLine

    func read(_ line: LineText, id: PartID, in context: LineContext) -> LineReading<ColumnLine> {
        let scan = ColumnGrammar.scan(line.string, id: id)
        guard var column = scan.column else { return LineReading(row: nil) }
        var spans: [LineSpan] = []
        var key = ColumnKey.none
        for (index, word) in scan.words.enumerated() {
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
            case .keyword: spans.append(LineSpan(word.range, .keyword))
            case .arrow:
                spans.append(LineSpan(word.range, .keyword))
                // The first `→` only: the word after it is its target, a key once it names a table's row on the board.
                guard key == .none, scan.words.indices.contains(index + 1), scan.words[index + 1].role == .unread else { continue }
                let target = scan.words[index + 1]
                if let found = Self.target(target.text, at: target.range, in: line, from: id, context) {
                    key = .to(found.row)
                    column.unread = Self.unread(scan, leaving: index...(index + 1))
                }
            case .defaultValue: spans.append(LineSpan(word.range, .code))
            case .unread:
                // A target that names a table is in its pill, the table's own name already as `customers.` is typed.
                if index > 0, scan.words[index - 1].role == .arrow, Self.names(word.text, at: word.range, in: line, from: id, context) {
                    spans.append(LineSpan(word.range, .pill(LineLooks.keyFill, ink: LineLooks.keyInk)))
                } else {
                    spans.append(LineSpan(word.range, .plain))
                }
            }
        }
        let mark: LineMark? = column.primaryKey ? LineMark(symbol: TableStyle.keySymbol, color: NSColor(TableStyle.keyColor))
            : column.unique ? LineMark(symbol: TableStyle.uniqueSymbol, color: NSColor(TableStyle.uniqueColor))
            : key != .none ? LineMark(symbol: TableStyle.linkSymbol, color: NSColor(TableStyle.linkColor)) : nil
        return LineReading(row: ColumnLine(column, key: key), spans: spans, mark: mark)
    }

    /// The unread words of a line but those at `skipped` (a key's), as written.
    private static func unread(_ scan: ColumnGrammar.Scan, leaving skipped: ClosedRange<Int>) -> String {
        scan.words.enumerated().filter { !skipped.contains($0.offset) && ($0.element.role == .unread || $0.element.role == .arrow) }
            .map { $0.element.text == ColumnGrammar.typedArrow ? ColumnGrammar.arrow : $0.element.text }.joined(separator: " ")
    }

    /// The row a key's target names, at `range` in the line: the run's reference (printed or picked: the row it stood for, whatever
    /// else is called so), on the whole target or on its column after the dot; else by name, a table on the shape's board and its
    /// column, or its primary key for a table alone. Nil where it names no row, or the line's own (`own`: a column is not its own key).
    static func target(_ word: String, at range: NSRange, in line: LineText, from own: PartID, _ context: LineContext) -> (table: ShapeID, row: PartAddress)? {
        let editor = context.editor
        // Where nothing draws connections, a key can't be drawn: its words stay words.
        guard editor.registry.drawsConnections else { return nil }
        func row(_ address: PartAddress?) -> (table: ShapeID, row: PartAddress)? {
            guard let address, address.part != nil, address != PartAddress(context.shape, part: own), let record = editor.document[address.shape],
                  record.kind == DatabaseTable.kind,
                  editor.registry.parts(of: record)?.contains(where: { $0.id == address.part }) == true else { return nil }
            return (address.shape, address)
        }
        if let found = row(line.reference(at: range)) { return found }
        guard let (table, column) = ColumnGrammar.target(word) else { return nil }
        if let column {
            let length = (column as NSString).length
            if let found = row(line.reference(at: NSRange(location: NSMaxRange(range) - length, length: length))) { return found }
        }
        guard let id = editor.service(KitNames.self)?.tableNamed(table, besides: context.shape),
              let record = editor.document[id]?.typed(as: DatabaseTable.self) else { return nil }
        let picked = column.map { name in record.props.columns.first { $0.name == name } } ?? Self.primaryKey(of: record.props)
        return picked.flatMap { $0.id == own && id == context.shape ? nil : (id, PartAddress(id, part: $0.id)) }
    }

    /// Whether a key's target as typed names a table on the board (`customers.`, `customers.i`): its pill forms.
    private static func names(_ word: String, at range: NSRange, in line: LineText, from own: PartID, _ context: LineContext) -> Bool {
        if target(word, at: range, in: line, from: own, context) != nil { return true }
        guard let (table, _) = ColumnGrammar.target(word) else { return false }
        return context.editor.service(KitNames.self)?.tableNamed(table, besides: context.shape) != nil
    }

    /// A table's primary key's column: the first that's part of it.
    static func primaryKey(of table: DatabaseTable) -> Column? { table.columns.first(where: \.primaryKey) }

    /// The line as the grammar prints it: an enum's name as it's called now, standing for it; then the key the line holds, or the
    /// board's for a column as stored, `→ customers.id` with the far table's and column's names as they are now, standing for the row.
    func print(_ line: ColumnLine, in context: LineContext) -> LineText {
        var column = line.column
        if let id = column.type.shape, let name = context.editor.service(KitNames.self)?.name(of: id) { column.type.words = name }
        var string = ColumnGrammar.print(column)
        var references: [LineReference] = []
        if let id = column.type.shape, !column.type.words.isEmpty,
           let type = ColumnGrammar.placedWords(of: string).dropFirst().first, type.text == column.type.words {
            references.append(LineReference(range: type.range, target: PartAddress(id)))
        }
        if let target = Self.key(of: line, in: context), let written = Self.written(target, context.editor) {
            string += " \(ColumnGrammar.arrow) "
            references.append(LineReference(range: NSRange(location: (string as NSString).length, length: (written as NSString).length), target: target))
            string += written
        }
        return LineText(string, references: references)
    }

    /// The row a line's key goes to: the one it says, or for a column as stored the board's (the key index).
    static func key(of line: ColumnLine, in context: LineContext) -> PartAddress? {
        switch line.key {
        case .none: nil
        case .to(let target): target
        case .stored: context.row.flatMap { context.editor.service(KeyIndex.self)?.target(of: $0, in: context.shape) }
        }
    }

    /// A row of a table written as a key's target, by the names they have now: `customers.id`. Nil for one that's gone.
    static func written(_ target: PartAddress, _ editor: CanvasEditor) -> String? {
        guard let part = target.part, let record = editor.shape(inFile: target.shape),
              let column = editor.registry.parts(of: record)?.first(where: { $0.id == part }) else { return nil }
        // A table with no name yet is the pill's placeholder: the line still holds its key, standing for the row, so editing the
        // column keeps it.
        return ColumnGrammar.written(table: editor.registry.title(of: record) ?? TableStyle.label, column: column.name)
    }

    func offers(at caret: Int, in line: LineText, reading: LineReading<ColumnLine>, context: LineContext) -> LineOffers? {
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
        let previous = before.last?.lowercased() ?? ""
        // Right after a key's arrow: the rows a key may go to.
        if previous == ColumnGrammar.arrow || previous == ColumnGrammar.typedArrow,
           before.dropLast().allSatisfy({ $0 != ColumnGrammar.arrow && $0 != ColumnGrammar.typedArrow }) {
            return keyOffers(typed, range: range, context)
        }
        // Nothing after a default's word, a key's target or a word nothing reads.
        if previous == ColumnGrammar.default || before.contains(where: { $0 == ColumnGrammar.arrow || $0 == ColumnGrammar.typedArrow }) { return nil }
        let said = Set(before.map { $0.lowercased() })
        let items = LineLooks.flags.filter { !said.contains($0.word) }.map { flag in
            LineOffer(CaretCompletion(label: flag.label, insert: flag.insert))
        }
        return items.isEmpty ? nil : LineOffers(range: range, query: typed, items: items)
    }

    /// After `→`: the tables on the shape's board that `typed` finds (Mentions' search with the table kind, nearest and recent first
    /// with nothing typed), each table's key columns as `customers.id`; after `customers.`, that table's key columns by name. A key
    /// column is one of its primary key or a unique one (all of a table's, where it has none of those). Each with its type, lit while
    /// it's highlighted, and standing for its row once picked.
    func keyOffers(_ typed: String, range: NSRange, _ context: LineContext) -> LineOffers? {
        let editor = context.editor
        func keyColumns(_ id: ShapeID) -> [Column] {
            guard let table = editor.document[id]?.typed(as: DatabaseTable.self)?.props else { return [] }
            let keys = table.columns.filter { $0.primaryKey || $0.unique }
            return keys.isEmpty ? table.columns : keys
        }
        func offer(_ table: ShapeID, _ column: Column, label: String) -> LineOffer {
            LineOffer(CaretCompletion(label: label, detail: column.type.words, insert: label), light: PartAddress(table, part: column.id))
        }
        if let dot = typed.lastIndex(of: "."), let (name, _) = ColumnGrammar.target(String(typed[...dot])),
           let table = editor.service(KitNames.self)?.tableNamed(name, besides: context.shape) {
            let after = String(typed[typed.index(after: dot)...])
            let length = (after as NSString).length
            let start = range.location + (String(typed[...dot]) as NSString).length
            let wordEnd = NSMaxRange(range)
            let items = keyColumns(table).map { offer(table, $0, label: $0.name) }
            guard !items.isEmpty else { return nil }
            return LineOffers(range: NSRange(location: start, length: max(length, wordEnd - start)), query: after, items: items)
        }
        guard let mentions = editor.mentions else { return nil }
        let board = editor.file.board(containing: context.shape)
        let found = mentions.candidates(matching: typed, in: AnyMentionable.self, for: context.shape, kinds: [DatabaseTable.kind]) { id in
            editor.file.board(containing: id) == board
        }
        var seen: Set<ShapeID> = []
        var items: [LineOffer] = []
        for candidate in found.all where seen.insert(candidate.id).inserted {
            guard let record = editor.document[candidate.id], let name = editor.registry.title(of: record) else { continue }
            for column in keyColumns(candidate.id) {
                items.append(offer(candidate.id, column, label: ColumnGrammar.written(table: name, column: column.name)))
            }
        }
        return items.isEmpty ? nil : LineOffers(range: range, query: typed, items: items)
    }

    /// SQL's types, then the file's enums, each in its purple chip and lit while it's highlighted.
    func typeOffers(_ context: LineContext) -> [LineOffer] {
        let types = LineLooks.sqlTypes.map { LineOffer(CaretCompletion(label: $0, insert: $0)) }
        let enums = (context.editor.service(KitNames.self)?.enums ?? []).reduce(into: [(id: ShapeID, name: String)]()) { list, found in
            if !list.contains(where: { $0.name == found.name }) { list.append((found.id, found.name)) }
        }
        return types + enums.map { LineOffer(CaretCompletion(label: $0.name, detail: EnumStyle.label, insert: $0.name, chip: LineLooks.enumChip), light: PartAddress($0.id)) }
    }

    var substitutions: [LineSubstitution] { [LineSubstitution(ColumnGrammar.typedArrow, becomes: ColumnGrammar.arrow)] }

    /// "customer_id, uuid, unique, key to id in customers": its name, its type, what it is, and where its key goes.
    func spoken(_ line: ColumnLine, in context: LineContext) -> String {
        let column = line.column
        var words = [column.name]
        if !column.type.words.isEmpty {
            let type = column.type.shape.flatMap { context.editor.service(KitNames.self)?.name(of: $0) } ?? column.type.words
            words.append(column.type.shape == nil ? type : "\(type) enum")
        }
        if column.primaryKey { words.append("primary key") }
        if column.unique { words.append("unique") }
        if column.nullable { words.append("null") }
        if let value = column.default { words.append("default \(value)") }
        if let target = Self.key(of: line, in: context), let name = context.editor.accessibleName(of: target) { words.append("key to \(name)") }
        if !column.unread.isEmpty { words.append(column.unread) }
        return words.joined(separator: ", ")
    }
}

/// A table written as lines: its columns, the column grammar, and its steps. A line's key is written with its column, in the
/// same step: the arrow made, re-aimed or deleted (the key index says what the board has, for the table being edited).
struct TableLines: LineModel {
    typealias Props = DatabaseTable
    typealias Row = ColumnLine

    /// The table being edited, and the keys its rows have: nil where the model is only named (the registry's).
    var table: ShapeID?
    weak var keys: KeyIndex?

    init(table: ShapeID? = nil, keys: KeyIndex? = nil) {
        self.table = table
        self.keys = keys
    }

    var noun: LineNoun { LineNoun("column") }
    var style: LineStyle { LineLooks.table }
    func rows(of props: DatabaseTable) -> [ColumnLine] { props.columns.map { ColumnLine($0) } }
    func setRows(_ rows: [ColumnLine], in props: inout DatabaseTable) { props.columns = rows.map(\.column) }
    func id(of row: ColumnLine) -> PartID { row.column.id }
    func role(of row: ColumnLine) -> LineRole { LineLooks.column }
    func roleOfNewRow(at index: Int, in props: DatabaseTable) -> LineRole { LineLooks.column }
    func grammar(for role: LineRole) -> any LineGrammar<ColumnLine> { ColumnLineGrammar() }
    func lineRect(_ line: Int, in frame: CGRect) -> CGRect { KitStyle.rowRect(line, in: frame) }

    /// What a line doesn't say stays: on delete, on update.
    func merged(_ read: ColumnLine, onto held: ColumnLine) -> ColumnLine {
        var line = read
        line.column.id = held.column.id
        line.column.onDelete = held.column.onDelete
        line.column.onUpdate = held.column.onUpdate
        return line
    }

    /// The columns written as the changes say, and each line's key with its column: a key made, re-aimed (the arrow's far end moved
    /// to the row named) or deleted where the line says otherwise than the board, all in the row's transaction; rows taken out handed
    /// to the core (`removeParts`), their keys going with them. False writes nothing (a locked table, a key that can't be drawn).
    func apply(_ changes: [LineChange<ColumnLine>], to id: ShapeID, in transaction: inout Transaction) -> Bool {
        guard let held = transaction.document[id], let record = held.typed(as: DatabaseTable.self) else { return false }
        // A locked table takes no key either: the columns can be as they were while a key is new.
        guard !transaction.isReadOnly(held) else { return false }
        var columns = record.props.columns
        var removed: Set<PartAddress> = []
        var keyed: [(column: PartID, key: ColumnKey)] = []
        for change in changes {
            switch change {
            case .add(let added, let index):
                columns.insert(contentsOf: added.map(\.column), at: min(max(0, index), columns.count))
                keyed += added.map { ($0.column.id, $0.key) }
            case .change(_, let to):
                guard let at = columns.firstIndex(where: { $0.id == to.column.id }) else { return false }
                columns[at] = to.column
                keyed.append((to.column.id, to.key))
            case .delete(let gone):
                let ids = Set(gone.map(\.column.id))
                columns.removeAll { ids.contains($0.id) }
                removed.formUnion(ids.map { PartAddress(id, part: $0) })
            case .move(let line, let index):
                guard let at = columns.firstIndex(where: { $0.id == line.column.id }) else { return false }
                let moved = columns.remove(at: at)
                columns.insert(moved, at: min(max(0, index), columns.count))
            }
        }
        transaction.update(id, as: DatabaseTable.self) { $0.props.columns = columns }
        guard transaction.document[id]?.typed(as: DatabaseTable.self)?.props.columns == columns else { return false }
        transaction.removeParts(removed)
        for (column, key) in keyed {
            guard KeyArrows.write(key, from: column, of: id, keys: keys, in: &transaction) else { return false }
        }
        return true
    }

    /// Add Column, Paste Columns, Rename Column (only its name changed), Add Key, Change Key and Delete Key (only its key changed),
    /// Change Key Action (only its on delete or on update, from its card), Change Column, Delete Column, Move Column.
    func stepName(of change: LineChange<ColumnLine>) -> String {
        switch change {
        case .add(let rows, _): rows.count == 1 ? TableStyle.addColumnStep : TableStyle.pasteColumnsStep
        case .change(let from, let to):
            switch (held(from), resolved(to)) {
            case let (was, now) where was == now:
                Self.onlyRenamed(from.column, to.column) ? TableStyle.renameColumnStep
                    : Self.onlyKeyActions(from.column, to.column) ? TableStyle.changeKeyActionStep : TableStyle.changeColumnStep
            case let (was, now) where from.column == to.column:
                was == nil ? TableStyle.addKeyStep : now == nil ? TableStyle.deleteKeyStep : TableStyle.changeKeyStep
            default: TableStyle.changeColumnStep
            }
        case .delete(let rows): rows.count == 1 ? TableStyle.deleteColumnStep : TableStyle.deleteColumnsStep
        case .move: TableStyle.moveColumnStep
        }
    }

    /// The row the key of the column `line` was read from goes to on the board: what the column has, whatever its printed line said
    /// (a key's words kept before their table existed read as a key that no arrow is yet).
    private func held(_ line: ColumnLine) -> PartAddress? {
        table.flatMap { keys?.target(of: line.column.id, in: $0) }
    }

    /// The row a line's key goes to, the board's for one as stored.
    private func resolved(_ line: ColumnLine) -> PartAddress? {
        switch line.key {
        case .none: nil
        case .to(let target): target
        case .stored: table.flatMap { keys?.target(of: line.column.id, in: $0) }
        }
    }

    /// What a fold keeps (⌃⌘↑): its keys (a primary key, a column that starts a key, read from the key index) and its
    /// unique columns, as T6 folds products to `id` and `sku`.
    func marked(_ shape: ShapeRecord<DatabaseTable>, in reading: LayoutReading) -> Set<PartID> {
        let keys = reading.service(KeyIndex.self)?.keys(of: shape.id) ?? [:]
        return Set(shape.props.columns.lazy.filter { $0.primaryKey || $0.unique || keys[$0.id] != nil }.map(\.id))
    }

    /// Whether `to` is `from` with only what its key does on delete or on update changed.
    static func onlyKeyActions(_ from: Column, _ to: Column) -> Bool {
        var acted = from
        acted.onDelete = to.onDelete
        acted.onUpdate = to.onUpdate
        return acted == to && (from.onDelete != to.onDelete || from.onUpdate != to.onUpdate)
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
    public static var columns: any LineGrammar<ColumnLine> { ColumnLineGrammar() }
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
    /// A key's target in a line: the link's blue, faint behind it, its text in the blue.
    static let keyFill = NSColor(TableStyle.linkColor).withAlphaComponent(TableStyle.keyPillFill)
    static let keyInk = NSColor(TableStyle.linkColor)

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
