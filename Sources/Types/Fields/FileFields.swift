import Canvas
import CanvasRPC
import Foundation

/// What the file's types say of the members a note's values can hold, by key at each depth: the union over
/// every type of its own fields, a group's members, another type's fields' and a list's items'. What a query
/// asks to say a path into `fieldValues` names a field no type has (`unknown`). Made when asked and kept until
/// a type's schema, name or place in the chain changes (`FieldBook.fileFields`); it holds no shape and reads no value.
/// And what `--ask` is told of them (`text(for:)`): a line for each titled type, its own fields, key first, and for a
/// relationship type the types it relates, and the names typed on its ends and their flags.
@MainActor
public final class FileFields {
    /// What a step can lead to: nothing more (a plain value), anything (pairs, `Other`, a type
    /// that is gone or a part of one, beyond the depth read), or members by key.
    private indirect enum Keys {
        case leaf
        case any
        case members([String: Keys])

        func merged(with other: Keys) -> Keys {
            switch (self, other) {
            case (.any, _), (_, .any): return .any
            case (.leaf, let other): return other
            case (let this, .leaf): return this
            case (.members(var mine), .members(let theirs)):
                for (key, keys) in theirs { mine[key] = mine[key].map { $0.merged(with: keys) } ?? keys }
                return .members(mine)
            }
        }
    }

    /// How deep a type's groups are read: past it, anything goes (a group that holds a group of itself).
    private static let depth = 6

    private weak var editor: CanvasEditor?
    private weak var book: FieldBook?
    private let root: Keys
    private let types: [ShapeID]
    /// A line for each titled type, once made.
    private lazy var lines: [TypeLine] = makeLines()

    init(book: FieldBook, types: [ShapeID], editor: CanvasEditor) {
        self.editor = editor
        self.book = book
        self.types = types
        var keys: [String: Keys] = [:]
        for type in types {
            for field in book.fields(types: [type]).fields where field.source == type {
                let found = Self.keys(of: field, book: book, depth: 0)
                keys[field.field.name] = keys[field.field.name].map { $0.merged(with: found) } ?? found
            }
        }
        root = .members(keys)
    }

    private static func keys(of field: Resolved.Field, book: FieldBook, depth: Int) -> Keys {
        guard depth < Self.depth else { return .any }
        switch book.kind(of: field) {
        case .group, .typeFields:
            // A reference to a type that is gone, or to a part of one, has no members to name.
            if let ref = field.field.schema["$ref"]?.string,
               SchemaReferences.target(of: ref).map({ $0.fragment.isEmpty && !book.fields(types: [$0.shape]).order.isEmpty }) != true {
                return .any
            }
            return members(of: field, book: book, depth: depth)
        case .listOfGroups, .listOfTypeFields:
            guard let item = book.item(of: field) else { return .any }
            return keys(of: item, book: book, depth: depth)
        case .plain, .choices, .list:
            return .leaf
        case .pairs, .either, .other:
            return .any
        }
    }

    private static func members(of field: Resolved.Field, book: FieldBook, depth: Int) -> Keys {
        var keys: [String: Keys] = [:]
        for member in book.members(of: field) {
            let found = Self.keys(of: member, book: book, depth: depth + 1)
            keys[member.field.name] = keys[member.field.name].map { $0.merged(with: found) } ?? found
        }
        return .members(keys)
    }

    /// The first of `members`, the path a query tests inside `fieldValues`, that no shape of the file can hold:
    /// its place in the path and the members that could be there. Nil for nothing to say: the path is held (or
    /// leads where nothing is known: pairs, `Other`, a type that is gone), and whenever any shape lists a type
    /// that is gone, whose fields are unknown and whose values are kept: no key can be called no type's then.
    public func unknown(_ members: [String]) -> (index: Int, known: [String])? {
        guard editor?.types?.listsAGoneType != true else { return nil }
        var here = root
        for (index, member) in members.enumerated() {
            switch here {
            case .any: return nil
            case .leaf: return (index, [])
            case .members(let keys):
                guard let next = keys[member] else { return (index, keys.keys.sorted()) }
                here = next
            }
        }
        return nil
    }
}


// MARK: What `--ask` is told

/// The most fields a type's line lists, and members of a group or list; past them `+N more`.
private let fieldsPerType = 60
private let membersPerField = 12
/// The most choices written out, past them `|+N`.
private let choicesWritten = 8
/// The most the whole block holds, in characters.
private let blockLimit = 8_000

/// One titled type's line, made once.
private struct TypeLine {
    let id: ShapeID
    let title: String
    let line: String
    /// Its characters, once counted.
    let size: Int
    /// The words of its title, its fields' keys and the names a person sees, lower case.
    let words: Set<String>
}

