import AppKit
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import CoreGraphics
import Foundation
import Mentions
import Selection
import TestKit
import Types

// keys in a relation card that no cell takes do not reach the canvas.

@MainActor let relationCardKeysTests = Suite("Keys in a row's card", [
    test("keys on a pill, on the blank line, and Delete on the blank line reach nothing of the canvas") {
        let r = try RowCardRig()
        defer { r.close() }
        r.s.relate(r.s.note, r.s.layerNote)
        expect(try r.open())
        let form = try require(r.form)
        let before = r.editor.document
        let tool = r.editor.currentToolID
        let selection = r.editor.selection
        for stop in [r.stop(0, 0), r.stop(1, 0)] {
            form.focus(stop)
            for key in ["\u{7f}", "\u{f728}"] where stop.line == 1 {
                r.window.press(key, code: key == "\u{7f}" ? 51 : 117)
            }
            for letter in ["x", "v", "r", "n", "e", "h", "t", "1"] where stop.line == 0 { r.window.press(letter) }
        }
        expectEqual(r.editor.document, before, "nothing written")
        expect(r.editor.document[r.s.note] != nil, "the note is still there")
        expectEqual(r.editor.currentToolID, tool, "the tool")
        expectEqual(r.editor.selection, selection)
    },
    test("a row's card is walked: Tab visits the pill and the blank line, ⇧Tab undoes each, a letter or Delete on the pill's neighbour changes nothing, Escape and Tab off the end give the canvas the keyboard; each stop is named") {
        let r = try RowCardRig()
        defer { r.close() }
        r.s.relate(r.s.note, r.s.layerNote)
        expect(try r.open())
        let form = try require(r.form)
        let walk = KeyWalk(r.window, editor: r.editor, readers: [.form({ [unowned r] in r.form }),
                                                                   .canvas(r.canvas, selection: { [unowned r] in r.editor.selectedShapeIDs.isEmpty ? [] : ["note"] })],
                           settle: .runLoop)
        let ids = formStopIDs(form)
        expectEqual(ids, ["card/d0/0.0", "card/d0/0.1", "card/d0/0.2", "card/d0/1.0"], "the arrow's line: its note and its fields; then the blank line")
        walk.expectCardStops(ids)
        r.cards.close()
        expect(try r.open())
        walk.expectShows(ids.map { Focus(surface: "card", element: String($0.dropFirst(5))) })
        let children = (form.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
        expectEqual(children.count, 4)
        expectEqual(children.first?.accessibilityRole(), .button, "the note's pill")
        expect(children.allSatisfy { !($0.accessibilityLabel() ?? "").isEmpty })
        let again = try require(r.form)
        again.focus(r.stop(1, 0))
        walk.press(.escape)
        expect(r.editor.card == nil)
        expect(r.window.firstResponder === r.canvas, "the canvas has the keyboard")
        expect(try r.open())
        r.form?.focus(r.stop(0, 0))
        let arrows = r.arrows
        walk.press(.delete)
        expect(r.arrows.count < arrows.count, "Delete on a stored line's pill takes the line out")
        expect(r.editor.card != nil)
    },
])
