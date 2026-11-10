import Foundation
import Types

// OpenAPI 3.0 and 3.1, JSON or YAML (the kit's subset, `YAMLReader`), read into an API and the types its bodies are: pure, from
// the ordered tree both read into (Types' `SchemaValue`), so endpoints and fields keep the file's order. A document is OpenAPI
// when its root says `openapi: 3.*` and has `paths`; Swagger 2.0 isn't read.
//
// - The API: titled `info.title`, else the file's name less its extensions; its version `info.version`; its server
//   `servers[0].url` with its variables' defaults, the scheme dropped (`https://api.shop.dev/v1/` is `api.shop.dev/v1`); its auth
//   the global `security`'s first scheme as the server line says it (`bearer`, `basic`, `apikey NAME`, `oauth2`).
// - Its endpoints, in the file's order: the method, the full path, `operationId` as its name, `summary`, `deprecated`, its scope
//   (the operation's `security`: its scopes, or another scheme's word; `[]` is `none`), its path and query parameters with their
//   types (`format` before `type`: `format: uuid` is `uuid`; an array's is its items' and `[]`), its body (`application/json`
//   first) and its responses by status, each with its type: a component's name, an array's items', or a type made for an inline
//   object, named for its operation (`CreateRefundRequest`, `CreateRefundResponse`, the status added when several are inline).
//   `$ref`s inside the document are followed (parameters, bodies, responses, path items). Grouped by the kit's one rule
//   (`APIGroups.byPrefix`).
// - Its types: each `components.schemas` entry, by its name, then the inline ones, in JSON Schema 2020-12: `nullable: true` is
//   `type: [t, "null"]` (and null among an `enum`'s values), `example` is `examples`, a boolean `exclusiveMinimum` (or maximum) a
//   number, a root `title`, `$id` and `$schema` dropped, `required` only what its object's `properties` name (Types warns of
//   any other), a `type` JSON Schema hasn't dropped, and a root `allOf` of `$ref`s and objects the types it builds on (`isA`) and
//   its own properties. A `$ref` to a component's schema stays `#/components/schemas/X[/…]` here, for the paste to point at X's
//   note (`urn:uuid:`); any other `$ref` (another file's, another part of the document) is `{}`.
// - Lost: discriminator, xml, externalDocs, `x-` extensions, header and cookie parameters, links, callbacks, webhooks, tags,
//   response headers.

/// An OpenAPI document as the kit puts it down: an API and its types.
public struct OpenAPIDocument: Sendable, Equatable {
    public var title: String
    public var version: String
    public var server: APIServer
    /// Its rows grouped by prefix (`APIGroups.byPrefix`), each endpoint's body and responses named by their types' names.
    public var rows: [APIRow]
    /// Its types: the components' schemas, then the inline ones, in order.
    public var types: [OpenAPIType]
}

/// A type an OpenAPI document gives: a name, its schema in JSON Schema 2020-12 (a component's `$ref` still the document's), and
/// the types it builds on (a root `allOf`'s `$ref`s), by name.
public struct OpenAPIType: Sendable, Equatable {
    public var name: String
    public var schema: SchemaValue
    public var isA: [String]
}

/// The OpenAPI reader.
public enum OpenAPIReader {
    /// What a `$ref` to a component's schema starts with.
    public static let componentPrefix = "#/components/schemas/"
    /// The methods an operation is under in a path item, as OpenAPI writes them.
    static let methods: Set<String> = ["get", "put", "post", "delete", "options", "head", "patch", "trace"]
    /// How far the sniff looks for `openapi`.
    static let sniffLength = 65_536

    /// Whether text may be OpenAPI, cheaply: `openapi` as a key in its first 64 KB.
    public static func sniffs(_ text: String) -> Bool {
        let head = text.utf8.count > sniffLength ? String(decoding: text.utf8.prefix(sniffLength), as: UTF8.self) : text
        return head.contains("\"openapi\"") || head.hasPrefix("openapi:") || head.contains("\nopenapi:")
    }

    /// The document text says, JSON or YAML; nil for text that isn't OpenAPI 3, or doesn't read. `fileName`: the file it came
    /// from, which names an API with no title.
    public static func read(_ text: String, fileName: String? = nil) -> OpenAPIDocument? {
        guard let root = tree(of: text) else { return nil }
        return read(root, fileName: fileName)
    }

