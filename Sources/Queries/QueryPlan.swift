import Canvas
import CanvasRPC
import Foundation
import QueryLanguage
import Topology

/// A query resolved against the app: every kind, attribute, literal, edge type and word checked
/// and bound, ready to be answered anywhere (`Sendable`). Titles and ids are left for the answer,
/// which checks them against the file as it takes it up. Made by `QueryState.check(_:)`, or by
/// `init(resolving:text:vocabulary:presentEdgeTypes:kindOf:)` from a vocabulary alone.
///
/// Its nodes are numbered in the order they're made, each once, for an answer's memo: what a node
/// matched is worked out once per query, however often the tree reaches it.
public struct QueryPlan: Sendable {
    /// The query as sent.
    public let text: String
    /// The query as the language writes it (`SelectorList.canonical`): what an answer says it ran.
    public let canonical: String
    /// What it matches: the union of its selectors, each shape once.
    let root: PlanList
    /// What answering it reads, so the answer takes up only that.
    let uses: PlanUses
    /// How many nodes and lists it has: their ids are `0..<nodeCount`.
    let nodeCount: Int
    /// The title heads (`.title` nodes) that stand where a container goes (the left of a space or
    /// `>`, in `:inside()`, what `:has()` is on): the answer refuses one whose shapes are all of kinds
    /// that hold no shapes (`cannot_contain`), as resolution refuses such a kind or id.
    let containerTitles: Set<PlanNodeID>

    /// The paths into an attribute's members the query tests, each once, in the order met: what the answer asks
    /// the plugin that knows the attribute's members whether any shape can hold (`QueryPathChecks`).
    var paths: [(attribute: String, members: [String])] { uses.paths.map { ($0.attribute, $0.members) } }

    /// The words in the plan whose verdict reads the editor (`QueryReads.editor`), in the order the
    /// query uses them, each once, as the query writes them: a plugin's word that says so
    /// (`:selected`, `:invalid`), `:current-board`, and a text read through a format that reads the
    /// editor, as `:contains` or the attribute (`[text]`) that reads it. The words an answer may
    /// depend on beyond the file.
    public var editorWords: [String] { uses.editorWords }

    /// Whether every word in it reads only the file (`editorWords` is empty): what it matches is a
    /// function of the file as the query takes it up, whoever asks and whatever they have selected
    /// or shown, so an answer to it stays an answer until the file changes. A word bound per request
    /// (`usesScope`) is none that reads the editor: the answer is a function of the file and of the
    /// shape bound.
    public var readsOnlyTheFile: Bool { uses.editorWords.isEmpty }

    /// Whether the plan names a shape, by title or by id: what `QueryState.checkNames(_:)` checks.
    var namesShapes: Bool {
        var names = false
        root.forEachNode { node in
            switch node.op {
            case .title, .id: names = true
            default: break
            }
        }
        return names
    }

    /// Whether the plan has an edge word (`:edge-to`, a relation, `:dangling`, and the others, and
    /// `:scope-start` and `:scope-end`, which are the ends of a connection; not `:scope`): the edge
    /// view a request asks for, and a wait for answers still arriving (`QueryRequest.settle`),
    /// matter to it. A plan without one never reads edges.
    public var readsEdges: Bool { uses.edges }

    /// Whether a query of it waits for answers still arriving before it takes up the file (`QueryRequest.settle`):
    /// one that reads edges, and one that holds a word that says it waits (Validation's, whose verdicts a plugin
    /// may still be working out).
    public var waitsForAnswers: Bool { uses.edges || uses.settles }
}

/// A node's number in its plan.
struct PlanNodeID: Hashable, Sendable {
    let rawValue: Int
}

/// Shapes any of whose nodes match (a selector list's OR; one node for most).
struct PlanList: Sendable {
    let id: PlanNodeID
    let items: [PlanNode]
}

/// A test of shapes, numbered.
struct PlanNode: Sendable {
    let id: PlanNodeID
    let op: PlanOp
    /// Where in the query it comes from, for what the answer refuses (an unknown title, a container
    /// that holds nothing); nil for what no one part says (a compound's AND).
    let span: QuerySpan?
}

