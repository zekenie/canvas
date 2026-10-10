import Canvas
import QueryLanguage
import Topology

// What queries take from the plugins that own a concern, each an extension point filled by
// QueryLexicon (QueriesTests fill them with fixtures of their own): what shapes are called (QueryNames, Titles'), what an untitled owner's board is called
// (QueryBoardNames, Boards'), words a query may use beyond the language's (QueryWords: a
// pseudo-class, `:selected`, or a relation over edges, `:mentions(S)`), and how text of a media
// type reads (QueryTextFormats: mention text as plain text with live names). Without one, a query
// does without: no titles (a title head is `no_names`), boards named by their owners' labels, no
// word the language hasn't, and text read as stored.

// MARK: Names

/// Whether a kind's shapes have names, for queries: none; named, by what the shape holds (read on
/// any thread); or derived, worked out by the plugin that names them (read on the main actor).
public enum QueryNameSource: Sendable {
    case none, named, derived
}

/// How shapes are named, for queries: the attribute a query tests names with (`[title^="API"]`),
/// which kinds' shapes have names and how, a named shape's name (anywhere) and a derived one's (on
/// the main actor, about the shape as the app has it when asked), and how a title a query writes is
/// folded to be matched. Only the sugar makes one (`registrar.queryNames`).
public struct QueryNaming: Sendable {
    let attribute: String
    let source: @MainActor (ShapeKind, Registry) -> QueryNameSource
    let named: @Sendable (AnyShapeRecord) -> String?
    let derived: @MainActor (AnyShapeRecord, Registry) -> String?
    let fold: @Sendable (String) -> String?
}

/// What names shapes for queries: at most one plugin.
public enum QueryNames {}

extension QueryNames: KeyedExtensionPoint {
    public typealias Contribution = QueryNaming
    public static var owner: PluginID { .queries }
    public static func uniqueKeys(of _: QueryNaming, for _: ShapeTarget) -> [AnyHashable] { [QueryPointKey(name: label)] }
    public static func summary(of _: QueryNaming, for _: ShapeTarget) -> String { label }
    static let label = "query names"

    /// The attribute is a word a query can write bare, in brackets: `[title]`.
    public static func check(_ registry: Registry) throws(RegistryError) {
        for naming in registry.contributions(to: QueryNames.self) where !isIdentifier(naming.value.attribute) {
            throw .invalid(point: "QueryNames", reason: "\(naming.pluginID) names shapes by the attribute \"\(naming.value.attribute)\", which a query can't write: a letter or _, then letters, digits, - and _")
        }
    }
}

// MARK: Boards' names

/// What a board is called while its owner has no name, per kind: Boards' placeholder, "Untitled
/// Subboard". Only the sugar makes one (`registrar.queryBoardNames`).
public struct QueryBoardNaming: Sendable {
    let placeholder: @MainActor (ShapeKind, Registry) -> String?
}

/// What names untitled owners' boards for queries: at most one plugin.
public enum QueryBoardNames {}

extension QueryBoardNames: KeyedExtensionPoint {
    public typealias Contribution = QueryBoardNaming
    public static var owner: PluginID { .queries }
    public static func uniqueKeys(of _: QueryBoardNaming, for _: ShapeTarget) -> [AnyHashable] { [QueryPointKey(name: label)] }
    public static func summary(of _: QueryBoardNaming, for _: ShapeTarget) -> String { label }
    static let label = "query board names"
}

// MARK: Words

/// Whether a shape meets a contributed pseudo-class, as far as `matches` can say anywhere: yes, no,
/// or ask `onMain` (a verdict only the main actor can reach: Validation's rules).
public enum QueryVerdict: Sendable {
    case yes, no, onMain
}

/// A shape a query tests, as the file was when the app took up the request: its record, the board
/// it's on, and Topology as it was then.
public struct QueryShape: Sendable {
    public let record: AnyShapeRecord
    public let board: BoardID
    public let topology: TopologySnapshot

