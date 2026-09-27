import Foundation

// Added properties (`ShapeProperty`): the plugin that owns one declares it, and kinds opt in.

extension PluginRegistrar {
    /// Declares an added property this plugin owns, so that kinds can opt into it. At most one
    /// plugin declares each key.
    public mutating func declare<P: ShapeProperty>(_: P.Type) {
        contribute(PropertyDeclaration(P.self), to: CorePoints.PropertyDeclarations.self)
    }

    /// Opts another plugin's kind into an added property: a bridge's form, for a kind whose plugin
    /// has never heard of the property.
    public mutating func optIn<K: ShapeProps, P: ShapeProperty>(_: K.Type, to _: P.Type) {
        contribute(PropertyOptIn(key: P.key, appliesTo: nil), to: CorePoints.PropertyOptIns.self, for: .kind(K.kind))
    }

    /// Opts every kind into an added property, or every kind `appliesTo` picks by its definition
    /// (so by capability). A kind opts in once: this and its own opt-in can't both hold.
    public mutating func optInEveryShape<P: ShapeProperty>(to _: P.Type, where appliesTo: @escaping @MainActor (any ShapeDefinition) -> Bool = { _ in true }) {
        contribute(PropertyOptIn(key: P.key, appliesTo: appliesTo), to: CorePoints.PropertyOptIns.self, for: .any)
    }
}

extension ShapeRegistrar {
    /// Opts this kind into an added property: its shapes hold a value for it, and its schema has
    /// it. A horizontal calls this from its own sugar (`note.checklist()`), which brings the rest.
    public mutating func optIn<P: ShapeProperty>(to _: P.Type) {
        contribute(PropertyOptIn(key: P.key, appliesTo: nil), to: CorePoints.PropertyOptIns.self)
    }
}

extension CorePoints {
    enum PropertyDeclarations: KeyedExtensionPoint {
        typealias Contribution = PropertyDeclaration
        static var owner: PluginID { .core }
        static func uniqueKeys(of c: PropertyDeclaration, for _: ShapeTarget) -> [AnyHashable] { [c.codec.key] }
    }

    enum PropertyOptIns: KeyedExtensionPoint {
        typealias Contribution = PropertyOptIn
        static var owner: PluginID { .core }
        /// A kind's own opt-ins, once each; every-kind ones are checked when they're expanded.
        static func uniqueKeys(of c: PropertyOptIn, for target: ShapeTarget) -> [AnyHashable] {
            target == .any ? [] : [OptInKey(target: target, key: c.key)]
        }
    }
}

struct OptInKey: Hashable, CustomStringConvertible {
    let target: ShapeTarget
    let key: PropertyKey
    var description: String { "\(target)'s \(key)" }
}

struct PropertyDeclaration {
    let codec: PropertyCodec
    init<P: ShapeProperty>(_: P.Type) { codec = PropertyCodec(P.self) }
}

struct PropertyOptIn {
    let key: PropertyKey
    /// For an every-kind opt-in: which kinds. Nil for one kind's own.
    let appliesTo: (@MainActor (any ShapeDefinition) -> Bool)?
}

/// An added property, erased: how its values are read, written, migrated and described. Used off
/// the main actor by the board codec.
struct PropertyCodec: Sendable {
    let key: PropertyKey
    let version: Int
    let migrations: [PropertyMigration]
    let defaultValue: (any AddedValue)?
    /// The value's type, as its property's name for messages.
    let typeName: String
    let decode: @Sendable (any Decoder) throws -> any AddedValue
    let decodeData: @Sendable (Data) throws -> any AddedValue
    let schema: @Sendable (inout SchemaDefinitions) -> JSONObject
    /// Its value is an optional, or holds optionals, which a schema can't say.
    let holdsOptionals: Bool

