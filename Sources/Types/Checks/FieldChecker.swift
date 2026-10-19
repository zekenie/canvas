import Canvas
import CanvasRPC
import Foundation

// What a list of types checks a value against: compiled once and kept (`FieldChecks` keeps one for
// each distinct list), pure over the field book it was built over, no editor. It runs the
// core's validator over the list's composed schema (made checkable, `FieldSchemas`) and each type's
// rules, and says each violation as a problem of a class: a needed field with no value, or a wrong
// value, at a path a row names.

/// A type as the resolver reads it: what a `$ref` to it is checked against.
struct ResourceInput: Equatable {
    var resolved: Resolved
    /// The type's own root `$defs` and `definitions`, which a reference with a fragment leads into.
    var defs: JSONObject
}

/// Every string the check adds to the validator's own: a needed field, a rule across fields, a name a
/// pairs field refuses, a type that refers to a gone one, a `$title` that titles nothing.
@MainActor
enum FieldCheckWords {
    static let separator = " › "

    /// `customer is needed`.
    static func needed(_ place: [String]) -> String { place.joined(separator: separator) + " is needed" }

    /// `Order rule: the note fits a form it shouldn’t`; `A type rule: …` when the rule's type has no name.
    static func rule(_ type: String?, _ detail: String) -> String { "\(type ?? "A type") rule: the note \(detail)" }

    /// `labels › Size 2 isn’t a name labels allows`.
    static func nameNotAllowed(_ place: [String], row: String) -> String {
        place.joined(separator: separator) + " isn’t a name \(row) allows"
    }

    /// A type whose JSON refers to a type that is gone.
    static func refersToGone(_ name: TypeLinkName) -> String {
        switch name {
        case .live(let title), .missing(let title): title.map { "Refers to “\($0)”, which is gone." } ?? "Refers to a type that is gone."
        }
    }

    /// A type's `$title` that titles nothing, in the voice of the schema warnings (`SchemaReadings`).
    static func title(_ problem: TitleSourceProblem) -> String {
        switch problem {
        case .namesNothing: "“$title” names no field."
        case .noField(let key): "“$title” names “\(key)”, which isn’t a field."
        case .cannotTitle(let key): "“$title” names “\(key)”, which isn’t text, a number, a date or a choice."
        }
    }

    /// A validator's detail without its closing full stop: it ends a problem's line.
    static func trimmed(_ detail: String) -> String { detail.hasSuffix(".") ? String(detail.dropLast()) : detail }
}

/// What a list of types checks a value against, public for what asks it without an editor's service: a check
/// over the file's types.
@MainActor
public final class FieldChecker {
    let types: [ShapeID]
    let resolved: Resolved
    /// The field book's `revision` it was last found current at.
    var stamp: Int

    let book: FieldBook
    private let main: SchemaValidator
    private let rules: [(source: ShapeID, validator: SchemaValidator)]
    /// What the resolver was given, for each type it was asked for (nil: the type was gone).
    private let inputs: [ShapeID: ResourceInput?]
    private let rowIndex: [String: Int]
    /// The check of no values: every untouched note of the list shares it. Kept with the rename count it was made at.
    private var emptyKept: (names: Int, check: FieldCheck)?
    /// Most problems one answer keeps, however many a note has; the cap keeps one of each class.
    static let capacity = 100

    /// Nil when no type of the list is a type.
    public init?(types: [ShapeID], book: FieldBook) {
        let resolved = book.fields(types: types)
        guard !resolved.order.isEmpty else { return nil }
        self.types = types
        self.resolved = resolved
        self.book = book
        stamp = book.revision
        rowIndex = Dictionary(resolved.fields.enumerated().map { ($1.field.name, $0) }, uniquingKeysWith: { first, _ in first })
        let resources = Resources(book: book)
        func validator(_ schema: JSONObject) -> SchemaValidator {
            SchemaValidator(JSONSchema(FieldChecker.object(FieldSchemas.checkable(.object(schema)))), formats: .standard) { resources.schema(for: $0) }
        }
        var base = resolved.schema
        base["allOf"] = nil
        main = validator(base)
        rules = resolved.rules.map { rule in
            (rule.source, validator(SchemaValue.object(rule.members).json.objectValue ?? [:]))
        }
        inputs = resources.met
    }

    /// The types a `$ref` of the list's schemas met when it was made, gone or not: what else the checker is a function of.
    var referencedTypes: [ShapeID] { Array(inputs.keys) }

