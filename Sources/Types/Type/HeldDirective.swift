import Canvas

/// A member of a type's schema that is held aside from what the type says of its fields: `"$name": {"const": <a
/// literal>}` in the root's `properties`, beside `$title` (`SchemaDirectives`: no field, no row, nothing a note of the
/// type holds). Types holds two, each kept saying what a value of the type's shape says by a rule `canBeType()` gives
/// the kind: `$color`, the type's color (`TypeColorDirective`), and `$autofill`, whether its notes fill their fields
/// from their words (`TypeAutofillDirective`); another plugin gives more (`registrar.typeDirective`: LanguageRules'
/// `$rules`). What they share is `HeldDirectives`'. The edits here keep the rest of the text as typed.
public struct HeldDirective: Sendable {
    /// The member's key in the root's `properties`: `$color`.
    public let key: String
    /// The member's one keyword: what it says.
    public static let keyword = "const"

    /// The directive `$name`: a plugin that holds one (`registrar.typeDirective(name)`) writes it through this.
    public init(name: String) { key = "$" + name }

    /// The member, as the root says it (the last of the last `properties`, as JSON is read); nil for none.
    func member(in root: JSONNode) -> JSONNode? { root["properties"]?[key] }

    /// `text` with the member's `const` saying `literal` (JSON, as written), or without the member for nil, the rest of
    /// the text as typed: how a plugin writes the directive it holds. Nil when the text isn't a JSON object or its
    /// `properties` isn't one.
    public func text(_ text: String, setting literal: String?) -> String? {
        guard let literal else { return removed(from: text) }
        return self.text(text, saying: literal, isSaid: { _ in false })
    }

    /// `text` with the member saying `literal` (JSON, as written): the `const` of the member replaced (its
    /// value made `{"const": …}` if it was something else; the text itself where `isSaid` holds of the `const`
    /// it has), else the member put in first in the root's `properties` (and a `properties` put in the root,
    /// first, if it has none). Nil when the text isn't a JSON object or its `properties` isn't one.
    func text(_ text: String, saying literal: String, isSaid: (JSONNode) -> Bool) -> String? {
        guard let root = try? JSONReader.read(text), root.isObject else { return nil }
        if let constant = member(in: root)?.members?.last(where: { $0.key == Self.keyword })?.value {
            return isSaid(constant) ? text : Self.replacing(constant.range, in: text, with: literal)
        }
        return setting(raw: "{\"\(Self.keyword)\": \(literal)}", in: text)
    }

    /// `written` with the member `held` has, as `held` writes it, when `written` has none. `written` as it is
    /// when it has the member, when either isn't a JSON object, or `held` has none.
    func carried(from held: String?, into written: String) -> String {
        guard let held, held.contains(key), let new = try? JSONReader.read(written), new.isObject, member(in: new) == nil,
              let old = try? JSONReader.read(held), let value = member(in: old) else { return written }
        return setting(raw: Self.slice(value.range, of: held), in: written) ?? written
    }

    /// `text` without the member.
    func stripped(_ text: String) -> String {
        guard text.contains(key) else { return text }
        return removed(from: text) ?? text
    }

    /// `text` with `raw` as the member's value: in place of the one it has, else put in.
    private func setting(raw: String, in text: String) -> String? {
        guard let root = try? JSONReader.read(text), root.isObject else { return nil }
        guard let properties = root.members?.last(where: { $0.key == "properties" })?.value else {
            return Self.inserting("\"properties\": {\"\(key)\": \(raw)}", into: root, in: text)
        }
        guard let members = properties.members else { return nil }
        if let member = members.last(where: { $0.key == key }) { return Self.replacing(member.value.range, in: text, with: raw) }
        return Self.inserting("\"\(key)\": \(raw)", into: properties, in: text)
    }

    /// `text` without its root `properties`' members of this key, each with its comma and the space
    /// before the next member's key; the text itself when there are none, nil when it isn't a JSON
    /// object.
    func removed(from text: String) -> String? {
        var text = text
        // One a pass, the last first: a schema holds one, and rarely two.
        while true {
            guard let root = try? JSONReader.read(text), root.isObject else { return nil }
            guard let properties = root["properties"], let members = properties.members,
                  let i = members.lastIndex(where: { $0.key == key }) else { return text }
            let member = members[i]
            if i + 1 < members.count {
                text = Self.replacing(member.keyRange.lowerBound..<members[i + 1].keyRange.lowerBound, in: text, with: "")
            } else if i > 0 {
                text = Self.replacing(members[i - 1].value.range.upperBound..<member.value.range.upperBound, in: text, with: "")
            } else {
                text = Self.replacing(properties.range.lowerBound + 1..<properties.range.upperBound - 1, in: text, with: "")
            }
        }
    }

    // MARK: Text

    /// `text` with `member` first in `object`, on the line its first member is on and indented as that
    /// is (after it with a space where that member has one after its colon, and none in a compact
    /// text), or, in an empty one, on a line of its own one step in from the object's line when the
    /// text has lines, else inside the braces.
    private static func inserting(_ member: String, into object: JSONNode, in text: String) -> String {
        let utf8 = Array(text.utf8)
        let inside = object.range.lowerBound + 1..<object.range.upperBound - 1
        guard let first = object.members?.first else {
            guard utf8.contains(UInt8(ascii: "\n")) else { return replacing(inside, in: text, with: member) }
            let outer = indentation(ofLineAt: object.range.lowerBound, in: utf8)
            return replacing(inside, in: text, with: "\n\(outer)\(step(in: utf8))\(member)\n\(outer)")
        }
        var space = String(decoding: utf8[inside.lowerBound..<first.keyRange.lowerBound], as: UTF8.self)
        if space.isEmpty, utf8[first.keyRange.upperBound..<first.value.range.lowerBound].contains(UInt8(ascii: " ")) { space = " " }
        return replacing(first.keyRange.lowerBound..<first.keyRange.lowerBound, in: text, with: "\(member),\(space)")
    }

