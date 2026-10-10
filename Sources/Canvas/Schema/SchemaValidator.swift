import Foundation

/// Where a JSON value breaks a schema: one keyword, at one place in the value.
///
/// Equal by `path`, `keyword` and `message`: `detail` is the message less the place's name, so it
/// follows from them.
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
    /// What's wrong without naming the place, for a reader that says the place its own way:
    /// "is 95 characters long, and should be at most 80." The message is the place's name, a space,
    /// and this. A violation made by hand with no detail has its message.
    public let detail: String

    public init(path: [JSONPathComponent], keyword: String, message: String, detail: String? = nil) {
        self.path = path
        self.keyword = keyword
        self.message = message
        self.detail = detail ?? message
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.path == b.path && a.keyword == b.keyword && a.message == b.message
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(path)
        hasher.combine(keyword)
        hasher.combine(message)
    }

    /// The root's member it's in (`title`, `frame`); nil for the root itself.
    public var property: String? {
        guard case .member(let name)? = path.first else { return nil }
        return name
    }

    /// The path as a JSON Pointer (RFC 6901): "/items/2/text"; empty for the root.
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
        case .member(let name): JSONPointer.escaped(name)
        case .element(let index): "\(index)"
        }
    }
}

/// JSON Pointer (RFC 6901), both ways: a name as one step of a pointer, `~` written `~0` and `/`
/// `~1`, and back; and a pointer as a `$ref` writes it, a URI fragment.
enum JSONPointer {
    static func escaped(_ name: String) -> String {
        name.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }

    static func unescaped(_ token: some StringProtocol) -> String {
        token.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
    }

