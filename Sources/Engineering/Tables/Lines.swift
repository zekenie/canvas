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
/// file's enums; after a type, null, unique, default, pk and →; after `→`, the key columns of the file's tables, nearest first (Mentions'
/// search with the table kind), and after `customers.` that table's, each lit on the board while it's highlighted.
struct ColumnLineGrammar: LineGrammar {
    typealias Row = ColumnLine

    func read(_ line: LineText, id: PartID, in context: LineContext) -> LineReading<ColumnLine> {
        let scan = ColumnGrammar.scan(line.string, id: id)
        guard var column = scan.column else { return LineReading(row: nil) }
        var spans: [LineSpan] = []
        var key = ColumnKey.none
        var arrowRead = false
        // The word after the first `→`, the only one that is a key: a later `→`'s is words.
        let keyTarget = scan.words.firstIndex { $0.role == .arrow }.map { $0 + 1 }
        for (index, word) in scan.words.enumerated() {
            switch word.role {
            case .name: spans.append(LineSpan(word.range, .name))
            case .type:
                let words = column.type.words, inner = scan.typeRange ?? word.range
                // A run the line carries stands for its enum whatever else is called so; a name typed afresh is found.
                let named: ShapeID? = if let target = line.reference(at: inner), context.editor.shape(inFile: target.shape)?.kind == DatabaseEnum.kind {
                    target.shape
                } else {
                    context.editor.service(KitNames.self)?.enumNamed(words, near: context.shape)
                }
                column.type.shape = named
                // A quoted name's pill is its words', the quotes outside it, as an API's quoted type's is.
                let quoted = inner.location != word.range.location
                spans.append(LineSpan(quoted ? inner : word.range, named == nil ? .code : .pill(LineLooks.enumFill, ink: LineLooks.enumInk)))
            case .keyword: spans.append(LineSpan(word.range, .keyword))
            case .arrow:
                spans.append(LineSpan(word.range, .keyword))
                // The first `→` only, as `canvas draw` reads a line's (`ColumnGrammar.key(in:)`): the word after it is its target, a key
                // once it names a table's row on the board or one a pill can reach; one that names none leaves the line no key, and a
                // later `→` is words.
                guard !arrowRead else { continue }
                arrowRead = true
                guard scan.words.indices.contains(index + 1), scan.words[index + 1].role == .unread else { continue }
                let target = scan.words[index + 1]
                if let found = Self.target(target.text, at: target.range, in: line, from: id, context) {
                    key = .to(found.row)
                    column.unread = Self.unread(scan, leaving: index...(index + 1))
                }
            case .defaultValue: spans.append(LineSpan(word.range, .code))
            case .unread:
                // The first `→`'s target that names a table is in its pill, the table's own name already as `customers.` is typed.
                if index == keyTarget, Self.names(word.text, at: word.range, in: line, from: id, context) {
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
    /// else is called so), on the whole target or on its column after the dot; else by name, the table nearest the shape (its board's,
    /// else another's that a pill can stand for) and its column, or its primary key for a table alone. Nil where it names no row, or the line's own (`own`: a column is not its own key).
    static func target(_ word: String, at range: NSRange, in line: LineText, from own: PartID, _ context: LineContext) -> (table: ShapeID, row: PartAddress)? {
        let editor = context.editor
        // Where nothing draws connections, a key can't be drawn: its words stay words.
        guard editor.registry.drawsConnections else { return nil }
        func row(_ address: PartAddress?) -> (table: ShapeID, row: PartAddress)? {
            guard let address, address.part != nil, address != PartAddress(context.shape, part: own), let record = editor.shape(inFile: address.shape),
                  record.kind == DatabaseTable.kind,
                  editor.registry.parts(of: record)?.contains(where: { $0.id == address.part }) == true else { return nil }
            return (address.shape, address)
        }
        if let found = row(line.reference(at: range)) { return found }
        guard let (table, column) = ColumnGrammar.target(word) else { return nil }
        if let column {
            let length = (ColumnGrammar.written(column: column) as NSString).length
            if let found = row(line.reference(at: NSRange(location: NSMaxRange(range) - length, length: length))) { return found }
        }
        guard let id = editor.service(KitNames.self)?.tableNamed(table, besides: context.shape),
              let record = editor.shape(inFile: id)?.typed(as: DatabaseTable.self) else { return nil }
        let picked = column.map { name in record.props.columns.first { $0.name == name } } ?? Self.primaryKey(of: record.props)
        return picked.flatMap { $0.id == own && id == context.shape ? nil : (id, PartAddress(id, part: $0.id)) }
    }

    /// Whether a key's target as typed names a table the key can reach (`customers.`, `customers.i`): its pill forms.
    private static func names(_ word: String, at range: NSRange, in line: LineText, from own: PartID, _ context: LineContext) -> Bool {
        if target(word, at: range, in: line, from: own, context) != nil { return true }
        guard let (table, _) = ColumnGrammar.target(word) else { return false }
        return context.editor.service(KitNames.self)?.tableNamed(table, besides: context.shape) != nil
    }

    /// A table's primary key's column: the first that's part of it.
    static func primaryKey(of table: DatabaseTable) -> Column? { table.columns.first(where: \.primaryKey) }

    /// The line as the grammar prints it: an enum's name as it's called now (quoted where it's several words), standing for it;
    /// then the key the line holds, or the board's for a column as stored, `→ customers.id` with the far table's and column's names
    /// as they are now, standing for the row, before the words the column kept, so the line's first `→` is its key. A column that has
    /// a key keeps no key's words in the line (`→ customers.id` typed before customers was made, and the key drawn since, to there
    /// or elsewhere): the key is the one thing the line says of where it goes.
    func print(_ line: ColumnLine, in context: LineContext) -> LineText {
        var column = line.column
        if let id = column.type.shape, let name = context.editor.service(KitNames.self)?.name(of: id) { column.type.words = name }
        let target = Self.key(of: line, in: context)
        let written = target.flatMap { Self.written($0, context.editor) }
        // The board has the key, so the words a column kept of one (typed before its table existed, or aimed elsewhere) are stale and
        // not shown: the line says one key, and its next commit drops them.
        if target != nil, written != nil, let words = ColumnGrammar.key(in: column.unread) { column.unread = words.rest }
        let (string, keyRange) = ColumnGrammar.print(column, key: written)
        var references: [LineReference] = []
        if let id = column.type.shape, !column.type.words.isEmpty, let type = ColumnGrammar.scan(string).typeRange,
           (string as NSString).substring(with: type) == column.type.words {
            references.append(LineReference(range: type, target: PartAddress(id)))
        }
        if let target, let keyRange { references.append(LineReference(range: keyRange, target: target)) }
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
        // The caret in a type (all its words, `timestamp with time zone`), or in the word after one that goes on with a word typed so
        // far (`double pre`): SQL's types and the file's enums, a pick replacing the type from its first word.
        let text = line.string as NSString
        if let run = ColumnGrammar.scan(line.string).words.first(where: { $0.role == .type }) {
            let end = NSMaxRange(run.range)
            if caret >= run.range.location && caret <= end {
                let prefix = text.substring(with: NSRange(location: run.range.location, length: caret - run.range.location))
                return LineOffers(range: run.range, query: prefix, items: typeOffers(context, typed: prefix))
            }
            if let at, !typed.isEmpty, words.firstIndex(where: { NSMaxRange($0.range) == end }).map({ $0 + 1 }) == at {
                let prefix = text.substring(with: NSRange(location: run.range.location, length: caret - run.range.location)).lowercased()
                if LineLooks.sqlTypes.contains(where: { $0.contains(" ") && $0.hasPrefix(prefix) }) {
                    let whole = NSRange(location: run.range.location, length: NSMaxRange(words[at].range) - run.range.location)
                    return LineOffers(range: whole, query: prefix, items: typeOffers(context, typed: prefix))
                }
            }
        }
        if index == 1 {
            return LineOffers(range: range, query: typed, items: typeOffers(context, typed: typed))
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

    /// After `→`: the tables of the file that `typed` finds and a pill can reach (Mentions' search with the table kind, nearest and recent
    /// first with nothing typed; one on another board says which), each table's key columns as `customers.id`; after `customers.`, that table's key columns by name. A key
    /// column is one of its primary key or a unique one (all of a table's, where it has none of those). Each with its type, lit while
    /// it's highlighted, and standing for its row once picked.
    func keyOffers(_ typed: String, range: NSRange, _ context: LineContext) -> LineOffers? {
        let editor = context.editor
        func keyColumns(_ id: ShapeID) -> [Column] {
            guard let table = editor.shape(inFile: id)?.typed(as: DatabaseTable.self)?.props else { return [] }
            let keys = table.columns.filter { $0.primaryKey || $0.unique }
            return keys.isEmpty ? table.columns : keys
        }
        // A table in a database, or on another board, says where it is (Mentions' place: `billing`, a board's name): two alike in two
        // databases of one board, or on two boards, are told apart by it, as the `@` picker's rows are.
        func offer(_ table: ShapeID, _ column: Column, label: String, insert: String) -> (id: ShapeID, offer: LineOffer) {
            let detail = [column.type.words, editor.mentions?.place(ofShape: table)?.text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return (table, LineOffer(CaretCompletion(label: label, detail: detail, insert: insert), light: PartAddress(table, part: column.id)))
        }
        if let dot = typed.lastIndex(of: "."), let (name, _) = ColumnGrammar.target(String(typed[...dot])),
           let table = editor.service(KitNames.self)?.tableNamed(name, besides: context.shape) {
            let after = String(typed[typed.index(after: dot)...])
            let length = (after as NSString).length
            let start = range.location + (String(typed[...dot]) as NSString).length
            let wordEnd = NSMaxRange(range)
            let items = keyColumns(table).map { offer(table, $0, label: $0.name, insert: ColumnGrammar.written(column: $0.name)).offer }
            guard !items.isEmpty else { return nil }
            return LineOffers(range: NSRange(location: start, length: max(length, wordEnd - start)), query: after, items: items)
        }
        guard let mentions = editor.mentions else { return nil }
        // Every table of the file a key can reach, nearest first (Mentions' ranking): one on another board through a pill for it,
        // so only one a pill can stand for as it is (typing never makes a shape public).
        let verdicts = FarVerdicts(editor)
        let found = mentions.candidates(matching: typed, in: AnyMentionable.self, for: context.shape, kinds: [DatabaseTable.kind]) { id in
            switch verdicts.verdict(of: id) {
            case .here, .reads: true
            case .fulfils, .cannot: false
            }
        }
        var seen: Set<ShapeID> = []
        var offered: [(id: ShapeID, offer: LineOffer)] = []
        for candidate in found.all where seen.insert(candidate.id).inserted {
            guard let record = editor.shape(inFile: candidate.id), let name = editor.registry.title(of: record) else { continue }
            for column in keyColumns(candidate.id) {
                let written = ColumnGrammar.written(table: name, column: column.name)
                offered.append(offer(candidate.id, column, label: written, insert: written))
            }
        }
        // Two tables of one name in one place say the same: one is offered, the one typing would bind.
        let items = Self.distinct(offered, near: context.shape, editor.service(KitNames.self))
        return items.isEmpty ? nil : LineOffers(range: range, query: typed, items: items)
    }

    /// SQL's types, each in one word (`LineLooks.offeredTypes`), with a spelling of several words only once what is
    /// `typed` has its first word whole and runs into its second ("double p", "timestamp w"), so scattered letters never offer one;
    /// then the file's enums, each in its purple chip, lit while it's highlighted and standing for its enum once picked
    /// (a name of several words put in quotes, as the line reads one). Two enums of one name are both offered, each saying where it is
    /// (its database, or its board: Mentions' place), so either can be picked; two that nothing tells apart (one name, one place) are
    /// offered once, as the one typing binds, since a pick of either could only be that one.
    func typeOffers(_ context: LineContext, typed: String) -> [LineOffer] {
        let typed = typed.lowercased()
        let spelled = LineLooks.sqlTypes.filter { spelling in
            guard let space = spelling.firstIndex(of: " ") else { return false }
            return typed.count > spelling[..<space].count + 1 && spelling.hasPrefix(typed)
        }
        let types = (spelled + LineLooks.offeredTypes).map { LineOffer(CaretCompletion(label: $0, insert: $0)) }
        let names = context.editor.service(KitNames.self)
        let enums = names?.enums ?? []
        var counts: [String: Int] = [:]
        for found in enums { counts[found.name, default: 0] += 1 }
        let offered = enums.map { found -> (id: ShapeID, offer: LineOffer) in
            let place = counts[found.name, default: 0] > 1 ? context.editor.mentions?.place(ofShape: found.id)?.text : nil
            let detail = [EnumStyle.label, place].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return (found.id, LineOffer(CaretCompletion(label: found.name, detail: detail, insert: ColumnGrammar.written(type: found.name), chip: LineLooks.enumChip),
                                        light: PartAddress(found.id)))
        }
        return types + Self.distinct(offered, near: context.shape, names)
    }

    /// `found`'s offers, one of those that say the same (a label and what it says of where): the shape nearest `shape`, as typing
    /// binds it.
    private static func distinct(_ found: [(id: ShapeID, offer: LineOffer)], near shape: ShapeID, _ names: KitNames?) -> [LineOffer] {
        func said(_ offer: LineOffer) -> [String] { [offer.completion.label, offer.completion.detail, offer.completion.insert] }
        var alike: [[String]: [ShapeID]] = [:]
        for item in found { alike[said(item.offer), default: []].append(item.id) }
        var kept: [[String]: ShapeID] = [:]
        for (said, ids) in alike where ids.count > 1 { kept[said] = names?.nearest(ids, to: shape) ?? ids[0] }
        return found.filter { item in kept[said(item.offer)].map { $0 == item.id } ?? true }.map(\.offer)
    }

    var substitutions: [LineSubstitution] { [LineSubstitution(ColumnGrammar.typedArrow, becomes: ColumnGrammar.arrow)] }

    /// "customer_id, uuid, unique, key to id in customers": its name, its type, what it is, and where its key goes.
    func spoken(_ line: ColumnLine, in context: LineContext) -> String {
        let column = line.column
        var words = [column.name]
        if !column.type.words.isEmpty {
            // An enum as rest binds it (by the stored shape, else the words' name now), as the screen draws it.
            let enumName = TableDefinition.enumName(of: column, in: context.shape, registry: context.editor.registry, inFile: context.editor.shape(inFile:),
                                                    names: context.editor.service(KitNames.self))
            words.append(enumName.map { "\($0) enum" } ?? column.type.words)
        }
        if column.primaryKey { words.append("primary key") }
        if column.unique { words.append("unique") }
        if column.nullable { words.append("null") }
        if let value = column.default { words.append("default \(value)") }
        var unread = column.unread
        if let target = Self.key(of: line, in: context), let name = context.editor.accessibleName(of: target) {
            words.append("key to \(name)")
            if let kept = ColumnGrammar.key(in: unread) { unread = kept.rest }
        }
        if !unread.isEmpty { words.append(unread) }
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
    /// As wide as every column's name and type read whole at rest (`TableDefinition.wholeWidth`): a commit widens it so.
    func wholeWidth(of shape: ShapeRecord<DatabaseTable>, in editor: CanvasEditor) -> CGFloat? {
        TableDefinition.wholeWidth(of: shape.props.columns, in: shape.id, registry: editor.registry, inFile: editor.shape(inFile:), names: editor.service(KitNames.self))
    }
    func rows(of props: DatabaseTable) -> [ColumnLine] { props.columns.map { ColumnLine($0) } }
    func setRows(_ rows: [ColumnLine], in props: inout DatabaseTable) { props.columns = rows.map(\.column) }
    func id(of row: ColumnLine) -> PartID { row.column.id }
    func renaming(_ row: ColumnLine, to id: PartID) -> ColumnLine {
        var row = row
        row.column.id = id
        return row
    }
    func role(of row: ColumnLine) -> LineRole { LineLooks.column }
    func roleOfNewRow(at index: Int, in props: DatabaseTable) -> LineRole { LineLooks.column }
    func grammar(for role: LineRole) -> any LineGrammar<ColumnLine> { ColumnLineGrammar() }
    func lineRect(_ line: Int, in frame: CGRect) -> CGRect { KitStyle.rowRect(line, in: frame) }

    /// Columns taken out are a new table (T5 panel 4: `addresses`): its own `id uuid pk` first, then the columns, as wide as
    /// the table they came from; its name typed at once. Columns that already hold the key (one named `id`, or any primary key)
    /// are the table's own: no second `id uuid pk` is put before them.
    func takeOut(_ rows: [ColumnLine], from shape: ShapeRecord<DatabaseTable>) -> DatabaseTable {
        var table = DatabaseTable.starter()
        if rows.contains(where: { $0.column.primaryKey || $0.column.name == "id" }) { table.columns = [] }
        table.columns += rows.map(\.column)
        table.frame.size = CGSize(width: shape.props.frame.width, height: KitStyle.height(rows: table.columns.count))
        return table
    }
    var takeOutEditsTitle: Bool { true }

    /// A column's lead is its mark in the gutter (a primary key's key, a key's link, a unique column's "1"): a press there drags
    /// the column, selected or not. A column with no mark has none: its row drags once it's selected.
    func lead(of row: ColumnLine, at index: Int, among rows: [ColumnLine], line: CGRect, in context: LineContext) -> CGRect? {
        let column = row.column
        guard column.primaryKey || column.unique || context.editor.service(KeyIndex.self)?.keys(of: context.shape)[column.id] != nil else { return nil }
        let side = KitStyle.leadSide
        return CGRect(x: line.minX + KitStyle.gutterMiddle - side / 2, y: line.midY - side / 2, width: side, height: side)
    }

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
        printable(table.flatMap { keys?.target(of: line.column.id, in: $0) })
    }

    /// The row a key goes to, but where the line couldn't say it (its table or row is gone): that key is no part of the line.
    private func printable(_ target: PartAddress?) -> PartAddress? {
        guard let target, let editor = keys?.editor, ColumnLineGrammar.written(target, editor) != nil else { return nil }
        return target
    }

    /// The row a line's key goes to, the board's for one as stored.
    private func resolved(_ line: ColumnLine) -> PartAddress? {
        switch line.key {
        case .none: nil
        case .to(let target): target
        case .stored: held(line)
        }
    }

    /// What a fold keeps (⌃⌘↑): its keys (a primary key, a column that starts a key, read from the key index) and its
    /// unique columns, as T6 folds products to `id` and `sku`.
    func marked(_ shape: ShapeRecord<DatabaseTable>, in reading: LayoutReading) -> Set<PartID> {
        let keys = reading.service(KeyIndex.self)?.keys(of: shape.id, in: reading) ?? [:]
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
    /// As wide as every value and its name read whole at rest (`EnumDefinition.wholeWidth`): a commit widens it so, as a table's.
    func wholeWidth(of shape: ShapeRecord<DatabaseEnum>, in editor: CanvasEditor) -> CGFloat? { EnumDefinition.wholeWidth(of: shape) }
    func rows(of props: DatabaseEnum) -> [EnumValue] { props.values }
    func setRows(_ rows: [EnumValue], in props: inout DatabaseEnum) { props.values = rows }
    func id(of row: EnumValue) -> PartID { row.id }
    func renaming(_ row: EnumValue, to id: PartID) -> EnumValue {
        var row = row
        row.id = id
        return row
    }
    /// Values taken out are an enum of their own, its name typed at once.
    var takeOutEditsTitle: Bool { true }
    func takeOut(_ rows: [EnumValue], from shape: ShapeRecord<DatabaseEnum>) -> DatabaseEnum {
        var type = shape.props
        type.values = rows
        type.frame.size.height = KitStyle.height(rows: rows.count)
        return type
    }
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
    /// A column as its card writes it where it gives its type, its default (`ColumnCard`): the columns the card can make.
    public static func cardRetyped(_ column: Column, _ type: TypeRef?) -> Column { ColumnCard.retyped(column, type) }
    public static func cardDefaulted(_ column: Column, _ value: String?) -> Column { ColumnCard.defaulted(column, value) }
    public static func cardNormalized(_ column: Column) -> Column { ColumnCard.normalized(column) }
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
    /// The same pills on a card's bubble, which follows the appearance where the table's paper doesn't: the hues made for the
    /// canvas, light and dark.
    static let cardKeyFill = NSColor(Swatch(KitStyle.linkBlue).solid).fading(to: TableStyle.keyPillFill)
    static let cardKeyInk = NSColor(Swatch(KitStyle.linkBlue).ink)
    static let cardEnumFill = NSColor(Swatch(KitStyle.enumPurple).solid).fading(to: TableStyle.enumPillFill)
    static let cardEnumInk = NSColor(Swatch(KitStyle.enumPurple).ink)

    /// What's offered after a type: each flag's word, what the list says, what a pick puts in.
    static let flags: [(word: String, label: String, insert: String)] = [
        (ColumnGrammar.null, "null", "null"),
        (ColumnGrammar.unique, "unique", "unique"),
        (ColumnGrammar.default, "default", "default "),
        (ColumnGrammar.primaryKey, "pk", "pk"),
        (ColumnGrammar.arrow, ColumnGrammar.arrow, ColumnGrammar.arrow + " "),
    ]

    /// SQL's types (Postgres's) as offered, the common first: each in one word (T2 panel 2's `int, int8, integer, interval, inet`),
    /// never a spelling of several words beside its short name (`timestamptz`, not `timestamp with time zone` too).
    static let offeredTypes = sqlTypes.filter { !$0.contains(" ") }

    /// Every spelling of SQL's types the offers know (Postgres's), several words among them: one of several words is offered only
    /// as it's typed into past its first word.
    static let sqlTypes = [
        "uuid", "text", "int", "int8", "integer", "interval", "inet", "bigint", "smallint", "serial", "bigserial", "numeric", "decimal",
        "real", "float8", "bool", "boolean", "date", "time", "timetz", "timestamp", "timestamptz", "json", "jsonb", "bytea", "varchar", "char",
        "citext", "money", "cidr", "double precision", "character varying", "timestamp with time zone", "timestamp without time zone",
        "time with time zone", "time without time zone",
    ]
}
