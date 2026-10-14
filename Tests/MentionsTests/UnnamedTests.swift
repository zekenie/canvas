import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Mentions
import TestKit
import Titles

// The shapes their kind gives no name (the "Untitled …" placeholder), which the catalog keeps in a
// side table: a list that asks (`candidates(…listingUnnamed: true)`) reads them as members, after
// the named ones, and matches them by their placeholder label alone; every list that doesn't ask
// (`@`, a command's kinds, a scope) is as it was. Fixtures only.

private func frame(_ i: Int) -> CGRect { CGRect(x: i * 150, y: 0, width: 120, height: 80) }

/// A jot (the text's shape) at the origin, then along its row two untitled tokens, a titled plate
/// and an untitled plate; a pocket far off, holding an untitled token and a titled plate.
@MainActor private final class Unnamed {
    let h: EditorHarness
    let owner = ShapeID(), pocket = ShapeID()
    let near = ShapeID(), far = ShapeID(), titled = ShapeID(), plain = ShapeID()
    let inside = ShapeID(), insideTitled = ShapeID()
    var state: MentionState { h.editor.mentionState }
    var pocketBoard: BoardID { BoardID(owner: pocket) }

    init() throws {
        func token(_ id: ShapeID, _ i: Int) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Token(frame(i)))) }
        var named = ShapeRecord(id: titled, Plate(frame(3)))
        named[TitleProperty.self] = "Layer"
        var insideNamed = ShapeRecord(id: insideTitled, Plate(frame(1)))
        insideNamed[TitleProperty.self] = "Deep layer"
        let root = [AnyShapeRecord(ShapeRecord(id: owner, Jot(CGRect(x: 0, y: 0, width: 100, height: 100), text: "Mine"))),
                    token(near, 1), token(far, 5), AnyShapeRecord(named), AnyShapeRecord(ShapeRecord(id: plain, Plate(frame(4)))),
                    AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 4000, y: 4000, width: 100, height: 100))))]
        h = try EditorHarness(plugins: mentionPlugins([PocketsPlugin()]),
                              file: CanvasFile(root: CanvasDocument(shapes: root),
                                               children: [pocket: CanvasDocument(shapes: [token(inside, 0), AnyShapeRecord(insideNamed)])]))
    }

    var everyone: [ShapeID] { [near, far, titled, plain, inside, insideTitled] }

    func list(_ query: String = "", among: [ShapeID]? = nil, kinds: Set<ShapeKind>? = nil, listing: Bool = true) -> MentionCandidates {
        state.candidates(matching: query, in: AnyMentionable.self, for: owner, kinds: kinds, among: among, listingUnnamed: listing)
    }
}

/// `plates` titled "toxe 1"… and `tokens` untitled, in rows, and a jot that owns the list.
@MainActor private func crowd(plates: Int, tokens: Int) throws -> (h: EditorHarness, owner: ShapeID, named: [ShapeID], unnamed: [ShapeID]) {
    func box(_ i: Int) -> CGRect { CGRect(x: (i % 100) * 150, y: (i / 100) * 100, width: 120, height: 80) }
    let owner = ShapeID()
    var shapes = [AnyShapeRecord(ShapeRecord(id: owner, Jot(CGRect(x: -400, y: -400, width: 100, height: 100), text: "Mine")))]
    var named: [ShapeID] = [], unnamed: [ShapeID] = []
    for i in 0..<plates {
        var plate = ShapeRecord(Plate(box(i)))
        plate[TitleProperty.self] = "toxe \(i + 1)"
        named.append(plate.id)
        shapes.append(AnyShapeRecord(plate))
    }
    for i in 0..<tokens {
        let token = ShapeRecord(Token(box(plates + i)))
        unnamed.append(token.id)
        shapes.append(AnyShapeRecord(token))
    }
    let h = try EditorHarness(plugins: mentionPlugins([PocketsPlugin()]), file: CanvasFile(root: CanvasDocument(shapes: shapes)))
    return (h, owner, named, unnamed)
}