    /// The check of no values, shared by every untouched note of the list. A rule across fields that fails on an
    /// empty note says its type's name, and a rename leaves this checker current: that answer is made again
    /// when `names` (the count of renames) has moved, and one that names nothing is kept.
    func emptyCheck(names: Int) -> FieldCheck {
        if let emptyKept, emptyKept.names == names || !emptyKept.check.problems.contains(where: { $0.path.isRoot }) { return emptyKept.check }
        let made = check(FieldValues())
        emptyKept = (names, made)
        return made
    }

    private static func object(_ value: JSONValue) -> JSONObject { value.objectValue ?? [:] }

    /// Whether the resolution and everything the resolver gave are what they were: then so are the validators and
    /// every answer this made.
    func isCurrent() -> Bool {
        guard book.fields(types: types) == resolved else { return false }
        let resources = Resources(book: book)
        for (type, input) in inputs where resources.input(for: type) != input { return false }
        return true
    }

    // MARK: Serving other types

    /// The resolver: a `$ref` to `urn:uuid:T` is served the checkable schema of T's fields, with its own
    /// `$defs` laid in; nil, and remembered as gone, for a type that is not one.
    @MainActor private final class Resources {
        let book: FieldBook
        private(set) var met: [ShapeID: ResourceInput?] = [:]
        private var schemas: [ShapeID: JSONSchema] = [:]

        init(book: FieldBook) {
            self.book = book
        }

        func schema(for uri: String) -> JSONSchema? {
            guard let target = SchemaReferences.target(of: uri), target.fragment.isEmpty else { return nil }
            if let kept = schemas[target.shape] { return kept }
            guard let input = input(for: target.shape) else {
                met[target.shape] = .some(nil)
                return nil
            }
            met[target.shape] = input
            var schema = input.resolved.schema
            for (key, defs) in input.defs { schema[key] = defs }
            let served = JSONSchema(FieldChecker.object(FieldSchemas.checkable(.object(schema))))
            schemas[target.shape] = served
            return served
        }

        func input(for type: ShapeID) -> ResourceInput? {
            let resolved = book.fields(types: [type])
            guard !resolved.order.isEmpty else { return nil }
            var defs: JSONObject = [:]
            if let text = book.schemaText(of: type), let root = SchemaReadings.reading(of: text, for: type).shownRoot {
                let json = SchemaValue(root).json
                for key in SchemaPositions.definitions { defs[key] = json[key] }
            }
            return ResourceInput(resolved: resolved, defs: defs)
        }
    }

    // MARK: Checking

    public func check(_ values: FieldValues) -> FieldCheck {
        let value = JSONValue.object(values.values)
        var found = main.violations(of: value).map { (violation: $0, source: ShapeID?.none) }
        for rule in rules { found += rule.validator.violations(of: value).map { (violation: $0, source: rule.source) } }
        guard !found.isEmpty else { return .clean }
        var problems: [FieldProblem] = []
        for (violation, source) in found {
            if let problem = classify(violation, source: source, values: values) { problems.append(problem) }
        }
        return FieldCheck(problems: sorted(capped(deduped(problems))))
    }

    /// What one violation is, if it is anything a note can show.
    private func classify(_ violation: SchemaViolation, source: ShapeID?, values: FieldValues) -> FieldProblem? {
        let path = FieldPath(violation: violation.path)
        switch violation.keyword {
        case "required", "dependentRequired":
            // A field the rows name, and not a yes or no (an unticked box is a value).
            guard let field = book.field(at: path, types: types) else { return nil }
            if case .plain(.yesNo) = book.kind(of: field) { return nil }
            let place = place(of: path, values: values)
            return FieldProblem(path: path, kind: .needed, keyword: violation.keyword, place: place, message: FieldCheckWords.needed(place))
        case "$ref", "patternProperties", "additionalProperties":
            // A type that is gone or a loop is not checked, and a value no field names is never wrong.
            return nil
        default:
            break
        }
        if path.isRoot {
            let message = FieldCheckWords.rule(source.flatMap { book.name(of: $0) }, FieldCheckWords.trimmed(violation.detail))
            return FieldProblem(path: path, kind: .wrong, keyword: "rule", place: [], message: message)
        }
        // A place no row has (under an `Other`, a pair of an unreadable branch) is the deepest row above it;
        // a value no field names at all is never wrong.
        var at = path
        while !at.isRoot, book.field(at: at, types: types) == nil { at = at.parent ?? FieldPath() }
        guard !at.isRoot else { return nil }
        let place = place(of: at, values: values)
        let message: String
        if violation.keyword == "propertyNames", at == path, let row = path.parent.flatMap({ book.field(at: $0, types: types) }) {
            message = FieldCheckWords.nameNotAllowed(place, row: FieldName.words(of: row.field))
        } else {
            message = place.joined(separator: FieldCheckWords.separator) + " " + FieldCheckWords.trimmed(violation.detail)
        }
        return FieldProblem(path: at, kind: .wrong, keyword: violation.keyword, place: place, message: message)
    }

