import Foundation

/// Where a JSON value breaks a schema: one keyword, at one place in the value.
public struct SchemaViolation: Hashable, Sendable, CustomStringConvertible {
    /// Where it is, from the value's root: the members and elements on the way. For a member that's
    /// missing (`required`) or not allowed (`additionalProperties`), that member.
    public let path: [JSONPathComponent]
    /// The keyword it breaks: `maxLength`, `type`, `required`; `false` for a schema that allows
    /// nothing.
    public let keyword: String
    /// What's wrong, for people. It names the place by its schema's `title`, else by its path:
    /// "Title is 95 characters long, and should be at most 80."
    public let message: String

    public init(path: [JSONPathComponent], keyword: String, message: String) {
        self.path = path
        self.keyword = keyword
        self.message = message
    }

    /// The root's member it's in (`title`, `checklist`); nil for the root itself.
    public var property: String? {
        guard case .member(let name)? = path.first else { return nil }
        return name
    }

    /// The path as a JSON Pointer (RFC 6901): "/checklist/2/text"; empty for the root.
    public var pointer: String { path.map { "/\($0.pointerToken)" }.joined() }

    public var description: String { "\(pointer.isEmpty ? "/" : pointer) \(keyword): \(message)" }
}

/// One step into a JSON value: a member of an object, or an element of an array (from 0).
public enum JSONPathComponent: Hashable, Sendable {
    case member(String)
    case element(Int)

    /// As a JSON Pointer writes it: `~` and `/` escaped.
    var pointerToken: String {
        switch self {
        case .member(let name): name.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
        case .element(let index): "\(index)"
        }
    }
}

extension JSONSchema {
    /// Where `value` breaks this schema, in the order the schema lists what it checks; empty when it
    /// holds up. To check many values, compile the schema once (`SchemaValidator`).
    public func violations(of value: JSONValue) -> [SchemaViolation] { SchemaValidator(self).violations(of: value) }
}

/// A JSON Schema (draft 2020-12), compiled to check values against: make one per schema, and keep
/// it. It asserts `type`, `enum`, `const`, the bounds on numbers (`minimum`, `maximum`, their
/// exclusive forms, `multipleOf`), strings (`minLength`, `maxLength`, counted in code points, and
/// `pattern`), arrays (`minItems`, `maxItems`, `uniqueItems`, `minContains`, `maxContains`) and
/// objects (`required`, `minProperties`, `maxProperties`, `dependentRequired`), and applies
/// `properties`, `patternProperties`, `additionalProperties`, `propertyNames`, `prefixItems`,
/// `items`, `contains`, `allOf`, `anyOf`, `oneOf`, `not`, `if`/`then`/`else` and `$ref`, to any
/// place in the same schema (`#/$defs/core.rect`, `#`). `format` is an annotation, as 2020-12 has
/// it, and so is any keyword it doesn't know (`x-canvas-owner`, `default`): neither is checked.
public struct SchemaValidator: Sendable {
    private let nodes: [Node]

    public init(_ schema: JSONSchema) {
        var compiler = Compiler(root: .object(schema.json))
        _ = compiler.node(for: .object(schema.json), at: "#")
        nodes = compiler.nodes
    }

    /// Where `value` breaks the schema, in the order the schema lists what it checks; empty when it
    /// holds up.
    public func violations(of value: JSONValue) -> [SchemaViolation] {
        var path: [JSONPathComponent] = []
        var found: [SchemaViolation] = []
        check(value, against: 0, at: &path, into: &found)
        return found
    }

    /// Whether `value` holds up against node `index`: for the applicators that only ask (`anyOf`,
    /// `not`), whose own violations aren't reported.
    private func holds(_ value: JSONValue, against index: Int, at path: inout [JSONPathComponent]) -> Bool {
        var found: [SchemaViolation] = []
        check(value, against: index, at: &path, into: &found)
        return found.isEmpty
    }

