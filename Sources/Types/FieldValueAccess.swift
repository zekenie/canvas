import Canvas

// Reading and setting one value inside a shape's `fieldValues`, at any depth: pure, so the writer, the
// rows, the card and the panel all change a value the same way.

extension FieldValues {
    /// The value at `path`: members by key, elements by index. Nil when nothing is there, or a step meets
    /// a value of the other shape (a key into a list). The root is the whole object.
    public func value(at path: FieldPath) -> JSONValue? {
        var current = JSONValue.object(values)
        for step in path.steps {
            switch (step, current) {
            case (.key(let key), .object(let members)):
                guard let next = members[key] else { return nil }
                current = next
            case (.index(let index), .array(let elements)):
                guard elements.indices.contains(index) else { return nil }
                current = elements[index]
            default:
                return nil
            }
        }
        return current
    }

    /// A copy with `value` at `path`. Nil or an empty value removes it, and every parent left empty goes
    /// too (the pruning rule). Missing parents are made: a key makes an object, an index an array. An
    /// index equal to the count appends, and so does one past it (no holes). Setting empty at an index
    /// takes the element out and the rest shift up. A parent that holds a value of the other shape (a
    /// string where a group should be) is replaced: nothing is refused. At the root, an object is the new
    /// whole and nil clears it; anything else changes nothing. A path that starts with an index has no
    /// row to be in: it changes nothing. Removing from under a parent of the other shape changes nothing
    /// (there was nothing there).
    public func setting(_ value: JSONValue?, at path: FieldPath) -> FieldValues {
        let value = value.flatMap(Self.pruned)
        if path.isRoot {
            guard let value else { return FieldValues() }
            return value.objectValue.map { FieldValues($0) } ?? self
        }
        guard path.field != nil else { return self }
        return FieldValues(Self.set(.object(values), steps: path.steps[...], to: value)?.objectValue ?? [:])
    }

    /// The members of the root no field of `resolved` names, in key order: what the panel dims.
    public func keys(unnamedBy resolved: Resolved) -> [String] {
        let named = Set(resolved.fields.map(\.field.name))
        return values.keys.filter { !named.contains($0) }.sorted()
    }

    private static func set(_ current: JSONValue?, steps: ArraySlice<FieldPath.Step>, to value: JSONValue?) -> JSONValue? {
        guard let step = steps.first else { return value }
        let rest = steps.dropFirst()
        switch step {
        case .key(let key):
            if value == nil, let current, current.objectValue == nil { return current }
            var members = current?.objectValue ?? [:]
            members[key] = set(members[key], steps: rest, to: value).flatMap(pruned)
            return members.isEmpty ? Optional.none : .object(members)
        case .index(let index):
            if value == nil, let current, current.arrayValue == nil { return current }
            var elements = current?.arrayValue ?? []
            if elements.indices.contains(index) {
                if let child = set(elements[index], steps: rest, to: value).flatMap(pruned) {
                    elements[index] = child
                } else {
                    elements.remove(at: index)
                }
            } else if let child = set(nil, steps: rest, to: value).flatMap(pruned) {
                elements.append(child)
            }
            return elements.isEmpty ? Optional.none : .array(elements)
        }
    }
}