    init(record: AnyShapeRecord, board: BoardID, topology: TopologySnapshot) {
        self.record = record
        self.board = board
        self.topology = topology
    }
}

/// What a word's or a text format's verdict reads, said once by whoever adds it: the file as the
/// query takes it up (its records, edges and containment: the snapshot), or the editor too (the
/// selection, the board shown, a service's state, the live validation). A plan that holds only
/// words that read the file answers the same whenever, whoever is looking, so what keeps an answer
/// past the moment it was asked (`QueryPlan.readsOnlyTheFile`) may keep it.
public struct QueryReads: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The file alone.
    public static let file = QueryReads(rawValue: 1)
    /// The editor: the default for a word added with a `prepare` that takes `QueryPreparation`.
    public static let editor = QueryReads(rawValue: 2)
}

/// The claim that a word or a text format reads only the file, made as a parameter (`reads: .file`)
/// that only the forms whose `prepare` takes a `QueryFilePreparation` accept: the compiler holds
/// it, since what they're given has no editor.
public struct QueryFileReads: Sendable {
    public static let file = QueryFileReads()
}

/// What a word's or a text format's `prepare` gets, on the main actor, in the turn the query takes
/// up the file: the editor, to take what it needs of it (a set of ids, a service's O(1) value).
@MainActor
public struct QueryPreparation {
    public let editor: CanvasEditor
    let file: QueryFilePreparation

    init(editor: CanvasEditor, file: QueryFilePreparation) {
        self.editor = editor
        self.file = file
    }
}

/// What a `reads: .file` word's or text format's `prepare` gets, on the main actor, in the turn the
/// query takes up the file: Topology as it was taken up (its edges in the request's view, its
/// containment, the records of every shape the app can show: `shape(_:)`, `forEachShape`) and the
/// registry. Never the editor: code that reads the live editor, the selection, the camera or a
/// service doesn't compile here. A request for several views at once prepares a word once, in the
/// first request's view. What a plugin keeps of the file and is a function of its records alone
/// reaches it only as a declared `QueryFileFact` (`fact(_:)`).
@MainActor
public struct QueryFilePreparation {
    public let snapshot: TopologySnapshot
    public let registry: Registry
    /// Lent to facts alone: never to the word.
    private let editor: CanvasEditor

    init(snapshot: TopologySnapshot, registry: Registry, editor: CanvasEditor) {
        self.snapshot = snapshot
        self.registry = registry
        self.editor = editor
    }

    /// A fact of the file as the query takes it up (`QueryFileFact.current(in:)`): what a plugin
    /// keeps that is a function of the records alone, taken in this turn.
    public func fact<Fact: QueryFileFact>(_: Fact.Type) -> Fact { Fact.current(in: editor) }
}

/// A value an editor keeps of the file that is a function of its records alone (never the person,
/// the board shown, the camera, a verdict, or Topology's resolved edges): the names mentions show
/// now, which are their shapes' names. The one way a `reads: .file` word or text format reads what
/// a plugin keeps (`QueryFilePreparation.fact(_:)`), so a query that uses it still reads only the
/// file: the claim is the fact type's, made once where it's declared, and a word's own `prepare`
/// still can't reach the editor. `current(in:)` runs on the main actor in the turn the query takes
/// up the file: O(1), a value the plugin keeps, shared, never one it makes then.
public protocol QueryFileFact: Sendable {
    @MainActor static func current(in editor: CanvasEditor) -> Self
}

/// What a word's `onMain` gets beside the shape: the registry, the editor, the editor's revision as
/// the query started, and the file as the app has it now. `onMain` is asked about the shape as the
/// app has it when it's asked, not as the query took it up: what only the main actor can answer (a
/// derived title, a validation verdict) is the app's now.
@MainActor
public struct QueryMainContext {
    public let registry: Registry
    public let editor: CanvasEditor
    /// `editor.revision` as the query started.
    public let revision: Int
    private let kept: KeptContexts

