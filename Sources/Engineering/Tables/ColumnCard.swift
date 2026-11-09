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
    /// `column` with its type as `type` says (none: no type), read back through its line: the words typed where its line has its
    /// type, so a `?` after it is null, a type of several words is SQL's or quoted as the line reads one, and words after it are
    /// the line's own (`not null`) or kept unread; the enum it names kept while its words stay its.
    static func retyped(_ column: Column, _ type: TypeRef?) -> Column {
        var untyped = column
        untyped.type = TypeRef("")
        let printed = ColumnGrammar.print(untyped) as NSString
        let text = type?.words.trimmingCharacters(in: .whitespaces) ?? ""
        let placed = ColumnGrammar.placedWords(of: printed as String)
        // The empty type a print says no type with, where a word kept would be read as one, is the place the new type goes.
        let tail = placed.dropFirst().first.flatMap { $0.text == ColumnGrammar.quoted("") ? NSMaxRange($0.range) : nil }
        guard !text.isEmpty, let name = placed.first,
              var read = ColumnGrammar.read(printed.substring(to: NSMaxRange(name.range)) + " " + text + printed.substring(from: tail ?? NSMaxRange(name.range)), id: column.id)
        else { return normalized(untyped) }
        read.onDelete = column.onDelete
        read.onUpdate = column.onUpdate
        if let type, read.type.words == ColumnGrammar.typeRun(ColumnGrammar.placedWords(of: text)[...])?.words { read.type.shape = type.shape }
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

    /// The row a column's key references, read from the key index, or the words its line's `→` keeps that name none.
    static func reference(of line: ColumnLine, in context: LineContext) -> ColumnReference? {
        if let target = ColumnLineGrammar.key(of: line, in: context) { return .row(target, rest: "") }
        guard let words = ColumnGrammar.key(in: line.column.unread) else { return nil }
        return .words(String(words.written.dropFirst(ColumnGrammar.arrow.count)).trimmingCharacters(in: .whitespaces))
    }

    /// The column referencing what `reference` says, as its line's `→` would: a row is its key (the arrow made, re-aimed, or kept
    /// where it's the one the board has), none takes the key out, and words that name no row are kept as `→ words`, no key.
    static func setReference(_ line: inout ColumnLine, _ reference: ColumnReference?, _ context: LineContext) {
        let rest = ColumnGrammar.key(in: line.column.unread)?.rest ?? line.column.unread
        let current = ColumnLineGrammar.key(of: line, in: context)
        switch reference {
        case .row(let target, let extra):
            // Words after the target stay the line's own, once.
            line.column.unread = extra.isEmpty || rest.hasSuffix(extra) ? rest : [rest, extra].filter { !$0.isEmpty }.joined(separator: " ")
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

/// What a column's card says it references: a row (its key, and the words typed after it, which stay the line's), or words that
/// name none.
enum ColumnReference: Equatable {
    case row(PartAddress, rest: String)
    case words(String)
}

/// A column's type, in its card: its words in code, an enum's name in its purple pill standing for the enum; SQL's types and the
/// file's enums offered, as after a name in the line.
struct ColumnTypeGrammar: LineGrammar {
    func read(_ line: LineText, id: PartID, in context: LineContext) -> LineReading<TypeRef> {
        let words = ColumnGrammar.placedWords(of: line.string)
        guard !words.isEmpty else { return LineReading(row: nil) }
        // Its type's words as a column's line reads them (several where SQL's are, a quoted name), then the grammar's own or plain.
        var spans: [LineSpan] = [], named: ShapeID?, after = words[...]
        if let run = ColumnGrammar.typeRun(words[...]) {
            named = if let target = line.reference(at: run.inner), context.editor.shape(inFile: target.shape)?.kind == DatabaseEnum.kind {
                target.shape
            } else {
                context.editor.service(KitNames.self)?.enumNamed(run.words, near: context.shape)
            }
            spans.append(LineSpan(run.range, named == nil ? .code : .pill(LineLooks.cardEnumFill, ink: LineLooks.cardEnumInk)))
            after = words.dropFirst(run.count)
        }
        spans += after.map { LineSpan($0.range, ColumnGrammar.isFlag($0.text) ? .keyword : .plain) }
        return LineReading(row: TypeRef(words.map(\.text).joined(separator: " "), shape: named), spans: spans)
    }

    func print(_ type: TypeRef, in context: LineContext) -> LineText {
        guard let id = type.shape, let name = context.editor.service(KitNames.self)?.name(of: id) else { return LineText(ColumnGrammar.written(type: type.words)) }
        let written = ColumnGrammar.written(type: name)
        let inner = written == name ? NSRange(location: 0, length: (name as NSString).length) : NSRange(location: 1, length: (written as NSString).length - 2)
        return LineText(written, references: [LineReference(range: inner, target: PartAddress(id))])
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
        var words = ColumnGrammar.placedWords(of: line.string)
        // The arrow the line's key starts with, typed or not, isn't part of the target.
        var spans: [LineSpan] = []
        if let arrow = words.first, arrow.text == ColumnGrammar.arrow || arrow.text == ColumnGrammar.typedArrow {
            spans.append(LineSpan(arrow.range, .keyword))
            words.removeFirst()
        }
        guard let first = words.first else { return LineReading(row: nil, spans: spans) }
        if let found = ColumnLineGrammar.target(first.text, at: first.range, in: line, from: context.row ?? id, context) {
            spans.append(LineSpan(first.range, .pill(LineLooks.cardKeyFill, ink: LineLooks.cardKeyInk)))
            spans += words.dropFirst().map { LineSpan($0.range, .plain) }
            return LineReading(row: .row(found.row, rest: words.dropFirst().map(\.text).joined(separator: " ")), spans: spans)
        }
        spans += words.map { LineSpan($0.range, .plain) }
        return LineReading(row: .words(words.map(\.text).joined(separator: " ")), spans: spans)
    }

    func print(_ reference: ColumnReference, in context: LineContext) -> LineText {
        switch reference {
        case .row(let target, let rest):
            guard let written = ColumnLineGrammar.written(target, context.editor) else { return LineText("") }
            let length = (written as NSString).length
            return LineText(rest.isEmpty ? written : "\(written) \(rest)", references: [LineReference(range: NSRange(location: 0, length: length), target: target)])
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
        case .row(let target, _): context.editor.accessibleName(of: target) ?? ""
        case .words(let words): words
        }
    }
}

/// A column's default, in its card: what it is as written, in code; a default in double quotes alone is the words between them,
/// as its line reads one.
struct ColumnDefaultGrammar: LineGrammar {
    func read(_ line: LineText, id: PartID, in context: LineContext) -> LineReading<String> {
        let text = line.string.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return LineReading(row: nil) }
        let words = ColumnGrammar.placedWords(of: text)
        let value = words.count == 1 ? ColumnGrammar.unquoted(words[0].text) ?? text : text
        return LineReading(row: value, spans: ColumnGrammar.placedWords(of: line.string).map { LineSpan($0.range, .code) })
    }

    func print(_ value: String, in context: LineContext) -> LineText { LineText(value) }

    func spoken(_ value: String, in context: LineContext) -> String { value }
}
