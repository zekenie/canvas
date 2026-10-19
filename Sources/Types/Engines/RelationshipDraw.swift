import Canvas
import CanvasRPC
import Draw
import Foundation
import Mentions
import Titles

// What `canvas draw` says of an arrow it drew, restated or deleted, and of a relationship type: the role the
// arrow has (an end of a relationship type, an arrow that says nothing, a relationship), the relationship types
// it is, those a plain arrow would fit, and what a relationship type relates. Types' one report
// (`FieldValuesPlugin`) adds these to the row as members, over the run's own graph (`RelationshipIndex.graph(in:)`),
// so a script that draws the types, the ends and the notes together is told what each became. A misfit is drawn,
// never refused: its row's `problems` and the run's error come from the check (`FieldChecks.drawn`), and
// Validation's issue says it once. `canvas draw` never picks a type for a plain arrow: a plain arrow between two
// notes that fit says which types would, and the script writes `is:`.

@MainActor
enum RelationshipDrawReport {
    /// The members a row carries.
    static let members = ["is", "endOf", "fits", "relates"]

    /// Adds what is to be said of `record` to `report`: the members, and the warnings of an arrow that is not
    /// what its statement may have meant (`written` is nil for a row that changes nothing: it is not warned about).
    static func add(to report: inout DrawShapeReport, record: AnyShapeRecord, written: JSONObject?, shapes: ShapeContext, bothHeads: Bool = false) {
        guard let reading = shapes.reading, let relationships = reading.service(RelationshipIndex.self) else { return }
        let registry = reading.registry
        let list = record[IsAProperty.self] ?? []
        let onBoard = reading.shape(inFile: record.id) != nil
        // A relationship type: what it relates.
        if onBoard, record[TypeSchemaProperty.self] != nil, record[RelationshipProperty.self] == true, registry.canBeRelationshipType(record.kind) {
            let graph = relationships.graph(in: reading)
            let sides = graph.sides(of: record.id)
            func side(_ side: RelationshipSide) -> JSONValue {
                let types = sides.types(on: side).map { JSONValue.string(title(of: $0, in: reading)) }
                return types.isEmpty ? .string(RelationshipWords.anything) : .array(types)
            }
            report.members["relates"] = .object(["from": side(.from), "to": side(.to)])
        } else if onBoard, written != nil, record[RelationshipProperty.self] == true, record[TypeSchemaProperty.self] == nil {
            // The mark is inert on a note with no schema.
            report.warnings.append(DrawIssue(RelationshipWords.markWithoutSchema, field: RelationshipProperty.key.rawValue))
        }
        guard registry.relates(record.kind) else { return }
        // An arrow: the relationship types it is, by their titles.
        if !list.isEmpty { report.members["is"] = .array(list.map { .string(title(of: $0.shape, in: reading)) }) }
        guard onBoard else {
            // A connection the run deleted: what went with it, when the statement named no type.
            if written == nil, !list.isEmpty {
                let names = list.map { title(of: $0.shape, in: reading) }.joined(separator: " and ")
                report.warnings.append(DrawIssue(RelationshipWords.removedTyped(names), field: IsAProperty.key.rawValue))
            }
            return
        }
        guard let ends = relationships.subjects(of: record, in: reading) else { return }
        let graph = relationships.graph(in: reading)
        func end(_ end: ReadEnd) -> AnyShapeRecord? { end.reading.noteID.flatMap { reading.shape(inFile: $0) } }
        let role = ArrowRole.of(from: end(ends.from), to: end(ends.to), registry: registry)
        switch role {
        case .end(let type, let side):
            var said: JSONObject = ["type": .string(title(of: type, in: reading)), "side": .string(side == .from ? "from" : "to")]
            if let name = registry.typeWords(of: record.kind)?.words(record)?.firstLine { said["row"] = .string(name) }
            let rule = record[RelationshipEndProperty.self] ?? EndRule()
            if rule.needed { said["needed"] = .bool(true) }
            if rule.onlyOne { said["onlyOne"] = .bool(true) }
            report.members["endOf"] = .object(said)
        case .notes:
            // A plain arrow between two notes: the relationship types it would fit, for a script to write.
            if list.isEmpty {
                let taken = graph.fitting(from: ends.from.reading, to: ends.to.reading).taken
                if !taken.isEmpty { report.members["fits"] = .array(taken.map { .string(title(of: $0, in: reading)) }) }
            }
        case .betweenTypes, .betweenRelationshipTypes, .endAtNonType:
            break
        }
        guard written != nil else { return }
        let field = IsAProperty.key.rawValue
        func label(_ end: ReadEnd) -> String {
            guard let id = end.reading.noteID ?? end.literal, let shape = reading.shape(inFile: id) else { return "Untitled" }
            return registry.mentionAppearance(of: shape)?.label ?? "Untitled " + registry.label(of: shape.kind).name
        }
        switch role {
        case .betweenTypes: report.warnings.append(DrawIssue(RelationshipWords.betweenTypes(from: label(ends.from), to: label(ends.to)), field: field))
        case .betweenRelationshipTypes: report.warnings.append(DrawIssue(RelationshipWords.betweenRelationshipTypes, field: field))
        case .endAtNonType(let type):
            let other = end(ends.from)?.id == type ? ends.to : ends.from
            report.warnings.append(DrawIssue(RelationshipWords.notAType(label(other), relation: title(of: type, in: reading)), field: field))
        default: break
        }
        if bothHeads, case .end(let type, let side) = role {
            report.warnings.append(DrawIssue(RelationshipWords.twoHeaded(relation: title(of: type, in: reading), side: side), field: field))
        }
        if case .end = role {} else if let rule = written?[RelationshipEndProperty.key.rawValue], rule != .null {
            report.warnings.append(DrawIssue(RelationshipWords.endRuleOffEnd, field: RelationshipEndProperty.key.rawValue))
        }
        // A type on an arrow that is not a relationship type: nothing checks its ends.
        // (Whether the list names a type is read from the reading's own record: the run's graph holds the types
        // of the file with none marked only once one is.)
        for link in list where isType(link.shape, in: reading) && !graph.isRelationshipType(link.shape) {
            report.warnings.append(DrawIssue(RelationshipWords.plainType(title(of: link.shape, in: reading)), field: field))
        }
    }

