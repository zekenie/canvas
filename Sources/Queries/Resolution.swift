import Canvas
import CanvasRPC
import Foundation
import FuzzyMatching
import QueryLanguage
import Topology

// Resolution: a query read (`SelectorList`) checked against what the app has (`QueryVocabulary`)
// and bound into a plan. Kinds must be the registry's; an attribute its compound's kind's (or, with
// no kind, some kind's), and its literal and operator what the property's schema takes; edge types
// declared, or in the file; words the language's or a plugin's. A container (the left of a space or
// `>`, `:inside`'s argument, the shape `:has` is on) that can only be a kind whose shapes hold no
// shapes (neither a board of them nor shapes on theirs) is refused, since nothing is ever inside
// it. Titles and ids are left for the answer, which checks them against the file it takes up (but
// an id's kind is checked here, for a container, from the file as the app has it). Every problem
// that doesn't depend on another is found, up to `QueryLimits.errors`, in the order they are in the
// query, the first leading: a compound whose kind isn't one has its attributes left unchecked,
// since what they'd be checked against is unknown.

extension QueryPlan {
    /// Resolves a query read against a vocabulary. `presentEdgeTypes` are the edge types the file
    /// has (a newer app's type, kept as written, is one a query may name though nothing declares
    /// it); `kindOf` is the kind of a shape the app has now, by id (nil: none), for a container
    /// named by its id.
    public init(resolving list: SelectorList, text: String, vocabulary: QueryVocabulary,
                presentEdgeTypes: Set<EdgeTypeID> = [], kindOf: (ShapeID) -> ShapeKind? = { _ in nil }) throws(QueryError) {
        var resolver = Resolver(vocabulary: vocabulary, presentEdgeTypes: presentEdgeTypes)
        let root = resolver.list(list, container: false)
        for (id, span) in resolver.containerIDs {
            guard let kind = kindOf(id), !vocabulary.containerKinds.contains(kind), vocabulary.kind(kind) != nil else { continue }
            resolver.problem(QueryError(.cannotContain,
                                        "#\(id.rawValue.uuidString) is \(indefinite(kind.rawValue)), which holds no shapes: nothing is inside it. \(Resolver.notSpatial)",
                                        hint: vocabulary.containersListed, span: span))
        }
        if let problems = resolver.collected { throw problems }
        guard let root else { throw QueryError(.syntax, "The query can't be read.") }
        self.init(text: text, canonical: list.canonical, root: root, uses: resolver.uses, nodeCount: resolver.nextID,
                  containerTitles: resolver.containerTitles)
    }
}

/// What resolving a compound knows of its shapes' kinds: its head's, none said (any kind), or its
/// head's isn't a kind (what depends on it isn't checked).
private enum CompoundKinds {
    case known(ShapeKind)
    case any
    case unknown
}

/// Walks a query's tree in the order it's written, building its plan and collecting its problems.
private struct Resolver {
    let vocabulary: QueryVocabulary
    let presentEdgeTypes: Set<EdgeTypeID>
    var problems: [QueryError] = []
    var uses = PlanUses()
    var nextID = 0
    /// Ids named where a container goes, checked once the walk is done.
    var containerIDs: [(ShapeID, QuerySpan)] = []
    /// Title heads where a container goes, by node.
    var containerTitles: Set<PlanNodeID> = []

    init(vocabulary: QueryVocabulary, presentEdgeTypes: Set<EdgeTypeID>) {
        self.vocabulary = vocabulary
        self.presentEdgeTypes = presentEdgeTypes
    }

    static let notSpatial = notDrawnWithin

    mutating func problem(_ error: QueryError) {
        problems.append(error)
    }

    /// Every problem as one error, in the order they're in the query, each once; nil for none.
    var collected: QueryError? {
        guard !problems.isEmpty else { return nil }
        var seen: [QueryError] = []
        for problem in problems where !seen.contains(problem) { seen.append(problem) }
        let ordered = seen.enumerated().sorted { a, b in
            (a.element.span?.offset ?? Int.max, a.offset) < (b.element.span?.offset ?? Int.max, b.offset)
        }.map(\.element)
        return QueryError(collecting: ordered)
    }

    mutating func number() -> PlanNodeID {
        defer { nextID += 1 }
        return PlanNodeID(rawValue: nextID)
    }

    mutating func node(_ op: PlanOp, span: QuerySpan? = nil) -> PlanNode {
        PlanNode(id: number(), op: op, span: span)
    }

    mutating func planList(_ items: [PlanNode]) -> PlanList {
        PlanList(id: number(), items: items)
    }

    // MARK: Lists, complexes, compounds

    /// A selector list, OR; with `container`, what each item is must be able to hold shapes.
    mutating func list(_ list: SelectorList, container: Bool) -> PlanList? {
        var items: [PlanNode] = [], failed = false
        for selector in list.selectors {
            if let item = complex(selector, container: container) { items.append(item) } else { failed = true }
        }
        return failed ? nil : planList(items)
    }

    /// A complex selector: its subject, directly inside (or inside, at any depth) what the compound
    /// before it matches, and so on back.
    mutating func complex(_ selector: ComplexSelector, container: Bool) -> PlanNode? {
        var previous: PlanNode?, failed = false
        for (index, compound) in selector.compounds.enumerated() {
            var relation: PlanNode?
            if index > 0 {
                uses.containment = true
                if let previous {
                    let inner = planList([previous])
                    relation = node(selector.combinators[index - 1] == .child ? .parentIn(inner) : .ancestorIn(inner))
                }
            }
            let isSubject = index == selector.compounds.count - 1
            // `kind "Title"`, a space between: the shapes titled so inside the kind's. Where the kind
            // holds no shapes, what was meant is most likely the two together, one shape, if its
            // shapes can have titles at all.
            var together: String?
            if !isSubject, selector.combinators[index] == .descendant, case .kind(let kind, _)? = compound.head,
               case .title(let title, _)? = selector.compounds[index + 1].head, vocabulary.naming != nil,
               let entry = vocabulary.kind(ShapeKind(rawValue: kind)), entry.names != QueryNameSource.none {
                let next = selector.compounds[index + 1]
                together = Compound(head: .kindTitle(kind, compound.span, title: title, next.span), filters: compound.filters + next.filters,
                                    span: compound.span).canonical
            }
            let resolved = self.compound(compound, relation: relation, container: isSubject ? container : true, together: together)
            if resolved == nil { failed = true }
            previous = resolved
        }
        return failed ? nil : previous
    }