    /// `kept` is the query's: made once per query and handed to each slice's context, so what holds
    /// it (weakly holding the editor) keeps the boards' contexts without keeping the editor alive.
    init(editor: CanvasEditor, revision: Int, kept: KeptContexts = KeptContexts()) {
        registry = editor.registry
        self.editor = editor
        self.revision = revision
        self.kept = kept
    }

    /// A board as the app has it now, to run rules over (`ShapeContext(document:registry:)` over
    /// `editor.contents(of:)`, read without observing it): one per board per query, made again only
    /// once the board has changed since (its revision in the file).
    public func shapes(on board: BoardID) -> ShapeContext {
        editor.withoutObservingDocument {
            let revision = editor.file.revision(of: board)
            if let context = kept.byBoard[board], context.revision == revision { return context.shapes }
            let shapes = ShapeContext(document: editor.contents(of: board), registry: registry)
            kept.byBoard[board] = (revision, shapes)
            return shapes
        }
    }

    /// A shape as the app has it now, and the board it's on now: nil once it's gone from the file,
    /// or kept aside, or on a board the app can't show. Read without observing the file.
    public func shape(_ id: ShapeID) -> (record: AnyShapeRecord, board: BoardID)? {
        editor.withoutObservingDocument {
            let file = editor.file
            guard let board = file.board(containing: id), let record = file.record(id), !record.isOpaque,
                  file.canShow(board, boardOwningKinds: registry.boardOwningKinds) else { return nil }
            return (record, board)
        }
    }
}

/// The contexts one query's main slices made, by board.
@MainActor
final class KeptContexts {
    var byBoard: [BoardID: (revision: Int, shapes: ShapeContext)] = [:]
}

/// A pseudo-class a plugin adds (`:selected`), type-erased: what `prepare` took on the main actor is
/// handed back as it was to `seeds`, `matches` and `onMain`.
struct ContributedPseudoClass: Sendable {
    let reads: QueryReads
    let prepare: @MainActor (QueryPreparation) -> any Sendable
    let seeds: (@Sendable (any Sendable) -> Set<ShapeID>)?
    let matches: @Sendable (QueryShape, any Sendable) -> QueryVerdict
    let onMain: (@MainActor (AnyShapeRecord, BoardID, any Sendable, QueryMainContext) -> Bool)?
}

/// A relation a plugin answers from what it keeps of the file (`:is-a(S)`), type-erased: `related`
/// says, for a shape, the shapes it stands in the relation to directly, with what `prepare` took on
/// the main actor; `seeds` is every shape that has any, which are the only shapes that can match.
struct ContributedFileRelation: Sendable {
    /// Whether a shape is also related to what the shapes it's related to are, however far.
    let transitive: Bool
    /// Whether its argument names types: what `.Name` is refused toward.
    let namesTypes: Bool
    let prepare: @MainActor (QueryFilePreparation) -> any Sendable
    let seeds: @Sendable (any Sendable) -> Set<ShapeID>
    let related: @Sendable (ShapeID, any Sendable) -> [ShapeID]
}

/// A word a plugin adds to queries: a pseudo-class (`:selected`), a relation over edges of exactly
/// some types (`:mentions(S)`) or a relation answered from a fact of the file (`:is-a(S)`), with
/// what it means in a line and a query that uses it. Only the sugar makes one
/// (`registrar.queryPseudoClass`, `registrar.queryRelation`).
public struct QueryWordDeclaration: Sendable {
    enum Meaning: Sendable {
        case pseudoClass(ContributedPseudoClass)
        /// `.outgoing`: the result → S; `.incoming`: S → the result.
        case relation(types: [EdgeTypeID], direction: EdgeDirection)
        /// The result is related, directly or (`transitive`) through other shapes, to a shape S
        /// matches, as the plugin's `related` says.
        case fileRelation(ContributedFileRelation)
    }