    /// Text as an ordered tree: JSON when it starts with `{`, else YAML.
    static func tree(of text: String) -> SchemaValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") {
            return (try? JSONReader.read(trimmed)).map { SchemaValue($0) }
        }
        return (try? YAMLReader.read(text, textKeys: textKeys)) ?? nil
    }

    /// The keys whose plain scalar the document's words are read as written (`version: 1.0` is "1.0", `summary: 404` is "404").
    static let textKeys: Set<String> = ["version", "title", "summary", "operationId"]

    /// The document a tree says; nil for one that isn't OpenAPI 3 (a root `openapi: 3.*` with `paths`).
    public static func read(_ root: SchemaValue, fileName: String? = nil) -> OpenAPIDocument? {
        guard isOpenAPI3(root), let paths = root["paths"]?.members else { return nil }
        var reading = Reading(root: root)
        let info = root["info"]
        let title = info?["title"].map(Self.scalarText)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let named = (title?.isEmpty ?? true) ? fileName.flatMap(Self.name(ofFile:)) ?? "" : title!
        let version = info?["version"].map(Self.scalarText) ?? ""
        let server = APIServer(host: Self.host(of: root), auth: reading.globalAuth)
        // The components' schemas, by their names, before any inline type, which takes a name none of them has.
        for member in root["components"]?["schemas"]?.members ?? [] {
            reading.used.insert(member.key)
        }
        var componentTypes: [OpenAPIType] = []
        for member in root["components"]?["schemas"]?.members ?? [] {
            componentTypes.append(reading.type(named: member.key, member.value))
        }
        var endpoints: [Endpoint] = []
        for path in paths {
            let item = reading.resolved(path.value)
            let shared = item["parameters"]?.elements ?? []
            for operation in item.members ?? [] where methods.contains(operation.key.lowercased()) {
                endpoints.append(reading.endpoint(operation.key.uppercased(), path.key, reading.resolved(operation.value), shared: shared))
            }
        }
        return OpenAPIDocument(title: named, version: version, server: server, rows: APIGroups.byPrefix(endpoints),
                               types: componentTypes + reading.inline)
    }

    /// Whether a tree is OpenAPI 3: `openapi` a 3.x version (a number where YAML read `3.1` as one) and `paths` a mapping.
    static func isOpenAPI3(_ root: SchemaValue) -> Bool {
        guard root["paths"]?.members != nil, let version = root["openapi"] else { return false }
        if let text = version.string { return text.hasPrefix("3.") }
        if let number = version.number { return number >= 3 && number < 4 }
        return false
    }

    /// A file's name less its extensions: `billing.openapi.yaml` is `billing`.
    static func name(ofFile file: String) -> String? {
        let base = (file as NSString).lastPathComponent
        let name = base.split(separator: ".", maxSplits: 1).first.map(String.init) ?? base
        return name.isEmpty ? nil : name
    }

    /// The first server's URL, its variables' defaults put in, its scheme and a trailing slash dropped.
    static func host(of root: SchemaValue) -> String {
        guard let server = root["servers"]?.elements?.first, var url = server["url"]?.string else { return "" }
        for variable in server["variables"]?.members ?? [] {
            guard let value = variable.value["default"].map(scalarText) else { continue }
            url = url.replacingOccurrences(of: "{\(variable.key)}", with: value)
        }
        if let scheme = url.range(of: "://") { url = String(url[scheme.upperBound...]) }
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    /// A scalar as text: a string as it is, a whole number without its point.
    static func scalarText(_ value: SchemaValue) -> String {
        switch value {
        case .string(let text): text
        case .number(let number): number == number.rounded() && abs(number) < 1e15 ? String(Int64(number)) : "\(number)"
        case .bool(let bool): bool ? "true" : "false"
        default: ""
        }
    }

    /// The component a `$ref` names, and what follows its name (a pointer into it, "" for the whole); nil for any other `$ref`.
    public static func component(of ref: String) -> (name: String, fragment: String)? {
        guard ref.hasPrefix(componentPrefix) else { return nil }
        let rest = ref.dropFirst(componentPrefix.count)
        let name = rest.prefix { $0 != "/" }
        guard !name.isEmpty else { return nil }
        return (unescaped(String(name)), String(rest.dropFirst(name.count)))
    }

    /// A JSON pointer's token as it reads: `~1` a slash, `~0` a tilde, and percent-escapes undone.
    static func unescaped(_ token: String) -> String {
        let decoded = token.removingPercentEncoding ?? token
        return decoded.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
    }
}

/// A document being read: its root, the types made for inline objects so far, and the names taken.
private struct Reading {
    let root: SchemaValue
    var inline: [OpenAPIType] = []
    var used: Set<String> = []
    /// What the global security's scheme says on the server line.
    var globalAuth: String = ""