    /// A compound: its head and its filters, and `relation` (to the compound before it), all of
    /// them, cheapest first. `together`: the compound written with the one after a space, for a
    /// refusal of this one as a container.
    mutating func compound(_ compound: Compound, relation: PlanNode?, container: Bool, together: String? = nil) -> PlanNode? {
        let (heads, kinds) = self.head(compound.head)
        var failed = heads == nil
        // A container: on the left of a combinator, in :inside(), or what :has() is on.
        let holdsHas = compound.filters.contains { filter in
            if case .pseudo(let pseudo) = filter { pseudo.word == .has } else { false }
        }
        let isContainer = container || holdsHas
        if isContainer { checkContainer(compound, heads: heads ?? [], together: together) }
        var nodes: [PlanNode] = []
        for filter in compound.filters {
            let resolved: PlanNode? = switch filter {
            case .attribute(let test): attribute(test, in: compound, kinds: kinds)
            case .pseudo(let pseudo): self.pseudo(pseudo, in: compound, kinds: kinds, container: isContainer)
            }
            if let resolved { nodes.append(resolved) } else { failed = true }
        }
        if let relation { nodes.append(relation) }
        guard !failed, let heads else { return nil }
        // Every node matches only shapes the query ranges over, so "every shape" says nothing beside one.
        if !(heads.count == 1 && heads[0].isEveryShape) || nodes.isEmpty { nodes.insert(contentsOf: heads, at: 0) }
        let ordered = nodes.enumerated().sorted { a, b in (cost(a.element.op), a.offset) < (cost(b.element.op), b.offset) }.map(\.element)
        return ordered.count == 1 ? ordered[0] : node(.and(ordered), span: compound.span)
    }

    /// A compound's head, as nodes (a kind and a title are two): nil (and a problem) when it can't
    /// be resolved.
    mutating func head(_ head: Head?) -> ([PlanNode]?, CompoundKinds) {
        switch head {
        case nil, .any?:
            return ([node(.all)], .any)
        case .kind(let name, let span)?:
            let kind = ShapeKind(rawValue: name)
            guard vocabulary.kind(kind) != nil else {
                problem(unknownKind(name, span: span))
                return (nil, .unknown)
            }
            return ([node(.kinds([kind]), span: span)], .known(kind))
        case .title(let title, let span)?:
            return (titled(title, span: span).map { [$0] }, .any)
        case .kindTitle(let name, let kindSpan, let title, let titleSpan)?:
            // `kind[title="Title"]`, but a title head: one no shape has is refused, as `"Title"` is.
            let kind = ShapeKind(rawValue: name)
            guard let entry = vocabulary.kind(kind) else {
                problem(unknownKind(name, span: kindSpan, beforeTitle: true))
                return (nil, .unknown)
            }
            if vocabulary.naming != nil, entry.names == .none, let attribute = vocabulary.nameAttribute {
                let named = vocabulary.kinds.filter { $0.names != .none }.map(\.kind.rawValue)
                problem(QueryError(.unknownAttribute, "\(name) has no \(attribute)s.",
                                   hint: named.isEmpty ? nil : "The kinds whose shapes have \(attribute)s: \(named.joined(separator: ", ")).",
                                   span: titleSpan))
                return (nil, .known(kind))
            }
            guard let named = titled(title, span: titleSpan) else { return (nil, .known(kind)) }
            return ([node(.kinds([kind]), span: kindSpan), named], .known(kind))
        case .id(let id, let span)?:
            return ([node(.id(ShapeID(id)), span: span)], .any)
        }
    }

    /// A title head's node: nil (and a problem) when nothing names shapes.
    mutating func titled(_ title: String, span: QuerySpan) -> PlanNode? {
        guard let naming = vocabulary.naming else {
            problem(QueryError(.noNames, "Nothing in this app names shapes, so titles can't be used.",
                               hint: "Name shapes by their kind, or by id: # and the id a row gives.", span: span))
            return nil
        }
        uses.names = true
        return node(.title(folded: naming.fold(title) ?? title, written: title), span: span)
    }

    /// A compound that must be able to hold shapes (a container): refused when its head is a kind
    /// that holds no shapes (a kind with a title too); its id, if it's named by one, checked once the
    /// walk is done; its title, if one, left for the answer to check against the shapes it names
    /// (`containerTitles`). `together`: the compound written with the title after its space, the
    /// hint for a kind that holds no shapes.
    mutating func checkContainer(_ compound: Compound, heads: [PlanNode], together: String?) {
        switch compound.head {
        case .kind(let name, let span)?, .kindTitle(let name, let span, _, _)?:
            let kind = ShapeKind(rawValue: name)
            guard vocabulary.kind(kind) != nil, !vocabulary.containerKinds.contains(kind) else { return }
            problem(QueryError(.cannotContain, "\(indefinite(name).capitalizedFirst) holds no shapes: nothing is inside it. \(Self.notSpatial)",
                               hint: together.map { "Write them together for one shape: \($0)." } ?? vocabulary.containersListed, span: span))
        case .id(let id, let span)?:
            containerIDs.append((ShapeID(id), span))
        case .title?:
            if let head = heads.first { containerTitles.insert(head.id) }
        default:
            break
        }
    }

    /// A word where a kind goes that isn't one. `beforeTitle`: a title follows it (`note"Auth"`), so
    /// it isn't a title written without its quotes.
    func unknownKind(_ name: String, span: QuerySpan, beforeTitle: Bool = false) -> QueryError {
        let message = "\(name) isn't a kind."
        let type = EdgeTypeID(rawValue: name)
        if vocabulary.edgeTree.isDeclared(type) || presentEdgeTypes.contains(type) {
            return QueryError(.unknownKind, "\(name) is an edge type, not a kind.",
                              hint: ":\(Word.connectedTo.rawValue)(*, \(name)) finds the shapes it joins.", span: span)
        }
        if let attribute = vocabulary.kinds.lazy.compactMap({ $0.attribute(name) }).first {
            return QueryError(.unknownKind, message, hint: "Attributes are tested in brackets: [\(attribute.name)].", span: span)
        }
        if let word = vocabulary.words.first(where: { $0.word == asciiLowercased(name) }) {
            return QueryError(.unknownKind, message, hint: "A pseudo-class is written after a colon: :\(word.word).", span: span)
        }
        if let hint = didYouMean(vocabulary.kindsLike(name).map(vocabulary.called)) {
            return QueryError(.unknownKind, message, hint: hint, span: span)
        }
        // A word like no kind may be a title without its quotes, which the answer, reading the
        // titles, can tell (`QueryState.run`).
        let premise = vocabulary.naming == nil || beforeTitle ? nil : HintPremise(.titled(name), hint: "\(quoted(name)) is the shape titled so.")
        return QueryError(.unknownKind, message, hint: "The kinds: \(vocabulary.kinds.map(\.kind.rawValue).joined(separator: ", ")).",
                          premise: premise, span: span)
    }

