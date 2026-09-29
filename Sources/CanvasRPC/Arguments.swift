import Foundation

// A command's params, spelled as command-line arguments. The app describes each command's params
// as a JSON Schema (`CommandSpec.params`); what a property's schema says its value is decides how
// it's written:
//
//     a string                                  --kind sticky-note       (one of its enum's, if it has one)
//     a number, an integer                      --estimate 3
//     a boolean                                 --schema, --no-schema, --schema=false
//     a fixed number of numbers (a point)       --at 10,20               (or as JSON: --at '[10, 20]')
//     an array of any of those                  --set a=1 --set b=2      (repeatable)
//     anything else (an object)                 --props '{"text": "Hi"}' (JSON; - reads it from standard input)
//
// Text whose schema says `"x-stdin": true` (a script) is read from standard input when it's given
// as -, as JSON always is; help writes its value <script>|-. A param whose schema says
// `"x-timeout": 60` has the app wait on something slow (a language model): given, `canvas` waits up
// to that many seconds for the answer, and help says so.
//
// `--name=value` works as well as `--name value`, `fooBar` is `--foo-bar` (or `--fooBar`), `--`
// ends the options, and the command's positionals take what's left, in order.

/// One of a command's params, as the command line reads and shows it.
public struct CommandArgument: Equatable, Sendable {
    /// The param's name, as the request has it.
    public let name: String
    /// `--name`, with a camelCase name spelled with hyphens.
    public let option: String
    /// Also taken by position, without its option.
    public let isPositional: Bool
    public let isRequired: Bool
    public let value: ValueShape
    /// What its schema's `description` says.
    public let summary: String?
    public let defaultValue: JSON?
    /// What help calls its value: `<x,y>`.
    public let valueName: String
    /// Text given as `-` is read from standard input: its schema says `"x-stdin": true`.
    public let readsStandardInput: Bool
    /// How long, in seconds, `canvas` waits for the answer to a request that gives it: its schema's
    /// `"x-timeout"`, for a param the app waits on something slow for. Nil: the usual wait.
    public let waits: TimeInterval?

    /// Whether `--word` names it.
    func matches(_ word: String) -> Bool { word == name || "--\(word)" == option }

    /// Its value as usage and help write it: `<x,y>`, or `<script>|-` for one that standard input
    /// can give.
    var valueLabel: String { "<\(valueName)>" + (readsStandardInput ? "|-" : "") }
}

/// How a value is written, from what its schema says it is.
public indirect enum ValueShape: Equatable, Sendable {
    /// As typed, and one of `choices` if there are any.
    case text(choices: [String]?)
    case number
    case integer
    /// Present or not: `--name`, `--no-name`.
    case flag
    /// This many numbers, separated by commas: a point, a size.
    case numbers(Int)
    /// The option given again for each element.
    case list(ValueShape)
    /// JSON text.
    case json

    var isRepeatable: Bool {
        if case .list = self { true } else { false }
    }
}

/// Why standard input's text couldn't be had.
public enum StandardInputError: Error, CustomStringConvertible, Sendable {
    /// Its bytes aren't UTF-8.
    case notUTF8
    /// It's closed: there's nothing to read.
    case closed

    public var description: String {
        switch self {
        case .notUTF8: "it isn't UTF-8 text"
        case .closed: "it's closed"
        }
    }
}

/// Arguments that don't spell a command's params: what's wrong, and what would help.
public struct ArgumentError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public let hint: String?

    public init(_ message: String, hint: String? = nil) {
        self.message = message
        self.hint = hint
    }

    public var description: String { message }
}

