@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

/// A remark on a shape: an added property only the shapes it's set on have.
enum Remark {}
extension Remark: ShapeProperty {
    static let key: PropertyKey = "remark"
    static var defaultValue: String? { nil }
}

/// Boxes, discs, tags, tickets and remarks; with pockets, which own boards, unless `pockets` is false.
@MainActor private func registry(pockets: Bool = true) throws -> Registry {
    let plugins: [any CanvasPlugin] = [FixturesPlugin(), Contributor(id: "tickets") { $0.shape(TicketDefinition()) }]
    return try Registry(plugins: plugins + (pockets ? [PocketsPlugin()] : []) + [Contributor(id: "remarks") { r in
        r.declare(Remark.self)
        r.optIn(Box.self, to: Remark.self)
        if pockets { r.optIn(Pocket.self, to: Remark.self) }
    }])
}

@MainActor private func codec(pockets: Bool = true) throws -> BoardCodec { BoardCodec(registry: try registry(pockets: pockets)) }

private func id(_ n: Int) -> ShapeID { ShapeID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!) }

private func box(_ n: Int, remark: String? = nil) -> AnyShapeRecord {
    var record = AnyShapeRecord(ShapeRecord(id: id(n), Box(CGRect(x: n, y: 0, width: 10, height: 10))))
    record[Remark.self] = remark
    return record
}

private func pocket(_ n: Int, remark: String? = nil) -> AnyShapeRecord {
    var record = AnyShapeRecord(ShapeRecord(id: id(n), Pocket(CGRect(x: n, y: 0, width: 40, height: 30))))
    record[Remark.self] = remark
    return record
}

/// Why the file won't open; nil if it does.
@MainActor private func refusal(_ json: String) -> BoardReadError? {
    do {
        _ = try codec().decode(Data(json.utf8))
        return nil
    } catch {
        return error as? BoardReadError
    }
}

private func board(_ records: AnyShapeRecord...) -> CanvasDocument { CanvasDocument(shapes: records) }

private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

/// A format-4 file's JSON with this root and these boards (records already JSON), at today's versions.
private func file(_ root: [String], boards: [(Int, [String])]) -> String {
    let entries = boards.map { #""\#(id($0.0))" : { "shapes" : [\#($0.1.joined(separator: ", "))] }"# }
    return #"{ "format" : 4, "versions" : { "kinds" : { "box" : 0, "pocket" : 0 } }, "shapes" : [\#(root.joined(separator: ", "))], "boards" : { \#(entries.joined(separator: ", ")) } }"#
}

private func record(_ n: Int, _ kind: String, _ index: String) -> String {
    #"{ "id" : "\#(id(n))", "kind" : "\#(kind)", "index" : "\#(index)", "props" : { "frame" : [[0, 0], [10, 10]] } }"#
}

/// JSON as the codec writes it: sorted, pretty-printed.
private func written(_ json: JSONValue) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(json)
}

/// A reproducible stream of choices for the fuzz test.
private struct Mutations: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 11 | state << 53
    }
}