    let word: String
    let summary: String
    let example: String
    let meaning: Meaning
    /// What its verdict reads.
    var reads: QueryReads {
        switch meaning {
        case .pseudoClass(let behavior): behavior.reads
        case .relation, .fileRelation: .file
        }
    }
    /// Whether it's the person's selection (`registrar.querySelection`): what `--ask` says is
    /// selected. At most one word is.
    var isSelection = false
}

/// What a selection word (`registrar.querySelection`) takes as the query takes up the file: the
/// shapes selected, in the selection's order, and as a set.
struct SelectedShapes: Sendable {
    let ids: [ShapeID]
    let set: Set<ShapeID>
}

/// The words plugins add to queries, each once: none may be one of the language's own
/// (`QueryLanguage.Word`), nor one it knows people reach for (`KnownInventions`), and a relation
/// follows edge types some installed plugin declares.
public enum QueryWords {}

extension QueryWords: KeyedExtensionPoint {
    public typealias Contribution = QueryWordDeclaration
    public static var owner: PluginID { .queries }
    public static func uniqueKeys(of declaration: QueryWordDeclaration, for _: ShapeTarget) -> [AnyHashable] {
        [QueryWordKey(word: declaration.word)]
    }
    public static func summary(of declaration: QueryWordDeclaration, for _: ShapeTarget) -> String { "query word :\(declaration.word)" }

    public static func check(_ registry: Registry) throws(RegistryError) {
        for declared in registry.contributions(to: QueryWords.self) {
            let word = declared.value.word
            func refuse(_ reason: String) -> RegistryError {
                .invalid(point: "QueryWords", reason: "\(declared.pluginID) adds :\(word), \(reason)")
            }
            guard isWord(word) else { throw refuse("which isn't lowercase words joined by hyphens") }
            guard Word(rawValue: word) == nil else { throw refuse("one of the language's own words") }
            guard KnownInventions.invention(for: word) == nil else {
                throw refuse("which the language refuses as a word people reach for; pick another")
            }
            if declared.value.isSelection,
               let other = registry.contributions(to: QueryWords.self).first(where: { $0.value.isSelection && $0.value.word != word }) {
                throw refuse("the person's selection, which :\(other.value.word) (\(other.pluginID)) says already")
            }
            if case .fileRelation(let relation) = declared.value.meaning, relation.namesTypes,
               let other = registry.contributions(to: QueryWords.self).first(where: { other in
                   if case .fileRelation(let theirs) = other.value.meaning { theirs.namesTypes && other.value.word != word } else { false }
               }) {
                throw refuse("a relation that names types, which :\(other.value.word) (\(other.pluginID)) is already")
            }
            guard case .relation(let types, _) = declared.value.meaning else { continue }
            guard !types.isEmpty else { throw refuse("a relation over no edge type") }
            for type in types where !registry.declaresEdgeType(type) {
                throw refuse("a relation over edge type \(type), which no installed plugin declares")
            }
        }
    }

    /// Lowercase ASCII words (a letter, then letters and digits) joined by single hyphens.
    static func isWord(_ word: String) -> Bool {
        let parts = word.split(separator: "-", omittingEmptySubsequences: false)
        return parts.allSatisfy { part in
            guard let first = part.first, first.isASCII, first.isLowercase else { return false }
            return part.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) }
        }
    }
}

struct QueryWordKey: Hashable, CustomStringConvertible {
    let word: String
    var description: String { ":\(word)" }
}

// MARK: Text formats

/// How strings whose schema says `contentMediaType: mediaType` read in queries and rows: `read`
/// makes the stored text what a person reads (anywhere), with what `prepare` took on the main
/// actor; `describes` says so in the vocabulary ("mentions read as @Name"). Only the sugar makes
/// one (`registrar.queryTextFormat`).
public struct QueryTextFormatting: Sendable {
    let mediaType: String
    let describes: String
    /// What it reads: the file, or the editor too.
    let reads: QueryReads
    let prepare: @MainActor (QueryPreparation) -> any Sendable
    let read: @Sendable (String, any Sendable) -> String
}

