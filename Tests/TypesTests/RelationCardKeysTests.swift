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
])
