import AppKit
import Canvas
import LineRows
import Palette

// A column's card (⌘↓ in its line, T4 panel 1): its type, the row its key references, null, unique, primary key, its default,
// and what its key does on delete and on update. Each line writes the column as its line would say it, through the column
// grammar (a type or a default is printed into the line and read back, so `uuid?` is a nullable uuid and words the grammar
// can't place stay unread, as typed in the line), in one step the table names by what changed: Change Column, Add Key, Change
// Key, Delete Key, Change Key Action. References reads the key index (a key is its arrow): a row named makes the key, re-aims it
// or, emptied, deletes it, as the line's `→` does; words that name no row stay the line's `→ words`, no arrow. An enum's value
// has nothing more than its line, so no card.

extension TableLines {
    func card(of row: ColumnLine, in context: LineContext) -> LineCard<ColumnLine>? {
        let column = row.column
        let keyed = ColumnLineGrammar.key(of: row, in: context) != nil
        let mark: LineMark? = column.primaryKey ? LineMark(symbol: TableStyle.keySymbol, color: NSColor(TableStyle.keyColor))
            : keyed ? LineMark(symbol: TableStyle.linkSymbol, color: NSColor(TableStyle.linkColor))
            : column.unique ? LineMark(symbol: TableStyle.uniqueSymbol, color: NSColor(TableStyle.uniqueColor)) : nil
        return LineCard(header: LineCardHeader(name: column.name, mark: mark), lines: [
            .field(TableStyle.typeLine, grammar: ColumnTypeGrammar(), get: { line, _ in line.column.type.words.isEmpty ? nil : line.column.type },
                   set: { line, type, _ in line.column = ColumnCard.retyped(line.column, type) }),
            .field(TableStyle.referencesLine, grammar: ColumnReferenceGrammar(), get: ColumnCard.reference(of:in:), set: ColumnCard.setReference),
            .toggle(TableStyle.nullLine, get: \.column.nullable, set: { $0.column.nullable = $1 }),
            .toggle(TableStyle.uniqueLine, get: \.column.unique, set: { $0.column.unique = $1 }),
            .toggle(TableStyle.primaryKeyLine, get: \.column.primaryKey, set: { $0.column.primaryKey = $1 }),
            .field(TableStyle.defaultLine, grammar: ColumnDefaultGrammar(), get: { line, _ in line.column.default },
                   set: { line, value, _ in line.column = ColumnCard.defaulted(line.column, value) }),
            .choice(TableStyle.onDeleteLine, options: TableStyle.keyActions, get: \.column.onDelete, set: { $0.column.onDelete = $1 }),
            .choice(TableStyle.onUpdateLine, options: TableStyle.keyActions, get: \.column.onUpdate, set: { $0.column.onUpdate = $1 }),
        ])
    }
}

/// What a column's card writes, as the column's line would.
@MainActor
enum ColumnCard {
    /// `column` with its type as `type` says (none: no type), read back through its line: a `?` after it is null, words after it
    /// the line's own (`not null`) or kept unread; the enum it names kept while its words stay its.
    static func retyped(_ column: Column, _ type: TypeRef?) -> Column {
        var written = column
        written.type = TypeRef(type?.words ?? "")
        var read = normalized(written)
        if let type, read.type.words == bare(ColumnGrammar.placedWords(of: type.words).first?.text ?? "") { read.type.shape = type.shape }
        return read
    }

    /// `column` with `value` as its default (none: no default), read back through its line.
    static func defaulted(_ column: Column, _ value: String?) -> Column {
        var written = column
        written.default = value
        return normalized(written)
    }

    /// A column as its line, printed and read again, says it: what a line would hold, with what no line says (on delete, on
    /// update) kept.
    static func normalized(_ column: Column) -> Column {
        guard var read = ColumnGrammar.read(ColumnGrammar.print(column), id: column.id) else { return column }
        read.onDelete = column.onDelete
        read.onUpdate = column.onUpdate
        read.type.shape = read.type.words == column.type.words ? column.type.shape : nil
        return read
    }

    /// A type's words without the `?` that says null.
    private static func bare(_ words: String) -> String { words.count > 1 && words.hasSuffix("?") ? String(words.dropLast()) : words }

    /// The row a column's key references, read from the key index, or the words its line's `→` keeps that name none.
    static func reference(of line: ColumnLine, in context: LineContext) -> ColumnReference? {
        if let target = ColumnLineGrammar.key(of: line, in: context) { return .row(target) }
        guard let words = ColumnGrammar.key(in: line.column.unread) else { return nil }
        return .words(String(words.written.dropFirst(ColumnGrammar.arrow.count)).trimmingCharacters(in: .whitespaces))
    }

    /// The column referencing what `reference` says, as its line's `→` would: a row is its key (the arrow made, re-aimed, or kept
    /// where it's the one the board has), none takes the key out, and words that name no row are kept as `→ words`, no key.
    static func setReference(_ line: inout ColumnLine, _ reference: ColumnReference?, _ context: LineContext) {
        let rest = ColumnGrammar.key(in: line.column.unread)?.rest ?? line.column.unread
        let current = ColumnLineGrammar.key(of: line, in: context)
        switch reference {
        case .row(let target):
            line.column.unread = rest
            if target != current { line.key = .to(target) }
        case .words(let words):
            line.column.unread = [rest, "\(ColumnGrammar.arrow) \(words)"].filter { !$0.isEmpty }.joined(separator: " ")
            line.key = .none
        case nil:
            line.column.unread = rest
            if current != nil { line.key = .none }
        }
    }
}

