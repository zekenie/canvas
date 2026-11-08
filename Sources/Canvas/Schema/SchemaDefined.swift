import CanvasRPC
import Foundation

/// A struct defined by its list of properties: the list is how it's written in a board and read
/// back (its `Codable`), and what its JSON Schema says. Every kind's props are one
/// (`ShapeProps`), and so is any struct stored in them:
///
///     public struct StickyNote: BoxShapeProps {
///         public static let kind: ShapeKind = "sticky-note"
///         public static let properties = Properties<StickyNote>(title: "Sticky note") {
///             Property("frame", \.frame).required()
///             Property("text", \.text).description("What the note says.")
///         }
///         public var frame: CGRect = .zero
///         public var text = ""
///         public init() {}
///     }
///
/// Each property's type comes from its member, and its default from `init()`. A property is named
/// after its member, every stored member is listed (the registry refuses a kind whose list misses
/// one: a board wouldn't save it), and a member missing from a board reads as its default, unless
/// it's `required()`.
public protocol SchemaDefined: Codable, SchemaDescribed, Sendable {
    /// Every member at its default: what a member missing from a board reads as, and each
    /// property's `default`.
    init()
    /// Every stored member, in order.
    static var properties: Properties<Self> { get }
}

/// A type's list of properties, and what its schema says about the type as a whole.
public struct Properties<Root: SchemaDefined>: Sendable {
    public let title: String?
    public let description: String?
    /// Set, the type's schema is a shared definition of this name (`$defs`), which each use refers
    /// to; otherwise it's written out where it's used.
    public let definition: String?
    /// Set, a value of the type reads as this member of it where a text compares it as one value (a query's `[a.type="uuid"]`
    /// reads a type's `words`): the schema says so (`KindSchema.readsAsKeyword`). It must be one of its properties.
    public let readsAs: String?
    /// Set with `readsAs`, the member of it that holds the id of a shape whose name now is what the value reads as instead of its
    /// `readsAs` member, while that shape has a name (`KindSchema.namedByKeyword`): a type as written reads as the name of the type
    /// it names, which a rename of that shape changes with nothing written here. It must be one of its properties.
    public let namedBy: String?
    let list: [AnyProperty<Root>]
    /// Those whose members name shapes (`ShapeNaming`), in list order: all that walking or
    /// renaming the type's names looks at, none for most types.
    let namingProperties: [AnyProperty<Root>]

    public init(title: String? = nil, description: String? = nil, definition: String? = nil, readsAs: String? = nil, namedBy: String? = nil,
                @PropertyListBuilder<Root> _ properties: () -> [AnyProperty<Root>]) {
        self.title = title
        self.description = description
        self.definition = definition
        self.readsAs = readsAs
        self.namedBy = namedBy
        list = properties()
        namingProperties = list.filter { $0.naming != nil }
    }

    /// The properties' names, in order: the keys a board writes.
    public var names: [String] { list.map(\.name) }

    /// The object schema, written out.
    func objectSchema(in definitions: inout SchemaDefinitions) -> JSONObject {
        let id = ObjectIdentifier(Root.self)
        definitions.record(Root.self)
        guard !definitions.inPlace.contains(id) else {
            definitions.problems.append("\(Root.self) holds itself; give it a definition name (Properties(definition:)) so its schema can refer to itself")
            return [:]
        }
        definitions.inPlace.append(id)
        defer { definitions.inPlace.removeLast() }
        // Two, so a default that varies (a new id each time) isn't stated as one.
        let prototype = Root(), another = Root()
        var json: JSONObject = [:]
        if let title { json["title"] = .string(title) }
        if let description { json["description"] = .string(description) }
        json["type"] = "object"
        var properties: JSONObject = [:]
        for property in list { properties[property.name] = .object(property.schema(prototype, another, &definitions)) }
        json["properties"] = .object(properties)
        let required = list.filter(\.isRequired).map { JSONValue.string($0.name) }
        if !required.isEmpty { json["required"] = .array(required) }
        json["additionalProperties"] = false
        if let readsAs {
            if properties[readsAs] == nil { definitions.problems.append("\(Root.self) reads as \(readsAs), which isn't one of its properties") }
            json[KindSchema.readsAsKeyword] = .string(readsAs)
            if let namedBy {
                if properties[namedBy] == nil { definitions.problems.append("\(Root.self) is named by \(namedBy), which isn't one of its properties") }
                json[KindSchema.namedByKeyword] = .string(namedBy)
            }
        }
        return json
    }
}

