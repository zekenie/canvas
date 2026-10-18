import Canvas
import Colors
import Foundation

// A type's JSON completes as VS Code completes a JSON Schema: the generic engine (`JSONCompleter`)
// over JSON Schema's own meta-schema (`MetaSchema`), which holds all it knows of JSON Schema as data
// (the keywords, their descriptions, the values they take, when they matter). Code adds only what a
// schema can't say of where in the text it is: which names a `required` list can hold (the same
// object's `properties`), where a `$ref` can point (the root's definitions, and the other types of
// the file), that `$schema` and `$vocabulary` belong at the top (the spec's rule of where, which no
// meta-schema checks), that a type's root takes no `title` (its name is its shape's title), and the
// directives in the root's `properties`: `$title` and the field it names, `$color` and the colors.
// Whoever completes a schema of its own may offer more values at a place (`extra`). Offsets are UTF-16, as
// the code editor's text view counts them.

/// What can be typed where the caret is in a type's JSON: keywords with their descriptions, the
/// values a keyword takes, the fields a `required` list can name, the definitions and types a `$ref`
/// can point to.
public enum TypeCompletions {
    /// The engine over the meta-schema, made once.
    static let engine = JSONCompleter(schema: MetaSchema.root, offers: offers(at:), keys: keys(at:))

    /// What can be typed at the caret at `utf16Caret` in `text`, a schema's JSON, with every range
    /// in UTF-16 (the completions' range into the text, each item's selection within its insert).
    /// Nil where nothing can (`JSONCaret.at`), nothing is offered, or the text is too long to color
    /// (`SchemaCodeColors.maxLength`), as it would be to read at every keystroke. `types` lists the
    /// other types a `$ref` can point to (`type(_:named:detail:)`), asked only where a `$ref`'s value
    /// goes, and `colors` the colors a `$color` can be (`color(_:)`), asked only in one. `extra` adds
    /// values where a value goes (`JSONCompletionPlace`), after the rest.
    @MainActor public static func completions(in text: String, at utf16Caret: Int, types: @MainActor () -> [JSONCompletionOffer] = { [] },
                                   colors: @MainActor () -> [JSONCompletionOffer] = { BuiltInColors.all.map(color) },
                                   extra: @escaping @Sendable (JSONCompletionPlace) -> [JSONCompletionOffer] = { _ in [] }) -> JSONCompletions? {
        let count = text.utf8.count
        guard count <= SchemaCodeColors.maxLength, utf16Caret >= 0 else { return nil }
        // An ASCII text (a schema mostly is) counts alike either way.
        let isASCII = text.utf16.count == count
        guard let offset = isASCII ? utf16Caret : TextOffsets.utf8(ofUTF16: utf16Caret, in: Array(text.utf8)),
              let caret = JSONCaret.at(offset, in: text) else { return nil }
        var others: [JSONCompletionOffer] = [], named: [JSONCompletionOffer] = []
        if case .value(of: "$ref") = caret.position { others = types() }
        if caret.path == colorDirective { named = colors() }
        guard var completions = $asking.withValue(Asking(otherTypes: others, colors: named, extra: extra),
                                                  operation: { engine.completions(at: caret, in: text) })
        else { return nil }
        completions.items.removeAll { !belongs($0, at: caret) }
        guard !completions.items.isEmpty else { return nil }
        if !isASCII {
            let utf16 = SchemaCodeColors.UTF16Offsets(text, utf8Count: count)
            completions.range = utf16[completions.range.lowerBound]..<utf16[completions.range.upperBound]
        }
        for i in completions.items.indices {
            let insert = completions.items[i].insert, selection = completions.items[i].selection
            guard insert.utf16.count != insert.utf8.count else { continue }
            let utf16 = SchemaCodeColors.UTF16Offsets(insert, utf8Count: insert.utf8.count)
            completions.items[i].selection = utf16[selection.lowerBound]..<utf16[selection.upperBound]
        }
        return completions
    }

    // MARK: What only code knows

    /// The meta-schema's schemas of `required` and `$ref`: a place held to one of them is in that
    /// keyword's value. (A schema is known by where it's written.)
    private static let requiredKeyword = MetaSchema.root["properties"]?["required"]
    private static let refKeyword = MetaSchema.root["properties"]?["$ref"]
    /// What `#` is offered as, beside a `$ref`.
    static let wholeSchema = "Whole schema"
    /// What a call adds to the engine's offers, while its completions are made: the other types a
    /// `$ref` can point to, and what the caller adds at a place. One reference, never a closure held
    /// as a task-local's value itself, which a release build's task-local push crashed on.
    final class Asking: Sendable {
        let otherTypes: [JSONCompletionOffer]
        let colors: [JSONCompletionOffer]
        let extra: @Sendable (JSONCompletionPlace) -> [JSONCompletionOffer]
        init(otherTypes: [JSONCompletionOffer], colors: [JSONCompletionOffer], extra: @escaping @Sendable (JSONCompletionPlace) -> [JSONCompletionOffer]) {
            self.otherTypes = otherTypes
            self.colors = colors
            self.extra = extra
        }
    }
    @TaskLocal static var asking: Asking?

