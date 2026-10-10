import Canvas

// The schema the check reads: a type's composed schema rewritten, on a copy, so that the validator says
// what the plan means. Pure, nonisolated, and made once where a schema is compiled or served. Five
// rewrites (T1 to T5; T2b with T2): an unreadable pattern is not a wrong value, a value no field names
// is never wrong, `dependentSchemas` is enforced, an `if` on fields asks only once they have values,
// and "at least one of" names every field it would take.

public enum FieldSchemas {
    /// `schema` with the five rewrites applied at every place that holds a schema. The input is not
    /// changed, and a schema none of them touch comes back equal.
    public static func checkable(_ schema: JSONValue) -> JSONValue {
        walk(schema, depth: 0)
    }

    private static func walk(_ value: JSONValue, depth: Int) -> JSONValue {
        guard case .object(var node) = value, depth < JSONReader.maxDepth else { return value }
        // The children first: what the rewrites add holds schemas already walked, and is not walked again.
        for key in SchemaPositions.named + SchemaPositions.definitions {
            if case .object(let named)? = node[key] { node[key] = .object(named.mapValues { walk($0, depth: depth + 1) }) }
        }
        for key in SchemaPositions.single {
            if let sub = node[key], sub.objectValue != nil { node[key] = walk(sub, depth: depth + 1) }
        }
        for key in SchemaPositions.lists {
            if case .array(let list)? = node[key] { node[key] = .array(list.map { walk($0, depth: depth + 1) }) }
        }
        var added: [JSONValue] = []
        unreadablePatterns(&node)
        unnamedValues(&node)
        dependentSchemas(&node, into: &added)
        conditions(&node, into: &added)
        for key in ["anyOf", "oneOf"] { atLeastOne(key, &node, into: &added) }
        if !added.isEmpty { node["allOf"] = .array((node["allOf"]?.arrayValue ?? []) + added) }
        return .object(node)
    }

    // MARK: T1

    /// A pattern ICU cannot read would be reported as a wrong value; it is the type's fault, not the
    /// note's, so the pattern goes.
    private static func unreadablePatterns(_ node: inout JSONObject) {
        if case .string(let pattern)? = node["pattern"], SchemaValidator.regex(for: pattern) == nil { node["pattern"] = nil }
        if case .object(let entries)? = node["patternProperties"] {
            let readable = entries.filter { SchemaValidator.regex(for: $0.key) != nil }
            node["patternProperties"] = readable.isEmpty ? nil : .object(readable)
        }
    }

    // MARK: T2

    /// A value no field names is never wrong: what a group says of members it does not name (their
    /// names, their number at most, their form) would be broken by one no field holds. `minProperties`
    /// stays, since an unnamed member can only help meet it. A pairs field has no `properties`, so these
    /// are its rules and stay; only `additionalProperties: false` goes from anywhere (T2b).
    private static func unnamedValues(_ node: inout JSONObject) {
        if case .object(let properties)? = node["properties"], !properties.isEmpty {
            for key in ["additionalProperties", "propertyNames", "patternProperties", "unevaluatedProperties", "maxProperties"] { node[key] = nil }
        }
        if node["additionalProperties"] == .bool(false) { node["additionalProperties"] = nil }
    }

    // MARK: T3

    /// The core ignores `dependentSchemas`; here it is an `if` the validator does enforce.
    private static func dependentSchemas(_ node: inout JSONObject, into added: inout [JSONValue]) {
        guard case .object(let dependent)? = node["dependentSchemas"] else { return }
        node["dependentSchemas"] = nil
        for (name, schema) in dependent.sorted(by: { $0.key < $1.key }) {
            added.append(.object(["if": .object(["required": .array([.string(name)])]), "then": schema]))
        }
    }

    // MARK: T4

    /// An `if` that tests fields asks for its `then` or `else` only once the fields it tests have values
    /// (an empty Order is not asked for a gift note, nor is its `else` applied): the node loses
    /// `if/then/else` and its `allOf` gains `{if: presence(X), then: {if: X, then: T, else: E}}`. An `if`
    /// with no `properties` is the author's.
    private static func conditions(_ node: inout JSONObject, into added: inout [JSONValue]) {
        guard case .object(let test)? = node["if"], case .object(let tested)? = test["properties"], !tested.isEmpty,
              node["then"] != nil || node["else"] != nil else { return }
        var inner: JSONObject = ["if": .object(test)]
        inner["then"] = node["then"]
        inner["else"] = node["else"]
        for key in ["if", "then", "else"] { node[key] = nil }
        added.append(.object(["if": presence(of: test), "then": .object(inner)]))
    }

    /// What it takes for the fields `test` speaks of to have values, and so on one level down, for a
    /// field whose own test has `properties`.
    private static func presence(of test: JSONObject) -> JSONValue {
        guard case .object(let tested)? = test["properties"] else { return .object([:]) }
        var asked: JSONObject = ["required": .array(tested.keys.sorted().map(JSONValue.string))]
        var inner: JSONObject = [:]
        for (name, schema) in tested {
            if case .object(let member) = schema, case .object(let nested)? = member["properties"], !nested.isEmpty { inner[name] = presence(of: member) }
        }
        if !inner.isEmpty { asked["properties"] = .object(inner) }
        return .object(asked)
    }

    // MARK: T5

    /// "At least one of": an `anyOf` or `oneOf` whose branches only ask for fields. Left as it is, the
    /// validator's one violation hides the branches; here, with none satisfied, every field of the
    /// branches is asked for. A `oneOf` that two branches satisfy is still the validator's `oneOf`.
    private static func atLeastOne(_ key: String, _ node: inout JSONObject, into added: inout [JSONValue]) {
        guard case .array(let branches)? = node[key], !branches.isEmpty else { return }
        var asked: [String] = []
        for branch in branches {
            guard let names = requiredOnly(branch) else { return }
            for name in names where !asked.contains(name) { asked.append(name) }
        }
        node[key] = nil
        added.append(.object(["if": .object(["not": .object(["anyOf": .array(branches)])]),
                              "then": .object(["required": .array(asked.map(JSONValue.string))])]))
        if key == "oneOf", branches.count >= 2 {
            added.append(.object(["if": .object(["anyOf": .array(branches)]), "then": .object(["oneOf": .array(branches)])]))
        }
    }

    /// The names a branch asks for when it asks for nothing else (a `title`, `description` or `$comment`
    /// beside is fine); nil for any other branch.
    private static func requiredOnly(_ branch: JSONValue) -> [String]? {
        guard case .object(let members) = branch, case .array(let required)? = members["required"], !required.isEmpty else { return nil }
        guard members.keys.allSatisfy({ ["required", "title", "description", "$comment"].contains($0) }) else { return nil }
        let names = required.compactMap(\.stringValue)
        return names.count == required.count ? names : nil
    }
}
