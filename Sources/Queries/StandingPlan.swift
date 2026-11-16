import Canvas
import Topology

// What a standing query reads of a plan: where it stands on other shapes (its anchors), and what
// beyond a shape's own record a commit may change under it (edges, containment, whether a shape is
// there at all). A shape's answer is a function of its own record, of where it is in the
// containment tree, of its edges, of the facts the words take, and of what the plan's anchors
// match among every shape; so an answer kept for a shape no commit names holds while those hold.

/// Where a plan stands on what other shapes match: a list or a node evaluated among every shape
/// whatever the candidates of the node that holds it (what `:inside(S)`, `S T`, `S > T`, `:has(S)`,
/// an edge word's and a relation's S match). What it matched is kept with a standing query's
/// answer, and a commit's shapes are checked against it before they're answered with it.
enum StandingAnchor: Sendable {
    case list(PlanList)
    case node(PlanNode)

    var id: PlanNodeID {
        switch self {
        case .list(let list): list.id
        case .node(let node): node.id
        }
    }
}

/// What a standing query's plan reads beyond each shape's own record, worked out once as it stands.
struct StandingReads: Sendable, Equatable {
    /// The edge types it reads, each with those under it: nil for none, `everyType` for any.
    var edgeTypes: Set<EdgeTypeID>?
    /// Whether it reads edges of every type (an edge word with no types, a word of a plugin's, which
    /// is handed the shape's edges).
    var everyType = false
    /// Containment: `:inside`, a space, `>`, `:has`, `:top-level`, and a plugin's word, which is
    /// handed the shape's place.
    var containment = false
    /// Whether a shape's answer reads what's inside it: `:has`. A shape that holds nothing changing
    /// place changes the answers of the shapes it was inside and is inside now, which are asked with
    /// it. (A plugin's word is taken to judge a shape by its own place, as `containment` says.)
    var descendants = false
    /// Whether a shape being there at all is read of shapes other than it: `:dangling`, whose far
    /// ends may go without the carrier changing.
    var presence = false
    /// Whether where a shape is may be read: a plugin's word, which is handed the record, box and
    /// all. A shape that only moved is asked again for such a plan.
    var box = false

    /// Whether a change to the edges of these types (by type, with what each touched) reaches it.
    func reads(_ touchedByType: [EdgeTypeID: Set<ShapeID>]) -> Bool {
        if everyType { return !touchedByType.isEmpty }
        guard let edgeTypes else { return false }
        return touchedByType.keys.contains(where: edgeTypes.contains)
    }
}

extension QueryPlan {
    /// Its anchors, each after those inside it, so a check of one reads those inside it as checked.
    var standingAnchors: [StandingAnchor] {
        var found: [StandingAnchor] = []
        root.collectAnchors(into: &found)
        return found
    }

    /// What it reads beyond each shape's own record.
    var standingReads: StandingReads {
        var reads = StandingReads()
        func note(_ types: PlanEdgeTypes) {
            guard let types = types.types else { return reads.everyType = true }
            reads.edgeTypes = (reads.edgeTypes ?? []).union(types)
        }
        root.forEachNode { node in
            switch node.op {
            case .edges(_, _, _, let types), .relation(_, _, let types, _):
                note(types)
            case .dangling(let types):
                note(types)
                reads.presence = true
            case .scope(let word) where word.readsEdges:
                reads.everyType = true
            case .has:
                reads.containment = true
                reads.descendants = true
            case .inside, .parentIn, .ancestorIn, .topLevel:
                reads.containment = true
            case .pseudo, .textPseudo:
                reads.everyType = true
                reads.containment = true
                reads.box = true
            default:
                break
            }
        }
        return reads
    }
}

extension PlanList {
    fileprivate func collectAnchors(into found: inout [StandingAnchor]) {
        for item in items { item.collectAnchors(into: &found) }
    }
}

extension PlanNode {
    fileprivate func collectAnchors(into found: inout [StandingAnchor]) {
        func anchor(_ list: PlanList) {
            list.collectAnchors(into: &found)
            found.append(.list(list))
        }
        switch op {
        case .not(let list), .is(let list):
            list.collectAnchors(into: &found)
        case .inside(let list), .parentIn(let list), .ancestorIn(let list):
            anchor(list)
        case .has(let items):
            for item in items {
                item.node.collectAnchors(into: &found)
                found.append(.node(item.node))
            }
        case .edges(_, let first, let second, _):
            anchor(first)
            if let second { anchor(second) }
        case .relation(_, let list, _, _), .fileRelation(_, let list):
            anchor(list)
        case .and(let nodes):
            for node in nodes { node.collectAnchors(into: &found) }
        case .all, .kinds, .title, .id, .attribute, .contains, .topLevel, .currentBoard, .scope, .dangling, .pseudo, .textPseudo:
            break
        }
    }
}

/// What a standing query asks an evaluation: the whole file (`shapes` nil), or a commit's shapes,
/// each answered with what the anchors matched as of the last whole answer (`anchors`), once the
/// shapes `checked` (those and the shapes of the asks still out) are found to leave each anchor as
/// it was.
struct StandingAsk: Sendable {
    let plan: QueryPlan
    let anchorPlaces: [StandingAnchor]
    let shapes: Set<ShapeID>?
    let checked: Set<ShapeID>
    let anchors: [PlanNodeID: Set<ShapeID>]
}

/// What an evaluation answers a standing query: every match, and what each anchor matched (asked
/// for the whole file, or for a commit's shapes that moved an anchor, `escalated`); or which of the
/// shapes asked match.
enum StandingAnswer: Sendable {
    case whole(matches: Set<ShapeID>, anchors: [PlanNodeID: Set<ShapeID>], escalated: Bool)
    case shapes(matching: Set<ShapeID>)
}
