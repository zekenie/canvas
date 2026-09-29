import Canvas
import CanvasTesting
import Foundation
import Queries
import QueryLanguage
import TestKit
import Topology

// Containment, answered: what's on the board of what, at any depth or directly, from either side;
// the top board and the board shown; and what the answer refuses once it has the file: a name no
// shape has, an id no shape the app can show has (gone, kept aside, on a board it can't show), and a
// name standing where a container goes whose shapes hold no board.

@MainActor let containmentTests = Suite("Containment", [
    test("a space, >, :inside, :has and :has(>), on the shelf") {
        // The shelf: chore 1 "Alpha", pocket 2 "Pantry" holding chore 11 "Beta" and pocket 12, which
        // holds chore 21 and tile 22 "Tiled"; links 3 and 4 on the top board.
        let h = try shelf()
        expectMatches([
            #""Pantry" > *"#: [11, 12],
            #""Pantry" *"#: [11, 12, 21, 22],
            "pocket > chore": [11, 21],
            "pocket chore": [11, 21],
            "pocket pocket > *": [21, 22],
            #""Pantry" > pocket > tile"#: [22],
            #""Pantry" > tile"#: [],
            #":inside("Pantry")"#: [11, 12, 21, 22],
            "chore:inside(pocket)": [11, 21],
            #""Beta":inside(*)"#: [11],
            #""Alpha":inside(*)"#: [],
            ":not(:inside(*))": [1, 2, 3, 4],
            "pocket:has(chore)": [2, 12],
            "pocket:has(> tile)": [12],
            #":has(> "Beta")"#: [2],
            #":has("Tiled")"#: [2, 12],
            #""Pantry":has(> "Tiled")"#: [],
            #""Pantry":has("Tiled")"#: [2],
            "pocket:has(> chore, > tile)": [2, 12],
            ":has(*)": [2, 12],
            ":not(:has(*))": [1, 11, 21, 22, 3, 4],
        ], on: h)
    },
    test("from either side: the same answer among a few candidates as among every shape") {
        let h = try shelf()
        // Narrowed by an id first, then by containment; and containment first, over every shape.
        expectMatches([
            "#\(uuid(21)):inside(pocket)": [21],
            "#\(uuid(21)):inside(#\(uuid(2)))": [21],
            "#\(uuid(11)):inside(#\(uuid(12)))": [],
            "#\(uuid(12)):has(> tile)": [12],
            "#\(uuid(2)):has(> tile)": [],
            "#\(uuid(22))[caption=Tiled]:inside(pocket)": [22],
            ":is(#\(uuid(21)), #\(uuid(1))):top-level": [1],
            ":is(#\(uuid(2)), #\(uuid(12))) > *": [11, 12, 21, 22],
            "pocket > :is(#\(uuid(21)), #\(uuid(11)))": [11, 21],
        ], on: h)
    },
    test("the top board, and the board shown as the query takes up the file") {
        let h = try shelf()
        expectMatches([
            ":top-level": [1, 2, 3, 4],
            "chore:top-level": [1],
            ":current-board": [1, 2, 3, 4],
        ], on: h)
        expect(h.enter(id(2)))
        expectMatches([
            ":current-board": [11, 12],
            ":top-level": [1, 2, 3, 4],
            ":not(:current-board):not(:top-level)": [21, 22],
            "*": [1, 2, 11, 12, 21, 22, 3, 4],
        ], on: h)
    },
    test("a name no shape has is refused, with the names it may have meant") {
        let h = try shelf()
        let refused = try require(refusedAnswer(#""Alpah" *"#, on: h))
        expectEqual(refused.reason, .unknownTitle)
        expectEqual(refused.message, "No shape is titled Alpah.")
        expectEqual(refused.hint, #"Did you mean "Alpha"?"#)
        expectEqual(refused.span, QuerySpan(offset: 0, length: 7))
        let differentCase = try require(refusedAnswer(#""alpha""#, on: h))
        expectEqual(differentCase.hint, #"Did you mean "Alpha"?"#, "names are matched as written: case counts")
        // Every one, in the order they're written, with ids beside them.
        let several = try require(refusedAnswer(#":inside("Nope"), #\#(uuid(99)), "Zilch""#, on: h))
        expectEqual(several.errors.map(\.reason), [.unknownTitle, .unknownID, .unknownTitle])
        expectEqual(several.errors.map(\.span?.offset), [8, 17, 56])
        // A derived name is a name.
        expectEqual(try matched(#""Tiled""#, on: h), [id(22)])
        // Asking whether a name is anyone's, without a refusal, is [caption="…"]: 0 is an answer.
        let asked = try answer(#"[caption="Alpah"]"#, on: h)
        expectEqual(asked.count, 0)
        expectEqual(asked.warnings.map(\.reason), [.noTitleMatch])
    },
    test("an id no shape the app can show has: gone, kept aside, or on a board it can't show") {
        let h = try hiddenShelf()
        let gone = try require(refusedAnswer("#\(uuid(99))", on: h))
        expectEqual(gone.reason, .unknownID)
        expectEqual(gone.message, "No shape the app can show has that id: it may have been deleted.")
        expectEqual(gone.hint, "Run the query that gave it again.")
        expectEqual(gone.span, QuerySpan(offset: 0, length: 37))
        let keptAside = try require(refusedAnswer("#\(uuid(10))", on: h))
        expectEqual(keptAside.reason, .unknownID)
        expectEqual(keptAside.message, "That shape is kept aside: the app can't read it.")
        let hidden = try require(refusedAnswer("chore:inside(#\(uuid(20))) , #\(uuid(11))", on: h))
        expectEqual(hidden.errors.map(\.message), ["That shape is kept aside: the app can't read it.",
                                                   "That shape is on a board the app can't show."])
        expectEqual(try matched("#\(uuid(1))", on: h), [id(1)])
    },
    test("a name where a container goes, whose shapes hold no board, is refused once they're found") {
        let h = try shelf()
        let refusals: [(String, String, QuerySpan)] = [
            (#""Alpha" *"#, "Alpha is a chore, which holds no board: nothing is inside it.", QuerySpan(offset: 0, length: 7)),
            (#"chore:inside("Tiled")"#, "Tiled is a tile, which holds no board: nothing is inside it.", QuerySpan(offset: 13, length: 7)),
            (#""Beta":has(*)"#, "Beta is a chore, which holds no board: nothing is inside it.", QuerySpan(offset: 0, length: 6)),
            (#""Beta" > tile"#, "Beta is a chore, which holds no board: nothing is inside it.", QuerySpan(offset: 0, length: 6)),
            // Through :is and :where, whose items are where a container goes too.
            (#":is("Alpha") *"#, "Alpha is a chore, which holds no board: nothing is inside it.", QuerySpan(offset: 4, length: 7)),
            (#"chore:inside(:is("Tiled"))"#, "Tiled is a tile, which holds no board: nothing is inside it.", QuerySpan(offset: 17, length: 7)),
            (#":where("Beta") > tile"#, "Beta is a chore, which holds no board: nothing is inside it.", QuerySpan(offset: 7, length: 6)),
            (#":is("Beta"):has(*)"#, "Beta is a chore, which holds no board: nothing is inside it.", QuerySpan(offset: 4, length: 6)),
        ]
        for (text, message, span) in refusals {
            let refused = try require(refusedAnswer(text, on: h), text)
            expectEqual(refused.reason, .cannotContain, text)
            expectEqual(refused.message, message + " Being drawn within its bounds isn't something a query can ask yet.", text)
            expectEqual(refused.hint, "The kinds that hold boards: pocket.", text)
            expectEqual(refused.span, span, text)
        }
        // Where a name isn't a container's, nothing is refused.
        expectMatches([#""Alpha", "Beta""#: [1, 11], #":not("Alpha")"#: [2, 11, 12, 21, 22, 3, 4]], on: h)
        // A name some container has is fine, whatever else has it too.
        h.editor.transact { $0.update(id(1)) { $0[Caption.self] = "Pantry" } }
        expectMatches([#""Pantry" > *"#: [11, 12], #""Pantry""#: [1, 2]], on: h)
        // An untitled pocket's board holds shapes too.
        expectMatches(["pocket:not([caption]) > *": [21, 22]], on: h)
    },
])