@MainActor let unnamedTests = Suite("Listing the unnamed", [
    test("an empty query lists a shape its kind gives no name when asked: the named ones first, nearest first, then the other boards'") {
        let u = try Unnamed()
        let listed = u.list(among: u.everyone)
        expectEqual(listed.nearby.map(\.id), [u.titled, u.insideTitled, u.near, u.plain, u.far, u.inside], "named, nearest first, then the unnamed: the board shown's nearest first, then the pocket's")
        expectEqual(listed.nearby.map(\.appearance.label), ["Layer", "Deep layer", "Untitled Token", "Untitled Plate", "Untitled Token", "Untitled Token"])
        expectEqual(listed.nearby.map(\.appearance.isPlaceholder), [false, false, true, true, true, true])
    },

    test("without it, the default, an unnamed shape handed in is dropped, as it was") {
        let u = try Unnamed()
        expectEqual(u.list(among: u.everyone, listing: false).nearby.map(\.id), [u.titled, u.insideTitled])
        expectEqual(u.list("untitled", among: u.everyone, listing: false).matches, [])
        expectEqual(u.list(among: [u.near, u.far], listing: false), MentionCandidates())
    },

    test("the `@` picker, a scope and a list of no shapes handed in never list one, asked or not") {
        let u = try Unnamed()
        expect(u.list(listing: false).nearby.allSatisfy { !$0.appearance.isPlaceholder })
        expect(u.list().nearby.allSatisfy { !$0.appearance.isPlaceholder }, "no `among` and no `kinds`: nothing to list them among")
        expectEqual(u.list("untitled").matches, [])
        expectEqual(u.state.candidates(matching: "", in: Starred.self, for: u.owner, listingUnnamed: true).nearby, [])
    },

    test("a typed query matches them only by their placeholder label, after the named matches") {
        let u = try Unnamed()
        expectEqual(u.list("untitled token", among: u.everyone).matches.map(\.id).count, 3)
        expectEqual(Set(u.list("untitled token", among: u.everyone).matches.map(\.id)), [u.near, u.far, u.inside])
        expectEqual(u.list("untitled plate", among: u.everyone).matches.map(\.id), [u.plain])
        expectEqual(u.list("layer", among: u.everyone).matches.map(\.id).count, 2, "the named, and no unnamed shape for a word that isn't its label")
        expectEqual(u.list("zzz", among: u.everyone).matches, [])
        let both = u.list("l", among: u.everyone).matches
        expectEqual(Array(both.prefix(2).map(\.id)), [u.titled, u.insideTitled].sorted { a, b in both.firstIndex { $0.id == a }! < both.firstIndex { $0.id == b }! })
        expectEqual(Set(both.suffix(from: 2).map(\.id)), [u.near, u.far, u.plain, u.inside], "the named first, then the unnamed")
        expect(!u.list("untitled", among: u.everyone).matches.isEmpty && u.list("untitled", among: u.everyone).matches.allSatisfy { $0.appearance.isPlaceholder })
    },

    test("kinds: asked, the unnamed of those kinds are members too, on every board; unasked, they are not") {
        let u = try Unnamed()
        expectEqual(u.list(kinds: [Token.kind]).nearby.map(\.id).count, 3)
        expectEqual(Set(u.list(kinds: [Token.kind]).nearby.map(\.id)), [u.near, u.far, u.inside])
        expectEqual(u.list(kinds: [Token.kind], listing: false).nearby, [])
        expectEqual(u.list("untitled", kinds: [Plate.kind]).matches.map(\.id), [u.plain])
        expectEqual(u.list(among: [u.near, u.plain], kinds: [Token.kind]).nearby.map(\.id), [u.near], "among and kinds: the shapes of both")
    },

    test("a recent pick of an unnamed shape is listed first, and the owner and shapes given twice once") {
        let u = try Unnamed()
        u.state.didPick(u.far)
        let listed = u.list(among: u.everyone + [u.near, u.owner])
        expectEqual(listed.recent.map(\.id), [u.far])
        expect(!listed.nearby.contains { $0.id == u.owner || $0.id == u.far })
        expectEqual(listed.nearby.filter { $0.id == u.near }.count, 1)
        expectEqual(u.list(among: u.everyone, listing: false).recent, [], "unasked, it isn't one")
    },

    test("an unnamed shape leaves the list when it is named and returns when it isn't, on any board, undo and redo too") {
        let u = try Unnamed()
        expect(u.list(among: u.everyone).nearby.contains { $0.id == u.plain })
        u.h.editor.rename(u.plain, "Named now")
        let named = u.list(among: u.everyone, listing: false).nearby
        expect(named.contains { $0.id == u.plain && !$0.appearance.isPlaceholder }, "named, it is an ordinary entry")
        expectEqual(u.list(among: u.everyone).nearby.filter { $0.id == u.plain }.count, 1)
        u.h.editor.rename(u.plain, nil)
        expect(!u.list(among: u.everyone, listing: false).nearby.contains { $0.id == u.plain })
        expect(u.list(among: u.everyone).nearby.contains { $0.id == u.plain && $0.appearance.isPlaceholder })
        u.h.editor.undo()
        expect(u.list(among: u.everyone, listing: false).nearby.contains { $0.id == u.plain }, "undo names it again")
        u.h.editor.redo()
        expect(!u.list(among: u.everyone, listing: false).nearby.contains { $0.id == u.plain })

        u.h.editor.transact(on: u.pocketBoard, "Rename") { $0.update(u.inside, as: Token.self) { $0.props.caption = "Inside" } }
        expect(u.list(among: u.everyone, listing: false).nearby.contains { $0.id == u.inside }, "named on another board")
        u.h.editor.transact(on: u.pocketBoard, "Clear") { $0.update(u.inside, as: Token.self) { $0.props.caption = "" } }
        expect(u.list(among: u.everyone).nearby.contains { $0.id == u.inside && $0.appearance.isPlaceholder })
    },

    test("a deleted unnamed shape is gone, a board deleted with its owner takes its unnamed with it, and undo brings them back") {
        let u = try Unnamed()
        u.h.editor.delete(u.far)
        expect(!u.list(among: u.everyone).nearby.contains { $0.id == u.far })
        u.h.editor.undo()
        expect(u.list(among: u.everyone).nearby.contains { $0.id == u.far })
        u.h.editor.transact { $0.delete([u.pocket]) }
        expect(!u.list(among: u.everyone).nearby.contains { $0.id == u.inside })
        u.h.editor.undo()
        expect(u.list(among: u.everyone).nearby.contains { $0.id == u.inside })
        expectEqual(u.list(among: u.everyone).nearby.count, 6)
    },

    test("a file put in place takes the side table afresh") {
        let u = try Unnamed()
        let other = ShapeID(), gone = ShapeID()
        u.h.editor.replaceFile(with: CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: other, Token(frame(0)))),
                                                                                AnyShapeRecord(ShapeRecord(id: gone, Plate(frame(1))))])))
        expectEqual(u.list(among: [u.near, other, gone]).nearby.map(\.id), [other, gone])
        expectEqual(u.list(among: [u.near, u.far, u.inside]).nearby, [])
    },

    test("a note that holds nothing is listed by the placeholder, whatever else the list is asked of: the owner's own text does not hide it") {
        let u = try Unnamed()
        let typed = u.list("untitled", among: [u.near, u.plain])
        expectEqual(Set(typed.matches.map(\.id)), [u.near, u.plain])
        expect(typed.matches.allSatisfy { !$0.matched.isEmpty })
        expectEqual(u.list(among: [u.near, u.plain]).nearby.map(\.id).first, u.near, "the nearest first")
    },
    test("the typo's tier is tried for the unnamed as for the named: a longer query ranked among a shorter one's matches lists what a fresh one does") {
        let (h, owner, named, unnamed) = try crowd(plates: 9, tokens: 1)
        let all = named + unnamed
        @MainActor func list(_ query: String, _ among: [ShapeID]) -> MentionCandidates {
            h.editor.mentionState.candidates(matching: query, in: AnyMentionable.self, for: owner, among: among, listingUnnamed: true)
        }
        let shorter = list("tox", all)
        expectEqual(Set(shorter.matches.map(\.id)), Set(named), "only the nine named")
        let narrowed = list("toxe", shorter.matches.map(\.id)), fresh = list("toxe", all)
        let missing = Set(fresh.matches.map(\.id)).subtracting(narrowed.matches.map(\.id))
        expect(missing.isEmpty || narrowed.forgave, "a fresh list has \(missing.count) the narrowed one lacks, and it does not say so")
        // With few matched, the unnamed token is a typo of "toxe" and listed, and the list says it forgave.
        let rare = try crowd(plates: 2, tokens: 1)
        let sparse = rare.h.editor.mentionState.candidates(matching: "toxe", in: AnyMentionable.self, for: rare.owner, among: rare.named + rare.unnamed, listingUnnamed: true)
        expectEqual(sparse.matches.map(\.id), rare.named + rare.unnamed, "the typo's tier reads the unnamed when few matched")
        expect(sparse.forgave)
    },

    test("listing the unnamed costs what listing as many named shapes does, to within a small factor, for a typed query and an empty one") {
        let n = 10_000
        let u = try crowd(plates: 0, tokens: n), m = try crowd(plates: n, tokens: 0)
        for query in ["u", "un", ""] {
            @MainActor func run(_ c: (h: EditorHarness, owner: ShapeID, named: [ShapeID], unnamed: [ShapeID]), _ ids: [ShapeID]) -> Duration {
                _ = c.h.editor.mentionState.candidates(matching: query, in: AnyMentionable.self, for: c.owner, among: ids, listingUnnamed: true)
                // The least of five: the cost of the call, not of what else the machine runs.
                var least = Duration.seconds(1000)
                for _ in 0..<5 {
                    least = min(least, threadCPUTime { _ = c.h.editor.mentionState.candidates(matching: query, in: AnyMentionable.self, for: c.owner, among: ids, listingUnnamed: true) })
                }
                return least
            }
            // An unnamed shape is placed (its board, how near, its place in the file) where a named one is only
            // matched, so it costs some two times a named one; sorting them all cost several times that.
            let unnamed = run(u, u.unnamed), named = run(m, m.named)
            expect(unnamed < named * 3 + .milliseconds(5), "\"\(query)\": unnamed \(unnamed), named \(named) (the least of 5 calls)")
        }
    },
])
