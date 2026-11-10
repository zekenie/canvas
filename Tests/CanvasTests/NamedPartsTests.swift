@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

// Names of parts in values (`ShapeNaming.renamingParts`): a mention of a table's row, here a `PartCite` held in a kind's props (a list,
// a set, a dictionary, an optional, a struct's members) and in an added property. A part moved (`Transaction.moveParts`) is renamed
// where it went in every value that names it, found by the one lookup a plugin gives (`registrar.standInLookup(…namers:)`), on any
// board the step may write, a read-only shape left as it was, all in the step that moves it; and the editing part
// (`editor.editingPart`), which only a shape being edited has.

/// A name of a row of a shape: a leaf that names its shape (copies rename it) and its part (a move does).
struct PartCite: Hashable, Sendable {
    var address: PartAddress
    init(_ address: PartAddress) { self.address = address }
}

extension PartCite: Codable {
    init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        let pieces = text.split(separator: "/").compactMap { UUID(uuidString: String($0)) }
        guard pieces.count >= 1 else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: text)) }
        address = PartAddress(ShapeID(pieces[0]), part: pieces.count > 1 ? PartID(pieces[1]) : nil)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(([address.shape.rawValue] + (address.part.map { [$0.rawValue] } ?? [])).map(\.uuidString).joined(separator: "/"))
    }
}

extension PartCite: SchemaDescribed {
    static func schema(in definitions: inout SchemaDefinitions) -> JSONObject {
        definitions.reference("part-cite", of: Self.self) { _ in ["type": "string", "description": "A shape, and perhaps a row of it."] }
    }
}

extension PartCite: ShapeNaming {
    func forEachNamedShape(_ body: (ShapeID) -> Void) { body(address.shape) }
    func renamingShapes(_ rename: (ShapeID) -> ShapeID?) -> PartCite {
        PartCite(PartAddress(rename(address.shape) ?? address.shape, part: address.part))
    }
    func renamingParts(_ rename: (PartAddress) -> PartAddress?) -> PartCite { PartCite(rename(address) ?? address) }
}

/// A struct that holds names, with nothing to write.
struct CiteNote: SchemaDefined, Hashable {
    static let properties = Properties<CiteNote>(definition: "cite-note") {
        Property("cites", \.cites)
    }
    var cites: [PartCite] = []
}

extension CiteNote: ShapeNaming {}

/// A box whose props name rows in a list, a set, a dictionary, an optional and a struct in a list.
struct Cited: BoxShapeProps {
    static let kind: ShapeKind = "cited"
    static let properties = Properties<Cited> {
        Property("frame", \.frame).required()
        Property("list", \.list)
        Property("set", \.set)
        Property("byName", \.byName)
        Property("lead", \.lead)
        Property("notes", \.notes)
    }
    var frame: CGRect = .zero
    var list: [PartCite] = []
    var set: Set<PartCite> = []
    var byName: [String: PartCite] = [:]
    var lead: PartCite?
    var notes: [CiteNote] = []
}

/// Names of rows given to a shape as an added value; the boxes opt into it.
enum PartCites {}
extension PartCites: ShapeProperty {
    static let key: PropertyKey = "part-cites"
    static var defaultValue: [PartCite]? { nil }
}

@MainActor private final class Namers {
    var shapes: [ShapeID: [ShapeID]] = [:]
}

@MainActor private func namerPlugin(_ namers: Namers) -> Contributor {
    Contributor(id: "namers") { registrar in
        registrar.declare(PartCites.self)
        registrar.shape(PlainDefinition<Cited>()) { $0.optIn(to: PartCites.self) }
        registrar.standInLookup({ _, _ in [] }, namers: { _, shape in namers.shapes[shape] ?? [] })
    }
}

@MainActor private struct Scene {
    let h: EditorHarness
    let namers = Namers()
    let orders = ShapeID(), customers = ShapeID(), pocket = ShapeID(), onRoot = ShapeID(), far = ShapeID(), frozen = ShapeID()
    let id = RosterRow(name: "id"), customerID = RosterRow(name: "customer_id")
    var farBoard: BoardID { BoardID(owner: pocket) }
    var from: PartAddress { PartAddress(orders, part: customerID.id) }
    var to: PartAddress { PartAddress(customers, part: customerID.id) }