@MainActor let boardCodecFileTests = Suite("Boards on disk", [
    test("a file of the root alone is written as its board always was") {
        let codec = try codec()
        let plain = board(box(1), box(2))
        let remarked = board(box(1, remark: "Hi"), pocket(2))
        for document in [plain, remarked] {
            expectEqual(text(try codec.encode(CanvasFile(root: document))), text(try codec.encode(document)))
        }
        expect(text(try codec.encode(CanvasFile(root: plain))).contains(#""format" : 1"#))
        expect(text(try codec.encode(CanvasFile(root: remarked))).contains(#""format" : 3"#))
        expect(!text(try codec.encode(CanvasFile(root: remarked))).contains("boards"))
    },
    test("a subboard of a subboard is written at format 4, every board in one flat map") {
        let ticket = AnyShapeRecord(ShapeRecord(id: id(3), Ticket(frame: CGRect(x: 0, y: 0, width: 5, height: 5), title: "Inside", done: false)))
        let file = CanvasFile(root: board(box(1), pocket(10, remark: "Plan")),
                              children: [id(10): board(ticket, pocket(11, remark: "Q3")), id(11): board(box(2))])
        expectEqual(text(try codec().encode(file)), """
        {
          "boards" : {
            "00000000-0000-0000-0000-000000000010" : {
              "shapes" : [
                {
                  "id" : "00000000-0000-0000-0000-000000000003",
                  "index" : "a0",
                  "kind" : "ticket",
                  "props" : {
                    "done" : false,
                    "frame" : [
                      [
                        0,
                        0
                      ],
                      [
                        5,
                        5
                      ]
                    ],
                    "title" : "Inside"
                  }
                },
                {
                  "added" : {
                    "remark" : "Q3"
                  },
                  "id" : "00000000-0000-0000-0000-000000000011",
                  "index" : "a1",
                  "kind" : "pocket",
                  "props" : {
                    "frame" : [
                      [
                        11,
                        0
                      ],
                      [
                        40,
                        30
                      ]
                    ]
                  }
                }
              ]
            },
            "00000000-0000-0000-0000-000000000011" : {
              "shapes" : [
                {
                  "id" : "00000000-0000-0000-0000-000000000002",
                  "index" : "a0",
                  "kind" : "box",
                  "props" : {
                    "frame" : [
                      [
                        2,
                        0
                      ],
                      [
                        10,
                        10
                      ]
                    ]
                  }
                }
              ]
            }
          },
          "format" : 4,
          "shapes" : [
            {
              "id" : "00000000-0000-0000-0000-000000000001",
              "index" : "a0",
              "kind" : "box",
              "props" : {
                "frame" : [
                  [
                    1,
                    0
                  ],
                  [
                    10,
                    10
                  ]
                ]
              }
            },
            {
              "added" : {
                "remark" : "Plan"
              },
              "id" : "00000000-0000-0000-0000-000000000010",
              "index" : "a1",
              "kind" : "pocket",
              "props" : {
                "frame" : [
                  [
                    10,
                    0
                  ],
                  [
                    40,
                    30
                  ]
                ]
              }
            }
          ],
          "versions" : {
            "added" : {
              "remark" : 0
            },
            "kinds" : {
              "box" : 0,
              "pocket" : 0,
              "ticket" : 2
            }
          }
        }
        """)
    },
    test("a file reads back as the boards it was, with nothing to report") {
        let codec = try codec()
        let file = CanvasFile(root: board(box(1), pocket(10)),
                              children: [id(10): board(box(2, remark: "In"), pocket(11)), id(11): board(box(3))])
        let loaded = try codec.decode(try codec.encode(file))
        expectEqual(loaded.file, file)
        expectEqual(loaded.document, file.root)
        expect(loaded.report.isEmpty, "\(loaded.report)")
        expectEqual(loaded.file.path(to: BoardID(owner: id(11))), [.root, BoardID(owner: id(10)), BoardID(owner: id(11))])
    },
    test("a file whose other boards have emptied is written as the root alone, in the format that holds it") {
        let codec = try codec()
        var file = CanvasFile(root: board(box(1, remark: "Hi"), pocket(10)), children: [id(10): board(box(2))])
        expect(text(try codec.encode(file)).contains(#""format" : 4"#))
        file.set(CanvasDocument(), for: BoardID(owner: id(10)))
        expectEqual(text(try codec.encode(file)), text(try codec.encode(file.root)))
        expect(text(try codec.encode(file)).contains(#""format" : 3"#))
    },
    test("format 4 reads, a newer format doesn't, and an older one's boards aren't read") {
        let json = file([record(1, "box", "a0"), record(10, "pocket", "a1")], boards: [(10, [record(2, "box", "a0")])])
        let codec = try codec()
        let loaded = try codec.decode(Data(json.utf8))
        expectEqual(loaded.file[BoardID(owner: id(10))].shapes.map(\.id), [id(2)])
        expect(loaded.report.isEmpty, "\(loaded.report)")
        let newer = BoardCodec.format + 1
        expectEqual(refusal(json.replacingOccurrences(of: #""format" : 4"#, with: #""format" : \#(newer)"#)), .newerFormat(newer))
        let older = try codec.decode(Data(json.replacingOccurrences(of: #""format" : 4"#, with: #""format" : 3"#).utf8))
        expectEqual(older.file.children, [:])
        expectEqual(older.document.shapes.map(\.id), [id(1), id(10)])
        let notAMap = json.replacingOccurrences(of: #""boards" : {"#, with: #""boards" : [], "was" : {"#)
        guard case .unreadable? = refusal(notAMap) else { expect(false, "boards that aren't an object make a file that isn't one"); return }
    },
    test("an id on two boards is kept by the first in tree order, with the board it owns; the other gets a new one") {
        // The root holds pocket 10 and box 5; 10's board holds pocket 11 and pocket 5 (a repeat);
        // an orphan board, 1, holds pocket 11 again. Board 5 is the root box's, which owns none.
        let json = file([record(10, "pocket", "a0"), record(5, "box", "a1")], boards: [
            (1, [record(11, "pocket", "a0")]),
            (5, [record(7, "box", "a0")]),
            (10, [record(11, "pocket", "a0"), record(5, "pocket", "a1")]),
            (11, [record(6, "box", "a0")]),
        ])
        let loaded = try codec().decode(Data(json.utf8))
        let file = loaded.file
        expectEqual(file.board(containing: id(5)), .root)
        expectEqual(file.record(id(5))?.kind, Box.kind)
        expectEqual(file.board(containing: id(11)), BoardID(owner: id(10)), "reached from the root before the orphan, whose key comes first")
        expectEqual(file.path(to: BoardID(owner: id(11))), [.root, BoardID(owner: id(10)), BoardID(owner: id(11))])
        expectEqual(file[BoardID(owner: id(11))].shapes.map(\.id), [id(6)])
        expectEqual(file[BoardID(owner: id(5))].shapes.map(\.id), [id(7)])
        let renamed = loaded.report.repairs.compactMap { repair -> ShapeID? in
            if case .newID(let old?, _) = repair { old } else { nil }
        }
        expectEqual(renamed, [id(5), id(11)])
        expectEqual(file[BoardID(owner: id(10))].shapes.count, 2)
        expectEqual(file[BoardID(owner: id(1))].shapes.count, 1)
        expectEqual(loaded.report.keptBoards, [
            LoadReport.KeptBoard(key: id(5).description, shapeCount: 1, reason: .ownerNotABoard(Box.kind)),
            LoadReport.KeptBoard(key: id(1).description, shapeCount: 1, reason: .unreachable),
        ])
        expectEqual(file.shapeCount, 7)
    },
    test("boards no shape reaches, and boards whose owners hold each other, are kept and written back byte for byte") {
        let codec = try codec()
        // Orphan 20 holds pocket 21, whose board holds a box; 22 and 23 hold each other's owners.
        let file = CanvasFile(root: board(box(1)), children: [
            id(20): board(box(2), pocket(21)), id(21): board(box(3)),
            id(22): board(pocket(23)), id(23): board(pocket(22)),
        ])
        let data = try codec.encode(file)
        let loaded = try codec.decode(data)
        expectEqual(loaded.file, file)
        expectEqual(loaded.report.keptBoards, [
            LoadReport.KeptBoard(key: id(20).description, shapeCount: 2, reason: .unreachable),
            LoadReport.KeptBoard(key: id(21).description, shapeCount: 1, reason: .unreachable),
            LoadReport.KeptBoard(key: id(22).description, shapeCount: 1, reason: .unreachable),
            LoadReport.KeptBoard(key: id(23).description, shapeCount: 1, reason: .unreachable),
        ])
        expect(loaded.report.repairs.isEmpty && loaded.report.keptAside.isEmpty)
        expectEqual(text(try codec.encode(loaded.file)), text(data))
    },
    test("a board whose owner is kept aside or owns none is kept, with the boards under it, and written back byte for byte") {
        // Without pockets installed, every pocket is kept aside, and so is each one's board.
        let nest = CanvasFile(root: board(box(1), pocket(10, remark: "Plan")),
                              children: [id(10): board(box(2), pocket(11)), id(11): board(box(3))])
        let data = try codec().encode(nest)
        let loaded = try codec(pockets: false).decode(data)
        expectEqual(loaded.report.keptBoards, [
            LoadReport.KeptBoard(key: id(10).description, shapeCount: 2, reason: .ownerKeptAside(Pocket.kind)),
            LoadReport.KeptBoard(key: id(11).description, shapeCount: 1, reason: .ownerKeptAside(Pocket.kind)),
        ])
        expectEqual(loaded.report.keptAside, [
            LoadReport.KeptShape(id: id(10), kind: Pocket.kind, reason: .unknownKind),
            LoadReport.KeptShape(id: id(11), kind: Pocket.kind, reason: .unknownKind, board: BoardID(owner: id(10))),
        ])
        expectEqual(loaded.file[BoardID(owner: id(11))].shapes.map(\.id), [id(3)])
        // Saved by this app, the pockets are written as shapes kept aside are, and that's written
        // back byte for byte; an app with pockets reads every board back.
        let saved = try codec(pockets: false).encode(loaded.file)
        expectEqual(text(try codec(pockets: false).encode(try codec(pockets: false).decode(saved).file)), text(saved))
        expectEqual(try codec().decode(saved).file, nest)

        // A board under a box, which owns none, and the board of a pocket on it.
        let odd = CanvasFile(root: board(box(1)), children: [id(1): board(pocket(12)), id(12): board(box(4))])
        let oddData = try codec().encode(odd)
        let oddLoaded = try codec().decode(oddData)
        expectEqual(oddLoaded.report.keptBoards, [
            LoadReport.KeptBoard(key: id(1).description, shapeCount: 1, reason: .ownerNotABoard(Box.kind)),
            LoadReport.KeptBoard(key: id(12).description, shapeCount: 1, reason: .insideKeptBoard),
        ])
        expectEqual(oddLoaded.file, odd)
        expectEqual(text(try codec().encode(oddLoaded.file)), text(oddData))
    },
    test("an entry of boards that isn't a board is kept as it was, until a board takes its key") {
        let codec = try codec()
        // An id, but not as this app writes one.
        let lowercase = "abcdef00-0000-0000-0000-000000000012"
        let data = try codec.encode(CanvasFile(root: board(pocket(10), pocket(11)), children: [id(10): board(box(2))]))
        var json = try JSONDecoder().decode(JSONValue.self, from: data)
        var boards = json["boards"]?.objectValue ?? [:]
        boards["nope"] = .number(42)
        boards[id(11).description] = .object(["shapes": .string("lost")])
        boards[lowercase] = .object(["shapes": .array([])])
        json["boards"] = .object(boards)
        let unusual = try written(json)
        let loaded = try codec.decode(unusual)
        expectEqual(loaded.file.unreadableBoards, [
            "nope": .number(42),
            id(11).description: .object(["shapes": .string("lost")]),
            lowercase: .object(["shapes": .array([])]),
        ])
        expectEqual(loaded.report.keptBoards.map(\.key), [id(11).description, lowercase, "nope"])
        for kept in loaded.report.keptBoards {
            guard case .unreadable(let why) = kept.reason else { expect(false, "\(kept) is unreadable"); continue }
            expect(!why.isEmpty)
            expectEqual(kept.shapeCount, 0)
        }
        expectEqual(loaded.file.children.keys.map { $0 }, [id(10)])
        expectEqual(text(try codec.encode(loaded.file)), text(unusual))
        expectEqual(try codec.decode(try codec.encode(loaded.file)).file, loaded.file)

        // Once pocket 11's board has shapes, it's written under that key.
        var file = loaded.file
        file.set(board(box(3)), for: BoardID(owner: id(11)))
        expectEqual(file.unreadableBoards.count, 2)
        let reread = try codec.decode(try codec.encode(file))
        expectEqual(reread.file[BoardID(owner: id(11))].shapes.map(\.id), [id(3)])
        expectEqual(reread.file, file)
    },
    test("an entry of boards that isn't a board, and can't be kept as it was, stops the file opening, so a save can't lose it") {
        let json = file([record(10, "pocket", "a0")], boards: [(10, [record(2, "box", "a0")])])
        let huge = json.replacingOccurrences(of: #""boards" : {"#, with: #""boards" : { "nope" : { "a" : 1e400, "b" : [1, 2] },"#)
        guard case .unreadable(let why)? = refusal(huge) else { expect(false, "refused"); return }
        expect(why.contains("boards.nope"), why)
        let fine = json.replacingOccurrences(of: #""boards" : {"#, with: #""boards" : { "nope" : { "a" : 1e300, "b" : [1, 2] },"#)
        expectEqual(refusal(fine), nil, "one it can keep is kept")
    },
    test("shapes and values kept aside on other boards say which board they're on") {
        let json = file([record(10, "pocket", "a0")], boards: [(10, [
            record(2, "gadget", "a0"),
            #"{ "id" : "\#(id(3))", "kind" : "box", "index" : "a1", "props" : { "frame" : [[0, 0], [1, 1]] }, "added" : { "confetti" : 1 } }"#,
        ])])
        let loaded = try codec().decode(Data(json.utf8))
        let inside = BoardID(owner: id(10))
        expectEqual(loaded.report.keptAside, [LoadReport.KeptShape(id: id(2), kind: "gadget", reason: .unknownKind, board: inside)])
        expectEqual(loaded.report.keptValues, [LoadReport.KeptValue(id: id(3), kind: Box.kind, key: "confetti", reason: .notDeclared, board: inside)])
        expect(loaded.report.keptBoards.isEmpty, "the board itself can be shown")
        expectEqual(LoadReport.KeptShape(id: id(2), kind: "gadget", reason: .unknownKind),
                    LoadReport.KeptShape(id: id(2), kind: "gadget", reason: .unknownKind, board: .root))
    },
    test("a chain of boards a thousand deep reads and writes, its file no deeper than a board's") {
        let codec = try codec()
        let count = 1000
        var children: [ShapeID: CanvasDocument] = [:]
        for n in 1...count { children[id(n)] = board(n < count ? pocket(n + 1) : box(0)) }
        let file = CanvasFile(root: board(pocket(1)), children: children)
        let loaded = try codec.decode(try codec.encode(file))
        expectEqual(loaded.file, file)
        expect(loaded.report.isEmpty)
        expectEqual(loaded.file.path(to: BoardID(owner: id(count)))?.count, count + 1)
    },
    test("no truncated or scrambled file of several boards crashes the reader, and what opens saves and reopens the same") {
        let codec = try codec()
        var root: [AnyShapeRecord] = [], children: [ShapeID: CanvasDocument] = [:]
        var n = 100
        func next() -> Int { n += 1; return n }
        for i in 0..<3 {
            let outer = next(), inner = next()
            root.append(box(next(), remark: i == 0 ? "Top" : nil))
            root.append(pocket(outer, remark: "Pocket \(i)"))
            let ticket = AnyShapeRecord(ShapeRecord(id: id(next()), Ticket(frame: CGRect(x: i, y: 0, width: 5, height: 5), title: "T\(i)", done: i == 1)))
            let target = next()
            let tag = AnyShapeRecord(ShapeRecord(id: id(next()), Tag(target: id(target))))
            children[id(outer)] = board(box(target, remark: "In \(i)"), ticket, pocket(inner), tag)
            children[id(inner)] = board(box(next()), box(next()))
        }
        let good = Array(try codec.encode(CanvasFile(root: CanvasDocument(shapes: root), children: children)))
        var random = Mutations(state: 11)
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
            for board in [BoardID.root] + loaded.file.children.keys.map({ BoardID(owner: $0) }) {
                let keys = loaded.file[board].shapes.map(\.stackingKey)
                expect(keys.allSatisfy { $0 != nil })
                expectEqual(keys.compactMap { $0 }, keys.compactMap { $0 }.sorted())
            }
            let reopened = try codec.decode(try codec.encode(loaded.file))
            expectEqual(reopened.file, loaded.file)
            expect(reopened.report.repairs.isEmpty, "\(reopened.report.repairs)")
            expectEqual(reopened.report.keptBoards, loaded.report.keptBoards)
        }
        expect(opened > 0, "some mutations leave a file that opens")
    },
])
