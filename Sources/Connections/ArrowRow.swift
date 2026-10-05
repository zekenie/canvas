import Canvas
import SwiftUI
import TableOfContents
import Topology

extension ShapeRegistrar where Definition == ArrowDefinition {
    /// The arrow's row in the table of contents, under the shape it starts from (as data-canvas's
    /// edges): its label's first line, else "Arrow", dimmed. Where it starts at a stand-in that stands
    /// for exactly one shape its record names, on the board the stand-in is on, the row is under that
    /// shape, where the arrow reads as starting from (Topology's resolved edge); else under the
    /// stand-in, as for any shape. `ArrowRowNesting` tells the list when a change to the edges moves
    /// such a row.
    mutating func arrowRow() {
        contentsRow(nestedUnder: { arrow, context in
            guard let start = arrow.props.start.binding?.shapeID else { return nil }
            return context.service(TopologyIndex.self)?.nestingParent(ofArrowStartingAt: start) ?? start
        }) { arrow in
            ContentsLabel(arrow.props.firstLine ?? "", placeholder: "Arrow", systemImage: ArrowStyle.symbol)
        }
    }
}

/// Keeps arrows' rows where they nest as stand-ins stand for other shapes: an arrow that starts at a
/// stand-in is listed under what the stand-in stands for, which changes with no change to the arrow
/// (the stand-in re-pointed, what it stands for made private or deleted, an answer given for it). It
/// follows Topology's one delivery of every change to the edges and tells the list which arrows' rows
/// to make again (`contentsDidChange(for:)`), nesting and all.
@MainActor
final class ArrowRowNesting {
    private var following: TopologyFollowing?

    init(editor: CanvasEditor) {
        guard let topology = editor.topology, !topology.standInKinds.isEmpty else { return }
        following = topology.follow { [weak editor, weak topology] change in
            // No stand-in in the file (the last one deleted included): no arrow starts at one.
            guard let editor, let topology, topology.hasStandIns else { return }
            let arrows = topology.arrows(startingAtStandInsIn: change.touched)
            if !arrows.isEmpty { editor.contentsDidChange(for: arrows) }
        }
    }
}

extension ArrowRowNesting: EditorService {
    /// Nothing: showing another board changes no edge, and a service that follows a switch by working
    /// out its change set costs every switch both boards' shapes.
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {}
}

extension TopologyIndex {
    /// The shape a row of an arrow starting at `start` nests under: the one shape `start` stands for,
    /// by its record, when that is on the board `start` is on (else the row is under `start`, as a
    /// listing nests a row only under a shape it lists); `start` for anything else. A shape that
    /// stands for nothing costs a dictionary hit.
    @MainActor
    func nestingParent(ofArrowStartingAt start: ShapeID) -> ShapeID {
        guard case .record(let targets) = forwarding(of: start), targets.count == 1, let target = targets.first,
              case .live(let board) = end(target), end(start) == .live(board) else { return start }
        return target
    }

    /// The arrows that start at a stand-in among `ids`, as drawn (the literal view: they start there
    /// whatever it stands for now, even for nothing): the rows that nest under what it stands for, or
    /// under it, as of now.
    @MainActor
    func arrows(startingAtStandInsIn ids: Set<ShapeID>) -> Set<ShapeID> {
        var found: Set<ShapeID> = []
        for id in ids where forwarding(of: id) != .none {
            for edge in edges(of: id, .outgoing, types: .within(ArrowEdge.id), view: .literal) { found.insert(edge.carrier) }
        }
        return found
    }
}

extension Arrow {
    /// The first line of its text that says something, trimmed; nil for none.
    var firstLine: String? {
        text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }
}
