@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

// Values that name shapes loosely (`ShapeNaming`), beside bindings (`ShapeReferencing`), with
// CanvasTesting's `Citation`, `Memo`, `CitingTag` and `CitationsProperty`.

/// A struct that holds a name of a shape, but doesn't adopt `ShapeNaming`: nothing could find it.
struct Footnote: SchemaDefined, Equatable {
    static let properties = Properties<Footnote> {
        Property("cite", \.cite)
    }
    var cite: Citation?
}

/// A kind whose props hold one.
struct Annotated: BoxShapeProps {
    static let kind: ShapeKind = "annotated"
    static let properties = Properties<Annotated> {
        Property("frame", \.frame).required()
        Property("footnotes", \.footnotes)
    }
    var frame: CGRect = .zero
    var footnotes: [Footnote] = []
}

/// An added property whose value holds one.
enum Footnotes {}
extension Footnotes: ShapeProperty {
    static let key: PropertyKey = "footnotes"
    static var defaultValue: [Footnote]? { nil }
}

/// An editor with the fixtures' kinds (a box, a disc and a tag), a memo and a citing tag.
@MainActor private func namingEditor(_ more: [any CanvasPlugin] = []) throws -> CanvasEditor {
    CanvasEditor(registry: try Registry(plugins: [FixturesPlugin(), NamingPlugin()] + more))
}

/// Every name a record holds, by property, as `forEachNamingValue` walks them.
@MainActor private func names(in record: AnyShapeRecord, _ registry: Registry) -> [String: [ShapeID]] {
    var found: [String: [ShapeID]] = [:]
    record.forEachNamingValue(in: registry) { property, value in
        found[property, default: []] += []
        value.forEachNamedShape { found[property, default: []].append($0) }
    }
    return found
}

private func uuid(_ n: Int) -> ShapeID { ShapeID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!) }