    // MARK: Attributes

    /// `[name op value flag]`: a reader per kind that has the attribute (the compound's kind, or
    /// every kind with one), each with the literal read as that kind's property takes it. `!=` is
    /// `:not([name=value])`: shapes without the attribute match it.
    mutating func attribute(_ test: AttributeTest, in compound: Compound, kinds: CompoundKinds) -> PlanNode? {
        let entries: [QueryVocabulary.KindEntry]
        switch kinds {
        case .unknown: return nil
        case .known(let kind): entries = vocabulary.kind(kind).map { [$0] } ?? []
        case .any: entries = vocabulary.kinds
        }
        let having = entries.compactMap { entry in entry.attribute(test.name).map { (entry, $0) } }
        guard !having.isEmpty else {
            problem(missingAttribute(test, in: compound, entries: entries, kinds: kinds))
            return nil
        }

        var readers: [AttributeReader] = [], refusal: QueryError?
        for (entry, attribute) in having {
            do throws(QueryError) {
                let typed = test.path.isEmpty && !Self.readsItems(test, attribute: attribute, of: entry)
                    ? try typedTest(test, attribute: attribute, of: entry) : try pathTest(test, attribute: attribute, of: entry)
                let source: AttributeReader.Source = attribute.isName ? .names : .property(attribute.shape)
                if let index = readers.firstIndex(where: { $0.source == source && $0.test == typed }) {
                    readers[index] = AttributeReader(kinds: readers[index].kinds.union([entry.kind]), source: source, test: typed)
                } else {
                    readers.append(AttributeReader(kinds: [entry.kind], source: source, test: typed))
                }
                if attribute.isName { uses.names = true }
                if let mediaType = attribute.mediaType {
                    uses.textFormats.insert(mediaType)
                    if vocabulary.textFormats[mediaType]?.reads.contains(.editor) == true { uses.noteEditorWord("[\(test.name)]") }
                }
            } catch {
                refusal = refusal ?? error
            }
        }
        guard !readers.isEmpty else {
            problem(refusal!)
            return nil
        }
        uses.attributes.insert(test.name)
        uses.readsText = true
        if !test.path.isEmpty { uses.notePath(attribute: test.name, members: test.path) }
        let tested = node(.attribute(name: test.name, readers: readers), span: test.span)
        return test.op == .notEquals ? node(.not(planList([tested])), span: test.span) : tested
    }

    /// Why no kind the compound can be has the attribute: a property that says where a shape is, one
    /// inside another, a word people reach for that's a selector here (`[kind=chore]` is `chore`), a
    /// name on a kind without names, or no such attribute.
    func missingAttribute(_ test: AttributeTest, in compound: Compound, entries: [QueryVocabulary.KindEntry],
                          kinds: CompoundKinds) -> QueryError {
        let name = test.name, span = test.span
        if entries.contains(where: { $0.schema.properties[name] != nil && $0.schema.holdsPlace(name) }) {
            return QueryError(.notBuilt, "\(name) is where the shape is; where shapes are isn't in the language yet.", span: span)
        }
        // A quoted name that is an attribute and a path (`["meta.owner"]`): the path is written bare.
        let parts = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.count > 1, parts.allSatisfy(isIdentifier), vocabulary.kinds.contains(where: { $0.attribute(parts[0]) != nil }) {
            var bare = test
            bare.name = parts[0]
            bare.path = Array(parts.dropFirst())
            return QueryError(.unknownAttribute, "No attribute is called \(name).",
                              hint: "A member inside an attribute is written without quotes: \(bare.canonical).", span: span)
        }
        if test.path.isEmpty, !vocabulary.kinds.contains(where: { $0.attribute(name) != nil }), let error = peopleWord(test, in: compound) { return error }
        let attributes: [String]
        let message: String
        switch kinds {
        case .known(let kind):
            attributes = entries.first?.attributes.map(\.name) ?? []
            message = name == vocabulary.nameAttribute ? "\(kind) has no \(name)s." : "\(kind) has no attribute \(name)."
        default:
            attributes = Set(vocabulary.kinds.flatMap { $0.attributes.map(\.name) }).sorted()
            message = "No kind has an attribute \(name)."
        }
        let guess = didYouMean(Suggestions.closest(to: name, among: attributes, limit: 1))
        let listing: String? = if case .known = kinds {
            attributes.isEmpty ? "It has no attributes." : "Its attributes: \(attributes.joined(separator: ", "))."
        } else {
            nil
        }
        return QueryError(.unknownAttribute, message, hint: sentences(guess, listing), span: span)
    }

