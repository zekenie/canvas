/// What each shape names, kept with the other way round, what names each shape: the shapes a shape's rules
/// looked up and those whose rules looked a shape up, a type's references and the types that refer to it, the
/// shapes a reference's row read its path from. Setting what a shape names replaces what it named, and the other
/// side follows; a shape that names nothing and a shape nothing names are dropped. Of shapes alone, not generic:
/// another module calls it, and a generic one's code there runs unspecialized (nothing is `@inlinable`).
public struct ReverseIndex: Sendable {
    /// What each shape names.
    public private(set) var of: [ShapeID: Set<ShapeID>] = [:]
    /// The shapes that name each one.
    public private(set) var by: [ShapeID: Set<ShapeID>] = [:]

    public init() {}

    /// Makes `values` what `key` names (none takes it out): O(what it named and names), and the other
    /// side touched only where they differ. Nothing is made or hashed for the difference when either side
    /// is empty: a validation's first read sets what every shape's rules looked up, each named by nothing yet.
    public mutating func set(_ values: Set<ShapeID>, for key: ShapeID) {
        let before = of[key] ?? []
        guard before != values else { return }
        for gone in before where values.isEmpty || !values.contains(gone) {
            by[gone]?.remove(key)
            if by[gone]?.isEmpty == true { by[gone] = nil }
        }
        for added in values where before.isEmpty || !before.contains(added) { by[added, default: []].insert(key) }
        of[key] = values.isEmpty ? nil : values
    }

    /// Takes `key` out: it names nothing.
    public mutating func forget(_ key: ShapeID) { set([], for: key) }
}
