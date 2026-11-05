import Canvas
import CoreGraphics
import Draw
import Mentions
import Selection
import Topology

extension TypesStyle {
    /// The step a name typed in a relationship type's pill takes, where the gesture that made it is not its step.
    public static let nameRelationshipType = "Name Relationship Type"
    /// How much clear arrow each end of a new relationship type is given before the type's box: the types' names on the
    /// arrows are typed after, and a head and a name must not hide each other.
    public static let endArrowRoom: CGFloat = 120
    /// The height both types are about to gain with a relationship type between them: the dashed line's eight points and
    /// one row (`relationRuleHeight` + `rowHeight`, which Rows declares and a test holds this to).
    public static let relationshipRowGrowth: CGFloat = 30
}

/// How an arrow's chip is drawn: as any chip is, or wrong (red, with a wave).
public enum RelationshipTone: Sendable, Equatable {
    case plain, wrong
}

/// What the parts of Types above IsA do for it, handed over by `TypesPlugin` so IsA names none of them: the tone of
/// an arrow's chip, which is the check's (Checks); the arrow's card a chip opens, which is Form's; and the card that
/// defines a relationship type, which Tab in its pill's name asks for.
@MainActor
public final class RelationshipHooks {
    /// How the chip of a relationship type on this arrow is drawn: wrong while the check calls one of its ends a
    /// misfit. Plain where there is no check to ask (a list without the check).
    public let tone: @MainActor (ShapeID) -> RelationshipTone
    /// Opens the card of an arrow's relationship, hung from the arrow's anchor, with the arrow selected; false when
    /// none opens (the relationship's type has no fields, the board is shown as skeletons).
    public let openCard: @MainActor (ShapeID) -> Bool
    /// Opens the card that defines a relationship type, hung from its pill, at `add field`: what Tab does in the
    /// pill's name, once the name is kept and editing has ended. False when none opens (nothing fills it in: a list
    /// without the card, a board shown as skeletons); the type keeps its name either way.
    public var openDefinition: @MainActor (ShapeID) -> Bool

    public init(tone: @escaping @MainActor (ShapeID) -> RelationshipTone = { _ in .plain },
                openCard: @escaping @MainActor (ShapeID) -> Bool = { _ in false },
                openDefinition: @escaping @MainActor (ShapeID) -> Bool = { _ in false }) {
        self.tone = tone
        self.openCard = openCard
        self.openDefinition = openDefinition
    }
}

extension RelationshipHooks: EditorService {}

