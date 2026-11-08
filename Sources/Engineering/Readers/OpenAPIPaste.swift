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
// component's note (`urn:uuid:` and its id, a fragment kept), and a type the file had is joined with what it holds, its
// properties by name. The API alone on the first row, its types below it, four to a row. A type finds only a note that is a type,
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
            rows.append([api(document)])
            guard let typeKind else { continue }
            let types = document.types.map { type($0, kind: typeKind) }
            rows += stride(from: 0, to: types.count, by: typesARow).map { Array(types[$0..<min($0 + typesARow, types.count)]) }
        }
        return DrawPut(rows: rows)
    }

    // MARK: Statements

    /// The API's statement: its title, server, version and rows, each endpoint by its full path.
    @MainActor
    static func api(_ document: OpenAPIDocument) -> DrawPut.Shape {
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
                    "body": endpoint.body.map { $0.words as Any } ?? NSNull(),
                    "responses": endpoint.responses.map { response -> [String: Any] in
                        var item: [String: Any] = ["status": response.status]
                        if let type = response.type { item["type"] = type.words }
                        return item
                    },
                    "deprecated": endpoint.deprecated,
                ] as [String: Any])
            }
        }
        var shape = DrawPut.Shape(kind: API.kind.rawValue, title: document.title)
        shape.json = [(key: "server", text: json(["host": document.server.host, "auth": document.server.auth])),
                      (key: "endpoints", text: json(items))]
        if !document.version.isEmpty { shape.values = [(key: "version", text: document.version)] }
        // Made wide enough for its paths to show whole; one the file has keeps the width it has.
        shape.width = APIDrawing.wholeWidth(of: document.rows)
        return shape
    }

    /// A type's statement: a note of `kind` by its name, the types it builds on, its schema once every note of the put is known.
    static func type(_ type: OpenAPIType, kind: ShapeKind) -> DrawPut.Shape {
        var shape = DrawPut.Shape(kind: kind.rawValue, title: type.name)
        if !type.isA.isEmpty { shape.json = [(key: IsAProperty.key.rawValue, text: json(type.isA))] }
        let schema = type.schema
        shape.late = [DrawPut.LateValue(key: TypeSchemaProperty.key.rawValue) { names in
            var written = pointed(schema) { names.shape(kind, called: $0) }
            if names.found, let held = names.editor.shape(inFile: names.shape)?[TypeSchemaProperty.self],
               let node = try? JSONReader.read(held.text) {
                written = joined(written, onto: SchemaValue(node))
            }
            return written.pretty
        }]
        shape.admits = { $0[TypeSchemaProperty.self] != nil }
        return shape
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

    /// A type's schema pasted again, joined onto the one it holds: what the paste says, its properties joined by name (each held
    /// one in its place, replaced where the paste says it, the paste's new ones after), `required` the paste's and the held
    /// one's for a property only it has, and what else only the held one says kept.
    public static func joined(_ written: SchemaValue, onto held: SchemaValue) -> SchemaValue {
        guard case .object(var members) = written, let heldMembers = held.members else { return written }
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
        if !properties.isEmpty {
            if let at = members.firstIndex(where: { $0.key == "properties" }) {
                members[at].value = .object(properties)
            } else {
                members.append(SchemaMember(key: "properties", value: .object(properties)))
            }
        }
        members.removeAll { $0.key == "required" }
        if !required.isEmpty {
            let at = (members.firstIndex { $0.key == "properties" }).map { $0 + 1 } ?? members.count
            members.insert(SchemaMember(key: "required", value: .array(required.map(SchemaValue.string))), at: at)
        }
        for member in heldMembers where !members.contains(where: { $0.key == member.key }) { members.append(member) }
        return .object(members)
    }

    /// A value as JSON text.
    private static func json(_ value: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }
}
