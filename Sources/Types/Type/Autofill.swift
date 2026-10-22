import Canvas

/// Whether a shape of a type fills its fields from its words, a language model reading them (`FieldFill`): on a
/// shape of a type, its own say, held only where it differs from what its types say; on a type, what its shapes
/// do unless they say otherwise, kept in step with its schema's `$autofill` (`TypeAutofillDirective`). None: as its
/// types say (the first of its chain's types that holds one), and with none saying, on (`TypeIndex.autofills`). On
/// the kinds that can be instances (`typeable()`), which a type's note is too.
public enum AutofillProperty {}

extension AutofillProperty: ShapeProperty {
    public static let key: PropertyKey = "autofill"
    public static var defaultValue: Bool? { nil }
    public static var keywords: PropertyKeywords<Bool> {
        PropertyKeywords().description("Whether the shape fills its fields from its words, which a language model reads; on a type, whether the shapes of it do unless they say otherwise. None: as its types say, else true.")
    }
}

/// Whether a type's shapes fill their fields from their words, in its schema: `"$autofill": {"const": false}`, a
/// directive in the root's `properties` beside `$title` and `$color` (`HeldDirective`), its `const` true or false. It
/// says what the type's shape's own `autofill` says, and every write keeps the two saying it (`keep`, the rule
/// `canBeType()` gives the kind), as `$color` and a type's color are kept: the panel's box and draw's `autofill:` write
/// the JSON, and the member typed in the JSON (or written by draw's `schema:`, or by words that are JSON) is the
/// shape's `autofill`; taking the member out takes it away. A type built on it says the same unless it says
/// otherwise (`TypeIndex.autofills`, through the chain).
public enum TypeAutofillDirective {
    public static let name = "autofill"
    public static let key = "$" + name
    static let directive = HeldDirective(name: name)

    /// What a schema says of whether its type's shapes fill their fields.
    public enum Reading: Equatable, Sendable {
        /// No `$autofill`.
        case none
        case autofills(Bool)
        /// An `$autofill` that isn't `{"const": true}` or `{"const": false}`.
        case notABool
    }

    /// What `text` says; nil while it isn't a JSON object (a text being typed says nothing).
    public static func reading(of text: String) -> Reading? {
        guard let root = try? JSONReader.read(text), root.isObject else { return nil }
        return reading(of: root)
    }

    /// What a schema's root says (the last `$autofill` of the last `properties`, as JSON is read).
    public static func reading(of root: JSONNode) -> Reading {
        guard let member = directive.member(in: root) else { return .none }
        guard let said = member[HeldDirective.keyword]?.bool else { return .notABool }
        return .autofills(said)
    }

    /// Whether a reading says what a shape's own `autofill` does: none for none, the same for the same.
    public static func says(_ reading: Reading, _ autofills: Bool?) -> Bool {
        switch (reading, autofills) {
        case (.none, nil): true
        case let (.autofills(said), held?): said == held
        default: false
        }
    }

    /// `text` saying `autofills`: the `const` of its `$autofill` replaced, else the member put in first in the
    /// root's `properties`; with nil, every `$autofill` taken out. Nil when the text isn't a JSON object or its
    /// `properties` isn't one. The rest of the text stays as typed.
    public static func text(_ text: String, saying autofills: Bool?) -> String? {
        guard let autofills else { return directive.removed(from: text) }
        return directive.text(text, saying: autofills ? "true" : "false", isSaid: { $0.bool == autofills })
    }

    /// The rule `canBeType()` gives a kind (`keepsInStep`): after every write a type's `autofill` and its
    /// `$autofill` say one thing, as `TypeColorDirective.keep` keeps its color and `$color`. A write that changes
    /// the member (or a schema that comes with one) gives the shape that say (none, the member taken out; nothing,
    /// one that isn't true or false); else a write that changes the shape's say (or a shape that comes, or is made a
    /// type, with one) writes it in the member, a text that isn't a JSON object staying as it is. Both changed, the
    /// member wins. Two that disagree with neither changed are left until either changes.
    public static func keep(_ before: AnyShapeRecord?, _ record: inout AnyShapeRecord) {
        guard let schema = record[TypeSchemaProperty.self] else { return }
        let held = before?[TypeSchemaProperty.self]
        let own = record[AutofillProperty.self]
        let ownMoved = held == nil || before?[AutofillProperty.self] != own
        let textMoved = held?.text != schema.text
        // With no say and no `$autofill` in the text there is nothing to keep, and nothing to read.
        guard ownMoved || textMoved, own != nil || schema.text.contains(key) || held?.text.contains(key) == true,
              let now = reading(of: schema.text), !says(now, own) else { return }
        // As the color's: a text before that was being typed is taken as having said what the shape held then.
        let directiveMoved = textMoved && (held.map { reading(of: $0.text).map { $0 != now } ?? !says(now, before?[AutofillProperty.self]) } ?? (now != .none))
        if directiveMoved {
            switch now {
            case .none: record[AutofillProperty.self] = nil
            case .autofills(let said): record[AutofillProperty.self] = said
            case .notABool: break
            }
        } else if ownMoved, let written = text(schema.text, saying: own), written != schema.text {
            record[TypeSchemaProperty.self] = SchemaText(written)
        }
    }
}
