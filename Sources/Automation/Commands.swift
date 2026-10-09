import Canvas
import CanvasRPC
import CoreGraphics
import DrawScript
import Foundation

// The command line's own commands: what any board can do whatever's installed. `draw` puts shapes
// on a board from a script; `kinds` says what a script can draw, and with what. Other plugins add
// theirs with `registrar.automationCommand`.

public struct AutomationPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .automation }

    #if DEBUG
    /// How many times a run has read the names of every board of a file in this process, debug
    /// builds only: a script that names no shape, in its statements or its texts, reads none, and
    /// one that does reads them once.
    @MainActor public internal(set) static var fileNamesRead = 0
    /// How many boards' arrows a run has read to choose the board it draws on, debug builds only: only
    /// an edge between two boards looks (for itself, drawn through a stand-in), each board once a run.
    @MainActor public internal(set) static var boardConnectionsRead = 0
    #endif

    public func register(into registrar: inout PluginRegistrar) {
        let canvas = RPC.commandName
        registrar.automationCommand(
            "draw", "Draw shapes on a board, and connect them, from a script.",
            discussion: """
                A script is one statement a line: a shape (its kind, its title in double quotes, its attributes and \
                where it goes against other shapes: right of "API"), an edge (edge "API" -> "DB"), a delete, or a \
                style. A statement about a title the board has changes that shape; one about a title it doesn't \
                makes a new one. It's applied all at once, as one step of the app's undo, or not at all, and the \
                result says what each statement did and where its shape landed. A title names a shape on any board \
                of the file (the one the window shows first), and in "X" puts a shape on the board X holds (a \
                subboard's), or in X, where X holds shapes on its own board (a frame's): a run draws on the board \
                what it names is on, else the one the window shows, without \
                moving the window (the result's on says which). An edge to a shape on another board goes into a \
                reference to it, put beside the shape on this board, when the shape is public (via: reference asks \
                for one on a single board too). The language is taught \
                by the repository's canvas skill (.claude/skills/canvas); `\(canvas) kinds` lists what can be drawn, \
                and with what.
                """,
            params: DrawParams.self, positionals: ["script"],
            // No kind by name: this plugin knows none, and the kinds are whatever's installed.
            examples: [
                CommandExample(#"\#(canvas) draw '<kind> "API"'"#, "A shape titled API, as near the middle of the view as there's room."),
                CommandExample(#"\#(canvas) draw '<kind> "DB" below "API"'"#, "Another, below it."),
                CommandExample(#"\#(canvas) draw 'edge "API" -> "DB"'"#, "Connect the two."),
                CommandExample(#"\#(canvas) draw 'delete "DB"'"#, "Delete one, and what connects to it."),
                CommandExample(#"\#(canvas) draw '<kind> "Cache" in "Backend"'"#, "A shape on the board of the subboard titled Backend."),
                CommandExample("\(canvas) draw --dry-run - < plan.txt", "Read the script from standard input, and say what it would do."),
            ]
        ) { params, context throws(AutomationError) in
            try draw(params, in: context)
        }
        registrar.automationCommand(
            "show", "Show another board of the file in its window: a subboard's, by its title, or the top one.",
            discussion: """
                Moves the window, as opening a subboard does; it changes nothing on any board, and the board left is \
                a step of Go › Back. Drawing doesn't need it: a script draws on the board its titles are on, and \
                in "X" puts a shape on the board X holds.
                """,
            params: ShowParams.self, positionals: ["shape"],
            examples: [
                CommandExample(#"\#(canvas) show "Q3""#, "Show the board the shape titled Q3 holds."),
                CommandExample("\(canvas) show --root", "Show the board at the top of the file."),
            ]
        ) { params, context throws(AutomationError) in
            try show(params, in: context)
        }
        registrar.automationCommand(
            "kinds", "List the kinds of shape the app has: what a script can draw, and with what.",
            discussion: """
                For each kind: whether a script can draw it (and why not), whether its shapes have titles of their own \
                (named), worked out from them (derived) or none, the size its tool places, what its shapes hold for \
                in "X" to name (a board of its own, or shapes on the board it's on), each attribute a script can \
                write and what it takes, and the sides an edge may leave it by, with what it may carry from each. \
                --schema adds each kind's JSON Schema (draft 2020-12): every property, what it takes, its default and \
                its bounds.
                """,
            scope: .app, params: ListKinds.self, positionals: ["kind"],
            examples: [
                CommandExample("\(canvas) kinds", "Every kind, and what a script can write on it."),
                CommandExample("\(canvas) kinds <kind> --schema", "One kind, with its JSON Schema."),
            ]
        ) { params, context throws(AutomationError) in
            try kinds(params, in: context.registry)
        }
        registrar.automationCommand(
            "measure", "Say how big a draw script's shapes would be, and what they reach, without drawing it.",
            discussion: """
                Takes a script as `draw` does and answers for each shape statement the size draw would make it \
                (a note as tall as its text at its width), how far its title's pill and chips reach above it, and, \
                for each edge that says via:, the size of the reference draw would put beside its start; and the \
                constants placement is done with (every named gap, the step between references, how far in a \
                frame's content sits, the smallest sizes). Where shapes go is ignored. It reads nothing on a board, \
                changes nothing and opens no undo step, so a tool can lay shapes out before it draws them.
                """,
            scope: .app, params: MeasureParams.self, positionals: ["script"],
            examples: [
                CommandExample("\(canvas) measure - < plan.txt", "Read the script from standard input, and say how big each shape would be."),
            ]
        ) { params, context throws(AutomationError) in
            try measure(params, in: context)
        }
    }
}

// MARK: kinds

struct ListKinds: SchemaDefined {
    static let properties = Properties<ListKinds>(title: "kinds") {
        Property("kind", \.kind).description("Just this kind.")
        Property("schema", \.schema).description("With each kind's JSON Schema.")
    }
    var kind: String?
    var schema = false
}

/// A kind, as `kinds` lists it: the language's vocabulary for it.
struct KindSummary: Encodable {
    let kind: String
    let title: String?
    /// The tool named for it (`ToolID(placing:)`), by its label: the one that places it, or draws
    /// it by hand.
    let tool: String?
    /// Whether a script can draw it, and why not.
    let drawable: Bool
    let why: String?
    /// Whether its shapes have titles: `named` (given one), `derived` (worked out), `none`.
    let names: String
    /// What its tool places: `200x200`.
    let size: String?
    /// The smallest its shapes are drawn (`Placement.minimumSize`), under which a `size:` is refused:
    /// `96x64`; nil where any size goes.
    let smallest: String?
    /// What a shape of it holds, which `in "X"` names it for: `board`, a board of its own (a
    /// subboard's, which the shape goes on), or `shapes` on the board it's on (a frame's, which the
    /// shape goes in); nil for neither.
    let holds: String?
    /// What a script can write on it, and what each takes: `{"status": "todo|doing|blocked|done"}`.
    let attributes: [String: String]
    /// The sides an edge may leave it by, and what it may carry from each.
    let edges: [String: [String]]?
    let schema: JSONValue?
}

/// Why a script can't place a kind no tool places: its tool draws one by hand (a line, by its
/// drag), or it has none.
@MainActor
func unplaceable(_ kind: ShapeKind, in registry: Registry) -> String {
    guard let tool = registry.tools.first(where: { $0.id == ToolID(placing: kind) }) else { return "no tool places one" }
    return "its tool (\(tool.label)) draws one by hand, so a script can't place one"
}

@MainActor
func kinds(_ params: ListKinds, in registry: Registry) throws(AutomationError) -> [KindSummary] {
    var kinds = registry.kinds.sorted { $0.rawValue < $1.rawValue }
    if let named = params.kind {
        guard let kind = kinds.first(where: { $0.rawValue == named }) else {
            let all = kinds.map(\.rawValue)
            throw AutomationError("there's no kind of shape called \(named)", reason: ScriptError.Reason.unknownKind.rawValue,
                                  hint: (Suggestions.closest(to: named, among: all, limit: 1).first.map { "did you mean \($0)? " } ?? "")
                                      + "the kinds: \(all.joined(separator: ", "))")
        }
        kinds = [kind]
    }
    let naming = registry.drawNaming, edging = registry.drawEdging, edgeKind = edging.flatMap { $0.kind(registry) }
    return kinds.map { kind in
        let vocabulary = KindVocabulary(kind, in: registry)
        let placement = registry.placement(for: kind)
        let why: String? = if Keyword(rawValue: kind.rawValue) != nil {
            "its name is one of the language's words"
        } else if kind == edgeKind {
            "it joins two shapes: write edge \"A\" -> \"B\""
        } else if placement == nil {
            unplaceable(kind, in: registry)
        } else {
            nil
        }
        let names = if vocabulary.namingProperty != nil { "named" } else if naming?.isDerived(kind, registry) == true { "derived" } else { "none" }
        var attributes: [String: String] = [:]
        for name in vocabulary.attributes { attributes[name] = vocabulary.compactType(of: name) }
        for name in vocabulary.collisions {
            attributes[name] = "\(vocabulary.compactType(of: name)) — can't be written: \(name): is one of the language's own keys"
        }
        let sides = (edging?.sides(kind, registry) ?? [:]).filter { !$0.value.isEmpty }
        return KindSummary(kind: kind.rawValue, title: vocabulary.root["title"]?.stringValue,
                           tool: registry.tools.first { $0.id == ToolID(placing: kind) }?.label,
                           drawable: why == nil, why: why, names: names,
                           size: placement.map { Drawing.written($0.size) },
                           smallest: placement.flatMap { $0.minimumSize == .zero ? nil : Drawing.written($0.minimumSize) },
                           holds: registry.boardOwningKinds.contains(kind) ? "board" : registry.containingKinds.contains(kind) ? "shapes" : nil,
                           attributes: attributes,
                           edges: sides.isEmpty ? nil : Dictionary(uniqueKeysWithValues: sides.map { ($0.key.rawValue, $0.value) }),
                           schema: params.schema ? .object(vocabulary.root) : nil)
    }
}
