@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

// File values on disk: the envelope's `values`, from format 6, each value with its version; a file
// with none written as it always was; what the app can't use kept whole and written back; migrations.

/// Who signs for the file: a list of structs, as a plugin's own list would be.
private struct Signatory: Codable, Equatable, Sendable {
    var name: String
    var title: String
}

private enum Signatories {}
extension Signatories: FileProperty {
    static let key: PropertyKey = "signatories"
    static var defaultValue: [Signatory] { [] }
}

/// When the file's concern was founded, if anyone said: written as a board writes any date.
private enum Founded {}
extension Founded: FileProperty {
    static let key: PropertyKey = "founded"
    static var defaultValue: Date? { nil }
}

/// The letterhead a version on: uppercase since version 1.
private enum LoudLetterhead {}
extension LoudLetterhead: FileProperty {
    static let key: PropertyKey = "letterhead"
    static var defaultValue: String { "" }
    static let migrations = [
        PropertyMigration("letterheads are uppercase") { value in
            guard let text = value.stringValue else { throw NotText() }
            value = .string(text.uppercased())
        },
    ]
}

private struct NotText: Error {}

@MainActor private func office() -> Contributor {
    Contributor(id: "office") { r in
        r.declare(file: Signatories.self)
        r.declare(file: Founded.self)
    }
}

/// Boxes and pockets, with the letterhead, the signatories and the founding date.
@MainActor private func registry() throws -> Registry {
    try Registry(plugins: [FixturesPlugin(), PocketsPlugin(), LetterheadPlugin(), office()])
}

/// The same, with the letterhead a version on.
@MainActor private func loudRegistry() throws -> Registry {
    try Registry(plugins: [FixturesPlugin(), PocketsPlugin(), Contributor(id: "loud") { $0.declare(file: LoudLetterhead.self) }, office()])
}

private func id(_ n: Int) -> ShapeID { ShapeID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!) }
private func box(_ n: Int) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id(n), Box(CGRect(x: 0, y: 0, width: 10, height: 10)))) }
private func pocket(_ n: Int) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id(n), Pocket(CGRect(x: 0, y: 0, width: 10, height: 10)))) }
private func board(_ records: AnyShapeRecord...) -> CanvasDocument { CanvasDocument(shapes: records) }
private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

/// JSON as the codec writes it: sorted, pretty-printed.
private func written(_ json: JSONValue) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(json)
}

private func parsed(_ data: Data) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: data) }

