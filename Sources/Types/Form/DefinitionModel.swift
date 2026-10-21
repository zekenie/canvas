import Canvas
import Foundation
import Mentions
import Titles

// What the relationship type's card shows, read from the file as it stands: the type's name, its fields (the one writer's
// `fields(of:)`) and one line for each end arrow (the end type, the row's name and the rule). Nothing is kept: the card
// reads it again whenever a commit might have changed it, and draws what differs.

/// A place the keyboard can be in the card. The text ones have the caret in the form's one cell editor; the others have the
/// keyboard themselves.
public enum DefinitionStop: Hashable, Sendable {
    /// The type's name.
    case title
    /// A field's name and its kind, by the field's key.
    case fieldName(String)
    case fieldKind(String)
    /// A choice's option, by the field's key and its place among the options, and the empty line that adds one.
    case option(String, Int)
    case newOption(String)
    /// The empty line that adds a field.
    case addField
    /// An end's row name, and its two rules, by the end's arrow.
    case endName(ShapeID)
    case needed(ShapeID)
    case onlyOne(ShapeID)

    /// Whether the caret is typed in it.
    public var isText: Bool {
        switch self {
        case .fieldKind, .needed, .onlyOne: false
        default: true
        }
    }
}

/// One end of the type, as its line shows it.
public struct DefinitionEnd: Equatable, Sendable {
    public var carrier: ShapeID
    public var type: ShapeID
    public var side: RelationshipSide
    /// The row's name as the end's arrow says it (its words' first line); empty when it says none.
    public var name: String
    /// What the row is called with none said: `owner` on the from side, the other type's name on the to side.
    public var placeholder: String
    public var rule: EndRule
}

struct DefinitionModel: Equatable {
    /// The type's title; empty while untitled.
    var title: String
    var fields: [DefinedField]
    /// From ends first, then to ends, each in file order.
    var ends: [DefinitionEnd]

    /// Nil when the shape is no relationship type (gone, or its mark taken off).
    @MainActor
    static func read(_ hub: ShapeID, in editor: CanvasEditor) -> DefinitionModel? {
        guard let record = editor.shape(inFile: hub), record[TypeSchemaProperty.self] != nil,
              let relationships = editor.relationships, relationships.graph.isRelationshipType(hub), let types = editor.types else { return nil }
        let graph = relationships.graph
        // Its own ends: those of a type it builds on are that type's to edit.
        let sides = graph.ownSides(of: hub)
        var ends: [DefinitionEnd] = []
        for side in RelationshipSide.allCases {
            for end in sides[side] {
                let row = relationships.rows(for: [end.type], isType: false).first { $0.carriers.contains(end.carrier) }
                ends.append(DefinitionEnd(carrier: end.carrier, type: end.type, side: side, name: end.name ?? "",
                                          placeholder: row?.name(in: types.graph) ?? "", rule: end.rule))
            }
        }
        return DefinitionModel(title: record[TitleProperty.self] ?? "", fields: editor.fieldDefiner?.fields(of: hub) ?? [], ends: ends)
    }

    /// What a text stop holds in this model; nil for a stop that is not there.
    func text(of stop: DefinitionStop) -> String? {
        switch stop {
        case .title: return title
        case .fieldName(let key): return fields.first { $0.key == key }?.name
        case .option(let key, let place):
            guard let field = fields.first(where: { $0.key == key }), field.options.indices.contains(place) else { return nil }
            return field.options[place]
        case .newOption(let key): return fields.contains { $0.key == key && $0.kind == .choice } ? "" : nil
        case .addField: return ""
        case .endName(let carrier): return ends.first { $0.carrier == carrier }?.name
        case .fieldKind, .needed, .onlyOne: return nil
        }
    }
}

/// A line of the card, top to bottom.
enum DefinitionLine: Equatable {
    case title
    case field(Int)
    /// The list of kinds under the field at that place: the kind at that place in `DefinedKind.allCases`.
    case kindChoice(Int, Int)
    case option(Int, Int)
    case newOption(Int)
    case addField
    /// The hairline.
    case rule
    case end(Int)

    /// What can have the keyboard on the line.
    func stops(in model: DefinitionModel) -> [DefinitionStop] {
        switch self {
        case .title: return [.title]
        case .field(let index):
            let field = model.fields[index]
            return field.kind == nil ? [.fieldName(field.key)] : [.fieldName(field.key), .fieldKind(field.key)]
        case .option(let index, let place): return [.option(model.fields[index].key, place)]
        case .newOption(let index): return [.newOption(model.fields[index].key)]
        case .addField: return [.addField]
        case .end(let index):
            let carrier = model.ends[index].carrier
            return [.endName(carrier), .needed(carrier), .onlyOne(carrier)]
        case .kindChoice, .rule: return []
        }
    }
}

extension DefinitionModel {
    /// The lines, with the kinds of the field whose list is open (`listing`) after its line.
    func lines(listing: String?) -> [DefinitionLine] {
        var lines: [DefinitionLine] = [.title]
        for (index, field) in fields.enumerated() {
            lines.append(.field(index))
            if listing == field.key { for kind in DefinedKind.allCases.indices { lines.append(.kindChoice(index, kind)) } }
            if field.kind == .choice {
                for place in field.options.indices { lines.append(.option(index, place)) }
                lines.append(.newOption(index))
            }
        }
        lines.append(.addField)
        if !ends.isEmpty {
            lines.append(.rule)
            for index in ends.indices { lines.append(.end(index)) }
        }
        return lines
    }
}