    /// `#` and the pointer, each character a fragment can't hold percent-encoded (`%` too):
    /// `#/$defs/core.rect`.
    static func fragment(_ pointer: String) -> String {
        "#" + (pointer.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? pointer)
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
/// Strings are compared as JSON Schema compares them, code point for code point (Swift's `==`
/// equates "é" and "e\u{301}"). Patterns are ECMA-262's, as JSON Schema's are, run by ICU
/// (`NSRegularExpression`) once what it reads otherwise is rewritten (`ICUPattern`); one ICU can't
/// read at all is a problem of the schema's.
///
/// A `$ref` may also name a schema outside this one, `urn:uuid:…#/$defs/name`: `init(_:resources:)`
/// asks its resolver for the schema filed under the part before the first `#`, verbatim (no RFC 3986
/// resolution against `$id`, which stays an annotation), once per URI however many refs name it,
/// then follows the fragment in that schema, whose own `#/…` refs are to itself. A `$ref` with no
/// resolver to ask, or that the resolver has no schema for, is a problem like one to nowhere.
public struct SchemaValidator: Sendable {
    private let nodes: [Node]
    /// What's wrong with the schema itself, each saying where it is: a `$ref` to a place the schema
    /// doesn't have, a pattern that isn't a regular expression, a place whose `$ref` leads back to
    /// it before going into the value (checking one would never end). Empty for a sound schema.
    /// Checking a value says each where the value meets it, as "can't be checked"; the registry
    /// refuses a kind whose schema has any.
    public let problems: [String]
    /// The URIs outside the schema that its `$ref`s name, each once, in the order the compiler met
    /// them, found or not: what a caller that keeps this validator drops it on when one of those
    /// schemas changes (or appears). Empty without a resolver.
    public let resources: [String]

    public init(_ schema: JSONSchema) {
        var compiler = Compiler(root: .object(schema.json), resolver: nil)
        _ = compiler.node(for: .object(schema.json), at: "#")
        compiler.markLoops()
        nodes = compiler.nodes
        problems = compiler.problems
        resources = []
    }

    /// The schema compiled with `resources` to ask for the schemas its `$ref`s name outside it: the
    /// URI is the `$ref`'s part before its first `#`, as written, and nil is a schema it doesn't
    /// have. It runs while compiling and isn't kept, so a validator is as `Sendable` as ever: it may
    /// close over state that isn't, or read a snapshot taken for the purpose.
    public init(_ schema: JSONSchema, resources resolve: (_ uri: String) -> JSONSchema?) {
        let compiled = withoutActuallyEscaping(resolve) { resolver in
            var compiler = Compiler(root: .object(schema.json), resolver: resolver)
            _ = compiler.node(for: .object(schema.json), at: "#")
            compiler.markLoops()
            return (compiler.nodes, compiler.problems, compiler.met)
        }
        (nodes, problems, resources) = compiled
    }

    /// Where `value` breaks the schema, in the order the schema lists what it checks; empty when it
    /// holds up.
    public func violations(of value: JSONValue) -> [SchemaViolation] {
        var path: [JSONPathComponent] = []
        var found = Found(quiet: false)
        check(value, against: 0, at: &path, into: &found)
        return found.violations
    }

    /// Whether `value` holds up against node `index`: for the applicators that only ask (`anyOf`,
    /// `not`, `if`), whose own violations aren't reported, so aren't worded.
    private func holds(_ value: JSONValue, against index: Int, at path: inout [JSONPathComponent]) -> Bool {
        var found = Found(quiet: true)
        check(value, against: index, at: &path, into: &found)
        return !found.broke
    }

    private func check(_ value: JSONValue, against index: Int, at path: inout [JSONPathComponent], into found: inout Found) {
        guard !found.isSettled else { return }
        let node = nodes[index]
        // What the place is called, worked out only when there's something to say about it.
        func name() -> Naming { Naming(path: path, title: title(of: node)) }
        if node.allowsNothing { return found.report(path, "false", name: name(), "isn’t allowed here.") }
        if let unresolved = node.unresolvedRef {
            return found.report(path, "$ref", name: name(), "can’t be checked: its schema refers to \(unresolved), which \(node.unresolvedWhole ? "can’t be found" : "isn’t in it").")
        }
        if node.loops {
            return found.report(path, "$ref", name: name(), "can’t be checked: its schema refers back to itself without end.")
        }
        if let ref = node.ref { check(value, against: ref, at: &path, into: &found) }
        // A value of the wrong type isn't what the rest describes: that's all there is to say.
        if let types = node.types, types.isDisjoint(with: JSONTypes(of: value)) {
            return found.report(path, "type", name: name(), "should be \(Self.list(node.typeNames.map(Self.typeName), or: true)), not \(Self.describe(value)).")
        }
        if let values = node.enumValues, !values.contains(where: { Self.same($0, value) }) {
            found.report(path, "enum", name: name(), "should be \(Self.list(values.map(Self.literal), or: true)).")
        }
        if let constant = node.constValue, !Self.same(value, constant) {
            found.report(path, "const", name: name(), "should be \(Self.literal(constant)).")
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
            found.report(path, "anyOf", name: name(), "doesn’t fit any of its forms.")
        }
        if !node.oneOf.isEmpty {
            let fits = node.oneOf.count { holds(value, against: $0, at: &path) }
            if fits != 1 { found.report(path, "oneOf", name: name(), fits == 0 ? "doesn’t fit any of its forms." : "fits more than one of its forms.") }
        }
        if let not = node.not, holds(value, against: not, at: &path) {
            found.report(path, "not", name: name(), "fits a form it shouldn’t.")
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

    private func checkNumber(_ number: Double, _ node: Node, at path: [JSONPathComponent], into found: inout Found) {
        func report(_ keyword: String, _ bound: Double, _ should: String) {
            found.report(path, keyword, name: Naming(path: path, title: title(of: node)), "is \(Self.format(number)), and should be \(should) \(Self.format(bound)).")
        }
        if let minimum = node.minimum, number < minimum { report("minimum", minimum, "at least") }
        if let maximum = node.maximum, number > maximum { report("maximum", maximum, "at most") }
        if let bound = node.exclusiveMinimum, number <= bound { report("exclusiveMinimum", bound, "more than") }
        if let bound = node.exclusiveMaximum, number >= bound { report("exclusiveMaximum", bound, "less than") }
        if let divisor = node.multipleOf, divisor > 0, !Self.isMultiple(number, of: divisor) {
            report("multipleOf", divisor, "a multiple of")
        }
    }

    /// Whether `number` is a whole number of `divisor`s, as JSON's decimal numbers mean it. The
    /// remainder is exact however large the number (no quotient to overflow or round away), and the
    /// nearest multiple may be off by what the two numbers' binary forms are: half the number's
    /// precision (its ulp), and half the divisor's as many times over as the quotient, which comes
    /// to less than two of the number's ulps (700000.07 is ten million and one 0.07s, and more than
    /// an ulp off in binary); or by a billionth of the divisor. So a number whose precision is
    /// coarser than the divisor (2⁶⁰ + 256, of 3) is one, as no double between it and a multiple
    /// tells them apart.
    static func isMultiple(_ number: Double, of divisor: Double) -> Bool {
        guard number.isFinite else { return false }
        let remainder = abs(number).truncatingRemainder(dividingBy: divisor)
        return min(remainder, divisor - remainder) <= max(divisor * 1e-9, 2 * number.ulp)
    }

    private func checkString(_ string: String, _ node: Node, at path: [JSONPathComponent], into found: inout Found) {
        func name() -> Naming { Naming(path: path, title: title(of: node)) }
        if node.minLength != nil || node.maxLength != nil {
            // Code points, as JSON Schema counts a string's length.
            let length = string.unicodeScalars.count
            if let minimum = node.minLength, length < minimum {
                found.report(path, "minLength", name: name(), length == 0 ? "is empty." : "\(Self.length(of: string, length)), and should be at least \(minimum).")
            }
            if let maximum = node.maxLength, length > maximum {
                found.report(path, "maxLength", name: name(), "\(Self.length(of: string, length)), and should be at most \(maximum).")
            }
        }
        if let pattern = node.pattern {
            guard let regex = pattern.regex else {
                return found.report(path, "pattern", name: name(), "can’t be checked: its pattern \(Self.quoted(pattern.source)) isn’t a regular expression ICU can read.")
            }
            if regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) == nil {
                found.report(path, "pattern", name: name(), "should match \(pattern.source).")
            }
        }
    }

    private func checkArray(_ elements: [JSONValue], _ node: Node, at path: inout [JSONPathComponent], into found: inout Found) {
        func name() -> Naming { Naming(path: path, title: title(of: node)) }
        if node.items != nil || !node.prefixItems.isEmpty {
            for (offset, element) in elements.enumerated() {
                let schema: Int? = offset < node.prefixItems.count ? node.prefixItems[offset] : node.items
                guard let schema else { continue }
                if offset >= node.prefixItems.count, nodes[schema].allowsNothing {
                    // `items: false`: no element past the listed ones, said once for the array.
                    found.report(path, "items", name: name(), "has \(Self.count(elements.count, "item")), and should have at most \(node.prefixItems.count).")
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
                found.report(path, node.minContains == nil ? "contains" : "minContains",
                             name: name(), fits == 0 ? "has no item that fits." : "has \(fitting), and should have at least \(least).")
            }
            if let most = node.maxContains, fits > most {
                found.report(path, "maxContains", name: name(), "has \(fitting), and should have at most \(most).")
            }
        }
        if let minimum = node.minItems, elements.count < minimum {
            found.report(path, "minItems", name: name(), "has \(Self.count(elements.count, "item")), and should have at least \(minimum).")
        }
        if let maximum = node.maxItems, elements.count > maximum {
            found.report(path, "maxItems", name: name(), "has \(Self.count(elements.count, "item")), and should have at most \(maximum).")
        }
        if node.uniqueItems, Set(elements.map(Exactly.init)).count != elements.count {
            found.report(path, "uniqueItems", name: name(), "has the same item more than once.")
        }
    }

    /// The schema's properties first, in name order, then the members it doesn't list, in name order,
    /// against the patterns and `additionalProperties`. A member is a property only when its name is
    /// the property's, code point for code point.
    private func checkObject(_ members: JSONObject, _ node: Node, at path: inout [JSONPathComponent], into found: inout Found) {
        func name() -> Naming { Naming(path: path, title: title(of: node)) }
        /// The object's name, as it reads mid-sentence, from one of its members.
        func objectName() -> String { Naming(path: Array(path.dropLast()), title: title(of: node)).lowercased }
        func memberName(_ member: String) -> Naming {
            Naming(path: path + [.member(member)], title: node.listed[member].flatMap { nodes[$0].title })
        }
        for member in node.required where Self.member(member, of: members) == nil {
            found.report(path + [.member(member)], "required", name: memberName(member), "is missing.")
        }
        for (member, dependents) in node.dependentRequired where Self.member(member, of: members) != nil {
            for dependent in dependents where Self.member(dependent, of: members) == nil {
                found.report(path + [.member(dependent)], "dependentRequired",
                             name: memberName(dependent), "is missing, which \(memberName(member).lowercased) needs.")
            }
        }
        var listed = 0
        for (member, schema) in node.properties {
            guard let value = Self.member(member, of: members) else { continue }
            listed += 1
            path.append(.member(member))
            check(value, against: schema, at: &path, into: &found)
            path.removeLast()
        }
        // The rest, only when something could say anything about them.
        if node.propertyNames != nil || !node.patternProperties.isEmpty || (node.additionalProperties != nil && listed < members.count) {
            // A pattern that isn't a regular expression can't say which members it's for: said once,
            // and none of the rest is held to `additionalProperties`.
            let broken = node.patternProperties.first { $0.regex == nil }
            if let broken {
                found.report(path, "patternProperties",
                             name: name(), "can’t be checked: its pattern \(Self.quoted(broken.source)) for properties isn’t a regular expression ICU can read.")
            }
            for member in members.keys.sorted() {
                let value = members[member]!
                path.append(.member(member))
                defer { path.removeLast() }
                if let names = node.propertyNames, !holds(.string(member), against: names, at: &path) {
                    found.report(path, "propertyNames", name: member, "isn’t a name \(objectName()) allows.")
                }
                var matched = broken != nil || Self.member(member, of: node.listed) != nil
                for (_, regex, schema) in node.patternProperties {
                    guard let regex, regex.firstMatch(in: member, range: NSRange(member.startIndex..., in: member)) != nil else { continue }
                    matched = true
                    check(value, against: schema, at: &path, into: &found)
                }
                if !matched, let additional = node.additionalProperties {
                    if nodes[additional].allowsNothing {
                        found.report(path, "additionalProperties", name: Naming(path: path, title: nil), "isn’t one of \(objectName())’s properties.")
                    } else {
                        check(value, against: additional, at: &path, into: &found)
                    }
                }
            }
        }
        if let minimum = node.minProperties, members.count < minimum {
            found.report(path, "minProperties", name: name(), "has \(Self.count(members.count, "property", "properties")), and should have at least \(minimum).")
        }
        if let maximum = node.maxProperties, members.count > maximum {
            found.report(path, "maxProperties", name: name(), "has \(Self.count(members.count, "property", "properties")), and should have at most \(maximum).")
        }
    }

    // MARK: Sameness

    /// Whether two values are the same JSON, as JSON Schema has it: strings code point for code point
    /// (Swift's `==` equates canonically equivalent ones), numbers by value (1 and 1.0 alike),
    /// objects member for member, whatever their order.
    static func same(_ a: JSONValue, _ b: JSONValue) -> Bool {
        switch (a, b) {
        case (.null, .null): true
        case (.bool(let a), .bool(let b)): a == b
        case (.number(let a), .number(let b)): a == b
        case (.string(let a), .string(let b)): a.utf8.elementsEqual(b.utf8)
        case (.array(let a), .array(let b)): a.count == b.count && zip(a, b).allSatisfy { same($0, $1) }
        case (.object(let a), .object(let b)):
            a.count == b.count && a.allSatisfy { key, value in member(key, of: b).map { same(value, $0) } ?? false }
        default: false
        }
    }

    /// The member named exactly `name`: a dictionary finds one whose name is only canonically
    /// equivalent too.
    static func member<Value>(_ name: String, of members: [String: Value]) -> Value? {
        guard let index = members.index(forKey: name), members[index].key.utf8.elementsEqual(name.utf8) else { return nil }
        return members[index].value
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
        case .string(let string): string.count <= 20 ? quoted(string) : "a string"
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
        case .string(let string): quoted(string)
        case .array(let elements): "[\(elements.map(literal).joined(separator: ", "))]"
        case .object(let members): "{\(members.keys.sorted().map { "\(quoted($0)): \(literal(members[$0]!))" }.joined(separator: ", "))}"
        }
    }

    /// A string as JSON writes it: in quotes, with its quotes, backslashes and control characters
    /// escaped, so a message stays on one line.
    static func quoted(_ string: String) -> String {
        var quoted = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": quoted += "\\\""
            case "\\": quoted += "\\\\"
            case "\n": quoted += "\\n"
            case "\r": quoted += "\\r"
            case "\t": quoted += "\\t"
            case _ where scalar.value < 0x20 || scalar == "\u{2028}" || scalar == "\u{2029}":
                quoted += String(format: "\\u%04x", scalar.value)
            default: quoted.unicodeScalars.append(scalar)
            }
        }
        return quoted + "\""
    }

    /// Without a fraction when it's whole: 80, 0.5.
    static func format(_ number: Double) -> String {
        number.rounded() == number && abs(number) < 1e15 ? "\(Int64(number))" : "\(number)"
    }

    private static func count(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(count) \(count == 1 ? singular : plural ?? "\(singular)s")"
    }

    /// What a string's length is, in the code points JSON Schema counts: "is 95 characters long".
    /// Where the string shows fewer characters than that (an emoji with a skin tone is two code
    /// points, an accent may be one of its own), both, so the count a person sees makes sense of
    /// the bound, without naming the standard that counts: "counts as 82 characters (41 shown)".
    private static func length(of string: String, _ codePoints: Int) -> String {
        let shown = string.count
        let counted = count(codePoints, "character")
        return shown == codePoints ? "is \(counted) long" : "counts as \(counted) (\(shown) shown)"
    }

    /// "a, b or c"; "a, b and c" when `or` is false.
    private static func list(_ items: [String], or: Bool) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + (or ? " or " : " and ") + items.last!
    }
}