    init(root: SchemaValue) {
        self.root = root
        if let requirement = root["security"]?.elements?.first?.members?.first {
            globalAuth = word(ofScheme: requirement.key)
        }
    }

    /// What a security scheme is called on the server line: `bearer`, `basic`, `apikey NAME`, `oauth2`; another HTTP scheme its
    /// name, another type its own word, and a scheme the document doesn't define its key.
    func word(ofScheme key: String) -> String {
        guard let scheme = root["components"]?["securitySchemes"]?[key].map({ resolved($0) }) else { return key }
        switch scheme["type"]?.string?.lowercased() {
        case "http": return scheme["scheme"]?.string?.lowercased() ?? "http"
        case "apikey": return ["apikey", scheme["name"]?.string ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        case "oauth2": return "oauth2"
        case let other?: return other
        case nil: return key
        }
    }

    // MARK: $refs

    /// A value with its `$ref` followed, inside the document (a parameter's, a body's, a response's, a path item's), as far as
    /// eight hops; a `$ref` that leads nowhere, or out of the document, is `{}`.
    func resolved(_ value: SchemaValue) -> SchemaValue {
        var value = value
        for _ in 0..<8 {
            guard let ref = value["$ref"]?.string else { return value }
            guard let found = pointed(ref) else { return .object([]) }
            value = found
        }
        return .object([])
    }

    /// What a `#/…` pointer points to in the document.
    func pointed(_ ref: String) -> SchemaValue? {
        guard ref.hasPrefix("#/") else { return nil }
        var value = root
        for token in ref.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false) {
            let key = OpenAPIReader.unescaped(String(token))
            if let elements = value.elements, let index = Int(key), elements.indices.contains(index) {
                value = elements[index]
            } else if let found = value[key] {
                value = found
            } else {
                return nil
            }
        }
        return value
    }

    // MARK: Endpoints

    mutating func endpoint(_ method: String, _ path: String, _ operation: SchemaValue, shared: [SchemaValue]) -> Endpoint {
        let id = operation["operationId"].map(OpenAPIReader.scalarText) ?? ""
        var endpoint = Endpoint(method: method, path: path, name: id, summary: operation["summary"].map(OpenAPIReader.scalarText) ?? "",
                                deprecated: operation["deprecated"]?.bool ?? false)
        endpoint.authScope = scope(of: operation)
        endpoint.parameters = parameters(of: operation, shared: shared, path: path)
        let stem = Self.stem(operationId: id, method: method, path: path)
        if let body = operation["requestBody"].map({ resolved($0) }), let schema = Self.schema(inContent: body["content"]) {
            endpoint.body = typeWords(schema, inline: stem + "Request").map { TypeRef($0) }
        }
        let responses = operation["responses"]?.members ?? []
        let bodies = responses.map { (status: $0.key, schema: Self.schema(inContent: resolved($0.value)["content"])) }
        let inlineCount = bodies.filter { $0.schema.map { isInline($0) } ?? false }.count
        for response in bodies {
            var type: TypeRef?
            if let schema = response.schema {
                let name = stem + "Response" + (inlineCount > 1 ? response.status.prefix(1).uppercased() + response.status.dropFirst() : "")
                type = typeWords(schema, inline: name).map { TypeRef($0) }
            }
            endpoint.responses.append(EndpointResponse(status: response.status, type: type))
        }
        return endpoint
    }

    /// What an operation's `security` asks: nothing said, none (`""`); `[]`, `none`; else its first requirement's scopes, or the
    /// word of its scheme where that isn't the API's.
    func scope(of operation: SchemaValue) -> String {
        guard let requirements = operation["security"]?.elements else { return "" }
        guard let requirement = requirements.first?.members, !requirement.isEmpty else { return "none" }
        let scopes = requirement.flatMap { $0.value.elements?.compactMap(\.string) ?? [] }
        if !scopes.isEmpty { return scopes.joined(separator: " ") }
        let word = word(ofScheme: requirement[0].key)
        return word == globalAuth ? "" : word
    }

