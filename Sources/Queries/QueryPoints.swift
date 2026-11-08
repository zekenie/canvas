import Canvas
import CanvasRPC
import QueryLanguage
import Topology

// What queries take from the plugins that own a concern, each an extension point filled by the
// plugin that owns the meaning (QueriesTests fill them with fixtures of their own): what shapes
// are called (QueryNames, Titles'), what an untitled owner's board is called (QueryBoardNames,
// Boards'), words a query may use beyond the language's (QueryWords: a pseudo-class, `:selected`,
// or a relation over edges, `:mentions(S)`), and how text of a media type reads
// (QueryTextFormats: mention text as plain text with live names). Without one, a query does
// without: no titles (a title head is `no_names`), boards named by their owners' labels, no word
// the language hasn't, and text read as stored.

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

// MARK: Parts' names

/// What a part of a kind's shapes is called, for queries: a connection's end bound to a row says the row (`QueryEnd.row`,
/// "customer_id", "POST /orders/{id}/refunds"), read off the main actor from the record, as a named shape's name is. Nil for
/// a part the record doesn't hold, or one with no name. Only the sugar makes one (`registrar.queryPartNames`).
public struct QueryPartNaming: Sendable {
    let name: @Sendable (AnyShapeRecord, PartID) -> String?
}

/// What names the parts of a kind's shapes for queries: one plugin a kind, contributed for that kind.
public enum QueryPartNames {}

extension QueryPartNames: KeyedExtensionPoint {
    public typealias Contribution = QueryPartNaming
    public static var owner: PluginID { .queries }
    public static func uniqueKeys(of _: QueryPartNaming, for target: ShapeTarget) -> [AnyHashable] { [QueryPointKey(name: "query part names \(target)")] }
    public static func summary(of _: QueryPartNaming, for _: ShapeTarget) -> String { "query part names" }
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

/// A thing a word's argument names that the file no longer holds (a shape a drawing made and
/// someone deleted): its id as the word keeps it, and the members the word says of it. A query's
/// answer lists it (`QueryResult.absent`), beside the shapes that matched.
public struct QueryAbsent: Sendable, Equatable {
    public var id: String
    public var members: [String: JSON]

    public init(id: String, members: [String: JSON] = [:]) {
        self.id = id
        self.members = members
    }
}

/// How a word with a text is kept by the plan and the capture, one entry for each text a query
/// gives it (`:drawn-by("A")` and `:drawn-by("B")` are two): the word and the text joined by a
/// character no word holds. Never shown; `word(of:)` and `text(of:)` split it.
enum WordKey {
    private static let separator: Character = "\u{0}"

    static func make(_ word: String, text: String?) -> String {
        text.map { word + String(separator) + $0 } ?? word
    }

    static func word(of key: String) -> String {
        guard let index = key.firstIndex(of: separator) else { return key }
        return String(key[..<index])
    }