/// The modifiers a property takes, each adding JSON Schema keywords to what its type says: a kind's
/// own properties (`Property`), and an added property's (`ShapeProperty.keywords`). A bound
/// (`maxLength`, `minimum`, `pattern`) is what a shape can break, and what checking it against its
/// kind's schema finds (`Registry.schemaViolations(of:)`); the rest describe.
public protocol PropertyModifiers {
    /// Any other JSON Schema keywords, as they're written: `.keywords(["multipleOf": 0.5])`.
    func keywords(_ more: JSONObject) -> Self
}

extension PropertyModifiers {
    public func title(_ text: String) -> Self { keywords(["title": .string(text)]) }
    public func description(_ text: String) -> Self { keywords(["description": .string(text)]) }
    public func minimum(_ value: Double) -> Self { keywords(["minimum": .number(value)]) }
    public func maximum(_ value: Double) -> Self { keywords(["maximum": .number(value)]) }
    /// In code points, as JSON Schema counts a string's length.
    public func minLength(_ count: Int) -> Self { keywords(["minLength": .number(Double(count))]) }
    /// In code points, as JSON Schema counts a string's length.
    public func maxLength(_ count: Int) -> Self { keywords(["maxLength": .number(Double(count))]) }
    /// An ECMA-262 regular expression the whole string must match somewhere (anchor it with ^ and $).
    public func pattern(_ regex: String) -> Self { keywords(["pattern": .string(regex)]) }
    public func minItems(_ count: Int) -> Self { keywords(["minItems": .number(Double(count))]) }
    public func maxItems(_ count: Int) -> Self { keywords(["maxItems": .number(Double(count))]) }
    public func deprecated() -> Self { keywords(["deprecated": true]) }
    public func readOnly() -> Self { keywords(["readOnly": true]) }
    /// What a plugin keeps for itself (`x-canvas-unlisted`): neither `canvas draw` nor `canvas
    /// query` lists, reads or writes it, as an attribute or a row's; its plugin gives them words of its
    /// own for what it means (Grouping's groups).
    public func unlisted() -> Self { keywords([KindSchema.unlistedKeyword: true]) }
    /// What the text is, as JSON Schema's `format` names it (`"date"`, or a plugin's own: `x-canvas-query`).
    public func format(_ name: String) -> Self { keywords(["format": .string(name)]) }
}

/// One property: a stored member, named, with anything its schema says beyond its type.
/// `Property("estimate", \.estimate).minimum(0).description("Hours.")`
public struct Property<Root, Value: Codable & SchemaDescribed & Sendable>: PropertyModifiers, Sendable {
    let name: String
    let keyPath: WritableKeyPath<Root, Value> & Sendable
    var keywords: JSONObject = [:]
    var examples: [Value] = []
    var isRequired = false

    public init(_ name: String, _ keyPath: WritableKeyPath<Root, Value> & Sendable) {
        self.name = name
        self.keyPath = keyPath
    }

    /// Has no default: a board, or anyone writing one, must give it. Reading one without it fails.
    public func required() -> Self { with { $0.isRequired = true } }
    public func examples(_ values: Value...) -> Self { with { $0.examples += values } }
    public func keywords(_ more: JSONObject) -> Self { with { $0.keywords.merge(more) { _, new in new } } }

    private func with(_ change: (inout Self) -> Void) -> Self {
        var copy = self
        change(&copy)
        return copy
    }

