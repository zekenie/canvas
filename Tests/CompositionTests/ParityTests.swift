import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Composition
import Connections
import CoreGraphics
import Geometry
import LanguageModels
import Selection
import StickyNotes
import TestKit

// Pixel goldens rendered by the untouched POC's CanvasView (Fixtures/poc-*.png, recorded with
// Replay.swift's `snapshot`: aqua, 2×, the accent pinned to blue, as main.swift pins it here).
// Every pixel must match.
//
// An intended deviation, as TranscriptTests' `intendedDeviations` are: the POC predates skeletons
// and drew every shape in full at every zoom, while the app draws notes and arrows as their
// skeletons below 35% (`editor.skeletonZoom`) on purpose, and outlines them as their skeletons
// are drawn (an arrow by its skeleton's arc, a rect as a filled ring), so "re-aimed-zoomed-out", at
// 15%, would differ in the shapes and their outlines. What its golden holds the app to is how an
// arrow is re-aimed and drawn in full (its outline, binding hints and handles), so every board
// here is drawn in full at every zoom (`skeletonZoom = 0`, host SPI), as the POC drew it; what the
// app draws below 35% is held by the skeleton tests. A second intended deviation: the POC outlined
// a shape on its own edge (B outlined as the arrow's target hugs it in "re-aiming-into-b"), where
// the app stands every closed shape's outline off its edge by 4 view points (`Style.outlineStandoff`),
// so every board here is drawn with no standoff (`outlineStandoff = 0`, host SPI), as the POC drew
// it; what the app draws is held by CanvasTests' outline tests. A third: the app shows the zoom
// above the minimap while it changes, which the POC had no such thing as, so the snapshots leave
// it out (`zoomIndicator`, hidden), and CanvasUITests hold it. The goldens stay as the POC
// recorded them.

/// Compares a snapshot of `view` with Fixtures/poc-<name>.png; on a difference, writes the
/// snapshot to build/parity-<name>.png.
@MainActor func expectMatchesPOC(_ view: NSView, _ name: String, file: StaticString = #fileID, line: UInt = #line) throws {
    (view as? CanvasView)?.zoomIndicator.isHidden = true
    let rep = snapshot(view)
    let golden = try require(NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: "Tests/CompositionTests/Fixtures/poc-\(name).png"))),
                             file: file, line: line)
    expectEqual(rep.pixelsWide, golden.pixelsWide, "\(name): width", file: file, line: line)
    expectEqual(rep.pixelsHigh, golden.pixelsHigh, "\(name): height", file: file, line: line)
    var differing = 0
    var p = [Int](repeating: 0, count: 4), q = [Int](repeating: 0, count: 4)
    // Byte-identical buffers are the usual case, and quick to check. (A PNG loads unpremultiplied,
    // which only matters for pixels that aren't opaque, and the canvas has none.)
    let layout = { (r: NSBitmapImageRep) in r.bitmapFormat.subtracting(.alphaNonpremultiplied) }
    let sameBytes = layout(rep) == layout(golden) && rep.bitsPerPixel == golden.bitsPerPixel
        && rep.bytesPerRow == golden.bytesPerRow && rep.pixelsHigh == golden.pixelsHigh
        && memcmp(rep.bitmapData!, golden.bitmapData!, rep.bytesPerRow * rep.pixelsHigh) == 0
    for y in 0..<(sameBytes ? 0 : min(rep.pixelsHigh, golden.pixelsHigh)) {
        for x in 0..<min(rep.pixelsWide, golden.pixelsWide) {
            rep.getPixel(&p, atX: x, y: y); golden.getPixel(&q, atX: x, y: y)
            if p != q { differing += 1 }
        }
    }
    if differing > 0 {
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "build/parity-\(name).png"))
    }
    expectEqual(differing, 0, "\(name): differing pixels; see build/parity-\(name).png", file: file, line: line)
}

/// The POC's welcome board text (804db97), verbatim. The shipped board's third note says how the
/// hand tool and the marquee work instead, and its fourth and fifth how notes are linked from their
/// ports (no arrow tool, and no ellipse); the goldens come only from the POC, so the welcome renders
/// use these.
let pocWelcomeTexts = [
    "Double-click empty space to add a note. Drag a note to move it.",
    "Double-click a note (or select it and press Return) to edit it.",
    "Pinch to zoom, scroll with two fingers to pan. Dragging the background pans too.",
    "Press A for the arrow tool, then drag from one shape to another. Press O to place an ellipse.",
    "Pause inside a note while drawing to aim at that spot. Hold ⌥ to go all the way in, ⌘ to not attach.",
    "Select an arrow and drag its middle handle to bend it.",
]

@MainActor let parityTests = Suite("Pixel parity", [
    test("the welcome board, a selected bent arrow, and a zoomed selection render identically") {
        let editor = ShippedPlugins.makeEditor(document: WelcomeBoard.document(texts: pocWelcomeTexts), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        editor.skeletonZoom = 0     // in full at every zoom, as the POC drew (above)
        editor.outlineStandoff = 0  // outlines on the shapes' edges, as the POC drew (above)
        let canvas = CanvasView(editor: editor)
        canvas.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let arrows = editor.document.shapes.filter { $0.kind == Arrow.kind }.map(\.id)
        let notes = editor.document.shapes.filter { $0.kind == StickyNote.kind }.map(\.id)
        try expectMatchesPOC(canvas, "welcome")
        editor.selection = arrows[2]
        try expectMatchesPOC(canvas, "selected-arrow")
        editor.camera.setZoom(0.6, around: CGPoint(x: 300, y: 200))
        editor.selection = notes[1]
        try expectMatchesPOC(canvas, "zoomed")
    },
    // Target outlines, binding hints, handles and halos, reached with the same NSEvents as in the POC.
    test("arrow interactions render identically mid-gesture: outlines, hints, handles and halos") {
        for (name, withArrow, steps) in interactions {
            let board = Board(withArrow: withArrow, texts: noteTexts)
            // In full at every zoom, as the POC drew: "re-aimed-zoomed-out" is at 15%, where the app
            // draws skeletons on purpose (above).
            board.editor.skeletonZoom = 0
            board.editor.outlineStandoff = 0        // and B outlined as the target on its edge, as the POC drew
            board.player.play(steps)
            try expectMatchesPOC(board.canvas, name)
        }
    },
])