/// What checking a value found. Quiet, for an applicator that only asks whether a value holds up:
/// nothing is worded or kept, and the first violation settles it.
private struct Found {
    let quiet: Bool
    private(set) var violations: [SchemaViolation] = []
    /// Whether anything broke: all a quiet one learns.
    private(set) var broke = false

    init(quiet: Bool) { self.quiet = quiet }

    /// Whether there's nothing more to find out.
    var isSettled: Bool { quiet && broke }

    /// `name` is the place as the message calls it, `detail` what is wrong without it.
    mutating func report(_ path: @autoclosure () -> [JSONPathComponent], _ keyword: String, name: @autoclosure () -> CustomStringConvertible, _ detail: @autoclosure () -> String) {
        broke = true
        guard !quiet else { return }
        let detail = detail()
        violations.append(SchemaViolation(path: path(), keyword: keyword, message: "\(name()) \(detail)", detail: detail))
    }
}

/// A value in a set as JSON Schema tells values apart (`SchemaValidator.same`): for `uniqueItems`.
private struct Exactly: Hashable {
    let value: JSONValue

    static func == (a: Self, b: Self) -> Bool { SchemaValidator.same(a.value, b.value) }

    func hash(into hasher: inout Hasher) { Self.hash(value, into: &hasher) }

