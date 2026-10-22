import Canvas
import CanvasRPC
import Draw
import Queries

/// Types' values in draw, in Types: `fieldValues: {…}` joins what a shape holds, member by member
/// at every depth (a list replaced whole, `null` clearing the member it is written at), so a statement
/// names only what it changes and a script run again says `unchanged`. The merged value goes through
/// the property's own rule (`FieldValues.pruned`: empties are not kept), so what is compared and what
/// is stored are the same. A string that is exactly `@[Title]` is the text it is: no field names a note. And it reports on each shape a run draws, changes or restates (and on each arrow it deletes, for what the row says of it): its row's
/// `problems` (what its values still need and what is wrong, as the check of the run says it, against types
/// the script draws too), and, for a shape the run wrote values on, each member no field of its types
/// names (kept, and warned about).
public struct FieldValuesPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { "draw-field-values" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.drawValueWriter(for: FieldValuesProperty.key, merge: { written, held in
            FieldValues.pruned(FieldValuesMerge.merged(written, into: held)) ?? .null
        })
        // An arrow's `endRule: {needed: true}` sets the members it names and keeps the rest, so a script
        // run again says `unchanged` and one that sets Only one does not undo Needed.
        registrar.drawValueWriter(for: RelationshipEndProperty.key, merge: { written, held in
            EndRuleMerge.merged(written, into: held)
        })
        registrar.drawReports(members: RelationshipDrawReport.members) { record, written, shapes, bothHeads in
            guard let reading = shapes.reading, let checks = reading.service(FieldChecks.self) else { return DrawShapeReport() }
            // A connection the run deleted is not on the board: its members, and nothing of its values.
            guard reading.shape(inFile: record.id) != nil else {
                var gone = DrawShapeReport()
                RelationshipDrawReport.add(to: &gone, record: record, written: written, shapes: shapes, bothHeads: bothHeads)
                return gone
            }
            let values = written?[FieldValuesProperty.key.rawValue]?.objectValue
            let drawn = checks.drawn(record, written: values, reading: reading)
            var report = DrawShapeReport(problems: drawn.check.problems.map { problem in
                ShapeProblem(field: problem.placeName, path: problem.pointer, class: problem.kind.word, message: problem.message)
            })
            let key = FieldValuesProperty.key.rawValue
            func issue(_ message: String) -> DrawIssue { DrawIssue(message, field: key) }
            if let values, values.values.contains(where: { $0 != .null }), (record[IsAProperty.self] ?? []).isEmpty {
                report.warnings.append(issue("\(key): it has no type, so no member is a field"))
            }
            let types = drawn.typeNames.joined(separator: " or ")
            for member in drawn.unnamed {
                guard let name = member.path.steps.last, case .key(let word) = name else { continue }
                report.warnings.append(issue("\"\(word)\" isn't a field of \(member.within ?? types)"))
            }
            RelationshipDrawReport.add(to: &report, record: record, written: written, shapes: shapes, bothHeads: bothHeads)
            return report
        }
    }
}

/// The merge of an arrow's `endRule`, pure: `written` over `held` member by member (`null` takes a member
/// away), the whole `null` when nothing is left that is true, as the property's own rule has it.
public enum EndRuleMerge {
    public static func merged(_ written: JSONValue, into held: JSONValue?) -> JSONValue {
        guard case .object(let members) = written else { return written }
        var result: JSONObject = held?.objectValue ?? [:]
        for (key, member) in members {
            if member == .null { result.removeValue(forKey: key) } else { result[key] = member }
        }
        return result.values.contains(.bool(true)) ? .object(result) : .null
    }
}