    init() throws {
        let orders = orders, customerID = customerID.id, rowID = id.id, onRoot = onRoot, far = far, frozen = frozen
        let cited = Cited(frame: CGRect(x: 0, y: 200, width: 50, height: 50), list: [PartCite(PartAddress(orders, part: customerID)), PartCite(PartAddress(orders, part: rowID))],
                          set: [PartCite(PartAddress(orders, part: customerID))], byName: ["a": PartCite(PartAddress(orders, part: customerID))],
                          lead: PartCite(PartAddress(orders, part: customerID)),
                          notes: [CiteNote(cites: [PartCite(PartAddress(orders, part: customerID)), PartCite(PartAddress(orders))])])
        func record(_ id: ShapeID, frozen: Bool = false) -> AnyShapeRecord {
            var record = AnyShapeRecord(ShapeRecord(id: id, cited))
            record[PartCites.self] = [PartCite(PartAddress(orders, part: customerID))]
            if frozen { record[Frozen.self] = true }
            return record
        }
        let root = CanvasDocument(shapes: [
            AnyShapeRecord(ShapeRecord(id: orders, Roster(CGRect(x: 0, y: 0, width: 160, height: 80), rows: [self.id, self.customerID]))),
            AnyShapeRecord(ShapeRecord(id: customers, Roster(CGRect(x: 300, y: 0, width: 160, height: 60), rows: []))),
            AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 600, y: 0, width: 100, height: 100)))),
            record(onRoot),
        ])
        let inside = CanvasDocument(shapes: [record(far), record(frozen, frozen: true)])
        h = try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin(), RostersPlugin(), FreezingPlugin(), namerPlugin(namers)],
                              file: CanvasFile(root: root, children: [pocket: inside]))
        namers.shapes[orders] = [onRoot, far, frozen]
    }

    func cited(_ id: ShapeID) -> Cited? { h.file.record(id)?.typed(as: Cited.self)?.props }
    func added(_ id: ShapeID) -> [PartCite]? { h.file.record(id)?[PartCites.self] }

    /// The column moved to "customers" in a step of its own.
    func move() {
        h.editor.transact("Move Column") { tx in
            tx.update(orders, as: Roster.self) { $0.props.rows.remove(at: 1) }
            tx.update(customers, as: Roster.self) { $0.props.rows.append(customerID) }
            tx.moveParts([from: to])
        }
    }
}