    /// An operation's path and query parameters with their types: the path item's, overridden by the operation's of the same name
    /// and place; the path's in the path's order, then the query's in the order written.
    func parameters(of operation: SchemaValue, shared: [SchemaValue], path: String) -> [PathParameter] {
        var found: [(name: String, place: String, type: String)] = []
        for parameter in (shared + (operation["parameters"]?.elements ?? [])).map({ resolved($0) }) {
            guard let name = parameter["name"]?.string, let place = parameter["in"]?.string, place == "path" || place == "query" else { continue }
            let schema = parameter["schema"] ?? Self.schema(inContent: parameter["content"])
            let type = schema.map { typeName(of: $0) } ?? ""
            found.removeAll { $0.name == name && $0.place == place }
            found.append((name, place, type))
        }
        let order = EndpointGrammar.parameterNames(in: path)
        let inPath = found.filter { $0.place == "path" }.sorted { (order.firstIndex(of: $0.name) ?? .max) < (order.firstIndex(of: $1.name) ?? .max) }
        // A query parameter a path parameter has the name of is dropped: a parameter is kept by its name alone, and the card's
        // field for the path's would otherwise change both.
        let named = Set(inPath.map(\.name))
        return (inPath + found.filter { $0.place == "query" && !named.contains($0.name) }).map { PathParameter(name: $0.name, type: $0.type) }
    }

    /// A parameter's type in a word: a component's name, its `format`, else its `type`; an array's its items' and `[]`.
    func typeName(of schema: SchemaValue, hops: Int = 0) -> String {
        if let ref = schema["$ref"]?.string {
            if let component = OpenAPIReader.component(of: ref), component.fragment.isEmpty { return component.name }
            // A pointer into the document is followed as far as eight hops, as `resolved` is: pointers may lead back to themselves.
            guard hops < 8 else { return "" }
            return pointed(ref).map { typeName(of: $0, hops: hops + 1) } ?? ""
        }
        if let format = schema["format"]?.string, !format.isEmpty { return format }
        let type = schema["type"]?.string ?? schema["type"]?.elements?.compactMap(\.string).first { $0 != "null" } ?? ""
        if type == "array", let items = schema["items"] { return typeName(of: items, hops: hops + 1) + "[]" }
        return type
    }

    /// A body's schema: its `application/json` content's, else the first JSON media type's, else the first's.
    static func schema(inContent content: SchemaValue?) -> SchemaValue? {
        guard let media = content?.members, !media.isEmpty else { return nil }
        let pick = media.first { $0.key.lowercased() == "application/json" }
            ?? media.first { $0.key.lowercased().contains("json") } ?? media[0]
        return pick.value["schema"]
    }

    /// Whether a body's schema is an object of its own, which becomes a type named for its operation (an array of one too).
    func isInline(_ schema: SchemaValue) -> Bool {
        if schema["$ref"] != nil { return false }
        if schema["type"]?.string == "array", let items = schema["items"] { return isInline(items) }
        return Self.isObject(schema)
    }

    /// Whether a schema describes an object: `type: object`, or properties, or a composition.
    static func isObject(_ schema: SchemaValue) -> Bool {
        guard schema.isObject else { return false }
        if let type = schema["type"]?.string { return type == "object" }
        if let types = schema["type"]?.elements?.compactMap(\.string) { return types.contains("object") }
        return ["properties", "allOf", "anyOf", "oneOf", "additionalProperties"].contains { schema[$0] != nil }
    }

    /// The type a body's schema names: a component's name, an array's items', or a new type for an inline object (named `inline`,
    /// made unique); nil for a scalar or a part of a component.
    mutating func typeWords(_ schema: SchemaValue, inline name: String) -> String? {
        if let ref = schema["$ref"]?.string {
            guard let component = OpenAPIReader.component(of: ref), component.fragment.isEmpty else { return nil }
            return component.name
        }
        if schema["type"]?.string == "array", let items = schema["items"] { return typeWords(items, inline: name) }
        guard Self.isObject(schema) else { return nil }
        var unique = name, count = 1
        while used.contains(unique) {
            count += 1
            unique = name + String(count)
        }
        used.insert(unique)
        inline.append(type(named: unique, schema))
        return unique
    }

    /// The words an operation's inline types are named by: its `operationId` with a capital (`CreateRefund`), else its method and
    /// its path's words (`PostWebhooksStripe`).
    static func stem(operationId: String, method: String, path: String) -> String {
        func capitalized(_ word: Substring) -> String { word.prefix(1).uppercased() + word.dropFirst() }
        let id = operationId.filter { $0.isLetter || $0.isNumber || $0 == "_" }
        if !id.isEmpty { return capitalized(Substring(id)) }
        let words = ([method.lowercased()] + path.split { !$0.isLetter && !$0.isNumber }.map(String.init)).map { capitalized(Substring($0)) }
        return words.joined()
    }