extension CommandSpec {
    /// Its params as arguments: the positionals in order, then the other options by name, then
    /// `--board` for a board's command.
    public var arguments: [CommandArgument] {
        let properties = params["properties"]?.objectValue ?? [:]
        let required = Set(params["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        let names = positionals.filter { properties[$0] != nil } + properties.keys.filter { !positionals.contains($0) }.sorted()
        var arguments = names.map { name in
            let written = properties[name] ?? [:], schema = resolve(written)
            let shape = shape(of: schema)
            return CommandArgument(name: name, option: "--\(Self.hyphenated(name))", isPositional: positionals.contains(name),
                                   isRequired: required.contains(name), value: shape, summary: schema["description"]?.stringValue,
                                   defaultValue: schema["default"], valueName: valueName(name, written, shape),
                                   readsStandardInput: schema["x-stdin"] == .bool(true),
                                   waits: schema["x-timeout"]?.numberValue.flatMap { $0 > 0 && $0.isFinite ? $0 : nil })
        }
        if scope == .board {
            arguments.append(CommandArgument(
                name: RPC.boardParam, option: "--\(RPC.boardParam)", isPositional: false, isRequired: false, value: .text(choices: nil),
                summary: "The board to work on: its id (`\(RPC.commandName) boards`), its file, or its name. Default: the board in front.",
                defaultValue: nil, valueName: "board", readsStandardInput: false, waits: nil))
        }
        return arguments
    }

    /// The params `arguments` (what follows the command's name) spell. `standardInput` is read for a
    /// JSON value given as `-`.
    public func params(from arguments: [String], standardInput: () throws -> String = CommandSpec.readStandardInput) throws(ArgumentError) -> [String: JSON] {
        let all = self.arguments
        var params: [String: JSON] = [:]
        var loose: [String] = []
        var index = 0, optionsEnded = false
        while index < arguments.count {
            let word = arguments[index]
            index += 1
            if !optionsEnded, word == "--" {
                optionsEnded = true
                continue
            }
            guard !optionsEnded, word.hasPrefix("--"), word.count > 2 else {
                loose.append(word)
                continue
            }
            var name = String(word.dropFirst(2)), inline: String?
            if let equals = name.firstIndex(of: "=") {
                inline = String(name[name.index(after: equals)...])
                name = String(name[..<equals])
            }
            var argument = all.first { $0.matches(name) }, negated = false
            if argument == nil, name.hasPrefix("no-"), let flag = all.first(where: { $0.matches(String(name.dropFirst(3))) && $0.value == .flag }) {
                argument = flag
                negated = true
            }
            guard let argument else {
                let options = all.map(\.option)
                let listed = options.isEmpty ? "It takes no options." : "Its options: \(options.joined(separator: ", "))."
                // Every board's command takes --board: one about the app says why it doesn't.
                let aboutApp = name == RPC.boardParam && scope == .app ? "It's about the app, not a board. " : ""
                throw ArgumentError("\(self.name) has no option --\(name)",
                                    hint: Self.closest(to: "--\(name)", among: options).map { "Did you mean \($0)?" } ?? aboutApp + listed)
            }
            let value: JSON
            if argument.value == .flag {
                if let inline {
                    guard !negated, let bool = Self.bool(inline) else {
                        throw ArgumentError("\(argument.option) is on or off: true or false, not \(inline)")
                    }
                    value = .bool(bool)
                } else {
                    value = .bool(!negated)
                }
            } else {
                let text: String
                if let inline {
                    text = inline
                } else {
                    guard index < arguments.count else { throw ArgumentError("\(argument.option) needs a value: \(argument.valueLabel)") }
                    text = arguments[index]
                    index += 1
                }
                value = try Self.value(text, for: argument, standardInput: standardInput)
            }
            try Self.put(value, for: argument, in: &params)
        }
        var rest = loose[...]
        for name in positionals {
            guard let argument = all.first(where: { $0.name == name }) else { continue }
            if argument.value.isRepeatable {
                while let text = rest.popFirst() { try Self.put(Self.value(text, for: argument, standardInput: standardInput), for: argument, in: &params) }
            } else if let text = rest.popFirst() {
                try Self.put(Self.value(text, for: argument, standardInput: standardInput), for: argument, in: &params)
            }
        }
        if let extra = rest.first {
            throw ArgumentError("\(name) doesn't take \(extra)", hint: "Usage: \(usage())")
        }
        for argument in all where argument.isRequired && params[argument.name] == nil {
            throw ArgumentError("\(name) needs \(argument.isPositional ? argument.valueLabel : "\(argument.option) \(argument.valueLabel)")",
                                hint: "Usage: \(usage())")
        }
        return params
    }

    /// All of standard input, as text: UTF-8, or it throws, as it does when standard input can't
    /// be read (a directory, or closed).
    public static func readStandardInput() throws -> String {
        let data = try FileHandle.standardInput.readToEnd() ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { throw StandardInputError.notUTF8 }
        return text
    }

    private static func put(_ value: JSON, for argument: CommandArgument, in params: inout [String: JSON]) throws(ArgumentError) {
        if argument.value.isRepeatable {
            params[argument.name] = .array((params[argument.name]?.arrayValue ?? []) + [value])
        } else {
            guard params[argument.name] == nil else { throw ArgumentError("\(argument.option) is given twice") }
            params[argument.name] = value
        }
    }

    /// A value as its shape says it's written.
    private static func value(_ text: String, for argument: CommandArgument, standardInput: () throws -> String) throws(ArgumentError) -> JSON {
        func value(_ text: String, as shape: ValueShape) throws(ArgumentError) -> JSON {
            let what = "\(argument.isPositional ? "<\(argument.valueName)>" : argument.option)"
            switch shape {
            case .text(let choices):
                if text == "-", argument.readsStandardInput {
                    do { return .string(try standardInput()) } catch { throw ArgumentError("\(what): standard input couldn't be read: \(error)") }
                }
                guard let choices, !choices.contains(text) else { return .string(text) }
                throw ArgumentError("\(what) is one of \(choices.joined(separator: ", ")), not \(text)",
                                    hint: closest(to: text, among: choices).map { "Did you mean \($0)?" })
            case .number:
                guard let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite else {
                    throw ArgumentError("\(what) is a number, not \(text)")
                }
                return .number(number)
            case .integer:
                guard let integer = Int(text.trimmingCharacters(in: .whitespaces)) else { throw ArgumentError("\(what) is a whole number, not \(text)") }
                return .number(Double(integer))
            case .flag:
                guard let bool = bool(text) else { throw ArgumentError("\(what) is true or false, not \(text)") }
                return .bool(bool)
            case .numbers(let count):
                let parts: [String]
                if text.hasPrefix("[") {
                    parts = ((try? JSON(text: text))?.arrayValue ?? []).map { $0.numberValue.map { "\($0)" } ?? "" }
                } else {
                    parts = text.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                }
                let numbers = parts.compactMap(Double.init).filter(\.isFinite)
                guard parts.count == count, numbers.count == count else {
                    throw ArgumentError("\(what) is \(count) numbers, as \(argument.valueName), not \(text)")
                }
                return .array(numbers.map(JSON.number))
            case .list(let element):
                return try value(text, as: element)
            case .json:
                let source: String
                if text == "-" {
                    do { source = try standardInput() } catch { throw ArgumentError("\(what): standard input couldn't be read: \(error)") }
                } else {
                    source = text
                }
                do {
                    return try JSON(text: source)
                } catch {
                    throw ArgumentError("\(what) takes JSON, which \(text == "-" ? "standard input" : "'\(text)'") isn't",
                                        hint: "Quote it for the shell: \(argument.option) '{\"name\": \"value\"}'.")
                }
            }
        }
        return try value(text, as: argument.value)
    }

    private static func bool(_ text: String) -> Bool? {
        switch text.lowercased() {
        case "true", "yes", "on", "1": true
        case "false", "no", "off", "0": false
        default: nil
        }
    }

    /// `fooBar` as `foo-bar`.
    static func hyphenated(_ name: String) -> String {
        name.reduce(into: "") { result, character in
            if character.isUppercase, !result.isEmpty { result += "-" }
            result += character.lowercased()
        }
    }

    /// What `candidate` was likely meant to be, if it's close to one of `choices`: two edits away or
    /// fewer, or one of them starts with it.
    public static func closest(to candidate: String, among choices: [String]) -> String? {
        // As close by edits, the one that starts more like it: --st is --set, not --at.
        let scored = choices.map { ($0, editDistance(candidate, $0), $0.commonPrefix(with: candidate).count) }
            .filter { $0.1 <= max(1, min(2, candidate.count / 3)) }
        return scored.min { ($0.1, -$0.2) < ($1.1, -$1.2) }?.0 ?? choices.first { $0.hasPrefix(candidate) && candidate.count >= 2 }
    }

    /// Edits from one to the other: a character added, removed or changed, or two neighbors swapped
    /// (crad is card, one edit away).
    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var beforePrevious = Array(repeating: 0, count: b.count + 1), previous = Array(0...b.count), current = previous
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { current[j] = min(current[j], beforePrevious[j - 2] + 1) }
            }
            (beforePrevious, previous, current) = (previous, current, beforePrevious)
        }
        return previous[b.count]
    }

    // MARK: Reading the schema

    func resolve(_ schema: JSON) -> JSON { schema.resolvingReference(in: params) }

    private func shape(of schema: JSON) -> ValueShape { schema.valueShape(in: params) }

    /// What help calls a value, from its property's schema as written (`$ref` and all).
    private func valueName(_ name: String, _ written: JSON, _ shape: ValueShape) -> String {
        let schema = resolve(written)
        if let named = schema["x-value-name"]?.stringValue { return named }
        switch shape {
        case .text(let choices?) where choices.count <= 4: return choices.joined(separator: "|")
        case .text: return Self.hyphenated(name)
        case .number, .integer: return "number"
        case .flag: return ""
        case .numbers(let count):
            // The core's point and size say "[x, y]" and "[width, height]", under whatever a
            // property beside the reference says.
            if let description = definition(referencedBy: written)?["description"]?.stringValue ?? schema["description"]?.stringValue,
               description.hasPrefix("["), description.hasSuffix("]") {
                let parts = description.dropFirst().dropLast().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == count, parts.allSatisfy({ $0.allSatisfy(\.isLetter) }) { return parts.joined(separator: ",") }
            }
            return Array(repeating: "n", count: count).joined(separator: ",")
        case .list(let element): return valueName(name, schema["items"] ?? [:], element)
        case .json: return "json"
        }
    }

    /// The definition a schema's `$ref` names, as it's written there.
    private func definition(referencedBy schema: JSON) -> JSON? {
        schema.referencedDefinition(in: params)
    }
}