    private func check(_ value: JSONValue, against index: Int, at path: inout [JSONPathComponent], into found: inout [SchemaViolation]) {
        let node = nodes[index]
        // What the place is called, worked out only when there's something to say about it.
        func name() -> Naming { Naming(path: path, title: title(of: node)) }
        func report(_ keyword: String, _ message: String) {
            found.append(SchemaViolation(path: path, keyword: keyword, message: message))
        }
        if node.allowsNothing { return report("false", "\(name()) isn't allowed here.") }
        if let unresolved = node.unresolvedRef {
            return report("$ref", "\(name()) can't be checked: its schema refers to \(unresolved), which isn't in it.")
        }
        if let ref = node.ref { check(value, against: ref, at: &path, into: &found) }
        // A value of the wrong type isn't what the rest describes: that's all there is to say.
        if let types = node.types, types.isDisjoint(with: JSONTypes(of: value)) {
            return report("type", "\(name()) should be \(Self.list(node.typeNames.map(Self.typeName), or: true)), not \(Self.describe(value)).")
        }
        if let values = node.enumValues, !values.contains(value) {
            report("enum", "\(name()) should be \(Self.list(values.map(Self.literal), or: true)).")
        }
        if let constant = node.constValue, value != constant {
            report("const", "\(name()) should be \(Self.literal(constant)).")
        }
        switch value {
        case .number(let number) where node.checksNumbers:
            checkNumber(number, node, at: path, into: &found)
        case .string(let string) where node.checksStrings:
            checkString(string, node, at: path, into: &found)
        case .array(let elements):
            checkArray(elements, node, at: &path, into: &found)
        case .object(let members):
            checkObject(members, node, at: &path, into: &found)
        default:
            break
        }
        for index in node.allOf { check(value, against: index, at: &path, into: &found) }
        if !node.anyOf.isEmpty, !node.anyOf.contains(where: { holds(value, against: $0, at: &path) }) {
            report("anyOf", "\(name()) doesn't fit any of its forms.")
        }
        if !node.oneOf.isEmpty {
            let fits = node.oneOf.count { holds(value, against: $0, at: &path) }
            if fits != 1 { report("oneOf", fits == 0 ? "\(name()) doesn't fit any of its forms." : "\(name()) fits more than one of its forms.") }
        }
        if let not = node.not, holds(value, against: not, at: &path) {
            report("not", "\(name()) fits a form it shouldn't.")
        }
        if let condition = node.condition {
            let branch = holds(value, against: condition, at: &path) ? node.then : node.else
            if let branch { check(value, against: branch, at: &path, into: &found) }
        }
    }

    /// A place's title: its schema's, else that of the schema its `$ref` points to.
    private func title(of node: Node) -> String? {
        node.title ?? node.ref.flatMap { nodes[$0].title }
    }

    private func checkNumber(_ number: Double, _ node: Node, at path: [JSONPathComponent], into found: inout [SchemaViolation]) {
        func report(_ keyword: String, _ bound: Double, _ should: String) {
            let name = Naming(path: path, title: title(of: node))
            found.append(SchemaViolation(path: path, keyword: keyword,
                                         message: "\(name) is \(Self.format(number)), and should be \(should) \(Self.format(bound))."))
        }
        if let minimum = node.minimum, number < minimum { report("minimum", minimum, "at least") }
        if let maximum = node.maximum, number > maximum { report("maximum", maximum, "at most") }
        if let bound = node.exclusiveMinimum, number <= bound { report("exclusiveMinimum", bound, "more than") }
        if let bound = node.exclusiveMaximum, number >= bound { report("exclusiveMaximum", bound, "less than") }
        if let divisor = node.multipleOf, divisor > 0 {
            let quotient = number / divisor
            if !quotient.isFinite || abs(quotient - quotient.rounded()) > 1e-9 * max(1, abs(quotient)) {
                report("multipleOf", divisor, "a multiple of")
            }
        }
    }

