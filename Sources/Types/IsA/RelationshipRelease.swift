import Adornments
import AppKit
import Canvas
import Connections
import CoreGraphics
import Foundation
import Selection

// What happens when a connection is released (a port's drag let go over a shape, Connect's): an arrow between two notes takes
// the one relationship type that fits, in the press's own step; several fit and they're offered in the one list a release
// opens (Connections', `ConnectionMade`: Types' answer, `TypeReleasePlugin`, after the channels'); none leaves it plain; an
// arrow between a type and a relationship type is an end and nothing more; one between two types is replaced by a
// relationship type between them with an arrow to each (`newRelationshipType`). Connections knows no more of it.

extension PluginID {
    public static let typeRelease: PluginID = "type-release"
}

/// Types' answer to every connection's release (Connections' `ConnectionMade`): the relationship type it takes, or those it
/// could, as rows of the one list. A plugin value of its own after `PortsPlugin`, whose point it fills.
public struct TypeReleasePlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .typeRelease }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.connectionMade { connection, editor in editor.relationshipAnswer(connection) }
    }
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
    /// - between two types: `newRelationshipType`, and from a type back to itself (a port's drag let go on the type, or
    ///   Connect on it alone) a relationship type from it to itself, with two arrows.
    ///
    /// An arrow that already holds a type, or is not bound at both ends, or is not of a kind that relates, is left
    /// alone, and so is one drawn against a type's direction. Whatever the outcome, the relationships then count the
    /// connection (`connectionReleased`), as every way a drag ends does.
    @discardableResult
    public func connectionDrawn(_ connection: ShapeID) -> ConnectionOutcome {
        let (outcome, choices) = released(connection)
        if case .offered = outcome, !choices.isEmpty { presentConnectionChoices([choices], for: connection) }
        return outcome
    }

    /// What a connection's release is to Types, as the one list asks it (`ConnectionMade`): settled for a type taken, an end, or
    /// a relationship type made; the types that fit as rows of the list; nothing for a plain arrow.
    public func relationshipAnswer(_ connection: ShapeID) -> ConnectionAnswer {
        let (outcome, choices) = released(connection)
        switch outcome {
        case .plain: return .nothing
        case .took, .end, .madeRelationshipType: return .settled
        case .offered: return choices.isEmpty ? .nothing : .offers(choices)
        }
    }

    /// What `connectionDrawn` does but open the list: the outcome, and for several types that fit, the list's rows.
    private func released(_ connection: ShapeID) -> (ConnectionOutcome, [ConnectionChoice]) {
        defer { connectionReleased(connection) }
        guard let relationships, let record = shape(inFile: connection), registry.relates(record.kind),
              (record[IsAProperty.self] ?? []).isEmpty, let subjects = relationships.subjects(of: connection) else { return (.plain, []) }
        let from = subjects.from.literal.flatMap { shape(inFile: $0) }, to = subjects.to.literal.flatMap { shape(inFile: $0) }
        switch ArrowRole.of(from: from, to: to, registry: registry) {
        case .betweenTypes:
            guard let from, let to else { return (.plain, []) }
            return (newRelationshipType(from: from.id, to: to.id, replacing: connection).map { .madeRelationshipType($0) } ?? .plain, [])
        case .end(let type, _):
            return (.end(type), [])
        case .betweenRelationshipTypes, .endAtNonType:
            return (.plain, [])
        case .notes:
            let (taken, open) = relationships.graph.fitting(from: subjects.from.reading, to: subjects.to.reading)
            switch taken.count {
            case 0:
                return (.plain, [])
            case 1:
                addTypeLink(taken[0], to: connection)
                return (.took(taken[0]), [])
            default:
                return (.offered(taken: taken, open: open), RelationshipMenus.choices(taken: taken, open: open, for: connection, in: self))
            }
        }
    }

    /// Whether an arrow from `shape` to itself is made a relationship type from it to itself (`connectionDrawn`, as one
    /// between two types is): a type that is no relationship type. Relate to ▸ asks it to list the type itself.
    func canRelateToItself(_ shape: AnyShapeRecord) -> Bool {
        relationships != nil && ArrowRole.of(from: shape, to: shape, registry: registry) == .betweenTypes
    }
}
