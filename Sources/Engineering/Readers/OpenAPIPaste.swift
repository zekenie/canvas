import Canvas
import Clipboard
import Draw
import Foundation
import Types

// ⌘V of OpenAPI: what the reader read (`OpenAPIReader`), as the draw program Draw puts down (`DrawPut`, decided 16). The API an
// `api` statement by its title, its server and version, its rows as JSON with every member the file says (a header, or an
// endpoint with its full path, name, summary, scope, parameters, body, responses and deprecated); then its types, each a type
// note's statement (of the kind New Type makes, `newTypeKind`, never a literal) by its name, `is:` the types it builds on, and its
// schema written once the put has found or made every note (`DrawPut.LateValue`): a `$ref` to a component's schema points at that
// component's note (`urn:uuid:` and its id, a fragment kept), each property titled as the file keys it (`titled`: a field reads
// `payment_id`, as written), and a type the file had is joined with what it holds, its
// properties by name. The API alone on the first row, its types below it, four to a row, each after the type that refers to it
// most (`laidOut`). A type finds only a note that is a type,
// so a plain note of the same name is left alone and a type made beside it.
// So the put finds the API by its title, nearest first and file-wide, and the endpoints' writer joins its rows by method and full
// path (`APIWords.mergedEndpoints`: ids kept; a new one under the longest header it starts with; one the paste leaves out kept); a
// body's and a response's words bind to the type notes of the put. One step, "Paste OpenAPI", what lands selected.

/// The OpenAPI paste reader.
public enum OpenAPIPaste {
    /// Its name, and so its step's: "Paste OpenAPI".
    static let name = "OpenAPI"
    /// How many types a row of what lands holds.
    static let typesARow = 4
    /// The files it reads.
    static let fileExtensions: Set<String> = ["yaml", "yml", "json"]

    /// Whether the pasteboard may hold OpenAPI, cheaply: a `.yaml`, `.yml` or `.json` file that says `openapi`, or text that does.
    static func sniffs(_ content: PasteContent) -> Bool {
        let files = content.files.filter { fileExtensions.contains($0.fileExtension) }
        if !files.isEmpty { return files.contains { $0.text.map(OpenAPIReader.sniffs) ?? false } }
        return content.text.map(OpenAPIReader.sniffs) ?? false
    }

    /// What ⌘V puts down of the pasteboard's OpenAPI (its files', each an API, else its text's), its types notes of `typeKind`
    /// (none without one); nil when nothing reads.
    @MainActor
    static func read(_ content: PasteContent, typeKind: ShapeKind?) -> DrawPut? {
        let files = content.files.filter { fileExtensions.contains($0.fileExtension) }
        let documents: [OpenAPIDocument]
        if !files.isEmpty {
            documents = files.compactMap { file in file.text.flatMap { OpenAPIReader.read($0, fileName: file.name) } }
        } else {
            documents = content.text.flatMap { OpenAPIReader.read($0) }.map { [$0] } ?? []
        }
        return documents.isEmpty ? nil : program(documents, typeKind: typeKind)
    }

    /// What a paste of `text` (from a file named `fileName`) puts down, its types notes of `typeKind`; nil when it isn't OpenAPI 3.
    @MainActor
    public static func program(of text: String, named fileName: String? = nil, typeKind: ShapeKind?) -> DrawPut? {
        OpenAPIReader.read(text, fileName: fileName).map { program([$0], typeKind: typeKind) }
    }

    /// The program that puts `documents` down: each API alone on a row, its types below it, four to a row.
    @MainActor
    static func program(_ documents: [OpenAPIDocument], typeKind: ShapeKind?) -> DrawPut {
        var rows: [[DrawPut.Shape]] = []
        for document in documents {
            rows.append([api(document, typeKind: typeKind)])
            guard let typeKind else { continue }
            let types = laidOut(document.types).map { type(document.types[$0], kind: typeKind) }
            rows += stride(from: 0, to: types.count, by: typesARow).map { Array(types[$0..<min($0 + typesARow, types.count)]) }
        }
        var put = DrawPut(rows: rows)
        // What it puts down of that kind is types, not notes: so VoiceOver hears it.
        if let typeKind { put.labels[typeKind.rawValue] = APIStyle.pastedTypeLabel }
        return put
    }