extension FileFields {
    /// What a translator of English into queries is told of the file's types: a line for each titled type (its
    /// title, `builds on` and its parents' titles when it builds on any, then its own fields, each key first, then
    /// in quotes the name a person sees when the field's own `title` says another than the key's words, then its
    /// kind in parentheses), the types that share a word with `question` first, then by how many notes are one, however
    /// far (`allInstances`), then by title. A relationship type's line says `relates A to B` after its name (`anything` for a side with no end) and
    /// ends with `; rows:` and the rows its ends name or flag; an untitled one is told by `#` and its id. At most 8,000
    /// characters: past them the last types are named on a last line, as many as fit. Empty when no type is titled.
    /// Never a note's text or values.
    public func text(for question: String) -> String {
        let typeLines = lines
        guard !typeLines.isEmpty else { return "" }
        let asked = Self.words(in: question)
        let instances = editor?.types.map { index in typeLines.map { index.allInstances(of: $0.id).count } } ?? typeLines.map { _ in 0 }
        let named = typeLines.map { line in asked.contains { line.words.contains($0) } }
        typealias Rank = (named: Bool, instances: Int, title: String, place: Int)
        let ranks: [Rank] = typeLines.indices.map { (named[$0], instances[$0], typeLines[$0].title, $0) }
        let ranked = ranks.sorted { a, b in
            if a.named != b.named { return a.named }
            if a.instances != b.instances { return a.instances > b.instances }
            if a.title != b.title { return a.title < b.title }
            return a.place < b.place
        }.map { typeLines[$0.place] }
        // Whole types from the front while they fit with the last line that names the rest.
        var kept: [String] = [], size = 0, taken = 0
        for line in ranked {
            let more = ranked.count - taken - 1
            // Room for the last line that names the rest, at its shortest.
            let reserve = more > 0 ? Self.omission(of: [], count: more).count + 1 : 0
            guard size + line.size + 1 + reserve <= blockLimit else { break }
            kept.append(line.line)
            size += line.size + 1
            taken += 1
        }
        if taken < ranked.count {
            kept.append(Self.omission(of: ranked[taken...].map(\.title), count: ranked.count - taken, room: blockLimit - size))
        }
        return kept.joined(separator: "\n")
    }

    /// `and 3 more types: A, B, C`, the names as many as `room` holds, then `…`.
    private static func omission(of names: [String], count: Int, room: Int = .max) -> String {
        let lead = "and \(count) more \(count == 1 ? "type" : "types"): "
        guard !names.isEmpty else { return lead + "…" }
        var line = lead
        for (place, name) in names.enumerated() {
            let next = line + (place == 0 ? "" : ", ") + name
            guard next.count + (place == names.count - 1 ? 0 : 2) <= room else { return line + (place == 0 ? "" : ", ") + "…" }
            line = next
        }
        return line
    }

    private func makeLines() -> [TypeLine] {
        guard let book, let index = editor?.types else { return [] }
        let relationships = editor?.relationships?.graph
        var made: [TypeLine] = []
        for type in types {
            let relates = relationships.map { $0.isRelationshipType(type) } ?? false
            // An untitled type is told only when it is a relationship type, by its id: an id is something an agent may be given.
            let named = index.name(of: type).flatMap { $0.isEmpty ? nil : $0 }
            guard let title = named ?? (relates ? "#" + type.rawValue.uuidString : nil) else { continue }
            let own = book.fields(types: [type]).fields.filter { $0.source == type }
            let parents = index.links(of: type).compactMap { link in index.isType(link.shape) ? index.name(of: link.shape) : nil }.filter { !$0.isEmpty }
            var line = title + (parents.isEmpty ? "" : " builds on " + parents.joined(separator: ", "))
            var words = Self.words(in: title)
            var rows = ""
            if relates, let relationships {
                let sides = relationships.sides(of: type)
                func titled(_ side: RelationshipSide) -> String {
                    let names = sides.types(on: side).map { index.name(of: $0).flatMap { $0.isEmpty ? nil : $0 } ?? "an untitled type" }
                    return names.isEmpty ? "anything" : names.joined(separator: " or ")
                }
                line += " relates \(titled(.from)) to \(titled(.to))"
                // What is told of the ends: the end types' titles are words of the line, and so are the names typed on the ends.
                for end in sides.from + sides.to {
                    if let name = index.name(of: end.type) { words.formUnion(Self.words(in: name)) }
                    if let name = end.name { words.formUnion(Self.words(in: name)) }
                }
                // Its rows are its own ends': one with none takes the other's ends and gives no rows of its own.
                rows = Self.rows(of: type, sides: relationships.ownSides(of: type), index: index)
            }
            line += ": "
            if own.isEmpty {
                line += "no fields"
            } else {
                var written = own.prefix(fieldsPerType).map { Self.written($0, book: book, depth: 0) }
                if own.count > fieldsPerType { written.append("+\(own.count - fieldsPerType) more") }
                line += written.joined(separator: ", ")
                for field in own {
                    words.formUnion(Self.words(in: field.field.name))
                    words.formUnion(Self.words(in: FieldName.words(of: field.field)))
                }
            }
            line += rows
            made.append(TypeLine(id: type, title: title, line: line, size: line.count, words: words))
        }
        return made
    }