    static func replacing(_ range: Range<Int>, in text: String, with new: String) -> String {
        let utf8 = Array(text.utf8)
        return String(decoding: utf8[..<range.lowerBound], as: UTF8.self) + new + String(decoding: utf8[range.upperBound...], as: UTF8.self)
    }

    private static func slice(_ range: Range<Int>, of text: String) -> String {
        String(decoding: Array(text.utf8)[range], as: UTF8.self)
    }

    /// The spaces and tabs a line starts with: the line `offset` is on.
    private static func indentation(ofLineAt offset: Int, in utf8: [UInt8]) -> String {
        var start = offset
        while start > 0, utf8[start - 1] != UInt8(ascii: "\n") { start -= 1 }
        var end = start
        while end < utf8.count, utf8[end] == UInt8(ascii: " ") || utf8[end] == UInt8(ascii: "\t") { end += 1 }
        return String(decoding: utf8[start..<end], as: UTF8.self)
    }

    /// One step of indentation, as the text's first indented line has it: two spaces in a text that
    /// has none.
    private static func step(in utf8: [UInt8]) -> String {
        var i = 0
        while i < utf8.count {
            if utf8[i] == UInt8(ascii: "\n") {
                var end = i + 1
                while end < utf8.count, utf8[end] == UInt8(ascii: " ") || utf8[end] == UInt8(ascii: "\t") { end += 1 }
                if end > i + 1 { return String(decoding: utf8[(i + 1)..<end], as: UTF8.self) }
            }
            i += 1
        }
        return "  "
    }
}

/// What the held directives share, being no field's: the model is never sent one, a schema written whole keeps those
/// of the one it replaces unless it says them, and a change to one alone says nothing of the type's fields (no revision
/// of the type moves, and its words aren't written again). Types' own two, then those the registry's plugins give, in
/// plugin order (`registry.heldDirectives`).
public struct HeldDirectives: Sendable {
    let all: [HeldDirective]

    /// Types' own: `$color` and `$autofill`.
    static let own = [TypeColorDirective.directive, TypeAutofillDirective.directive]

    /// Types' own and those named (without their `$`): what a registry holds is `registry.heldDirectives`.
    public init(adding names: [String] = []) {
        all = Self.own + names.map { HeldDirective(name: $0) }
    }

    /// Whether a root `properties` key is one of them.
    public func isHeld(_ key: String) -> Bool { all.contains { $0.key == key } }

    /// `text` without them, as the model is sent a schema.
    public func stripped(_ text: String) -> String { all.reduce(text) { $1.stripped($0) } }

    /// `written` with each that `held` has and `written` doesn't, as `held` writes it: a schema written whole
    /// (draw's `schema:`, the model's, words that are JSON) keeps the type's color, what its notes do and what
    /// other plugins keep there, unless it says them.
    public func carried(from held: String?, into written: String) -> String {
        all.reduce(written) { $1.carried(from: held, into: $0) }
    }

    /// Whether two schemas' texts are the same but for them: what a type given another color, or told
    /// whether its notes fill, or given other rules, changes, which says nothing of its fields.
    public func sameButHeld(_ a: String, _ b: String) -> Bool {
        a == b || all.contains { a.contains($0.key) || b.contains($0.key) } && stripped(a) == stripped(b)
    }

    /// Whether a schema's root holds none of them: what lets a text be sent as it is.
    func isAbsent(from root: JSONNode?) -> Bool { all.allSatisfy { held in root.flatMap { held.member(in: $0) } == nil } }
}

/// The directives other plugins hold in a type's schema (`registrar.typeDirective`): each a name, held as Types holds
/// `$color` and `$autofill` (`HeldDirectives`). A name once; none of Types' own, nor `title`.
public enum TypeDirectives {}

extension TypeDirectives: KeyedExtensionPoint {
    public typealias Contribution = String
    public static var owner: PluginID { .types }
    public static func uniqueKeys(of name: String, for _: ShapeTarget) -> [AnyHashable] { [name] }
    public static func summary(of name: String, for _: ShapeTarget) -> String { "type directive $\(name)" }

    /// A name is a word (letters and digits, a letter first), and none Types says itself.
    public static func check(_ registry: Registry) throws(RegistryError) {
        for name in registry.contributions(to: TypeDirectives.self).map(\.value) {
            guard let first = name.first, first.isLetter, name.allSatisfy({ $0.isLetter || $0.isNumber }) else {
                throw .invalid(point: "TypeDirectives", reason: "$\(name) isn't a word")
            }
            guard !["title", "color", "autofill"].contains(name) else { throw .invalid(point: "TypeDirectives", reason: "$\(name) is Types' own") }
        }
    }
}

extension PluginRegistrar {
    /// A member of every type's schema that is this plugin's, `"$name": {"const": …}` in the root's `properties`,
    /// held aside as `$color` is: the model that keeps a type's words and schema in step is never sent it, a schema
    /// written whole keeps it unless it says it, and a change to it alone is no change to the type's fields.
    ///
    ///     registrar.typeDirective("rules")
    public mutating func typeDirective(_ name: String) {
        contribute(name, to: TypeDirectives.self)
    }
}

extension Registry {
    /// Every directive held aside: Types' own, then those plugins give (`typeDirective`), in plugin order.
    public var heldDirectives: HeldDirectives {
        memo("Types.heldDirectives") { HeldDirectives(adding: contributions(to: TypeDirectives.self).map(\.value)) }
    }
}