/// What a column's card says it references: a row (its key), or words that name none.
enum ColumnReference: Equatable {
    case row(PartAddress)
    case words(String)
}

/// A column's type, in its card: its words in code, an enum's name in its purple pill standing for the enum; SQL's types and the
/// file's enums offered, as after a name in the line.
struct ColumnTypeGrammar: LineGrammar {
    func read(_ line: LineText, id: PartID, in context: LineContext) -> LineReading<TypeRef> {
        let words = ColumnGrammar.placedWords(of: line.string)
        guard let first = words.first else { return LineReading(row: nil) }
        let bare = first.text.count > 1 && first.text.hasSuffix("?") ? String(first.text.dropLast()) : first.text
        let named: ShapeID? = if let target = line.reference(at: NSRange(location: first.range.location, length: (bare as NSString).length)),
                                 context.editor.shape(inFile: target.shape)?.kind == DatabaseEnum.kind {
            target.shape
        } else {
            context.editor.service(KitNames.self)?.enumNamed(bare, near: context.shape)
        }
        var spans = [LineSpan(first.range, named == nil ? .code : .pill(LineLooks.enumFill, ink: LineLooks.enumInk))]
        spans += words.dropFirst().map { LineSpan($0.range, ColumnGrammar.isFlag($0.text) ? .keyword : .plain) }
        return LineReading(row: TypeRef(words.map(\.text).joined(separator: " "), shape: named), spans: spans)
    }

    func print(_ type: TypeRef, in context: LineContext) -> LineText {
        guard let id = type.shape, let name = context.editor.service(KitNames.self)?.name(of: id) else { return LineText(type.words) }
        return LineText(name, references: [LineReference(range: NSRange(location: 0, length: (name as NSString).length), target: PartAddress(id))])
    }

    func offers(at caret: Int, in line: LineText, reading: LineReading<TypeRef>, context: LineContext) -> LineOffers? {
        let words = ColumnGrammar.placedWords(of: line.string)
        let at = words.firstIndex { caret >= $0.range.location && caret <= NSMaxRange($0.range) }
        guard (at ?? words.filter { NSMaxRange($0.range) < caret }.count) == 0 else { return nil }
        let range = at.map { words[$0].range } ?? NSRange(location: caret, length: 0)
        let typed = at.map { String(words[$0].text.utf16.prefix(caret - words[$0].range.location)) ?? "" } ?? ""
        return LineOffers(range: range, query: typed, items: ColumnLineGrammar().typeOffers(context))
    }

    func spoken(_ type: TypeRef, in context: LineContext) -> String { type.words }
}

/// The row a column's key references, in its card: `customers.id` in the link's blue pill once it names a table's row (by the
/// run's reference, else by name); the tables' key columns offered, as after `→` in the line, each lit.
struct ColumnReferenceGrammar: LineGrammar {
    func read(_ line: LineText, id: PartID, in context: LineContext) -> LineReading<ColumnReference> {
        let words = ColumnGrammar.placedWords(of: line.string)
        guard let first = words.first else { return LineReading(row: nil) }
        let text = words.map(\.text).joined(separator: " ")
        if words.count == 1, let found = ColumnLineGrammar.target(first.text, at: first.range, in: line, from: context.row ?? id, context) {
            return LineReading(row: .row(found.row), spans: [LineSpan(first.range, .pill(LineLooks.keyFill, ink: LineLooks.keyInk))])
        }
        return LineReading(row: .words(text), spans: words.map { LineSpan($0.range, .plain) })
    }

    func print(_ reference: ColumnReference, in context: LineContext) -> LineText {
        switch reference {
        case .row(let target):
            guard let written = ColumnLineGrammar.written(target, context.editor) else { return LineText("") }
            return LineText(written, references: [LineReference(range: NSRange(location: 0, length: (written as NSString).length), target: target)])
        case .words(let words):
            return LineText(words)
        }
    }

    func offers(at caret: Int, in line: LineText, reading: LineReading<ColumnReference>, context: LineContext) -> LineOffers? {
        let words = ColumnGrammar.placedWords(of: line.string)
        let at = words.firstIndex { caret >= $0.range.location && caret <= NSMaxRange($0.range) }
        guard (at ?? words.filter { NSMaxRange($0.range) < caret }.count) == 0 else { return nil }
        let range = at.map { words[$0].range } ?? NSRange(location: caret, length: 0)
        let typed = at.map { String(words[$0].text.utf16.prefix(caret - words[$0].range.location)) ?? "" } ?? ""
        return ColumnLineGrammar().keyOffers(typed, range: range, context)
    }

    var substitutions: [LineSubstitution] { [] }

    func spoken(_ reference: ColumnReference, in context: LineContext) -> String {
        switch reference {
        case .row(let target): context.editor.accessibleName(of: target) ?? ""
        case .words(let words): words
        }
    }
}

/// A column's default, in its card: what it is as written, in code.
struct ColumnDefaultGrammar: LineGrammar {
    func read(_ line: LineText, id: PartID, in context: LineContext) -> LineReading<String> {
        let text = line.string.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return LineReading(row: nil) }
        return LineReading(row: text, spans: ColumnGrammar.placedWords(of: line.string).map { LineSpan($0.range, .code) })
    }

    func print(_ value: String, in context: LineContext) -> LineText { LineText(value) }

    func spoken(_ value: String, in context: LineContext) -> String { value }
}
