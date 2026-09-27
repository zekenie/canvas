import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import Composition
import CoreGraphics
import Ellipses
import Foundation
import Geometry
import StickyNotes
import TaskCards
import TestKit

// The persistence plan's budgets, for boards of generated shapes: saving and opening, and one hover
// and one drag frame (the input, then drawing the whole canvas) at 60 fps. `./build.sh bench` runs
// these in a release build and holds them to the budgets; `./test.sh` runs them debug and small, so
// they keep working, and only reports.
#if DEBUG
let sizes = [300]
let holdsToBudgets = false
#else
let sizes = [1_000, 10_000]
let holdsToBudgets = true
#endif

/// Milliseconds.
enum Budget {
    static let open10k = 1_000.0
    static let frame = 16.0
}

/// Notes, tasks and ellipses in a grid, with an arrow from every fourth note to the note after it.
/// Every other note has a title, so frames draw pills.
@MainActor func generatedBoard(shapes count: Int) -> CanvasDocument {
    var shapes: [AnyShapeRecord] = []
    let columns = Int(Double(count).squareRoot().rounded(.up))
    var previousNote: ShapeID?
    var i = 0
    while shapes.count < count {
        let origin = CGPoint(x: (i % columns) * 260, y: (i / columns) * 260)
        switch i % 10 {
        case 0, 1:
            shapes.append(AnyShapeRecord(ShapeRecord(TaskCard(frame: CGRect(origin: origin, size: TaskCard.defaultSize), title: "Task \(i)",
                                                              status: .doing, estimate: 3))))
        case 2:
            shapes.append(AnyShapeRecord(ShapeRecord(Ellipse(frame: CGRect(origin: origin, size: CGSize(width: 160, height: 120))))))
        default:
            let note = ShapeRecord(StickyNote(frame: CGRect(origin: origin, size: StickyNote.defaultSize), text: "Note \(i): something to do",
                                              title: i % 2 == 0 ? "Title \(i)" : nil))
            shapes.append(AnyShapeRecord(note))
            if let previousNote, i % 4 == 0, shapes.count < count {
                let bound = { (id: ShapeID) in ArrowTerminal.bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)) }
                shapes.append(AnyShapeRecord(ShapeRecord(Arrow(start: bound(previousNote), end: bound(note.id)))))
            }
            previousNote = note.id
        }
        i += 1
    }
    return CanvasDocument(shapes: shapes)
}

/// The median of `runs` timings, in milliseconds.
@MainActor func median(runs: Int, _ body: () throws -> Void) rethrows -> Double {
    let clock = ContinuousClock()
    var times: [Double] = []
    for _ in 0..<runs {
        let elapsed = try clock.measure(body)
        times.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
    }
    return times.sorted()[times.count / 2]
}

@MainActor func draw(_ editor: CanvasEditor, into context: CGContext, size: CGSize) {
    editor.draw(in: context, bounds: CGRect(origin: .zero, size: size), dirtyRect: CGRect(origin: .zero, size: size))
}

@MainActor func report(_ line: String) { print("  \(line)") }

@MainActor let benchmarks = Suite("Benchmarks", [
    test("saving and opening a board stay within budget") {
        let registry = try ShippedPlugins.registry()
        let codec = BoardCodec(registry: registry)
        for size in sizes {
            let document = generatedBoard(shapes: size)
            var data = Data()
            let save = try median(runs: 5) { data = try codec.encode(document) }
            var opened: CanvasEditor?
            let open = try median(runs: 5) {
                opened = CanvasEditor(registry: registry, document: try codec.decode(data).document, scheduler: ManualScheduler())
            }
            expectEqual(opened?.document, document)
            report(String(format: "%6d shapes, %5.1f MB: save %7.1f ms, open %7.1f ms", size, Double(data.count) / 1e6, save, open))
            if holdsToBudgets, size >= 10_000 { expect(open < Budget.open10k, "opening \(size) shapes took \(open) ms") }
        }
    },
    test("a hover and a drag, each with the whole canvas redrawn, fit in a frame") {
        let viewport = CGSize(width: 1200, height: 800)
        let context = try require(CGContext(data: nil, width: Int(viewport.width), height: Int(viewport.height), bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: viewport.height)
        context.scaleBy(x: 1, y: -1)
        for size in sizes {
            let document = generatedBoard(shapes: size)
            let registry = try ShippedPlugins.registry()
            let h = EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }
            // The top-left of the board, where the first note is.
            let note = try require(document.shapes.first { $0.kind == StickyNote.kind })
            let center = CGPoint(x: try require(note.box).midX, y: try require(note.box).midY)
            var step = 0
            let hover = median(runs: 21) {
                step += 1
                h.move(to: center + CGPoint(x: CGFloat(step % 7), y: 0))
                draw(h.editor, into: context, size: viewport)
            }
            h.press(at: center)
            let drag = median(runs: 21) {
                step += 1
                h.drag(to: center + CGPoint(x: CGFloat(step), y: CGFloat(step) / 2))
                draw(h.editor, into: context, size: viewport)
            }
            // Where a frame's time goes: the input alone, and drawing alone.
            let dragInput = median(runs: 21) {
                step += 1
                h.drag(to: center + CGPoint(x: CGFloat(step), y: CGFloat(step) / 2))
            }
            h.release()
            let hoverInput = median(runs: 21) {
                step += 1
                h.move(to: center + CGPoint(x: CGFloat(step % 7), y: 0))
            }
            let drawing = median(runs: 21) { draw(h.editor, into: context, size: viewport) }
            report(String(format: "%6d shapes: hover %5.1f ms, drag %5.1f ms (budget %.0f); hover input %.1f, drag input %.1f, drawing %.1f",
                          size, hover, drag, Budget.frame, hoverInput, dragInput, drawing))
            if holdsToBudgets {
                expect(hover < Budget.frame, "a hover over \(size) shapes took \(hover) ms")
                expect(drag < Budget.frame, "a drag over \(size) shapes took \(drag) ms")
            }
        }
    },
])
