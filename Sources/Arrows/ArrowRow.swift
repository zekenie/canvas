import Canvas
import Foundation
import Mentions
import SwiftUI
import TableOfContents
import Topology
import Types

extension ShapeRegistrar where Definition == ArrowDefinition {
    /// The arrow's row in the table of contents, under the shape it starts from (as data-canvas's
    /// edges): a relationship's is its relationship type's title in the type's color (the label stays on the
    /// arrow, its chip and its card; `ArrowTypeRows` tells the list when the title changes); else its
    /// label's first line, each mention with its shape's name as it is now, else "Arrow", dimmed; a rename of a shape its label mentions remakes the row (`MentionRows.affected`). Where
    /// it starts at a stand-in that stands for exactly one shape its record names, on the board the
    /// stand-in is on, the row is under that shape, where the arrow reads as starting from (Topology's
    /// resolved edge); else under the stand-in, as for any shape. `ArrowRowNesting` tells the list
    /// when a change to the edges moves such a row.
    mutating func arrowRow() {
        contentsRow(nestedUnder: { arrow, context in
            guard let start = arrow.props.start.binding?.shapeID else { return nil }
            return context.service(TopologyIndex.self)?.nestingParent(ofArrowStartingAt: start) ?? start
        }, affected: MentionRows.affected) { arrow, context in
            // An arrow of a relationship type is listed as its type, in the type's color.
            if let type = ArrowTypeRows.relationshipType(of: arrow, context: context), let types = context.service(TypeIndex.self),
               case .live(let title?) = types.name(of: TypeLink(type)) {
                return ContentsLabel(title, placeholder: "Arrow", systemImage: ArrowStyle.symbol, color: Color(nsColor: types.look(of: type).row))
            }
            return ContentsLabel(Arrow.firstLine(of: context.plainText(arrow.props.text)) ?? "", placeholder: "Arrow", systemImage: ArrowStyle.symbol,
                                 color: context.color(of: arrow))
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

/// Keeps a relationship's row in the table of contents titled by its relationship type: the row is made again when
/// the arrow is given a type, loses it or is re-aimed (the relationships say which arrows) and when the type is
/// renamed (the type index says which types), for the arrows of that type. A row reads the title when it is next
/// drawn, and a keystroke in a type's title costs the arrows of the type a dictionary entry forgotten each.
@MainActor
final class ArrowTypeRows {
    init(editor: CanvasEditor) {
        // Registered after Types; a list without it has no relationships.
        guard let relationships = editor.relationships, let types = editor.types else { return }
        relationships.onChange { [weak editor] change in
            guard let editor, !change.arrows.isEmpty else { return }
            editor.contentsDidChange(for: change.arrows)
        }
        types.onChange { [weak editor, weak types] change in
            guard let editor, let types else { return }
            let renamed = change.types.intersection(types.graph.relationshipTypes)
            guard !renamed.isEmpty else { return }
            var arrows: Set<ShapeID> = []
            for type in renamed { arrows.formUnion(types.instances(of: type)) }
            if !arrows.isEmpty { editor.contentsDidChange(for: arrows) }
        }
    }

    /// The first relationship type in the arrow's `is` list: the one that titles its row.
    static func relationshipType(of arrow: ShapeRecord<Arrow>, context: ContentsContext) -> ShapeID? {
        guard let list = arrow[IsAProperty.self], !list.isEmpty, let types = context.service(TypeIndex.self) else { return nil }
        let marked = types.graph.relationshipTypes
        return list.map(\.shape).first(where: marked.contains)
    }
}

extension ArrowTypeRows: EditorService {}

extension ArrowRowNesting: EditorService {}

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
    /// The first line of its text, as it reads (`plain`), that says something, trimmed; nil for none.
    static func firstLine(of plain: String) -> String? {
        plain.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }
}