    private static func hash(_ value: JSONValue, into hasher: inout Hasher) {
        switch value {
        case .null: hasher.combine(0)
        case .bool(let bool): hasher.combine(1); hasher.combine(bool)
        case .number(let number): hasher.combine(2); hasher.combine(number)
        case .string(let string): hasher.combine(3); combine(string, into: &hasher)
        case .array(let elements): hasher.combine(4); hasher.combine(elements.count); for element in elements { hash(element, into: &hasher) }
        case .object(let members):
            // In no particular order: each member hashed alone, and the hashes summed.
            hasher.combine(5)
            var sum = 0
            for (name, member) in members {
                var one = Hasher()
                combine(name, into: &one)
                hash(member, into: &one)
                sum &+= one.finalize()
            }
            hasher.combine(sum)
        }
    }

    /// A string's code points, as its UTF-8.
    private static func combine(_ string: String, into hasher: inout Hasher) {
        var string = string
        string.withUTF8 { bytes in
            hasher.combine(bytes.count)
            hasher.combine(bytes: UnsafeRawBufferPointer(bytes))
        }
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
/// "Items › item 3 › text"), else, at the root, "The value". Capitalized, to start a sentence.
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

// MARK: Patterns

/// An ECMA-262 pattern, JSON Schema's dialect, rewritten so that ICU (`NSRegularExpression`) reads
/// it the same way where the two differ: `$` is only the end of the string (ICU's also matches
/// before a line break that ends it); `.` is anything but a line terminator as ECMA counts them;
/// `\d`, `\w`, `\b` and their opposites are ASCII, and `\s` is ECMA's whitespace (ICU's are
/// Unicode's: Arabic digits, accented letters, U+0085); `\0`, `\v` and `\u{…}` are the characters
/// they are; `[^]` is any character and `[]` none; and in a class, `\b` is a backspace, and a `[`,
/// a `&`, a `:` just inside and a second `-` of two are only themselves (ICU nests and combines
/// sets there). What ICU can't read at all (a lookbehind of no fixed length, a named group that
/// isn't ASCII, a reference ahead to a group) is no regular expression here, and a schema with one
/// is refused.
enum ICUPattern {
    private static let word = "[A-Za-z0-9_]"
    private static let notWord = "[^A-Za-z0-9_]"
    private static let space = "\\t\\n\\x{0B}\\f\\r\\x{20}\\x{A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}"

    static func from(_ ecma: String) -> String {
        let scalars = Array(ecma.unicodeScalars)
        var icu = String.UnicodeScalarView()
        func append(_ text: String) { icu.append(contentsOf: text.unicodeScalars) }
        func scalar(at index: Int) -> Unicode.Scalar? { scalars.indices.contains(index) ? scalars[index] : nil }
        var inClass = false
        // In a class: whether the last thing written was a `-` of its own, so a second is escaped.
        var afterDash = false
        var index = 0
        while index < scalars.count {
            let current = scalars[index]
            if current == "\\", let next = scalar(at: index + 1) {
                afterDash = false
                switch next {
                case "d": append("[0-9]")
                case "D": append("[^0-9]")
                case "w": append(word)
                case "W": append(notWord)
                case "s": append("[\(space)]")
                case "S": append("[^\(space)]")
                case "v": append("\\x{0B}")
                case "b" where inClass: append("\\x{08}")
                case "b": append("(?:(?<=\(word))(?!\(word))|(?<!\(word))(?=\(word)))")
                case "B" where !inClass: append("(?:(?<=\(word))(?=\(word))|(?<!\(word))(?!\(word)))")
                case "0" where !(scalar(at: index + 2).map { ("0"..."9").contains($0) } ?? false):
                    append("\\x{0}")
                case "u" where scalar(at: index + 2) == "{":
                    append("\\x{")
                    index += 3
                    continue
                default:
                    icu.append(current)
                    icu.append(next)
                }
                index += 2
                continue
            }
            if inClass {
                switch current {
                case "]": inClass = false; icu.append(current)
                case "[", "&": icu.append("\\"); icu.append(current)
                case "-" where afterDash: append("\\-")
                default: icu.append(current)
                }
                afterDash = current == "-" && !afterDash
            } else if current == "[" {
                let negated = scalar(at: index + 1) == "^"
                let first = index + (negated ? 2 : 1)
                if scalar(at: first) == "]" {
                    // ECMA's `[]` matches nothing, and `[^]` anything; ICU reads a `]` just inside as itself.
                    append(negated ? "[\\x{0}-\\x{10FFFF}]" : "[^\\x{0}-\\x{10FFFF}]")
                    index = first + 1
                    continue
                }
                append(negated ? "[^" : "[")
                // A `:` just inside would start one of ICU's POSIX classes (`[:alpha:]`).
                if scalar(at: first) == ":" {
                    append("\\:")
                    index = first + 1
                } else {
                    index = first
                }
                inClass = true
                afterDash = false
                continue
            } else {
                switch current {
                case "$": append("\\z")
                case ".": append("[^\\n\\r\\x{2028}\\x{2029}]")
                default: icu.append(current)
                }
            }
            index += 1
        }
        return String(icu)
    }

    /// The pattern compiled, or nil if ICU can't read it.
    static func regex(_ ecma: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: from(ecma))
    }
}

extension SchemaValidator {
    /// A schema's pattern (`pattern`, a `patternProperties` name), ECMA-262's dialect, compiled to
    /// match as the validator matches it (`ICUPattern`); nil for one ICU can't read. For code that
    /// reads a schema's patterns beside the validator: completion's `patternProperties`.
    public static func regex(for pattern: String) -> NSRegularExpression? { ICUPattern.regex(pattern) }
}

// MARK: Compiling

/// One schema (or subschema), its keywords read out once. Filled while compiling, then never
/// changed, so it's shared freely.
private final class Node: @unchecked Sendable {
    /// `false`: nothing fits.
    var allowsNothing = false
    var title: String?
    var ref: Int?
    /// A `$ref` to a place the schema doesn't have, or (with `unresolvedWhole`) to a schema outside
    /// it that the resolver didn't have: the URI.
    var unresolvedRef: String?
    var unresolvedWhole = false
    /// A place its `$ref` leads back to before going into the value, where checking would go round
    /// forever: it stops there.
    var loops = false
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
    /// Nil regex: the pattern isn't a regular expression.
    var patternProperties: [(source: String, regex: NSRegularExpression?, schema: Int)] = []
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

