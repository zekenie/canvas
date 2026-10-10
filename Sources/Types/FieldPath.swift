import Canvas
import Foundation

/// Where a value is in a shape's `fieldValues`: members by the field's key (`ChainField.name`, never
/// its title), elements by their index in the stored list, which is dense (empties are pruned: a blank
/// or half-typed line lives in its editor, and a card maps its display line to the stored index by
/// counting the non-blank lines before it).
public struct FieldPath: Hashable, Sendable {
    public enum Step: Hashable, Sendable {
        case key(String), index(Int)
    }

    public var steps: [Step]

    public init(_ steps: [Step] = []) {
        self.steps = steps
    }

    /// The row on the note: a path of one key.
    public init(field key: String) {
        steps = [.key(key)]
    }

    /// A `SchemaViolation`'s path.
    public init(_ components: [JSONPathComponent]) {
        steps = components.map { component in
            switch component {
            case .member(let name): .key(name)
            case .element(let index): .index(index)
            }
        }
    }

    /// The first key: the row on the note. Nil for the root, and for a path that starts with an index.
    public var field: String? {
        if case .key(let key)? = steps.first { key } else { nil }
    }

    /// The path one step up: the root for a path of one step, nil for the root.
    public var parent: FieldPath? {
        steps.isEmpty ? nil : FieldPath(Array(steps.dropLast()))
    }

    public func key(_ k: String) -> FieldPath { FieldPath(steps + [.key(k)]) }
    public func index(_ i: Int) -> FieldPath { FieldPath(steps + [.index(i)]) }

    /// Whether `other` is this path or under it.
    public func isPrefix(of other: FieldPath) -> Bool {
        steps.count <= other.steps.count && zip(steps, other.steps).allSatisfy { $0 == $1 }
    }

    /// No steps: a problem there is across fields, the note's own.
    public var isRoot: Bool { steps.isEmpty }

    /// As a JSON Pointer writes it, `~` and `/` escaped: `/lineItems/1/quantity`. Empty for the root.
    public var pointer: String {
        steps.map { step in
            switch step {
            case .key(let key): "/" + key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
            case .index(let index): "/\(index)"
            }
        }.joined()
    }
}