    /// The words people write in brackets for what a query says otherwise: `[kind=chore]` for the
    /// kind `chore`, `[id=…]` for `#…`, `[name=…]` for the names point's attribute, `[board=…]` for
    /// what's on a board, and `[class=…]`, refused toward the app's word for a type's shapes. Nil for any other. A hint made from the value is
    /// only for `=`: `[board!=root]` is every shape but those on top, so the value's own form would
    /// ask the opposite.
    func peopleWord(_ test: AttributeTest, in compound: Compound) -> QueryError? {
        guard let word = PeopleWord(rawValue: asciiLowercased(test.name)) else { return nil }
        let value = test.op == .equals ? test.value?.text : nil
        let others = compound.filters.filter { $0 != .attribute(test) }
        let rest = others.map(filterText).joined()
        let span = test.span
        switch word {
        case .kind, .type:
            // The kind the value names, or the one it was probably meant as (`task`, a Task, is `chore`);
            // none for an edge type, whatever kind it looks like.
            let kind = value.flatMap { value -> ShapeKind? in
                if vocabulary.kind(ShapeKind(rawValue: value)) != nil { return ShapeKind(rawValue: value) }
                let type = EdgeTypeID(rawValue: value)
                guard !vocabulary.edgeTree.isDeclared(type), !presentEdgeTypes.contains(type) else { return nil }
                return vocabulary.kindsLike(value).first
            }
            // What the compound's head names, kept: a title with the kind before it, where the kind's
            // shapes can have one (else no hint: a kind's every shape would say more than was asked),
            // and a shape's id alone, which names one shape.
            let hint: String? = switch compound.head {
            case nil, .any?, .kind?:
                kind.map { $0.rawValue + rest }
            case .title(let title, let titleSpan)?, .kindTitle(_, _, let title, let titleSpan)?:
                kind.flatMap { kind in
                    guard vocabulary.naming != nil, let entry = vocabulary.kind(kind), entry.names != QueryNameSource.none else { return nil }
                    return Head.kindTitle(kind.rawValue, span, title: title, titleSpan).canonical + rest
                }
            case .id?:
                value.map { _ in headText(compound.head) + rest }
            }
            return QueryError(.unknownAttribute, "\(test.name) isn't an attribute: a shape's kind starts its part of the query.",
                              hint: hint, span: span)
        case .id:
            let hint = value.flatMap { UUID(uuidString: $0) }.map { "#\($0.uuidString)" + rest }
            return QueryError(.unknownAttribute, "\(test.name) isn't an attribute: # and a shape's id name the shape.", hint: hint, span: span)
        case .name:
            guard let attribute = vocabulary.nameAttribute, attribute != test.name else { return nil }
            var renamed = test
            renamed.name = attribute
            return QueryError(.unknownAttribute, "\(test.name) isn't an attribute: a shape's name is its \(attribute).",
                              hint: headText(compound.head) + renamed.canonical + rest, span: span)
        case .board, .page:
            // Written as a row gives `board`: "root" for the top board, else its owner's id; or by
            // the owner's title. A row's board is the one a shape is on, which `>` says nearest
            // (directly inside the owner: on its board, in no container), a head after it
            // (`"Pantry" > *[rank>3]`); and the top board's, `:top-level`. An owner by id or title is
            // hinted only once it's known to hold shapes (`HintPremise`).
            let message = "\(test.name) isn't an attribute: what's on a board is written after the shape that owns it."
            let inside = (compound.head == nil ? "*" : headText(compound.head)) + rest
            guard let value else { return QueryError(.unknownAttribute, message, span: span) }
            if asciiLowercased(value) == "root" {
                return QueryError(.unknownAttribute, message, hint: headText(compound.head) + rest + ":\(Word.topLevel.rawValue)", span: span)
            }
            let owner: Head
            if let id = UUID(uuidString: value) {
                owner = .id(id, span)
            } else if vocabulary.naming != nil {
                owner = .title(value, span)
            } else {
                return QueryError(.unknownAttribute, message, span: span)
            }
            return QueryError(.unknownAttribute, message,
                              premise: HintPremise(.holdShapes([Compound(head: owner, span: span)]), hint: owner.canonical + " > " + inside),
                              span: span)
        case .class:
            // A word the app may give a meaning (`HintPremise.Claim.typeWord`); without one, a plain refusal.
            return QueryError(.unsupported, "A type isn't an attribute: a shape is found by its kind, its title, its id, an attribute or a word.",
                              hint: value.map { "Name a kind, or find the word: :contains(\(quoted($0)))." },
                              premise: value.map { HintPremise(.typeWord($0), hint: nil) }, span: span)
        }
    }

    // MARK: Literals and operators, typed by the schema