    /// The places applied to the same value as this one: a loop through them never ends. `then`
    /// and `else` are applied only with an `if`.
    var inPlace: [Int] {
        [ref, not, condition].compactMap { $0 } + (condition == nil ? [] : [then, `else`].compactMap { $0 }) + allOf + anyOf + oneOf
    }
}

private struct Compiler {
    let root: JSONValue
    /// Asked for a schema outside the root, by its URI; nil when there is none to ask.
    let resolver: ((String) -> JSONSchema?)?
    var nodes: [Node] = []
    /// Where each node is, as its resource's URI (empty for the root) and a JSON Pointer from that
    /// resource's root, for `problems`: `#/$defs/core.rect`, `urn:uuid:…#/properties/name`.
    var pointers: [String] = []
    /// Each place compiled, by those same names, so a `$ref` to a place already compiled, or being
    /// compiled (a type that holds itself), finds its node.
    var byPointer: [String: Int] = [:]
    var problems: [String] = []
    /// Each resource the resolver was asked for, nil if it had none; asked once.
    private var resources: [String: JSONValue?] = [:]
    /// Their URIs, in the order they were first asked for.
    var met: [String] = []

    init(root: JSONValue, resolver: ((String) -> JSONSchema?)?) {
        self.root = root
        self.resolver = resolver
    }