/// How text of each media type reads in queries: one plugin per media type.
public enum QueryTextFormats {}

extension QueryTextFormats: KeyedExtensionPoint {
    public typealias Contribution = QueryTextFormatting
    public static var owner: PluginID { .queries }
    public static func uniqueKeys(of format: QueryTextFormatting, for _: ShapeTarget) -> [AnyHashable] {
        [QueryPointKey(name: "query text \(format.mediaType)")]
    }
    public static func summary(of format: QueryTextFormatting, for _: ShapeTarget) -> String { "query text \(format.mediaType)" }
}

/// The one key a point with one contribution (or one per media type) claims: its name in a conflict.
struct QueryPointKey: Hashable, CustomStringConvertible {
    let name: String
    var description: String { name }
}

/// A letter or `_`, then letters, digits, `-` and `_`: what a query writes bare.
func isIdentifier(_ text: String) -> Bool {
    guard let first = text.first, first.isLetter || first == "_" else { return false }
    return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
}

// MARK: Sugar (what QueryLexicon writes)

extension PluginRegistrar {
    /// Names shapes for queries, for `"Title"` heads, the attribute `attribute` (`[title^="API"]`),
    /// rows and `--ask`'s titles: `source` says, once per kind, whether its shapes are named, and
    /// how; `named` is a named shape's name, read anywhere (folded; nil for none); `derived` a
    /// derived one's, on the main actor, about the shape as the app has it when asked (folded; nil
    /// for none); and `fold` how a title a query writes is folded to be matched (nil: it's blank).
    /// At most one plugin names shapes.
    public mutating func queryNames(attribute: String,
                                    source: @escaping @MainActor (ShapeKind, Registry) -> QueryNameSource,
                                    named: @escaping @Sendable (AnyShapeRecord) -> String?,
                                    derived: @escaping @MainActor (AnyShapeRecord, Registry) -> String?,
                                    fold: @escaping @Sendable (String) -> String?) {
        contribute(QueryNaming(attribute: attribute, source: source, named: named, derived: derived, fold: fold), to: QueryNames.self)
    }

    /// What a board is called while its owner has no name, per board-owning kind, asked once per
    /// kind as the vocabulary is built. A board's name is then its owner's name (the names point),
    /// else this, else the kind's label (`registry.label(of:)`): Boards' own rule. At most one
    /// plugin names boards.
    public mutating func queryBoardNames(placeholder: @escaping @MainActor (ShapeKind, Registry) -> String?) {
        contribute(QueryBoardNaming(placeholder: placeholder), to: QueryBoardNames.self)
    }

    /// `:word`, a pseudo-class with no argument, meaning `summary` ("the person has it selected"),
    /// as `example` uses it. `prepare` runs on the main actor in the turn the query takes up the file
    /// (take what's needed there, O(1) or O(what it holds)); `seeds`, the only shapes that can
    /// match, if it knows them; `matches` anywhere, for each shape a query tests; and `onMain` for a
    /// shape `matches` leaves to the main actor (`.onMain`), asked in slices about the shape as the
    /// app has it then. It reads the editor (`QueryReads.editor`): a plan that holds it isn't
    /// `readsOnlyTheFile`.
    public mutating func queryPseudoClass<Prepared: Sendable>(
        _ word: String, _ summary: String, example: String,
        prepare: @escaping @MainActor (QueryPreparation) -> Prepared,
        seeds: (@Sendable (Prepared) -> Set<ShapeID>)? = nil,
        matches: @escaping @Sendable (QueryShape, Prepared) -> QueryVerdict,
        onMain: (@MainActor (AnyShapeRecord, BoardID, Prepared, QueryMainContext) -> Bool)? = nil
    ) {
        contributePseudoClass(word, summary, example: example, reads: .editor, prepare: { prepare($0) }, seeds: seeds, matches: matches,
                              onMain: onMain)
    }

