import Canvas

// What an arrow's ends say of a relationship: pure over the graph, the ends and the names handed in, so the
// service, a run and a test ask the same code. The misfit is the graph's `fit`; this only says it. Nothing is
// refused: a misfit is an error on the arrow at the end that does not fit, an end that cannot be read is a
// warning there, and an arrow of a relationship type that is not bound at both ends is a warning at no end.

/// The names the sentences need, handed in.
public struct RelationNaming {
    /// Mentions' label for a shape, else `Untitled` and its kind.
    public var label: (ShapeID) -> String
    /// A shape's own types that are types, in list order.
    public var directTypes: (ShapeID) -> [ShapeID]
    /// The lower-case name of the shape's kind when it holds no `is` (it can have no type); nil for a typeable kind.
    public var kindName: (ShapeID) -> String?

    public init(label: @escaping (ShapeID) -> String, directTypes: @escaping (ShapeID) -> [ShapeID], kindName: @escaping (ShapeID) -> String?) {
        self.label = label
        self.directTypes = directTypes
        self.kindName = kindName
    }
}

/// What the arrow part says, and the shapes whose labels the sentences quote (the quote table's input).
public struct ArrowVerdict: Equatable, Sendable {
    public var problems: [FieldProblem] = []
    public var quoted: [ShapeID] = []

    public init(problems: [FieldProblem] = [], quoted: [ShapeID] = []) {
        self.problems = problems
        self.quoted = quoted
    }
}

@MainActor
public enum RelationChecks {
    /// An arrow's problems against each marked type in `types`, in list order, each side from first. `ends` is
    /// nil when the arrow is not bound at both ends.
    public static func arrow(types: [ShapeID], ends: ConnectionReading?, graph: RelationshipGraph, naming: RelationNaming) -> ArrowVerdict {
        let marked = types.filter(graph.isRelationshipType)
        guard let first = marked.first else { return ArrowVerdict() }
        guard let ends else { return ArrowVerdict(problems: [looseEnd(relation: first, graph: graph)]) }
        var verdict = ArrowVerdict()
        var seen: Set<FieldProblem> = []
        func add(_ problem: FieldProblem) { if seen.insert(problem).inserted { verdict.problems.append(problem) } }
        for relation in marked {
            guard let fit = graph.fit(of: relation, from: ends.from.reading, to: ends.to.reading) else { continue }
            let title = graph.types.names[relation]
            for side in RelationshipSide.allCases {
                switch fit[side] {
                case .fits, .open: continue
                case .misfit(let allowed):
                    guard case .note(let end) = ends[side].reading else { continue }
                    let message = RelationWords.misfit(relation: title, side: side, allowed: allowed.map { graph.types.names[$0] },
                                                       end: naming.label(end), is: describe(end, graph: graph, naming: naming))
                    add(FieldProblem(path: FieldPath(), kind: .wrong, keyword: "misfit", place: [], message: message, locus: .end(side)))
                    if !verdict.quoted.contains(end) { verdict.quoted.append(end) }
                case .unjudged(let reading):
                    guard let message = RelationWords.unread(reading, relation: title, side: side, label: naming.label) else { continue }
                    add(FieldProblem(path: FieldPath(), kind: .warning, keyword: "unread", place: [], message: message, locus: .end(side)))
                    if case .notAdmitted(let shape, _) = reading, !verdict.quoted.contains(shape) { verdict.quoted.append(shape) }
                }
            }
        }
        return verdict
    }

    /// A note's problems for its ruled rows, in the rows' order (`rows` are those with a rule): a Needed row with no relationship
    /// is one `needed` (amber on the row, and an issue of Validation's third level, `:incomplete`, as a needed field is), and more than one where the row allows one
    /// is one `wrong` (red on the row, an error on the note). Each is at `.row(key)`, named by the row (`layer is needed`,
    /// `layer has 2 notes, and should have at most 1`). A misfit, a pill that cannot be read and a relationship the arrow of which is
    /// not a note's own all count in `count`: the arrow is there. None for the arrows: a relationship's own wrong or needed value
    /// marks its arrow only.
    public static func note(rows: [RelationshipRow], count: (RelationshipRow) -> Int, graph: RelationshipGraph) -> [FieldProblem] {
        var problems: [FieldProblem] = []
        for row in rows where !row.rule.isNone {
            let name = row.name(in: graph.types)
            let n = count(row)
            if n == 0, row.rule.needed {
                problems.append(FieldProblem(path: FieldPath(), kind: .needed, keyword: "required", place: [name], message: FieldCheckWords.needed([name]),
                                             locus: .row(row.key)))
            } else if n > 1, row.rule.onlyOne {
                problems.append(FieldProblem(path: FieldPath(), kind: .wrong, keyword: "onlyOne", place: [name], message: RelationWords.onlyOne(name, count: n),
                                             locus: .row(row.key)))
            }
        }
        return problems
    }

    /// Whether any of these problems is said in a name that is read from a title (a row with no name typed on its end).
    public static func namesATitle(_ problems: [FieldProblem]) -> Bool {
        problems.contains { problem in
            if case .row(let key) = problem.locus, case .unnamed = key.label { true } else { false }
        }
    }

    /// What a shape that does not fit is.
    private static func describe(_ end: ShapeID, graph: RelationshipGraph, naming: RelationNaming) -> EndDescription {
        if graph.types.types.contains(end) { return .type }
        if let kind = naming.kindName(end) { return .kind(kind) }
        let direct = naming.directTypes(end)
        return direct.isEmpty ? .untyped : .types(direct.map { graph.types.names[$0] })
    }

    /// The warning of an arrow that holds a marked type and is not bound at both ends: the free end of an
    /// arrow of a relationship type, and the loose end of an arrow with no `is` bound to one. With no `relation`
    /// (an arrow its relationship type was taken from: deleted, or moved away) it says `This arrow`.
    public static func looseEnd(relation: ShapeID?, graph: RelationshipGraph) -> FieldProblem {
        FieldProblem(path: FieldPath(), kind: .warning, keyword: "free", place: [],
                     message: RelationWords.free(relation: relation.flatMap { graph.types.names[$0] }), locus: .end(nil))
    }
}