    /// A color, as a `$color` holds it: its name, with its value beside it.
    public static func color(_ color: NamedColor) -> JSONCompletionOffer {
        JSONCompletionOffer(string: color.name, detail: ShapeColor.value(color.value).text)
    }

    /// Another type, as a `$ref` points to it: its URI (`SchemaReferences.uri`), offered by its name.
    public static func type(_ type: ShapeID, named name: String, detail: String) -> JSONCompletionOffer {
        JSONCompletionOffer(json: JSONReader.literal(SchemaReferences.uri(of: type)), label: name, detail: detail)
    }

    /// A `required` list's names, and a `$ref`'s targets: its own definitions, then other types;
    /// then what the caller adds.
    static func offers(at place: JSONCompletionPlace) -> [JSONCompletionOffer] {
        let caret = place.caret
        let own: [JSONCompletionOffer]
        switch caret.position {
        case .element where caret.path.last == .member("required") && holds(place.schemas, requiredKeyword):
            own = requirable(caret)
        case .value(of: "$ref") where holds(place.valueSchemas, refKeyword):
            own = targets(in: caret.root) + (asking?.otherTypes ?? [])
        case .value(of: TitleSource.from) where caret.path == titleDirective:
            own = titling(caret)
        case .value(of: TypeColorDirective.keyword) where caret.path == colorDirective:
            own = asking?.colors ?? []
        default:
            own = []
        }
        return own + (asking?.extra(place) ?? [])
    }

    /// Where the root's `$title` and `$color` directives are written, and its `properties`.
    private static let titleDirective: [JSONPathComponent] = [.member("properties"), .member("$" + TitleSource.directive)]
    private static let colorDirective: [JSONPathComponent] = [.member("properties"), .member(TypeColorDirective.key)]
    private static let rootProperties: [JSONPathComponent] = [.member("properties")]

    /// The keys code adds to the meta-schema's: in the root's `properties`, `$title` (written with its one
    /// member and the field to pick) and `$color` (written with its one member and the color to pick); in
    /// `$title`, `x-canvas-from`. Asked only where a key goes.
    static func keys(at caret: JSONCaret) -> [JSONCompletionKeyOffer] {
        if caret.path == rootProperties {
            let value = "{\"\(TitleSource.from)\": \"\"}", color = "{\"\(TypeColorDirective.keyword)\": \"\"}"
            return [JSONCompletionKeyOffer(key: "$" + TitleSource.directive, detail: "Titles a note from a field", value: value,
                                           selection: (value.utf8.count - 2)..<(value.utf8.count - 2), reopens: true),
                    JSONCompletionKeyOffer(key: TypeColorDirective.key, detail: "The type's color", value: color,
                                           selection: (color.utf8.count - 2)..<(color.utf8.count - 2), reopens: true)]
        }
        if caret.path == titleDirective {
            return [JSONCompletionKeyOffer(key: TitleSource.from, detail: "The field", value: "\"\"", selection: 1..<1, reopens: true)]
        }
        return []
    }

    /// The root's fields that can title a note (text, a number, a date or a choice), each with its type in a
    /// word or two; a field that is a `#` reference is read through it one step. One that is inherited is
    /// not here: the tab sees this type's text, and typed by hand it works through the chain.
    static func titling(_ caret: JSONCaret) -> [JSONCompletionOffer] {
        var named = Set<String>()
        return (caret.root["properties"]?.members ?? []).compactMap { member in
            guard SchemaDirectives.isField(member.key), named.insert(member.key).inserted else { return nil }
            var node = member.value
            if let ref = node["$ref"]?.string, ref.hasPrefix("#"), let target = JSONPointer(ref)?.resolve(in: caret.root) { node = target.value }
            guard TitleSource.titles(FieldKindReader.kind(of: SchemaValue(node))) != nil else { return nil }
            return JSONCompletionOffer(string: member.key, detail: SchemaFieldType(node).label)
        }
    }

    private static func holds(_ schemas: [JSONNode], _ keyword: JSONNode?) -> Bool {
        guard let keyword else { return false }
        return schemas.contains { $0.range == keyword.range }
    }

