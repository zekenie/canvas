@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Publishing
import References
import TestKit
import Topology

// What a reference holds, how it's written, and what that says in its schema: the mode is derived
// (target wins), each writer keeps one mode and refits the width, the schema marks what a script
// may not write, and its target is a name, which a copy renames and a deletion never looks for.

private let origin = CGPoint(x: 40, y: 60)
private let placed = CGRect(origin: origin, size: Reference.defaultSize)

@MainActor let modelTests = Suite("The Reference kind", [
    test("its mode is derived from what it holds: a target wins, else words or a query, else it's empty") {
        let id = ShapeID()
        expectEqual(Reference(frame: placed).mode, .empty)
        expectEqual(Reference(frame: placed, target: ReferenceTarget(id: id, label: "A")).mode, .direct)
        expectEqual(Reference(frame: placed, words: "every note").mode, .dynamic)
        expectEqual(Reference(frame: placed, query: "box").mode, .dynamic)
        expectEqual(Reference(frame: placed, target: ReferenceTarget(id: id, label: "A"), words: "x", query: "box").mode, .direct,
                    "a hand-edited board that holds both is direct: the target wins")
        expectEqual(Reference(frame: placed, words: "every note", query: "box").text, "every note", "a dynamic one is called by its words")
        expectEqual(Reference(frame: placed, query: "box").text, "box", "else by its query")
    },
    test("picking stands for the shape, lets go of words and query, and fits the pill to its name, growing rightward") {
        var props = Reference(frame: placed, words: "every note", query: "box", all: true)
        ReferenceEdits.pick(&props, ReferenceTarget(id: ShapeID(), label: "Shapes"))
        expectEqual(props.target?.label, "Shapes")
        expectEqual(props.words, "")
        expectEqual(props.query, nil)
        expectEqual(props.all, true, "the flag is the person's, kept")
        expectEqual(props.frame.origin, origin, "it grows from where it is")
        expectEqual(props.frame.height, 32)
        expectEqual(props.frame.width, ReferenceEdits.width(of: props))
        var longer = props
        ReferenceEdits.pick(&longer, ReferenceTarget(id: ShapeID(), label: "Shapes and what they hold"))
        expect(longer.frame.width > props.frame.width, "a longer name is a wider pill")
    },
    test("finding stands for words, a query when they've been interpreted, and no target; words alone let go of a query") {
        var props = Reference(frame: placed)
        ReferenceEdits.pick(&props, ReferenceTarget(id: ShapeID(), label: "Shapes"))
        ReferenceEdits.find(&props, words: "payment notes", query: "box")
        expectEqual(props.target, nil)
        expectEqual(props.words, "payment notes")
        expectEqual(props.query, "box")
        expectEqual(props.mode, .dynamic)
        ReferenceEdits.find(&props, words: "payment notes today")
        expectEqual(props.query, nil, "words written alone clear the query that was for other words")
        expectEqual(props.frame.width, ReferenceEdits.width(of: props))
    },
    test("a dynamic pill always reserves room for its widest badge, and a direct one for its eye or warning, so neither refits when they come") {
        var direct = Reference(frame: placed), dynamic = Reference(frame: placed)
        ReferenceEdits.pick(&direct, ReferenceTarget(id: ShapeID(), label: "payment notes"))
        ReferenceEdits.find(&dynamic, words: "payment notes")
        expectEqual(dynamic.frame.width - direct.frame.width, 36 - 17, "the gap and the badge, less a direct pill's gap and glyph")
    },
    test("a pill is never under 64 wide or over 280, and clearing puts it back to what a placed one is") {
        var props = Reference(frame: placed)
        ReferenceEdits.pick(&props, ReferenceTarget(id: ShapeID(), label: ""))
        expectEqual(props.frame.width, 64, "10 + 16 + 6 + 17 + 14 is under it")
        ReferenceEdits.pick(&props, ReferenceTarget(id: ShapeID(), label: "A"))
        expect(props.frame.width > 64, "a letter and the trailing glyph's room: \(props.frame.width)")
        ReferenceEdits.pick(&props, ReferenceTarget(id: ShapeID(), label: String(repeating: "wide ", count: 40)))
        expectEqual(props.frame.width, 280)
        ReferenceEdits.clear(&props)
        expectEqual(props.mode, .empty)
        expectEqual(props.frame, placed)
    },
    test("its schema: the target and the words are read-only, the query is text in the query language, and the flag is plain") {
        let h = try referenceHarness()
        let schema = try require(h.editor.registry.schema(for: Reference.kind)).json
        let properties = try require(schema["properties"]?.objectValue)
        expectEqual(properties["target"]?.objectValue?["readOnly"], true)
        expectEqual(properties["words"]?.objectValue?["readOnly"], true)
        expectEqual(properties["query"]?.objectValue?["format"], "x-canvas-query")
        expectEqual(properties["query"]?.objectValue?["readOnly"], nil)
        expectEqual(properties["all"]?.objectValue?["readOnly"], nil)
        expectEqual(properties["query"]?.objectValue?["maxLength"], 8_192)
        expectEqual(properties["words"]?.objectValue?["maxLength"], 500)
        expectEqual(schema["required"], ["frame"], "only its frame must be written")
    },
    test("it's never public, and holds no `public` property: nothing could stand for it") {
        let h = try referenceHarness()
        let registry = h.editor.registry
        expect(!registry.canBePublic(Reference.kind))
        expect(!registry.properties(for: Reference.kind).contains(PublicProperty.key))
    },
    test("its target is a name: a copy renames it with what's copied along and keeps it otherwise, and a deletion never looks for it") {
        let h = try referenceHarness()
        let box = h.addBox("shapes")
        let reference = h.addReference(to: box, label: "shapes")
        let record = try require(h.editor.document[reference])
        let copyOfBox = ShapeID()
        expectEqual(record.remappingReferences({ $0 == box ? copyOfBox : nil }, in: h.editor.shapeContext)?.typed(as: Reference.self)?.props.target?.id,
                    copyOfBox, "copied with its shape, it names the copy")
        expectEqual(record.remappingReferences({ _ in nil }, in: h.editor.shapeContext), record, "copied alone, it names the same one: a second reference to it")
        expectEqual(record.remappingReferences({ $0 == box ? copyOfBox : nil }, in: h.editor.shapeContext)?.typed(as: Reference.self)?.props.target?.label,
                    "shapes", "the name it held goes with it")
        h.editor.transact { $0.delete([box]) }
        expectEqual(h.reference(reference)?.target?.id, box, "deleting the shape wrote nothing to the reference")
    },
])