    private func checkString(_ string: String, _ node: Node, at path: [JSONPathComponent], into found: inout [SchemaViolation]) {
        func report(_ keyword: String, _ message: (Naming) -> String) {
            found.append(SchemaViolation(path: path, keyword: keyword, message: message(Naming(path: path, title: title(of: node)))))
        }
        if node.minLength != nil || node.maxLength != nil {
            // Code points, as JSON Schema counts a string's length.
            let length = string.unicodeScalars.count
            if let minimum = node.minLength, length < minimum {
                report("minLength") { length == 0 ? "\($0) is empty." : "\($0) is \(Self.count(length, "character")) long, and should be at least \(minimum)." }
            }
            if let maximum = node.maxLength, length > maximum {
                report("maxLength") { "\($0) is \(Self.count(length, "character")) long, and should be at most \(maximum)." }
            }
        }
        if let pattern = node.pattern {
            guard let regex = pattern.regex else {
                return report("pattern") { "\($0) can't be checked: its pattern \(pattern.source) isn't a regular expression." }
            }
            if regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) == nil {
                report("pattern") { "\($0) should match \(pattern.source)." }
            }
        }
    }

    private func checkArray(_ elements: [JSONValue], _ node: Node, at path: inout [JSONPathComponent],
                            into found: inout [SchemaViolation]) {
        func name() -> Naming { Naming(path: path, title: title(of: node)) }
        func report(_ keyword: String, _ message: String) {
            found.append(SchemaViolation(path: path, keyword: keyword, message: message))
        }
        if node.items != nil || !node.prefixItems.isEmpty {
            for (offset, element) in elements.enumerated() {
                let schema: Int? = offset < node.prefixItems.count ? node.prefixItems[offset] : node.items
                guard let schema else { continue }
                if offset >= node.prefixItems.count, nodes[schema].allowsNothing {
                    // `items: false`: no element past the listed ones, said once for the array.
                    report("items", "\(name()) has \(Self.count(elements.count, "item")), and should have at most \(node.prefixItems.count).")
                    break
                }
                path.append(.element(offset))
                check(element, against: schema, at: &path, into: &found)
                path.removeLast()
            }
        }
        if let contains = node.contains {
            let fits = elements.indices.count { offset in
                path.append(.element(offset))
                defer { path.removeLast() }
                return holds(elements[offset], against: contains, at: &path)
            }
            let least = node.minContains ?? 1
            let fitting = fits == 1 ? "1 item that fits" : "\(fits) items that fit"
            if fits < least {
                report("contains", fits == 0 ? "\(name()) has no item that fits." : "\(name()) has \(fitting), and should have at least \(least).")
            }
            if let most = node.maxContains, fits > most {
                report("maxContains", "\(name()) has \(fitting), and should have at most \(most).")
            }
        }
        if let minimum = node.minItems, elements.count < minimum {
            report("minItems", "\(name()) has \(Self.count(elements.count, "item")), and should have at least \(minimum).")
        }
        if let maximum = node.maxItems, elements.count > maximum {
            report("maxItems", "\(name()) has \(Self.count(elements.count, "item")), and should have at most \(maximum).")
        }
        if node.uniqueItems, Set(elements).count != elements.count {
            report("uniqueItems", "\(name()) has the same item more than once.")
        }
    }

    /// The schema's properties first, in name order, then the members it doesn't list, in name order,
    /// against the patterns and `additionalProperties`.
    private func checkObject(_ members: JSONObject, _ node: Node, at path: inout [JSONPathComponent],
                             into found: inout [SchemaViolation]) {
        func name() -> Naming { Naming(path: path, title: title(of: node)) }
        func report(_ keyword: String, _ message: String, member: String? = nil) {
            found.append(SchemaViolation(path: member.map { path + [.member($0)] } ?? path, keyword: keyword, message: message))
        }
        func memberName(_ member: String) -> Naming {
            Naming(path: path + [.member(member)], title: node.listed[member].flatMap { nodes[$0].title })
        }
        for member in node.required where members[member] == nil {
            report("required", "\(memberName(member)) is missing.", member: member)
        }
        for (member, dependents) in node.dependentRequired where members[member] != nil {
            for dependent in dependents where members[dependent] == nil {
                report("dependentRequired", "\(memberName(dependent)) is missing, which \(memberName(member).lowercased) needs.", member: dependent)
            }
        }
        var listed = 0
        for (member, schema) in node.properties {
            guard let value = members[member] else { continue }
            listed += 1
            path.append(.member(member))
            check(value, against: schema, at: &path, into: &found)
            path.removeLast()
        }
        // The rest, only when something could say anything about them.
        if node.propertyNames != nil || !node.patternProperties.isEmpty || (node.additionalProperties != nil && listed < members.count) {
            let object = name().lowercased
            for member in members.keys.sorted() {
                let value = members[member]!
                path.append(.member(member))
                defer { path.removeLast() }
                if let names = node.propertyNames, !holds(.string(member), against: names, at: &path) {
                    found.append(SchemaViolation(path: path, keyword: "propertyNames", message: "\(member) isn't a name \(object) allows."))
                }
                var matched = node.listed[member] != nil
                for (regex, schema) in node.patternProperties where regex.firstMatch(in: member, range: NSRange(member.startIndex..., in: member)) != nil {
                    matched = true
                    check(value, against: schema, at: &path, into: &found)
                }
                if !matched, let additional = node.additionalProperties {
                    if nodes[additional].allowsNothing {
                        found.append(SchemaViolation(path: path, keyword: "additionalProperties",
                                                     message: "\(Naming(path: path, title: nil)) isn't one of \(object)'s properties."))
                    } else {
                        check(value, against: additional, at: &path, into: &found)
                    }
                }
            }
        }
        if let minimum = node.minProperties, members.count < minimum {
            report("minProperties", "\(name()) has \(Self.count(members.count, "property", "properties")), and should have at least \(minimum).")
        }
        if let maximum = node.maxProperties, members.count > maximum {
            report("maxProperties", "\(name()) has \(Self.count(members.count, "property", "properties")), and should have at most \(maximum).")
        }
    }

    // MARK: Words

    private static func typeName(_ type: String) -> String {
        switch type {
        case "null": "null"
        case "boolean": "true or false"
        case "object": "an object"
        case "array": "an array"
        case "number": "a number"
        case "integer": "a whole number"
        case "string": "a string"
        default: type
        }
    }

    /// What a value is, briefly: a string or a number as written, anything else by its type.
    private static func describe(_ value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool(let bool): "\(bool)"
        case .number(let number): format(number)
        case .string(let string): string.count <= 20 ? "\"\(string)\"" : "a string"
        case .array: "an array"
        case .object: "an object"
        }
    }

    /// A value as JSON writes it, on one line.
    private static func literal(_ value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool(let bool): "\(bool)"
        case .number(let number): format(number)
        case .string(let string): "\"\(string)\""
        case .array(let elements): "[\(elements.map(literal).joined(separator: ", "))]"
        case .object(let members): "{\(members.keys.sorted().map { "\"\($0)\": \(literal(members[$0]!))" }.joined(separator: ", "))}"
        }
    }

    /// Without a fraction when it's whole: 80, 0.5.
    static func format(_ number: Double) -> String {
        number.rounded() == number && abs(number) < 1e15 ? "\(Int64(number))" : "\(number)"
    }

    private static func count(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(count) \(count == 1 ? singular : plural ?? "\(singular)s")"
    }

    /// "a, b or c"; "a, b and c" when `or` is false.
    private static func list(_ items: [String], or: Bool) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + (or ? " or " : " and ") + items.last!
    }
}

