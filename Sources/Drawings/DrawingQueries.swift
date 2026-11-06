import Canvas
import CanvasRPC
import Draw
import Queries

// What a query reads of drawings: `:drawn-by("NAME")`, the shapes a drawing made (each row with the drawing's `key` for it and `in`, the key
// of the drawing's shape that holds it), and, in the answer's `absent`, what it made that the file no longer holds; `:changed("NAME")`, the
// shapes it made that differ from what it last wrote, each row's `changed` saying how. Both read the file alone (`reads: .file`): the
// records are a file value, taken up with the file in O(1), and read off the main actor, a drawing at a time (a shape two drawings hold
// is judged by each against what that one wrote).

/// The words that read drawings, apart from what keeps them so a list without queries leaves them out.
public struct DrawingQueriesPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { "drawing-queries" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.queryPseudoClass(Word.drawnBy.rawValue, "a drawing of that name made it (canvas apply, or canvas draw --drawing)",
                                   example: #":drawn-by("Sign-up plan")"#, argument: "name", reads: .file,
                                   prepare: { preparation, name in Drawn(facts: preparation.fact(DrawingsFact.self).facts, name: name) },
                                   seeds: { $0.held() },
                                   matches: { shape, drawn in drawn.made(shape) ? .yes : .no },
                                   members: [Member.key.rawValue, Member.in.rawValue],
                                   rowMembers: { shape, drawn in drawn.members(of: shape) },
                                   absent: { drawn in drawn.gone() })
        registrar.queryPseudoClass(Word.changed.rawValue,
                                   "the drawing of that name made it, and it differs from what that drawing last wrote: moved, resized, in another frame, or its attributes",
                                   example: #":changed("Sign-up plan")"#, argument: "name", reads: .file,
                                   prepare: { preparation, name in Drawn(facts: preparation.fact(DrawingsFact.self).facts, name: name) },
                                   seeds: { $0.held() },
                                   matches: { shape, drawn in drawn.changes(of: shape).isEmpty ? .no : .yes },
                                   members: [Member.key.rawValue, Member.in.rawValue, Member.changed.rawValue],
                                   rowMembers: { shape, drawn in
                                       let changes = drawn.changes(of: shape)
                                       guard !changes.isEmpty else { return [:] }
                                       var members = drawn.members(of: shape)
                                       members[Member.changed.rawValue] = .array(changes.map(JSON.string))
                                       return members
                                   })
    }

    /// Its words.
    enum Word: String {
        case drawnBy = "drawn-by"
        case changed
    }

    /// What its rows say.
    enum Member: String {
        case key, `in`, changed
    }
}

/// The file's drawings as a query takes them up.
struct DrawingsFact: QueryFileFact {
    let facts: DrawingFacts

    static func current(in editor: CanvasEditor) -> DrawingsFact { DrawingsFact(facts: DrawingFacts(editor: editor)) }
}

/// One drawing, as its words read it, off the main actor: what it made, what is gone, a row's key and holder, and how a shape
/// differs from what it last wrote. Made in O(1) as the query takes up the file; each answer is worked out where it is asked.
struct Drawn: Sendable {
    let facts: DrawingFacts
    let name: String
    let record: DrawingRecord?

    init(facts: DrawingFacts, name: String) {
        self.facts = facts
        self.name = name
        record = facts.drawing(name)
    }

    /// The shapes it made that the file holds.
    func held() -> Set<ShapeID> { record == nil ? [] : facts.held(by: name) }

    /// Whether it made this shape.
    func made(_ shape: QueryShape) -> Bool { record?.shapes[shape.record.id.description] != nil }

    /// What it made that the file no longer holds, each with its key.
    func gone() -> [QueryAbsent] {
        guard record != nil else { return [] }
        return facts.gone(from: name).map { QueryAbsent(id: $0.id, members: [DrawingQueriesPlugin.Member.key.rawValue: .string($0.key)]) }
    }

    /// A row's `key` in the drawing and `in`, the key of the drawing's shape that holds it; nothing for a shape the drawing didn't make.
    func members(of shape: QueryShape) -> [String: JSON] {
        guard let record, let key = record.shapes[shape.record.id.description]?.key else { return [:] }
        var members: [String: JSON] = [DrawingQueriesPlugin.Member.key.rawValue: .string(key)]
        if let holder = facts.holder(of: shape.record, on: shape.board, in: record) { members[DrawingQueriesPlugin.Member.in.rawValue] = .string(holder) }
        return members
    }

    /// How a shape it made differs from what it last wrote of it: none for one it didn't make, or one as it was written.
    func changes(of shape: QueryShape) -> [String] {
        guard let record else { return [] }
        return facts.changes(of: shape.record, on: shape.board, in: record)
    }
}
