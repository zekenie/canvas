import Adornments
import AppKit
import Canvas
import CoreGraphics
import Foundation
import Selection

// What happens when a port's drag is released over a shape: an arrow between two notes takes the one relationship
// type that fits, in the press's own step; several fit and a list opens at the arrow; none leaves it plain; an arrow
// between a type and a relationship type is an end and nothing more; one between two types is replaced by a
// relationship type between them with an arrow to each (`newRelationshipType`). Connections calls
// `connectionDrawn` and knows no more of it.

extension TypesStyle {
    /// The gray row that leaves an arrow plain: the list's last.
    public static let plainArrow = "Plain arrow"
}

/// What a port's release did to the arrow it drew.
public enum ConnectionOutcome: Sendable, Equatable {
    /// Nothing: the arrow is as drawn.
    case plain
    /// The one relationship type that fits was given to it, inside the press's step.
    case took(ShapeID)
    /// Several fit: the list opened at the arrow, which is selected while it is open.
    case offered(taken: [ShapeID], open: [ShapeID])
    /// It is an end of this relationship type (a type to it, or it to a type): the arrow is left as drawn.
    case end(ShapeID)
    /// It ran between two types: replaced by this new relationship type, with an arrow to each.
    case madeRelationshipType(ShapeID)
}

extension CanvasEditor {
    /// A port's drag was released over a shape, and drew `connection` (Connections calls it from inside the press,
    /// after the commit that completed the arrow and before the press's step closes). What the arrow is is read from its
    /// two ends alone (`ArrowRole`) and from the types it fits (`RelationshipGraph.fitting`):
    ///
    /// - between two notes, with exactly one relationship type taken by a drawn end: the arrow takes it, by
    ///   `addTypeLink` alone, so the press's step is still `Add Arrow`;
    /// - several taken: the list opens at the arrow, which is selected while it is open (`.offered`);
    /// - none taken, or only open ones (an open type is offered in `/is-a`'s list and Is a ▸, never taken alone): plain;
    /// - between a type and a relationship type: an end, and nothing else;
    /// - between two types: `newRelationshipType`.
    ///
    /// An arrow that already holds a type, or is not bound at both ends, or is not of a kind that relates, is left
    /// alone, and so is one drawn against a type's direction. Whatever the outcome, the relationships then count the
    /// connection (`connectionReleased`), as every way a drag ends does.
    @discardableResult
    public func connectionDrawn(_ connection: ShapeID) -> ConnectionOutcome {
        defer { connectionReleased(connection) }
        guard let relationships, let record = shape(inFile: connection), registry.relates(record.kind),
              (record[IsAProperty.self] ?? []).isEmpty, let subjects = relationships.subjects(of: connection) else { return .plain }
        let from = subjects.from.literal.flatMap { shape(inFile: $0) }, to = subjects.to.literal.flatMap { shape(inFile: $0) }
        switch ArrowRole.of(from: from, to: to, registry: registry) {
        case .betweenTypes:
            guard let from, let to else { return .plain }
            return newRelationshipType(from: from.id, to: to.id, replacing: connection).map { .madeRelationshipType($0) } ?? .plain
        case .end(let type, _):
            return .end(type)
        case .betweenRelationshipTypes, .endAtNonType:
            return .plain
        case .notes:
            let (taken, open) = relationships.graph.fitting(from: subjects.from.reading, to: subjects.to.reading)
            switch taken.count {
            case 0:
                return .plain
            case 1:
                addTypeLink(taken[0], to: connection)
                return .took(taken[0])
            default:
                selection = connection
                presentTypeList(taken: taken, open: open, for: connection)
                return .offered(taken: taken, open: open)
            }
        }
    }

    /// The list at an arrow: the taken types, the open ones, a rule, a gray `Plain arrow`, under the arrow's adornment
    /// row (its label, else the middle of its outline), opened with the first taken type highlighted so Return takes it.
    private func presentTypeList(taken: [ShapeID], open: [ShapeID], for connection: ShapeID) {
        guard let menu = RelationshipMenus.menu(taken: taken, open: open, for: connection, in: self) else { return }
        let anchor = adornmentAnchor(of: connection) ?? shapeContext.geometry(of: connection)?.bounds ?? .zero
        popUpMenu(menu, below: anchor, highlighting: menu.items.first)
    }
}