/// JSON's types, as a schema's `type` names them.
private struct JSONTypes: OptionSet {
    let rawValue: UInt8
    static let null = JSONTypes(rawValue: 1 << 0)
    static let boolean = JSONTypes(rawValue: 1 << 1)
    static let object = JSONTypes(rawValue: 1 << 2)
    static let array = JSONTypes(rawValue: 1 << 3)
    static let number = JSONTypes(rawValue: 1 << 4)
    static let string = JSONTypes(rawValue: 1 << 5)
    static let integer = JSONTypes(rawValue: 1 << 6)

    init(rawValue: UInt8) { self.rawValue = rawValue }

    /// The types a value is: a whole number is an integer as well as a number.
    init(of value: JSONValue) {
        switch value {
        case .null: self = .null
        case .bool: self = .boolean
        case .object: self = .object
        case .array: self = .array
        case .string: self = .string
        case .number(let number): self = number.isFinite && number.rounded() == number ? [.number, .integer] : .number
        }
    }

    /// Those named; a name that isn't a type names none.
    init(names: [String]) {
        let known: [String: JSONTypes] = ["null": .null, "boolean": .boolean, "object": .object, "array": .array,
                                          "number": .number, "string": .string, "integer": .integer]
        self = names.reduce(into: []) { types, name in types.formUnion(known[name] ?? []) }
    }
}

