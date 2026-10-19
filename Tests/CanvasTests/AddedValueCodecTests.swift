@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

/// Labels on a parcel: once the parcel's own `tags`, handed over at version 1; lowercase since
/// the property's version 1.
enum Labels {}
extension Labels: ShapeProperty {
    static let key: PropertyKey = "labels"
    static var defaultValue: [String]? { [] }
    static let migrations = [
        PropertyMigration("labels are lowercase") { labels in
            guard let items = labels.arrayValue else { throw NotAList() }
            labels = .array(items.map { .string(($0.stringValue ?? "").lowercased()) })
        },
    ]
}

struct NotAList: Error {}

/// A kind with a history that hands a member over: version 0 had `tags`.
struct Parcel: BoxShapeProps {
    static let kind: ShapeKind = "parcel"
    static let migrations = [PropsMigration.handOver("tags", to: Labels.self)]
    static let properties = Properties<Parcel> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect = .zero
}

/// A date only some shapes have: written as a board writes any date, whichever way it's read.
enum Deadline {}
extension Deadline: ShapeProperty {
    static let key: PropertyKey = "deadline"
    static var defaultValue: Date? { nil }
}

/// The same property a version on, by a step that rewrites nothing.
enum LaterDeadline {}
extension LaterDeadline: ShapeProperty {
    static let key: PropertyKey = "deadline"
    static var defaultValue: Date? { nil }
    static let migrations = [PropertyMigration("deadlines take a step")]
}

@MainActor private func deadlines<P: ShapeProperty>(_: P.Type) throws -> Registry {
    try Registry(plugins: [FixturesPlugin(), Contributor(id: "deadlines") { $0.declare(P.self); $0.optIn(Box.self, to: P.self) }])
}

@MainActor private func registry() throws -> Registry {
    try Registry(plugins: [FixturesPlugin(), ratings(), Contributor(id: "parcels") { r in
        r.declare(Labels.self)
        r.shape(PlainDefinition<Parcel>()) { $0.optIn(to: Labels.self) }
    }])
}

private func uuid(_ n: Int) -> ShapeID { ShapeID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!) }

/// A format-2 board's JSON with these shape records (already JSON).
private func board(_ records: [String], versions: String = #"{ "kinds" : { "box" : 0, "disc" : 0, "parcel" : 1 }, "added" : { "stars" : 0, "sticker" : 0 } }"#) -> String {
    #"{ "format" : 3, "versions" : \#(versions), "shapes" : [\#(records.joined(separator: ", "))] }"#
}