    // MARK: Types

    /// A component's or an inline object's type: its schema converted, a root `allOf` folded into what it builds on and its own
    /// properties.
    func type(named name: String, _ schema: SchemaValue) -> OpenAPIType {
        var converted = SchemaConversion.convert(schema, isRoot: true)
        var isA: [String] = []
        if case .object(var members) = converted, let parts = converted["allOf"]?.elements {
            members.removeAll { $0.key == "allOf" }
            var kept: [SchemaValue] = []
            var properties: [SchemaMember] = converted["properties"]?.members ?? []
            var required: [String] = converted["required"]?.elements?.compactMap(\.string) ?? []
            var others: [SchemaMember] = []
            for part in parts {
                if let ref = part["$ref"]?.string, let component = OpenAPIReader.component(of: ref), component.fragment.isEmpty,
                   part.members?.count == 1 {
                    if !isA.contains(component.name) { isA.append(component.name) }
                } else if let own = part.members, part["$ref"] == nil {
                    for property in part["properties"]?.members ?? [] {
                        if let at = properties.firstIndex(where: { $0.key == property.key }) { properties[at] = property } else { properties.append(property) }
                    }
                    required += part["required"]?.elements?.compactMap(\.string) ?? []
                    others += own.filter { !["properties", "required"].contains($0.key) }
                } else {
                    kept.append(part)
                }
            }
            for other in others where !members.contains(where: { $0.key == other.key }) { members.append(other) }
            if !kept.isEmpty { members.append(SchemaMember(key: "allOf", value: .array(kept))) }
            if !members.contains(where: { $0.key == "type" }), !isA.isEmpty || !properties.isEmpty {
                members.insert(SchemaMember(key: "type", value: .string("object")), at: 0)
            }
            if !properties.isEmpty {
                members.removeAll { $0.key == "properties" || $0.key == "required" }
                members.append(SchemaMember(key: "properties", value: .object(properties)))
                let names = Set(properties.map(\.key))
                var seen: Set<String> = []
                let kept = required.filter { names.contains($0) && seen.insert($0).inserted }
                if !kept.isEmpty { members.append(SchemaMember(key: "required", value: .array(kept.map(SchemaValue.string)))) }
            }
            // A 3.0 `nullable` on a root that was folded: its type, now written, allows null.
            if schema["nullable"]?.bool == true, let at = members.firstIndex(where: { $0.key == "type" }), let type = members[at].value.string {
                members[at].value = .array([.string(type), .string("null")])
            }
            converted = .object(members)
        }
        return OpenAPIType(name: name, schema: rerouted(converted), isA: isA)
    }

    /// `value` with each `$ref` into a component's `allOf` part pointing where that part's members are now: the folded type has
    /// no `allOf` of its own parts, so a part that is a `$ref` is its target, and a part's properties are the component's own;
    /// any other pointer into one leads nowhere (`{}`).
    func rerouted(_ value: SchemaValue) -> SchemaValue {
        switch value {
        case .object(let members):
            guard let ref = value["$ref"]?.string, let component = OpenAPIReader.component(of: ref), component.fragment.hasPrefix("/allOf/") else {
                return .object(members.map { SchemaMember(key: $0.key, value: rerouted($0.value)) })
            }
            let after = component.fragment.dropFirst("/allOf/".count)
            let index = after.prefix { $0 != "/" }
            let rest = String(after.dropFirst(index.count))
            let whole = String(ref.dropLast(component.fragment.count))
            let part = Int(index).flatMap { root["components"]?["schemas"]?[component.name]?["allOf"]?.elements?[safe: $0] }
            if let target = part?["$ref"]?.string, target.hasPrefix(OpenAPIReader.componentPrefix) {
                return .object([SchemaMember(key: "$ref", value: .string(target + rest))])
            }
            if part != nil, rest.hasPrefix("/properties/") {
                return .object([SchemaMember(key: "$ref", value: .string(whole + rest))])
            }
            return .object([])
        case .array(let elements):
            return .array(elements.map { rerouted($0) })
        default:
            return value
        }
    }
}

