import Adornments
import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Checklists
import Composition
import CoreGraphics
import Ellipses
import Foundation
import Geometry
import Locking
import Selection
import StickyNotes
import TableOfContents
import TaskCards
import TestKit
import Titles
import Validation

// The persistence plan's budgets, for boards of generated shapes: saving and opening, validation's
// first read (every shape checked, against its kind's schema too) and its read after moving them
// all, and one hover and one drag frame (the input, then drawing the whole canvas, and the minimap
// with it), on a note, from a note's port and onto a title's pill, at 60 fps. `./build.sh bench`
// runs these in a release build and holds them to the budgets; `./test.sh` runs them debug and
// small, so they keep working, and only reports.
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
    /// Reading the table of contents' rows after a commit that changed a shape or two.
    static let contentsRows = 1.0
    /// Validation's first read of 10,000 shapes' issues, each shape checked against its kind's
    /// schema too: once, on the first frame after opening.
    static let validation10k = 100.0
    /// Validation's read after a commit that changed a shape or two.
    static let validationAfterCommit = 1.0
    /// Validation's read after a drag event that moved all 10,000 shapes (⌘A, then a drag): each
    /// moved shape's rules run again, but not its schema check, which moving a shape can't change
    /// (with it, some 30 ms). The drag event's own commit, before it, costs more than a frame.
    static let validationAfterMovingAll10k = 16.0
}

