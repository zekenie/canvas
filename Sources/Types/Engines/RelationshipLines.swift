import Canvas
import Draw

/// The halves of one line through a relationship type, for `canvas measure` of a document (Draw's `DrawLines`): of the connections a
/// document draws, those that are its ends, read from their end records alone (`ArrowRole`, so the types the document draws count),
/// where it has exactly one end on each side and they run to two different shapes. That is when `EndArrows` makes the two a line
/// and Arrows draws them as one arc through the type's pill (`ArrowThrough`); a side with two ends, and a type related to itself,
/// are arrows of their own. A layout that sees the pair can put the type between its two types, where the arc is straight.
enum RelationshipLines {
    @MainActor
    static func lines(_ connections: [DrawnConnection], _ shapes: [ShapeID: AnyShapeRecord], _ registry: Registry) -> [DrawLine] {
        var order: [ShapeID] = []
        var froms: [ShapeID: [DrawnConnection]] = [:], tos: [ShapeID: [DrawnConnection]] = [:]
        for connection in connections where registry.relates(connection.record.kind) {
            guard case .end(let type, let side) = ArrowRole.of(from: shapes[connection.from], to: shapes[connection.to], registry: registry) else { continue }
            if froms[type] == nil && tos[type] == nil { order.append(type) }
            if side == .from { froms[type, default: []].append(connection) } else { tos[type, default: []].append(connection) }
        }
        return order.compactMap { type in
            guard let into = froms[type], let out = tos[type], into.count == 1, out.count == 1, into[0].from != out[0].to else { return nil }
            return DrawLine(first: into[0].record.id, second: out[0].record.id, through: type)
        }
    }
}