    var erased: AnyProperty<Root> {
        let name = name, keyPath = keyPath, keywords = keywords, examples = examples, isRequired = isRequired
        let isOptional = Value.self is any OptionalValue.Type
        let isNil: @Sendable (Value) -> Bool = { isOptional && ($0 as? any OptionalValue)?.isNil == true }
        // Found by a check like an optional's, once: a member that names no shape carries nil, and
        // walking or renaming names never looks at it.
        let naming: PropertyNaming<Root>? = Value.self is any ShapeNaming.Type ? PropertyNaming(
            value: { $0[keyPath: keyPath] as! any ShapeNaming },
            rename: { root, rename in
                root[keyPath: keyPath] = (root[keyPath: keyPath] as! any ShapeNaming).renamingShapes(rename) as! Value
            }) : nil
        return AnyProperty(
            name: name,
            isRequired: isRequired,
            valueType: Value.self,
            keyPath: keyPath,
            isOptional: isOptional,
            isNil: { isNil($0[keyPath: keyPath]) },
            naming: naming,
            encode: { root, container in
                let value = root[keyPath: keyPath]
                guard !isNil(value) else { return }
                try container.encode(value, forKey: PropertyCodingKey(name))
            },
            decode: { container, root in
                let key = PropertyCodingKey(name)
                guard container.contains(key), try !container.decodeNil(forKey: key) else {
                    guard !isRequired else {
                        throw DecodingError.keyNotFound(key, .init(codingPath: container.codingPath, debugDescription: "\(name) is missing"))
                    }
                    return
                }
                root[keyPath: keyPath] = try container.decode(Value.self, forKey: key)
            },
            patch: { container, root, prototype in
                let key = PropertyCodingKey(name)
                guard container.contains(key) else { return }
                guard try container.decodeNil(forKey: key) else {
                    root[keyPath: keyPath] = try container.decode(Value.self, forKey: key)
                    return
                }
                guard !isRequired else {
                    throw DecodingError.valueNotFound(Value.self, .init(codingPath: container.codingPath + [key],
                                                                        debugDescription: "it's required, so it can't be null"))
                }
                root[keyPath: keyPath] = prototype[keyPath: keyPath]
            },
            schema: { prototype, another, definitions in
                var json = Value.schema(in: &definitions).merging(keywords) { _, new in new }
                let value = prototype[keyPath: keyPath]
                // A default is what every `init()` gives: one that varies (a new id) is none.
                if !isRequired, !isNil(value), let encoded = try? JSONValue(boardEncoding: value),
                   (try? JSONValue(boardEncoding: another[keyPath: keyPath])) == encoded {
                    json["default"] = encoded
                }
                let encodedExamples = examples.compactMap { try? JSONValue(boardEncoding: $0) }
                if !encodedExamples.isEmpty { json["examples"] = .array(encodedExamples) }
                return json
            })
    }
}

/// A property, whatever its member's type: what a list holds.
public struct AnyProperty<Root>: Sendable {
    let name: String
    let isRequired: Bool
    let valueType: Any.Type
    /// Which member it writes.
    let keyPath: AnyKeyPath & Sendable
    let isOptional: Bool
    /// Whether it's a nil optional in `root`.
    let isNil: @Sendable (Root) -> Bool
    /// Set only when its member names shapes (`ShapeNaming`).
    let naming: PropertyNaming<Root>?
    let encode: @Sendable (Root, inout KeyedEncodingContainer<PropertyCodingKey>) throws -> Void
    let decode: @Sendable (KeyedDecodingContainer<PropertyCodingKey>, inout Root) throws -> Void
    /// Reads its member over `root`'s, as `decode` does, except that a member the container doesn't
    /// have stays as `root` has it, and null puts it back to `prototype`'s (its default), unless
    /// it's required.
    let patch: @Sendable (KeyedDecodingContainer<PropertyCodingKey>, inout Root, _ prototype: Root) throws -> Void
    /// Its schema, with its default read off `prototype`, if `another` (a second `init()`) has the
    /// same one.
    let schema: @Sendable (_ prototype: Root, _ another: Root, inout SchemaDefinitions) -> JSONObject
}