/// Notes, tasks and ellipses in a grid, with an arrow from every fourth note to the note after it.
/// Every other note has a title, so frames draw pills, and every fourth a checklist of two, so they
/// draw checklist chips (a task shows none); every task has a checklist of three, so boards save and
/// open added values; and every ellipse is locked, so frames draw lock chips.
@MainActor func generatedBoard(shapes count: Int) -> CanvasDocument {
    var shapes: [AnyShapeRecord] = []
    let columns = Int(Double(count).squareRoot().rounded(.up))
    var previousNote: ShapeID?
    var i = 0
    while shapes.count < count {
        let origin = CGPoint(x: (i % columns) * 260, y: (i / columns) * 260)
        switch i % 10 {
        case 0, 1:
            var task = AnyShapeRecord(ShapeRecord(TaskCard(frame: CGRect(origin: origin, size: TaskCard.defaultSize), status: .doing, estimate: 3)))
            task[TitleProperty.self] = "Task \(i)"
            task[ChecklistProperty.self] = [ChecklistItem(text: "Spec", isDone: true), ChecklistItem(text: "Build"), ChecklistItem(text: "Ship")]
            shapes.append(task)
        case 2:
            var ellipse = AnyShapeRecord(ShapeRecord(Ellipse(frame: CGRect(origin: origin, size: CGSize(width: 160, height: 120)))))
            ellipse[LockedProperty.self] = true
            shapes.append(ellipse)
        default:
            var note = ShapeRecord(StickyNote(frame: CGRect(origin: origin, size: StickyNote.defaultSize), text: "Note \(i): something to do"))
            note[TitleProperty.self] = i % 2 == 0 ? "Title \(i)" : nil
            note[ChecklistProperty.self] = i % 4 == 3 ? [ChecklistItem(text: "Draft", isDone: true), ChecklistItem(text: "Send")] : []
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

extension Duration {
    var milliseconds: Double { Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15 }
}

/// The median of `runs` timings of `body`, in milliseconds, each after an untimed `prepare`.
@MainActor func median(runs: Int, prepare: () -> Void = {}, _ body: () throws -> Void) rethrows -> Double {
    let clock = ContinuousClock()
    var times: [Double] = []
    for _ in 0..<runs {
        prepare()
        times.append(try clock.measure(body).milliseconds)
    }
    return times.sorted()[times.count / 2]
}

/// Every row, nested ones included.
@MainActor func rowCount(_ entries: [ContentsEntry]) -> Int { entries.reduce(0) { $0 + 1 + rowCount($1.children ?? []) } }

@MainActor func draw(_ editor: CanvasEditor, into context: CGContext, size: CGSize) {
    editor.draw(in: context, bounds: CGRect(origin: .zero, size: size), dirtyRect: CGRect(origin: .zero, size: size))
}

@MainActor func report(_ line: String) { print("  \(line)") }

/// Draws a view as its window would, into `context` (sized to it, y down).
@MainActor func display(_ view: NSView, into context: CGContext) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    view.draw(view.bounds)
    NSGraphicsContext.restoreGraphicsState()
}

@MainActor func bitmapContext(_ size: CGSize, scale: CGFloat = 1) throws -> CGContext {
    let context = try require(CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.translateBy(x: 0, y: size.height * scale)
    context.scaleBy(x: scale, y: -scale)
    return context
}

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
            expectEqual(opened?.document, registry.fillingDefaults(document))
            report(String(format: "%6d shapes, %5.1f MB: save %7.1f ms, open %7.1f ms", size, Double(data.count) / 1e6, save, open))
            if holdsToBudgets, size >= 10_000 { expect(open < Budget.open10k, "opening \(size) shapes took \(open) ms") }
        }
    },
    test("validation's first read checks every shape, against its kind's schema too; a drag checks the dragged shapes again, but not their schemas") {
        for size in sizes {
            let document = generatedBoard(shapes: size)
            let registry = try ShippedPlugins.registry()
            var editor = CanvasEditor(registry: registry, document: document, scheduler: ManualScheduler())
            let first = median(runs: 5, prepare: { editor = CanvasEditor(registry: registry, document: document, scheduler: ManualScheduler()) }) {
                _ = editor.validation?.results
            }
            let schemas = median(runs: 5) {
                for shape in document.shapes { _ = registry.schemaViolations(of: shape) }
            }
            let note = try require(document.shapes.first { $0.kind == StickyNote.kind })
            var step = 0.0
            let again = median(runs: 21, prepare: {
                step += 1
                editor.transact { $0.update(note.id) { $0.box = $0.box?.offsetBy(dx: 1, dy: step) } }
            }) { _ = editor.validation?.results }
            // ⌘A, and a drag from a note, as a user moves the whole board: every shape moves on every
            // drag event (but the locked ellipses, and the arrows with their notes).
            let h = EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }
            _ = h.editor.validation?.results
            h.hold(.command)
            h.key("a")
            h.hold([])
            let center = CGPoint(x: try require(note.box).midX, y: try require(note.box).midY)
            // Once ⌘, let go, no longer counts as held: a press with it would brush.
            h.press(at: center, after: 200)
            var nudge = 0.0
            let all = median(runs: 11, prepare: {
                nudge += 1
                h.drag(to: center + CGPoint(x: nudge, y: 0))
            }) { _ = h.editor.validation?.results }
            expectEqual(h.editor.document[note.id]?.box?.origin.x, (note.box?.origin.x ?? 0) + nudge, "the drag moves what ⌘A selected")
            h.release()
            expectEqual(editor.validation?.results.isEmpty, true, "the generated board has no issues")
            report(String(format: "%6d shapes, validation: first read %6.1f ms (budget %.0f), of which the schemas about %6.1f; after a drag event %6.3f (budget %.0f); after moving them all %6.2f (budget %.0f)",
                          size, first, Budget.validation10k, schemas, again, Budget.validationAfterCommit, all, Budget.validationAfterMovingAll10k))
            if holdsToBudgets {
                if size >= 10_000 {
                    expect(first < Budget.validation10k, "validation's first read of \(size) shapes took \(first) ms")
                    expect(all < Budget.validationAfterMovingAll10k, "validation after moving all \(size) shapes took \(all) ms")
                }
                expect(again < Budget.validationAfterCommit, "validation after a drag event on \(size) shapes took \(again) ms")
            }
        }
    },
    test("a hover, a drag and a hover onto a title's pill, each with the whole canvas redrawn, fit in a frame") {
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
            // A hover onto a titled note's pill, which is its note's (Selection's `DecorationHits`): the
            // first note whose pill is in view (the first row's are above it).
            @MainActor func pill(of record: AnyShapeRecord) -> CGRect? {
                h.editor.adornmentFrames(of: record.id).first { $0.adornment == .of(TitlePill.self) }?.rect
            }
            let inView = CGRect(origin: .zero, size: viewport)
            // Notes only: an ellipse's derived title shows a pill too, and comes first at 1,000 and
            // 10,000 shapes.
            let titled = try require(h.editor.document.shapes.first {
                $0.kind == StickyNote.kind && (pill(of: $0).map { inView.contains(h.editor.camera.toView($0)) } ?? false)
            }, "a titled note's pill in view")
            let titledPill = try require(pill(of: titled))
            let onPill = median(runs: 21) {
                step += 1
                h.move(to: h.view(CGPoint(x: titledPill.minX + 10 + CGFloat(step % 7), y: titledPill.midY)))
                draw(h.editor, into: context, size: viewport)
            }
            expectEqual(h.editor.hovered, titled.id, "the pill is its note's")
            // Zoomed out to fit the board (as far as the zoom goes), the first frame makes the labels of
            // every adorned shape in view, and the next draws what's kept. Reported, with no budget.
            h.editor.camera = Camera(fitting: h.editor.shapeBounds, in: viewport, inset: 0)
            let clock = ContinuousClock()
            let zoomedOut = clock.measure { draw(h.editor, into: context, size: viewport) }.milliseconds
            let zoomedOutAgain = clock.measure { draw(h.editor, into: context, size: viewport) }.milliseconds
            report(String(format: "%6d shapes: a hover onto a titled note's pill %5.1f ms (budget %.0f); zoomed out to fit the board (%.0f%%), the first frame %.1f, the next %.1f",
                          size, onPill, Budget.frame, h.editor.camera.zoom * 100, zoomedOut, zoomedOutAgain))
            if holdsToBudgets {
                expect(onPill < Budget.frame, "a hover onto a titled note's pill over \(size) shapes took \(onPill) ms")
            }
        }
    },
    test("a hover on a note's dot, and a drag from it drawing an arrow across the board, each with the whole canvas redrawn, fit in a frame") {
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        for size in sizes {
            let document = generatedBoard(shapes: size)
            let registry = try ShippedPlugins.registry()
            let h = EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }
            // The first note's bottom dot, 12 points below it in the gap between the rows, where no
            // arrow leaves it.
            let note = try require(document.shapes.first { $0.kind == StickyNote.kind }?.box)
            let dot = CGPoint(x: note.midX, y: note.maxY + 12)
            h.move(to: CGPoint(x: note.midX, y: note.midY))
            var step = 0
            let hover = median(runs: 21) {
                step += 1
                h.move(to: dot + CGPoint(x: CGFloat(step % 7) - 3, y: 0))
                draw(h.editor, into: context, size: viewport)
            }
            expectEqual(h.editor.cursor, .openHand, "the pointer is on the dot")
            let hoverInput = median(runs: 21) {
                step += 1
                h.move(to: dot + CGPoint(x: CGFloat(step % 7) - 3, y: 0))
            }
            // Pressed there and dragged round a circle over the rows in view: notes, which take the
            // arrow, and tasks and ellipses, which don't.
            let around = { (turn: Int) in
                CGPoint(x: 700 + 300 * cos(CGFloat(turn) * .pi / 21), y: 450 + 300 * sin(CGFloat(turn) * .pi / 21))
            }
            h.press(at: dot)
            h.drag(to: around(0))
            expectEqual(h.editor.document.shapes.count, size + 1, "an arrow is being drawn")
            var turn = 0
            let drag = median(runs: 21) {
                turn += 1
                h.drag(to: around(turn))
                draw(h.editor, into: context, size: viewport)
            }
            let dragInput = median(runs: 21) {
                turn += 1
                h.drag(to: around(turn))
            }
            h.release()
            report(String(format: "%6d shapes: hover on a note's dot %5.1f ms, drag from it %5.1f ms (budget %.0f); hover input %.1f, drag input %.1f",
                          size, hover, drag, Budget.frame, hoverInput, dragInput))
            if holdsToBudgets {
                expect(hover < Budget.frame, "a hover on a note's dot over \(size) shapes took \(hover) ms")
                expect(drag < Budget.frame, "a drag from a note's dot over \(size) shapes took \(drag) ms")
            }
        }
    },
    test("the table of contents' rows cost what a commit changed, not what's on the board") {
        for size in sizes {
            let document = generatedBoard(shapes: size)
            let registry = try ShippedPlugins.registry()
            let h = EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }
            let contents = try require(h.editor.tableOfContents)
            let note = try require(document.shapes.first { $0.kind == StickyNote.kind })
            let center = CGPoint(x: try require(note.box).midX, y: try require(note.box).midY)
            var step = 0
            let dragNote = {
                step += 1
                h.drag(to: center + CGPoint(x: CGFloat(step), y: CGFloat(step) / 2))
            }
            // Pressing the note selects it, which lists it alone. The rows read are held until the
            // next read, as the list holds the rows it shows.
            h.press(at: center)
            var rows = contents.entries
            let alone = median(runs: 21, prepare: dragNote) { rows = contents.entries }
            expectEqual(rowCount(rows), 1)
            // Show All lists every shape again, through the drag and after it.
            contents.showAll()
            rows = contents.entries
            let drag = median(runs: 21, prepare: dragNote) { rows = contents.entries }
            h.release()
            var added: [ShapeID] = []
            let insert = median(runs: 21, prepare: {
                added.append(h.editor.add(StickyNote(frame: CGRect(x: -1000, y: -1000, width: 200, height: 200), text: "Added")))
            }) { rows = contents.entries }
            let delete = median(runs: 21, prepare: {
                let id = added.removeLast()
                h.editor.transact { $0.delete([id]) }
            }) { rows = contents.entries }
            var restacked = 0
            // Unlocked shapes only: a locked one's restack is refused, and would time nothing.
            let restackable = document.shapes.filter { !$0.isLocked }
            let restack = median(runs: 21, prepare: {
                restacked += 1
                let id = restackable[restacked * restackable.count / 22].id
                h.editor.transact { $0.bringToFront(id) }
            }) { rows = contents.entries }
            expect(contents.scope == nil, "every shape is listed")
            expectEqual(rowCount(rows), size)
            report(String(format: "%6d shapes, the table of contents' rows: after a drag event %6.3f ms (budget %.0f), %6.3f listing only the dragged shape; after an insert %6.3f, a delete %6.3f, a restack %6.3f",
                          size, drag, Budget.contentsRows, alone, insert, delete, restack))
            if holdsToBudgets {
                for (what, time) in [("a drag event", drag), ("a drag event, listing only the dragged shape,", alone), ("an insert", insert),
                                     ("a delete", delete), ("a restack", restack)] {
                    expect(time < Budget.contentsRows, "reading the rows after \(what) on \(size) shapes took \(time) ms")
                }
            }
        }
    },
    test("the minimap draws a board a frame's worth at a time, and a drag redraws only what moved") {
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        for size in sizes {
            let document = generatedBoard(shapes: size)
            let registry = try ShippedPlugins.registry()
            let h = EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: viewport), styleMask: [.titled], backing: .buffered, defer: false)
            let canvas = CanvasView(editor: h.editor)
            window.contentView = canvas
            canvas.showsMinimap = true
            let minimap = try require(canvas.minimap)
            let minimapContext = try bitmapContext(minimap.bounds.size, scale: window.backingScaleFactor)
            draw(h.editor, into: context, size: viewport)     // the canvas's first frame works out every shape's geometry
            // The first picture of the board, drawn as frames come: how many, and the longest.
            let clock = ContinuousClock()
            var frames = 0, longest = 0.0, total = 0.0
            while true {
                let ms = clock.measure { display(minimap, into: minimapContext) }.milliseconds
                frames += 1
                longest = max(longest, ms)
                total += ms
                guard h.scheduler.pendingCount > 0, frames < 1000 else { break }
                h.wait(0)                                   // the next frame the minimap asked for
            }
            expectEqual(h.scheduler.pendingCount, 0, "the first picture is all drawn")
            let note = try require(document.shapes.first { $0.kind == StickyNote.kind })
            let center = CGPoint(x: try require(note.box).midX, y: try require(note.box).midY)
            h.press(at: center)
            var step = 0
            let drag = median(runs: 21) {
                step += 1
                h.drag(to: center + CGPoint(x: CGFloat(step), y: CGFloat(step) / 2))
                draw(h.editor, into: context, size: viewport)
                display(minimap, into: minimapContext)
            }
            let minimapAlone = median(runs: 21) {
                step += 1
                h.drag(to: center + CGPoint(x: CGFloat(step), y: CGFloat(step) / 2))
                display(minimap, into: minimapContext)
            }
            h.release()
            report(String(format: "%6d shapes: minimap's first picture %.1f ms in %d frames (longest %.1f); drag with the minimap %5.1f ms (budget %.0f), its part %.1f",
                          size, total, frames, longest, drag, Budget.frame, minimapAlone))
            if holdsToBudgets {
                expect(longest < Budget.frame, "a frame of the minimap's first picture of \(size) shapes took \(longest) ms")
                expect(drag < Budget.frame, "a drag over \(size) shapes, with the minimap, took \(drag) ms")
            }
        }
    },
])
