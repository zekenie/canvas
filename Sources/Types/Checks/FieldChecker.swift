import Canvas
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

    /// What a pointer's type is called in a line: its name, else "its type".
    private static func typeName(_ type: TypeLinkName) -> String {
        switch type {
        case .live(let title), .missing(let title): title ?? "its type"
        }
    }

    /// `customer isn’t a link to a Person`; `… to a note of its type` for a type with no name.
    static func notALink(_ place: [String], to type: TypeLinkName) -> String {
        let name = typeName(type)
        return place.joined(separator: separator) + " isn’t a link to " + (name == "its type" ? "a note of its type" : "a \(name)")
    }

    /// `customer links to “Ann Lee”, which is gone`; `a note` for a link that holds no name.
    static func linkGone(_ place: [String], stored: String) -> String {
        place.joined(separator: separator) + " links to “\(stored.isEmpty ? "a note" : stored)”, which is gone"
    }

    /// `customer links to “Ann Lee”, which isn’t a Person`; `which isn’t of its type` for a type with no name.
    static func linkNotOne(_ place: [String], shown: String, type: TypeLinkName) -> String {
        let name = typeName(type)
        return place.joined(separator: separator) + " links to “\(shown)”, which isn’t " + (name == "its type" ? "of its type" : "a \(name)")
    }

    /// A validator's detail without its closing full stop: it ends a problem's line.
    static func trimmed(_ detail: String) -> String { detail.hasSuffix(".") ? String(detail.dropLast()) : detail }
}

/// Where a list's schema holds a pointer: the steps from the note's values to its value (a key for a field
/// or a member, any index for an item of a list), and the type it points at.
struct LinkSite: Hashable {
    enum Step: Hashable { case key(String), anyIndex }
    var steps: [Step]
    var type: ShapeID
}

/// What a pointer's target is, to the type it points at.
public enum LinkState: Sendable {
    /// A note whose chain reaches the type.
    case one
    /// A note that is not one: it lost the type, stopped building on it, or became a type.
    case notOne
    /// No shape of the file has the id.
    case gone
    /// A shape the check can't read (kept aside): neither warned nor wrong.
    case elsewhere
}