    /// A test of one kind's attribute: the operator one its type has a meaning for, the literal read
    /// as the property takes it (a quoted number as a number; a day as the whole UTC day; a choice,
    /// any case with `i`; a list's item for `~=`), and a flag only on text.
    func typedTest(_ test: AttributeTest, attribute: QueryVocabulary.AttributeEntry, of entry: QueryVocabulary.KindEntry) throws(QueryError) -> TypedTest {
        let name = attribute.name, span = test.span
        guard let op = test.op, let literal = test.value else { return TypedTest(comparison: .present, ignoringCase: false) }
        let text = literal.text, ignoringCase = test.flag == .insensitive
        let nature = attribute.shape.what(compactType: attribute.compactType)
        let takesHint = "\(name) takes \(takes(attribute.compactType))."

        func refuseOperator(use: String?) -> QueryError {
            QueryError(.unsupportedOperator, "\(op.rawValue) compares \(op.domain); \(name) is \(nature).", hint: use, span: span)
        }
        func invalid(_ message: String, hint: String? = nil) -> QueryError {
            QueryError(.invalidValue, message, hint: hint ?? takesHint, span: span)
        }
        func refuseFlag() throws(QueryError) {
            guard let flag = test.flag else { return }
            var plain = test
            plain.flag = nil
            throw QueryError(.unsupportedOperator, "The \(flag.rawValue) flag compares text; \(name) is \(nature).",
                             hint: "Leave it out: \(plain.canonical).", span: span)
        }
        let ordering = "Use =, !=, <, <=, > or >=."

        switch attribute.shape {
        case .string(let format, _, let choices):
            // `[a=""]`: no value, absent or empty, on any text (a date's and a choice's too); for a
            // name, none, since a blank name is none. `[a!=""]` is its `:not`, as `!=` always is.
            if op.isEquality, text.isEmpty {
                if format == KindSchema.dateTime { try refuseFlag() }
                return TypedTest(comparison: .absent, ignoringCase: false)
            }
            if format == KindSchema.dateTime {
                try refuseFlag()
                guard op.isEquality || op.isOrdering else { throw refuseOperator(use: ordering) }
                guard let value = QueryDates.value(of: text) else { throw invalid("\(text) isn't a date.") }
                return TypedTest(comparison: op.comparison(value), ignoringCase: false)
            }
            guard !op.isOrdering else { throw refuseOperator(use: choices == nil ? "Use *=, ^=, $= or =." : "Use = or !=.") }
            if let choices, op.isEquality, !Self.isChoice(text, among: choices, ignoringCase: ignoringCase) {
                throw invalid("\(text) isn't one of \(name)'s words.",
                              hint: sentences(didYouMean(Suggestions.closest(to: text, among: choices, limit: 1)), takesHint))
            }
            // A name is matched folded, as a title head matches (`"Alpha"`): `=` folds the literal too.
            let written = attribute.isName && op.isEquality ? vocabulary.naming?.fold(text) ?? text : text
            return TypedTest(comparison: op.textComparison(written), ignoringCase: ignoringCase)
        case .number(let integer):
            try refuseFlag()
            guard op.isEquality || op.isOrdering else { throw refuseOperator(use: ordering) }
            guard text != KindSchema.null else { throw invalid("\(text) isn't a number.") }
            let value: JSONValue
            do throws(KindSchema.Refusal) {
                if integer, op.isOrdering, let number = Double(text), number.isFinite {
                    // Ordering takes any finite number: `[estimate<2.5]` is 0, 1 and 2. Only `=` and
                    // `!=` need a whole number, which no fraction equals.
                    value = .number(number)
                } else {
                    // Quoted or not, a number: `[rank="3"]` reads as `[rank=3]`.
                    value = try entry.schema.value(ofLiteral: text, quoted: false, for: name)
                }
            } catch {
                throw Self.numberRefusal(error, text: text, integer: integer, invalid: { invalid($0) })
            }
            return TypedTest(comparison: op.comparison(Self.number(value)), ignoringCase: false)
        case .boolean:
            try refuseFlag()
            guard op.isEquality else { throw refuseOperator(use: "Use = or !=: [\(name)=true].") }
            guard let flag = Bool(text) else { throw invalid("\(text) isn't true or false.") }
            return TypedTest(comparison: .equals(.bool(flag)), ignoringCase: false)
        case .array(let items):
            guard op == .hasWord else {
                let example = "[\(name)~=\(literal.isBare ? text : quoted(text))]"
                throw op.isEquality
                    ? QueryError(.unsupportedOperator, "\(op.rawValue) compares one value; \(name) is a list.",
                                 hint: "\(example) finds a list that holds it.", span: span)
                    : refuseOperator(use: "Use ~=: \(example) finds a list that holds it.")
            }
            let item = try itemValue(literal, items: items, of: name, in: entry, test: test)
            return TypedTest(comparison: .hasItem(item), ignoringCase: ignoringCase)
        case .object:
            guard !op.isEquality else {
                throw QueryError(.notBuilt, "\(name) is an object: comparing a whole object isn't in the language yet.",
                                 hint: "[\(name)] asks whether it says anything; [\(name).member] tests what is inside it.", span: span)
            }
            throw refuseOperator(use: nil)
        case .json:
            guard op.isEquality else { throw refuseOperator(use: "Use = or !=.") }
            let value: JSONValue = literal.isBare ? (Self.json(text) ?? .string(text)) : .string(text)
            return TypedTest(comparison: .equals(.json(value)), ignoringCase: ignoringCase)
        }
    }

    /// Whether a comparison with no path is a path test all the same: on a list of objects, or an object, whose schema says the
    /// member each reads as (`KindSchema.readsAs`): `[values="paid"]` is `[values.text="paid"]`, an item at a time.
    static func readsItems(_ test: AttributeTest, attribute: QueryVocabulary.AttributeEntry, of entry: QueryVocabulary.KindEntry) -> Bool {
        guard test.path.isEmpty, let op = test.op, !op.isOrdering else { return false }
        switch attribute.shape {
        case .array, .object: return entry.schema.readsAs(attribute.name, at: []) != nil
        default: return false
        }
    }

    /// Whether what a property holds has members: an object, any JSON, or a list of them, however deep.
    static func holdsMembers(_ shape: KindSchema.PropertyShape) -> Bool {
        switch shape {
        case .object, .json: true
        case .array(let items): holdsMembers(items)
        default: false
        }
    }

    /// `[a.b.c op value flag]`: a test of what's at the members inside an object attribute, typed
    /// later by the value found there (`PathTest`). Only an attribute whose value is an object (or
    /// any JSON), or a list of them, has members; a list, at the attribute or on the way, is searched
    /// an item at a time. Where the path ends at an object whose schema says the member it reads as
    /// (`KindSchema.readsAs`: a type as written, its `words`), a comparison compares that member. The
    /// literal needs nothing now but an ordering's: a number or a date.
    func pathTest(_ test: AttributeTest, attribute: QueryVocabulary.AttributeEntry, of entry: QueryVocabulary.KindEntry) throws(QueryError) -> TypedTest {
        let name = attribute.name, span = test.span
        guard Self.holdsMembers(attribute.shape) else {
            let what = attribute.shape.what(compactType: attribute.compactType)
            throw QueryError(.unknownAttribute, "\(name) is \(what), so it has no members.", hint: "[\(name)] tests it.", span: span)
        }
        // A member the kind's schema rules out is a slip, not an empty answer: a schema that lists every member of the objects the
        // path goes through (closed) is held to them.
        if let unknown = entry.schema.unknownMember(of: name, at: test.path) {
            let inside = test.path.prefix(unknown.depth).joined(separator: ".")
            throw QueryError(.unknownAttribute, "\(inside.isEmpty ? name : "\(name).\(inside)") has no member \(unknown.member).",
                             hint: sentences(didYouMean(Suggestions.closest(to: unknown.member, among: unknown.known, limit: 1)),
                                             "Its members: \(unknown.known.joined(separator: ", "))."), span: span)
        }
        guard let op = test.op, let literal = test.value else {
            return TypedTest(comparison: .path(PathTest(members: test.path, op: nil, literal: "", ignoringCase: false)), ignoringCase: false)
        }
        let members = test.path + (entry.schema.readsAs(name, at: test.path).map { [$0] } ?? [])
        let written = members.joined(separator: ".")
        if op.isOrdering {
            if let flag = test.flag {
                var plain = test
                plain.flag = nil
                throw QueryError(.unsupportedOperator, "The \(flag.rawValue) flag compares text; \(op.rawValue) compares numbers and dates.",
                                 hint: "Leave it out: \(plain.canonical).", span: span)
            }
            guard PathTest.number(literal.text) != nil || QueryDates.value(of: literal.text) != nil else {
                throw QueryError(.invalidValue, "\"\(literal.text)\" isn't a number or a date.",
                                 hint: "\(name).\(written) is compared by its value: a number, or a date as \"2026-10-01\".", span: span)
            }
        }
        let path = PathTest(members: members, op: op, literal: literal.text, ignoringCase: test.flag == .insensitive,
                            namedBy: members.count > test.path.count ? entry.schema.namedBy(name, at: test.path) : nil)
        return TypedTest(comparison: .path(path), ignoringCase: path.ignoringCase)
    }

