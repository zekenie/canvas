import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Composition
import CoreGraphics
import Foundation
import Geometry
import Selection
import StickyNotes
import TestKit

// The arrow regression gate. Fixtures/arrow-transcript.txt was recorded from the untouched POC
// (804db97) by feeding its CanvasView the steps in Replay.swift as real NSEvents. Here the same
// Player feeds the same NSEvents to today's CanvasView, with the shipped plugins and a manual clock
// for the timers; the text must match byte for byte.

/// Today's canvas set up for a scenario: two notes, and an arrow between their centers with this
/// bend, if given.
@MainActor
struct Board {
    let editor: CanvasEditor
    let canvas: CanvasView
    let a: ShapeID
    let b: ShapeID
    let player: Player

    init(withArrow bend: CGFloat?, texts: (String, String) = ("", "")) {
        let a = ShapeRecord(StickyNote(frame: A, text: texts.0)), b = ShapeRecord(StickyNote(frame: B, text: texts.1))
        func bound(_ note: ShapeRecord<StickyNote>) -> ArrowTerminal {
            .bound(ArrowBinding(shapeID: note.id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
        }
        var shapes = [AnyShapeRecord(a), AnyShapeRecord(b)]
        if let bend { shapes.append(AnyShapeRecord(ShapeRecord(Arrow(start: bound(a), end: bound(b), bend: bend)))) }
        let scheduler = ManualScheduler()
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(shapes: shapes), scheduler: scheduler)
        let canvas = CanvasView(editor: editor)
        // CanvasView.init points this at NSEvent.modifierFlags, the real keyboard. The POC read that
        // in its timers too, and nobody held a key while it was recorded.
        editor.liveModifiers = { [] }
        let arrowIDs = { editor.document.shapes.filter { $0.kind == Arrow.kind }.map(\.id) }
        let noteIDs = { editor.document.shapes.filter { $0.kind != Arrow.kind }.map(\.id) }
        player = Player(canvas, wait: { scheduler.advance(by: .milliseconds($0)) }, direct: { step in
            switch step {
            case .selectArrow(let i): editor.selection = arrowIDs()[i]
            case .selectShape(let i): editor.selection = noteIDs()[i]
            case .zoom(let zoom, let anchor): editor.camera.setZoom(zoom, around: anchor)
            default: fatalError("\(step) is an event")
            }
        })
        (self.editor, self.canvas, self.a, self.b) = (editor, canvas, a.id, b.id)
    }
}

func describe(_ terminal: ArrowTerminal, _ ids: [ShapeID]) -> String {
    func r(_ v: CGFloat) -> String { String(format: "%.6f", Double(v)) }
    switch terminal {
    case .free(let p): return "free(\(r(p.x)),\(r(p.y)))"
    case .bound(let b):
        let index = ids.firstIndex(of: b.shapeID).map(String.init) ?? "?"
        return "bound(#\(index),\(r(b.normalizedAnchor.x)),\(r(b.normalizedAnchor.y)),\(b.isPrecise ? "precise" : "imprecise")\(b.isExact ? ",exact" : ""))"
    }
}

@MainActor func transcript() -> String {
    var lines: [String] = []
    for (name, withArrow, steps) in scenarios {
        let board = Board(withArrow: withArrow)
        board.player.play(steps)
        board.player.sleep(200)
        let editor = board.editor, ids = [board.a, board.b]
        let notes = editor.document.shapes.filter { $0.kind != Arrow.kind }
            .map { s in "#\(ids.firstIndex(of: s.id).map(String.init) ?? "new")@\(s.box!)" }.joined(separator: " ")
        lines.append("\(name): tool=\(editor.currentToolID.rawValue) camera=\(editor.camera.origin) shapes=[\(notes)]")
        for record in editor.document.shapes {
            guard let arrow = record.typed(as: Arrow.self)?.props else { continue }
            lines.append("    \(describe(arrow.start, ids)) -> \(describe(arrow.end, ids)) bend=\(String(format: "%.6f", Double(arrow.bend))) heads=\(arrow.startArrowhead),\(arrow.endArrowhead)")
        }
    }
    return lines.joined(separator: "\n") + "\n"
}

/// Where the app ends a scenario differently from the POC on purpose, line for line: the golden's
/// line, and the app's. The fixture stays as the POC recorded it.
///
/// "move shape": the POC brought a pressed shape to the front, and the app doesn't (tldraw doesn't
/// either), so the note dragged, #0, stays behind #1. Only the notes' order differs: every
/// position, and every arrow, is the POC's.
let intendedDeviations: [(golden: String, app: String)] = [
    ("move shape: tool=select camera=(0.0, 0.0) shapes=[#1@(460.0, 80.0, 200.0, 200.0) #0@(130.0, 150.0, 200.0, 200.0)]",
     "move shape: tool=select camera=(0.0, 0.0) shapes=[#0@(130.0, 150.0, 200.0, 200.0) #1@(460.0, 80.0, 200.0, 200.0)]"),
]

@MainActor let transcriptTests = Suite("Arrow transcript", [
    test("every scenario, fed to the canvas view as NSEvents, ends exactly as it did in the POC, less the intended deviations") {
        var golden = try String(contentsOfFile: "Tests/CompositionTests/Fixtures/arrow-transcript.txt", encoding: .utf8)
        for deviation in intendedDeviations {
            let lines = golden.components(separatedBy: "\n")
            expectEqual(lines.filter { $0 == deviation.golden }.count, 1, "a deviation names exactly one line of the POC's transcript")
            golden = lines.map { $0 == deviation.golden ? deviation.app : $0 }.joined(separator: "\n")
        }
        let actual = transcript()
        if actual != golden {
            try? actual.write(toFile: "build/arrow-transcript.actual.txt", atomically: true, encoding: .utf8)
            let diff = zip(golden.split(separator: "\n"), actual.split(separator: "\n")).filter { $0 != $1 }.prefix(5)
            for (g, a) in diff { print("  golden: \(g)\n  actual: \(a)") }
        }
        expect(actual == golden, "see build/arrow-transcript.actual.txt")
    },
])