/// A format-6 file of one box, with these entries as its `values`.
private func file(values: String, format: Int = 6) -> Data {
    Data(#"""
    { "format" : \#(format), "versions" : { "kinds" : { "box" : 0 } }, "values" : \#(values),
      "shapes" : [ { "id" : "\#(id(1))", "index" : "a0", "kind" : "box", "props" : { "frame" : [[0, 0], [10, 10]] } } ] }
    """#.utf8)
}

/// Why the file won't open; nil if it does.
private func refusal(_ codec: BoardCodec, _ data: Data) -> BoardReadError? {
    do {
        _ = try codec.decode(data)
        return nil
    } catch {
        return error
    }
}

@MainActor let fileValueCodecTests = Suite("File values on disk", [
    test("a file's values are in the envelope, by key, each with its version, at format 6") {
        var file = CanvasFile(root: board(box(1)))
        file[Letterhead.self] = "Acme"
        file[Signatories.self] = [Signatory(name: "Ann", title: "Chair")]
        expectEqual(BoardCodec.format, 6)
        expectEqual(text(try BoardCodec(registry: try registry()).encode(file)), """
        {
          "format" : 6,
          "shapes" : [
            {
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
          "values" : {
            "letterhead" : {
              "v" : 0,
              "value" : "Acme"
            },
            "signatories" : {
              "v" : 0,
              "value" : [
                {
                  "name" : "Ann",
                  "title" : "Chair"
                }
              ]
            }
          },
          "versions" : {
            "kinds" : {
              "box" : 0
            }
          }
        }
        """)
    },
    test("a file reads back its values as they were, whatever boards it has, with nothing to report") {
        let codec = BoardCodec(registry: try registry())
        var file = CanvasFile(root: board(box(1), pocket(10)), children: [id(10): board(box(2))])
        file[Letterhead.self] = "Acme"
        file[Signatories.self] = [Signatory(name: "Ann", title: "Chair"), Signatory(name: "Bo", title: "Clerk")]
        file[Founded.self] = Date(timeIntervalSince1970: 1_700_000_000)
        let data = try codec.encode(file)
        expect(text(data).contains(#""format" : 6"#))
        expect(text(data).contains(#""value" : "2023-11-14T22:13:20Z""#), "a date as a board writes one")
        let loaded = try codec.decode(data)
        expectEqual(loaded.file, file)
        expectEqual(loaded.file[Letterhead.self], "Acme")
        expectEqual(loaded.file[Signatories.self].map(\.name), ["Ann", "Bo"])
        expectEqual(loaded.file[Founded.self], Date(timeIntervalSince1970: 1_700_000_000))
        expectEqual(loaded.file.fileValueKeys, ["founded", "letterhead", "signatories"])
        expect(loaded.report.isEmpty, "\(loaded.report)")
        expectEqual(try codec.encode(loaded.file), data)
    },
    test("a file with no value is written as it always was, byte for byte, in the format it had") {
        let codec = BoardCodec(registry: try registry())
        let plain = CanvasFile(root: board(box(1)))
        let nested = CanvasFile(root: board(box(1), pocket(10)), children: [id(10): board(box(2))])
        // As the registry without any file property writes them.
        let before = BoardCodec(registry: try Registry(plugins: [FixturesPlugin(), PocketsPlugin()]))
        for (file, format) in [(plain, 1), (nested, 4)] {
            let data = try codec.encode(file)
            expectEqual(data, try before.encode(file))
            expect(text(data).contains(#""format" : \#(format)"#), text(data))
            expect(!text(data).contains("values"))
            var headed = file
            headed[Letterhead.self] = "Acme"
            expect(text(try codec.encode(headed)).contains(#""format" : 6"#), "only a file with a value needs the format")
            headed[Letterhead.self] = ""
            expectEqual(try codec.encode(headed), data, "set back to its default, it's off the file")
        }
        expectEqual(try codec.encode(plain), try codec.encode(plain.root), "and a file of the root alone is its board")
    },
    test("an editor's file with a value saves and reads back, and undone it saves as it did before") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin(), LetterheadPlugin(), office()],
                                  file: CanvasFile(root: board(box(1), pocket(10)), children: [id(10): board(box(2))]))
        let codec = BoardCodec(registry: h.editor.registry)
        let before = try codec.encode(h.file)
        h.editor.transact("Head File") { transaction in
            transaction.setFileValue(Letterhead.self, to: "Acme")
            transaction.setFileValue(Signatories.self, to: [Signatory(name: "Ann", title: "Chair")])
        }
        let loaded = try codec.decode(try codec.encode(h.file))
        expectEqual(loaded.file, h.file)
        expect(loaded.report.isEmpty, "\(loaded.report)")
        h.editor.replaceFile(with: loaded.file)
        expectEqual(h.editor.file[Signatories.self], [Signatory(name: "Ann", title: "Chair")])
        h.editor.transact("Head File") { $0.setFileValue(Letterhead.self, to: "Apex") }
        h.editor.undo()
        expectEqual(try codec.encode(h.file), try codec.encode(loaded.file))
        h.editor.transact("Clear") { transaction in
            transaction.setFileValue(Letterhead.self, to: "")
            transaction.setFileValue(Signatories.self, to: [])
        }
        expectEqual(try codec.encode(h.file), before, "with none again, byte for byte")
    },
    test("values the app can't use are kept whole, reported, read as their defaults, and written back as they were") {
        let codec = BoardCodec(registry: try registry())
        var headed = CanvasFile(root: board(box(1)))
        headed[Signatories.self] = [Signatory(name: "Ann", title: "Chair")]
        var json = try parsed(try codec.encode(headed))
        var values = try require(json["values"])
        values["confetti"] = ["v": 2, "value": ["velocity": 240]]         // no plugin declares it
        values["letterhead"] = ["v": 3, "value": ["text": "ACME"]]        // from a newer version
        values["founded"] = ["v": 0, "value": 12]                         // not a date
        values["stamp"] = "long ago"                                      // not a value with its version
        json["values"] = values
        let data = try written(json)
        let loaded = try codec.decode(data)
        expectEqual(loaded.report.keptFileValues.map(\.key), ["confetti", "founded", "letterhead", "stamp"])
        expectEqual(loaded.report.keptFileValues[0].reason, .notDeclared)
        guard case .unreadable(let why) = loaded.report.keptFileValues[1].reason else { throw RequireFailed() }
        expect(why.contains("founded"), why)
        expectEqual(loaded.report.keptFileValues[2].reason, .newerVersion(file: 3, app: 0))
        expectEqual(loaded.report.keptFileValues[3].reason, .unreadable("it isn't a value with its version"))
        expect(!loaded.report.isEmpty)
        expect(loaded.report.keptAside.isEmpty && loaded.report.keptValues.isEmpty && loaded.report.repairs.isEmpty, "nothing else is touched")
        expectEqual(loaded.file.keptFileValues, ["confetti", "founded", "letterhead", "stamp"])
        expectEqual(loaded.file.fileValueKeys, ["signatories"], "what it can use, it does")
        expectEqual(loaded.file[Signatories.self], [Signatory(name: "Ann", title: "Chair")])
        expectEqual(loaded.file[Letterhead.self], "", "one kept aside reads as the default")
        expectEqual(loaded.file[Founded.self], nil)
        expectEqual(try codec.encode(loaded.file), data, "written back as read")

        // One kept aside takes no write, in an editor or out of one; the rest do, and the kept go on being saved.
        var file = loaded.file
        file[Letterhead.self] = "Apex"
        expectEqual(file, loaded.file)
        let h = try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin(), LetterheadPlugin(), office()], file: loaded.file)
        h.editor.transact { $0.setFileValue(Letterhead.self, to: "Apex") }
        expect(!h.editor.canUndo, "nothing committed")
        h.editor.transact { $0.setFileValue(Signatories.self, to: []) }
        expectEqual(h.file.keptFileValues, ["confetti", "founded", "letterhead", "stamp"])
        var expected = json
        expected["values"]?["signatories"] = JSONValue?.none
        expectEqual(try codec.encode(h.file), try written(expected))
        h.editor.undo()
        expectEqual(try codec.encode(h.file), data)
    },
    test("a value from an older version of its property goes through its migrations, and is saved at today's") {
        let codec = BoardCodec(registry: try loudRegistry())
        let old = try codec.decode(file(values: #"{ "letterhead" : { "v" : 0, "value" : "Acme" } }"#))
        expectEqual(old.file[LoudLetterhead.self], "ACME")
        expect(old.report.isEmpty, "\(old.report)")
        let saved = try parsed(try codec.encode(old.file))
        expectEqual(saved["values"], ["letterhead": ["v": 1, "value": "ACME"]])
        let current = try codec.decode(file(values: #"{ "letterhead" : { "v" : 1, "value" : "Quiet" } }"#))
        expectEqual(current.file[LoudLetterhead.self], "Quiet", "today's version is read as written")
        // A migration that fails keeps the value as it was.
        let data = file(values: #"{ "letterhead" : { "v" : 0, "value" : 12 } }"#)
        let failed = try codec.decode(data)
        guard case .unreadable(let why)? = failed.report.keptFileValues.first?.reason else { throw RequireFailed() }
        expect(why.contains("letterheads are uppercase"), why)
        expectEqual(failed.file.keptFileValues, ["letterhead"])
        expectEqual(try parsed(try codec.encode(failed.file))["values"], try parsed(data)["values"])
        // The app that doesn't have the step yet keeps what the newer one wrote.
        let older = try BoardCodec(registry: try registry()).decode(try codec.encode(old.file))
        expectEqual(older.report.keptFileValues, [LoadReport.KeptFileValue(key: "letterhead", reason: .newerVersion(file: 1, app: 0))])
    },
    test("a default or a null in the file is no value; values that aren't an object refuse the file; an older format's aren't read") {
        let codec = BoardCodec(registry: try registry())
        let defaults = try codec.decode(file(values: #"{ "letterhead" : { "v" : 0, "value" : "" }, "signatories" : { "v" : 0, "value" : null } }"#))
        expectEqual(defaults.file.fileValueKeys, [])
        expectEqual(defaults.file.keptFileValues, [])
        expect(defaults.report.isEmpty, "\(defaults.report)")
        expectEqual(defaults.file, CanvasFile(root: defaults.document))
        expectEqual(refusal(codec, file(values: "[]")), .unreadable("its values aren’t an object"))
        let older = try codec.decode(file(values: #"{ "letterhead" : { "v" : 0, "value" : "Acme" } }"#, format: 5))
        expectEqual(older.file[Letterhead.self], "")
        expectEqual(older.file.keptFileValues, [])
        expectEqual(refusal(codec, file(values: "{ }", format: BoardCodec.format + 1)), .newerFormat(BoardCodec.format + 1))
    },
])