    static func text(of key: String) -> String? {
        key.firstIndex(of: separator).map { String(key[key.index(after: $0)...]) }
    }
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
    /// Given the word's text, if it takes one (`QueryWordDeclaration.argument`).
    let prepare: @MainActor (QueryPreparation, String?) -> any Sendable
    let seeds: (@Sendable (any Sendable) -> Set<ShapeID>)?
    let matches: @Sendable (QueryShape, any Sendable) -> QueryVerdict
    let onMain: (@MainActor (AnyShapeRecord, BoardID, any Sendable, QueryMainContext) -> Bool)?
    /// What a row it matched says of why (`ShapeProblem`), on the main actor, for the rows a query
    /// returns alone.
    let problems: (@MainActor (AnyShapeRecord, BoardID, any Sendable, QueryMainContext) -> [ShapeProblem])?
    /// The members it adds to the rows it matched (`memberNames` declares which), worked out off the
    /// main actor as rows are built.
    var rowMembers: (@Sendable (QueryShape, any Sendable) -> [String: JSON])?
    var memberNames: [String] = []
    /// What its argument names that the file no longer holds, off the main actor.
    var absent: (@Sendable (any Sendable) -> [QueryAbsent])?
    /// Whether a query that holds it waits for answers still arriving (`TopologyIndex.isSettling`), as one that
    /// reads edges does: a word whose verdicts a plugin works out later (Validation's, which a rule's model
    /// answers feed).
    var settles = false
}

/// A relation a plugin answers from what it keeps of the file (`:is-a(S)`), type-erased: `related`
/// says, for a shape, the shapes it stands in the relation to directly, with what `prepare` took on
/// the main actor; `seeds` is every shape that has any, which are the only shapes that can match.
struct ContributedFileRelation: Sendable {
    /// Whether a shape is also related to what the shapes it's related to are, however far.
    let transitive: Bool
    /// Whether its argument names types: what `.Name` is refused toward.
    let namesTypes: Bool
    /// The shapes its argument names when `namesTypes` (the types), so a title is a type's when a shape so titled is
    /// among them; nil where the plugin does not say, and any titled shape may be one.
    let argumentShapes: (@Sendable (any Sendable) -> Set<ShapeID>)?
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
    /// The name of the one quoted text the word takes (`:drawn-by("name")`); nil for a word that takes none.
    /// Only a pseudo-class takes one.
    var argument: String?
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
/// (`QueryLanguage.Word`), nor one the engine binds per request (`:scope`, `:scope-start`,
/// `:scope-end`: `QueryBinding`), nor one it knows people reach for (`KnownInventions`), and a
/// relation follows edge types some installed plugin declares.
public enum QueryWords {}

extension QueryWords: KeyedExtensionPoint {
    public typealias Contribution = QueryWordDeclaration
    public static var owner: PluginID { .queries }
    public static func uniqueKeys(of declaration: QueryWordDeclaration, for _: ShapeTarget) -> [AnyHashable] {
        [QueryWordKey(word: declaration.word)]
    }
    public static func summary(of declaration: QueryWordDeclaration, for _: ShapeTarget) -> String {
        var line = "query word :\(declaration.word)"
        if declaration.argument != nil { line += "(\"…\")" }
        if case .pseudoClass(let behavior) = declaration.meaning, !behavior.memberNames.isEmpty {
            line += " members " + behavior.memberNames.joined(separator: ", ")
        }
        return line
    }