/// What a node tests.
indirect enum PlanOp: Sendable {
    /// Every shape the query ranges over.
    case all
    /// Shapes of these kinds.
    case kinds(Set<ShapeKind>)
    /// Shapes whose name, folded, is this (folded by the names point's `fold`); `written` as the
    /// query wrote it, for a refusal.
    case title(folded: String, written: String)
    /// The shape with this id.
    case id(ShapeID)
    /// An attribute's test, read per kind (`AttributeReader`): a shape matches when its kind has a
    /// reader whose test holds for its value.
    case attribute(name: String, readers: [AttributeReader])
    /// The name or any text of its attributes holds this, ignoring case (`:contains`).
    case contains(String)
    case not(PlanList)
    case `is`(PlanList)
    /// Inside a shape the list matches, at any depth (`:inside`).
    case inside(PlanList)
    /// Something the items match is inside it: at any depth, or directly (`child`).
    case has([PlanHasItem])
    /// Directly inside a shape the list matches: in it, or on its board in no container (`A > B`'s
    /// B).
    case parentIn(PlanList)
    /// Inside a shape the list matches, at any depth (`A B`'s B).
    case ancestorIn(PlanList)
    /// Inside nothing: on the file's top board, in no container.
    case topLevel
    /// On the board the file's window shows, as the query started.
    case currentBoard
    /// A word bound per request: the shape the request is bound to, or where its connection starts or
    /// ends (`QueryMatchRequest.scope`). The plan holds the word, never the id.
    case scope(ScopeWord)
    /// One of the language's edge words (`:edge-to` … `:between`): its anchors (`second` only for
    /// `:between`) and the edge types it follows.
    case edges(word: Word, anchor: PlanList, second: PlanList?, types: PlanEdgeTypes)
    /// A plugin's relation answered from a fact of the file (`:is-a(S)`): the result is related to a
    /// shape the anchor matches, as the plugin's `related` says, however far when it's transitive.
    case fileRelation(word: String, anchor: PlanList)
    /// A plugin's relation (`:mentions(S)`): the result → S (`.outgoing`) or S → the result.
    case relation(word: String, anchor: PlanList, types: PlanEdgeTypes, direction: EdgeDirection)
    /// Carries an edge of these types whose far end isn't a shape the query ranges over.
    case dangling(PlanEdgeTypes)
    /// A plugin's pseudo-class (`:selected`), by its word: its behavior is the vocabulary's.
    case pseudo(word: String)
    /// Every node matches: a compound's head and filters, cheapest first (`PlanCost`).
    case and([PlanNode])
}

/// One item of `:has(…)`.
struct PlanHasItem: Sendable {
    /// `> S`: directly inside the subject; else at any depth.
    let child: Bool
    let node: PlanNode
}

/// How an attribute is read for some kinds, and the test its value must pass.
struct AttributeReader: Sendable {
    enum Source: Sendable, Equatable {
        /// The property of this shape in the kind's schema (`record.propertiesJSON`), text read
        /// through its media type's format, if one.
        case property(KindSchema.PropertyShape)
        /// The shape's name, through the names point (named or derived).
        case names
    }

    let kinds: Set<ShapeKind>
    let source: Source
    let test: TypedTest
}

/// An attribute's test, its literal read by the property's type.
struct TypedTest: Sendable, Equatable {
    enum Comparison: Sendable, Equatable {
        /// `[a]`: a value that says something (true; text, a list or an object not empty; a number
        /// or a date there at all).
        case present
        /// `[a=""]` on text: no value, absent or empty (for a name, none).
        case absent
        /// `=`: the value (a day: any instant of it).
        case equals(PlanValue)
        /// `^=`, `$=`, `*=`: text starts with, ends with, holds.
        case prefix(String), suffix(String), substring(String)
        /// `~=` on text: one of its whitespace-separated words is this.
        case word(String)
        /// `|=`: the text is this, or starts with it and a hyphen.
        case dash(String)
        /// `<`, `<=`, `>`, `>=` on a number or a date (a day: before its start, before its end,
        /// from its end, from its start).
        case less(PlanValue), lessOrEqual(PlanValue), greater(PlanValue), greaterOrEqual(PlanValue)
        /// `~=` on a list: an item equals this.
        case hasItem(PlanValue)
        /// `[a.b]` and the rest: what's at the members inside the attribute's object, typed by the
        /// value found there (`PathTest`).
        case path(PathTest)
    }

    let comparison: Comparison
    /// The `i` flag: text compared ignoring case (no diacritics folded).
    let ignoringCase: Bool
}

/// A literal as its property reads it.
enum PlanValue: Sendable, Equatable {
    case text(String)
    case number(Double)
    case bool(Bool)
    /// A whole UTC day, from this instant (its midnight) to the next day's.
    case day(Date)
    /// An instant.
    case instant(Date)
    /// Any other JSON (an item of a list of any JSON).
    case json(JSONValue)
}