    /// The order a document's types are put down in, by what refers to what (`ReaderLayout.walk`): from the type most `$ref`s and
    /// `allOf`s name, each after the type that refers to it most, so a type lands beside what it's built of (Refund beside Money
    /// and Base). Indexes into `types`.
    static func laidOut(_ types: [OpenAPIType]) -> [Int] {
        let index = Dictionary(types.enumerated().map { ($0.element.name, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var links: [(from: Int, to: Int)] = []
        for (from, type) in types.enumerated() {
            for name in type.isA { if let to = index[name] { links.append((from, to)) } }
            func refs(_ schema: SchemaValue) {
                switch schema {
                case .object(let members):
                    if let ref = schema["$ref"]?.string, let component = OpenAPIReader.component(of: ref), let to = index[component.name] {
                        links.append((from, to))
                    }
                    for member in members { refs(member.value) }
                case .array(let elements):
                    elements.forEach(refs)
                default:
                    break
                }
            }
            refs(type.schema)
        }
        return ReaderLayout.walk(Array(types.indices), links: links)
    }

    // MARK: Statements

    /// The API's statement: its title, server, version and rows, each endpoint by its full path.
    @MainActor
    static func api(_ document: OpenAPIDocument, typeKind: ShapeKind? = nil) -> DrawPut.Shape {
        var shape = DrawPut.Shape(kind: API.kind.rawValue, title: document.title.isEmpty ? APIStyle.pastedTitle : document.title)
        shape.json = [(key: "server", text: json(["host": document.server.host, "auth": document.server.auth])),
                      (key: "endpoints", text: json(items(of: document, bind: { _ in nil })))]
        if !document.version.isEmpty { shape.values = [(key: "version", text: document.version)] }
        // Each body's and response's type bound to the type note of the put by its id, once every note is known: by its title it
        // could be another shape's (an API titled as one of its types).
        if let typeKind {
            shape.late = [DrawPut.LateValue(key: "endpoints", isJSON: true) { names in
                json(items(of: document, bind: { words in names.shape(typeKind, called: words)?.description }))
            }]
        }
        // Made wide enough for its paths to show whole; one the file has keeps the width it has.
        shape.size = DrawPut.Dimensions(width: APIDrawing.wholeWidth(of: document.rows))
        return shape
    }

    /// The API's rows as the items its `endpoints` writer takes (every member the file says, an endpoint's path whole), each type's
    /// words as `bind` gives its shape's id, if it does.
    @MainActor
    private static func items(of document: OpenAPIDocument, bind: (String) -> String?) -> [Any] {
        func typed(_ type: TypeRef) -> Any {
            guard let id = bind(type.words) else { return type.words }
            return ["words": type.words, "shape": id]
        }
        var items: [Any] = []
        for (index, row) in document.rows.enumerated() {
            switch row {
            case .header(let header):
                items.append(["header": header.prefix])
            case .endpoint(let endpoint):
                items.append([
                    "method": endpoint.method,
                    "path": APIGroups.fullPath(of: index, in: document.rows),
                    "name": endpoint.name,
                    "summary": endpoint.summary,
                    "authScope": endpoint.authScope,
                    "parameters": endpoint.parameters.map { ["name": $0.name, "type": $0.type] },
                    // No body said: none, so an endpoint pasted again without one has none.
                    "body": endpoint.body.map { typed($0) } ?? NSNull(),
                    "responses": endpoint.responses.map { response -> [String: Any] in
                        var item: [String: Any] = ["status": response.status]
                        if let words = response.type { item["type"] = typed(words) }
                        return item
                    },
                    // The file says every response the endpoint has: one pasted again without one drops it.
                    APIWords.wholeResponses: true,
                    "deprecated": endpoint.deprecated,
                ] as [String: Any])
            }
        }
        return items
    }

    /// A type's statement: a note of `kind` by its name, the types it builds on, its schema once every note of the put is known.
    @MainActor
    static func type(_ type: OpenAPIType, kind: ShapeKind) -> DrawPut.Shape {
        var shape = DrawPut.Shape(kind: kind.rawValue, title: type.name)
        if !type.isA.isEmpty {
            shape.json = [(key: IsAProperty.key.rawValue, text: json(type.isA))]
            // The types it builds on by their ids, which no other shape of the put's title can be.
            shape.late = [DrawPut.LateValue(key: IsAProperty.key.rawValue, isJSON: true) { names in
                json(type.isA.map { names.shape(kind, called: $0)?.description ?? $0 })
            }]
        }
        let schema = titled(type.schema)
        // As tall as its rows, as wide as a note holding a type is drawn; one the file has keeps its own size.
        let rows = max(1, schema["properties"]?.members?.count ?? 0)
        shape.size = DrawPut.Dimensions(width: APIStyle.pastedTypeWidth, height: CGFloat(rows) * APIStyle.pastedTypeRowHeight + 2 * APIStyle.pastedTypePad)
        shape.late.append(DrawPut.LateValue(key: TypeSchemaProperty.key.rawValue) { names in
            var written = pointed(schema) { names.shape(kind, called: $0) }
            if names.found, let held = names.editor.shape(inFile: names.shape)?[TypeSchemaProperty.self],
               let node = try? JSONReader.read(held.text) {
                written = joined(written, onto: SchemaValue(node))
            }
            return written.pretty
        })
        shape.admits = { $0[TypeSchemaProperty.self] != nil }
        return shape
    }

    /// `schema` with each property, at any depth, titled as the file keys it where it has no title of its own: Types shows a field by
    /// its title, so a body's field reads `payment_id`, as the wire and the table beside it say it (E1 panel 4's `total_cents`),
    /// never its words (`payment id`). A property that is `true` or `false` is left as it is.
    public static func titled(_ schema: SchemaValue) -> SchemaValue {
        switch schema {
        case .object(let members):
            return .object(members.map { member in
                guard member.key == "properties", case .object(let properties) = member.value else {
                    return SchemaMember(key: member.key, value: titled(member.value))
                }
                return SchemaMember(key: member.key, value: .object(properties.map { property in
                    var value = titled(property.value)
                    if SchemaDirectives.isField(property.key), case .object(var fields) = value, !fields.contains(where: { $0.key == "title" }) {
                        fields.insert(SchemaMember(key: "title", value: .string(property.key)), at: 0)
                        value = .object(fields)
                    }
                    return SchemaMember(key: property.key, value: value)
                }))
            })
        case .array(let elements):
            return .array(elements.map(titled))
        default:
            return schema
        }
    }

    /// `schema` with each `$ref` to a component's schema pointing at that component's note (`urn:uuid:` and its id, a fragment
    /// kept); a schema whose `$ref` names a component no note stands for is `{}`.
    public static func pointed(_ schema: SchemaValue, _ note: (String) -> ShapeID?) -> SchemaValue {
        switch schema {
        case .object(let members):
            if let ref = schema["$ref"]?.string, let component = OpenAPIReader.component(of: ref) {
                guard let id = note(component.name) else { return .object([]) }
                let uri = SchemaReferences.uri(of: id) + (component.fragment.isEmpty ? "" : "#" + component.fragment)
                return .object(members.map { $0.key == "$ref" ? SchemaMember(key: "$ref", value: .string(uri)) : SchemaMember(key: $0.key, value: pointed($0.value, note)) })
            }
            return .object(members.map { SchemaMember(key: $0.key, value: pointed($0.value, note)) })
        case .array(let elements):
            return .array(elements.map { pointed($0, note) })
        default:
            return schema
        }
    }

    /// A type's schema pasted again, joined onto the one it holds, in the order it holds: what the paste says over what it holds,
    /// its properties joined by name (each held one in its place, replaced where the paste says it, the paste's new ones after),
    /// `required` the paste's and the held one's for a property only it has, and what else only the held one says kept where it
    /// is. A paste of what the note already says changes nothing, not even the order, so it is no step.
    public static func joined(_ written: SchemaValue, onto held: SchemaValue) -> SchemaValue {
        guard let heldMembers = held.members, case .object(let writtenMembers) = written else { return written }
        let heldProperties = held["properties"]?.members ?? [], writtenProperties = written["properties"]?.members ?? []
        var properties = heldProperties
        for property in writtenProperties {
            if let at = properties.firstIndex(where: { $0.key == property.key }) { properties[at] = property } else { properties.append(property) }
        }
        let onlyHeld = Set(heldProperties.map(\.key)).subtracting(writtenProperties.map(\.key))
        var required = written["required"]?.elements?.compactMap(\.string) ?? []
        for name in held["required"]?.elements?.compactMap(\.string) ?? [] where onlyHeld.contains(name) && !required.contains(name) {
            required.append(name)
        }
        func member(_ key: String, _ value: SchemaValue?) -> SchemaMember? {
            switch key {
            case "properties": properties.isEmpty ? nil : SchemaMember(key: key, value: .object(properties))
            case "required": required.isEmpty ? nil : SchemaMember(key: key, value: .array(required.map(SchemaValue.string)))
            default: value.map { SchemaMember(key: key, value: $0) }
            }
        }
        var members: [SchemaMember] = []
        // What it holds, each member where it is, the paste's value in it; then what only the paste says, in its order.
        for kept in heldMembers {
            if let joined = member(kept.key, written[kept.key] ?? kept.value) { members.append(joined) }
        }
        for written in writtenMembers where !members.contains(where: { $0.key == written.key }) {
            if let joined = member(written.key, written.value) { members.append(joined) }
        }
        // `properties` and `required` the paste adds to a note that had neither of them.
        for key in ["properties", "required"] where !members.contains(where: { $0.key == key }) {
            if let joined = member(key, nil) { members.append(joined) }
        }
        return .object(members)
    }

    /// A value as JSON text.
    private static func json(_ value: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }
}
