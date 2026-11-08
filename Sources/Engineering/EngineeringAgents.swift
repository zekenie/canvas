import Canvas
import CanvasRPC
import Queries

// What agents read of the kit's shapes, through Queries' points: `:route("POST /orders/{id}/refunds")`, the APIs that serve a
// route; the names of a table's columns, an enum's values and an API's rows, so a connection's end bound to one says it
// (`"row": "customer_id"`); and what `--ask` is told, `<tables>` and `<apis>`. A plugin value of its own, after Queries, and in
// no kit: words never switch, so a file with the kit off is asked about its tables as one with it on.

extension PluginID {
    public static let engineeringAgents: PluginID = "engineering-agents"
}

/// The kit's words for agents' queries, its kinds' row names, and `--ask`'s `<tables>` and `<apis>`.
public struct EngineeringAgentsPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .engineeringAgents }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.queryPseudoClass(RouteWord.word, RouteWord.summary, example: RouteWord.example, argument: "route", reads: .file,
                                   prepare: { _, text in RoutePattern(text) },
                                   matches: { shape, route in RouteWord.routes(shape.record, route).isEmpty ? .no : .yes },
                                   members: [RouteWord.member],
                                   rowMembers: { shape, route in
                                       let routes = RouteWord.routes(shape.record, route)
                                       return routes.isEmpty ? [:] : [RouteWord.member: .array(routes.map(JSON.string))]
                                   })
        registrar.queryPartNames(of: DatabaseTable.kind) { record, part in
            record.typed(as: DatabaseTable.self)?.props.columns.first { $0.id == part }?.name
        }
        registrar.queryPartNames(of: DatabaseEnum.kind) { record, part in
            record.typed(as: DatabaseEnum.self)?.props.values.first { $0.id == part }?.text
        }
        registrar.queryPartNames(of: API.kind) { record, part in
            guard let rows = record.typed(as: API.self)?.props.endpoints, let index = rows.firstIndex(where: { $0.id == part }) else { return nil }
            return APIGroups.fullName(of: index, in: rows)
        }
        registrar.queryAskFact(tag: KitAskFacts.tablesTag) { editor, question in KitAskFacts.tables(in: editor, question: question) }
        registrar.queryAskFact(tag: KitAskFacts.apisTag) { editor, question in KitAskFacts.apis(in: editor, question: question) }
    }
}

/// `:route("…")`: what it says, and the routes of a shape it holds.
enum RouteWord {
    static let word = "route"
    static let summary = "an API with an endpoint of that method and whole path; {id} stands for any parameter, and a path alone for any method"
    static let example = #":route("POST /orders/{id}/refunds")"#
    /// What a row it matched adds: the endpoints that are the route, by their whole names.
    static let member = "routes"

    /// The endpoints of `record` that are `route`, by their whole names: none for a shape that's no API, or a route that says no path.
    static func routes(_ record: AnyShapeRecord, _ route: RoutePattern?) -> [String] {
        guard let route, record.kind == API.kind, let api = record.typed(as: API.self) else { return [] }
        return route.routes(in: api.props)
    }
}