/// How a property whose member names shapes is walked and renamed: pure, so a list's `@Sendable`
/// closures can call it anywhere.
struct PropertyNaming<Root>: Sendable {
    /// The member, as the names it holds.
    let value: @Sendable (Root) -> any ShapeNaming
    /// Renames the member's names in `root`, as `ShapeNaming.renamingShapes` does.
    let rename: @Sendable (inout Root, (ShapeID) -> ShapeID?) -> Void
}

@resultBuilder
public enum PropertyListBuilder<Root> {
    public static func buildExpression<Value>(_ property: Property<Root, Value>) -> [AnyProperty<Root>] { [property.erased] }
    public static func buildBlock(_ parts: [AnyProperty<Root>]...) -> [AnyProperty<Root>] { parts.flatMap { $0 } }
}

extension SchemaDefined {
    /// Each listed property from its key; a missing one keeps `init()`'s value, unless required.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: PropertyCodingKey.self)
        var value = Self()
        for property in Self.properties.list { try property.decode(container, &value) }
        self = value
    }

    /// Each listed property under its name; a nil optional is left out.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: PropertyCodingKey.self)
        for property in Self.properties.list { try property.encode(self, &container) }
    }

    public static func schema(in definitions: inout SchemaDefinitions) -> JSONObject {
        guard let name = properties.definition else { return properties.objectSchema(in: &definitions) }
        return definitions.reference(name, of: Self.self) { properties.objectSchema(in: &$0) }
    }

    /// `base`, with each member `data` (a JSON object, as a board writes one) has read over it:
    /// what it leaves out stays exactly as `base` has it, never written out and read back, and null
    /// puts a member back to its default (`init()`'s), unless it's required.
    static func patching(_ base: Self, with data: Data) throws -> Self {
        let decoder = BoardCodec.makeDecoder()
        decoder.userInfo[.patchBase] = base
        return try decoder.decode(Patched<Self>.self, from: data).value
    }
}

extension CodingUserInfoKey {
    /// The value `Patched` reads members over.
    fileprivate static let patchBase = CodingUserInfoKey(rawValue: "canvas.patchBase")!
}

/// A value read over the one the decoder's `userInfo` holds: `SchemaDefined.patching(_:with:)`.
private struct Patched<Root: SchemaDefined>: Decodable {
    let value: Root

    init(from decoder: any Decoder) throws {
        guard let base = decoder.userInfo[.patchBase] as? Root else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "there's no \(Root.self) to read it over"))
        }
        let container = try decoder.container(keyedBy: PropertyCodingKey.self)
        var value = base
        let prototype = Root()
        for property in Root.properties.list { try property.patch(container, &value, prototype) }
        self.value = value
    }
}

/// A property's name as a coding key.
struct PropertyCodingKey: CodingKey, Sendable {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ name: String) { stringValue = name }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue _: Int) { nil }
}

protocol OptionalValue {
    var isNil: Bool { get }
    static var wrappedType: Any.Type { get }
}

extension Optional: OptionalValue {
    var isNil: Bool { self == nil }
    static var wrappedType: Any.Type { Wrapped.self }
}

extension JSONValue {
    /// A value as a board writes it: dates in ISO 8601 and a number that isn't finite as text
    /// (`BoardCodec`'s coders), where the wire's `init(encoding:)` writes Foundation's default
    /// date and refuses a number that isn't finite.
    init(boardEncoding value: some Encodable) throws {
        self = try BoardCodec.makeDecoder().decode(JSONValue.self, from: BoardCodec.makeEncoder().encode(value))
    }
}

// MARK: Every member listed

