import Canvas
import Foundation

/// What a row with more in it reads: one line in plain words, then `›`. One place, so the row, the fold
/// and the card's head say the same.
public enum FieldSummary: Equatable, Sendable {
    /// Nothing yet: `add gift note`, faint italic (`FieldWords.add`).
    case empty(String)
    /// A plain value; an either, as whichever branch the value is.
    case value(String)
    /// Values joined by commas; the drawer ends the line `+N` when it is cut.
    case items([String])
    /// `2 items`.
    case count(Int)
    /// The first pair and how many more: `size: L, +1`.
    case pair(first: String, more: Int)
    /// Slice 14: the stored tokens of notes a field points at. K0 never produces it.
    case pills(targets: [String], more: Int)
    /// A field no control suits: `edited as JSON in the panel`.
    case json

    /// The summary of the value `field` holds (nil for none), read by the field's kind. `types` is the
    /// shape's own list, as `FieldBook.field(at:types:)` takes it.
    @MainActor
    public static func of(_ value: JSONValue?, field: Resolved.Field, in book: FieldBook, types: [ShapeID],
                          locale: Locale = .autoupdatingCurrent) -> FieldSummary {
        let empty = FieldSummary.empty(FieldWords.add(FieldName.words(of: field.field)))
        guard let value, let value = FieldValues.pruned(value) else { return empty }
        return summary(of: value, field: field, in: book, locale: locale) ?? empty
    }

    /// The summary as one string, the way a group's summary holds a member that has more in it:
    /// `2 items`, `gift, mugs`, `size: L, +1`.
    public var text: String {
        switch self {
        case .empty(let words): words
        case .value(let text): text
        case .items(let items): items.joined(separator: ", ")
        case .count(let count): FieldWords.items(count)
        case .pair(let first, let more): more > 0 ? "\(first), +\(more)" : first
        case .pills(let targets, let more): (targets + (more > 0 ? ["+\(more)"] : [])).joined(separator: ", ")
        case .json: FieldWords.editedAsJSON
        }
    }

    // MARK: Reading

    @MainActor
    private static func summary(of value: JSONValue, field: Resolved.Field, in book: FieldBook, locale: Locale) -> FieldSummary? {
        switch book.kind(of: field) {
        case .plain(let kind):
            return .value(FieldText.shown(value, as: kind, locale: locale))
        case .choices(let options):
            return items(of: value, locale: locale) { FieldText.shown($0, as: .choice(options), locale: locale) }
        case .list(let kind):
            return items(of: value, locale: locale) { FieldText.shown($0, as: kind, locale: locale) }
        case .group, .typeFields:
            return group(value, field: field, in: book, locale: locale)
        case .listOfGroups, .listOfTypeFields:
            guard let elements = value.arrayValue else { return .value(FieldText.shown(value, asOneOf: [], locale: locale)) }
            return .count(elements.count)
        case .pointer:
            return .value(value.stringValue ?? FieldText.shown(value, asOneOf: [], locale: locale))
        case .pointers:
            guard let elements = value.arrayValue else { return .value(value.stringValue ?? FieldText.shown(value, asOneOf: [], locale: locale)) }
            return .value(elements.map { $0.stringValue ?? FieldText.shown($0, asOneOf: [], locale: locale) }.joined(separator: ", "))
        case .pairs(let kind):
            guard let members = value.objectValue else { return .value(FieldText.shown(value, asOneOf: [], locale: locale)) }
            guard let first = members.keys.sorted().first, let firstValue = members[first] else { return nil }
            return .pair(first: "\(first): \(FieldText.shown(firstValue, as: kind, locale: locale))", more: members.count - 1)
        case .either(let first, let second):
            return either(value, first, second, field: field, in: book, locale: locale)
        case .other:
            return .json
        }
    }

    private static func items(of value: JSONValue, locale: Locale, shown: (JSONValue) -> String) -> FieldSummary {
        guard let elements = value.arrayValue else { return .value(FieldText.shown(value, asOneOf: [], locale: locale)) }
        return .items(elements.map(shown))
    }

    /// A group and another type's fields: the filled members' shown values in the members' order, a member
    /// with more in it as its own summary (`2 items`), a ticked box as its name. A type that is gone has no
    /// members: the stored object's string and number leaves, in key order.
    @MainActor
    private static func group(_ value: JSONValue, field: Resolved.Field, in book: FieldBook, locale: Locale) -> FieldSummary? {
        guard let members = value.objectValue else { return .value(FieldText.shown(value, asOneOf: [], locale: locale)) }
        let fields = book.members(of: field)
        var shown: [String] = []
        if fields.isEmpty {
            shown = leaves(of: value)
        } else {
            for member in fields {
                guard let held = members[member.field.name] else { continue }
                if case .plain(.yesNo) = book.kind(of: member) {
                    if held == .bool(true) { shown.append(FieldName.words(of: member.field)) }
                } else if let text = summary(of: held, field: member, in: book, locale: locale)?.text {
                    shown.append(text)
                }
            }
        }
        return shown.isEmpty ? nil : .items(shown)
    }

    private static func leaves(of value: JSONValue) -> [String] {
        switch value {
        case .string(let text): [text]
        case .number(let number): [FieldText.shortest(number)]
        case .object(let members): members.keys.sorted().flatMap { leaves(of: members[$0] ?? .null) }
        case .array(let elements): elements.flatMap(leaves)
        case .bool, .null: []
        }
    }

    /// An either, as whichever branch the value is.
    @MainActor
    private static func either(_ value: JSONValue, _ first: FieldKind, _ second: FieldKind, field: Resolved.Field, in book: FieldBook,
                               locale: Locale) -> FieldSummary? {
        let branches = book.branches(of: field)
        if case .plain(let a) = first, case .plain(let b) = second {
            return .value(FieldText.shown(value, asOneOf: [a, b], locale: locale))
        }
        guard branches.count == 2 else { return .value(FieldText.shown(value, asOneOf: [], locale: locale)) }
        for branch in branches where fits(value, book.kind(of: branch)) {
            return summary(of: value, field: branch, in: book, locale: locale)
        }
        return .value(FieldText.shown(value, asOneOf: [], locale: locale))
    }

    /// Whether a stored value is the shape of a kind: a list for the kinds of lists, an object for the
    /// kinds of groups, a scalar for the rest.
    private static func fits(_ value: JSONValue, _ kind: FieldKind) -> Bool {
        switch (kind, value) {
        case (.choices, .array), (.list, .array), (.listOfGroups, .array), (.listOfTypeFields, .array), (.pointers, .array): true
        case (.group, .object), (.typeFields, .object), (.pairs, .object): true
        case (.plain, .array), (.plain, .object), (.pointer, .array), (.pointer, .object): false
        case (.plain, _), (.pointer, _): true
        case (.either(let a, let b), _): fits(value, a) || fits(value, b)
        default: false
        }
    }
}