/// What a list of types checks a value against, public for what asks it without an editor's service: a check
/// over the file's types and a state for each pointer's target (`linkProblems`).
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
    /// Where the list's schema holds pointers, at any depth: empty for most lists, so a check of a note with
    /// no pointer costs nothing more.
    let linkSites: [LinkSite]
    /// The type of each pointer the list's schema holds, sites or not, and whether it was a type then: one that
    /// goes or comes back makes the checker stale, as its sites are no longer the ones it would read.
    private let linkTypes: [ShapeID: Bool]
    /// Whether the list's schema holds a pointer.
    public var holdsLinks: Bool { !linkSites.isEmpty }

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
        (linkSites, linkTypes) = Self.linkSites(of: resolved, book: book)
    }

    /// The types a `$ref` of the list's schemas met when it was made, and the types its pointers point at, gone or
    /// not: what else the checker is a function of.
    var referencedTypes: [ShapeID] { Array(inputs.keys) + linkTypes.keys.filter { inputs[$0] == nil } }

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

    // MARK: Pointers

    /// The deepest a pointer is looked for (a group in a group, another type's fields in another's).
    private static let linkDepth = 16

    /// The pointers of the list's fields: a top-level field, a member of a group or of another type's fields,
    /// an item of a list of groups or of pointers, at any depth, another type's fields followed once on any
    /// path. A pointer to a type that isn't one is left out: its values are kept and not checked. An
    /// `either`'s branches aren't followed: a pointer there is an `Other`. With the sites, every pointer's type
    /// and whether it was a type, left out or not.
    private static func linkSites(of resolved: Resolved, book: FieldBook) -> ([LinkSite], [ShapeID: Bool]) {
        var sites: [LinkSite] = []
        var types: [ShapeID: Bool] = [:]
        func site(_ steps: [LinkSite.Step], _ type: ShapeID) {
            let isType = types[type] ?? book.isType(type)
            types[type] = isType
            if isType { sites.append(LinkSite(steps: steps, type: type)) }
        }
        func collect(_ field: Resolved.Field, _ steps: [LinkSite.Step], _ depth: Int, _ following: Set<ShapeID>) {
            guard depth < linkDepth else { return }
            switch book.kind(of: field) {
            case .pointer(let type):
                site(steps, type)
            case .pointers(let type):
                site(steps + [.anyIndex], type)
            case .group:
                for member in book.members(of: field) { collect(member, steps + [.key(member.field.name)], depth + 1, following) }
            case .typeFields(let type):
                guard !following.contains(type) else { return }
                for member in book.members(of: field) { collect(member, steps + [.key(member.field.name)], depth + 1, following.union([type])) }
            case .listOfGroups:
                if let item = book.item(of: field) { collect(item, steps + [.anyIndex], depth + 1, following) }
            case .listOfTypeFields(let type):
                guard !following.contains(type), let item = book.item(of: field) else { return }
                collect(item, steps + [.anyIndex], depth + 1, following.union([type]))
            default:
                break
            }
        }
        for field in resolved.fields { collect(field, [.key(field.field.name)], 0, []) }
        return (sites, types)
    }

    /// What the pointers in `values` say: each site's values walked (an index for each item of a list), by
    /// `state` of each target (given the type it points at). A value that is not exactly one token is wrong, a
    /// token whose target is gone a warning, one that is no longer a note of the type wrong. Pure: the state is
    /// handed in, so a check over a reading says the same of a note the editor doesn't hold.
    public func linkProblems(in values: FieldValues, state: (_ target: ShapeID, _ type: ShapeID) -> LinkState) -> [FieldProblem] {
        guard !linkSites.isEmpty else { return [] }
        var problems: [FieldProblem] = []
        let root = JSONValue.object(values.values)
        for site in linkSites {
            // A type that has gone since the sites were read: its values are kept and not checked.
            guard book.isType(site.type) else { continue }
            let type = TypeLinkName.live(book.name(of: site.type))
            func visit(_ value: JSONValue, _ steps: ArraySlice<LinkSite.Step>, _ path: [FieldPath.Step]) {
                guard let step = steps.first else {
                    let path = FieldPath(path), place = place(of: path, values: values)
                    guard let link = FieldLink(value) else {
                        problems.append(FieldProblem(path: path, kind: .wrong, keyword: "link", place: place, message: FieldCheckWords.notALink(place, to: type)))
                        return
                    }
                    switch state(link.target, site.type) {
                    case .one, .elsewhere:
                        break
                    case .gone:
                        problems.append(FieldProblem(path: path, kind: .warning, keyword: "link", place: place, message: FieldCheckWords.linkGone(place, stored: link.stored)))
                    case .notOne:
                        problems.append(FieldProblem(path: path, kind: .wrong, keyword: "link", place: place,
                                                     message: FieldCheckWords.linkNotOne(place, shown: book.shown(link), type: type)))
                    }
                    return
                }
                switch (step, value) {
                case (.key(let key), .object(let members)):
                    if let member = members[key] { visit(member, steps.dropFirst(), path + [.key(key)]) }
                case (.anyIndex, .array(let items)):
                    for (number, item) in items.enumerated() { visit(item, steps.dropFirst(), path + [.index(number)]) }
                default:
                    break
                }
            }
            visit(root, site.steps[...], [])
        }
        return problems
    }

    /// The validator's answer and the pointers' together, as `check(_:)` would have made one: deduped, capped
    /// and sorted.
    func merged(_ base: FieldCheck, with links: [FieldProblem]) -> FieldCheck {
        guard !links.isEmpty else { return base }
        return FieldCheck(problems: sorted(capped(deduped(base.problems + links))))
    }

    /// Whether the resolution, everything the resolver gave and which pointers' types are types are what
    /// they were: then so are the validators, the sites, and every answer this made.
    func isCurrent() -> Bool {
        guard book.fields(types: types) == resolved else { return false }
        for (type, wasType) in linkTypes where book.isType(type) != wasType { return false }
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
        var neededPaths: Set<FieldPath> = [], seen: Set<FieldProblem> = []
        return problems.filter { problem in
            switch problem.kind {
            case .needed: neededPaths.insert(problem.path).inserted
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