/// What a message calls a place in the value: its schema's title, else its path ("Title",
/// "Checklist › item 3 › text"), else, at the root, "The value". Capitalized, to start a sentence.
private struct Naming: CustomStringConvertible {
    let path: [JSONPathComponent]
    let title: String?

    var description: String {
        let words = lowercased
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// As it reads mid-sentence: a title with its first letter lowercased, a path as it's written.
    var lowercased: String {
        if let title, !title.isEmpty { return title.prefix(1).lowercased() + title.dropFirst() }
        guard !path.isEmpty else { return "the value" }
        return path.map { component in
            switch component {
            case .member(let name): name
            case .element(let index): "item \(index + 1)"
            }
        }.joined(separator: " › ")
    }
}

// MARK: Compiling

/// One schema (or subschema), its keywords read out once. Filled while compiling, then never
/// changed, so it's shared freely.
private final class Node: @unchecked Sendable {
    /// `false`: nothing fits.
    var allowsNothing = false
    var title: String?
    var ref: Int?
    /// A `$ref` to a place the schema doesn't have.
    var unresolvedRef: String?
    /// Nil: any type.
    var types: JSONTypes?
    /// As the schema names them, for messages.
    var typeNames: [String] = []
    var enumValues: [JSONValue]?
    var constValue: JSONValue?
    var minimum: Double?
    var maximum: Double?
    var exclusiveMinimum: Double?
    var exclusiveMaximum: Double?
    var multipleOf: Double?
    var minLength: Int?
    var maxLength: Int?
    var pattern: (source: String, regex: NSRegularExpression?)?
    var prefixItems: [Int] = []
    var items: Int?
    var contains: Int?
    var minContains: Int?
    var maxContains: Int?
    var minItems: Int?
    var maxItems: Int?
    var uniqueItems = false
    /// In name order.
    var properties: [(name: String, schema: Int)] = []
    /// The same, by name.
    var listed: [String: Int] = [:]
    var patternProperties: [(regex: NSRegularExpression, schema: Int)] = []
    var additionalProperties: Int?
    var propertyNames: Int?
    var required: [String] = []
    /// In name order.
    var dependentRequired: [(String, [String])] = []
    var minProperties: Int?
    var maxProperties: Int?
    var allOf: [Int] = []
    var anyOf: [Int] = []
    var oneOf: [Int] = []
    var not: Int?
    var condition: Int?
    var then: Int?
    var `else`: Int?

    /// Whether a number or a string has anything to be held to here, beyond its type.
    var checksNumbers: Bool { minimum != nil || maximum != nil || exclusiveMinimum != nil || exclusiveMaximum != nil || multipleOf != nil }
    var checksStrings: Bool { minLength != nil || maxLength != nil || pattern != nil }
}

private struct Compiler {
    let root: JSONValue
    var nodes: [Node] = []
    /// Each place compiled, by its JSON Pointer from the root (`#/$defs/core.rect`), so a `$ref` to
    /// a place already compiled, or being compiled (a type that holds itself), finds its node.
    var byPointer: [String: Int] = [:]

    init(root: JSONValue) { self.root = root }

    mutating func node(for schema: JSONValue, at pointer: String) -> Int {
        if let known = byPointer[pointer] { return known }
        let node = Node()
        nodes.append(node)
        let index = nodes.count - 1
        byPointer[pointer] = index
        fill(node, from: schema, at: pointer)
        return index
    }

