import Automation
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Draw
import Foundation
import TestKit

// `canvas draw` with text a plugin writes (`DrawTextFormats`): a string whose schema says
// `contentMediaType` of a media type some plugin writes is handed to its format as the script wrote
// it, and the shape keeps what the format gives back. These tests' format has a syntax of its own,
// where `<Title>` names a shape and is kept as `<Title|ID>`; a text of one kind may name only
// tiles. The tiles and cards are the fixtures'; no real kind, and no mention.

let refsMediaType = "text/x-test-refs"

/// What a text of a kind may name: any shape, or only some kinds.
protocol RefScope: Sendable {
    static var onlyKinds: [String]? { get }
}

enum AnyRef: RefScope {
    static let onlyKinds: [String]? = nil
}

enum TilesOnly: RefScope {
    static let onlyKinds: [String]? = ["tile"]
}

/// A string whose schema says its content is of `refsMediaType`, with what `Scope` admits beside the
/// reference: the way a kind says what its mention text may mention.
struct RefText<Scope: RefScope>: Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    var stored: String

    init(_ stored: String) { self.stored = stored }
    init(stringLiteral value: String) { stored = value }
    init(from decoder: any Decoder) throws { stored = try decoder.singleValueContainer().decode(String.self) }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stored)
    }
}

extension RefText: SchemaDescribed {
    static func schema(in definitions: inout SchemaDefinitions) -> JSONObject {
        var json = definitions.reference("refs", of: AnyRef.self) { _ in ["type": "string", "contentMediaType": .string(refsMediaType)] }
        if let only = Scope.onlyKinds { json["x-test-only"] = .array(only.map { .string($0) }) }
        return json
    }
}

/// What a tile says to a shape: whom (tiles only), and what.
struct Say: SchemaDefined, Equatable {
    static let properties = Properties<Say> {
        Property("to", \.to)
        Property("text", \.text)
    }
    var to: RefText<TilesOnly> = ""
    var text: RefText<AnyRef> = ""
}

/// Text that may name any shape.
enum Remark {}

extension Remark: ShapeProperty {
    static let key: PropertyKey = "remark"
    static var defaultValue: RefText<AnyRef>? { nil }
}

/// Text that may name tiles only.
enum PinnedTo {}

extension PinnedTo: ShapeProperty {
    static let key: PropertyKey = "pinnedTo"
    static var defaultValue: RefText<TilesOnly>? { nil }
}

/// A list of texts.
enum Lines {}

extension Lines: ShapeProperty {
    static let key: PropertyKey = "lines"
    static var defaultValue: [RefText<AnyRef>]? { [] }
}

/// A list of objects, each holding two texts.
enum Says {}

extension Says: ShapeProperty {
    static let key: PropertyKey = "says"
    static var defaultValue: [Say]? { [] }
}

/// A dictionary of texts, by name: `additionalProperties` in its schema.
enum Notes {}

extension Notes: ShapeProperty {
    static let key: PropertyKey = "notes"
    static var defaultValue: [String: RefText<AnyRef>]? { [:] }
}

/// A pair of texts, a tuple (`prefixItems` in its schema): the first names any shape, the second tiles only.
struct Duo: Codable, Hashable, Sendable {
    var first: RefText<AnyRef> = ""
    var second: RefText<TilesOnly> = ""

    init() {}

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        first = try container.decode(RefText<AnyRef>.self)
        second = try container.decode(RefText<TilesOnly>.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(first)
        try container.encode(second)
    }
}

extension Duo: SchemaDescribed {
    static func schema(in definitions: inout SchemaDefinitions) -> JSONObject {
        ["type": "array", "prefixItems": [.object(RefText<AnyRef>.schema(in: &definitions)), .object(RefText<TilesOnly>.schema(in: &definitions))],
         "minItems": 2, "maxItems": 2]
    }
}

enum Pair {}

extension Pair: ShapeProperty {
    static let key: PropertyKey = "pair"
    static var defaultValue: Duo? { nil }
}

