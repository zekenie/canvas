import Canvas
import CoreGraphics
import Draw
import Mentions
import Selection
import Topology

extension TypesStyle {
    /// The step the name card takes, inside the step the gesture made.
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

/// What the parts of Types above IsA do for it, handed over by `TypesPlugin` so IsA names none of them: showing the
/// card that names a relationship type, which is Form's; the tone of an arrow's chip, which is the check's (Checks);
/// and the arrow's card a chip opens, which is Form's.
@MainActor
public final class RelationshipHooks {
    /// Shows the card that names a relationship type, at its pill, for the writer that made it (inside the writer's
    /// step); false when none shows (a read-only board or shape, a shape drawn as a skeleton).
    let nameIt: @MainActor (ShapeID) -> Bool
    /// How the chip of a relationship type on this arrow is drawn: wrong while the check calls one of its ends a
    /// misfit. Plain where there is no check to ask (a list without the check).
    public let tone: @MainActor (ShapeID) -> RelationshipTone
    /// Opens the card of an arrow's relationship, hung from the arrow's anchor, with the arrow selected; false when
    /// none opens (the relationship's type has no fields, the board is shown as skeletons).
    public let openCard: @MainActor (ShapeID) -> Bool

    public init(nameIt: @escaping @MainActor (ShapeID) -> Bool,
                tone: @escaping @MainActor (ShapeID) -> RelationshipTone = { _ in .plain },
                openCard: @escaping @MainActor (ShapeID) -> Bool = { _ in false }) {
        self.nameIt = nameIt
        self.tone = tone
        self.openCard = openCard
    }
}

extension RelationshipHooks: EditorService {
    /// Nothing: showing another board changes nothing here, and a service that follows a switch by working out its
    /// change set costs every switch both boards' shapes.
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {}
}

extension CanvasEditor {
    /// A relationship type put between two types, with an arrow to it from the first and another from it to the
    /// second, and `connection` (the arrow a port's drag drew between them), if given, taken away: one step,
    /// "New Relationship Type", which stays open past the press while the card that names it is shown. The new note is
    /// of the first kind that can hold the mark and has a tool to place it (the first type's own kind if it can), with
    /// the starter schema, the mark, no words and no title, drawn small, put between the two where each arrow shows a
    /// body (`Surroundings.between`) and settled; the two arrows are made as `canvas draw` makes an edge
    /// (`registry.drawConnection`), one head each. It is then selected, never edited, and the card that names it is
    /// shown by this writer, inside the step (`RelationshipHooks.nameIt`), so one Undo, once the card is dismissed, takes
    /// back the note, both arrows and the name.
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
        // Its room is what it is laid out at (drawn small), and its stored box is the placement's.
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
        // The paper is drawn from the top-left its box stores, so the box's top-left is the landing's.
        guard let landing else { return nil }
        let record = placement.shape(at: CGPoint(x: landing.rect.minX + placement.size.width / 2, y: landing.rect.minY + placement.size.height / 2))
        // A new pill goes where a draw run puts it, past the new type.
        var farLanding: Landing?
        if let pending = pill, pending.reused == nil, let route = verdicts.route, let record = shape(inFile: far) {
            let label = registry.mentionAppearance(of: record)?.label ?? ""
            guard var made = registry.standIns.make(pending.kind, standingFor: far, label: label), let pillSize = made.box?.size,
                  let pillSurroundings = Surroundings(on: board, moving: pillSize, in: self) else { return nil }
            let spot = route.spot(beside: near, edgeIs: farFirst ? .to : .from, side: nil, in: pillSurroundings.reading)
            guard let spotLanding = route.landing(of: pillSize, at: spot, in: pillSurroundings, avoiding: [landing.rect]) else { return nil }
            made.box = spotLanding.rect
            pill?.record = made
            farLanding = spotLanding
        }
        struct Refused: Error {}
        var refused: ShapeID?
        let made: ShapeID? = undoHistory.group(TypesStyle.newRelationshipType) {
            do {
                try transact(TypesStyle.newRelationshipType) { transaction in
                    if let connection { transaction.delete([connection]) }
                    var ends = (first, second)
                    if let pending = pill {
                        if pending.fulfil { transaction.update(inFile: far) { _ = registry.standIns.fulfil(pending.kind, &$0) } }
                        // Asked again as the step leaves the far type: it may have gone private or away since.
                        guard let farBoard = transaction.board(containing: far), let there = transaction.contents(of: farBoard)[far],
                              registry.standIns.admits(pending.kind, there) else { throw Refused() }
                    }
                    transaction.insert(record)
                    if case .refused(let container) = transaction.settle([record.id]) {
                        refused = container
                        throw Refused()
                    }
                    if let pending = pill {
                        if let reused = pending.reused {
                            if farFirst { ends.0 = reused } else { ends.1 = reused }
                        } else if let pillRecord = pending.record {
                            transaction.insert(pillRecord)
                            guard transaction.document[pillRecord.id] != nil else { throw Refused() }
                            if case .refused(let container) = transaction.settle([pillRecord.id]) {
                                refused = container
                                throw Refused()
                            }
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
                    guard let toIt = registry.drawConnection(from: ends.0, to: record.id, in: transaction.shapes, standingFor: (farFirst ? stood : [], [])) else { throw Refused() }
                    transaction.insert(toIt)
                    guard let fromIt = registry.drawConnection(from: record.id, to: ends.1, in: transaction.shapes, standingFor: ([], farFirst ? [] : stood),
                                                               beside: first == second ? [toIt.id] : nil) else { throw Refused() }
                    transaction.insert(fromIt)
                    guard transaction.refusedShapes.isEmpty else { throw Refused() }
                }
            } catch {
                return nil
            }
            selection = record.id
            _ = service(RelationshipHooks.self)?.nameIt(record.id)
            return record.id
        }
        if let refused { refuseChanges(to: [refused]) }
        return made
    }

    /// The kind a relationship type put down beside `owner` is: the owner's, if it can hold the mark and has a tool to
    /// place it; else the first kind that can.
    func relationshipTypeKind(besides owner: ShapeID) -> ShapeKind? {
        func usable(_ kind: ShapeKind) -> Bool { registry.canBeType(kind) && registry.canBeRelationshipType(kind) && registry.placement(for: kind) != nil }
        if let record = document[owner], usable(record.kind) { return record.kind }
        return registry.kinds.first(where: usable)
    }
}