    /// The schema filed under `uri`, asking the resolver the first time only.
    private mutating func resource(_ uri: String) -> JSONValue? {
        if let known = resources[uri] { return known }
        let found = resolver?(uri).map { JSONValue.object($0.json) }
        resources[uri] = .some(found)
        met.append(uri)
        return found
    }

    mutating func node(for schema: JSONValue, at pointer: String) -> Int {
        if let known = byPointer[pointer] { return known }
        let node = Node()
        nodes.append(node)
        pointers.append(pointer)
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
            // The resource the place is in: the root's, or one the resolver gave.
            let here = String(pointer[..<(pointer.firstIndex(of: "#") ?? pointer.endIndex)])
            let hash = reference.firstIndex(of: "#")
            let base = String(reference[..<(hash ?? reference.endIndex)])
            let fragment = hash.map { String(reference[$0...]) } ?? (base.isEmpty ? reference : "#")
            if base.isEmpty || base == here {
                if let target = Self.resolve(fragment, in: here.isEmpty ? root : resource(here) ?? root) {
                    node.ref = self.node(for: target, at: here + Self.normalized(fragment))
                } else {
                    node.unresolvedRef = reference
                    problems.append("the $ref at \(pointer), \(reference), isn't in the schema")
                }
            } else if resolver == nil {
                node.unresolvedRef = reference
                problems.append("the $ref at \(pointer), \(reference), isn't in the schema")
            } else if let outside = resource(base) {
                if let target = Self.resolve(fragment, in: outside) {
                    node.ref = self.node(for: target, at: base + Self.normalized(fragment))
                } else {
                    node.unresolvedRef = reference
                    problems.append("the $ref at \(pointer), \(reference), isn't in \(base)")
                }
            } else {
                node.unresolvedRef = base
                node.unresolvedWhole = true
                problems.append("the $ref at \(pointer), \(base), can't be found")
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
        if let pattern = json["pattern"]?.stringValue {
            let regex = ICUPattern.regex(pattern)
            node.pattern = (pattern, regex)
            if regex == nil { problems.append("the pattern at \(pointer), \(SchemaValidator.quoted(pattern)), isn't a regular expression ICU can read") }
        }
        node.prefixItems = children("prefixItems")
        node.items = child("items")
        node.contains = child("contains")
        node.minContains = count("minContains")
        node.maxContains = count("maxContains")
        node.minItems = count("minItems")
        node.maxItems = count("maxItems")
        node.uniqueItems = json["uniqueItems"]?.boolValue ?? false
        let properties = json["properties"]?.objectValue ?? [:]
        node.properties = properties.keys.sorted().map { ($0, self.node(for: properties[$0]!, at: "\(pointer)/properties/\(JSONPointer.escaped($0))")) }
        node.listed = Dictionary(uniqueKeysWithValues: node.properties.map { ($0.name, $0.schema) })
        let patterns = json["patternProperties"]?.objectValue ?? [:]
        node.patternProperties = patterns.keys.sorted().map { pattern in
            let regex = ICUPattern.regex(pattern)
            if regex == nil {
                problems.append("the pattern for properties at \(pointer), \(SchemaValidator.quoted(pattern)), isn't a regular expression ICU can read")
            }
            return (pattern, regex, self.node(for: patterns[pattern]!, at: "\(pointer)/patternProperties/\(JSONPointer.escaped(pattern))"))
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

    /// Marks each place whose `$ref` leads back to it, through places applied to the same value
    /// (`$ref`, `allOf`, `anyOf`, `oneOf`, `not`, `if`, `then`, `else`), where checking would go
    /// round forever: `{"$ref": "#"}`, two definitions that are each other's `allOf`. A loop that
    /// goes into the value on the way (a type that holds itself) ends with the value, so it's fine.
    /// Every loop has one place marked (the first a depth-first walk meets), which is enough to end
    /// it.
    mutating func markLoops() {
        // 0 not met yet, 1 on the walk's way, 2 done.
        var state = [UInt8](repeating: 0, count: nodes.count)
        var marked: [Int] = []
        func visit(_ index: Int) {
            state[index] = 1
            for next in nodes[index].inPlace {
                if state[next] == 0 {
                    visit(next)
                } else if state[next] == 1, !nodes[next].loops {
                    nodes[next].loops = true
                    marked.append(next)
                }
            }
            state[index] = 2
        }
        for index in nodes.indices where state[index] == 0 { visit(index) }
        problems += marked.map { "\(pointers[$0]) refers back to itself without going into the value, so checking one would never end" }
    }

    /// The place a fragment points to in the resource whose root is `root` (`#`, `#/$defs/core.rect`),
    /// percent-decoded and unescaped as a JSON Pointer; nil for one that isn't there.
    static func resolve(_ reference: String, in root: JSONValue) -> JSONValue? {
        guard reference.hasPrefix("#") else { return nil }
        let pointer = String(reference.dropFirst()).removingPercentEncoding ?? String(reference.dropFirst())
        guard !pointer.isEmpty else { return root }
        guard pointer.hasPrefix("/") else { return nil }
        var value = root
        for token in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let name = JSONPointer.unescaped(token)
            switch value {
            case .object(let members):
                guard let member = SchemaValidator.member(name, of: members) else { return nil }
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

    /// A fragment as the pointer the compiler files its place under (after its resource's URI).
    static func normalized(_ reference: String) -> String {
        reference.removingPercentEncoding ?? reference
    }
}