@MainActor let namingTests = Suite("Names of shapes (ShapeNaming)", [
    test("the walk finds every name: in a struct in a list, an optional, a dictionary and an added value, each with its property") {
        let editor = try namingEditor()
        let a = ShapeID(), b = ShapeID(), c = ShapeID(), d = ShapeID(), e = ShapeID()
        let memo = editor.add(Memo(CGRect(x: 0, y: 0, width: 10, height: 10), text: "plain text",
                                   notes: [MemoNote("first", cites: [Citation(a), Citation(b)]), MemoNote("second")],
                                   lead: Citation(c), sources: ["one": Citation(d)]))
        editor.transact { $0.update(memo) { $0[CitationsProperty.self] = [Citation(e)] } }
        let record = try require(editor.document[memo])
        expectEqual(names(in: record, editor.registry), ["notes": [a, b], "lead": [c], "sources": [d], "citations": [e]])
        var order: [String] = []
        record.forEachNamingValue(in: editor.registry) { property, _ in order.append(property) }
        expectEqual(order, ["notes", "lead", "sources", "citations"], "its own in list order, then its added ones; never text")
        let blank = editor.add(Memo())
        let empty = try require(editor.document[blank])
        expectEqual(names(in: empty, editor.registry), ["notes": [], "lead": [], "sources": []], "an unset added value isn't there to walk")
    },
    test("a copy renames the names of the shapes copied with it and keeps the rest; none is let go") {
        let editor = try namingEditor()
        let a = ShapeID(), b = ShapeID(), c = ShapeID(), d = ShapeID(), e = ShapeID()
        let memo = editor.add(Memo(CGRect(x: 0, y: 0, width: 10, height: 10), text: "plain text",
                                   notes: [MemoNote("first", cites: [Citation(a), Citation(b)])],
                                   lead: Citation(c), sources: ["one": Citation(d)]))
        editor.transact { $0.update(memo) { $0[CitationsProperty.self] = [Citation(e)] } }
        let record = try require(editor.document[memo])
        let copyOfA = ShapeID()
        let alone = try require(record.remappingReferences({ $0 == a ? copyOfA : nil }, in: editor.shapeContext))
        expectEqual(alone.typed(as: Memo.self)?.props,
                    Memo(CGRect(x: 0, y: 0, width: 10, height: 10), text: "plain text",
                         notes: [MemoNote("first", cites: [Citation(copyOfA), Citation(b)])], lead: Citation(c), sources: ["one": Citation(d)]))
        expectEqual(alone[CitationsProperty.self], [Citation(e)])
        let copies = [a: ShapeID(), b: ShapeID(), c: ShapeID(), d: ShapeID(), e: ShapeID()]
        let together = try require(record.remappingReferences({ copies[$0] }, in: editor.shapeContext))
        expectEqual(names(in: together, editor.registry),
                    ["notes": [copies[a]!, copies[b]!], "lead": [copies[c]!], "sources": [copies[d]!], "citations": [copies[e]!]])
        expectEqual(record.remappingReferences({ _ in nil }, in: editor.shapeContext), record, "nil keeps every name")
    },
    test("a delete never looks for names: no memo is walked, and what named the shape still does") {
        let editor = try namingEditor()
        let box = editor.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let memos = (0..<3).map { _ in editor.add(Memo(lead: Citation(box), sources: ["box": Citation(box)])) }
        editor.transact { $0.update(memos[0]) { $0[CitationsProperty.self] = [Citation(box)] } }
        let before = memos.map { editor.document[$0] }
        let visits = Citation.visits
        editor.transact { $0.delete([box]) }
        expectEqual(Citation.visits, visits, "no citation was walked or renamed")
        expectEqual(memos.map { editor.document[$0] }, before)
    },
    test("a shape that binds and names: a delete lets its binding go and keeps its name; a copy alone does too") {
        let editor = try namingEditor()
        let box = editor.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let tag = editor.add(CitingTag(target: box, cite: Citation(box)))
        let record = try require(editor.document[tag])
        let copyOfBox = ShapeID()
        expectEqual(record.remappingReferences({ $0 == box ? copyOfBox : nil }, in: editor.shapeContext)?.typed(as: CitingTag.self)?.props,
                    CitingTag(target: copyOfBox, cite: Citation(copyOfBox)), "copied together: both follow the copy")
        expectEqual(record.remappingReferences({ _ in nil }, in: editor.shapeContext)?.typed(as: CitingTag.self)?.props,
                    CitingTag(target: nil, cite: Citation(box)), "copied alone: the binding goes, the name stays")
        editor.transact { $0.delete([box]) }
        expectEqual(editor.document[tag]?.typed(as: CitingTag.self)?.props, CitingTag(target: nil, cite: Citation(box)))
    },
    test("the shapes a record is bound to are what its kind binds, never what it names, each once") {
        let editor = try namingEditor()
        let box = editor.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let gone = ShapeID()
        let context = editor.shapeContext
        expectEqual(AnyShapeRecord(ShapeRecord(CitingTag(target: box, cite: Citation(gone)))).boundShapes(in: context), [box])
        expectEqual(AnyShapeRecord(ShapeRecord(Tag(target: gone))).boundShapes(in: context), [gone], "one that isn't there is still bound")
        expectEqual(AnyShapeRecord(ShapeRecord(Tag(target: nil))).boundShapes(in: context), [])
        expectEqual(AnyShapeRecord(ShapeRecord(Memo(lead: Citation(box)))).boundShapes(in: context), [])
        expectEqual(AnyShapeRecord(ShapeRecord(Box(.zero))).boundShapes(in: context), [])
    },
    test("the registry refuses a struct that holds names without adopting ShapeNaming, in a kind or an added value; a kind's props needn't") {
        do {
            _ = try Registry(plugins: [Contributor(id: "kinds") { $0.shape(PlainDefinition<Annotated>()) }])
            expect(false, "a struct whose names nothing could find was accepted")
        } catch {
            expectEqual("\(error)", "Shapes: annotated (from kinds): Footnote.cite names shapes (ShapeNaming), so Footnote must adopt ShapeNaming too (extension Footnote: ShapeNaming {}), or a copy would go on naming the originals")
        }
        do {
            _ = try Registry(plugins: [Contributor(id: "p") { $0.declare(Footnotes.self) }])
            expect(false, "a value whose names nothing could find was declared")
        } catch {
            expectEqual("\(error)", "PropertyDeclarations: property footnotes (from p): Footnote.cite names shapes (ShapeNaming), so Footnote must adopt ShapeNaming too (extension Footnote: ShapeNaming {}), or a copy would go on naming the originals")
        }
        expect(!(Memo.self is any ShapeNaming.Type), "a kind's props are walked by their list")
        _ = try Registry(plugins: [NamingPlugin()])
    },
    test("naming kinds are those whose props or opted-in added values hold names; no other shape is walked") {
        let bridge = Contributor(id: "bridge") { $0.optIn(Disc.self, to: CitationsProperty.self) }
        let registry = try Registry(plugins: [FixturesPlugin(), NamingPlugin(), bridge])
        expectEqual(registry.namingKinds, [Memo.kind, CitingTag.kind, Disc.kind])
        expectEqual(try Registry(plugins: [FixturesPlugin()]).namingKinds, [])
        let editor = CanvasEditor(registry: registry)
        let boxID = editor.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let box = try require(editor.document[boxID])
        var walked = 0
        box.forEachNamingValue(in: registry) { _, _ in walked += 1 }
        expectEqual(walked, 0)
        expectEqual(box.remappingReferences({ _ in ShapeID() }, in: editor.shapeContext), box)
        let disc = editor.add(Disc(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let named = ShapeID()
        editor.transact { $0.update(disc) { $0[CitationsProperty.self] = [Citation(named)] } }
        expectEqual(names(in: try require(editor.document[disc]), registry), ["citations": [named]])
    },
    test("names a record keeps aside aren't walked or renamed: an added value from a newer version, or a whole shape") {
        let registry = try Registry(plugins: [FixturesPlugin(), NamingPlugin()])
        let json = """
        { "format" : 3, "versions" : { "kinds" : { "\(Memo.kind)" : 0 }, "added" : { "\(CitationsProperty.key)" : 3 } }, "shapes" : [
          { "id" : "\(uuid(1))", "kind" : "\(Memo.kind)", "index" : "a0", "props" : { "frame" : [[0, 0], [10, 10]], "lead" : "\(uuid(7))" },
            "added" : { "\(CitationsProperty.key)" : ["\(uuid(8))"] } }
        ] }
        """
        let loaded = try BoardCodec(registry: registry).decode(Data(json.utf8))
        let memo = try require(loaded.document[uuid(1)])
        expectEqual(memo.keptProperties, [CitationsProperty.key])
        expectEqual(names(in: memo, registry), ["notes": [], "lead": [uuid(7)], "sources": []])
        let context = ShapeContext(document: loaded.document, registry: registry)
        let copy = try require(memo.remappingReferences({ _ in uuid(9) }, in: context))
        expectEqual(copy.typed(as: Memo.self)?.props.lead, Citation(uuid(9)))
        let written = try JSONDecoder().decode(JSONValue.self, from: BoardCodec(registry: registry).encode(CanvasDocument(shapes: [copy])))
        expectEqual(written["shapes"]?.arrayValue?.first?["kept"]?[CitationsProperty.key.rawValue], ["v": 3, "value": [.string(uuid(8).description)]],
                    "the kept value still names the original")
        let newer = """
        { "format" : 1, "schema" : { "\(Memo.kind)" : 5 }, "shapes" : [
          { "id" : "\(uuid(2))", "kind" : "\(Memo.kind)", "index" : "a0", "props" : { "frame" : [[0, 0], [10, 10]], "lead" : "\(uuid(7))" } }
        ] }
        """
        let aside = try require(BoardCodec(registry: registry).decode(Data(newer.utf8)).document[uuid(2)])
        expect(aside.isOpaque)
        expectEqual(names(in: aside, registry), [:])
        expectEqual(aside.remappingReferences({ _ in uuid(9) }, in: context), aside)
    },
    test("optionals, lists, sets and dictionaries of names are names; a struct's are its listed members'") {
        let a = ShapeID(), b = ShapeID(), c = ShapeID()
        let rename: (ShapeID) -> ShapeID? = { $0 == a ? c : nil }
        expectEqual(Optional(Citation(a)).renamingShapes(rename), Citation(c))
        expectEqual((nil as Citation?).renamingShapes(rename), nil)
        expectEqual([Citation(a), Citation(b)].renamingShapes(rename), [Citation(c), Citation(b)])
        expectEqual(Set([Citation(a), Citation(c)]).renamingShapes(rename), [Citation(c)], "renamed alike, two elements are one")
        expectEqual(["x": Citation(a), "y": Citation(b)].renamingShapes(rename), ["x": Citation(c), "y": Citation(b)])
        let note = MemoNote("see", cites: [Citation(a), Citation(b), Citation(a)])
        expectEqual(note.renamingShapes(rename), MemoNote("see", cites: [Citation(c), Citation(b), Citation(c)]))
        var named: [ShapeID] = []
        note.forEachNamedShape { named.append($0) }
        expectEqual(named, [a, b, a], "in order, repeats included")
    },
    test("the leaves a value holds, wherever they are in it: in a struct's members, a list, an optional and a dictionary") {
        let a = ShapeID(), b = ShapeID(), c = ShapeID()
        @MainActor func leaves(of value: any ShapeNaming) -> [Citation] {
            var found: [Citation] = []
            value.forEachNamingLeaf { leaf in
                guard let citation = leaf as? Citation else { return expect(false, "\(leaf) isn't a leaf") }
                found.append(citation)
            }
            return found
        }
        expectEqual(leaves(of: Citation(a)), [Citation(a)], "a leaf is its own")
        let note = MemoNote("see", cites: [Citation(a), Citation(b)])
        expectEqual(leaves(of: note), [Citation(a), Citation(b)])
        expectEqual(leaves(of: [note, MemoNote("more", cites: [Citation(c)])]), [Citation(a), Citation(b), Citation(c)])
        expectEqual(leaves(of: Optional(["one": [note]])), [Citation(a), Citation(b)])
        expectEqual(leaves(of: (nil as MemoNote?)), [])
        expectEqual(Set(leaves(of: Set([Citation(a), Citation(c)]))), [Citation(a), Citation(c)])
    },
    test("a dictionary keyed by strings is an object in a schema, its members its values', and a board keeps it") {
        let registry = try Registry(plugins: [FixturesPlugin(), NamingPlugin()])
        let json = try require(registry.schema(for: Memo.kind)).json
        expectEqual(json["properties"]?["sources"], ["type": "object", "additionalProperties": ["$ref": "#/$defs/canvastesting.citation"], "default": [:]])
        expectEqual(json["properties"]?["notes"]?["items"], ["$ref": "#/$defs/canvastesting.memo-note"])
        let memo = AnyShapeRecord(ShapeRecord(id: uuid(1), Memo(CGRect(x: 0, y: 0, width: 10, height: 10), sources: ["one": Citation(uuid(2))])))
        expectEqual(registry.schemaViolations(of: memo), [])
        let codec = BoardCodec(registry: registry)
        let read = try codec.decode(try codec.encode(CanvasDocument(shapes: [memo])))
        expectEqual(read.document[uuid(1)]?.typed(as: Memo.self)?.props.sources, ["one": Citation(uuid(2))])
    },
])
