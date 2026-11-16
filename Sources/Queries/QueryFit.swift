import Canvas
import CanvasRPC
import CoreGraphics
import Foundation
import QueryLanguage

// Writes that make a shape match: what a query says a shape *is*, written onto a record, so a shape made inside a place
// that accepts `:is-a("Task")` comes out one. The query is read as the language reads it (a `SelectorList`, never a plan:
// a plan is where the engine's own meaning of a word lives, and what is written is the shape the query describes, said
// compound by compound), synchronously on the main actor, and never awaits an evaluation: it asks nothing of the file but
// what a word's owner reads in its writer.
//
// What it writes is only what it can be sure of. Only the subject compound, the last of a complex selector, says what the
// shape is (the compounds before it say where it sits). Its head must be the record's kind (or, when the kind is open, the
// record becomes one of that kind), a title or an id names one shape and is never written. `[a=v]` sets a property, `[a]` on
// a true|false sets true, `[a.b.c=v]` sets a member inside an object or any-JSON property (making the objects on the way),
// `:is` and `:where` write the first of their alternatives that writes something, a plugin's word its owner's writer
// (`makes:`). Everything else (`:not`, `:has`, `:inside`, `:top-level`, `:current-board`, `:contains`, the edge words,
// `:dangling`, `!=`, `^=`, `$=`, `*=`, `~=`, `|=` and orderings) is skipped: nothing can be sure of it.

/// One alternative of what a relation's word names, as written (`:is-a("Task", #id)` has two): its canonical text, and the one
/// shape it names when it names one alone, by title, by kind and title, or by id. What a relation's writer (`makes:`) is
/// handed, so it never reads a query itself.
public struct QueryAnchor: Sendable, Equatable {
    /// The alternative as the language prints it.
    public let text: String
    /// The title it names (escapes undone, as written: not folded), alone or after a kind; nil when it names none.
    public let title: String?
    /// The kind it says before a title (`note"Task"`); nil when it says none.
    public let kind: ShapeKind?
    /// The id it names (`#7C1E…`); nil when it names none.
    public let id: ShapeID?

    init(_ selector: ComplexSelector) {
        text = selector.canonical
        var title: String?, kind: ShapeKind?, id: ShapeID?
        if selector.compounds.count == 1, let compound = selector.compounds.first, compound.filters.isEmpty {
            switch compound.head {
            case .title(let written, _)?: title = written
            case .kindTitle(let name, _, let written, _)?:
                kind = ShapeKind(rawValue: name)
                title = written
            case .id(let uuid, _)?: id = ShapeID(uuid)
            case .kind?, .any?, nil: break
            }
        }
        self.title = title
        self.kind = kind
        self.id = id
    }
}

/// A query's writes onto a record (`QueryState.fit`).
@MainActor
struct QueryFit {
    let editor: CanvasEditor
    let vocabulary: QueryVocabulary

    private var registry: Registry { editor.registry }

    /// `record` written to match the first alternative of `text` that can be written, or nil when the text doesn't read, or
    /// writing it changes nothing.
    func fit(_ record: AnyShapeRecord, toMatch text: String, kindIsOpen: Bool) -> AnyShapeRecord? {
        guard !record.isOpaque, let list = try? SelectorList(parsing: text) else { return nil }
        guard let written = first(of: list.selectors, for: record, open: kindIsOpen), written != record else { return nil }
        return written
    }

    // MARK: Alternatives

    /// What the first alternative that can be written writes: nil when none can. One that is writable and writes nothing is
    /// the one used all the same.
    private func first(of selectors: [ComplexSelector], for record: AnyShapeRecord, open: Bool) -> AnyShapeRecord? {
        for selector in selectors {
            if let written = subject(of: selector, for: record, open: open) { return written }
        }
        return nil
    }