    /// `~=`'s value on a list: an item, read as the list's items take one.
    func itemValue(_ literal: Literal, items: KindSchema.PropertyShape, of name: String, in entry: QueryVocabulary.KindEntry,
                   test: AttributeTest) throws(QueryError) -> PlanValue {
        let text = literal.text, span = test.span
        let itemType = items.what(compactType: "")
        let hint = "An item of \(name) is \(itemType)."
        func invalid(_ message: String) -> QueryError { QueryError(.invalidValue, message, hint: hint, span: span) }
        func refuseFlag() throws(QueryError) {
            guard let flag = test.flag else { return }
            var plain = test
            plain.flag = nil
            throw QueryError(.unsupportedOperator, "The \(flag.rawValue) flag compares text; \(name)'s items are \(itemType).",
                             hint: "Leave it out: \(plain.canonical).", span: span)
        }
        switch items {
        case .string(let format, _, let choices):
            if format == KindSchema.dateTime {
                try refuseFlag()
                guard let value = QueryDates.value(of: text) else { throw invalid("\(text) isn't a date.") }
                return value
            }
            if let choices, !Self.isChoice(text, among: choices, ignoringCase: test.flag == .insensitive) {
                throw QueryError(.invalidValue, "\(text) isn't one of the words \(name) holds.",
                                 hint: sentences(didYouMean(Suggestions.closest(to: text, among: choices, limit: 1)),
                                                 "Its items: \(choices.joined(separator: "|")).") , span: span)
            }
            return .text(text)
        case .number(let integer):
            try refuseFlag()
            guard text != KindSchema.null else { throw invalid("\(text) isn't a number.") }
            let value: JSONValue
            do throws(KindSchema.Refusal) {
                value = try entry.schema.value(ofLiteral: text, quoted: false, forItemOf: name)
            } catch {
                throw Self.numberRefusal(error, text: text, integer: integer, invalid: { invalid($0) })
            }
            return Self.number(value)
        case .boolean:
            try refuseFlag()
            guard let flag = Bool(text) else { throw invalid("\(text) isn't true or false.") }
            return .bool(flag)
        case .array, .object:
            throw QueryError(.notBuilt, "\(name) holds \(itemType == "a list" ? "lists" : "objects"): comparing a whole one isn't in the language yet.",
                             span: span)
        case .json:
            return .json(literal.isBare ? (Self.json(text) ?? .string(text)) : .string(text))
        }
    }

    static func isChoice(_ text: String, among choices: [String], ignoringCase: Bool) -> Bool {
        ignoringCase ? choices.contains { $0.caseInsensitiveCompare(text) == .orderedSame } : choices.contains(text)
    }

    static func number(_ value: JSONValue) -> PlanValue {
        .number(value.numberValue ?? .nan)
    }

    static func numberRefusal(_ refusal: KindSchema.Refusal, text: String, integer: Bool, invalid: (String) -> QueryError) -> QueryError {
        switch refusal {
        case .notFinite: invalid("\(text) isn't a finite number.")
        case .notA where integer && Double(text)?.isFinite == true: invalid("\(text) isn't a whole number.")
        default: invalid("\(text) isn't a number.")
        }
    }

    static func json(_ text: String) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    // MARK: Pseudo-classes

    /// A pseudo-class: the language's own word, a plugin's, or one refused. `container`: the compound
    /// it's in must be able to hold shapes, and so must what `:is` and `:where` hold, since their
    /// shapes are the compound's (`:is(rectangle) *` is refused as `rectangle *` is).
    mutating func pseudo(_ pseudo: PseudoClass, in compound: Compound, kinds: CompoundKinds, container: Bool) -> PlanNode? {
        guard let word = pseudo.word else { return contributed(pseudo, in: compound, kinds: kinds) }
        let span = pseudo.span
        switch (word, pseudo.argument) {
        case (.not, .selectors(let list)):
            return self.list(list, container: false).map { node(.not($0), span: span) }
        case (.is, .selectors(let list)), (.where, .selectors(let list)):
            return self.list(list, container: container).map { node(.is($0), span: span) }
        case (.inside, .selectors(let list)):
            uses.containment = true
            return self.list(list, container: true).map { node(.inside($0), span: span) }
        case (.has, .has(let items)):
            uses.containment = true
            var resolved: [PlanHasItem] = [], failed = false
            for item in items {
                if let inner = self.compound(item.compound, relation: nil, container: false) {
                    resolved.append(PlanHasItem(child: item.child, node: inner))
                } else {
                    failed = true
                }
            }
            return failed ? nil : node(.has(resolved), span: span)
        case (.topLevel, _):
            uses.containment = true
            return node(.topLevel, span: span)
        case (.currentBoard, _):
            uses.currentBoard = true
            uses.noteEditorWord(":\(Word.currentBoard.rawValue)")
            return node(.currentBoard, span: span)
        case (.dangling, .none):
            uses.edges = true
            return node(.dangling(.all), span: span)
        case (.dangling, .types(let terms)):
            uses.edges = true
            return types(terms, in: pseudo, anchors: nil).map { node(.dangling($0), span: span) }
        case (.contains, .text(let text)):
            uses.readsText = true
            if vocabulary.naming != nil { uses.names = true }
            uses.textFormats.formUnion(vocabulary.textFormats.keys)
            if vocabulary.textFormats.values.contains(where: { $0.reads.contains(.editor) }) { uses.noteEditorWord(":\(Word.contains.rawValue)") }
            return node(.contains(text), span: span)
        case (_, .anchored(let anchors, let terms)):
            uses.edges = true
            var lists: [PlanList] = [], failed = false
            for anchor in anchors {
                if let item = complex(anchor, container: false) { lists.append(planList([item])) } else { failed = true }
            }
            let filter = terms.map { types($0, in: pseudo, anchors: anchors) } ?? .all
            guard !failed, let filter, let first = lists.first else { return nil }
            // `#S::part(R)`: the parser let a row through only as the whole anchor of a word that reads one edge's end there.
            let part = anchors.count == 1 && word.anchorsRow ? anchors[0].compounds.last?.part.map { PartID($0.id) } : nil
            return node(.edges(word: word, anchor: first, second: lists.count > 1 ? lists[1] : nil, types: filter, part: part), span: span)
        default:
            problem(QueryError(.badArgument, ":\(word.rawValue) takes \(word.takes).", hint: word.example, span: span))
            return nil
        }
    }

