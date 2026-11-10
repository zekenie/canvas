import Canvas
import CanvasRPC
import Queries

// What agents read of the kit's shapes, through Queries' points: `:route("POST /orders/{id}/refunds")`, the APIs that serve a
// route and the endpoints taken out of one that are it; the names of a table's columns, an enum's values, an API's rows and an
// endpoint's own row, so a connection's end bound to one says it (`"row": "customer_id"`); and what `--ask` is told, `<tables>`
// and `<apis>`. A plugin value of its own, after Queries, and in
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
                                   refusing: RoutePattern.refusal(of:),
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
            record.typed(as: API.self).flatMap { APIGroups.fullName(ofRow: part, in: $0.props.endpoints) }
        }
        // An endpoint taken out of an API keeps its row, named as it was there: its method and whole path.
        registrar.queryPartNames(of: StandaloneEndpoint.kind) { record, part in
            record.typed(as: StandaloneEndpoint.self).flatMap { alone in
                alone.props.endpoint.id == part ? APIGroups.fullName(method: alone.props.endpoint.method, path: alone.props.endpoint.path) : nil
            }
        }
        registrar.queryAskFact(tag: KitAskFacts.tablesTag) { editor, question in KitAskFacts.tables(in: editor, question: question) }
        registrar.queryAskFact(tag: KitAskFacts.apisTag) { editor, question in KitAskFacts.apis(in: editor, question: question) }
    }
}

/// `:route("…")`: what it says, and the routes of a shape it holds.
enum RouteWord {
    static let word = "route"
    static let summary = "an API with an endpoint of that method and whole path, or an endpoint taken out of one that is it; {id} stands for any parameter, and a path alone for any method"
    static let example = #":route("POST /orders/{id}/refunds")"#
    /// What a row it matched adds: the endpoints that are the route, by their whole names.
    static let member = "routes"

    /// The endpoints of `record` that are `route`, by their whole names: an API's, or an endpoint of its own's one (its path is
    /// whole); none for any other shape, or a route that says no path.
    static func routes(_ record: AnyShapeRecord, _ route: RoutePattern?) -> [String] {
        guard let route else { return [] }
        if let api = record.typed(as: API.self) { return route.routes(in: api.props) }
        guard let endpoint = record.typed(as: StandaloneEndpoint.self)?.props.endpoint,
              route.matches(method: endpoint.method, path: endpoint.path) else { return [] }
        return [APIGroups.fullName(method: endpoint.method, path: endpoint.path)]
    }
}
