import Canvas
import CanvasRPC
import Draw
import Foundation
import SlashCommands
import Titles
import Types

// The ways to an API besides its tool: `/api [NAME]`, a new API named as it's put down (no name: the board's name and " API"),
// edited at its empty row; and `canvas draw`'s words, `server:` (its first line: `"api.shop.dev/v1 bearer"`) and `endpoints:`
// (lines in the endpoint grammar with whole paths, each put under the longest header it starts with, else at the top; a path
// alone a header; or JSON items, a header `{"header": "/orders"}`), joined onto what the API holds by method and full path, so a
// statement names only what it changes, the rows it leaves out stay, and a run again is `unchanged`. A body's or a response's type
// that names a type note of the file is bound to it, a pill, never an arrow (decided 24).

extension PluginRegistrar {
    /// `/api NAME`, which puts `api` down titled NAME (else the board's name and " API") beside the selection, or in view, edited at
    /// its empty row, in one step ("Add API").
    mutating func apiCommands(placing api: Placement) {
        selectionSlashCommand(.atOnce(APIWords.command, argument: APIWords.name, step: APIStyle.addStep, when: { _, editor in !editor.isBoardReadOnly },
                                            accepts: { _ in true }) { target, arguments, editor in
            let beside: [ShapeID] = if case .selection(let ids) = target { ids } else { [] }
            let name = TitleProperty.folded(arguments.text) ?? editor.accessibleBoardName.flatMap { TitleProperty.folded($0 + APIStyle.boardSuffix) }
            let named = name.map { api.setting(TitleProperty.self, to: $0) } ?? api
            editor.insert(named, named: APIStyle.addStep, beside: beside)
        })
    }

    /// The writers of an API's `server:` and `endpoints:`.
    mutating func apiDraw() {
        drawValueWriter(for: "server", describes: APIWords.serverText, write: { value, _ throws(DrawError) in
            try APIWords.server(written: value)
        }, merge: { written, _ in written })
        drawValueWriter(for: "endpoints", describes: APIWords.endpointLines, write: { value, context throws(DrawError) in
            try APIWords.endpoints(written: value, context)
        }, merge: { written, held in
            APIWords.mergedEndpoints(written, onto: held)
        })
    }
}

/// What `/api` and `canvas draw` say of an API.
enum APIWords {
    static let command = "api"
    static let name = "name"
    static let serverText = "a line (host[/path] [bearer | basic | apikey NAME | oauth2])"
    static let endpointLines = "lines (METHOD /whole/path/{param} [(Body)] [→ [status] [Response]]; a path alone a header)"
    static let reason = "invalid_value"
    static let ambiguousReason = "ambiguous_title"

    /// The server a script wrote: its line read, or its JSON as given.
    static func server(written value: JSONValue) throws(DrawError) -> JSONValue {
        guard case .string(let text) = value else { return value }
        return (try? JSONValue(encoding: ServerGrammar.read(text) ?? APIServer())) ?? value
    }

    /// The rows a script wrote, each as the object a row is coded as, its path whole: its lines read (an endpoint's members its line
    /// says, a body it doesn't give written null, so a restated endpoint loses it; a header `{"id", "header"}`), or its JSON items as
    /// given (an id given to each with none, a type given as words `{"words": …}`, a method in capitals), each type that names a type
    /// note bound to it. A name two type notes answer to is refused, as any ambiguous name is.
    @MainActor
    static func endpoints(written value: JSONValue, _ context: DrawTextContext) throws(DrawError) -> JSONValue {
        var items: [[String: JSONValue]]
        switch value {
        case .string(let text):
            items = EndpointGrammar.read(lines: text).map { row in
                var members = (try? JSONValue(encoding: row))?.objectValue ?? [:]
                guard row.endpoint != nil else { return members }
                // What only the card says stays the endpoint's: the line says none of it.
                for card in ["name", "summary", "authScope", "parameters", "deprecated"] { members[card] = nil }
                if members["body"] == nil { members["body"] = .null }
                if members["responses"]?.arrayValue?.isEmpty ?? true { members["responses"] = nil }
                return members
            }
        case .array(let given):
            items = try given.map { item throws(DrawError) in try normalized(item) }
        default: return value
        }
        for index in items.indices where items[index]["header"] == nil {
            if let body = items[index]["body"]?.objectValue { items[index]["body"] = .object(try bound(body, context)) }
            if let responses = items[index]["responses"]?.arrayValue {
                var bound: [JSONValue] = []
                for case .object(var response) in responses {
                    if let type = response["type"]?.objectValue { response["type"] = .object(try Self.bound(type, context)) }
                    bound.append(.object(response))
                }
                items[index]["responses"] = .array(bound)
            }
        }
        return .array(items.map(JSONValue.object))
    }

