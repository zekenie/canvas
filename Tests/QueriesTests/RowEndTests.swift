@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import Queries
import QueryLanguage
import TestKit
import Topology

// What Queries gives a kind with rows, generically: a connection's end bound to a row names it (`QueryEnd.row`), by the names the
// kind's plugin gives through the part names point, read off the main actor; and a test inside a list attribute, an item at a time,
// where an item (or an object) whose schema says the member it reads as is compared by that member. Rosters (CanvasTesting's rows),
// straps bound to their rows, wired; chores' crews, a list of hands each read as its name, and a badge read as its label.

/// Straps emit a wire from what their start is bound to, to what their end is, each end's part with it, as an arrow bound to rows does.
@MainActor private func strapWires() -> Contributor {
    Contributor(id: "strap-wires") { registrar in
        registrar.edges(Strap.self) { record, _, sink in
            guard let strap = record.typed(as: Strap.self)?.props, let from = strap.from, let to = strap.to else { return }
            sink.emit(WireEdge.id, from: from.shape, to: to.shape, fromPart: from.part, toPart: to.part)
        }
    }
}

/// A roster's rows by their names, as the kind that defines rosters would give them; a row with no name has none.
@MainActor private func rosterNames() -> Contributor {
    Contributor(id: "roster-names") { registrar in
        registrar.queryPartNames(of: Roster.kind) { record, part in
            record.typed(as: Roster.self)?.props.rows.first { $0.id == part }?.name
        }
    }
}

/// One hand of a chore's crew: read as its name.
struct Hand: SchemaDefined, Hashable, Sendable {
    static let properties = Properties<Hand>(definition: "hand", readsAs: "name") {
        Property("name", \.name)
        Property("role", \.role)
    }
    var name: String
    var role: String
    init(name: String, role: String) {
        self.name = name
        self.role = role
    }
    init() { self.init(name: "", role: "") }
}

/// A chore's badge: read as its label.
struct Badge: SchemaDefined, Hashable, Sendable {
    static let properties = Properties<Badge>(definition: "badge", readsAs: "label") {
        Property("label", \.label)
        Property("level", \.level)
    }
    var label: String
    var level: Int
    init(label: String, level: Int) {
        self.label = label
        self.level = level
    }
    init() { self.init(label: "", level: 0) }
}

/// What a chore's crew is: a list of hands.
enum Crew {}
extension Crew: ShapeProperty {
    static let key: PropertyKey = "crew"
    static var defaultValue: [Hand]? { nil }
}

/// What a chore's badge is.
enum BadgeProperty {}
extension BadgeProperty: ShapeProperty {
    static let key: PropertyKey = "badge"
    static var defaultValue: Badge? { nil }
}

private let crewPlugin = Contributor(id: "crew") { registrar in
    registrar.declare(Crew.self)
    registrar.declare(BadgeProperty.self)
    registrar.optIn(Chore.self, to: Crew.self)
    registrar.optIn(Chore.self, to: BadgeProperty.self)
}

/// Chores 1 "Alpha" (Ann cooks, Bo cleans; a gold badge), 2 "Beta" (Cy cooks; a silver one) and 3 "Gamma" (no crew, no badge).
@MainActor private func crewed() throws -> EditorHarness {
    var alpha = chore(id(1), caption: "Alpha"), beta = chore(id(2), caption: "Beta")
    alpha[Crew.self] = [Hand(name: "Ann", role: "cook"), Hand(name: "Bo", role: "clean")]
    alpha[BadgeProperty.self] = Badge(label: "gold", level: 3)
    beta[Crew.self] = [Hand(name: "Cy", role: "cook")]
    beta[BadgeProperty.self] = Badge(label: "silver", level: 2)
    return try EditorHarness(plugins: queryPlugins(more: [crewPlugin]),
                             file: CanvasFile(root: CanvasDocument(shapes: [alpha, beta, chore(id(3), caption: "Gamma")])))
}