    /// Whether the reading has the shape as a type: a note that holds a schema.
    private static func isType(_ id: ShapeID, in reading: LayoutReading) -> Bool {
        guard let record = reading.shape(inFile: id) else { return false }
        return reading.registry.canBeType(record.kind) && record[TypeSchemaProperty.self] != nil
    }

    /// A shape's title as the reading has it, else its id (what a query row says of a type with none).
    private static func title(of id: ShapeID, in reading: LayoutReading) -> String {
        reading.shape(inFile: id).flatMap { reading.registry.title(of: $0) } ?? id.rawValue.uuidString
    }
}

/// What a script is told of an arrow, in words. Never "edge type", "link" or "reference" for a relationship.
enum RelationshipWords {
    static let anything = "anything"
    static let endRuleOffEnd = "endRule says something only on an arrow between a type and a relationship type."
    static let betweenRelationshipTypes = "Both ends are relationship types, so this arrow says nothing."

    static func betweenTypes(from: String, to: String) -> String {
        "Both ends are types, so this arrow says nothing. Put a relationship type between them: edge \"\(from)\" -> \"T\" and edge \"T\" -> \"\(to)\"."
    }

    static func notAType(_ label: String, relation: String) -> String {
        "\(quoted(label)) isn't a type, so this arrow is not an end of \(quoted(relation))."
    }

    static func plainType(_ title: String) -> String {
        "\(quoted(title)) isn't a relationship type, so nothing checks this arrow's ends. Mark it with relationship: true."
    }

    static let markWithoutSchema = "relationship: says something only on a type, a note with a schema:"

    static func twoHeaded(relation: String, side: RelationshipSide) -> String {
        "A two-headed arrow is read from its start to its end, so this is only the \(side == .from ? "from" : "to") end of \(quoted(relation)). For a type related to itself write two edges."
    }

    static func removedTyped(_ names: String) -> String {
        "it removed an arrow of \(names), since a delete edge without is: removes every arrow of the pair"
    }

    private static func quoted(_ label: String) -> String { "“" + label + "”" }
}
