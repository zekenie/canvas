@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

/// A kind with a history. Version 0 had a `name`; version 1 renamed it `title`; version 2 added `done`.
struct Ticket: BoxShapeProps {
    static let kind: ShapeKind = "ticket"
    static let migrations = [
        PropsMigration("name becomes title") { props in props["title"] = props.removeValue(forKey: "name") },
        PropsMigration("tickets can be done") { props in props["done"] = false },
    ]
    var frame: CGRect
    var title: String
    var done: Bool
}

struct TicketDefinition {}
extension TicketDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Ticket>, in context: RenderContext) {}
}

/// A kind with a plain number, to show what a board does with one that isn't finite.
struct Reading: ShapeProps {
    static let kind: ShapeKind = "reading"
    var value: Double
}

struct ReadingDefinition {}
extension ReadingDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Reading>, in context: RenderContext) {}
    func geometry(of shape: ShapeRecord<Reading>, in context: ShapeContext) -> ShapeGeometry { ShapeGeometry(outline: [], isClosed: false) }
}

@MainActor func codecRegistry() throws -> Registry {
    try Registry(plugins: [FixturesPlugin(), Contributor(id: "tickets") { $0.shape(TicketDefinition()); $0.shape(ReadingDefinition()) }])
}

private func uuid(_ n: Int) -> ShapeID { ShapeID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!) }

@MainActor private func read(_ json: String) throws -> LoadedBoard { try BoardCodec(registry: codecRegistry()).decode(Data(json.utf8)) }

@MainActor private func readError(_ json: String) -> BoardReadError? {
    do {
        _ = try BoardCodec(registry: codecRegistry()).decode(Data(json.utf8))
        return nil
    } catch {
        return error as? BoardReadError
    }
}

/// A board's JSON with these shape records (already JSON) and this schema.
private func board(_ records: [String], schema: String = #"{ "box" : 0, "ticket" : 2 }"#, format: Int = 1) -> String {
    #"{ "format" : \#(format), "schema" : \#(schema), "shapes" : [\#(records.joined(separator: ", "))] }"#
}

private func box(_ id: Int, index: String? = "a0", frame: String = "[[0, 0], [10, 10]]") -> String {
    #"{ "id" : "\#(uuid(id))", "kind" : "box", \#(index.map { #""index" : "\#($0)", "# } ?? "")"props" : { "frame" : \#(frame) } }"#
}

/// A reproducible stream of choices for the fuzz test.
private struct Mutations: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 11 | state << 53
    }
}