extension CanvasEditor {
    /// A relationship type put between two types, with an arrow to it from the first and another from it to the
    /// second, and `connection` (the arrow a port's drag drew between them), if given, taken away: one step,
    /// "New Relationship Type", which stays open past the press while its name is typed. The new note is of the first
    /// kind that can hold the mark and has a tool to place it (the first type's own kind if it can), with the starter
    /// schema, the mark, no words and no title; it is drawn as a pill (`TypeRows.pill`), its stored frame centered on the
    /// middle of the straight line between the two types where each arrow shows a body (`Surroundings.between`) and
    /// settled; the two arrows are made as `canvas draw` makes an edge (`registry.drawConnection`), one head each. It is
    /// then selected and its name edited in place, inside the step (a note placed begins its own editing the same way), so
    /// one Undo, once the editing is over, takes back the note, both arrows and the name.
    ///
    /// One of the two may be a type on another board: it is related through a pill on the board shown that stands for it
    /// (the pill the other type already has an arrow into is reused, else one is put down where a draw run puts it, beyond
    /// the new type), the far type made what the pill's kind needs in the same step (`farVerdict`), and the new type
    /// lands beside the near one.
    ///
    /// A type related to itself (`first == second`: "friends with another @Person") is two arrows, never a two-headed one: the
    /// same pair of shapes joined twice, one into the new type and one out of it, the second asked of the connection maker
    /// beside the first (`beside:` names it, and the maker stores the second bent apart from it). The new type then lands beside the type
    /// with the room each arrow needs, there being no gap between a type and itself.
    ///
    /// Nil, with nothing changed and no step left, when nothing makes connections (`registry.drawsConnections`), an end is
    /// not on a board of the file or both are far, a far end cannot be picked, no kind can hold the mark, nothing could be
    /// put down between them, a connection could not be made, the board is read-only, or the container it would land in
    /// is (the core refuses it, and it shakes).
    @discardableResult
    public func newRelationshipType(from first: ShapeID, to second: ShapeID, replacing connection: ShapeID? = nil) -> ShapeID? {
        guard registry.drawsConnections, !isBoardReadOnly, let firstBoard = file.board(containing: first), let secondBoard = file.board(containing: second),
              firstBoard == board || secondBoard == board,
              let kind = relationshipTypeKind(besides: firstBoard == board ? first : second), let base = registry.placement(for: kind) else { return nil }
        let placement = base.setting(TypeSchemaProperty.self, to: SchemaText(TypeSchemaProperty.starter))
            .setting(RelationshipProperty.self, to: true)
        // Its room is what it is laid out at (a pill), and its stored box is the placement's, centered on where it lands.
        let probe = placement.shape(at: .zero)
        let size = shapeContext.layingOut(with: [probe]).frame(of: probe)?.size ?? placement.size
        // The end on another board: the pill that stands for it, reused or made, and what it takes.
        let farFirst = firstBoard != board, far = farFirst ? first : second, near = farFirst ? second : first
        var pill: (kind: ShapeKind, reused: ShapeID?, record: AnyShapeRecord?, fulfil: Bool, standingFor: ShapeKind)?
        let verdicts = FarVerdicts(self)
        if firstBoard != secondBoard {
            guard let route = verdicts.route, let record = shape(inFile: far), verdicts.verdict(of: far) != .cannot, let found = verdicts.kind(for: record) else { return nil }
            let reused = route.existing(for: far, kind: found.kind, sharing: .host(near), near: near, in: document)
            pill = (found.kind, reused, nil, found.fulfils, record.kind)
        }
        guard let surroundings = Surroundings(on: board, moving: size, in: self) else { return nil }
        let landing: Landing?
        if first == second {
            // Beside the type, as far from it as the room both arrows need: the type's box as it is about to be, grown by what
            // the room is over draw's normal gap, which `near` leaves between its target and what it lands.
            guard var bounds = surroundings.reading.shapes.geometry(of: first)?.bounds, !bounds.isNull, bounds.width.isFinite, bounds.height.isFinite else { return nil }
            bounds.size.height += TypesStyle.relationshipRowGrowth
            landing = surroundings.near(bounds.insetBy(dx: -max(0, TypesStyle.endArrowRoom - PlacingStyle.arrowRoom),
                                                       dy: -max(0, TypesStyle.endArrowRoom - PlacingStyle.arrowRoom)))
        } else if pill == nil {
            landing = surroundings.between(first, second, growing: TypesStyle.relationshipRowGrowth, room: TypesStyle.endArrowRoom)
        } else {
            landing = surroundings.near(near)
        }
        // The pill is drawn about the middle of the box it stores, so the box's middle is the landing's: on the straight line between the
        // two types where the gap holds it (the middle of the line between them, which is where the two arrows leave them).
        guard let landing else { return nil }
        let middle = Self.pillMiddle(of: landing, between: first, second, in: surroundings)
        let record = placement.shape(at: middle.point)
        // A new pill goes where a draw run puts it, past the new type.
        var farLanding: Landing?
        if let pending = pill, pending.reused == nil, let route = verdicts.route, let record = shape(inFile: far) {
            let label = registry.mentionAppearance(of: record)?.label ?? ""
            guard var made = registry.standIns.make(pending.kind, standingFor: far, label: label) else { return nil }
            route.seat(&made, beside: near, in: self)
            guard let pillSize = made.box?.size, let pillSurroundings = Surroundings(on: board, moving: pillSize, in: self) else { return nil }
            let spot = route.spot(beside: near, edgeIs: farFirst ? .to : .from, side: nil, in: pillSurroundings.reading)
            guard let spotLanding = route.landing(of: pillSize, at: spot, in: pillSurroundings, avoiding: [landing.rect]) else { return nil }
            made.box = spotLanding.rect
            pill?.record = made
            farLanding = spotLanding
        }
        let made: ShapeID? = undoHistory.group(TypesStyle.newRelationshipType) {
            // Whole or not at all (`transactWhole`): a read-only container a shape would land in refuses it,
            // nothing commits and no step is left, and the container shakes.
            let drawn: Void? = transactWhole(TypesStyle.newRelationshipType) { transaction in
                if let connection { transaction.delete([connection]) }
                var ends = (first, second)
                if let pending = pill {
                    if pending.fulfil { transaction.update(inFile: far) { _ = registry.standIns.fulfil(pending.kind, &$0) } }
                    // Asked again as the step leaves the far type: it may have gone private or away since.
                    guard let farBoard = transaction.board(containing: far), let there = transaction.contents(of: farBoard)[far],
                          registry.standIns.admits(pending.kind, there) else { throw Transaction.Refused() }
                }
                transaction.insert(record)
                guard case .settled = transaction.settle([record.id]) else { throw Transaction.Refused() }
                if let pending = pill {
                    if let reused = pending.reused {
                        if farFirst { ends.0 = reused } else { ends.1 = reused }
                    } else if let pillRecord = pending.record {
                        transaction.insert(pillRecord)
                        guard transaction.document[pillRecord.id] != nil else { throw Transaction.Refused() }
                        guard case .settled = transaction.settle([pillRecord.id]) else { throw Transaction.Refused() }
                        for above in farLanding?.above ?? [] {
                            guard let mine = transaction.document.index(of: pillRecord.id), let theirs = transaction.document.index(of: above), theirs > mine else { continue }
                            transaction.move(pillRecord.id, above: above)
                        }
                        if farFirst { ends.0 = pillRecord.id } else { ends.1 = pillRecord.id }
                    }
                }
                let stood: [ShapeKind] = pill.map { [$0.standingFor] } ?? []
                // The first arrow is in the document before the second is made: a type related to itself joins one
                // pair twice, and the maker reads the bend of the arrow the second goes beside from there.
                guard let toIt = registry.drawConnection(from: ends.0, to: record.id, in: transaction.shapes, standingFor: (farFirst ? stood : [], [])) else { throw Transaction.Refused() }
                transaction.insert(toIt)
                guard let fromIt = registry.drawConnection(from: record.id, to: ends.1, in: transaction.shapes, standingFor: ([], farFirst ? [] : stood),
                                                           beside: first == second ? [toIt.id] : nil) else { throw Transaction.Refused() }
                transaction.insert(fromIt)
            }
            guard drawn != nil else { return nil }
            // On the line between the two types, it is on it as they are now (they have their new rows): one line through the pill, straight.
            if middle.isOnLine { straighten(record.id) }
            selection = record.id
            // Its name is typed in the pill, in this step; zoomed out nothing shows, as with a card: the type is made, selected and untitled.
            if !drawsSkeletons { beginEditing(record.id) }
            return record.id
        }
        return made
    }