@MainActor let namedPartsTests = Suite("Names of parts (ShapeNaming.renamingParts)", [
    test("a name of a row is renamed wherever a value holds it: a struct's members, a list, a set, a dictionary, an optional; a name of a shape as a whole, or of another row, is kept") {
        let a = ShapeID(), b = ShapeID(), p = PartID(), q = PartID(), r = PartID()
        let from = PartAddress(a, part: p), to = PartAddress(b, part: q)
        let rename: (PartAddress) -> PartAddress? = { $0 == from ? to : nil }
        expectEqual(PartCite(from).renamingParts(rename), PartCite(to))
        expectEqual(PartCite(PartAddress(a)).renamingParts(rename), PartCite(PartAddress(a)), "the shape as a whole isn't one of its rows")
        expectEqual(PartCite(PartAddress(a, part: r)).renamingParts(rename), PartCite(PartAddress(a, part: r)), "another row of it isn't")
        expectEqual(Optional(PartCite(from)).renamingParts(rename), PartCite(to))
        expectEqual((nil as PartCite?).renamingParts(rename), nil)
        expectEqual([PartCite(from), PartCite(PartAddress(a))].renamingParts(rename), [PartCite(to), PartCite(PartAddress(a))])
        expectEqual(Set([PartCite(from), PartCite(PartAddress(a))]).renamingParts(rename), [PartCite(to), PartCite(PartAddress(a))])
        expectEqual(["x": PartCite(from), "y": PartCite(PartAddress(a))].renamingParts(rename), ["x": PartCite(to), "y": PartCite(PartAddress(a))])
        expectEqual(CiteNote(cites: [PartCite(from), PartCite(PartAddress(b))]).renamingParts(rename), CiteNote(cites: [PartCite(to), PartCite(PartAddress(b))]))
        expectEqual(CiteNote(cites: [PartCite(from)]).renamingParts { _ in nil }, CiteNote(cites: [PartCite(from)]), "nothing renamed, nothing changed")
        // A value that names no part is itself.
        expectEqual(Citation(a).renamingParts(rename), Citation(a))
    },
    test("moveParts renames a moved row in every value that names it, in props and added values, on this board and another, in the step that moves it, and Undo gives them all back") {
        let s = try Scene()
        s.h.editor.undoHistory.seal()
        let before = (s.cited(s.onRoot), s.cited(s.far), s.added(s.onRoot), s.added(s.far))
        s.move()
        let to = PartCite(s.to), other = PartCite(PartAddress(s.orders, part: s.id.id))
        for id in [s.onRoot, s.far] {
            let cited = try require(s.cited(id))
            expectEqual(cited.list, [to, other], "a list")
            expectEqual(cited.set, [to], "a set")
            expectEqual(cited.byName, ["a": to], "a dictionary")
            expectEqual(cited.lead, to, "an optional")
            expectEqual(cited.notes, [CiteNote(cites: [to, PartCite(PartAddress(s.orders))])], "a struct's members; the shape as a whole stays")
            expectEqual(s.added(id), [to], "an added value")
        }
        expectEqual(s.h.editor.board, .root, "the far board's shapes were written from the root")
        s.h.editor.undo()
        expectEqual(s.cited(s.onRoot), before.0)
        expectEqual(s.cited(s.far), before.1)
        expectEqual(s.added(s.onRoot), before.2)
        expectEqual(s.added(s.far), before.3)
        expectEqual(s.h.editor.document[s.orders]?.typed(as: Roster.self)?.props.rows.count, 2, "one step: the move itself is undone with the names")
    },
    test("a read-only shape, on this board or another, keeps its names; a shape the lookup doesn't give is not written; a name put in the same step isn't looked for") {
        let s = try Scene()
        s.move()
        expectEqual(s.cited(s.frozen)?.lead, PartCite(s.from), "a locked shape on another board is left as it was")
        expectEqual(s.added(s.frozen), [PartCite(s.from)])
        expectEqual(s.cited(s.onRoot)?.lead, PartCite(s.to))

        let t = try Scene()
        t.namers.shapes[t.orders] = []
        t.move()
        expectEqual(t.cited(t.onRoot)?.lead, PartCite(t.from), "nobody the lookup gives, nobody renamed: the index is the lookup")

        let u = try Scene()
        let fresh = ShapeID()
        u.h.editor.transact("Move Column") { tx in
            var record = AnyShapeRecord(ShapeRecord(id: fresh, Cited(frame: .zero, lead: PartCite(u.from))))
            record[PartCites.self] = nil
            tx.insert(record)
            tx.update(u.orders, as: Roster.self) { $0.props.rows.remove(at: 1) }
            tx.update(u.customers, as: Roster.self) { $0.props.rows.append(u.customerID) }
            tx.moveParts([u.from: u.to])
        }
        expectEqual(u.cited(fresh)?.lead, PartCite(u.from), "a shape the index hasn't heard of yet names what it named")
        expectEqual(u.cited(u.onRoot)?.lead, PartCite(u.to))
    },
    test("a row that moves within its shape renames nothing; a shape's own address renames only the names of that shape as a whole") {
        let s = try Scene()
        s.h.editor.transact("Reorder") { tx in tx.moveParts([s.from: s.from]) }
        expectEqual(s.cited(s.onRoot)?.lead, PartCite(s.from))
        s.h.editor.transact("Move Table") { tx in tx.moveParts([PartAddress(s.orders): PartAddress(s.customers)]) }
        expectEqual(s.cited(s.onRoot)?.lead, PartCite(s.from), "a part-less address names no row")
        expectEqual(s.cited(s.onRoot)?.notes.first?.cites.last, PartCite(PartAddress(s.customers)), "the shape as a whole is named where it went")
    },
    test("a shape that was all its one row, moved as a whole to the row it became (a key with no part), is named as that row wherever a value names it as a whole, on this board and another, in the step; Undo and Redo give and take it") {
        let s = try Scene()
        s.h.editor.undoHistory.seal()
        let whole = PartCite(PartAddress(s.orders)), row = PartCite(s.to)
        s.h.editor.transact("Move Endpoint") { tx in
            tx.update(s.customers, as: Roster.self) { $0.props.rows.append(s.customerID) }
            tx.moveParts([PartAddress(s.orders): s.to])
        }
        for id in [s.onRoot, s.far] {
            let notes = try require(s.cited(id)).notes
            expectEqual(notes, [CiteNote(cites: [PartCite(s.from), row])], "the shape as a whole is the row now; its rows' names, no key's, stay")
        }
        expectEqual(s.cited(s.frozen)?.notes.first?.cites.last, whole, "a read-only shape keeps its name")
        s.h.editor.undo()
        expectEqual(s.cited(s.far)?.notes.first?.cites.last, whole, "Undo names the shape again")
        s.h.editor.redo()
        expectEqual(s.cited(s.far)?.notes.first?.cites.last, row, "Redo names the row")
    },
    test("the editing part is the row the keys are on while a shape is edited, and nothing before it or after") {
        let registry = try Registry(plugins: [Contributor(id: "slips") { $0.shape(SlipDefinition()) }])
        let h = EditorHarness { CanvasEditor(registry: registry, scheduler: $0, stackingKeys: .sequential) }
        let slip = h.add(Slip(CGRect(x: 0, y: 0, width: 100, height: 60), text: "x"))
        let part = PartID()
        h.editor.editingPart = part
        expectEqual(h.editor.editingPart, nil, "no shape is being edited: it holds none")
        expect(h.editor.beginEditing(slip))
        h.editor.editingPart = part
        expectEqual(h.editor.editingPart, part)
        h.editor.endEditing()
        expectEqual(h.editor.editingPart, nil, "editing over: no row")
    },
])