/// The edge types a word follows: every type (no list), or exactly those a list resolved to, each
/// type's descendants already taken in unless it said `only`.
struct PlanEdgeTypes: Sendable, Equatable {
    /// Nil: every type.
    let types: Set<EdgeTypeID>?

    static let all = PlanEdgeTypes(types: nil)

    /// As Topology filters: `.all`, or `.only` the set.
    var filter: EdgeTypeFilter { types.map { .only($0) } ?? .all }

    var planDescription: String {
        types.map { "(\($0.map(\.rawValue).sorted().joined(separator: "|")))" } ?? "(every type)"
    }
}

/// What answering a plan reads, so the answer takes up only that from the app.
/// A path a query tests into an attribute: its members, as written.
struct PlanPath: Sendable, Equatable {
    let attribute: String
    let members: [String]
}

struct PlanUses: Sendable, Equatable {
    /// Titles (a title head, the names point's attribute): the names point.
    var names = false
    /// The attributes it tests, by name.
    var attributes: Set<String> = []
    /// The media types whose formats it reads text through (`prepare`d as it takes up the file).
    var textFormats: Set<String> = []
    /// Plugins' pseudo-classes it uses (`prepare`d as it takes up the file).
    var pseudoClasses: Set<String> = []
    /// Topology's edges.
    var edges = false
    /// A word that waits for answers still arriving, as edges do (`queryPseudoClass(settles:)`).
    var settles = false
    /// Topology's containment.
    var containment = false
    /// The board the window shows.
    var currentBoard = false
    /// Text, which a shape being typed into holds as the board has it, and may still change
    /// (attributes, `:contains`): the answer warns about it (`editing`).
    var readsText = false
    /// The words that read the editor (`QueryPlan.editorWords`), in the order they're met, each once.
    var editorWords: [String] = []
    /// Where it uses a word bound per request (`:scope`, `:scope-start`, `:scope-end`), in the order
    /// they're met, each use once: what the asker must bind (`QueryPlan.usesScope`).
    var scope: [PlanScopeUse] = []
    /// The paths into an attribute's members it tests (`[fieldValues.a.b]`), each once, as written.
    var paths: [PlanPath] = []

    /// Notes that the plan tests a path.
    mutating func notePath(attribute: String, members: [String]) {
        let path = PlanPath(attribute: attribute, members: members)
        if !paths.contains(path) { paths.append(path) }
    }

    /// Notes that the plan has `word`, which reads the editor.
    mutating func noteEditorWord(_ word: String) {
        if !editorWords.contains(word) { editorWords.append(word) }
    }
}

// MARK: Cost

/// How early a compound's node runs: AND commutes, so what narrows most for least goes first.
enum PlanCost: Int, Comparable {
    /// Ids, titles, a word's seeds: a few shapes, found directly.
    case found
    /// Kinds, every shape: a walk of the shapes the query ranges over.
    case kinds
    /// Sets taken up with the file: the top board, the board shown.
    case captured
    /// Topology's containment and edges, and what's worked out of other nodes.
    case structure
    /// Attributes and text, read per shape.
    case read
    /// A word the main actor answers.
    case main

    static func < (a: PlanCost, b: PlanCost) -> Bool { a.rawValue < b.rawValue }
}

// MARK: Reading a plan