private func shape(_ id: Int, kind: String = "box", index: String, added: String? = nil, kept: String? = nil) -> String {
    let extra = [added.map { #""added" : \#($0)"# }, kept.map { #""kept" : \#($0)"# }].compactMap { $0 }
    return #"{ "id" : "\#(uuid(id))", "kind" : "\#(kind)", "index" : "\#(index)", "props" : { "frame" : [[0, 0], [10, 10]] }\#(extra.map { ", " + $0 }.joined()) }"#
}

@MainActor private func read(_ json: String) throws -> LoadedBoard { try BoardCodec(registry: registry()).decode(Data(json.utf8)) }

private func object(_ data: Data) throws -> JSONObject { try JSONDecoder().decode(JSONValue.self, from: data).objectValue ?? [:] }

@MainActor let addedValueCodecTests = Suite("Added properties on disk", [
    test("a shape's added values are beside its props, and each property's version beside each kind's") {
        let codec = BoardCodec(registry: try registry())
        var record = AnyShapeRecord(ShapeRecord(id: uuid(1), Box(CGRect(x: 0, y: 0, width: 10, height: 10))))
        record[Stars.self] = 3
        record[Sticker.self] = "gold"
        let json = String(decoding: try codec.encode(CanvasDocument(shapes: [record])), as: UTF8.self)
        expectEqual(json, """
        {
          "format" : 3,
          "shapes" : [
            {
              "added" : {
                "stars" : 3,
                "sticker" : "gold"
              },
              "id" : "00000000-0000-0000-0000-000000000001",
              "index" : "a0",
              "kind" : "box",
              "props" : {
                "frame" : [
                  [
                    0,
                    0
                  ],
                  [
                    10,
                    10
                  ]
                ]
              }
            }
          ],
          "versions" : {
            "added" : {
              "stars" : 0,
              "sticker" : 0
            },
            "kinds" : {
              "box" : 0
            }
          }
        }
        """)
    },
    test("a board reads back its values as they were, and a shape saved before its kind opted in gets the defaults, with nothing to report") {
        let codec = BoardCodec(registry: try registry())
        let h = try EditorHarness(plugins: [FixturesPlugin(), ratings()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        h.add(Disc(CGRect(x: 20, y: 0, width: 10, height: 10)))
        h.editor.transact { $0.update(box) { $0[Stars.self] = 4; $0[Sticker.self] = "gold" } }
        let loaded = try codec.decode(try codec.encode(h.editor.document))
        expectEqual(loaded.document, h.editor.document)
        expect(loaded.report.isEmpty, "\(loaded.report)")
        let old = try read(board([shape(1, index: "a0")], versions: #"{ "kinds" : { "box" : 0 } }"#))
        expectEqual(old.document[uuid(1)]?[Stars.self], 0)
        expectEqual(old.document[uuid(1)]?[Sticker.self], nil)
        expect(old.report.isEmpty, "\(old.report)")
        let formatOne = try read(#"{ "format" : 1, "schema" : { "box" : 0 }, "shapes" : [\#(shape(1, index: "a0"))] }"#)
        expectEqual(formatOne.document[uuid(1)]?[Stars.self], 0)
    },
    test("values the app can't use are kept with their version, reported, and written back as they were, while their shapes stay usable") {
        let loaded = try read(board([
            shape(1, index: "a0", added: #"{ "confetti" : { "velocity" : 240 }, "stars" : 2 }"#),
            shape(2, kind: "disc", index: "a1", added: #"{ "stars" : 5 }"#),
            shape(3, index: "a2", added: #"{ "sticker" : 12 }"#),
            shape(4, index: "a3", added: #"{ "stars" : 9 }"#),
        ], versions: #"{ "kinds" : { "box" : 0, "disc" : 0 }, "added" : { "stars" : 0, "sticker" : 0 } }"#))
        expectEqual(loaded.report.keptValues.map(\.key), ["confetti", "stars", "sticker"])
        expectEqual(loaded.report.keptValues.map(\.id), [uuid(1), uuid(2), uuid(3)])
        expectEqual(loaded.report.keptValues[0].reason, .notDeclared)
        expectEqual(loaded.report.keptValues[1].reason, .notOptedIn)
        guard case .unreadable(let why) = loaded.report.keptValues[2].reason else { throw RequireFailed() }
        expect(why.contains("added.sticker"), why)
        let first = try require(loaded.document[uuid(1)])
        expect(!first.isOpaque)
        expectEqual(first[Stars.self], 2)
        expectEqual(first.keptProperties, ["confetti"])
        expectEqual(loaded.document[uuid(2)]?.keptProperties, ["stars"])
        expectEqual(loaded.document[uuid(3)]?[Sticker.self], nil)
        let codec = BoardCodec(registry: try registry())
        let written = try object(codec.encode(loaded.document))
        let shapes = try require(written["shapes"]?.arrayValue)
        expectEqual(shapes[0]["kept"], ["confetti": ["v": 0, "value": ["velocity": 240]]])
        expectEqual(shapes[0]["added"], ["stars": 2])
        expectEqual(shapes[2]["kept"], ["sticker": ["v": 0, "value": 12]])
        expectEqual(shapes[2]["added"], ["stars": 0], "the default fills in beside it")
        let again = try codec.decode(try codec.encode(loaded.document))
        expectEqual(again.document, loaded.document)
        expectEqual(again.report.keptValues.map(\.key), ["confetti", "stars", "sticker"])
    },
    test("a value from a newer version of its property is kept at that version, beside new values at this one") {
        let codec = BoardCodec(registry: try registry())
        let loaded = try read(board([shape(1, index: "a0", added: #"{ "stars" : 9 }"#)],
                                    versions: #"{ "kinds" : { "box" : 0 }, "added" : { "stars" : 3 } }"#))
        expectEqual(loaded.report.keptValues.map(\.reason), [.newerVersion(file: 3, app: 0)])
        let document = CanvasDocument(shapes: loaded.document.shapes + [AnyShapeRecord(ShapeRecord(id: uuid(2), Box(.zero)))])
        let written = try object(codec.encode(try Registry(plugins: [FixturesPlugin(), ratings()]).fillingDefaults(document)))
        let shapes = try require(written["shapes"]?.arrayValue)
        expectEqual(shapes[0]["kept"], ["stars": ["v": 3, "value": 9]])
        expectEqual(shapes[1]["added"], ["stars": 0])
        expectEqual(written["versions"]?["added"], ["stars": 0], "the version of the values in added")
    },
    test("a kept entry that isn't one is left out, with a repair to say so, and the rest are kept") {
        let loaded = try read(board([
            shape(1, index: "a0", kept: #"{ "confetti" : { "v" : 0, "value" : 1 }, "glitter" : { "value" : 2 }, "sparkle" : { "v" : 1.5, "value" : 3 } }"#),
            shape(2, index: "a1", added: #"[1, 2]"#),
            shape(3, index: "a2", kept: #"7"#),
        ]))
        expectEqual(loaded.document[uuid(1)]?.keptProperties, ["confetti"])
        expectEqual(loaded.report.repairs, [.droppedValues(uuid(1)), .droppedValues(uuid(2)), .droppedValues(uuid(3))])
        expectEqual(loaded.document[uuid(2)]?[Stars.self], 0, "the defaults still fill in")
    },
    test("a date is written as a board writes one, and reads back through every path: typed, kept and taken back, migrated") {
        let when = Date(timeIntervalSince1970: 1_790_000_000)
        var record = AnyShapeRecord(ShapeRecord(id: uuid(1), Box(CGRect(x: 0, y: 0, width: 10, height: 10))))
        record[Deadline.self] = when
        let board = try BoardCodec(registry: deadlines(Deadline.self)).encode(CanvasDocument(shapes: [record]))
        expectEqual(try object(board)["shapes"]?.arrayValue?.first?["added"], ["deadline": "2026-09-21T14:13:20Z"])
        // An app without the property keeps it, and one with it takes it back.
        let without = BoardCodec(registry: try Registry(plugins: [FixturesPlugin()]))
        let kept = try without.encode(try without.decode(board).document)
        expectEqual(try object(kept)["shapes"]?.arrayValue?.first?["kept"], ["deadline": ["v": 0, "value": "2026-09-21T14:13:20Z"]])
        let back = try BoardCodec(registry: deadlines(Deadline.self)).decode(kept)
        expectEqual(back.document[uuid(1)]?[Deadline.self], when)
        expect(back.report.isEmpty, "\(back.report)")
        // A version on, the same board reads through the property's step.
        let later = BoardCodec(registry: try deadlines(LaterDeadline.self))
        expectEqual(try later.decode(board).document[uuid(1)]?[LaterDeadline.self], when)
        let fixture = Data(#""2026-09-21T14:13:20Z""#.utf8)
        expectEqual(try later.migrateValue(fixture, property: "deadline", version: 0), fixture)
        expectEqual(try later.migrateValue(fixture, property: "deadline", version: 1), fixture)
    },
    test("a shape's kept values are reported in the order of their keys") {
        let loaded = try read(board([shape(1, index: "a0", added: #"{ "zebra" : 1, "apple" : 2 }"#,
                                           kept: #"{ "mango" : { "v" : 0, "value" : 3 } }"#)]))
        expectEqual(loaded.report.keptValues.map(\.key), ["apple", "mango", "zebra"])
    },
    test("a kept value is taken back once the app can use it") {
        let loaded = try read(board([shape(1, index: "a0", kept: #"{ "stars" : { "v" : 0, "value" : 4 } }"#)]))
        expectEqual(loaded.document[uuid(1)]?[Stars.self], 4)
        expectEqual(loaded.document[uuid(1)]?.keptProperties, [])
        expect(loaded.report.isEmpty, "\(loaded.report)")
    },
    test("a shape kept aside keeps its added values, with their versions, and nothing can set one") {
        let loaded = try read(board([shape(1, kind: "comet", index: "a0", added: #"{ "stars" : 2 }"#,
                                           kept: #"{ "confetti" : { "v" : 4, "value" : true } }"#)]))
        let comet = try require(loaded.document[uuid(1)])
        expect(comet.isOpaque)
        expectEqual(comet.keptProperties, ["confetti", "stars"])
        expectEqual(loaded.report.keptValues, [], "the shape is reported, not each value")
        let h = try EditorHarness(plugins: [FixturesPlugin(), ratings()], document: loaded.document)
        h.editor.transact { $0.update(uuid(1)) { $0[Stars.self] = 5 } }
        expectEqual(h.editor.document[uuid(1)], comet)
        let written = try object(BoardCodec(registry: try registry()).encode(h.editor.document))
        expectEqual(written["shapes"]?.arrayValue?.first?["kept"], ["confetti": ["v": 4, "value": true], "stars": ["v": 0, "value": 2]])
    },
    test("a kind's history hands a member over to an added property, which then migrates by its own history") {
        let codec = BoardCodec(registry: try registry())
        let old = #"{ "id" : "\#(uuid(1))", "kind" : "parcel", "index" : "a0", "props" : { "frame" : [[0, 0], [10, 10]], "tags" : ["Fragile", "UP"] } }"#
        let loaded = try read(#"{ "format" : 1, "schema" : { "parcel" : 0 }, "shapes" : [\#(old)] }"#)
        expectEqual(loaded.document[uuid(1)]?[Labels.self], ["fragile", "up"])
        expect(loaded.report.isEmpty, "\(loaded.report)")
        let written = try object(codec.encode(loaded.document))
        let parcel = try require(written["shapes"]?.arrayValue?.first)
        expectEqual(parcel["props"], ["frame": [[0, 0], [10, 10]]])
        expectEqual(parcel["added"], ["labels": ["fragile", "up"]])
        expectEqual(written["versions"]?["added"], ["labels": 1])
        let record = try codec.decodeRecord(props: Data(#"{ "frame" : [[0, 0], [1, 1]], "tags" : ["A"] }"#.utf8), kind: Parcel.kind, version: 0)
        expectEqual(record[Labels.self], ["a"])
        expectEqual(String(decoding: try codec.migrateValue(Data(#"["B"]"#.utf8), property: "labels", version: 0), as: UTF8.self), "[\n  \"b\"\n]")
        expectEqual(codec.version(ofProperty: "labels"), 1)
        // A value handed over that can't be read costs only that value, as it would in a board:
        // decodeProps reads the props, and decodeRecord, stricter, says why.
        let badTags = Data(#"{ "frame" : [[0, 0], [1, 1]], "tags" : 5 }"#.utf8)
        expect(try codec.decodeProps(badTags, kind: Parcel.kind, version: 0) is Parcel)
        do {
            _ = try codec.decodeRecord(props: badTags, kind: Parcel.kind, version: 0)
            expect(false, "a record whose handed-over value doesn't read decoded")
        } catch {}
        expectEqual(codec.version(ofProperty: "nope"), nil)
    },
    test("no truncated or scrambled board with added and kept values crashes the reader") {
        let codec = BoardCodec(registry: try registry())
        let seed = try read(board((0..<8).map { i in
            shape(i + 1, index: "a\(i)", added: #"{ "stars" : \#(i), "sticker" : "s\#(i)", "confetti" : [\#(i)] }"#,
                  kept: #"{ "sparkle" : { "v" : \#(i), "value" : { "n" : \#(i) } } }"#)
        }))
        let good = Array(try codec.encode(seed.document))
        var random = UInt64(11)
        func next(_ bound: Int) -> Int {
            random = random &* 6364136223846793005 &+ 1442695040888963407
            return Int((random >> 33) % UInt64(bound))
        }
        var opened = 0
        for _ in 0..<300 {
            var bytes = good
            for _ in 0..<(1 + next(3)) {
                let at = next(bytes.count)
                switch next(3) {
                case 0: bytes.removeSubrange(at..<min(bytes.count, at + 1 + next(30)))
                case 1: let noise = Array(#"{}[],:"0aZ -\"#.utf8); bytes[at] = noise[next(noise.count)]
                default: bytes.insert(contentsOf: bytes[at..<min(bytes.count, at + 40)], at: at)
                }
                if bytes.isEmpty { break }
            }
            guard let loaded = try? codec.decode(Data(bytes)) else { continue }
            opened += 1
            let written = try codec.encode(loaded.document)
            expectEqual(try codec.decode(written).document, loaded.document, "what opens saves and reopens the same")
        }
        expect(opened > 0, "some mutations leave a board that opens")
    },
])