/// The texts, on tiles (every one), cards (a remark) and links (a remark, an edge's own attribute).
let refTexts = Contributor(id: "ref-texts") { registrar in
    registrar.declare(Remark.self)
    registrar.declare(PinnedTo.self)
    registrar.declare(Lines.self)
    registrar.declare(Says.self)
    registrar.declare(Notes.self)
    registrar.declare(Pair.self)
    registrar.optIn(Tile.self, to: Remark.self)
    registrar.optIn(Tile.self, to: PinnedTo.self)
    registrar.optIn(Tile.self, to: Lines.self)
    registrar.optIn(Tile.self, to: Says.self)
    registrar.optIn(Tile.self, to: Notes.self)
    registrar.optIn(Tile.self, to: Pair.self)
    registrar.optIn(Card.self, to: Remark.self)
    registrar.optIn(Link.self, to: Remark.self)
}

/// The format: `<name>` is a shape by its title, kept as `<title|id>`; an unclosed `<` is text, and
/// `<>` is refused. A text that says `x-test-only` beside its reference may name only those kinds.
func refFormat(mediaType: String = refsMediaType, id: PluginID = "refs") -> Contributor {
    Contributor(id: id) { registrar in
        registrar.drawTextFormat(mediaType: mediaType, describes: "<Title> names") { text, context throws(DrawError) in
            let only = context.schema["x-test-only"]?.arrayValue?.compactMap(\.stringValue)
            var written = "", rest = Substring(text)
            while let open = rest.firstIndex(of: "<") {
                written += rest[..<open]
                guard let close = rest[open...].firstIndex(of: ">") else {
                    written += rest[open...]
                    rest = ""
                    break
                }
                let name = String(rest[rest.index(after: open)..<close])
                guard !name.isEmpty else {
                    throw DrawError("<> names nothing", reason: "invalid_value", hint: "put a title between the brackets")
                }
                let shape = try context.shape(called: name) { record in
                    guard let only, !only.contains(record.kind.rawValue) else { return nil }
                    return "which only \(only.joined(separator: " or ")) shapes can be named here"
                }
                written += "<\(shape.title)|\(shape.id)>"
                rest = rest[rest.index(after: close)...]
            }
            return written + rest
        }
    }
}

/// An editor with the texts and their format, and the draw plugins.
@MainActor func refsEditor(_ more: [any CanvasPlugin] = []) throws -> CanvasEditor {
    try drawEditor([refTexts, refFormat()] + more)
}

/// What a shape's property holds, as stored.
@MainActor func kept<P: ShapeProperty>(_ property: P.Type, of title: String, in editor: CanvasEditor) -> P.Value? {
    shape(title, in: editor)?[property]
}

/// The id of the tile (or card) called this, for what's stored of it.
@MainActor func id(of title: String, in editor: CanvasEditor) throws -> ShapeID {
    try require(shape(title, in: editor), "a shape called \(title)").id
}