extension QueryPlan: CustomStringConvertible {
    /// The plan as a tree, a node a line, each indented under the one it's in: what tests and
    /// debugging read. Its ids and spans are left out, so two queries that mean the same thing
    /// print the same (`[rank=3]` and `[rank="3"]`).
    public var description: String {
        var lines: [String] = []
        func list(_ items: PlanList, _ depth: Int) {
            if items.items.count == 1 {
                node(items.items[0], depth)
            } else {
                lines.append(String(repeating: "  ", count: depth) + "any of")
                for item in items.items { node(item, depth + 1) }
            }
        }
        func node(_ planned: PlanNode, _ depth: Int) {
            let indent = String(repeating: "  ", count: depth)
            switch planned.op {
            case .all: lines.append(indent + "every shape")
            case .kinds(let kinds): lines.append(indent + "kind " + kinds.map(\.rawValue).sorted().joined(separator: "|"))
            case .title(let folded, _):
                lines.append(indent + "titled " + quotedForPlan(folded) + (containerTitles.contains(planned.id) ? ", a container" : ""))
            case .id(let id): lines.append(indent + "id " + id.description)
            case .attribute(let name, let readers):
                for reader in readers {
                    var name = name
                    if case .path(let path) = reader.test.comparison { name += "." + path.members.joined(separator: ".") }
                    lines.append(indent + "[\(name)] of \(reader.kinds.map(\.rawValue).sorted().joined(separator: "|"))"
                                 + " \(reader.source.planDescription): \(reader.test.planDescription)")
                }
            case .contains(let text): lines.append(indent + "contains " + quotedForPlan(text))
            case .not(let inner):
                lines.append(indent + "not")
                list(inner, depth + 1)
            case .is(let inner):
                lines.append(indent + "is")
                list(inner, depth + 1)
            case .inside(let inner):
                lines.append(indent + "inside")
                list(inner, depth + 1)
            case .has(let items):
                lines.append(indent + "has")
                for item in items {
                    if item.child {
                        lines.append(indent + "  directly")
                        node(item.node, depth + 2)
                    } else {
                        node(item.node, depth + 1)
                    }
                }
            case .parentIn(let inner):
                lines.append(indent + "directly inside")
                list(inner, depth + 1)
            case .ancestorIn(let inner):
                lines.append(indent + "inside, at any depth")
                list(inner, depth + 1)
            case .topLevel: lines.append(indent + "top level")
            case .currentBoard: lines.append(indent + "on the board shown")
            case .scope(let word): lines.append(indent + word.written)
            case .edges(let word, let anchor, let second, let types):
                lines.append(indent + "\(word.rawValue) \(types.planDescription)")
                list(anchor, depth + 1)
                if let second { list(second, depth + 1) }
            case .relation(let word, let anchor, let types, let direction):
                lines.append(indent + "\(word) \(direction == .incoming ? "from" : "to") \(types.planDescription)")
                list(anchor, depth + 1)
            case .fileRelation(let word, let anchor):
                lines.append(indent + "\(word) of the file")
                list(anchor, depth + 1)
            case .dangling(let types): lines.append(indent + "dangling \(types.planDescription)")
            case .pseudo(let word): lines.append(indent + ":" + word)
            case .and(let nodes):
                lines.append(indent + "all of")
                for inner in nodes { node(inner, depth + 1) }
            }
        }
        list(root, 0)
        return lines.joined(separator: "\n")
    }
}

extension AttributeReader.Source {
    var planDescription: String {
        switch self {
        case .names: "name"
        case .property(let shape): shape.planDescription
        }
    }
}

extension KindSchema.PropertyShape {
    var planDescription: String {
        switch self {
        case .string(let format, let mediaType, let choices):
            "text" + (format.map { " \($0)" } ?? "") + (mediaType.map { " \($0)" } ?? "") + (choices.map { " \($0.joined(separator: "|"))" } ?? "")
        case .number(let integer): integer ? "integer" : "number"
        case .boolean(let fallback): "true|false (\(fallback) when absent)"
        case .array(let items): "list of \(items.planDescription)"
        case .object: "object"
        case .json: "JSON"
        }
    }
}

extension TypedTest {
    var planDescription: String {
        let flag = ignoringCase ? " ignoring case" : ""
        return switch comparison {
        case .present: "present"
        case .absent: "absent or empty"
        case .equals(let value): "= \(value.planDescription)\(flag)"
        case .prefix(let text): "starts with \(quotedForPlan(text))\(flag)"
        case .suffix(let text): "ends with \(quotedForPlan(text))\(flag)"
        case .substring(let text): "holds \(quotedForPlan(text))\(flag)"
        case .word(let text): "has the word \(quotedForPlan(text))\(flag)"
        case .dash(let text): "is or starts \(quotedForPlan(text + "-"))\(flag)"
        case .less(let value): "< \(value.planDescription)"
        case .lessOrEqual(let value): "<= \(value.planDescription)"
        case .greater(let value): "> \(value.planDescription)"
        case .greaterOrEqual(let value): ">= \(value.planDescription)"
        case .hasItem(let value): "has the item \(value.planDescription)\(flag)"
        case .path(let path): path.planDescription
        }
    }
}

extension PlanValue {
    var planDescription: String {
        switch self {
        case .text(let text): quotedForPlan(text)
        case .number(let number): KindSchema.number(number)
        case .bool(let flag): "\(flag)"
        case .day(let start): "the day " + start.formatted(.iso8601.year().month().day())
        case .instant(let instant): instant.formatted(.iso8601)
        case .json(let json): "JSON \(json)"
        }
    }
}

/// Text in double quotes, `"` and `\` escaped: for a plan's description.
func quotedForPlan(_ text: String) -> String {
    "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}
