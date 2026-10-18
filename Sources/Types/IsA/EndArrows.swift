import Canvas
import ContextMenus
import CoreGraphics
import Foundation
import Selection
import Topology

// One line through the pill: the two arrows at a relationship type read as the halves of one line, car ——[owner]——> person.
// What Types says of such an arrow is a layout input, `EndArrow.input`: that it is an end, which side, and, when the type
// has the one end on each side, the other half; the kind that draws arrows (Arrows) lays the half out as part of the arc
// through the type's pill, with no head at the pill and no words. Nothing of it is stored.

/// What an arrow that is an end of a relationship type is to the line through the type's pill.
public struct EndArrow: Hashable, Sendable {
    /// The relationship type.
    public let hub: ShapeID
    /// `from`: the arrow runs from a type into the hub, so its end is at the pill; `to`: out of the hub to a type, so its start is.
    public let side: RelationshipSide
    /// The arrow at the other side when the type has exactly one end on each side: the half this one makes a line with.
    public let partner: ShapeID?

    public init(hub: ShapeID, side: RelationshipSide, partner: ShapeID?) {
        self.hub = hub
        self.side = side
        self.partner = partner
    }
}

extension EndArrow {
    /// Whether an arrow is an end of a relationship type and what that says of how it is laid out: nil for any other shape.
    /// Types provides it (`EndArrows`), from the relationship index; an arrow it names is laid out again by
    /// `editor.shapesDidChangeLayout` when its ends change, as the index says them. What the shapes at its ends do (a far type
    /// moved, the partner re-aimed, the pill moved) is the geometry's own business: it looks them up, and the index of
    /// shapes follows.
    public static let input = LayoutInputKey<EndArrow>("end-arrow")
}

/// Keeps the arrows that are ends laid out as the index says they are: the provider's answer for each, and the announcement
/// when it changes with no change to the arrow's own record.
@MainActor
final class EndArrows: EditorService {
    private weak var editor: CanvasEditor?
    /// What each arrow told to be an end was told, to say when it changes: a name or a rule on an end changes nothing here.
    private var told: [ShapeID: EndArrow] = [:]

    init(editor: CanvasEditor) {
        self.editor = editor
        if let relationships = editor.relationships {
            // The ends the file has already: what they are told, so that a change after the first is seen as one.
            for id in relationships.endCarriers { told[id] = Self.role(of: id, in: relationships) }
            relationships.onChange { [weak self] change in self?.heard(change) }
        }
    }

    /// Showing another board changes nothing here: what an arrow is told is the file's.
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {}

    /// The index named these connections: those whose answer is another now, ends that came, went or whose partner changed,
    /// are laid out again; and nothing else is. Each end of a type whose ends changed is named by the index, so a side that
    /// gains a second gives each half its own line again.
    private func heard(_ change: RelationshipChange) {
        guard let editor, let relationships = editor.relationships else { return }
        var named: Set<ShapeID> = []
        func consider(_ id: ShapeID) {
            let now = Self.role(of: id, in: relationships)
            guard told[id] != now else { return }
            told[id] = now
            named.insert(id)
        }
        if change.everything {
            for id in Set(told.keys).union(relationships.endCarriers) { consider(id) }
        } else {
            for id in change.arrows { consider(id) }
        }
        editor.shapesDidChangeLayout(named)
    }

    /// What the index says of an arrow: nil for one that is no end.
    private static func role(of id: ShapeID, in relationships: RelationshipIndex) -> EndArrow? {
        guard let end = relationships.end(id) else { return nil }
        var partner: ShapeID?
        if let sides = relationships.graph.ends.sides[end.type], sides.from.count == 1, sides.to.count == 1 {
            partner = (end.side == .from ? sides.to : sides.from)[0].carrier
        }
        return EndArrow(hub: end.type, side: end.side, partner: partner)
    }

    /// The provider: asked of every shape of a kind that relates when it is laid out. As the committed index has it, for an
    /// arrow nothing changed mid-transaction; nil for one that did, which is laid out as it is stored.
    static func provide(_ record: AnyShapeRecord, _ reading: LayoutReading) -> EndArrow? {
        guard reading.registry.relates(record.kind), let relationships = reading.service(RelationshipIndex.self), relationships.isActive,
              !reading.isChanged(record.id) else { return nil }
        return role(of: record.id, in: relationships)
    }
}

extension TypesStyle {
    /// The step that puts a relationship type's pill on the line between its two types.
    public static let straighten = "Straighten"
}

extension CanvasEditor {
    /// The two ends of a relationship type that has one end on each side, and the shape each runs to: nil for a type with
    /// another number of ends, or when both run to the same shape (a type related to itself: two arrows, no line through the pill).
    func straightenable(_ hub: ShapeID) -> (from: (arrow: ShapeID, far: ShapeID), to: (arrow: ShapeID, far: ShapeID))? {
        guard let relationships, relationships.isActive, let sides = relationships.graph.ends.sides[hub], sides.from.count == 1, sides.to.count == 1,
              let topology else { return nil }
        func far(_ arrow: ShapeID, _ side: RelationshipSide) -> ShapeID? {
            guard let edge = topology.edges(carriedBy: arrow, view: .literal).first(where: \.isConnection) else { return nil }
            return side == .from ? edge.literalSource : edge.literalTarget
        }
        guard let first = far(sides.from[0].carrier, .from), let second = far(sides.to[0].carrier, .to), first != second else { return nil }
        return ((sides.from[0].carrier, first), (sides.to[0].carrier, second))
    }

    /// Moves a relationship type's pill onto the middle of the straight line between the two shapes it joins, so the line through
    /// it is straight: one step, "Straighten". False, with nothing changed, for a type with other than one end on each side, one
    /// not on the board shown, one that is read-only (the core refuses it, and it shakes), or a pill already there.
    @discardableResult
    public func straighten(_ hub: ShapeID) -> Bool {
        guard document[hub] != nil, let ends = straightenable(hub) else { return false }
        let context = shapeContext
        guard let pill = context.frame(of: hub), let first = context.frame(of: ends.from.far), let second = context.frame(of: ends.to.far) else { return false }
        let middle = CGPoint(x: (first.midX + second.midX) / 2, y: (first.midY + second.midY) / 2)
        let delta = CGPoint(x: middle.x - pill.midX, y: middle.y - pill.midY)
        guard abs(delta.x) > 0.001 || abs(delta.y) > 0.001 else { return false }
        let before = revision
        transact(TypesStyle.straighten) { $0.translate([hub], by: delta) }
        return revision != before
    }
}

/// Straighten, in the menu of a relationship type with one end on each side: the pill goes onto the middle of the line between its
/// two types.
@MainActor
func registerEndArrows(into registrar: inout PluginRegistrar) {
    registrar.service { EndArrows(editor: $0) }
    registrar.layoutInput(EndArrow.input) { record, reading in EndArrows.provide(record, reading) }
    registrar.contextMenuForCanvas {
        MenuItems(in: ShapeMenuGroup.self, id: "straighten") { subject in
            if subject.shapes.count == 1, let hub = subject.shapes.first, subject.editor.straightenable(hub) != nil {
                MenuItem(TypesStyle.straighten, in: ShapeMenuGroup.self, id: "straighten", stepName: TypesStyle.straighten) { ids, editor in
                    for hub in ids { editor.straighten(hub) }
                }
            }
        }
    }
}