    /// A word the language doesn't know: one the engine binds per request (`:scope`), a plugin's
    /// pseudo-class or relation, else refused. A plugin may not add a word of the first sort
    /// (`QueryWords.check`), so none is hidden by the other.
    mutating func contributed(_ pseudo: PseudoClass, in compound: Compound, kinds: CompoundKinds) -> PlanNode? {
        if let bound = ScopeWord(rawValue: pseudo.name) { return scoped(bound, pseudo) }
        guard let declared = vocabulary.contributedWords[pseudo.name] else {
            let attributes: [String] = switch kinds {
            case .known(let kind): vocabulary.kind(kind)?.attributes.map(\.name) ?? []
            case .any, .unknown: vocabulary.kinds.flatMap { $0.attributes.map(\.name) }
            }
            problem(vocabulary.unknownWord(pseudo, attributes: attributes))
            return nil
        }
        switch declared.meaning {
        case .pseudoClass(let behavior):
            var key = declared.word, text: String?
            if let argument = declared.argument {
                do throws(QueryError) {
                    text = try pseudo.text(argument: argument, example: declared.example)
                    if let text, let why = behavior.refusing?(text) {
                        throw QueryError(.badArgument, why, hint: declared.example, span: pseudo.span)
                    }
                } catch {
                    problem(error)
                    return nil
                }
                key = WordKey.make(declared.word, text: text)
            } else if case .raw = pseudo.argument {
                problem(QueryError(.badArgument, ":\(declared.word) takes \(declared.takes).", hint: ":\(declared.word)", span: pseudo.span))
                return nil
            }
            uses.pseudoClasses.insert(key)
            if behavior.settles { uses.settles = true }
            if declared.reads.contains(.editor) { uses.noteEditorWord(":\(declared.word)") }
            if let text { return node(.textPseudo(key: key, word: declared.word, text: text), span: pseudo.span) }
            return node(.pseudo(word: declared.word), span: pseudo.span)
        case .fileRelation:
            let list: SelectorList
            do throws(QueryError) {
                list = try SelectorList(argumentOf: pseudo)
            } catch {
                var refusal = error
                if refusal.reason == .badArgument { refusal.hint = declared.example }
                problem(refusal)
                return nil
            }
            // The fact may rest on edges still arriving (a stand-in's), so it waits for them as an edge word does.
            uses.edges = true
            uses.pseudoClasses.insert(declared.word)
            return self.list(list, container: false).map { node(.fileRelation(word: declared.word, anchor: $0), span: pseudo.span) }
        case .relation(let types, let direction):
            let list: SelectorList
            do throws(QueryError) {
                list = try SelectorList(argumentOf: pseudo)
            } catch {
                var refusal = error
                if refusal.reason == .badArgument { refusal.hint = declared.example }
                problem(refusal)
                return nil
            }
            uses.edges = true
            return self.list(list, container: false).map {
                node(.relation(word: declared.word, anchor: $0, types: PlanEdgeTypes(types: Set(types)), direction: direction), span: pseudo.span)
            }
        }
    }

    /// A word bound per request (`:scope`, `:scope-start`, `:scope-end`): it takes no argument, and the
    /// plan keeps where it's used, for the asker to bind (`QueryPlan.unbound(by:)`). The ends are
    /// Topology's connection edges, which a stand-in may still be answering, so those two wait for
    /// them as `:start-of` and `:end-of` do; `:scope` reads the bound id alone.
    mutating func scoped(_ word: ScopeWord, _ pseudo: PseudoClass) -> PlanNode? {
        if case .raw = pseudo.argument {
            problem(QueryError(.badArgument, "\(word.written) takes \(Word.Signature.none.takes).", hint: word.written, span: pseudo.span))
            return nil
        }
        uses.scope.append(PlanScopeUse(word: word, span: pseudo.span))
        if word.readsEdges { uses.edges = true }
        return node(.scope(word), span: pseudo.span)
    }

    /// A type list: each type and, unless it says `only`, those under it. A type must be declared,
    /// or in the file.
    mutating func types(_ terms: [TypeTerm], in pseudo: PseudoClass, anchors: [ComplexSelector]?) -> PlanEdgeTypes? {
        var found: Set<EdgeTypeID> = [], failed = false
        let tree = vocabulary.edgeTree
        for term in terms {
            let type = EdgeTypeID(rawValue: term.name)
            guard tree.isDeclared(type) || presentEdgeTypes.contains(type) else {
                failed = true
                problem(unknownType(term, in: pseudo, terms: terms, anchors: anchors))
                continue
            }
            found.insert(type)
            if !term.only { found.formUnion(tree.descendants(of: type)) }
        }
        return failed ? nil : PlanEdgeTypes(types: found)
    }

    func unknownType(_ term: TypeTerm, in pseudo: PseudoClass, terms: [TypeTerm], anchors: [ComplexSelector]?) -> QueryError {
        let name = term.name
        if vocabulary.kind(ShapeKind(rawValue: name)) != nil {
            // After the shape, a comma starts edge types: a second shape is written with the first, in :is().
            var hint: String?
            if var written = anchors?.map(\.canonical), terms.count == 1, !term.only, let last = written.popLast() {
                written.append(":is(\(last), \(name))")
                hint = ":\(pseudo.name)(\(written.joined(separator: ", ")))"
            }
            return QueryError(.unknownEdgeType, "\(name) is a kind, not an edge type.", hint: hint, span: term.span)
        }
        let known = vocabulary.edgeTree.declared.map(\.rawValue)
            + presentEdgeTypes.filter { !vocabulary.edgeTree.isDeclared($0) }.map(\.rawValue).sorted()
        let hint = didYouMean(Suggestions.closest(to: name, among: known, limit: 3))
            ?? (known.isEmpty ? "Nothing in this app declares edge types." : "The edge types: \(known.joined(separator: ", ")).")
        // A word that is some shape's title may be a type's: the app says, once it has read the titles.
        var premise: HintPremise?
        if let anchors, terms.count == 1, !term.only {
            premise = HintPremise(.titledArgument(word: pseudo.name, anchors: anchors.map(\.canonical), title: name), hint: nil)
        }
        return QueryError(.unknownEdgeType, "\(name) isn't an edge type.", hint: hint, premise: premise, span: term.span)
    }

