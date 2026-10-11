import Canvas
import CoreGraphics
import Find
import Foundation

extension PluginID {
    public static let fieldFind: PluginID = "field-find"
}

/// Field values, for Find: on every kind that says where its rows go and holds `fieldValues`, a text for each
/// field of a note that is one that has a value, as its row shows it; a row with more in it gives every text
/// under it, one a line, at any depth. A hit marks its row's value as a highlighter does, the same mark for
/// each range of the text: a match inside a row with more in it marks that row's summary, a match in a folded
/// row the fold. A type's own note gives nothing (its kinds are not values) and a yes or no has no text.
/// A plugin value of its own, after Find and Types, so a list without Find leaves it out.
public struct FieldFindPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .fieldFind }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.findableTexts("field value",
                                where: { $0.holds(FieldValuesProperty.self) && $0.registry.typeRows(of: $0.kind) != nil },
                                affected: { changes, context in context.service(RowBook.self)?.reached(by: changes) ?? [] },
                                texts: { record, context in context.service(RowBook.self)?.findTexts(of: record) ?? [] },
                                rects: { record, field, ranges, context in
                                    let none = ranges.map { _ in [CGRect]() }
                                    guard let book = context.service(RowBook.self), let rect = book.findRect(of: record, field: field),
                                          let bounds = context.editor.shapeContext.geometry(of: record.id)?.bounds, !bounds.isNull else { return none }
                                    let place = rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
                                    return ranges.map { _ in [place] }
                                })
    }
}

extension RowBook {
    /// What a note that is one shows of its values, as text for Find: a text for each field of its types that
    /// holds a value, named by the field's key, a folded field's too. Read from the record and the resolved
    /// fields alone, never from the rows kept as shown, which the commit being heard may not have let go of.
    func findTexts(of record: AnyShapeRecord) -> [FindableText] {
        guard record[TypeSchemaProperty.self] == nil, kinds.contains(record.kind), let subject = subject(of: record), !subject.isType,
              let values = record[FieldValuesProperty.self], !values.isEmpty, let book = editor?.fieldBook else { return [] }
        var fields: [Resolved.Field] = []
        for item in template(subject).items {
            switch item {
            case .field(let field): fields.append(field.resolved)
            case .fold(let fold): fields.append(contentsOf: fold.folded)
            }
        }
        var texts: [FindableText] = []
        for field in fields {
            guard let held = values[field.field.name].flatMap(FieldValues.pruned) else { continue }
            // A row whose type is gone shows its dashed chip and no text.
            switch book.kind(of: field) {
            case .typeFields(let target), .listOfTypeFields(let target): if editor?.types?.isType(target) != true { continue }
            default: break
            }
            let lines = FieldFind.lines(of: held, field: field, in: book)
            if !lines.isEmpty { texts.append(FindableText(field: field.field.name, text: lines.joined(separator: "\n"))) }
        }
        return texts
    }

    /// Where a field's hit is marked, world units: its row's value as it hugs it, or the fold's words when the
    /// field is folded. Nil for a field no row of the note carries.
    func findRect(of record: AnyShapeRecord, field key: String) -> CGRect? {
        guard let subject = subject(of: record), !subject.isType, kinds.contains(record.kind), let block = rowsRect(of: record) else { return nil }
        let template = template(subject)
        let place = template.items.firstIndex { item in
            switch item {
            case .field(let field): field.path.field == key
            case .fold(let fold): fold.folded.contains { $0.field.name == key }
            }
        }
        guard let place else { return nil }
        let shown = shownRows(of: record, subject: subject, template: template, block: block)
        guard shown.rows.indices.contains(place) else { return nil }
        return focusRect(of: shown.rows[place], class: nil).offsetBy(dx: block.minX, dy: block.minY)
    }
}

@MainActor
enum FieldFind {
    /// Every text a value holds as its field shows it, one a line: a plain value as its row says it, a list's
    /// elements, a group's filled members (a member with more in it by its own texts, to any depth), a list of
    /// groups' elements' members, pairs' names and values, an either by whichever branch the value is, what
    /// no control suits by its strings. A yes or no gives none.
    static func lines(of value: JSONValue, field: Resolved.Field, in book: FieldBook) -> [String] {
        switch book.kind(of: field) {
        case .plain(let kind):
            return shown(value, as: kind)
        case .choices(let options):
            return elements(of: value).flatMap { shown($0, as: .choice(options)) }
        case .list(let kind):
            return elements(of: value).flatMap { shown($0, as: kind) }
        case .group, .typeFields:
            return members(of: value, field: field, in: book)
        case .listOfGroups, .listOfTypeFields:
            guard let item = book.item(of: field) else { return leaves(of: value) }
            return elements(of: value).flatMap { lines(of: $0, field: item, in: book) }
        case .pointer:
            return value.stringValue.map { [$0] } ?? []
        case .pointers:
            return elements(of: value).compactMap(\.stringValue)
        case .pairs(let kind):
            guard let pairs = value.objectValue else { return leaves(of: value) }
            return pairs.keys.sorted().flatMap { key in [key] + (pairs[key].map { shown($0, as: kind) } ?? []) }
        case .either(let first, let second):
            if case .plain(let a) = first, case .plain(let b) = second {
                return a == .yesNo && b == .yesNo ? [] : [FieldText.shown(value, asOneOf: [a, b])]
            }
            let branches = book.branches(of: field)
            for branch in branches where FieldSummary.fits(value, book.kind(of: branch)) {
                return lines(of: value, field: branch, in: book)
            }
            return leaves(of: value)
        case .other:
            return strings(of: value)
        }
    }

    private static func shown(_ value: JSONValue, as kind: PlainKind) -> [String] {
        kind == .yesNo ? [] : [FieldText.shown(value, as: kind)]
    }

    private static func elements(of value: JSONValue) -> [JSONValue] {
        value.arrayValue ?? [value]
    }

    /// A group's, or another type's, filled members in the members' order. A type that is gone has none to
    /// say which is which: the stored object's strings and numbers.
    private static func members(of value: JSONValue, field: Resolved.Field, in book: FieldBook) -> [String] {
        guard let held = value.objectValue else { return leaves(of: value) }
        let fields = book.members(of: field)
        if fields.isEmpty { return leaves(of: value) }
        return fields.flatMap { member -> [String] in
            guard let inner = held[member.field.name].flatMap(FieldValues.pruned) else { return [] }
            return lines(of: inner, field: member, in: book)
        }
    }

    /// The strings and the numbers a value holds, in key order.
    private static func leaves(of value: JSONValue) -> [String] {
        switch value {
        case .string(let text): [text]
        case .number(let number): [FieldText.shortest(number)]
        case .object(let members): members.keys.sorted().flatMap { leaves(of: members[$0] ?? .null) }
        case .array(let elements): elements.flatMap(leaves)
        case .bool, .null: []
        }
    }

    private static func strings(of value: JSONValue) -> [String] {
        switch value {
        case .string(let text): [text]
        case .object(let members): members.keys.sorted().flatMap { strings(of: members[$0] ?? .null) }
        case .array(let elements): elements.flatMap(strings)
        case .number, .bool, .null: []
        }
    }
}