    // MARK: Words

    /// The rows' names from the note down. A pairs field's key is the key, an item is labelled by its
    /// first plain value.
    private func place(of path: FieldPath, values: FieldValues) -> [String] {
        var words: [String] = [], prefix = FieldPath(), parent: Resolved.Field?
        for step in path.steps {
            prefix = FieldPath(prefix.steps + [step])
            let field = book.field(at: prefix, types: types)
            switch step {
            case .key(let key):
                if let parent, case .pairs = book.kind(of: parent) {
                    words.append(key)
                } else {
                    words.append(field.map { FieldName.words(of: $0.field) } ?? key)
                }
            case .index(let number):
                words.append(label(ofItem: number, at: prefix, field: field, values: values))
            }
            parent = field
        }
        return words
    }

    private static let labelLength = 24

    private func label(ofItem number: Int, at path: FieldPath, field: Resolved.Field?, values: FieldValues) -> String {
        if let field, case .object(let item)? = values.value(at: path) {
            for member in book.members(of: field) {
                guard case .plain(let kind) = book.kind(of: member), let value = item[member.field.name] else { continue }
                let text = FieldText.shown(value, as: kind).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return String(text.prefix(Self.labelLength)) }
            }
        }
        return "item \(number + 1)"
    }

    // MARK: The answer

    /// A field asked for by the root and by a rule is one problem; two wrongs at one path are two.
    private func deduped(_ problems: [FieldProblem]) -> [FieldProblem] {
        var neededPlaces: Set<FieldLocus> = [], seen: Set<FieldProblem> = []
        return problems.filter { problem in
            switch problem.kind {
            case .needed: neededPlaces.insert(problem.locus).inserted
            case .wrong, .warning: seen.insert(problem).inserted
            }
        }
    }

    /// At most `capacity`, wrong first, then needed, then warnings, and at least one of each class where
    /// several are there: the cap never changes what the ring, `:incomplete` or a warning reads.
    private func capped(_ problems: [FieldProblem]) -> [FieldProblem] {
        guard problems.count > Self.capacity else { return problems }
        var classes: [[FieldProblem]] = [.wrong, .needed, .warning].map { kind in problems.filter { $0.kind == kind } }
        classes.removeAll { $0.isEmpty }
        // One of each first, then the rest by class: wrong, needed, warning.
        var room = Self.capacity - classes.count
        return classes.flatMap { found -> [FieldProblem] in
            let extra = min(room, found.count - 1)
            room -= extra
            return Array(found.prefix(1 + extra))
        }
    }

    /// By the row's place in the note, then the path step by step (a key by its text, an index by its
    /// number, so item 2 comes before item 10); the root last. What is equal keeps the validator's order.
    private func sorted(_ problems: [FieldProblem]) -> [FieldProblem] {
        problems.enumerated().sorted { a, b in
            let rows = (row(of: a.element), row(of: b.element))
            if rows.0 != rows.1 { return rows.0 < rows.1 }
            let order = Self.compare(a.element.path.steps, b.element.path.steps)
            return order == 0 ? a.offset < b.offset : order < 0
        }.map(\.element)
    }

    private func row(of problem: FieldProblem) -> Int {
        problem.path.field.flatMap { rowIndex[$0] } ?? Int.max
    }

    private static func compare(_ a: [FieldPath.Step], _ b: [FieldPath.Step]) -> Int {
        for (x, y) in zip(a, b) {
            switch (x, y) {
            case (.key(let p), .key(let q)): if p != q { return p < q ? -1 : 1 }
            case (.index(let p), .index(let q)): if p != q { return p < q ? -1 : 1 }
            case (.key, .index): return -1
            case (.index, .key): return 1
            }
        }
        return a.count == b.count ? 0 : (a.count < b.count ? -1 : 1)
    }
}