    /// A row written as JSON: an id given where it has none, a type written as words made a type's, a method in capitals. It must
    /// read as a row.
    private static func normalized(_ item: JSONValue) throws(DrawError) -> [String: JSONValue] {
        guard case .object(var members) = item else { throw DrawError("\(item.compactText) isn't a row it takes", reason: reason) }
        if members["id"] == nil { members["id"] = .string(UUID().uuidString) }
        if let method = members["method"]?.stringValue { members["method"] = .string(method.uppercased()) }
        if let body = members["body"]?.stringValue { members["body"] = .object(["words": .string(body)]) }
        if let responses = members["responses"]?.arrayValue {
            members["responses"] = .array(responses.map { response in
                guard case .object(var fields) = response else { return response }
                if let type = fields["type"]?.stringValue { fields["type"] = .object(["words": .string(type)]) }
                if let status = fields["status"], status.stringValue == nil, let number = status.numberValue { fields["status"] = .string(String(Int(number))) }
                return .object(fields)
            })
        }
        guard (try? JSONValue.object(members).decode(APIRow.self)) != nil else {
            throw DrawError("\(item.compactText) isn't a row it takes", reason: reason)
        }
        return members
    }

    /// A type as written, bound to the type note its words name, if one does.
    @MainActor
    private static func bound(_ type: [String: JSONValue], _ context: DrawTextContext) throws(DrawError) -> [String: JSONValue] {
        guard type["shape"] == nil, let words = type["words"]?.stringValue, !words.isEmpty else { return type }
        do throws(DrawError) {
            // A type is a note that holds a schema: one the same script draws is one, though the file's index hasn't heard of it yet.
            let found = try context.shape(called: words, admitting: { $0[TypeSchemaProperty.self] != nil ? nil : "which isn't a type" })
            var bound = type
            bound["shape"] = .string(found.id.description)
            return bound
        } catch {
            if error.reason == ambiguousReason { throw error }
            return type
        }
    }

    /// The rows `written` says (paths whole) joined onto `held` (paths under their headers): a header by its prefix, kept where it
    /// is; an endpoint by its method and full path, read over the one held (a member it leaves out stays; its responses replace the
    /// held ones in order, the rest kept), or put under the longest header its path starts with, at the end of that group, its path
    /// written relative to it, else at the top. A new row whose id another holds is given one of its own.
    static func mergedEndpoints(_ written: JSONValue, onto held: JSONValue?) -> JSONValue {
        guard case .array(let items) = written else { return written }
        var rows = held.flatMap { try? $0.decode([APIRow].self) } ?? []
        for case .object(let given) in items {
            if let prefix = given["header"]?.stringValue {
                guard !rows.contains(where: { $0.header?.prefix == prefix }) else { continue }
                var header = PathHeader(prefix: prefix)
                if let id = given["id"].flatMap({ try? $0.decode(PartID.self) }), !rows.contains(where: { $0.id == id }) { header.id = id }
                rows.append(.header(header))
                continue
            }
            let method = given["method"]?.stringValue ?? "", path = given["path"]?.stringValue ?? ""
            if let at = APIGroups.index(of: method, path, in: rows), let old = rows[at].endpoint {
                var members = (try? JSONValue(encoding: old).objectValue) ?? [:]
                for (key, member) in given where key != "id" && key != "path" && key != "responses" { members[key] = member == .null ? nil : member }
                guard var endpoint = try? JSONValue.object(members).decode(Endpoint.self) else { continue }
                if let responses = given["responses"].flatMap({ try? $0.decode([EndpointResponse].self) }) {
                    endpoint.responses = responses + old.responses.dropFirst(responses.count)
                }
                rows[at] = .endpoint(endpoint)
                continue
            }
            var members = given
            for (key, member) in given where member == .null { members[key] = nil }
            guard var endpoint = try? JSONValue.object(members).decode(Endpoint.self) else { continue }
            let (index, relative) = APIGroups.place(path, in: rows)
            endpoint.path = relative
            if rows.contains(where: { $0.id == endpoint.id }) { endpoint.id = PartID() }
            rows.insert(.endpoint(endpoint), at: index)
        }
        return (try? JSONValue(encoding: rows)) ?? written
    }
}