    /// Whether a candidate goes where it's offered, as the spec has it (core §8.1): `$vocabulary`
    /// only in the root schema (never in a subschema), and `$schema` only in a schema resource's
    /// root, the root or a subschema with an `$id`; and no `title` at the root, where a type's name
    /// is its shape's title.
    static func belongs(_ item: JSONCompletionItem, at caret: JSONCaret) -> Bool {
        guard case .key = caret.position else { return true }
        guard !caret.path.isEmpty else { return item.label != "title" }
        // A directive's one member: the meta-schema would offer every keyword of a property's schema there.
        if caret.path == titleDirective { return item.label == TitleSource.from }
        if caret.path == colorDirective { return item.label == TypeColorDirective.keyword }
        switch item.label {
        case "$vocabulary": return false
        case "$schema": return caret.siblings.contains { $0.key == "$id" }
        default: return true
        }
    }

    /// The names in the `properties` of the object whose `required` list the caret is in, that the
    /// list doesn't hold yet, each with its type in a word or two (`SchemaFieldType.label`).
    static func requirable(_ caret: JSONCaret) -> [JSONCompletionOffer] {
        guard caret.containers.count >= 2 else { return [] }
        let object = caret.containers[caret.containers.count - 2]
        let listed = Set(caret.elements.compactMap(\.string))
        var named = Set<String>()
        // At the root a `$` key is a directive (`$title`), not a field a list can name.
        let isRoot = caret.path == [.member("required")]
        return (object["properties"]?.members ?? []).compactMap { property in
            guard !listed.contains(property.key), !isRoot || SchemaDirectives.isField(property.key), named.insert(property.key).inserted else { return nil }
            return JSONCompletionOffer(string: property.key, detail: SchemaFieldType(property.value).label)
        }
    }

    /// Where a `$ref` can point: the whole schema, and each of the root's definitions (`$defs`, and
    /// the older `definitions`), each with its type in a word or two (`SchemaFieldType.label`).
    static func targets(in root: JSONNode) -> [JSONCompletionOffer] {
        var offers = [JSONCompletionOffer(string: "#", detail: wholeSchema)]
        for keyword in ["$defs", "definitions"] {
            for definition in root[keyword]?.members ?? [] {
                offers.append(JSONCompletionOffer(string: "#/\(keyword)/\(pointerToken(definition.key))",
                                                  detail: SchemaFieldType(definition.value).label))
            }
        }
        return offers
    }

    /// A name as a JSON pointer's step in a URI's fragment: `~` and `/` escaped as the pointer
    /// escapes them, then what a fragment can't hold percent-encoded, as `SchemaResolver` reads it.
    /// (The core writes a `$ref` the same way, `JSONPointer.escaped` then `fragment`, which it keeps
    /// to itself.)
    static func pointerToken(_ name: String) -> String {
        let escaped = name.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
        return escaped.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? escaped
    }
}

extension TypeIndex {
    /// The types a `$ref` in the schema of `id` can point to, as its JSON's completions offer them:
    /// every other titled type of the file but a relationship type (`canBeEmbedded`), by its name (what its mentions show), its fields counted,
    /// in the order of their names.
    public func referenceTargets(from id: ShapeID) -> [JSONCompletionOffer] {
        var found: [(name: String, type: ShapeID, detail: String)] = []
        for type in types where type != id && canBeEmbedded(type) {
            guard let name = name(of: type), let schema = schemaText(of: type) else { continue }
            let shown = SchemaReadings.reading(of: schema, for: type).shown
            found.append((name, type, TypePanelText.subtitle(shown) ?? ""))
        }
        found.sort { a, b in
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.type.description < b.type.description : order == .orderedAscending
        }
        return found.map { TypeCompletions.type($0.type, named: $0.name, detail: $0.detail) }
    }
}

/// UTF-16 offsets (`NSString`'s) as UTF-8 ones: the other way is `SchemaCodeColors.UTF16Offsets`.
enum TextOffsets {
    /// The UTF-8 offset of UTF-16 offset `target`, counted a scalar at a time from the text's start:
    /// the start of the character it's in (a surrogate pair's second half is its first's); nil past
    /// the end.
    static func utf8(ofUTF16 target: Int, in bytes: [UInt8]) -> Int? {
        var utf16 = 0, i = 0
        while i < bytes.count {
            let lead = bytes[i]
            let units = lead >= 0xF0 ? 2 : 1
            if utf16 + units > target { return i }
            utf16 += units
            i += lead < 0x80 ? 1 : lead < 0xE0 ? 2 : lead < 0xF0 ? 3 : 4
        }
        return target == utf16 ? bytes.count : nil
    }
}
