import CanvasRPC
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
/// A board keeps a shape's metadata beside its props, each member under its owner's id, then its
/// name (`"meta" : { "clipboard" : { "copiedFrom" : … } }`), so neither may change once shipped,
/// and two plugins' members never share a place. Unlike props, a member isn't versioned: keep old
/// boards' values readable (add optional members only), since one that no longer decodes reads as
/// nil.
public protocol ShapeMetaKey {
    associatedtype Value: Codable, Equatable, Sendable
    /// The plugin that declares it: where boards keep it.
    static var owner: PluginID { get }
    /// Unique among its owner's keys.
    static var name: String { get }
}

/// A shape's metadata: each plugin's members, typed by their keys (`meta[CopiedFrom.self]`), kept
/// as the JSON a board writes. Members no installed plugin knows are kept, and saved back as they
/// were. Setting a member to nil removes it.
public struct ShapeMeta: Equatable, Sendable {
    /// Every member, by its owner's id, then its name.
    public private(set) var json: JSONObject

    public init(json: JSONObject = [:]) { self.json = json }

    public var isEmpty: Bool { json.isEmpty }

    /// Nil when there's no such member, or it doesn't decode as `Key.Value`.
    public subscript<Key: ShapeMetaKey>(key: Key.Type) -> Key.Value? {
        get {
            guard let value = json[Key.owner.rawValue]?[Key.name], let data = try? Self.encoder.encode(value) else { return nil }
            return try? Self.decoder.decode(Key.Value.self, from: data)
        }
        set {
            var members = json[Key.owner.rawValue]?.objectValue ?? [:]
            if let newValue {
                do {
                    members[Key.name] = try Self.decoder.decode(JSONValue.self, from: Self.encoder.encode(newValue))
                } catch {
                    preconditionFailure("\(Key.owner)'s \(Key.name) doesn't encode as JSON: \(error)")
                }
            } else {
                members[Key.name] = nil
            }
            json[Key.owner.rawValue] = members.isEmpty ? nil : .object(members)
        }
    }

    // A board's settings (dates, floats that aren't finite), without its pretty-printing: made once,
    // since every read and write goes through them.
    private static let encoder: JSONEncoder = {
        let encoder = BoardCodec.makeEncoder()
        encoder.outputFormatting = []
        return encoder
    }()
    private static let decoder = BoardCodec.makeDecoder()
}