// JSON Schema, read as the command line reads it: what `canvas` makes of an argument.
extension JSON {
    /// This schema, part of `root`, with a local `$ref` (`#/$defs/core.point`) followed to what it
    /// names; keywords beside the reference (a description, a default) say more than its target's.
    public func resolvingReference(in root: JSON) -> JSON {
        var schema = self, seen: Set<String> = []
        while let reference = schema["$ref"]?.stringValue, seen.insert(reference).inserted, let target = schema.referencedDefinition(in: root) {
            var merged = target
            for (key, value) in schema.objectValue ?? [:] where key != "$ref" { merged[key] = value }
            schema = merged
        }
        return schema
    }

    /// The definition this schema's local `$ref` names in `root`, as it's written there.
    func referencedDefinition(in root: JSON) -> JSON? {
        guard let reference = self["$ref"]?.stringValue, reference.hasPrefix("#/$defs/") else { return nil }
        return root["$defs"]?[String(reference.dropFirst("#/$defs/".count))]
    }

    /// How a value this schema (part of `root`) describes is written on a command line: text for a
    /// string, one of its choices if it has them, and so on (`ValueShape`).
    public func valueShape(in root: JSON) -> ValueShape {
        let schema = resolvingReference(in: root)
        switch schema["type"]?.stringValue {
        case "string": return .text(choices: schema.choices(in: root))
        case "number": return .number
        case "integer": return .integer
        case "boolean": return .flag
        case "array":
            if let prefix = schema["prefixItems"]?.arrayValue, !prefix.isEmpty, schema["items"] == .bool(false),
               prefix.allSatisfy({ ["number", "integer"].contains($0.resolvingReference(in: root)["type"]?.stringValue) }) {
                return .numbers(prefix.count)
            }
            if let items = schema["items"], items.objectValue != nil {
                let element = items.valueShape(in: root)
                switch element {
                case .text, .number, .integer, .numbers: return .list(element)
                case .flag, .list, .json: return .json
                }
            }
            return .json
        default:
            if let choices = schema.choices(in: root) { return .text(choices: choices) }
            return .json
        }
    }

    /// The strings a string must be: its `enum`, or the `const` of each of its `oneOf`.
    private func choices(in root: JSON) -> [String]? {
        if let values = self["enum"]?.arrayValue {
            let strings = values.compactMap(\.stringValue)
            return strings.count == values.count ? strings : nil
        }
        if let cases = self["oneOf"]?.arrayValue {
            let strings = cases.compactMap { $0.resolvingReference(in: root)["const"]?.stringValue }
            return strings.count == cases.count && !strings.isEmpty ? strings : nil
        }
        return nil
    }
}
