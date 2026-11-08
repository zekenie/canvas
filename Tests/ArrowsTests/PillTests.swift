import Adornments
import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import DetailPanel
import Foundation
import Geometry
import Mentions
import Selection
import TestKit
import Titles
import Types

// The pill that leads an arrow's label (Types' `RelationshipPill`, at Adornments' `inLabelLead`): an arrow of a relationship
// type has a label even with no words, a frame that is the pill and the words after it, centred where a label is, cut out of the
// line as a label is; its text goes after the pill; a short line gives the name alone, then a dot; zoomed out it is a capsule.
// An arrow with no relationship type has the label it always had (the parity goldens hold that); these hold the rest.

/// Two boxes `length` apart on a level line (edge to edge: 300 wide, centres `length + 300` apart), an arrow between them, with a type on
/// it: a relationship type named `owner` that holds a role and a date, or a plain type.
@MainActor
private struct PillBoard {
    let h: EditorHarness
    let arrow: ShapeID
    let type: ShapeID

    init(length: CGFloat = 400, degrees: CGFloat = 0, words: String = "", relationship: Bool = true, typed: Bool = true, bound: Bool = true) throws {
        h = try EditorHarness(plugins: arrowsPlugins(more: [DetailPanelPlugin(), LabelFixturesPlugin()]))
        let radians = degrees * CGFloat.pi / 180
        let reach = length + 100
        let first = CGPoint(x: 200, y: 400), second = CGPoint(x: first.x + reach * cos(radians), y: first.y + reach * sin(radians))
        let a = h.add(Box(CGRect(x: first.x - 50, y: first.y - 30, width: 100, height: 60)))
        let b = h.add(Box(CGRect(x: second.x - 50, y: second.y - 30, width: 100, height: 60)))
        func terminal(_ id: ShapeID) -> ArrowTerminal {
            .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
        }
        arrow = h.add(Arrow(start: terminal(a), end: terminal(b), text: MentionText(plain: words)))
        type = h.editor.addType("owner", at: CGRect(x: 3000, y: 3000, width: 200, height: 60))
        h.editor.transact { transaction in
            transaction.update(type) {
                $0[TypeSchemaProperty.self] = SchemaText(#"{"type": "object", "properties": {"since": {"type": "string"}, "primary": {"type": "string"}}}"#)
                if relationship { $0[RelationshipProperty.self] = true }
            }
        }
        if typed { h.editor.addTypeLink(type, to: arrow) }
    }

    var editor: CanvasEditor { h.editor }
    var geometry: ShapeGeometry? { editor.shapeContext.geometry(of: arrow) }
    var label: CGRect? { geometry?.label }
    var lead: CGRect? { geometry?.labelLead }
    var pill: AdornmentFrame? { editor.adornmentFrames(of: arrow).first { $0.adornment == .of(RelationshipPill.self) } }
    var middle: CGPoint? { editor.arrowGeometry(of: arrow)?.body.point(at: 0.5) }
}

@MainActor let arrowPillTests = Suite("The pill that leads an arrow's label", [
    test("an arrow of a relationship type has a label with no words: the pill and a padding of 4 around it, centred on the middle of its body") {
        let board = try PillBoard()
        let label = try require(board.label), lead = try require(board.lead), middle = try require(board.middle)
        expectEqual(lead.height, 18)
        expectEqual(label.size, CGSize(width: lead.width + 8, height: 26))
        expectEqual(lead, CGRect(x: label.minX + 4, y: label.minY + 4, width: lead.width, height: 18), "the pill within the label, a padding in")
        expect(abs(label.midX - middle.x) <= 1 && abs(label.midY - middle.y) <= 1, "centred: \(label) on \(middle)")
        expectEqual(board.pill?.rect, lead, "Adornments draws and points at the pill where the geometry kept it")
        expectEqual(board.pill?.label.text, "owner")
        expectEqual(board.editor.arrowLabelFrame(of: board.arrow), label)
    },
    test("an arrow with no relationship type, or a plain type, has no pill and no label: the label it always had") {
        for board in [try PillBoard(typed: false), try PillBoard(relationship: false)] {
            expectEqual(board.label, nil)
            expectEqual(board.lead, nil)
            expectEqual(board.pill, nil)
        }
        let plain = try PillBoard(words: "scall", relationship: false)
        let typed = try PillBoard(words: "scall", relationship: false, typed: false)
        expectEqual(plain.label, typed.label, "a plain type changes no frame")
        expectEqual(plain.lead, nil)
    },
    test("with words, the label is the pill and then the words as they are measured, the words' own padding the gap: wider by the pill and one padding") {
        let board = try PillBoard(words: "works at")
        let bare = try PillBoard(words: "works at", typed: false)
        let label = try require(board.label), lead = try require(board.lead), plain = try require(bare.label)
        expectEqual(label.width, plain.width + lead.width + 4)
        expectEqual(label.height, plain.height)
        expectEqual(lead.minX, label.minX + 4, "the pill leads")
        expectEqual(label.maxX - lead.maxX, plain.width, "and the words' frame is the words' alone, after it")
        let middle = try require(board.middle)
        expect(abs(label.midX - middle.x) <= 1, "the label, not the pill, is centred")
    },
    test("the body is cut around the whole label, the pill and the padding: no line shows between the pill's edge and the label's") {
        let board = try PillBoard()
        let bare = try PillBoard(typed: false)
        let label = try require(board.label), lead = try require(board.lead)
        let size = CGSize(width: 700, height: 700)
        let drawn = renderBitmap(board.editor, size: size), plain = renderBitmap(bare.editor, size: size)
        let y = label.midY
        expect(changedPixels(drawn, plain, in: CGRect(x: label.minX - 20, y: y - 3, width: 20, height: 6)) == 0, "the line left of the label is as it was")
        let gap = CGRect(x: label.minX + 1, y: y - 3, width: lead.minX - label.minX - 2, height: 6)
        expect(changedPixels(drawn, plain, in: gap) > 0, "the line is gone in the padding left of the pill")
    },
    test("slanted, the label is centred on the middle of the body at every slope, and the pill is in it") {
        for degrees: CGFloat in [0, 20, 35, -35, 70, 90, -90] {
            let board = try PillBoard(degrees: degrees)
            let label = try require(board.label), lead = try require(board.lead), middle = try require(board.middle)
            expect(abs(label.midX - middle.x) <= 1 && abs(label.midY - middle.y) <= 1, "\(degrees)°: \(label) on \(middle)")
            expect(label.contains(lead), "\(degrees)°")
            expectEqual(board.pill?.rect, lead)
        }
    },
    test("a shorter line gives the name alone, then a dot, never a pill wider than the room: the label is no wider than the body less 64") {
        var widths: [CGFloat] = []
        for length: CGFloat in [500, 160, 120, 60] {
            let board = try PillBoard(length: length)
            let lead = try require(board.lead), body = try require(board.editor.arrowGeometry(of: board.arrow)?.body)
            widths.append(lead.width)
            let label = try require(board.label)
            if lead.width > 10 { expect(label.width <= body.length - 64, "\(length): \(label.width) in \(body.length)") }
        }
        expect(widths[0] >= widths[1] && widths[1] > widths[2] && widths[2] >= widths[3], "narrower as the line shortens: \(widths)")
        expectEqual(widths.last, 10, "a dot on the shortest")
        let board = try PillBoard(length: 60)
        expectEqual(board.pill?.label.mark, .dot)
        expectEqual(board.pill?.label.tag, AdornmentTag(board.type), "and the dot is still the pill: it is clicked as one")
        expectEqual(board.lead?.height, 10)
    },
    test("the name alone when the line has no room for the value: the face that fits is chosen with no commit to the arrow") {
        let wide = try PillBoard(length: 500)
        wide.editor.fieldWriter?.set("2021", at: FieldPath(field: "since"), of: wide.arrow)
        expectEqual(wide.pill?.label.note, "2021")
        let name = try PillBoard(length: 150)
        name.editor.fieldWriter?.set("2021", at: FieldPath(field: "since"), of: name.arrow)
        expectEqual(name.pill?.label.text, "owner")
        expectEqual(name.pill?.label.note, nil, "the value drops first")
    },
    test("the label follows a rename and a value with no commit where none was made, and the arrow is not written") {
        let board = try PillBoard(length: 500)
        let record = board.editor.document[board.arrow]
        let width = try require(board.lead).width
        board.editor.rename(board.type, to: "owner or primary driver")
        expect(try require(board.lead).width > width, "the room is wider for a longer name")
        expectEqual(board.editor.document[board.arrow], record, "nothing written to the arrow")
        let longer = try require(board.label).width
        board.editor.undo()
        expectEqual(try require(board.lead).width, width, "and narrower again by the undo")
        expect(try require(board.label).width < longer)
        board.editor.fieldWriter?.set("2021", at: FieldPath(field: "since"), of: board.arrow)
        expect(try require(board.lead).width > width, "a value typed widens it")
    },
    test("a label edited has the editor over its words alone, after the pill; typing the first word changes nothing about the pill") {
        let board = try PillBoard()
        let lead = try require(board.lead)
        board.editor.selection = board.arrow
        expect(board.editor.beginEditing(board.arrow))
        let label = try require(board.label)
        let editing = try require(board.editor.editingFrame)
        expect(editing.width > 0 && editing.width < 20, "an empty label is as wide as an \"i\": \(editing)")
        expectEqual(editing.height, 26)
        // The label grows about its middle, as a label does, so the pill moves left by half of what is added; the editor is after it.
        expect(editing.minX > label.minX + 4 + lead.width - 20 && editing.maxX > label.maxX - 20, "the editor is in the label's words' place: \(editing) in \(label)")
        board.editor.endEditing()
        expectEqual(board.lead, lead)
    },
    test("the words are found where they are drawn: Find's and Mentions' placement is the words' frame, after the pill") {
        let board = try PillBoard(words: "works at")
        let geometry = try require(board.geometry)
        let label = try require(geometry.label), lead = try require(geometry.labelLead)
        let words = CGRect(x: lead.maxX, y: label.minY, width: label.maxX - lead.maxX, height: label.height)
        let bare = try require(try PillBoard(words: "works at", typed: false).label)
        expectEqual(words.size, bare.size, "the words have the room the same words have with no pill")
        expect(try require(board.editor.arrowGeometry(of: board.arrow)).bodyPath.boundingBoxOfPath.width > 0)
    },
    test("zoomed out a capsule of the pill's size sits in the type's tint where it is, with no letters, and the line runs whole through it") {
        let board = try PillBoard(length: 400)
        let bare = try PillBoard(length: 400, typed: false)
        let lead = try require(board.lead)
        for editor in [board.editor, bare.editor] { editor.camera = Camera(origin: .zero, zoom: 0.3) }
        expect(board.editor.drawsSkeletons)
        let size = CGSize(width: 300, height: 200)
        let drawn = renderBitmap(board.editor, size: size), plain = renderBitmap(bare.editor, size: size)
        let box = CGRect(x: lead.minX * 0.3, y: lead.minY * 0.3, width: lead.width * 0.3, height: lead.height * 0.3)
        expect(changedPixels(drawn, plain, in: box.insetBy(dx: -1, dy: -1)) > 0, "a capsule where the pill is")
        // Nothing beyond it: not above, not below, not before or after.
        expectEqual(changedPixels(drawn, plain, in: CGRect(x: 0, y: 0, width: size.width, height: box.minY - 2)), 0)
        expectEqual(changedPixels(drawn, plain, in: CGRect(x: 0, y: box.maxY + 2, width: size.width, height: size.height - box.maxY - 2)), 0)
        expectEqual(changedPixels(drawn, plain, in: CGRect(x: 0, y: 0, width: box.minX - 2, height: size.height)), 0)
        expectEqual(changedPixels(drawn, plain, in: CGRect(x: box.maxX + 2, y: 0, width: size.width - box.maxX - 2, height: size.height)), 0)
        expectEqual(board.editor.adornmentFrames(of: board.arrow), [], "Adornments shows none on a skeleton")
    },
    test("the bend handle is not on the pill: an arrow with a pill hides it where it would cover the name, and a plain arrow's stays") {
        let board = try PillBoard()
        board.editor.selection = board.arrow
        let middle = board.editor.camera.toView(try require(board.editor.arrowGeometry(of: board.arrow)).middle)
        expectEqual(board.editor.handle(atViewPoint: middle), nil, "no bend handle over the pill")
        let plain = try PillBoard(typed: false)
        plain.editor.selection = plain.arrow
        let there = plain.editor.camera.toView(try require(plain.editor.arrowGeometry(of: plain.arrow)).middle)
        expectEqual(plain.editor.handle(atViewPoint: there), AnyHashable(ArrowHandle.middle), "a plain arrow keeps it")
    },
])