/// Element types, for finding the optionals a property holds.
protocol SchemaContainer {
    static var elementType: Any.Type { get }
}

extension Array: SchemaContainer {
    static var elementType: Any.Type { Element.self }
}

extension Set: SchemaContainer {
    static var elementType: Any.Type { Element.self }
}

extension Dictionary: SchemaContainer {
    static var elementType: Any.Type { Value.self }
}

extension Optional: SchemaContainer {
    static var elementType: Any.Type { Wrapped.self }
}

/// What's wrong with a struct's list of properties, as a board would find out too late: a stored
/// member that isn't listed (a board wouldn't save it), a property that names no member, or whose
/// key path isn't that member (a computed view, part of a member), a name or a member listed twice,
/// an optional that's required or has a default that isn't nil (a nil one wouldn't save, or would
/// read back as the default), and optionals inside a collection or another optional (which a schema
/// can't say). Empty when there's nothing. In list order, so the first is always the same.
func propertyListProblems<T: SchemaDefined>(of _: T.Type) -> [String] {
    let name = String(describing: T.self)
    let prototype = T()
    let children = Mirror(reflecting: prototype).children
    let members = children.compactMap(\.label)
    let list = T.properties.list
    let listed = list.map(\.name)
    var problems: [String] = []
    for member in members where !listed.contains(member) {
        problems.append("\(name).\(member) isn't in \(name)'s properties, so boards wouldn't save it")
    }
    var seen: Set<String> = [], twice: Set<String> = []
    for property in listed where !seen.insert(property).inserted && twice.insert(property).inserted {
        problems.append("\(name) lists \(property) twice")
    }
    for property in list {
        guard let member = children.first(where: { $0.label == property.name }) else {
            problems.append("\(name)'s property \(property.name) names no member of \(name); a property is named after its member")
            continue
        }
        // Its key path must be that stored member, whole: not a computed view, nor part of one.
        let isStored = (property.keyPath as? PartialKeyPath<T>).flatMap { MemoryLayout<T>.offset(of: $0) } != nil
        if !isStored || type(of: member.value) != property.valueType {
            problems.append("\(name)'s property \(property.name) doesn't write its member \(property.name); a property's key path is the stored member it's named after")
        }
    }
    var writers: [AnyKeyPath: String] = [:]
    for property in list {
        if let first = writers[property.keyPath] {
            problems.append("\(name)'s properties \(first) and \(property.name) write the same member")
        }
        writers[property.keyPath] = writers[property.keyPath] ?? property.name
        if property.isOptional, property.isRequired {
            problems.append("\(name).\(property.name) is optional and required: a nil one wouldn't save, nor read back")
        } else if property.isOptional, !property.isNil(prototype) {
            problems.append("\(name).\(property.name) is optional with a default that isn't nil, so a nil one would read back as the default")
        }
        if holdsOptionals(property.valueType) {
            problems.append("\(name).\(property.name) holds optionals in a collection or an optional, which a schema can't say")
        }
    }
    return problems
}

/// A struct that holds names of shapes (a member that's `ShapeNaming`) without adopting
/// `ShapeNaming` itself: whatever holds it can't find those names, so a copy would go on naming
/// the originals. A kind's props needn't adopt it, since the core walks them by their list.
func namingProblems<T: SchemaDefined>(of _: T.Type) -> [String] {
    guard !(T.self is any ShapeNaming.Type), let member = T.properties.namingProperties.first?.name else { return [] }
    let name = String(describing: T.self)
    return ["\(name).\(member) names shapes (ShapeNaming), so \(name) must adopt ShapeNaming too (extension \(name): ShapeNaming {}), or a copy would go on naming the originals"]
}

/// Whether a collection (or optional) holds optionals, at any depth.
func holdsOptionals(_ type: Any.Type) -> Bool {
    guard let container = type as? any SchemaContainer.Type else { return false }
    return container.elementType is any OptionalValue.Type || holdsOptionals(container.elementType)
}
