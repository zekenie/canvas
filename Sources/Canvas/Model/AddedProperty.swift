import Foundation

/// A property a plugin adds to the kinds that opt in: something those shapes know (a title, say)
/// that the kinds don't declare themselves. The type is the key, as with detail tabs and extension
/// points, and says everything about the property once:
///
///     public enum TitleProperty {}
///     extension TitleProperty: ShapeProperty {
///         public static let key: PropertyKey = "title"
///         public static var defaultValue: String? { nil }
///     }
///
/// The plugin that owns it declares it (`registrar.declare(TitleProperty.self)`), and a kind opts
/// in, usually through that plugin's sugar (`note.title()`, which calls
/// `optIn(to: TitleProperty.self)`). Its value is then in each shape's record,
/// `shape[TitleProperty.self]`, changed in a transaction like the props, and saved with the
/// shape, in the board beside its props. The kind's schema (`registry.schema(for:)`) gains it as
/// one property, and its history (`migrations`) is its own, whatever kinds opt in.
///
/// For what a plugin keeps *about* a shape rather than what the shape knows (the shape it was
/// copied from), use `ShapeMeta`.
public protocol ShapeProperty {
    associatedtype Value: SchemaDescribed & Codable & Equatable & Sendable
    /// Where boards keep it, and its name in each kind's schema. Unique among added properties,
    /// never one of an opted-in kind's own property names, and never changed once shipped.
    static var key: PropertyKey { get }
    /// What every shape of a kind that opts in has until it's changed, filled in wherever shapes
    /// enter an editor (placed, inserted, opened). Nil: only the shapes it's set on have one, and
    /// setting it to nil removes it.
    static var defaultValue: Value? { get }
    /// What its schema says beyond its value's type, in the modifiers a kind's own properties take:
    /// `PropertyKeywords().description("What the shape is called.").minLength(1).maxLength(80)`. A
    /// bound is what a shape's value can break (`Registry.schemaViolations(of:)`). None by default.
    static var keywords: PropertyKeywords<Value> { get }
    /// Whether a value is no value at all, as a title of only spaces is Titles' none: a shape set
    /// to one, or read from a board with one, holds nil instead, or the default for a property that
    /// has one, so no shape ever holds it (and a default can't be one). Never, by default.
    static func isNone(_ value: Value) -> Bool
    /// Append only; the count is the version boards record. See `PropertyMigration`.
    static var migrations: [PropertyMigration] { get }
}

extension ShapeProperty {
    public static var keywords: PropertyKeywords<Value> { PropertyKeywords() }
    public static func isNone(_: Value) -> Bool { false }
    public static var migrations: [PropertyMigration] { [] }
    /// How many steps the value has been through: what a board records for this property.
    public static var version: Int { migrations.count }
}

/// What an added property's schema says beyond its value's type (`ShapeProperty.keywords`), in the
/// modifiers a kind's own properties take (`Property`'s).
public struct PropertyKeywords<Value: Encodable>: PropertyModifiers, Sendable {
    /// The keywords, as they're written into the schema of each kind that opts in.
    public private(set) var json: JSONObject = [:]

    public init() {}

    public func keywords(_ more: JSONObject) -> Self {
        var copy = self
        copy.json.merge(more) { _, new in new }
        return copy
    }

    public func examples(_ values: Value...) -> Self {
        let more = values.compactMap { try? JSONValue(encoding: $0) }
        return keywords(["examples": .array((json["examples"]?.arrayValue ?? []) + more)])
    }
}

/// One step in an added property's history: rewrites one shape's value, as JSON (whatever JSON it
/// is: an object, an array, a string), from the version before it to its own. The rules are a
/// kind's (`PropsMigration`): append only, pure and deterministic, and up only.
public struct PropertyMigration: Sendable {
    /// Says what the step does, for error messages.
    public let name: String
    let body: @Sendable (inout JSONValue) throws -> Void

    public init(_ name: String, _ body: @escaping @Sendable (_ value: inout JSONValue) throws -> Void) {
        self.name = name
        self.body = body
    }

    /// A step that rewrites nothing (a new member with a default); see `PropsMigration.init(_:)`.
    public init(_ name: String) {
        self.init(name) { _ in }
    }
}

// MARK: Values in a record

/// A shape's added properties: typed values (never JSON in memory, so drawing never decodes), and
/// the values this app can't use, kept as the JSON they were, at their version, to be written back.
struct AddedValues: Equatable, Sendable {
    private(set) var values: [PropertyKey: any AddedValue] = [:]
    var kept: [PropertyKey: KeptJSON] = [:]

    var isEmpty: Bool { values.isEmpty && kept.isEmpty }
    var keys: some Collection<PropertyKey> { values.keys }

    subscript<P: ShapeProperty>(_: P.Type) -> P.Value? {
        get { (values[P.key] as? Boxed<P.Value>)?.value }
        set {
            let value = newValue.flatMap { P.isNone($0) ? P.defaultValue : $0 }
            // A kept value stays as it was, and a property every shape has can't be removed.
            guard kept[P.key] == nil, value != nil || P.defaultValue == nil else { return }
            values[P.key] = value.map(Boxed.init)
        }
    }

    subscript(key: PropertyKey) -> (any AddedValue)? {
        get { values[key] }
        set { values[key] = newValue }
    }

    /// Every value kept aside: what a shape the app can't use holds.
    mutating func keepAll(at versions: (PropertyKey) -> Int) {
        for (key, value) in values {
            if let json = try? JSONValue(encoding: value) { kept[key] = KeptJSON(version: versions(key), json: json) }
        }
        values = [:]
    }

    static func == (a: Self, b: Self) -> Bool {
        a.kept == b.kept && a.values.count == b.values.count
            && a.values.allSatisfy { key, value in b.values[key].map(value.isEqual) ?? false }
    }
}

/// A value this app can't use, as it was read: its version, and its JSON.
struct KeptJSON: Equatable, Sendable {
    var version: Int
    var json: JSONValue
}

/// An added property's value, whatever its type.
protocol AddedValue: Encodable, Sendable {
    func isEqual(to other: any AddedValue) -> Bool
}

struct Boxed<Value: Codable & Equatable & Sendable>: AddedValue {
    let value: Value
    func isEqual(to other: any AddedValue) -> Bool { (other as? Self)?.value == value }
    /// Through a single-value container, so the encoder's settings apply (a date as a board writes one).
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

extension AnyShapeRecord {
    /// The value of an added property; nil if the shape has none (its kind doesn't opt in, the
    /// property's default is nil and it's unset, or the value is kept aside). Setting it changes
    /// the shape in a transaction, like its props: `tx.update(id) { $0[TitleProperty.self] = "Plans" }`.
    /// A value set on a kind that doesn't opt in is dropped when the transaction takes it, as is
    /// nil for a property every shape has, and anything set on a value that's kept aside. A value
    /// that's no value at all (`ShapeProperty.isNone`, a blank title) sets nil, or the default.
    public subscript<P: ShapeProperty>(_ property: P.Type) -> P.Value? {
        get { added[P.self] }
        set { added[P.self] = newValue }
    }

    /// Added properties this shape holds values for that the app can't use, kept as they were.
    public var keptProperties: [PropertyKey] { added.kept.keys.sorted { $0.rawValue < $1.rawValue } }
}

extension ShapeRecord {
    /// The value of an added property, as on `AnyShapeRecord`: what a definition, a row or a rule
    /// reads beside the kind's own props.
    public subscript<P: ShapeProperty>(_ property: P.Type) -> P.Value? {
        get { added[P.self] }
        set { added[P.self] = newValue }
    }
}
