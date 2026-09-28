import Foundation

/// A value that names shapes loosely, wherever a shape keeps it: a kind's own property, a struct in
/// one, a collection, an added property's value (a mention in text). Unlike a binding
/// (`ShapeReferencing`, a kind's: an arrow's end must be on its board), a name may outlive its
/// shape: a copy names the copies of the shapes copied with it and goes on naming the rest, and
/// deleting a shape never looks for names, so a name of a shape that's gone stays as it was.
///
/// The core finds these values through property lists: a kind's props by their list, and a struct
/// in them (or in an added value) that holds one adopts this too, in an extension, with nothing to
/// write (`extension ChecklistItem: ShapeNaming {}`: its listed members that name shapes). The
/// registry refuses a struct that holds names without adopting it, since its names would be copied
/// unrenamed. Optionals, arrays, sets and dictionaries of names are names. A leaf, a type coded by
/// hand that holds the ids itself, implements both requirements, and the registry can't look
/// inside it, as it can't check its list.
public protocol ShapeNaming: Sendable {
    /// Calls `body` with each shape it names, repeats included: in order, but for a set's or a
    /// dictionary's.
    func forEachNamedShape(_ body: (ShapeID) -> Void)
    /// Itself with each name that `rename` gives an id for renamed to that id; nil keeps the name
    /// as it is. Pure: it reads nothing else, so it runs anywhere.
    func renamingShapes(_ rename: (ShapeID) -> ShapeID?) -> Self
}

extension Optional: ShapeNaming where Wrapped: ShapeNaming {
    public func forEachNamedShape(_ body: (ShapeID) -> Void) { self?.forEachNamedShape(body) }
    public func renamingShapes(_ rename: (ShapeID) -> ShapeID?) -> Self { self.map { $0.renamingShapes(rename) } }
}

extension Array: ShapeNaming where Element: ShapeNaming {
    public func forEachNamedShape(_ body: (ShapeID) -> Void) {
        for element in self { element.forEachNamedShape(body) }
    }
    public func renamingShapes(_ rename: (ShapeID) -> ShapeID?) -> Self { map { $0.renamingShapes(rename) } }
}

/// Renaming rebuilds the set: two elements renamed alike are one.
extension Set: ShapeNaming where Element: ShapeNaming {
    public func forEachNamedShape(_ body: (ShapeID) -> Void) {
        for element in self { element.forEachNamedShape(body) }
    }
    public func renamingShapes(_ rename: (ShapeID) -> ShapeID?) -> Self { Set(map { $0.renamingShapes(rename) }) }
}

/// Keyed by strings, as a schema can describe it: its values name shapes, its keys don't.
extension Dictionary: ShapeNaming where Key == String, Value: ShapeNaming {
    public func forEachNamedShape(_ body: (ShapeID) -> Void) {
        for value in values { value.forEachNamedShape(body) }
    }
    public func renamingShapes(_ rename: (ShapeID) -> ShapeID?) -> Self { mapValues { $0.renamingShapes(rename) } }
}

/// A struct's names are those of its listed members that name shapes, in list order.
extension ShapeNaming where Self: SchemaDefined {
    public func forEachNamedShape(_ body: (ShapeID) -> Void) {
        forEachListedNamingValue { _, value in value.forEachNamedShape(body) }
    }
    public func renamingShapes(_ rename: (ShapeID) -> ShapeID?) -> Self { renamingListedNames(rename) }
}

extension SchemaDefined {
    /// Each listed member that names shapes, with its property's name, in list order.
    func forEachListedNamingValue(_ body: (_ property: String, _ value: any ShapeNaming) -> Void) {
        for property in Self.properties.namingProperties {
            if let naming = property.naming { body(property.name, naming.value(self)) }
        }
    }

    /// Itself with the names in its listed members renamed.
    func renamingListedNames(_ rename: (ShapeID) -> ShapeID?) -> Self {
        var renamed = self
        for property in Self.properties.namingProperties { property.naming?.rename(&renamed, rename) }
        return renamed
    }
}

extension AnyShapeRecord {
    /// Each value in its props and added values that names shapes (`ShapeNaming`), with the
    /// property it's in: its own properties in list order, then its added ones in its kind's
    /// order. None for a kind outside `registry.namingKinds`, or a shape kept aside, and none from
    /// an added value kept aside (`keptProperties`), which the app can't read.
    @MainActor
    public func forEachNamingValue(in registry: Registry, _ body: (_ property: String, _ value: any ShapeNaming) -> Void) {
        guard registry.namingKinds.contains(kind), !isOpaque else { return }
        props.forEachListedNamingValue(body)
        for key in registry.properties(for: kind) {
            guard let naming = registry.propertyTable.codecs[key]?.naming, let value = added[key],
                  let names = naming.value(value) else { continue }
            body(key.rawValue, names)
        }
    }

    /// Renames the names in its props and added values, as `remappingReferences` does after its
    /// kind's bindings, for a kind in `registry.namingKinds` that isn't kept aside. An added value
    /// kept aside keeps naming what it named.
    @MainActor
    mutating func renameNamedShapes(_ rename: (ShapeID) -> ShapeID?, in registry: Registry) {
        props = props.renamingListedNames(rename)
        for key in registry.properties(for: kind) {
            guard let naming = registry.propertyTable.codecs[key]?.naming, let value = added[key] else { continue }
            added[key] = naming.rename(value, rename)
        }
    }
}