    /// The subject compound written onto the record; the compounds before it say where the shape sits, and are skipped.
    private func subject(of selector: ComplexSelector, for record: AnyShapeRecord, open: Bool) -> AnyShapeRecord? {
        guard let compound = selector.compounds.last else { return nil }
        var record = record
        switch compound.head {
        case .kind(let name, _)?:
            let kind = ShapeKind(rawValue: name)
            if kind != record.kind {
                guard open, let turned = turned(record, into: kind) else { return nil }
                record = turned
            }
        case .any?, nil:
            break
        case .title?, .kindTitle?, .id?:
            return nil
        }
        // Words first, then the attributes: a word may give the shape a type, which its members are written by.
        for case .pseudo(let pseudo) in compound.filters { record = writing(pseudo, on: record, open: open) ?? record }
        for case .attribute(let test) in compound.filters { record = writing(test, on: record) ?? record }
        return record
    }

    // MARK: Words

    /// The record written to match the word, or nil when the word writes nothing.
    private func writing(_ pseudo: PseudoClass, on record: AnyShapeRecord, open: Bool) -> AnyShapeRecord? {
        if let word = pseudo.word {
            switch (word, pseudo.argument) {
            case (.is, .selectors(let list)), (.where, .selectors(let list)):
                // The first alternative that writes something.
                for selector in list.selectors {
                    if let written = subject(of: selector, for: record, open: open), written != record { return written }
                }
                return nil
            default:
                return nil
            }
        }
        guard let declared = vocabulary.contributedWords[pseudo.name] else { return nil }
        switch declared.meaning {
        case .pseudoClass(let behavior):
            guard let makes = behavior.makes else { return nil }
            var text: String?
            if let argument = declared.argument {
                guard let read = try? pseudo.text(argument: argument, example: declared.example) else { return nil }
                text = read
            } else if case .raw = pseudo.argument {
                // A word that takes none, given one: the query's own refusal, nothing to write.
                return nil
            }
            return makes(text, record, editor)
        case .fileRelation(let relation):
            guard let makes = relation.makes, let list = try? SelectorList(argumentOf: pseudo) else { return nil }
            return makes(list.selectors.map(QueryAnchor.init), record, editor)
        case .relation:
            return nil
        }
    }

    // MARK: Attributes

    /// The record with the property the test names set to what it says, or nil when it says nothing that can be written.
    private func writing(_ test: AttributeTest, on record: AnyShapeRecord) -> AnyShapeRecord? {
        guard let entry = vocabulary.kind(record.kind), let attribute = entry.attribute(test.name),
              attribute.mediaType == nil, !(attribute.isName && entry.schema.properties[test.name] == nil) else { return nil }
        if test.path.isEmpty {
            guard let value = value(of: test, attribute: attribute, entry: entry) else { return nil }
            return write([test.name: value], to: record)
        }
        // A member inside an object or any-JSON property.
        switch attribute.shape {
        case .object, .json: break
        default: return nil
        }
        guard test.op == .equals, let literal = test.value, !literal.text.isEmpty else { return nil }
        let member: JSONValue
        if let checking = registry.contributions(to: QueryPathChecks.self).first(where: { $0.value.attribute == test.name })?.value {
            // The attribute's owner knows what its members are, and types them; without a writer it writes none.
            let said = QueryMemberLiteral(text: literal.text, isQuoted: literal.isQuoted, ignoresCase: test.flag == .insensitive)
            guard let typed = checking.makes?(test.path, said, record, editor), typed != .null else { return nil }
            member = typed
        } else if literal.isQuoted {
            member = .string(literal.text)
        } else if let number = PathTest.number(literal.text) {
            member = .number(number)
        } else if let flag = Bool(literal.text) {
            member = .bool(flag)
        } else {
            member = .string(literal.text)
        }
        var root: JSONObject
        switch record.propertiesJSON?[test.name] {
        case .object(let object)?: root = object
        case nil, .null?: root = [:]
        default: return nil
        }
        guard let updated = Self.put(member, at: test.path[...], in: root) else { return nil }
        root = updated
        return write([test.name: .object(root)], to: record)
    }

