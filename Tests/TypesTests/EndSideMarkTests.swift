import Adornments
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Geometry
import Mentions
import TestKit
import Types

// `from` and `to` beside an end's arrow that has no name: gray, above the arrow's anchor, there while the arrow is an
// end of a relationship type and its words are empty, gone once a name is typed, back when it is taken away. Over bonds,
// in `RelationScene`'s editor.

@MainActor private func mark(of arrow: ShapeID, in editor: CanvasEditor) -> AdornmentFrame? {
    editor.adornmentFrames(of: arrow).first { $0.adornment == .of(EndSideMark.self) }
}

@MainActor let endSideMarkTests = Suite("from and to beside an end", [
    test("an end's arrow with no name says from or to by its side, in the softer ink, above its anchor; one that is named says nothing") {
        let s = try RelationScene()
        let from = s.fromEnd(), to = s.toEnd()
        let first = try require(mark(of: from, in: s.editor))
        expectEqual(first.label.text, "from")
        expectEqual(first.label.lineInk, .secondary)
        expectEqual(try require(mark(of: to, in: s.editor)).label.text, "to")
        let anchor = try require(s.editor.adornmentAnchor(of: from))
        expect(first.rect.maxY <= anchor.minY + 0.5, "above the anchor: \(first.rect) \(anchor)")
        expect(first.rect.minX >= anchor.minX - 0.5 && first.rect.minX < anchor.midX, "at its left end")
        // A name typed on the arrow is the end's, and the word goes.
        s.editor.transact("Name") { $0.update(from, as: Bond.self) { $0.props.text = MentionText(plain: "layer") } }
        expect(mark(of: from, in: s.editor) == nil, "a name replaces it")
        expectEqual(try require(mark(of: to, in: s.editor)).label.text, "to", "the other end is as it was")
        s.editor.transact("Name") { $0.update(from, as: Bond.self) { $0.props.text = MentionText(plain: "") } }
        expectEqual(mark(of: from, in: s.editor)?.label.text, "from", "and back when the name is taken away")
        s.editor.undo()
        expect(mark(of: from, in: s.editor) == nil, "the undo brings the name back")
    },
    test("only an end has one: a relationship, a plain arrow, an arrow between two types and a note have none; a type unmarked takes them away") {
        let s = try RelationScene()
        let from = s.fromEnd(), to = s.toEnd()
        let relationship = s.relate(s.note, s.layerNote)
        let plain = s.editor.addBond(s.note, s.layerNote)
        let between = s.editor.addBond(s.feature, s.layer)
        for id in [relationship, plain, between, s.note, s.feature] { expect(mark(of: id, in: s.editor) == nil, "none on \(id)") }
        expect(mark(of: from, in: s.editor) != nil && mark(of: to, in: s.editor) != nil)
        // The mark taken off the relationship type: its arrows are plain, with no side to say.
        s.editor.makePlainTypes([s.rel])
        expect(mark(of: from, in: s.editor) == nil && mark(of: to, in: s.editor) == nil, "no relationship type, no sides")
        s.editor.undo()
        expect(mark(of: from, in: s.editor) != nil && mark(of: to, in: s.editor) != nil, "back by the undo")
    },
    test("an arrow aimed at the relationship type later gains it, and one aimed away loses it") {
        let s = try RelationScene()
        let arrow = s.editor.addBond(s.feature, nil)
        expect(mark(of: arrow, in: s.editor) == nil, "a free end is no end")
        s.editor.transact("Aim") { $0.update(arrow, as: Bond.self) { $0.props.to = s.rel } }
        expectEqual(mark(of: arrow, in: s.editor)?.label.text, "from")
        s.editor.transact("Aim") { $0.update(arrow, as: Bond.self) { $0.props.to = s.layer } }
        expect(mark(of: arrow, in: s.editor) == nil, "between two types: plain")
    },
    test("none zoomed out, where nothing is adorned") {
        let s = try RelationScene()
        let from = s.fromEnd()
        s.editor.camera = Camera(origin: .zero, zoom: 0.3)
        expect(mark(of: from, in: s.editor) == nil)
        s.editor.camera = Camera(origin: .zero, zoom: 0.35)
        expect(mark(of: from, in: s.editor) != nil)
    },
])