@MainActor let boardCodecTests = Suite("Board codec", [
    test("a board is an envelope around its shapes, back to front, with each kind's version") {
        let document = CanvasDocument(shapes: [
            AnyShapeRecord(ShapeRecord(id: uuid(1), Box(CGRect(x: 10, y: 20, width: 30, height: 40)))),
            AnyShapeRecord(ShapeRecord(id: uuid(2), Ticket(frame: CGRect(x: 0.5, y: 0, width: 1, height: 2), title: "Ship it", done: true))),
        ])
        let json = String(decoding: try BoardCodec(registry: codecRegistry()).encode(document), as: UTF8.self)
        expectEqual(json, """
        {
          "format" : 1,
          "schema" : {
            "box" : 0,
            "ticket" : 2
          },
          "shapes" : [
            {
              "id" : "00000000-0000-0000-0000-000000000001",
              "index" : "a0",
              "kind" : "box",
              "props" : {
                "frame" : [
                  [
                    10,
                    20
                  ],
                  [
                    30,
                    40
                  ]
                ]
              }
            },
            {
              "id" : "00000000-0000-0000-0000-000000000002",
              "index" : "a1",
              "kind" : "ticket",
              "props" : {
                "done" : true,
                "frame" : [
                  [
                    0.5,
                    0
                  ],
                  [
                    1,
                    2
                  ]
                ],
                "title" : "Ship it"
              }
            }
          ]
        }
        """)
    },
    test("a board reads back as the document it was, with nothing to report") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let a = h.add(Box(CGRect(x: 1, y: 2, width: 3, height: 4)))
        h.add(Disc(CGRect(x: 5, y: 5, width: 5, height: 5)))
        h.add(Tag(target: a))
        h.editor.transact { $0.bringToFront(a) }
        let codec = BoardCodec(registry: h.editor.registry)
        let loaded = try codec.decode(try codec.encode(h.editor.document))
        expectEqual(loaded.document, h.editor.document)
        expect(loaded.report.isEmpty, "\(loaded.report)")
    },
    test("an older version of a kind is migrated, step by step, to today's") {
        let loaded = try read(board([#"{ "id" : "\#(uuid(1))", "index" : "a0", "kind" : "ticket", "props" : { "frame" : [[0, 0], [1, 1]], "name" : "Old" } }"#],
                                    schema: #"{ "ticket" : 0 }"#))
        let ticket = try require(loaded.document[uuid(1)]?.typed(as: Ticket.self)?.props)
        expectEqual(ticket.title, "Old")
        expectEqual(ticket.done, false)
        expect(loaded.report.isEmpty)
        // A record's own version wins over the schema's.
        let own = try read(board([#"{ "id" : "\#(uuid(1))", "index" : "a0", "kind" : "ticket", "v" : 1, "props" : { "frame" : [[0, 0], [1, 1]], "title" : "One" } }"#],
                                 schema: #"{ "ticket" : 0 }"#))
        expectEqual(own.document[uuid(1)]?.typed(as: Ticket.self)?.props.title, "One")
    },
    test("a shape whose kind isn't installed is kept aside, in its place, and written back as it was") {
        let codec = BoardCodec(registry: try codecRegistry())
        let gadget = #"{ "id" : "\#(uuid(2))", "index" : "a1", "kind" : "gadget", "props" : { "gears" : [1, 2.5, "nan"], "label" : "nan" } }"#
        let loaded = try codec.decode(Data(board([box(1, index: "a0"), gadget, box(3, index: "a2")], schema: #"{ "box" : 0, "gadget" : 3 }"#).utf8))
        expectEqual(loaded.document.shapes.map(\.id), [uuid(1), uuid(2), uuid(3)])
        let kept = try require(loaded.document[uuid(2)])
        expect(kept.isOpaque)
        expectEqual(kept.kind.rawValue, "gadget")
        expectEqual(loaded.report.keptAside, [LoadReport.KeptShape(id: uuid(2), kind: "gadget", reason: .unknownKind)])
        expect(loaded.report.repairs.isEmpty)
        // Nothing draws, hits or edits it, and an editor takes the board as it is.
        let editor = CanvasEditor(registry: try codecRegistry(), document: loaded.document)
        expectEqual(editor.shape(at: CGPoint(x: 5, y: 5)), uuid(3))
        expect(!editor.beginEditing(uuid(2)))
        // Saved, it's the same JSON at the same version, and reads back the same.
        let saved = try codec.decode(try codec.encode(editor.document))
        expectEqual(saved.document, loaded.document)
        let json = String(decoding: try codec.encode(editor.document), as: UTF8.self)
        expect(json.contains(#""v" : 3"#), json)
        expect(!json.contains(#""gadget" : 3"#), "the schema lists only kinds the app wrote: \(json)")
    },
    test("a shape from a newer version of its kind is kept aside, with its version") {
        let loaded = try read(board([#"{ "id" : "\#(uuid(1))", "index" : "a0", "kind" : "ticket", "props" : { "frame" : [[0, 0], [1, 1]], "title" : "Future", "priority" : 9 } }"#],
                                    schema: #"{ "ticket" : 7 }"#))
        expect(loaded.document[uuid(1)]?.isOpaque == true)
        expectEqual(loaded.report.keptAside.first?.reason, .newerVersion(file: 7, app: 2))
    },
    test("a shape that doesn't load is kept aside as it was, and the rest of the board opens") {
        let loaded = try read(board([
            box(1, index: "a0", frame: #""wide""#),
            box(2, index: "a1"),
            box(3, index: "a2", frame: #"[["nan", 0], [1, 1]]"#),
            // Migrated to a version that still doesn't decode: kept at the version it was.
            #"{ "id" : "\#(uuid(4))", "index" : "a3", "kind" : "ticket", "v" : 1, "props" : { "frame" : [[0, 0], [1, 1]], "title" : 12 } }"#,
            #""not a shape""#,
        ]))
        expectEqual(loaded.document.shapes.count, 5)
        expect(loaded.document[uuid(2)]?.isOpaque == false)
        let reasons = Dictionary(loaded.report.keptAside.map { ($0.id, $0.reason) }, uniquingKeysWith: { first, _ in first })
        for id in [uuid(1), uuid(3), uuid(4)] {
            guard case .unreadable(let why)? = reasons[id] else { expect(false, "\(id) is kept aside as unreadable"); continue }
            expect(!why.isEmpty)
        }
        expectEqual(loaded.report.keptAside.count, 4, "the string, too, under a new id")
        let codec = BoardCodec(registry: try codecRegistry())
        let json = String(decoding: try codec.encode(loaded.document), as: UTF8.self)
        expect(json.contains(#""title" : 12"#) && json.contains(#""v" : 1"#), "kept as it was, at its own version: \(json)")
        expect(json.contains(#""wide""#) && json.contains(#""nan""#), json)
    },
    test("ids that are missing or repeated are replaced; the first shape with an id keeps it") {
        let loaded = try read(board([box(1, index: "a0"), box(1, index: "a1"),
                                     #"{ "kind" : "box", "index" : "a2", "props" : { "frame" : [[0, 0], [1, 1]] } }"#]))
        expectEqual(loaded.document.shapes.count, 3)
        expectEqual(loaded.document.shapes.first?.id, uuid(1))
        let newIDs = loaded.report.repairs.compactMap { repair -> ShapeID?? in
            if case .newID(let old, _) = repair { old } else { nil }
        }
        expectEqual(newIDs, [uuid(1), nil])
        expectEqual(Set(loaded.document.shapes.map(\.id)).count, 3)
    },
    test("shapes come back in stacking order, whatever order the file lists them in") {
        let loaded = try read(board([box(1, index: "a2"), box(2, index: "a0"), box(3, index: "a1")]))
        expectEqual(loaded.document.shapes.map(\.id), [uuid(2), uuid(3), uuid(1)])
        expect(loaded.report.isEmpty, "keys that are all there and distinct need no repair")
    },
    test("tied keys are ordered by id and made distinct; missing or malformed ones go on top, in file order") {
        let loaded = try read(board([box(5, index: "a1"), box(4, index: "a1"), box(3, index: nil), box(2, index: "a00"), box(1, index: "a0")]))
        expectEqual(loaded.document.shapes.map(\.id), [uuid(1), uuid(4), uuid(5), uuid(3), uuid(2)])
        let keys = loaded.document.shapes.compactMap(\.stackingKey)
        expectEqual(keys.count, 5)
        expectEqual(keys, keys.sorted())
        expectEqual(Set(keys).count, 5)
        expectEqual(loaded.report.repairs, [.newStackingKey(uuid(5)), .newStackingKey(uuid(3)), .newStackingKey(uuid(2))])
    },
    test("a file that isn't a board, or is from a newer app, won't open, and says why") {
        expectEqual(readError(board([box(1)], format: 2)), .newerFormat(2))
        for json in ["", "not json", "[1, 2]", #"{ "shapes" : [] }"#, #"{ "format" : 1 }"#, #"{ "format" : 0, "shapes" : [] }"#, #"{ "format" : "1", "shapes" : [] }"#] {
            guard case .unreadable(let why)? = readError(json) else { expect(false, "\(json) is unreadable"); continue }
            expect(!why.isEmpty, json)
        }
        // A schema that isn't one only costs the versions: every kind is read at version 0.
        let loaded = try read(board([box(1)], schema: #""nonsense""#))
        expect(loaded.document[uuid(1)]?.isOpaque == false)
    },
    test("a number that isn't finite still saves, and reads back") {
        let codec = BoardCodec(registry: try codecRegistry())
        let document = CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: uuid(1), Reading(value: .infinity))),
                                               AnyShapeRecord(ShapeRecord(id: uuid(2), Reading(value: .nan)))])
        let loaded = try codec.decode(try codec.encode(document))
        expectEqual(loaded.document[uuid(1)]?.typed(as: Reading.self)?.props.value, .infinity)
        expect(loaded.document[uuid(2)]?.typed(as: Reading.self)?.props.value.isNaN == true)
    },
    test("one shape's props encode and decode on their own, at any version") {
        let codec = BoardCodec(registry: try codecRegistry())
        let data = try codec.encodeProps(Ticket(frame: .zero, title: "T", done: true))
        expectEqual(try codec.decodeProps(data, kind: Ticket.kind, version: 2) as? Ticket, Ticket(frame: .zero, title: "T", done: true))
        let old = Data(#"{ "frame" : [[0, 0], [0, 0]], "name" : "T" }"#.utf8)
        expectEqual(try codec.decodeProps(old, kind: Ticket.kind, version: 0) as? Ticket, Ticket(frame: .zero, title: "T", done: false))
        expectEqual(codec.version(of: Ticket.kind), 2)
        expectEqual(codec.version(of: Box.kind), 0)
        expectEqual(codec.version(of: "gadget"), nil)
    },
    test("no truncated or scrambled board crashes the reader: it opens, or says why not") {
        let codec = BoardCodec(registry: try codecRegistry())
        let h = try EditorHarness(plugins: [FixturesPlugin(), Contributor(id: "tickets") { $0.shape(TicketDefinition()); $0.shape(ReadingDefinition()) }])
        for i in 0..<12 {
            let id = h.add(Box(CGRect(x: i, y: i, width: 10, height: 10)))
            h.add(Ticket(frame: CGRect(x: 0, y: CGFloat(i), width: 5, height: 5), title: "T\(i)", done: i.isMultiple(of: 2)))
            h.add(Tag(target: id))
        }
        let good = Array(try codec.encode(h.editor.document))
        var random = Mutations(state: 7)
        var opened = 0
        for _ in 0..<400 {
            var bytes = good
            for _ in 0..<Int.random(in: 1...4, using: &random) {
                guard !bytes.isEmpty else { break }
                let at = Int.random(in: 0..<bytes.count, using: &random)
                switch Int.random(in: 0..<4, using: &random) {
                case 0: bytes.removeSubrange(at...)                                                         // truncated
                case 1: bytes[at] = Array(#"{}[],:"0aZ -\"#.utf8).randomElement(using: &random)!             // scrambled
                case 2: bytes.removeSubrange(at..<min(bytes.count, at + Int.random(in: 1...40, using: &random)))
                default: bytes.insert(contentsOf: bytes[at..<min(bytes.count, at + 60)], at: at)             // repeated
                }
            }
            guard let loaded = try? codec.decode(Data(bytes)) else { continue }
            opened += 1
            let keys = loaded.document.shapes.map(\.stackingKey)
            expect(keys.allSatisfy { $0 != nil })
            expectEqual(keys.compactMap { $0 }, keys.compactMap { $0 }.sorted())
            _ = CanvasEditor(registry: h.editor.registry, document: loaded.document)
        }
        expect(opened > 0, "some mutations leave a board that opens")
    },
])