    public static func check(_ registry: Registry) throws(RegistryError) {
        for declared in registry.contributions(to: QueryWords.self) {
            let word = declared.value.word
            func refuse(_ reason: String) -> RegistryError {
                .invalid(point: "QueryWords", reason: "\(declared.pluginID) adds :\(word), \(reason)")
            }
            guard isWord(word) else { throw refuse("which isn't lowercase words joined by hyphens") }
            guard Word(rawValue: word) == nil else { throw refuse("one of the language's own words") }
            guard ScopeWord(rawValue: word) == nil else { throw refuse("one of the engine's own words, bound per request") }
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
            if let argument = declared.value.argument, argument.isEmpty || argument.contains(where: { $0.isWhitespace || $0 == "\"" }) {
                throw refuse("which takes a text named \"\(argument)\", a name without spaces or quotes")
            }
            if case .pseudoClass(let behavior) = declared.value.meaning {
                guard (behavior.rowMembers != nil) == !behavior.memberNames.isEmpty else {
                    throw refuse("which declares row members without saying their names, or names without a row members function")
                }
                var seen: Set<String> = []
                for member in behavior.memberNames {
                    guard !member.isEmpty, !member.contains(where: { $0.isWhitespace || $0 == ":" || $0 == "\"" }) else {
                        throw refuse("with the row member \"\(member)\", which isn't a word a row can carry")
                    }
                    guard !QueryRow.ownKeys.contains(member) else { throw refuse("with the row member \(member), which a row has of its own") }
                    guard seen.insert(member).inserted else { throw refuse("with the row member \(member) declared twice") }
                }
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

// MARK: Paths

/// The first member of a path into an attribute that no shape of the file can hold: its place in the
/// path (`index`), and the members that could be there.
public struct QueryPathUnknown: Sendable {
    public var index: Int
    public var known: [String]

    public init(index: Int, known: [String]) {
        self.index = index
        self.known = known
    }
}

/// What a plugin knows of the members an object attribute holds (Types' fields of `fieldValues`), asked
/// of a path a query tests on that attribute, on the main actor as the query is run. Only the sugar makes
/// one (`registrar.queryPathCheck`).
public struct QueryPathChecking: Sendable {
    let attribute: String
    let check: @MainActor ([String], CanvasEditor) -> QueryPathUnknown?
}

/// What says which members an attribute can hold: at most one plugin an attribute.
public enum QueryPathChecks {}

extension QueryPathChecks: KeyedExtensionPoint {
    public typealias Contribution = QueryPathChecking
    public static var owner: PluginID { .queries }
    public static func uniqueKeys(of checking: QueryPathChecking, for _: ShapeTarget) -> [AnyHashable] {
        [QueryPointKey(name: "query path \(checking.attribute)")]
    }
    public static func summary(of checking: QueryPathChecking, for _: ShapeTarget) -> String { "query path \(checking.attribute)" }

    /// The attribute is a word a query can write bare, in brackets.
    public static func check(_ registry: Registry) throws(RegistryError) {
        for checking in registry.contributions(to: QueryPathChecks.self) where !isIdentifier(checking.value.attribute) {
            throw .invalid(point: "QueryPathChecks", reason: "\(checking.pluginID) checks paths into the attribute \"\(checking.value.attribute)\", which a query can't write: a letter or _, then letters, digits, - and _")
        }
    }
}

// MARK: Facts for `--ask`

/// A block a translator of English into queries is sent about the file, under a tag of its own (`fields`): made on
/// the main actor as the question is asked, bounded by its plugin. Never one of the request's own tags
/// (`AskFacts.reservedTags`). Only the sugar makes one (`registrar.queryAskFact`).
public struct QueryAskFact: Sendable {
    public let tag: String
    let text: @MainActor (CanvasEditor, _ question: String) -> String

    /// The block's text for `question`, on the main actor; empty for nothing to say (the block is left out).
    @MainActor public func text(for editor: CanvasEditor, question: String) -> String { text(editor, question) }
}

/// What tells a translator more of the file: one plugin a tag.
public enum QueryAskFacts {}

/// What the request to a translator already uses as tags (`AskRequest.Tag` is this one: written here, never as
/// strings, because a module may not write another module's plugin id as a literal and `titles` is Titles').
public enum AskFacts {
    public enum Tag: String, CaseIterable, Sendable {
        case question, vocabulary, board, titles, error
    }

    public static let reservedTags = Set(Tag.allCases.map(\.rawValue))
}

extension QueryAskFacts: KeyedExtensionPoint {
    public typealias Contribution = QueryAskFact
    public static var owner: PluginID { .queries }
    public static func uniqueKeys(of fact: QueryAskFact, for _: ShapeTarget) -> [AnyHashable] { [QueryPointKey(name: "ask fact \(fact.tag)")] }
    public static func summary(of fact: QueryAskFact, for _: ShapeTarget) -> String { "ask fact \(fact.tag)" }

    /// A tag is a word, and none of the request's own.
    public static func check(_ registry: Registry) throws(RegistryError) {
        for fact in registry.contributions(to: QueryAskFacts.self) {
            let tag = fact.value.tag
            guard !tag.isEmpty, tag.allSatisfy({ $0.isLowercase && $0.isLetter }) else {
                throw .invalid(point: "QueryAskFacts", reason: "\(fact.pluginID) tells --ask something under the tag \"\(tag)\", which is no word: lower-case letters")
            }
            guard !AskFacts.reservedTags.contains(tag) else {
                throw .invalid(point: "QueryAskFacts", reason: "\(fact.pluginID) tells --ask something under the tag \"\(tag)\", which the request uses itself")
            }
        }
    }
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

// MARK: Sugar (what the plugins that give words write)

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

    /// What the parts of `kind`'s shapes are called, for queries: `name` is given a shape's record and one of its parts, read
    /// anywhere (off the main actor, as a query's rows are made), and says the part's whole name, as `PartedShape.parts(of:)`
    /// does ("customer_id"); nil for a part the record doesn't hold. A connection's end bound to a part says it (`QueryEnd.row`).
    /// One plugin a kind: the one that defines it.
    public mutating func queryPartNames(of kind: ShapeKind, _ name: @escaping @Sendable (AnyShapeRecord, PartID) -> String?) {
        contribute(QueryPartNaming(name: name), to: QueryPartNames.self, for: .kind(kind))
    }

    /// What a board is called while its owner has no name, per board-owning kind, asked once per
    /// kind as the vocabulary is built. A board's name is then its owner's name (the names point),
    /// else this, else the kind's label (`registry.label(of:)`): Boards' own rule. At most one
    /// plugin names boards.
    public mutating func queryBoardNames(placeholder: @escaping @MainActor (ShapeKind, Registry) -> String?) {
        contribute(QueryBoardNaming(placeholder: placeholder), to: QueryBoardNames.self)
    }

    /// What an object attribute's members can be, for a query's `[attribute.a.b]`: `check` is given the
    /// path's members and the editor on the main actor, and says the first member no shape of the file can
    /// hold (nil: nothing to say), so the answer warns `unknown_field`. At most one plugin an attribute.
    public mutating func queryPathCheck(attribute: String, _ check: @escaping @MainActor ([String], CanvasEditor) -> QueryPathUnknown?) {
        contribute(QueryPathChecking(attribute: attribute, check: check), to: QueryPathChecks.self)
    }

    /// A block `--ask` sends about the file under `tag` (`<tag>`, the text, `</tag>`), after the titles: `text` is
    /// given the editor and the question on the main actor as the question is asked, and is bounded by the plugin
    /// (an empty text leaves the block out). One plugin a tag, none of the request's own.
    public mutating func queryAskFact(tag: String, _ text: @escaping @MainActor (CanvasEditor, _ question: String) -> String) {
        contribute(QueryAskFact(tag: tag, text: text), to: QueryAskFacts.self)
    }

    /// `:word`, a pseudo-class with no argument, meaning `summary` ("the person has it selected"),
    /// as `example` uses it. `prepare` runs on the main actor in the turn the query takes up the file
    /// (take what's needed there, O(1) or O(what it holds)); `seeds`, the only shapes that can
    /// match, if it knows them; `matches` anywhere, for each shape a query tests; and `onMain` for a
    /// shape `matches` leaves to the main actor (`.onMain`), asked in slices about the shape as the
    /// app has it then. It reads the editor (`QueryReads.editor`): a plan that holds it isn't
    /// `readsOnlyTheFile`. `problems` says what a row it matched has to answer for (a `ShapeProblem`
    /// each: a field and why), asked on the main actor in slices of only the rows a query returns,
    /// and listed on those rows as `problems`. `settles`: a query that holds it waits, before it takes up
    /// the file, while answers are still arriving (`TopologyIndex.isSettling`, `QueryRequest.settle`), as one
    /// that reads edges does, for a word whose verdicts a plugin works out later.
    public mutating func queryPseudoClass<Prepared: Sendable>(
        _ word: String, _ summary: String, example: String,
        prepare: @escaping @MainActor (QueryPreparation) -> Prepared,
        seeds: (@Sendable (Prepared) -> Set<ShapeID>)? = nil,
        matches: @escaping @Sendable (QueryShape, Prepared) -> QueryVerdict,
        onMain: (@MainActor (AnyShapeRecord, BoardID, Prepared, QueryMainContext) -> Bool)? = nil,
        problems: (@MainActor (AnyShapeRecord, BoardID, Prepared, QueryMainContext) -> [ShapeProblem])? = nil,
        settles: Bool = false
    ) {
        contributePseudoClass(word, summary, example: example, argument: nil, reads: .editor, prepare: { preparation, _ in prepare(preparation) },
                              seeds: seeds, matches: matches, onMain: onMain, problems: problems, settles: settles)
    }

    /// As above, for a word that takes one quoted text, `:word("…")` (`argument` is its name, "name", as the
    /// vocabulary says it): `prepare` is given the text too, and `seeds` and `matches` see what it made (keep the
    /// text in it if they need it). A query may use the word with several texts, each prepared on its own.
    public mutating func queryPseudoClass<Prepared: Sendable>(
        _ word: String, _ summary: String, example: String, argument: String,
        prepare: @escaping @MainActor (QueryPreparation, String) -> Prepared,
        seeds: (@Sendable (Prepared) -> Set<ShapeID>)? = nil,
        matches: @escaping @Sendable (QueryShape, Prepared) -> QueryVerdict,
        onMain: (@MainActor (AnyShapeRecord, BoardID, Prepared, QueryMainContext) -> Bool)? = nil,
        problems: (@MainActor (AnyShapeRecord, BoardID, Prepared, QueryMainContext) -> [ShapeProblem])? = nil,
        settles: Bool = false
    ) {
        contributePseudoClass(word, summary, example: example, argument: argument, reads: .editor,
                              prepare: { preparation, text in prepare(preparation, text ?? "") },
                              seeds: seeds, matches: matches, onMain: onMain, problems: problems, settles: settles)
    }

    /// As above, for a word whose verdict reads only the file (`reads: .file`): `prepare` is given
    /// the file as the query takes it up and the registry, and no editor, so it can't read anything
    /// else; and it has no `onMain`, whose context lends the editor. What a plan with such words
    /// alone says of itself (`QueryPlan.readsOnlyTheFile`) is true because of it.
    ///
    /// `rowMembers` adds members, the keys `members` declares (a key a row has of its own is a registry
    /// error), to each row the word matched, worked out off the main actor as the rows are built, flat
    /// beside the row's own and kept by `--brief` and `--fields`; where several words give one, the first
    /// (in the order of the words' names) keeps it. `absent` lists what its argument names that the file no
    /// longer holds, for an answer to say (`QueryResult.absent`), whatever the rows.
    public mutating func queryPseudoClass<Prepared: Sendable>(
        _ word: String, _ summary: String, example: String, reads _: QueryFileReads,
        prepare: @escaping @MainActor (QueryFilePreparation) -> Prepared,
        seeds: (@Sendable (Prepared) -> Set<ShapeID>)? = nil,
        matches: @escaping @Sendable (QueryShape, Prepared) -> QueryVerdict,
        members: [String] = [],
        rowMembers: (@Sendable (QueryShape, Prepared) -> [String: JSON])? = nil,
        absent: (@Sendable (Prepared) -> [QueryAbsent])? = nil
    ) {
        contributePseudoClass(word, summary, example: example, argument: nil, reads: .file, prepare: { preparation, _ in prepare(preparation.file) },
                              seeds: seeds, matches: matches, onMain: nil, problems: nil, settles: false,
                              members: members, rowMembers: rowMembers, absent: absent)
    }

    /// As the file form above, for a word that takes one quoted text, `:word("…")`: `argument` is its name,
    /// "name", `prepare` is given the text, and `seeds`, `matches`, `rowMembers` and `absent` see what it made.
    /// Written `:drawn-by("Plans")`: exactly one string (`bad_argument` for none, another sort of thing or
    /// two). A query may use it with several texts, each prepared, seeded and answered on its own.
    public mutating func queryPseudoClass<Prepared: Sendable>(
        _ word: String, _ summary: String, example: String, argument: String, reads _: QueryFileReads,
        prepare: @escaping @MainActor (QueryFilePreparation, String) -> Prepared,
        seeds: (@Sendable (Prepared) -> Set<ShapeID>)? = nil,
        matches: @escaping @Sendable (QueryShape, Prepared) -> QueryVerdict,
        members: [String] = [],
        rowMembers: (@Sendable (QueryShape, Prepared) -> [String: JSON])? = nil,
        absent: (@Sendable (Prepared) -> [QueryAbsent])? = nil
    ) {
        contributePseudoClass(word, summary, example: example, argument: argument, reads: .file,
                              prepare: { preparation, text in prepare(preparation.file, text ?? "") },
                              seeds: seeds, matches: matches, onMain: nil, problems: nil, settles: false,
                              members: members, rowMembers: rowMembers, absent: absent)
    }

    private mutating func contributePseudoClass<Prepared: Sendable>(
        _ word: String, _ summary: String, example: String, argument: String?, reads: QueryReads,
        prepare: @escaping @MainActor (QueryPreparation, String?) -> Prepared,
        seeds: (@Sendable (Prepared) -> Set<ShapeID>)?,
        matches: @escaping @Sendable (QueryShape, Prepared) -> QueryVerdict,
        onMain: (@MainActor (AnyShapeRecord, BoardID, Prepared, QueryMainContext) -> Bool)?,
        problems: (@MainActor (AnyShapeRecord, BoardID, Prepared, QueryMainContext) -> [ShapeProblem])?,
        settles: Bool,
        members: [String] = [],
        rowMembers: (@Sendable (QueryShape, Prepared) -> [String: JSON])? = nil,
        absent: (@Sendable (Prepared) -> [QueryAbsent])? = nil
    ) {
        let erasedPrepare: @MainActor (QueryPreparation, String?) -> any Sendable = { prepare($0, $1) }
        let erasedMatches: @Sendable (QueryShape, any Sendable) -> QueryVerdict = { shape, prepared in matches(shape, prepared as! Prepared) }
        var erasedSeeds: (@Sendable (any Sendable) -> Set<ShapeID>)?
        if let seeds { erasedSeeds = { prepared in seeds(prepared as! Prepared) } }
        var erasedOnMain: (@MainActor (AnyShapeRecord, BoardID, any Sendable, QueryMainContext) -> Bool)?
        if let onMain {
            erasedOnMain = { record, board, prepared, context in onMain(record, board, prepared as! Prepared, context) }
        }
        var erasedProblems: (@MainActor (AnyShapeRecord, BoardID, any Sendable, QueryMainContext) -> [ShapeProblem])?
        if let problems {
            erasedProblems = { record, board, prepared, context in problems(record, board, prepared as! Prepared, context) }
        }
        var pseudoClass = ContributedPseudoClass(reads: reads, prepare: erasedPrepare, seeds: erasedSeeds, matches: erasedMatches,
                                                 onMain: erasedOnMain, problems: erasedProblems, settles: settles)
        if let rowMembers { pseudoClass.rowMembers = { shape, prepared in rowMembers(shape, prepared as! Prepared) } }
        pseudoClass.memberNames = members
        if let absent { pseudoClass.absent = { prepared in absent(prepared as! Prepared) } }
        var declaration = QueryWordDeclaration(word: word, summary: summary, example: example, meaning: .pseudoClass(pseudoClass))
        declaration.argument = argument
        contribute(declaration, to: QueryWords.self)
    }

    /// `:word`, the person's selection, meaning `summary` ("the person has it selected"), as
    /// `example` uses it: the shapes `selected` lists (on the main actor, in the turn the query takes
    /// up the file), which are its only matches, and what `--ask` tells the model is selected
    /// (`QueryState.whereThePersonIs`), in that order. At most one plugin says what's selected.
    public mutating func querySelection(_ word: String, _ summary: String, example: String,
                                        selected: @escaping @MainActor (CanvasEditor) -> [ShapeID]) {
        let pseudoClass = ContributedPseudoClass(
            reads: .editor,
            prepare: { preparation, _ in
                let ids = selected(preparation.editor)
                return SelectedShapes(ids: ids, set: Set(ids))
            },
            seeds: { ($0 as! SelectedShapes).set },
            matches: { shape, taken in (taken as! SelectedShapes).set.contains(shape.record.id) ? .yes : .no },
            onMain: nil, problems: nil)
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
        transitive: Bool, namesTypes: Bool = false, argumentShapes: (@Sendable (Prepared) -> Set<ShapeID>)? = nil,
        prepare: @escaping @MainActor (QueryFilePreparation) -> Prepared,
        seeds: @escaping @Sendable (Prepared) -> Set<ShapeID>,
        related: @escaping @Sendable (ShapeID, Prepared) -> [ShapeID]
    ) {
        let erased: (@Sendable (any Sendable) -> Set<ShapeID>)?
        if let argumentShapes { erased = { (prepared: any Sendable) -> Set<ShapeID> in argumentShapes(prepared as! Prepared) } } else { erased = nil }
        let relation = ContributedFileRelation(
            transitive: transitive, namesTypes: namesTypes, argumentShapes: erased,
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