@MainActor let drawTextTests = Suite("draw: text a plugin writes", [
    test("a title in a text names the shape: one on the board, one the script draws further down, or restates, or renames to; kept with its title") {
        let editor = try refsEditor()
        _ = try drawn(#"""
        tile "Plan" remark: "Ask <Hub> before <Later>, then <Hub>"
        tile "Hub" right of "Plan"
        tile "Later" right of "Hub"
        """#, on: editor)
        let hub = try id(of: "Hub", in: editor), later = try id(of: "Later", in: editor)
        expectEqual(kept(Remark.self, of: "Plan", in: editor)?.stored, "Ask <Hub|\(hub)> before <Later|\(later)>, then <Hub|\(hub)>")
        // A shape the board has, restated or not, and one renamed in the script: by its new title, or the old.
        _ = try drawn(#"tile "Old" below "Plan""#, on: editor)
        let old = try id(of: "Old", in: editor)
        let result = try drawn(#"""
        tile "Plan" remark: "See <Old> and <New>, not <Hub>"
        tile "Old" title: "New"
        """#, on: editor)
        expectEqual(rows(result).map { $0["did"] }, ["updated", "renamed"])
        expectEqual(kept(Remark.self, of: "Plan", in: editor)?.stored, "See <New|\(old)> and <New|\(old)>, not <Hub|\(hub)>")
    },

    test("the board the run draws on comes first, then the board the window shows, then the rest of the file") {
        let n = Nest(), editor = try n.editor([refTexts, refFormat()])
        // On P's board, Hub is P's, though the window's board has one: the run draws there.
        _ = try drawn(#"tile "Cache" in "P" remark: "<Hub> and <Deep>""#, on: editor)
        let cache = try require(editor.contents(of: BoardID(owner: n.p)).shapes.first { $0.typed(as: Tile.self)?.props.label == "Cache" })
        expectEqual(cache[Remark.self]?.stored, "<Hub|\(n.pHub)> and <Deep|\(n.deep)>")
        // On Q's board, which has no Hub: the window's (the root's), not P's.
        _ = try drawn(#"tile "Qube" in "Q" remark: "<Hub> and <Twin>""#, on: editor)
        let qube = try require(editor.contents(of: BoardID(owner: n.q)).shapes.first { $0.typed(as: Tile.self)?.props.label == "Qube" })
        expectEqual(qube[Remark.self]?.stored, "<Hub|\(n.hub)> and <Twin|\(n.twin)>", "Hub is the window's, Twin the board's own")
        // From the window's board, a shape found elsewhere in the file, once.
        _ = try drawn(#"tile "Plan" remark: "<Deep>""#, on: editor)
        expectEqual(kept(Remark.self, of: "Plan", in: editor)?.stored, "<Deep|\(n.deep)>")
        expectEqual(editor.board, .root, "the window never moved")
    },

    test("shapes called alike are ambiguous where they are together: on the board, or elsewhere in the file, which the message says") {
        let n = Nest(), editor = try n.editor([refTexts, refFormat()])
        // On two other boards.
        let twice = try refused(#"tile "Plan" remark: "<Twin>""#, on: editor)
        expectEqual(twice.reason, "ambiguous_title")
        expectEqual(twice.message, #""Plan": remark: "Twin" is on 2 boards: "P"'s board and "Q"'s board"#)
        expectEqual(twice.hint, "a text names a shape by its title alone, so mention one whose title is its own here")
        expectEqual(twice.data?["line"], 1)
        expectEqual(twice.data?["statement"], #"tile "Plan" remark: "<Twin>""#)
        // Two on one other board.
        editor.transact(on: BoardID(owner: n.p), "More") {
            $0.insert(AnyShapeRecord(ShapeRecord(Tile(CGRect(x: 900, y: 0, width: 100, height: 60), label: "Deep"))))
        }
        let inOne = try refused(#"tile "Plan" remark: "<Deep>""#, on: editor)
        expectEqual(inOne.message, #""Plan": remark: "P"'s board has 2 shapes called "Deep": a tile "P" > "Deep" at 50,30 and a tile "P" > "Deep" at 950,30"#)
        // Two on the board the run draws on, and on the board the window shows.
        editor.transact { $0.insert(AnyShapeRecord(ShapeRecord(Tile(CGRect(x: 300, y: 300, width: 100, height: 60), label: "Hub")))) }
        let here = try refused(#"tile "Plan" remark: "<Hub>""#, on: editor)
        expectEqual(here.reason, "ambiguous_title")
        expectEqual(here.message, #""Plan": remark: the board has 2 shapes called "Hub": a tile at 50,30 and a tile at 350,330"#)
        let shown = try refused(#"tile "Qube" in "Q" remark: "<Hub>""#, on: editor)
        expectEqual(shown.message, #""Qube": remark: the board the window shows has 2 shapes called "Hub": a tile at 50,30 and a tile at 350,330"#)
        expectEqual(editor.document.shapes.count, 4, "nothing drawn")
    },

    test("a title the script's own deletes take, a shape or the board it holds, names nothing; one it deletes and draws again does") {
        let n = Nest()
        let editor = try n.editor([refTexts, refFormat()])
        let deleted = try refused("delete \"Deep\"\ntile \"Plan\" remark: \"<Deep>\"", on: editor)
        expectEqual(deleted.reason, "unknown_title")
        expectEqual(deleted.message, #""Plan": remark: names "Deep", which this script deletes"#)
        expectEqual(deleted.hint, #"draw "Deep" again after deleting it, or leave it out"#)
        expectEqual(deleted.data?["line"], 2)
        let held = try refused("delete \"P\"\ntile \"Plan\" remark: \"<Deep>\"", on: editor)
        expectEqual(held.message, #""Plan": remark: names "Deep", which this script deletes"#, "it's on the board P holds")
        // Hub is on two boards: the root's deleted, P's is still there to name.
        _ = try drawn("delete \"Hub\"\ntile \"Plan\" remark: \"<Hub>\"", on: editor)
        expectEqual(kept(Remark.self, of: "Plan", in: editor)?.stored, "<Hub|\(n.pHub)>")
        // Redrawn, it's the new one.
        let again = try n.editor([refTexts, refFormat()])
        _ = try drawn("delete \"Hub\"\ntile \"Hub\"\ntile \"Plan\" remark: \"<Hub>\" right of \"Hub\"", on: again)
        let new = try require(again.document.shapes.first { $0.typed(as: Tile.self)?.props.label == "Hub" })
        expect(new.id != n.hub)
        expectEqual(kept(Remark.self, of: "Plan", in: again)?.stored, "<Hub|\(new.id)>")
        // What's on a board the script doesn't delete is still there to name.
        let rest = try n.editor([refTexts, refFormat()])
        _ = try drawn("delete \"Q\"\ntile \"Near\" remark: \"<Deep>\" below \"Hub\"", on: rest)
        expectEqual(kept(Remark.self, of: "Near", in: rest)?.stored, "<Deep|\(n.deep)>")
    },

    test("a title nobody has is unknown, with the ones like it: the file's, and the script's own, among those the text may name") {
        let n = Nest(), editor = try n.editor([refTexts, refFormat()])
        let typo = try refused(#"tile "Plan" remark: "see <Twim>""#, on: editor)
        expectEqual(typo.reason, "unknown_title")
        expectEqual(typo.message, #""Plan": remark: there's no shape called "Twim""#)
        expectEqual(typo.hint, #"did you mean "Twin"?"#, "once, though two shapes are called that")
        let drawnOne = try refused("tile \"Plan\" remark: \"<Hubbel>\"\ntile \"Hubble\" right of \"Plan\"", on: editor)
        expect(drawnOne.hint?.contains(#""Hubble""#) == true, "\(String(describing: drawnOne.hint))")
        expectEqual(try refused(#"tile "Plan" remark: "<Zzzz>""#, on: editor).hint,
                    "a title is one the file has as the script starts, or one the script draws")
        // A card isn't a guess for what only tiles may be pinned to.
        var card = AnyShapeRecord(ShapeRecord(Card(CGRect(x: 600, y: 600, width: 100, height: 60))))
        card[Nickname.self] = "Hug"
        editor.transact { $0.insert(card) }
        editor.transact { $0.insert(AnyShapeRecord(ShapeRecord(Tile(CGRect(x: 800, y: 600, width: 100, height: 60), label: "Hum")))) }
        expectEqual(try refused(#"tile "Plan" remark: "<Hux>""#, on: editor).hint, #"did you mean "Hub", "Hug" or "Hum"?"#)
        expectEqual(try refused(#"tile "Plan" pinnedTo: "<Hux>""#, on: editor).hint, #"did you mean "Hub" or "Hum"?"#)
    },

    test("what a text may name is asked of each shape called that: the admitted one is the shape; none admitted is refused, with the format's reason") {
        let editor = try refsEditor()
        editor.transact { $0.insert(AnyShapeRecord(ShapeRecord(Tile(CGRect(x: 0, y: 0, width: 100, height: 60), label: "Row")))) }
        var card = AnyShapeRecord(ShapeRecord(Card(CGRect(x: 300, y: 0, width: 100, height: 60))))
        card[Nickname.self] = "Row"
        editor.transact { $0.insert(card) }
        let tile = try require(editor.document.shapes.first { $0.typed(as: Tile.self) != nil })
        // Any shape may be named: two are called Row, so it's ambiguous. Tiles only, there's one.
        expectEqual(try refused(#"tile "Plan" remark: "<Row>""#, on: editor).reason, "ambiguous_title")
        _ = try drawn(#"tile "Plan" pinnedTo: "<Row>""#, on: editor)
        expectEqual(kept(PinnedTo.self, of: "Plan", in: editor)?.stored, "<Row|\(tile.id)>")
        // Only a card is called that: refused, saying what it is and why.
        let only = try refsEditor()
        only.transact { $0.insert(card) }
        let none = try refused(#"tile "Plan" pinnedTo: "<Row>""#, on: only)
        expectEqual(none.reason, "invalid_value")
        expectEqual(none.message, #""Plan": pinnedTo: "Row" is a card, which only tile shapes can be named here"#)
        expectEqual(none.hint, nil)
        // A card the script draws counts as much.
        let own = try refused("card \"Row\"\ntile \"Plan\" pinnedTo: \"<Row>\" below \"Row\"", on: try refsEditor())
        expectEqual(own.message, #""Plan": pinnedTo: "Row" is a card, which only tile shapes can be named here"#)
        // The card on the board isn't taken by a text that names tiles only, so the rest of the file is
        // looked at, and a tile on another board is the one; a text that may name any shape takes the card.
        let n = Nest(), nest = try n.editor([refTexts, refFormat()])
        var near = AnyShapeRecord(ShapeRecord(Card(CGRect(x: 600, y: 0, width: 100, height: 60))))
        near[Nickname.self] = "Deep"
        nest.transact { $0.insert(near) }
        _ = try drawn(#"tile "Plan" pinnedTo: "<Deep>""#, on: nest)
        expectEqual(kept(PinnedTo.self, of: "Plan", in: nest)?.stored, "<Deep|\(n.deep)>")
        _ = try drawn(#"tile "Plan" remark: "<Deep>""#, on: nest)
        expectEqual(kept(Remark.self, of: "Plan", in: nest)?.stored, "<Deep|\(near.id)>")
    },

    test("the format's own refusal is the statement's, on its line; and what's inside lists and objects is written, each by its own schema") {
        let editor = try refsEditor()
        _ = try drawn(#"tile "Hub""# + "\n" + #"tile "Later" right of "Hub""#, on: editor)
        let hub = try id(of: "Hub", in: editor), later = try id(of: "Later", in: editor)
        let empty = try refused(#"tile "Plan" below "Hub" remark: "see <> here""#, on: editor)
        expectEqual(empty.reason, "invalid_value")
        expectEqual(empty.message, #""Plan": remark: <> names nothing"#)
        expectEqual(empty.hint, "put a title between the brackets")
        expectEqual(empty.data?["line"], 1)
        // An unclosed < is text.
        _ = try drawn(#"tile "Plan" below "Hub" remark: "1 < 2 and <Hub""#, on: editor)
        expectEqual(kept(Remark.self, of: "Plan", in: editor)?.stored, "1 < 2 and <Hub")
        // A list of texts, and a list of objects whose members are texts.
        _ = try drawn(#"tile "Plan" lines: ["<Hub>", "plain", "x <Later> y"] says: [{"to": "<Hub>", "text": "see <Later>"}, {"text": "<Hub><Later>"}]"#, on: editor)
        expectEqual(kept(Lines.self, of: "Plan", in: editor)?.map(\.stored), ["<Hub|\(hub)>", "plain", "x <Later|\(later)> y"])
        expectEqual(kept(Says.self, of: "Plan", in: editor)?.map { [$0.to.stored, $0.text.stored] },
                    [["<Hub|\(hub)>", "see <Later|\(later)>"], ["", "<Hub|\(hub)><Later|\(later)>"]])
        // The text inside is held to its own scope: a member that may name only tiles.
        var card = AnyShapeRecord(ShapeRecord(Card(CGRect(x: 600, y: 0, width: 100, height: 60))))
        card[Nickname.self] = "Row"
        editor.transact { $0.insert(card) }
        let scoped = try refused(#"tile "Plan" says: [{"to": "<Row>"}]"#, on: editor)
        expectEqual(scoped.message, #""Plan": says: "Row" is a card, which only tile shapes can be named here"#)
        // Several members at fault: the first by name, so the same each time.
        expectEqual(try refused(#"tile "Plan" says: [{"to": "<Row>", "text": "<Nobody>"}]"#, on: editor).reason, "unknown_title")
        // JSON with a member the type hasn't is refused before a text is read.
        expectEqual(try refused(#"tile "Plan" says: [{"txt": "<Hub>"}]"#, on: editor).message, #""Plan": says: txt isn't a member of item 1 (it has text and to)"#)
    },

    test("texts in a dictionary's values and a tuple's members are written by their schemas too: additionalProperties and prefixItems") {
        let editor = try refsEditor()
        _ = try drawn("tile \"Hub\"\ntile \"Later\" right of \"Hub\"", on: editor)
        let hub = try id(of: "Hub", in: editor), later = try id(of: "Later", in: editor)
        _ = try drawn(#"tile "Plan" below "Hub" notes: {"a": "<Hub>", "b": "plain <Later>"} pair: ["see <Later>", "<Hub>"]"#, on: editor)
        expectEqual(kept(Notes.self, of: "Plan", in: editor)?.mapValues(\.stored), ["a": "<Hub|\(hub)>", "b": "plain <Later|\(later)>"])
        expectEqual(kept(Pair.self, of: "Plan", in: editor).map { [$0.first.stored, $0.second.stored] }, ["see <Later|\(later)>", "<Hub|\(hub)>"])
        // The second of the pair names tiles only, and Row is a card.
        var card = AnyShapeRecord(ShapeRecord(Card(CGRect(x: 600, y: 0, width: 100, height: 60))))
        card[Nickname.self] = "Row"
        editor.transact { $0.insert(card) }
        expectEqual(try refused(#"tile "Plan" pair: ["<Row>", "<Row>"]"#, on: editor).message,
                    #""Plan": pair: "Row" is a card, which only tile shapes can be named here"#)
        expectEqual(try refused(#"tile "Plan" notes: {"a": "<Nobody>"}"#, on: editor).reason, "unknown_title")
        _ = try drawn(#"tile "Plan" pair: ["<Row>", "<Hub>"]"#, on: editor)
        expectEqual(kept(Pair.self, of: "Plan", in: editor)?.first.stored, "<Row|\(card.id)>")
    },

    test("an edge's own attributes and a style's are written the same: an edge's text names a shape, a style's is the statement's") {
        let editor = try refsEditor()
        _ = try drawn("tile \"Plan\"\ntile \"Hub\" right of \"Plan\"\ntile \"Later\" right of \"Hub\"", on: editor)
        let later = try id(of: "Later", in: editor)
        let edge = try drawn(#"edge "Plan" -> "Hub" remark: "see <Later>""#, on: editor)
        expectEqual(rows(edge).map { $0["did"] }, ["connected"])
        let link = try require(editor.document.shapes.first { $0.typed(as: Link.self) != nil })
        expectEqual(link[Remark.self]?.stored, "see <Later|\(later)>")
        let again = try drawn(#"edge "Plan" -> "Hub" remark: "see <Later>""#, on: editor)
        expectEqual(rows(again).map { $0["did"] }, ["unchanged"])
        let refusedEdge = try refused(#"edge "Plan" -> "Hub" remark: "see <Nobody>""#, on: editor)
        expectEqual(refusedEdge.reason, "unknown_title")
        expectEqual(refusedEdge.message, #"edge "Plan" -> "Hub": remark: there's no shape called "Nobody""#)
        // A style.
        _ = try drawn("style loud remark: \"<Later>\"\ntile \"Hub\" style: loud", on: editor)
        expectEqual(kept(Remark.self, of: "Hub", in: editor)?.stored, "<Later|\(later)>")
        let badStyle = try refused("style loud remark: \"<Nobody>\"\ntile \"Hub\" style: loud", on: editor)
        expectEqual(badStyle.message, #""Hub": remark: there's no shape called "Nobody" (from style loud)"#)
    },

    test("a script run twice says unchanged the second time, and a dry run says what a run would, changing nothing") {
        let editor = try refsEditor()
        let script = #"""
        tile "Plan" remark: "Ask <Hub> before <Later>"
        tile "Hub" right of "Plan"
        tile "Later" right of "Hub"
        """#
        let dry = try drawn(script, on: editor, ["--dry-run"])
        expectEqual(rows(dry).map { $0["did"] }, ["created", "created", "created"])
        expectEqual(editor.document.shapes.count, 0, "nothing changed")
        expect(!editor.canUndo)
        _ = try drawn(script, on: editor)
        let before = editor.document
        expectEqual(rows(try drawn(script, on: editor)).map { $0["did"] }, ["unchanged", "unchanged", "unchanged"])
        expectEqual(editor.document, before)
        expectEqual(rows(try drawn(script, on: editor, ["--dry-run"])).map { $0["did"] }, ["unchanged", "unchanged", "unchanged"])
        // The same refusal, dry or not, with nothing drawn.
        let nobody = #"tile "Plan" remark: "<Nobody>""#
        expectEqual(try refused(nobody, on: editor, ["--dry-run"]).message, try refused(nobody, on: editor).message)
        // Changed, it's updated.
        expectEqual(rows(try drawn(#"tile "Plan" remark: "Ask <Later> first""#, on: editor)).map { $0["did"] }, ["updated"])
    },

    test("without a plugin that writes the media type, a text is kept as written, and kinds says nothing of it") {
        let editor = try drawEditor([refTexts])
        _ = try drawn(#"tile "Plan" remark: "Ask <Hub> and <> then <Nobody>" lines: ["<x>"]"#, on: editor)
        expectEqual(kept(Remark.self, of: "Plan", in: editor)?.stored, "Ask <Hub> and <> then <Nobody>")
        let kinds = try run(["kinds", "tile"], on: nil, registry: editor.registry).get()
        expectEqual(kinds.arrayValue?.first?["attributes"]?["remark"], "text")
        expectEqual(kinds.arrayValue?.first?["attributes"]?["lines"], "JSON [text]")
        // Another media type's format isn't this one's.
        let other = try drawEditor([refTexts, refFormat(mediaType: "text/x-other")])
        _ = try drawn(#"tile "Plan" remark: "<Nobody>""#, on: other)
        expectEqual(kept(Remark.self, of: "Plan", in: other)?.stored, "<Nobody>")
    },

    test("kinds says what a text takes after its type, in a message's hint too: text, a list of texts, and not what's inside an object") {
        let editor = try refsEditor()
        let tile = try require(run(["kinds", "tile"], on: nil, registry: editor.registry).get().arrayValue?.first)
        expectEqual(tile["attributes"]?["remark"], "text (<Title> names)")
        expectEqual(tile["attributes"]?["pinnedTo"], "text (<Title> names)")
        expectEqual(tile["attributes"]?["lines"], "JSON [text] (<Title> names)")
        expectEqual(tile["attributes"]?["says"], "JSON [{text, to}]")
        expectEqual(tile["attributes"]?["finish"], "matte|glossy")
        let card = try require(run(["kinds", "card"], on: nil, registry: editor.registry).get().arrayValue?.first)
        expectEqual(card["attributes"]?["text"], "text", "a plain string has no format")
        expectEqual(card["attributes"]?["remark"], "text (<Title> names)")
        let json = try refused(#"tile "Plan" remark: [1]"#, on: editor)
        expectEqual(json.reason, "invalid_value")
        expectEqual(json.hint, "remark: takes text (<Title> names)")
    },

    test("a name in a text never decides the board a run draws on, nor makes it several: only the statements' titles do") {
        let n = Nest(), editor = try n.editor([refTexts, refFormat()])
        // Deep is on P's board, Hub on the root's: the run draws on the board shown, and names both.
        let result = try drawn(#"tile "Plan" remark: "<Deep> and <Hub>""#, on: editor)
        expectEqual(result["on"]?["board"], "root")
        expectEqual(editor.board, .root)
        expectEqual(kept(Remark.self, of: "Plan", in: editor)?.stored, "<Deep|\(n.deep)> and <Hub|\(n.hub)>")
        // A statement's own title does: Deep's board is the run's, and the text finds Hub there.
        let there = try drawn(#"tile "Deep" remark: "<Hub>""#, on: editor)
        expectEqual(there["on"]?["board"], .string(n.p.description))
        expectEqual(editor.file.record(n.deep)?[Remark.self]?.stored, "<Hub|\(n.pHub)>")
        // Two boards by their titles are two runs, whatever the texts say.
        let apart = try refused("tile \"Deep\" remark: \"<Hub>\"\ntile \"Hub\" finish: glossy", on: editor)
        expectEqual(apart.reason, "several_boards", "the second statement's title is the root's")
    },

    test("the file's names are read once, when a text first names a shape, and never for a script whose texts name none") {
        let n = Nest(), editor = try n.editor([refTexts, refFormat()])
        @MainActor func reads(_ script: String) throws -> Int {
            let before = DrawPlugin.fileNamesRead
            _ = try drawn(script, on: editor)
            return DrawPlugin.fileNamesRead - before
        }
        expectEqual(try reads(#"tile remark: "nothing named here, 1 < 2, a@[b]""#), 0)
        expectEqual(try reads(#"tile remark: "<Hub>""#), 1)
        expectEqual(try reads(#"tile remark: "<Hub> and <Deep>" lines: ["<Hub>", "<Deep>"]"#), 1, "once, for every name")
        expectEqual(try reads(#"tile "Plan" below "Hub""#), 1, "the statements' titles need them")
        expectEqual(try reads(#"tile "Plan" remark: "<Hub>""#), 1, "and the texts use the same")
    },

    test("a statement that couldn't be resolved leaves the texts that name its title without an error of their own") {
        let n = Nest(), editor = try n.editor([refTexts, refFormat()])
        // Hub is a tile on the board, so a card called that is the first statement's error alone.
        let result = try refused("card \"Hub\"\ntile \"Plan\" remark: \"<Hub>\" below \"Hub\"", on: editor)
        expectEqual(result.reason, "wrong_kind")
        expectEqual(result.data?["errors"], nil, "one error")
    },

    test("without a plugin that names shapes, a text can't name one") {
        let editor = try makeEditor([refTexts, refFormat()])
        let none = try refused(#"tile remark: "<Hub>""#, on: editor)
        expectEqual(none.reason, "no_names")
        expectEqual(none.message, "the tile on line 1: remark: titles name shapes, and nothing here gives shapes names")
        _ = try drawn(#"tile remark: "plain""#, on: editor)
    },

    test("the point takes one plugin for each media type, a media type and what it describes, and the report names it") {
        expectEqual(refusal { registrar in
            registrar.drawTextFormat(mediaType: "", describes: "x") { text, _ throws(DrawError) in text }
        }, "DrawTextFormats: a media type can't be blank")
        expectEqual(refusal { registrar in
            registrar.drawTextFormat(mediaType: "text/x-t", describes: "") { text, _ throws(DrawError) in text }
        }, "DrawTextFormats: text/x-t says nothing of what it describes, which canvas kinds shows after the type")
        do throws(RegistryError) {
            _ = try Registry(plugins: [DrawPlugin(), AutomationPlugin(), refFormat(), refFormat(id: "more")])
            expect(false, "two plugins write one media type")
        } catch {
            expectEqual(error.description, "refs and more both claim draw text text/x-test-refs in DrawTextFormats")
        }
        // Another media type is another claim.
        _ = try Registry(plugins: [DrawPlugin(), AutomationPlugin(), refFormat(), refFormat(mediaType: "text/x-other", id: "more")])
        let report = try refsEditor().registry.report.split(separator: "\n")
        expect(report.contains { $0.hasPrefix("refs ") && $0.hasSuffix(" draw text \(refsMediaType)") }, report.joined(separator: "\n"))
    },
])
