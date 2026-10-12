import Canvas
import Draw
import Mentions
import Queries

/// Types' values in draw, in Types: `fieldValues: {…}` joins what a shape holds, member by member
/// at every depth (a list replaced whole, `null` clearing the member it is written at), so a statement
/// names only what it changes and a script run again says `unchanged`. The merged value goes through
/// the property's own rule (`FieldValues.pruned`: empties are not kept), so what is compared and what
/// is stored are the same. A string that is exactly `@[Title]`, at any depth, is a pointer: it is written
/// as the token of the shape called Title (`FieldPointers`). And it reports on each shape a run draws, changes or restates: its row's
/// `problems` (what its values still need and what is wrong, as the check of the run says it, against types
/// the script draws too), and, for a shape the run wrote values on, each member no field of its types
/// names (kept, and warned about).
public struct FieldValuesPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { "draw-field-values" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.drawValueWriter(for: FieldValuesProperty.key, write: { value, context throws(DrawError) in
            try FieldPointers.written(value, in: context)
        }, merge: { written, held in
            FieldValues.pruned(FieldValuesMerge.merged(written, into: held)) ?? .null
        })
        registrar.drawReports { record, written, shapes in
            guard let reading = shapes.reading, let checks = reading.service(FieldChecks.self) else { return DrawShapeReport() }
            let values = written?[FieldValuesProperty.key.rawValue]?.objectValue
            let drawn = checks.drawn(record, written: values, reading: reading)
            var report = DrawShapeReport(problems: drawn.check.problems.map { problem in
                ShapeProblem(field: problem.path.field, path: problem.path.isRoot ? nil : problem.path.pointer, class: problem.kind.word, message: problem.message)
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
            return report
        }
    }
}

/// The merge, pure (public so a test of Types reaches it without `@testable`).
public enum FieldValuesMerge {
    /// `written` over `held`: `null` is `null` (the whole property off); an object is set member by
    /// member over the object held (nothing, a scalar or a list held is nothing to keep), a `null`
    /// member removing that member, any other joined with what the member holds; anything else
    /// (a list, a scalar) is the written value, whole. A `null` inside an object written where nothing is
    /// held clears nothing and is dropped, never stored. An object that sets nothing (only `null`s and
    /// empties) over a scalar or a list held leaves it: clearing a member under a value of the other shape
    /// clears nothing, as the one writer's `FieldValues.setting` has it (an address that was text, its type's
    /// field a group now, keeps its street when `{"unit": null}` is written under it).
    public static func merged(_ written: JSONValue, into held: JSONValue?) -> JSONValue {
        guard case .object(let members) = written else { return written }
        if let held, held.objectValue == nil, FieldValues.pruned(written) == nil { return held }
        var result: JSONObject = held?.objectValue ?? [:]
        for (key, member) in members {
            if member == .null {
                result.removeValue(forKey: key)
            } else {
                result[key] = merged(member, into: result[key])
            }
        }
        return .object(result)
    }
}

/// The pointers a script writes: in a value of `fieldValues`, at any depth (an object's members, a list's
/// items), a string that is exactly `@[Title]` becomes the token of the shape called Title, found and refused as
/// a text's mention is (`MentionTextsPlugin.shape(named:in:scope:)`). No type is asked: the target is any
/// mentionable shape, and whether it is the field's type is the check's to say. Nothing here spells the
/// grammar: Mentions reads a title (`MentionToken.shorthand`), a whole token (`MentionToken.read`) and writes
/// the token (`MentionToken.write`).
@MainActor
enum FieldPointers {
    static func written(_ value: JSONValue, in context: DrawTextContext) throws(DrawError) -> JSONValue {
        switch value {
        case .string(let text):
            return try pointer(text, in: context)
        case .array(let items):
            var written = items
            for index in items.indices { written[index] = try self.written(items[index], in: context) }
            return .array(written)
        case .object(let members):
            var written = members
            for key in members.keys.sorted() { written[key] = try self.written(members[key]!, in: context) }
            return .object(written)
        case .null, .bool, .number:
            return value
        }
    }

    /// `text` as a pointer is written. A whole token is kept as it is (an agent copying a query's row), `@[` among
    /// other text is text, and `\@[Title]` is the text `@[Title]`, the backslash dropped (a value holds plain
    /// strings, not mention text, so nothing else escapes it).
    private static func pointer(_ text: String, in context: DrawTextContext) throws(DrawError) -> JSONValue {
        guard text.utf8.contains(0x5B), MentionToken.read(text) == nil else { return .string(text) }
        if text.hasPrefix("\\"), case let rest = String(text.dropFirst()), MentionToken.shorthand(rest) != nil { return .string(rest) }
        guard text == "@[]" || MentionToken.shorthand(text) != nil else { return .string(text) }
        let shape = try MentionTextsPlugin.shape(named: MentionToken.shorthand(text) ?? "", in: context, scope: nil)
        return .string(MentionToken.write(shape.id, label: shape.title))
    }
}
