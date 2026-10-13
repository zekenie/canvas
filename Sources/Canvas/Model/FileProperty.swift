import Foundation

/// A value a plugin keeps on the file as a whole: what belongs to no shape and no board of it (the
/// colors a file names). It is to the file what an added property (`ShapeProperty`) is to a shape.
/// The type is the key, and says everything about the value once:
///
///     public enum Letterhead {}
///     extension Letterhead: FileProperty {
///         public static let key: PropertyKey = "letterhead"
///         public static var defaultValue: String { "" }
///     }
///
/// The plugin that owns it declares it (`registrar.declare(file: Letterhead.self)`). It's read from
/// the file (`editor.file[Letterhead.self]`, `transaction.fileValue(_:)`, and `fileValue(_:)` on a
/// render's and a layout's context), changed in a transaction
/// (`transaction.setFileValue(Letterhead.self, to: "Acme")`), so it's undone and redone with the
/// rest of its step, heard by services (`ChangeSet.fileValues`), and saved with the file, with its
/// version. Its history (`migrations`) is its own.
///
/// A file holds a value only while it differs from the default: every file reads the default until
/// it's set, setting the default takes the value off the file, and a file with none is written as
/// one always was. The core knows nothing of what a value means.
public protocol FileProperty {
    associatedtype Value: Codable & Equatable & Sendable
    /// Where a file keeps it. Unique among file properties (an added property may share it: a
    /// shape's values and the file's are kept apart), and never changed once shipped.
    static var key: PropertyKey { get }
    /// What every file reads until it's set, and what no file holds.
    static var defaultValue: Value { get }
    /// Append only; the count is the version a file records. See `PropertyMigration`.
    static var migrations: [PropertyMigration] { get }
}

extension FileProperty {
    public static var migrations: [PropertyMigration] { [] }
    /// How many steps the value has been through: what a file records for this property.
    public static var version: Int { migrations.count }
}

/// A file's values (`FileProperty`): typed (never JSON in memory), only those that differ from
/// their defaults, and the entries of a board file's `values` this app can't use, kept as the JSON
/// they were, whole, to be written back.
struct FileValues: Equatable, Sendable {
    private(set) var values: [PropertyKey: any AddedValue] = [:]
    /// What the app can't use (no installed plugin declares the key, a newer version, unreadable), by
    /// key: the whole entry, as read. A key kept aside reads as its default, and can't be set.
    var kept: [PropertyKey: JSONValue] = [:]

    var isEmpty: Bool { values.isEmpty && kept.isEmpty }
    var keys: some Collection<PropertyKey> { values.keys }

    subscript<P: FileProperty>(_: P.Type) -> P.Value {
        get { (values[P.key] as? Boxed<P.Value>)?.value ?? P.defaultValue }
        set {
            // A kept value stays as it was.
            guard kept[P.key] == nil else { return }
            values[P.key] = newValue == P.defaultValue ? nil : Boxed(value: newValue)
        }
    }

    /// The value held under a key, whatever its type; nil for none (the file reads the default).
    subscript(key: PropertyKey) -> (any AddedValue)? {
        get { values[key] }
        set { values[key] = newValue }
    }

    /// The keys whose values differ between the two, as they read: held by one and not the other
    /// (kept aside counts as not held), or held by both and unequal.
    func keysDiffering(from other: FileValues) -> Set<PropertyKey> {
        var keys: Set<PropertyKey> = []
        for (key, value) in values where !Self.same(value, other.values[key]) { keys.insert(key) }
        for key in other.values.keys where values[key] == nil { keys.insert(key) }
        return keys
    }

    static func same(_ a: (any AddedValue)?, _ b: (any AddedValue)?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case (let a?, let b?): a.isEqual(to: b)
        default: false
        }
    }

    static func == (a: Self, b: Self) -> Bool {
        a.kept == b.kept && a.values.count == b.values.count && a.values.allSatisfy { key, value in same(value, b.values[key]) }
    }
}