/// OpenAPI's schemas (3.0's dialect, and 3.1's, which is 2020-12 already) as JSON Schema 2020-12.
enum SchemaConversion {
    /// Keywords OpenAPI adds that JSON Schema has no word for, dropped.
    static let dropped: Set<String> = ["discriminator", "xml", "externalDocs", "nullable", "$schema", "$id"]
    /// Keywords whose value is a schema.
    static let single: Set<String> = ["items", "additionalProperties", "not", "if", "then", "else", "contains", "propertyNames",
                                      "unevaluatedProperties", "unevaluatedItems", "additionalItems"]
    /// Keywords whose value is a list of schemas.
    static let lists: Set<String> = ["allOf", "anyOf", "oneOf", "prefixItems"]
    /// Keywords whose value is an object of schemas by name.
    static let named: Set<String> = ["properties", "patternProperties", "dependentSchemas", "$defs", "definitions"]
    /// JSON Schema's types.
    static let types: Set<String> = ["null", "boolean", "object", "array", "number", "string", "integer"]

    /// A schema converted, `isRoot` for a type's own (whose `title` its note's title is).
    static func convert(_ schema: SchemaValue, isRoot: Bool = false, depth: Int = 0) -> SchemaValue {
        guard case .object(let members) = schema, depth < 64 else { return schema }
        if let ref = schema["$ref"]?.string, OpenAPIReader.component(of: ref) == nil {
            // A `$ref` out of the document, or to a part of it that isn't a component's schema: nothing said.
            return .object([])
        }
        let nullable = schema["nullable"]?.bool == true
        var out: [SchemaMember] = []
        for member in members {
            let key = member.key, value = member.value
            if dropped.contains(key) || key.hasPrefix("x-") { continue }
            if isRoot, key == "title" { continue }
            switch key {
            case "example":
                if schema["examples"] == nil { out.append(SchemaMember(key: "examples", value: .array([value]))) }
            case "exclusiveMinimum", "exclusiveMaximum":
                if let bool = value.bool {
                    // 3.0's flag on `minimum` (or maximum): the bound itself, exclusive.
                    let bound = schema[key == "exclusiveMinimum" ? "minimum" : "maximum"]
                    if bool, let bound { out.append(SchemaMember(key: key, value: bound)) }
                } else {
                    out.append(member)
                }
            case "minimum", "maximum":
                if schema[key == "minimum" ? "exclusiveMinimum" : "exclusiveMaximum"]?.bool == true { continue }
                out.append(member)
            case "type":
                var names = value.string.map { [$0] } ?? value.elements?.compactMap(\.string) ?? []
                names = names.filter { types.contains($0) }
                if nullable, !names.isEmpty, !names.contains("null") { names.append("null") }
                if names.isEmpty { continue }
                out.append(SchemaMember(key: key, value: names.count == 1 ? .string(names[0]) : .array(names.map(SchemaValue.string))))
            case "enum":
                if nullable, var values = value.elements, !values.contains(.null) {
                    values.append(.null)
                    out.append(SchemaMember(key: key, value: .array(values)))
                } else {
                    out.append(member)
                }
            case "required":
                out.append(member)
            case _ where single.contains(key):
                out.append(SchemaMember(key: key, value: value.elements.map { .array($0.map { convert($0, depth: depth + 1) }) } ?? convert(value, depth: depth + 1)))
            case _ where lists.contains(key):
                out.append(SchemaMember(key: key, value: .array((value.elements ?? []).map { convert($0, depth: depth + 1) })))
            case _ where named.contains(key):
                out.append(SchemaMember(key: key, value: .object((value.members ?? []).map { SchemaMember(key: $0.key, value: convert($0.value, depth: depth + 1)) })))
            default:
                out.append(member)
            }
        }
        // `nullable` beside no `type` (a `$ref` or a composition) can't add null to one: the schema or null. A root that is folded
        // into what it builds on has its type written then.
        let wraps = nullable && !out.isEmpty && !out.contains { $0.key == "type" || $0.key == "enum" } && !(isRoot && schema["allOf"] != nil)
        // `required` names only what its object's properties do: anything else is a property Types would warn has none.
        if let at = out.firstIndex(where: { $0.key == "required" }) {
            var names = out[at].value.elements?.compactMap(\.string) ?? []
            if schema["patternProperties"] == nil, let properties = schema["properties"]?.members {
                let named = Set(properties.map(\.key))
                names = names.filter { named.contains($0) && (!isRoot || SchemaDirectives.isField($0)) }
            }
            var seen: Set<String> = []
            names = names.filter { seen.insert($0).inserted }
            if names.isEmpty { out.remove(at: at) } else { out[at].value = .array(names.map(SchemaValue.string)) }
        }
        if wraps {
            return .object([SchemaMember(key: "anyOf", value: .array([.object(out), .object([SchemaMember(key: "type", value: .string("null"))])]))])
        }
        return .object(out)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
