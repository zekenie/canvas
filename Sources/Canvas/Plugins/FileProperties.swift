import Foundation

// File properties (`FileProperty`): the plugin that owns one declares it, and the file holds its value.

extension PluginRegistrar {
    /// Declares a file property this plugin owns: a value it keeps on the file as a whole
    /// (`FileProperty`), which a transaction then sets (`setFileValue`) and a board file saves. At
    /// most one plugin declares each key.
    public mutating func declare<P: FileProperty>(file _: P.Type) {
        contribute(FilePropertyDeclaration(P.self), to: CorePoints.FilePropertyDeclarations.self)
    }
}

extension CorePoints {
    enum FilePropertyDeclarations: KeyedExtensionPoint {
        typealias Contribution = FilePropertyDeclaration
        static var owner: PluginID { .core }
        static func uniqueKeys(of c: FilePropertyDeclaration, for _: ShapeTarget) -> [AnyHashable] { [c.codec.key] }
    }
}

struct FilePropertyDeclaration {
    let codec: FilePropertyCodec
    init<P: FileProperty>(_: P.Type) { codec = FilePropertyCodec(P.self) }
}

/// A file property, erased: how its value is read, written and migrated. Used off the main actor
/// by the board codec.
struct FilePropertyCodec: Sendable {
    let key: PropertyKey
    let version: Int
    let migrations: [PropertyMigration]
    /// The property's type: a write names its property by type, and only the declared one is taken.
    let property: ObjectIdentifier
    let decode: @Sendable (any Decoder) throws -> any AddedValue
    let decodeData: @Sendable (Data) throws -> any AddedValue
    /// Whether a value is the property's default, which no file holds: one read from a board isn't kept.
    let isDefault: @Sendable (any AddedValue) -> Bool

    init<P: FileProperty>(_: P.Type) {
        key = P.key
        version = P.version
        migrations = P.migrations
        property = ObjectIdentifier(P.self)
        // Through a single-value container, so the decoder's settings apply (a date as a board writes one).
        decode = { Boxed(value: try $0.singleValueContainer().decode(P.Value.self)) }
        decodeData = { Boxed(value: try BoardCodec.makeDecoder().decode(P.Value.self, from: $0)) }
        let defaultValue = P.defaultValue
        isDefault = { ($0 as? Boxed<P.Value>)?.value == defaultValue }
    }
}

extension Registry {
    /// The file properties installed plugins declare (`registrar.declare(file:)`), in plugin order.
    public var declaredFileProperties: [PropertyKey] {
        contributions(to: CorePoints.FilePropertyDeclarations.self).map(\.value.codec.key)
    }

    /// The plugin that declares a file property.
    public func owner(ofFileProperty key: PropertyKey) -> PluginID? {
        contributions(to: CorePoints.FilePropertyDeclarations.self).first { $0.value.codec.key == key }?.pluginID
    }

    /// Whether an installed plugin declares this file property, by its type.
    func declares<P: FileProperty>(file _: P.Type) -> Bool {
        fileProperties[P.key]?.property == ObjectIdentifier(P.self)
    }
}