    init<P: ShapeProperty>(_: P.Type) {
        key = P.key
        version = P.version
        migrations = P.migrations
        defaultValue = P.defaultValue.map(Boxed.init)
        typeName = "\(P.self)"
        // Through a single-value container, so the decoder's settings apply (a date as a board writes one).
        decode = { Boxed(value: try $0.singleValueContainer().decode(P.Value.self)) }
        decodeData = { Boxed(value: try BoardCodec.makeDecoder().decode(P.Value.self, from: $0)) }
        let keywords = P.keywords.json
        schema = { P.Value.schema(in: &$0).merging(keywords) { _, keyword in keyword } }
        holdsOptionals = P.Value.self is any OptionalValue.Type || Canvas.holdsOptionals(P.Value.self)
    }
}

/// Which kinds opt into which added properties, worked out when the registry is built. Each kind's
/// are in plugin order, since the contributions are.
struct PropertyTable {
    let codecs: [PropertyKey: PropertyCodec]
    let owners: [PropertyKey: PluginID]
    /// Each kind's opted-in properties, in plugin order.
    let byKind: [ShapeKind: [PropertyKey]]

    static let empty = PropertyTable(codecs: [:], owners: [:], byKind: [:])

    @MainActor
    init(declarations: [RawContribution], optIns: [RawContribution], definitions: [ShapeKind: any ShapeDefinition],
         kinds: [ShapeKind]) throws(RegistryError) {
        var codecs: [PropertyKey: PropertyCodec] = [:], owners: [PropertyKey: PluginID] = [:]
        for c in declarations {
            let codec = (c.value as! PropertyDeclaration).codec
            codecs[codec.key] = codec
            owners[codec.key] = c.pluginID
        }
        var byKind: [ShapeKind: [PropertyKey]] = [:], by: [OptInKey: PluginID] = [:]
        for c in optIns {
            let optIn = c.value as! PropertyOptIn
            guard codecs[optIn.key] != nil else {
                throw .invalid(point: c.pointName, reason: "\(c.pluginID) opts \(c.target == .any ? "every kind" : "\(c.target)") into property \(optIn.key), which no installed plugin declares")
            }
            let targets: [ShapeKind] = switch c.target {
            case .kind(let kind): [kind]
            case .any: kinds.filter { kind in definitions[kind].map { optIn.appliesTo?($0) ?? true } ?? false }
            }
            for kind in targets {
                let claim = OptInKey(target: .kind(kind), key: optIn.key)
                if let first = by[claim] {
                    guard first != c.pluginID else {
                        throw .invalid(point: c.pointName, reason: "\(first) opts \(kind) into property \(optIn.key) twice")
                    }
                    throw .conflict(point: c.pointName, key: "\(claim)", plugins: [first, c.pluginID])
                }
                by[claim] = c.pluginID
                if let own = definitions[kind]?.ownPropertyNames, own.contains(optIn.key.rawValue) {
                    throw .invalid(point: c.pointName, reason: "\(kind) has a property of its own named \(optIn.key), so it can't opt into the one \(owners[optIn.key]!) declares; hand the member over to it (PropsMigration.handOver), or rename one")
                }
                byKind[kind, default: []].append(optIn.key)
            }
        }
        self.codecs = codecs
        self.owners = owners
        self.byKind = byKind
    }

    private init(codecs: [PropertyKey: PropertyCodec], owners: [PropertyKey: PluginID], byKind: [ShapeKind: [PropertyKey]]) {
        self.codecs = codecs
        self.owners = owners
        self.byKind = byKind
    }

    /// `record` as its kind has it: a value for each opted-in property with a default that it has
    /// none of (and isn't kept aside), and no typed value for a property its kind doesn't opt into.
    func normalized(_ record: AnyShapeRecord) -> AnyShapeRecord {
        guard !record.isOpaque else {
            // Nothing can be set on a shape kept aside: it's saved as it was.
            guard !record.added.keys.isEmpty else { return record }
            var record = record
            for key in record.added.keys { record.added[key] = nil }
            return record
        }
        let keys = byKind[record.kind] ?? []
        guard !keys.isEmpty || !record.added.isEmpty else { return record }
        var record = record
        for key in record.added.keys where !keys.contains(key) { record.added[key] = nil }
        for key in keys where record.added[key] == nil && record.added.kept[key] == nil {
            record.added[key] = codecs[key]?.defaultValue
        }
        return record
    }
}