    /// `object` with `value` at `members`, the objects on the way made; nil where something that is no object is in the way.
    private static func put(_ value: JSONValue, at members: ArraySlice<String>, in object: JSONObject) -> JSONObject? {
        guard let key = members.first else { return nil }
        var object = object
        if members.count == 1 {
            object[key] = value
            return object
        }
        let inner: JSONObject
        switch object[key] {
        case .object(let existing)?: inner = existing
        case nil, .null?: inner = [:]
        default: return nil
        }
        guard let updated = put(value, at: members.dropFirst(), in: inner) else { return nil }
        object[key] = .object(updated)
        return object
    }

    /// What `[a=v]` says the property is, as the property's schema reads it; nil for a test that says nothing that can be
    /// written (any operator but `=`, an empty value, a list or an object, a value the schema doesn't take). `[a]` is true on a
    /// true|false.
    private func value(of test: AttributeTest, attribute: QueryVocabulary.AttributeEntry, entry: QueryVocabulary.KindEntry) -> JSONValue? {
        guard let op = test.op, let literal = test.value else {
            if case .boolean = attribute.shape { return .bool(true) }
            return nil
        }
        guard op == .equals, !literal.text.isEmpty else { return nil }
        let text = literal.text, name = test.name, ignoringCase = test.flag == .insensitive
        switch attribute.shape {
        case .string(let format, _, let choices):
            if format == KindSchema.dateTime {
                // A day is its UTC midnight; an instant is written in full (seconds and `Z`), as the stored form is.
                switch QueryDates.value(of: text) {
                case .day(let date)?, .instant(let date)?:
                    return .string(Self.instantText.string(from: date))
                default: return nil
                }
            }
            if let choices {
                let found = choices.first { ignoringCase ? $0.caseInsensitiveCompare(text) == .orderedSame : $0 == text }
                return found.map(JSONValue.string)
            }
            return .string(text)
        case .number:
            guard text != KindSchema.null else { return nil }
            return try? entry.schema.value(ofLiteral: text, quoted: false, for: name)
        case .boolean:
            return Bool(text).map(JSONValue.bool)
        case .json:
            let value: JSONValue = literal.isQuoted ? .string(text) : (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .string(text)
            return value == .null ? nil : value
        case .array, .object:
            return nil
        }
    }

    private static let instantText: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    /// The record with `properties` written onto it, if its kind takes them and its schema doesn't find anything wrong that it
    /// didn't before.
    private func write(_ properties: JSONObject, to record: AnyShapeRecord) -> AnyShapeRecord? {
        guard let written = try? registry.shape(record, setting: properties) else { return nil }
        let before = Set(registry.schemaViolations(of: record))
        guard registry.schemaViolations(of: written).allSatisfy(before.contains) else { return nil }
        return written
    }

    // MARK: Kinds

    /// The record as a shape of `kind`, made by the kind's placement at the record's frame, with
    /// its id, container and metadata, and the values of the properties plugins add that both kinds hold; nil for a kind with
    /// no placement, or a record with no box.
    private func turned(_ record: AnyShapeRecord, into kind: ShapeKind) -> AnyShapeRecord? {
        guard let box = record.box, vocabulary.kind(kind) != nil, let placement = registry.placement(for: kind) else { return nil }
        var made = placement.sized(box.size).shape(at: CGPoint(x: box.midX, y: box.midY)).copy(as: record.id, container: record.container)
        made.meta = record.meta
        let held = Set(registry.properties(for: kind))
        var carried: JSONObject = [:]
        for key in registry.properties(for: record.kind) where held.contains(key) {
            if let value = record.addedJSON(for: key) { carried[key.rawValue] = value }
        }
        guard !carried.isEmpty else { return made }
        return (try? registry.shape(made, setting: carried)) ?? made
    }
}

private extension Literal {
    var isQuoted: Bool {
        if case .quoted = self { true } else { false }
    }
}