@MainActor let rowEndTests = Suite("Rows at a connection's ends", [
    test("an end bound to a row names it, by the kind's names; a whole shape's end, a kind with no names and a row with none say no row") {
        let rows = ["id", "customer_id", ""].map { RosterRow(name: $0) }
        let left = ShapeRecord(id: id(1), Roster(CGRect(x: 0, y: 0, width: 100, height: 80), rows: rows))
        let right = ShapeRecord(id: id(2), Roster(CGRect(x: 300, y: 0, width: 100, height: 80), rows: rows))
        let muster = ShapeRecord(id: id(3), Muster(CGRect(x: 600, y: 0, width: 100, height: 80), rows: rows))
        let straps = [
            ShapeRecord(id: id(11), Strap(from: PartAddress(left.id, part: rows[1].id), to: PartAddress(right.id, part: rows[0].id))),
            ShapeRecord(id: id(12), Strap(from: PartAddress(left.id), to: PartAddress(right.id, part: rows[1].id))),
            ShapeRecord(id: id(13), Strap(from: PartAddress(muster.id, part: rows[0].id), to: PartAddress(left.id, part: rows[2].id))),
        ]
        let h = try EditorHarness(plugins: queryPlugins(more: [RostersPlugin(), StrapsPlugin(), strapWires(), rosterNames()]),
                                  file: CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(left), AnyShapeRecord(right), AnyShapeRecord(muster)]
                                                                            + straps.map(AnyShapeRecord.init))))
        let connections = try answer("strap", on: h).rows.map(\.connection)
        expectEqual(connections, [
            QueryConnection(type: WireEdge.id, from: QueryEnd(id: id(1), row: "customer_id"), to: QueryEnd(id: id(2), row: "id")),
            QueryConnection(type: WireEdge.id, from: QueryEnd(id: id(1)), to: QueryEnd(id: id(2), row: "customer_id")),
            QueryConnection(type: WireEdge.id, from: QueryEnd(id: id(3)), to: QueryEnd(id: id(1))),
        ], "a whole roster, a muster (no names) and a row with no name say none")
        let encoded = try JSONEncoder().encode(try require(connections.first ?? nil))
        expectEqual(try JSON(data: encoded), [
            "type": .string(WireEdge.id.rawValue), "from": ["id": .string(uuid(1)), "row": "customer_id"], "to": ["id": .string(uuid(2)), "row": "id"],
        ])
    },
    test("one plugin names a kind's parts, and the report says so") {
        let twice = try? Registry(plugins: queryPlugins(more: [RostersPlugin(), rosterNames(), Contributor(id: "again") { registrar in
            registrar.queryPartNames(of: Roster.kind) { _, _ in nil }
        }]))
        expect(twice == nil, "one plugin a kind")
        let report = try Registry(plugins: queryPlugins(more: [RostersPlugin(), rosterNames()])).report
        expect(report.contains("query part names"), report)
    },
    test("a test inside a list attribute holds when any item does; an item, or an object, that reads as a member is compared by it") {
        let h = try crewed()
        expectMatches([
            #"chore[crew.role="cook"]"#: [1, 2],
            #"chore[crew.name="Bo"]"#: [1],
            #"chore[crew.name^="C"]"#: [2],
            #"chore[crew="Ann"]"#: [1],
            #"chore[crew="ann" i]"#: [1],
            #"chore[crew~=Cy]"#: [2],
            #"chore[crew="Dee"]"#: [],
            #"chore[crew]"#: [1, 2],
            #"chore:not([crew])"#: [3],
            #"chore[badge="gold"]"#: [1],
            #"chore[badge.level>2]"#: [1],
            #"chore[badge.label*="l"]"#: [1, 2],
            #"chore[badge]"#: [1, 2],
        ], on: h)
        // As written, never as it's read.
        expectEqual(try require(h.editor.queries).check(#"chore[crew="Ann"]"#).canonical, #"chore[crew="Ann"]"#)
    },
    test("a list of text has no members, nor an object that says no member it reads as compared whole") {
        let h = try crewed()
        expectEqual(try refusedAnswer("chore[tags.x=1]", on: h)?.reason, .unknownAttribute)
        expectEqual(try refusedAnswer(#"chore[meta="ann"]"#, on: h)?.reason, .notBuilt, "an object compared whole, as before")
        expectEqual(try refusedAnswer("chore[tags=red]", on: h)?.reason, .unsupportedOperator, "a list of text takes ~=, as before")
    },
])