    /// As above, for a word whose verdict reads only the file (`reads: .file`): `prepare` is given
    /// the file as the query takes it up and the registry, and no editor, so it can't read anything
    /// else; and it has no `onMain`, whose context lends the editor. What a plan with such words
    /// alone says of itself (`QueryPlan.readsOnlyTheFile`) is true because of it.
    public mutating func queryPseudoClass<Prepared: Sendable>(
        _ word: String, _ summary: String, example: String, reads _: QueryFileReads,
        prepare: @escaping @MainActor (QueryFilePreparation) -> Prepared,
        seeds: (@Sendable (Prepared) -> Set<ShapeID>)? = nil,
        matches: @escaping @Sendable (QueryShape, Prepared) -> QueryVerdict
    ) {
        contributePseudoClass(word, summary, example: example, reads: .file, prepare: { prepare($0.file) }, seeds: seeds, matches: matches,
                              onMain: nil)
    }

    private mutating func contributePseudoClass<Prepared: Sendable>(
        _ word: String, _ summary: String, example: String, reads: QueryReads,
        prepare: @escaping @MainActor (QueryPreparation) -> Prepared,
        seeds: (@Sendable (Prepared) -> Set<ShapeID>)?,
        matches: @escaping @Sendable (QueryShape, Prepared) -> QueryVerdict,
        onMain: (@MainActor (AnyShapeRecord, BoardID, Prepared, QueryMainContext) -> Bool)?
    ) {
        let erasedPrepare: @MainActor (QueryPreparation) -> any Sendable = { prepare($0) }
        let erasedMatches: @Sendable (QueryShape, any Sendable) -> QueryVerdict = { shape, prepared in matches(shape, prepared as! Prepared) }
        var erasedSeeds: (@Sendable (any Sendable) -> Set<ShapeID>)?
        if let seeds { erasedSeeds = { prepared in seeds(prepared as! Prepared) } }
        var erasedOnMain: (@MainActor (AnyShapeRecord, BoardID, any Sendable, QueryMainContext) -> Bool)?
        if let onMain {
            erasedOnMain = { record, board, prepared, context in onMain(record, board, prepared as! Prepared, context) }
        }
        let pseudoClass = ContributedPseudoClass(reads: reads, prepare: erasedPrepare, seeds: erasedSeeds, matches: erasedMatches,
                                                 onMain: erasedOnMain)
        contribute(QueryWordDeclaration(word: word, summary: summary, example: example, meaning: .pseudoClass(pseudoClass)),
                   to: QueryWords.self)
    }

    /// `:word`, the person's selection, meaning `summary` ("the person has it selected"), as
    /// `example` uses it: the shapes `selected` lists (on the main actor, in the turn the query takes
    /// up the file), which are its only matches, and what `--ask` tells the model is selected
    /// (`QueryState.whereThePersonIs`), in that order. At most one plugin says what's selected.
    public mutating func querySelection(_ word: String, _ summary: String, example: String,
                                        selected: @escaping @MainActor (CanvasEditor) -> [ShapeID]) {
        let pseudoClass = ContributedPseudoClass(
            reads: .editor,
            prepare: { preparation in
                let ids = selected(preparation.editor)
                return SelectedShapes(ids: ids, set: Set(ids))
            },
            seeds: { ($0 as! SelectedShapes).set },
            matches: { shape, taken in (taken as! SelectedShapes).set.contains(shape.record.id) ? .yes : .no },
            onMain: nil)
        contribute(QueryWordDeclaration(word: word, summary: summary, example: example, meaning: .pseudoClass(pseudoClass), isSelection: true),
                   to: QueryWords.self)
    }

    /// `:word(S)`, a relation over edges of exactly `types` (none under them), meaning `summary`,
    /// as `example` uses it: `.outgoing`, the result has such an edge to a shape S matches;
    /// `.incoming`, a shape S matches has one to the result.
    public mutating func queryRelation(_ word: String, _ summary: String, example: String,
                                       types: [EdgeTypeID], direction: EdgeDirection) {
        contribute(QueryWordDeclaration(word: word, summary: summary, example: example,
                                        meaning: .relation(types: types, direction: direction)),
                   to: QueryWords.self)
    }