    /// `; rows: Person "jobs" (only one), Company "staff" (needed)`: for each row an end gives that has a name typed on
    /// its arrow or a flag (Needed, Only one), the end type, the name in quotes and the flags in parentheses. A name
    /// derived from a type's title is not told. Nothing when no row has either.
    private static func rows(of type: ShapeID, sides: RelationshipSides, index: TypeIndex) -> String {
        var clauses: [String] = []
        for rows in RelationshipEnds.rows(of: type, sides: sides).sorted(by: { first, second in
            let order = (sides.from + sides.to).map(\.type)
            return (order.firstIndex(of: first.key) ?? 0) < (order.firstIndex(of: second.key) ?? 0)
        }) {
            let end = index.name(of: rows.key).flatMap { $0.isEmpty ? nil : $0 } ?? "an untitled type"
            for row in rows.value {
                var typed: String?
                if case .typed(let name) = row.key.label { typed = name }
                var flags: [String] = []
                if row.rule.needed { flags.append("needed") }
                if row.rule.onlyOne { flags.append("only one") }
                guard typed != nil || !flags.isEmpty else { continue }
                clauses.append(end + (typed.map { " \"\($0)\"" } ?? "") + (flags.isEmpty ? "" : " (\(flags.joined(separator: ", ")))"))
            }
        }
        return clauses.isEmpty ? "" : "; rows: " + clauses.joined(separator: ", ")
    }

    /// A field as the block writes it: its key, the name a person sees in quotes when it is another than the key's
    /// words, its kind in parentheses, and, for a list or group, its members in braces (one level).
    private static func written(_ field: Resolved.Field, book: FieldBook, depth: Int) -> String {
        var text = field.field.name
        let shown = FieldName.words(of: field.field)
        if shown != FieldName.words(of: ChainField(name: field.field.name, schema: SchemaValue(JSONValue.object([:])))) { text += " \"\(shown)\"" }
        let kind = book.kind(of: field)
        text += " (\(word(of: kind, book: book)))"
        switch kind {
        case .group, .listOfGroups:
            guard depth == 0 else { return text + " {…}" }
            let source = kind == .group ? field : book.item(of: field)
            let members = source.map { book.members(of: $0) } ?? []
            var inside = members.prefix(membersPerField).map { written($0, book: book, depth: depth + 1) }
            if members.count > membersPerField { inside.append("+\(members.count - membersPerField) more") }
            return inside.isEmpty ? text : text + " {" + inside.joined(separator: ", ") + "}"
        default:
            return text
        }
    }

    /// A kind's words: `text`, `whole number`, `draft|paid`, `list of text`, `fields of Address`.
    private static func word(of kind: FieldKind, book: FieldBook) -> String {
        func type(_ id: ShapeID) -> String { book.name(of: id).flatMap { $0.isEmpty ? nil : $0 } ?? (book.schemaText(of: id) == nil ? "a gone type" : "an untitled type") }
        switch kind {
        case .plain(let plain): return word(of: plain)
        case .choices(let options): return "any of " + choices(options)
        case .list(let plain): return "list of " + word(of: plain)
        case .listOfGroups: return "list"
        case .listOfTypeFields(let id): return "list of fields of " + type(id)
        case .group: return "group"
        case .typeFields(let id): return "fields of " + type(id)
        case .pairs(let value): return "pairs of " + word(of: value)
        case .either(let first, let second): return word(of: first, book: book) + " or " + word(of: second, book: book)
        case .other: return "other"
        }
    }

    private static func word(of plain: PlainKind) -> String {
        switch plain {
        case .text: "text"
        case .date: "date"
        case .dateTime: "date-time"
        case .yesNo: "yes/no"
        case .number(let integer): integer ? "whole number" : "number"
        case .choice(let options): choices(options)
        }
    }

    /// The stored values, `a|b|c`; eight, then `|+N`.
    private static func choices(_ options: [FieldOption]) -> String {
        var shown = options.prefix(choicesWritten).map(\.label)
        if options.count > choicesWritten { shown.append("+\(options.count - choicesWritten)") }
        return shown.joined(separator: "|")
    }

    /// The lower-case words of `text`, and each without a trailing `s`.
    fileprivate static func words(in text: String) -> Set<String> {
        var found: Set<String> = []
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) where word.count > 1 {
            found.insert(String(word))
            if word.hasSuffix("s"), word.count > 3 { found.insert(String(word.dropLast())) }
        }
        return found
    }
}

extension FieldBook {
    /// The file's types' members, made again when a type comes, goes or changes its schema, name or own types, or a
    /// relationship type's ends change (the index's revision).
    public var fileFields: FileFields? {
        guard let editor = editorForFileFields, let index = editor.types else { return nil }
        // The types' own fields and names move the stamp; the relationship types' ends, their typed names and flags, the
        // relationship index's revision.
        let revision = editor.relationships?.revision ?? 0
        if let kept = fileFieldsKept, kept.stamp == index.stamp, kept.revision == revision { return kept.fields }
        let fields = FileFields(book: self, types: Array(index.types), editor: editor)
        fileFieldsKept = (index.stamp, revision, fields)
        return fields
    }
}

extension CanvasEditor {
    /// What the file's types say of the members a note's values hold (`FileFields`); nil without TypesPlugin.
    public var fileFields: FileFields? { fieldBook?.fileFields }
}
