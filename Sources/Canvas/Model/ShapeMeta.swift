import Foundation

/// A member of a shape's metadata (`AnyShapeRecord.meta`): something a plugin keeps about a shape
/// that isn't the kind's own data, such as the shape it was copied from. The type is the key,
/// declared by the plugin that owns it, as an extension point is:
///
///     public enum CopiedFrom {}
///     extension CopiedFrom: ShapeMetaKey {
///         public typealias Value = CopySource
///         public static var owner: PluginID { .clipboard }
///         public static var name: String { "copiedFrom" }
///     }
///
/// and read and written through the record, in a transaction: `record.meta[CopiedFrom.self]`.
/// A board keeps a shape's metadata beside its props, by `owner.name` (`"clipboard.copiedFrom"`), so
/// neither ever changes once shipped. Unlike props, a member isn't versioned: keep old boards'
/// values readable (add optional members only), since one that no longer decodes reads as nil.
public protocol ShapeMetaKey {
    associatedtype Value: Codable, Equatable, Sendable
    /// The plugin that declares it. With `name`, where boards keep it.
    static var owner: PluginID { get }
    /// Unique among its owner's keys.
    static var name: String { get }
}

extension ShapeMetaKey {
    /// Where a board keeps it: `owner.name`.
    static var storageKey: String { "\(owner).\(name)" }
}

/// A shape's metadata: each plugin's members, typed by their keys (`meta[CopiedFrom.self]`), kept
/// as the JSON a board writes. Members no installed plugin knows are kept, and saved back as they
/// were. Setting a member to nil removes it.
public struct ShapeMeta: Equatable, Sendable {
    /// Every member, by `owner.name`.
    public private(set) var json: JSONObject

    public init(json: JSONObject = [:]) { self.json = json }

    public var isEmpty: Bool { json.isEmpty }

    /// Nil when there's no such member, or it doesn't decode as `Key.Value`.
    public subscript<Key: ShapeMetaKey>(key: Key.Type) -> Key.Value? {
        get {
            guard let value = json[Key.storageKey], let data = try? BoardCodec.makeEncoder().encode(value) else { return nil }
            return try? BoardCodec.makeDecoder().decode(Key.Value.self, from: data)
        }
        set {
            guard let newValue else {
                json[Key.storageKey] = nil
                return
            }
            do {
                json[Key.storageKey] = try BoardCodec.makeDecoder().decode(JSONValue.self, from: BoardCodec.makeEncoder().encode(newValue))
            } catch {
                preconditionFailure("\(Key.storageKey) doesn't encode as JSON: \(error)")
            }
        }
    }
}