    /// `:word(S)`, a relation answered from what a plugin keeps of the file (a `QueryFileFact`, taken
    /// by `prepare` in the turn the query takes up the file), meaning `summary`, as `example` uses
    /// it: a result is related, as `related` says (the shapes `shape` is related to directly), to a
    /// shape S matches. With `transitive`, also through other shapes, however many, breadth first
    /// and cycle-safe (a shape in a cycle is related to itself); an answer is worked out once per
    /// query. `seeds` is every shape that has anything `related`: the only shapes that can match.
    /// It reads only the file (`reads: .file`), so a plan that holds it is `readsOnlyTheFile`. A
    /// relation with `namesTypes` is the word `.Name` is refused toward (`unsupported`, hinted
    /// `:word("Name")`); at most one word is.
    public mutating func queryRelation<Prepared: Sendable>(
        _ word: String, _ summary: String, example: String, reads _: QueryFileReads,
        transitive: Bool, namesTypes: Bool = false,
        prepare: @escaping @MainActor (QueryFilePreparation) -> Prepared,
        seeds: @escaping @Sendable (Prepared) -> Set<ShapeID>,
        related: @escaping @Sendable (ShapeID, Prepared) -> [ShapeID]
    ) {
        let relation = ContributedFileRelation(
            transitive: transitive, namesTypes: namesTypes,
            prepare: { prepare($0) },
            seeds: { seeds($0 as! Prepared) },
            related: { shape, prepared in related(shape, prepared as! Prepared) })
        contribute(QueryWordDeclaration(word: word, summary: summary, example: example, meaning: .fileRelation(relation)), to: QueryWords.self)
    }

    /// How strings whose schema says `contentMediaType: mediaType` read in queries and rows: `read`
    /// turns the stored text into what a person reads, anywhere, with what `prepare` took on the
    /// main actor in the turn the query takes up the file; `describes` says it in the vocabulary
    /// ("mentions read as @Name"). One plugin per media type.
    public mutating func queryTextFormat<Prepared: Sendable>(
        mediaType: String, describes: String,
        prepare: @escaping @MainActor (QueryPreparation) -> Prepared,
        read: @escaping @Sendable (String, Prepared) -> String
    ) {
        contributeTextFormat(mediaType: mediaType, describes: describes, reads: .editor, prepare: { prepare($0) }, read: read)
    }

    /// As above, for a format that reads only the file (`reads: .file`): `prepare` is given the file
    /// as the query takes it up and the registry, and no editor.
    public mutating func queryTextFormat<Prepared: Sendable>(
        mediaType: String, describes: String, reads _: QueryFileReads,
        prepare: @escaping @MainActor (QueryFilePreparation) -> Prepared,
        read: @escaping @Sendable (String, Prepared) -> String
    ) {
        contributeTextFormat(mediaType: mediaType, describes: describes, reads: .file, prepare: { prepare($0.file) }, read: read)
    }

    private mutating func contributeTextFormat<Prepared: Sendable>(
        mediaType: String, describes: String, reads: QueryReads,
        prepare: @escaping @MainActor (QueryPreparation) -> Prepared,
        read: @escaping @Sendable (String, Prepared) -> String
    ) {
        let erasedPrepare: @MainActor (QueryPreparation) -> any Sendable = { prepare($0) }
        let erasedRead: @Sendable (String, any Sendable) -> String = { text, prepared in read(text, prepared as! Prepared) }
        contribute(QueryTextFormatting(mediaType: mediaType, describes: describes, reads: reads, prepare: erasedPrepare, read: erasedRead),
                   to: QueryTextFormats.self)
    }
}

// MARK: Reading them

extension Registry {
    var queryNaming: QueryNaming? { contributions(to: QueryNames.self).first?.value }
    var queryBoardNaming: QueryBoardNaming? { contributions(to: QueryBoardNames.self).first?.value }
}