    private mutating func fill(_ node: Node, from schema: JSONValue, at pointer: String) {
        guard case .object(let json) = schema else {
            // `true` (or anything that isn't a schema) allows anything.
            if case .bool(false) = schema { node.allowsNothing = true }
            return
        }
        func child(_ keyword: String) -> Int? {
            json[keyword].map { self.node(for: $0, at: "\(pointer)/\(keyword)") }
        }
        func children(_ keyword: String) -> [Int] {
            (json[keyword]?.arrayValue ?? []).enumerated().map { self.node(for: $1, at: "\(pointer)/\(keyword)/\($0)") }
        }
        func count(_ keyword: String) -> Int? { json[keyword]?.numberValue.flatMap { Int(exactly: $0) } }

        node.title = json["title"]?.stringValue
        if let reference = json["$ref"]?.stringValue {
            if let target = Self.resolve(reference, in: root) {
                node.ref = self.node(for: target, at: Self.normalized(reference))
            } else {
                node.unresolvedRef = reference
            }
        }
        if let type = json["type"] {
            node.typeNames = type.stringValue.map { [$0] } ?? (type.arrayValue ?? []).compactMap(\.stringValue)
            let types = JSONTypes(names: node.typeNames)
            node.types = types.isEmpty ? nil : types
        }
        node.enumValues = json["enum"]?.arrayValue
        node.constValue = json["const"]
        node.minimum = json["minimum"]?.numberValue
        node.maximum = json["maximum"]?.numberValue
        node.exclusiveMinimum = json["exclusiveMinimum"]?.numberValue
        node.exclusiveMaximum = json["exclusiveMaximum"]?.numberValue
        node.multipleOf = json["multipleOf"]?.numberValue
        node.minLength = count("minLength")
        node.maxLength = count("maxLength")
        if let pattern = json["pattern"]?.stringValue { node.pattern = (pattern, try? NSRegularExpression(pattern: pattern)) }
        node.prefixItems = children("prefixItems")
        node.items = child("items")
        node.contains = child("contains")
        node.minContains = count("minContains")
        node.maxContains = count("maxContains")
        node.minItems = count("minItems")
        node.maxItems = count("maxItems")
        node.uniqueItems = json["uniqueItems"]?.boolValue ?? false
        let properties = json["properties"]?.objectValue ?? [:]
        node.properties = properties.keys.sorted().map { ($0, self.node(for: properties[$0]!, at: "\(pointer)/properties/\(Self.escaped($0))")) }
        node.listed = Dictionary(uniqueKeysWithValues: node.properties.map { ($0.name, $0.schema) })
        let patterns = json["patternProperties"]?.objectValue ?? [:]
        node.patternProperties = patterns.keys.sorted().compactMap { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, self.node(for: patterns[pattern]!, at: "\(pointer)/patternProperties/\(Self.escaped(pattern))"))
        }
        node.additionalProperties = child("additionalProperties")
        node.propertyNames = child("propertyNames")
        node.required = (json["required"]?.arrayValue ?? []).compactMap(\.stringValue)
        let dependents = json["dependentRequired"]?.objectValue ?? [:]
        node.dependentRequired = dependents.keys.sorted().map { ($0, (dependents[$0]?.arrayValue ?? []).compactMap(\.stringValue)) }
        node.minProperties = count("minProperties")
        node.maxProperties = count("maxProperties")
        node.allOf = children("allOf")
        node.anyOf = children("anyOf")
        node.oneOf = children("oneOf")
        node.not = child("not")
        node.condition = child("if")
        node.then = child("then")
        node.else = child("else")
    }

    /// The place a local `$ref` points to (`#`, `#/$defs/core.rect`), percent-decoded and unescaped
    /// as a JSON Pointer; nil for one that isn't local, or isn't there.
    static func resolve(_ reference: String, in root: JSONValue) -> JSONValue? {
        guard reference.hasPrefix("#") else { return nil }
        let pointer = String(reference.dropFirst()).removingPercentEncoding ?? String(reference.dropFirst())
        guard !pointer.isEmpty else { return root }
        guard pointer.hasPrefix("/") else { return nil }
        var value = root
        for token in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let name = token.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            switch value {
            case .object(let members):
                guard let member = members[name] else { return nil }
                value = member
            case .array(let elements):
                guard let index = Int(name), elements.indices.contains(index) else { return nil }
                value = elements[index]
            default:
                return nil
            }
        }
        return value
    }

    /// A `$ref` as the pointer the compiler files its place under.
    static func normalized(_ reference: String) -> String {
        reference.removingPercentEncoding ?? reference
    }

    static func escaped(_ name: String) -> String {
        name.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }
}