    // MARK: Cost

    /// How early a node runs in its compound.
    func cost(_ op: PlanOp) -> PlanCost {
        switch op {
        case .id, .title, .scope: .found
        case .all, .kinds: .kinds
        case .topLevel, .currentBoard: .captured
        case .not, .is, .inside, .has, .parentIn, .ancestorIn, .edges, .relation, .fileRelation, .dangling, .and: .structure
        case .contains: .read
        case .attribute(_, let readers):
            readers.contains { reader in
                reader.source == .names && reader.kinds.contains { vocabulary.kind($0)?.names == .derived }
            } ? .main : .read
        case .pseudo(let word), .textPseudo(let word, _, _):
            switch vocabulary.declaration(forKey: word)?.meaning {
            case .pseudoClass(let behavior)?: behavior.seeds != nil ? .found : behavior.onMain != nil ? .main : .read
            default: .read
            }
        }
    }
}

extension PlanNode {
    var isEveryShape: Bool {
        if case .all = op { true } else { false }
    }
}

/// Words people write in brackets that a query says otherwise.
private enum PeopleWord: String {
    case kind, type, id, name, board, page, `class`
}

private func headText(_ head: Head?) -> String { head?.canonical ?? "" }

private func filterText(_ filter: Filter) -> String {
    switch filter {
    case .attribute(let test): test.canonical
    case .pseudo(let pseudo): pseudo.canonical
    }
}

// MARK: Operators

extension Operator {
    /// `=` or `!=`.
    var isEquality: Bool { self == .equals || self == .notEquals }
    /// `<`, `<=`, `>`, `>=`.
    var isOrdering: Bool { [.less, .lessOrEqual, .greater, .greaterOrEqual].contains(self) }

    /// What it compares, for a refusal: "text", "words in text and items in lists".
    var domain: String {
        switch self {
        case .equals, .notEquals: "values"
        case .less, .lessOrEqual, .greater, .greaterOrEqual: "numbers and dates"
        case .hasWord: "words in text and items in lists"
        case .startsWith, .endsWith, .contains, .dashMatch: "text"
        }
    }

    /// The comparison of a value (`!=` is `=`, negated by its node).
    func comparison(_ value: PlanValue) -> TypedTest.Comparison {
        switch self {
        case .less: .less(value)
        case .lessOrEqual: .lessOrEqual(value)
        case .greater: .greater(value)
        case .greaterOrEqual: .greaterOrEqual(value)
        default: .equals(value)
        }
    }

    /// The comparison of text.
    func textComparison(_ text: String) -> TypedTest.Comparison {
        switch self {
        case .startsWith: .prefix(text)
        case .endsWith: .suffix(text)
        case .contains: .substring(text)
        case .hasWord: .word(text)
        case .dashMatch: .dash(text)
        default: .equals(.text(text))
        }
    }
}

extension Literal {
    var isBare: Bool {
        if case .bare = self { true } else { false }
    }
}

extension String {
    /// With its first letter in capitals.
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: Dates

/// Dates as a query writes them: a day, `YYYY-MM-DD` (the whole UTC day), or an instant in ISO 8601
/// (`2026-10-01T09:30`, seconds and a fraction optional; `Z` or an offset, and none is UTC).
enum QueryDates {
    static func value(of text: String) -> PlanValue? {
        if KindSchema.isDay(text) { return day(text).map(PlanValue.day) }
        let parts = text.split(separator: "T", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, KindSchema.isDay(String(parts[0])), let start = day(String(parts[0])),
              let offset = time(parts[1]) else { return nil }
        return .instant(start.addingTimeInterval(offset))
    }

    private static let utc = TimeZone(secondsFromGMT: 0)!

    /// Midnight UTC at the start of a real day.
    private static func day(_ text: String) -> Date? {
        let numbers = text.split(separator: "-").compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let components = DateComponents(year: numbers[0], month: numbers[1], day: numbers[2])
        guard let date = calendar.date(from: components) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        return back.year == numbers[0] && back.month == numbers[1] && back.day == numbers[2] ? date : nil
    }

    /// Seconds from the day's UTC midnight: `HH:MM[:SS[.fraction]]`, then `Z`, `±HH:MM`, `±HHMM`,
    /// `±HH` or nothing (UTC).
    private static func time(_ text: Substring) -> TimeInterval? {
        var rest = text[...]
        func number(_ count: Int) -> Int? {
            let digits = rest.prefix(count)
            guard digits.count == count, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            rest = rest.dropFirst(count)
            return Int(digits)
        }
        func take(_ character: Character) -> Bool {
            guard rest.first == character else { return false }
            rest = rest.dropFirst()
            return true
        }
        guard let hour = number(2), hour < 24, take(":"), let minute = number(2), minute < 60 else { return nil }
        var seconds = TimeInterval(hour * 3600 + minute * 60)
        if take(":") {
            guard let second = number(2), second < 60 else { return nil }
            seconds += TimeInterval(second)
            if take(".") || take(",") {
                let digits = rest.prefix { $0.isASCII && $0.isNumber }
                guard !digits.isEmpty, let fraction = Double("0." + digits) else { return nil }
                rest = rest.dropFirst(digits.count)
                seconds += fraction
            }
        }
        if rest.isEmpty || take("Z") || take("z") { return rest.isEmpty ? seconds : nil }
        guard let sign = rest.first, sign == "+" || sign == "-" else { return nil }
        rest = rest.dropFirst()
        guard let hours = number(2), hours < 24 else { return nil }
        // `±HH`, or minutes after it, with a colon or without (never a colon and nothing).
        let minutes = take(":") || !rest.isEmpty ? number(2) : 0
        guard let minutes, minutes < 60, rest.isEmpty else { return nil }
        let offset = TimeInterval(hours * 3600 + minutes * 60)
        return sign == "+" ? seconds - offset : seconds + offset
    }
}