    /// Where the pill's middle is: the landing's, moved onto the straight line between the middles of the two types when the landing
    /// is across the gap between them and so within a pill's width of that line (a landing beside the middle, clear of something in the
    /// way, is not on it and stays where the solver put it).
    private static func pillMiddle(of landing: Landing, between first: ShapeID, _ second: ShapeID, in surroundings: Surroundings) -> (point: CGPoint, isOnLine: Bool) {
        let middle = CGPoint(x: landing.rect.midX, y: landing.rect.midY)
        guard first != second, let a = surroundings.reading.shapes.geometry(of: first)?.bounds, let b = surroundings.reading.shapes.geometry(of: second)?.bounds,
              !a.isNull, !b.isNull else { return (middle, false) }
        // Each type as it is about to be, a row taller: the line the arrows will run along.
        let growth = TypesStyle.relationshipRowGrowth / 2
        let from = CGPoint(x: a.midX, y: a.midY + growth), to = CGPoint(x: b.midX, y: b.midY + growth)
        let line = CGPoint(x: to.x - from.x, y: to.y - from.y)
        let length2 = line.x * line.x + line.y * line.y
        guard length2 > 0 else { return (middle, false) }
        let t = ((middle.x - from.x) * line.x + (middle.y - from.y) * line.y) / length2
        let onLine = CGPoint(x: from.x + t * line.x, y: from.y + t * line.y)
        let off = hypot(onLine.x - middle.x, onLine.y - middle.y)
        return off <= min(landing.rect.width, landing.rect.height) ? (onLine, true) : (middle, false)
    }

    /// The kind a relationship type put down beside `owner` is: the owner's, if it can hold the mark and has a tool to
    /// place it; else the first kind that can.
    func relationshipTypeKind(besides owner: ShapeID) -> ShapeKind? {
        func usable(_ kind: ShapeKind) -> Bool { registry.canBeType(kind) && registry.canBeRelationshipType(kind) && registry.placement(for: kind) != nil }
        if let record = document[owner], usable(record.kind) { return record.kind }
        return registry.kinds.first(where: usable)
    }
}
