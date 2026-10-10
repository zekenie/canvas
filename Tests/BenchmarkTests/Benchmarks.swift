import Adornments
import AppKit
import Boards
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Composition
import Connections
import CoreGraphics
import DetailPanel
import Foundation
import Geometry
import HostSlots
import LanguageModels
import Locking
import Mentions
import Schemas
import Selection
import Snapping
import StickyNotes
import Subboards
import TableOfContents
import TestKit
import Titles
import Topology
import Validation

// The persistence plan's budgets, for boards of generated shapes: saving and opening (Mentions'
// index and catalog built as it opens), a board and a file whose shapes are spread across nested
// subboards, validation's first read (every shape checked, against its kind's schema too) and its
// read after a drag event of a subboard mentioned 100 times and after moving them all, and one
// hover and one drag frame (the input, then drawing the whole canvas, and the minimap with it), on
// a note, from a note's port and onto a title's pill and a mention's, at 60 fps; a frame zoomed out
// to fit the board, where shapes are skeletons (its first and each after), and a pan's frame with
// every shape selected (⌘A) there and at 100%; a board all out of view, with nothing selected and
// all of it, against an empty one; an empty board's frame on Retina, the dot grid all it draws,
// at four zooms, still, panning and pinching; frames and rows on a board beside a subboard holding the board's
// worth, and inside one while the root holds as many, with a drag event's input alone, which the
// file's other boards mustn't cost; entering a subboard, cold (the switch, a frame, the rows and
// validation's read), going back up to its board and down again, warm, and the minimap's picture of
// the board entered; a keystroke in the `@` picker (on the line of a command that takes few shapes
// too) and a rename of a shape mentioned 100 times (the rows and validation after it too); the
// panel of a subboard mentioned 100 times, read after a drag of another note and after renaming
// one of its mentioners; completing a schema card's JSON as long
// as the model writes it; undo and redo, a drag's in a frame and a tenth of the board's moved or
// deleted too, and deleting a subboard whose boards hold as many shapes, and its undo and redo; ten
// subboards in view, each holding as many, their previews filling in; and a `canvas draw` whose
// shapes are pushed along the grid; and the root crumb's menu inside a subboard, the root's rows
// after a move and a rename on the board shown. `./build.sh bench` runs these in a release build
// and holds them to the budgets; `./test.sh` runs them debug and small, so they keep working, and
// only reports. Reported alone: the inspector's list replaced on a switch, and a crumb's menu shown
// in the window (InspectorBenchmarks.swift), a chain of 1,000 boards, a crumb's menu's first read,
// the first frame zoomed in to 35% from skeletons (every text in view laid out), and a pinch from
// 100% to 10% and back, a frame at each zoom (in full just above 35%, a frame of the
// generated board takes more than 16 ms). New frame budgets time the main thread's CPU
// (`median(runs:onThread:)`), never the wall clock.
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
    /// A frame; also undoing or redoing a drag with its frame, and a tenth of the board's move or
    /// deletion (the step alone).
    static let frame = 16.0
    /// Reading the table of contents' rows after a commit that changed a shape or two.
    static let contentsRows = 1.0
    /// Validation's first read of 10,000 shapes' issues, each shape checked against its kind's
    /// schema too: once, on the first frame after opening.
    static let validation10k = 100.0
    /// Validation's read after a commit that changed a shape or two; also after a drag event of a
    /// subboard 100 notes mention, whose mention rule looked it up and ignores moves.
    static let validationAfterCommit = 1.0
    /// Validation's read after a drag event that moved all 10,000 shapes (⌘A, then a drag): each
    /// moved shape's rules run again but those that ignore moves, its schema check (with it, some
    /// 30 ms) and its mentions' (some 6 ms more). The drag event's own commit, before it, costs
    /// more than a frame.
    static let validationAfterMovingAll10k = 16.0
    /// Undoing or redoing every shape's deletion, with the frame after it: 10,000 shapes back or gone.
    /// Also undoing or redoing the deletion of a shape whose boards hold 10,000, with the frame after
    /// it.
    static let undoEveryShape = 100.0
    /// Topology's index of the file's edges (who mentions whom among them, and what arrows join) and
    /// Mentions' catalog (what the `@` picker searches, the whole file's), built as a file opens:
    /// part of opening it. The budget Mentions' own index of who mentions whom had.
    static let mentionIndex10k = 50.0
    /// What's connected to a shape with 100 edges, and how (`topology.neighbors(of:)`): what it
    /// returns, never the board.
    static let neighbors100 = 1.0
    /// A keystroke in the `@` picker, the `@` that opens it (recent picks and nearby shapes) included.
    static let pickerKeystroke = 2.0
    /// Completing a schema card's JSON at the caret, in a schema as long as the model writes: a
    /// keystroke, as in the `@` picker.
    static let schemaCompletion = pickerKeystroke
    /// What renaming a shape mentioned 100 times adds to the commit, over renaming one mentioned
    /// by none; and to validation's read after it.
    static let renameMentioned = 1.0
    /// The panel's layout of the shape it shows, read after a commit that changed a shape or two:
    /// its status lines and whether its Mentioned In tab shows are read on every commit, and the
    /// rest of its layout whenever they, or the shape, change.
    static let panelAfterCommit = 1.0
    /// What a frame's previews drawn as paths add to it: at most `Style.previewPathShapes` shapes, some 2 µs each.
    static let previewPaths = 3.0
    /// A frame zoomed in on a shape that holds all the view, on Retina at 1200 × 800: an empty
    /// board's frame and a fill, its shadow left out, since its fill hides it (blurred by the zoom,
    /// it took 24 to 26 ms at 800% on the CPU).
    static let coveredShape = 3.0
    /// Going back to a board shown lately, as it was left: the switch, its first frame, the table
    /// of contents' rows and validation's read, together.
    static let warmReturn = frame
    /// Entering a board of 10,000 shapes for the first time: the switch (the camera's first fit
    /// with it), the first frame (three notes in ten drawing pills), the table of contents' rows and
    /// validation's first read, together. Once a board, like opening a file. Who mentions whom
    /// (Topology's index) and Mentions' catalog are the file's, read as it opens, so entering a
    /// board reads none of them.
    static let enterCold = 250.0
    /// Deleting a shape whose boards hold 10,000 shapes: the commit, and every board under it taken
    /// with it. A frame and 2 ms: the generated file's two nested boards number their notes alike,
    /// so 2,608 titles are each held twice, and `TitleValidationPlugin`'s index takes every one out
    /// (some 1.7 ms; main was at 15.2 of a frame's 16 before it). The owner chose raising it over
    /// keeping the index's titles per board and numbering the generated titles across the file.
    static let subboardDeletion = frame + 2
    /// A drag event's input (its commit, without the frame) on a board beside or inside a subboard,
    /// on 10,000 shapes: some 0.25 ms, so a commit's upkeep of the whole file shows.
    static let dragInput = 1.0
    /// And how many times what it costs on a file of that board alone it may cost: the file's other
    /// boards cost a commit nothing.
    static let dragInputOverAlone = 3.0
    /// And more, for a timing too short to hold to a ratio (a drag on a board of 1,000, some 0.03 ms).
    static let dragInputSlack = 0.1
    /// The inspector's list replaced on a switch between boards of 10,000 rows each: reported, not
    /// held, until it's known to fit.
    static let listReplacedTarget = 50.0
    /// A `canvas draw` of 20 notes on 10,000 shapes, each pushed along its row to the end: the
    /// command runs on the main actor, so it's time the window doesn't draw.
    static let draw20 = 150.0
    /// An empty board's frame on Retina at 1200 × 800 (the background and the dot grid), the camera
    /// still, panning or pinching, at any zoom: a small part of a frame, where filling the grid's
    /// dots as ellipses took 3 to 7 ms. The thread's CPU time.
    static let emptyFrame = 2.0
    /// A frame zoomed out to fit the board (as far as the zoom goes: 10% for 10,000 shapes, some
    /// 1,700 of them in view, 11% for 1,000, all of them), where shapes are drawn as their
    /// skeletons, which show no adornments (a title is said on a shape big enough on screen, its
    /// cover, which each frame decides by the shape's kept bounds): the first frame, and each after.
    static let zoomedOut = frame
    /// What a board of 10,000 shapes, all out of view, adds to a frame over an empty board's, at
    /// 100% and at 10%, with nothing selected and with every shape (⌘A): nothing off screen is
    /// drawn, finding what's in view costs next to nothing, and a shape outlined out of view a look
    /// at its kept extent (all 10,000 of them, some 0.5 ms).
    static let offscreenBoard = 1.0
}

/// Notes, subboards and schema cards in a grid, with an arrow from every fourth note to
/// the note after it. Every other note has a title, so frames draw pills and boards save and open
/// added values; every subboard has a title, which its card draws (a subboard shows no pill), and an empty board, which
/// the file doesn't keep; every tenth shape is a locked note that mentions nothing, so frames draw lock chips (they're at the back
/// of the board's order, so its first note is the first of the ones that mention); every schema card
/// has a schema of its own, so frames read no card's schema again however many different ones there
/// are; and three notes in ten mention two shapes, so frames draw pills: a subboard (the first 100
/// of them the first subboard, `mentionedSubboard`, the rest the subboard before them) and a shape
/// that isn't on the board, which shows as missing.
@MainActor func generatedBoard(shapes count: Int) -> CanvasDocument {
    var shapes: [AnyShapeRecord] = [], lockedNotes: [AnyShapeRecord] = []
    let columns = Int(Double(count).squareRoot().rounded(.up))
    var previousNote: ShapeID?
    var firstSubboard: ShapeID?, lastSubboard: ShapeID?
    var notes = 0, mentioning = 0
    var i = 0
    while shapes.count + lockedNotes.count < count {
        let origin = CGPoint(x: (i % columns) * 260, y: (i / columns) * 260)
        switch i % 10 {
        case 0, 1:
            var subboard = AnyShapeRecord(ShapeRecord(Subboard(frame: CGRect(origin: origin, size: Subboard.defaultSize))))
            subboard[TitleProperty.self] = "Plan \(i)"
            shapes.append(subboard)
            if firstSubboard == nil { firstSubboard = subboard.id }
            lastSubboard = subboard.id
        case 2:
            var locked = AnyShapeRecord(ShapeRecord(StickyNote(frame: CGRect(origin: origin, size: CGSize(width: 160, height: 120)),
                                                               text: MentionText(plain: "Note \(i): locked, and nobody mentions it"))))
            locked[LockedProperty.self] = true
            lockedNotes.append(locked)
        case 9:
            var schema = SchemaCard(frame: CGRect(origin: origin, size: SchemaCard.defaultSize))
            schema.schema.text = #"{"title": "Record \#(i)", "type": "object", "properties": {"name": {"type": "string"}, "count\#(i)": {"type": "integer"}, "tags": {"type": "array", "items": {"type": "string"}}}, "required": ["name"]}"#
            schema.setPrompt(SchemaPromptText(plain: "Record \(i): its name, a count, and its tags"))
            shapes.append(AnyShapeRecord(ShapeRecord(schema)))
        default:
            var text = MentionText(plain: "Note \(i): something to do")
            if notes % 10 < 3, let firstSubboard, let lastSubboard {
                let subboard = mentioning < 100 ? firstSubboard : lastSubboard
                text = MentionText([.text("Note \(i): ask "), .mention(subboard, label: "Plan"), .text(" about it, and "),
                                    .mention(ShapeID(), label: "Old note \(i)")])
                mentioning += 1
            }
            notes += 1
            var note = ShapeRecord(StickyNote(frame: CGRect(origin: origin, size: StickyNote.defaultSize), text: text))
            note[TitleProperty.self] = i % 2 == 0 ? "Title \(i)" : nil
            shapes.append(AnyShapeRecord(note))
            if let previousNote, i % 4 == 0, shapes.count + lockedNotes.count < count {
                let bound = { (id: ShapeID) in ArrowTerminal.bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)) }
                shapes.append(AnyShapeRecord(ShapeRecord(Arrow(start: bound(previousNote), end: bound(note.id)))))
            }
            previousNote = note.id
        }
        i += 1
    }
    return CanvasDocument(shapes: shapes + lockedNotes)
}

/// Empty notes in a grid, which can't be mentioned (they have no name), and three notes that can: one
/// at the top left (`owner`), one in the middle and one at the bottom right (`others`).
@MainActor func sparseBoard(shapes count: Int) -> (document: CanvasDocument, owner: ShapeID, others: [ShapeID]) {
    let columns = Int(Double(count).squareRoot().rounded(.up))
    var shapes: [AnyShapeRecord] = []
    for i in 0..<count - 3 {
        let origin = CGPoint(x: (i % columns) * 260, y: (i / columns) * 260)
        shapes.append(AnyShapeRecord(ShapeRecord(StickyNote(frame: CGRect(origin: origin, size: CGSize(width: 160, height: 120)), text: ""))))
    }
    let far = CGFloat(columns) * 260
    let notes = [CGPoint(x: -300, y: -300), CGPoint(x: far / 2, y: far / 2), CGPoint(x: far, y: far)].map { origin in
        AnyShapeRecord(ShapeRecord(StickyNote(frame: CGRect(origin: origin, size: StickyNote.defaultSize), text: "Note")))
    }
    return (CanvasDocument(shapes: shapes + notes), notes[0].id, [notes[1].id, notes[2].id])
}

/// Named notes in a grid (the catalog holds each by its first line, "Note 17: something to do"), and
/// five subboards among them, "Plan 1" to "Plan 5", in the middle and the corners: the first note is
/// at the top left (`owner`), and the subboards are far from it. What a command that takes few of a
/// board's shapes (`/move-to`: shapes that hold shapes or own boards) finds on a board of 10,000.
@MainActor func fewSubboardsBoard(shapes count: Int) -> (document: CanvasDocument, owner: ShapeID, subboards: [ShapeID]) {
    let columns = Int(Double(count).squareRoot().rounded(.up))
    var shapes: [AnyShapeRecord] = []
    for i in 0..<count - 5 {
        let origin = CGPoint(x: (i % columns) * 260, y: (i / columns) * 260)
        shapes.append(AnyShapeRecord(ShapeRecord(StickyNote(frame: CGRect(origin: origin, size: CGSize(width: 160, height: 120)),
                                                            text: MentionText(plain: "Note \(i): something to do")))))
    }
    let far = CGFloat(columns) * 260
    let corners = [CGPoint(x: far / 2, y: far / 2), CGPoint(x: far, y: far), CGPoint(x: far, y: -400), CGPoint(x: -400, y: far), CGPoint(x: far / 2, y: -400)]
    let subboards = corners.enumerated().map { index, origin in
        var subboard = AnyShapeRecord(ShapeRecord(Subboard(frame: CGRect(origin: origin, size: Subboard.defaultSize))))
        subboard[TitleProperty.self] = "Plan \(index + 1)"
        return subboard
    }
    return (CanvasDocument(shapes: shapes + subboards), shapes[0].id, subboards.map(\.id))
}

/// The subboard the first 100 mentioning notes of a generated board mention.
@MainActor func mentionedSubboard(in document: CanvasDocument) -> ShapeID? { document.shapes.first { $0.kind == Subboard.kind }?.id }

/// Times what a plugin's services cost as an editor is made: a service of `start`'s, made just
/// before them, reads the clock, and one of `end`'s, made just after, reads it again.
@MainActor final class Stopwatch {
    var started: ContinuousClock.Instant?
    var ended: ContinuousClock.Instant?
    var milliseconds: Double { started.flatMap { start in ended.map { (start.duration(to: $0)).milliseconds } } ?? .nan }
}

@MainActor final class StopwatchStart: EditorService {
    init(_ watch: Stopwatch) { watch.started = ContinuousClock.now }
}

@MainActor final class StopwatchEnd: EditorService {
    init(_ watch: Stopwatch) { watch.ended = ContinuousClock.now }
}

/// The shipped plugins, with a stopwatch around Topology's service and Mentions': Topology's index
/// of the file's edges (the mentions among them) and Mentions' catalog, built from the file each is
/// given. Topology is moved to just before Mentions, so nothing else is made between them: where it
/// is changes only when its service is made, and Mentions' is made after it wherever it is.
@MainActor func pluginsTimingMentions(_ watch: Stopwatch) -> [any CanvasPlugin] {
    var plugins = ShippedPlugins.plugins(model: ScriptedLanguageModel())
    let topology = plugins.remove(at: plugins.firstIndex { $0.id == .topology }!)
    let at = plugins.firstIndex { $0.id == .mentions }!
    plugins.insert(Contributor(id: "bench-stopwatch-end") { r in r.service { _ in StopwatchEnd(watch) } }, at: at + 1)
    plugins.insert(topology, at: at)
    plugins.insert(Contributor(id: "bench-stopwatch-start") { r in r.service { _ in StopwatchStart(watch) } }, at: at)
    return plugins
}

/// A file of generated boards (`generatedBoard`): a root of `root` shapes beside a subboard for each
/// of `children` (in a row above the grid, out of the frames' view), whose board holds that many.
/// The last is the top of a chain `depth` boards deep, the shapes shared among them, each board but
/// the deepest holding the subboard of the next beside its share. A board's subboards that own
/// boards (`owners(in:)`) aren't among its count.
@MainActor func generatedFile(root: Int, children: [Int], depth: Int = 1) -> CanvasFile {
    precondition(depth >= 1 && (depth == 1 || !children.isEmpty))
    var boards: [ShapeID: CanvasDocument] = [:]
    let card = { (i: Int) in ShapeRecord(Subboard(frame: CGRect(origin: CGPoint(x: CGFloat(i) * 300, y: -400), size: Subboard.defaultSize))) }
    let owners = children.indices.map(card)
    for (owner, count) in zip(owners, children) {
        // Down the chain from this owner: each board its share, and the next board's card.
        var owner = owner
        let levels = owner.id == owners.last?.id ? depth : 1
        for level in 0..<levels {
            let share = level == levels - 1 ? count - count / levels * level : count / levels
            var shapes = generatedBoard(shapes: share).shapes
            if level < levels - 1 {
                let next = card(0)
                shapes.append(AnyShapeRecord(next))
                boards[owner.id] = CanvasDocument(shapes: shapes)
                owner = next
            } else {
                boards[owner.id] = CanvasDocument(shapes: shapes)
            }
        }
    }
    return CanvasFile(root: CanvasDocument(shapes: generatedBoard(shapes: root).shapes + owners.map(AnyShapeRecord.init)), children: boards)
}

/// The root's subboards that own boards in the file, in its order: those `generatedFile` put there,
/// not the empty ones a generated board holds.
func owners(in file: CanvasFile) -> [ShapeID] { file.root.shapes.filter { file.children[$0.id] != nil }.map(\.id) }

/// Every board with no shape locked (a locked shape inside a subboard keeps it from being deleted).
func unlocked(_ file: CanvasFile) -> CanvasFile {
    let unlock = { (document: CanvasDocument) in
        CanvasDocument(shapes: document.shapes.map { shape in
            var shape = shape
            shape[LockedProperty.self] = nil
            return shape
        })
    }
    return CanvasFile(root: unlock(file.root), children: file.children.mapValues(unlock))
}

extension Duration {
    var milliseconds: Double { Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15 }
}

/// The median of `runs` timings of `body`, in milliseconds, each after an untimed `prepare`: by the
/// wall clock, or with `onThread`, the thread's CPU time (what a budget is held to, since the wall
/// clock counts whatever else the machine runs).
@MainActor func median(runs: Int, prepare: () -> Void = {}, onThread: Bool = false, _ body: () throws -> Void) rethrows -> Double {
    let clock = ContinuousClock()
    var times: [Double] = []
    for _ in 0..<runs {
        prepare()
        times.append(try (onThread ? threadCPUTime(body) : clock.measure(body)).milliseconds)
    }
    return times.sorted()[times.count / 2]
}

/// The camera at `zoom` with the middle of `bounds` in the middle of a view of `size`.
func camera(centering bounds: CGRect, at zoom: CGFloat, in size: CGSize) -> Camera {
    Camera(origin: CGPoint(x: bounds.midX - size.width / 2 / zoom, y: bounds.midY - size.height / 2 / zoom), zoom: zoom)
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

/// The median times of undoing and redoing the step just made (the newest), each with `frame` after
/// it; the step is left done.
@MainActor func undoAndRedo(_ editor: CanvasEditor, runs: Int, frame: () -> Void) -> (undo: Double, redo: Double) {
    let undo = median(runs: runs, prepare: { if editor.canRedo { editor.redo() } }) {
        editor.undo()
        frame()
    }
    let redo = median(runs: runs, prepare: { if !editor.canRedo { editor.undo() } }) {
        editor.redo()
        frame()
    }
    return (undo, redo)
}

@MainActor let benchmarks = Suite("Benchmarks", [
    test("saving and opening a board stay within budget") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let codec = BoardCodec(registry: registry)
        for size in sizes {
            let document = generatedBoard(shapes: size)
            var data = Data()
            let save = try median(runs: 5) { data = try codec.encode(document) }
            // Opened with a stopwatch around Topology's service and Mentions', which build the index of
            // who mentions whom and the catalog.
            let watch = Stopwatch()
            let timed = try Registry(plugins: pluginsTimingMentions(watch))
            var opened: CanvasEditor?
            var indexTimes: [Double] = []
            let open = try median(runs: 5) {
                opened = CanvasEditor(registry: timed, document: try codec.decode(data).document, scheduler: ManualScheduler())
                indexTimes.append(watch.milliseconds)
            }
            let index = indexTimes.sorted()[indexTimes.count / 2]
            expectEqual(opened?.document, registry.fillingDefaults(document))
            let subboard = try require(mentionedSubboard(in: document))
            expectEqual(opened?.mentions?.mentioners(of: subboard).count, min(100, document.shapes.count { $0.kind == StickyNote.kind && $0.typed(as: StickyNote.self)?.props.text.mentioned.first == subboard }))
            report(String(format: "%6d shapes, %5.1f MB: save %7.1f ms, open %7.1f ms (budget %.0f), of which Topology's index and Mentions' catalog %5.1f (budget %.0f)",
                          size, Double(data.count) / 1e6, save, open, Budget.open10k, index, Budget.mentionIndex10k))
            if holdsToBudgets, size >= 10_000 {
                expect(open < Budget.open10k, "opening \(size) shapes took \(open) ms")
                expect(index < Budget.mentionIndex10k, "Topology's index and Mentions' catalog of \(size) shapes took \(index) ms")
            }
            // The same shapes spread across boards: a tenth on the root, a tenth in each of nine
            // subboards, the last of them the top of a chain ten boards deep.
            let tenth = size / 10
            let file = generatedFile(root: tenth, children: Array(repeating: tenth, count: 9), depth: 10)
            let nestedSave = try median(runs: 5) { data = try codec.encode(file) }
            let nestedOpen = try median(runs: 5) {
                opened = CanvasEditor(registry: registry, file: try codec.decode(data).file, scheduler: ManualScheduler())
            }
            expectEqual(opened?.file, registry.fillingDefaults(file))
            expectEqual(file.children.count, 18, "nine subboards, and nine more down the chain")
            report(String(format: "%6d shapes on %d boards, %5.1f MB: save %7.1f ms, open %7.1f ms (budget %.0f)",
                          file.shapeCount, file.children.count + 1, Double(data.count) / 1e6, nestedSave, nestedOpen, Budget.open10k))
            if holdsToBudgets, size >= 10_000 { expect(nestedOpen < Budget.open10k, "opening \(file.shapeCount) shapes on \(file.children.count + 1) boards took \(nestedOpen) ms") }
        }
    },
    test("validation's first read checks every shape, against its kind's schema too; a drag checks the dragged shapes again, but not their schemas or their mentions") {
        for size in sizes {
            let document = generatedBoard(shapes: size)
            let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
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
            // drag event (but the locked notes, and the arrows with their notes).
            let h = EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }
            _ = h.editor.validation?.results
            // A drag of the subboard the first 100 mentioning notes mention: each event moves it, and
            // checks those notes again, as their rules looked it up (`MentionValidationPlugin`'s).
            let subboard = try require(mentionedSubboard(in: document))
            expectEqual(h.editor.validation?.dependents(of: [subboard]), Set(h.editor.mentions?.mentioners(of: subboard) ?? []), "its mentioners looked it up")
            let subboardBox = try require(document[subboard]?.box)
            let subboardCenter = CGPoint(x: subboardBox.midX, y: subboardBox.midY)
            h.press(at: subboardCenter)
            var subboardNudge = 0.0
            let subboardDrag = median(runs: 21, prepare: {
                subboardNudge += 1
                h.drag(to: subboardCenter + CGPoint(x: subboardNudge, y: 0))
            }) { _ = h.editor.validation?.results }
            expectEqual(h.editor.document[subboard]?.box?.origin.x, subboardBox.origin.x + subboardNudge, "the drag moves the subboard")
            h.release()
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
            let mentioners = h.editor.mentions?.mentioners(of: subboard).count ?? 0
            report(String(format: "%6d shapes, validation: first read %6.1f ms (budget %.0f), of which the schemas about %6.1f; after a drag event %6.3f (budget %.0f), of a subboard mentioned %d times %6.3f; after moving them all %6.2f (budget %.0f)",
                          size, first, Budget.validation10k, schemas, again, Budget.validationAfterCommit, mentioners, subboardDrag, all, Budget.validationAfterMovingAll10k))
            if holdsToBudgets {
                if size >= 10_000 {
                    expect(first < Budget.validation10k, "validation's first read of \(size) shapes took \(first) ms")
                    expect(all < Budget.validationAfterMovingAll10k, "validation after moving all \(size) shapes took \(all) ms")
                }
                expect(again < Budget.validationAfterCommit, "validation after a drag event on \(size) shapes took \(again) ms")
                expect(subboardDrag < Budget.validationAfterCommit, "validation after a drag event of a subboard mentioned \(mentioners) times on \(size) shapes took \(subboardDrag) ms")
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
            let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
            let h = EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }
            // The top-left of the board, where the first note is: it mentions two shapes, so a drag
            // runs the rows' `MentionRows.affected` on every event, and notes with pills are in view.
            let note = try require(document.shapes.first { $0.kind == StickyNote.kind })
            expectEqual(h.editor.mentions?.mentions(in: note.id).count, 2, "the dragged note mentions")
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
            // A hover onto a mention's pill in a note, a face that hovers the subboard it names.
            let mentioning = try require(h.editor.document.shapes.first {
                $0.kind == StickyNote.kind && (h.editor.mentionPills(of: $0.id).first.map { inView.contains(h.editor.camera.toView($0.frame)) } ?? false)
            }, "a note's mention in view")
            let mention = try require(h.editor.mentionPills(of: mentioning.id).first)
            let onMention = median(runs: 21) {
                step += 1
                h.move(to: h.view(CGPoint(x: mention.frame.minX + 4 + CGFloat(step % 7), y: mention.frame.midY)))
                draw(h.editor, into: context, size: viewport)
            }
            expectEqual(h.editor.hovered, mention.target, "the pill hovers the subboard it names")
            report(String(format: "%6d shapes: a hover onto a titled note's pill %5.1f ms, onto a mention's pill %5.1f ms (budget %.0f)",
                          size, onPill, onMention, Budget.frame))
            if holdsToBudgets {
                expect(onPill < Budget.frame, "a hover onto a titled note's pill over \(size) shapes took \(onPill) ms")
                expect(onMention < Budget.frame, "a hover onto a mention's pill over \(size) shapes took \(onMention) ms")
            }
        }
    },
    test("an empty board's frame on Retina, the dot grid all it draws, costs little at every zoom, the camera still, panning or pinching") {
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport, scale: 2)
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let h = EditorHarness { CanvasEditor(registry: registry, document: CanvasDocument(), scheduler: $0) }
        let middle = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let frame = { draw(h.editor, into: context, size: viewport) }
        // 100%; where the dots are closest, just before the spacing doubles (70%, 35%); and 10%.
        for zoom: CGFloat in [1, 0.7, 0.35, 0.1] {
            h.editor.camera = Camera(origin: CGPoint(x: 3.3, y: 7.7), zoom: zoom)
            frame()
            let still = median(runs: 21, onThread: true, frame)
            // Less than a pixel a frame, so every frame's dots fall elsewhere within their pixels, and
            // a pinch back and forth by a fraction of a percent, each frame's spacing another's.
            let panning = median(runs: 21, onThread: true) {
                h.editor.camera.pan(by: CGSize(width: 0.37, height: 0.29))
                frame()
            }
            var step = 0
            let pinching = median(runs: 21, onThread: true) {
                step += 1
                h.editor.camera.zoom(by: step % 2 == 1 ? 1.003 : 1 / 1.003, around: middle)
                frame()
            }
            let ellipses = median(runs: 5, onThread: true) {
                drawGridAsEllipses(in: context, bounds: CGRect(origin: .zero, size: viewport), camera: h.editor.camera)
            }
            report(String(format: "empty board at %3.0f%%, 2×: a frame still %.2f ms, panning %.2f, pinching %.2f (budget %.0f); its grid as ellipses %.1f",
                          zoom * 100, still, panning, pinching, Budget.emptyFrame, ellipses))
            if holdsToBudgets {
                expect(still < Budget.emptyFrame, "an empty board's frame at \(zoom * 100)%, the camera still, took \(still) ms")
                expect(panning < Budget.emptyFrame, "an empty board's frame at \(zoom * 100)%, panning, took \(panning) ms")
                expect(pinching < Budget.emptyFrame, "an empty board's frame at \(zoom * 100)%, pinching, took \(pinching) ms")
            }
        }
    },
    test("zoomed out to fit the board, where shapes are skeletons, the first frame and each after fit in a frame; zoomed in to 35%, the first frame in full is reported") {
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        for size in sizes {
            // Each run a board of its own: new ids, so nothing the canvas keeps by what a shape says
            // or by its id (Mentions' memo of mention text, the schema cards' readings) is another
            // run's. Opened and drawn at 100% at its top left (validation's first read done), then
            // zoomed out to fit it, where shapes are skeletons with no adornments; then zoomed in to
            // 35% on its middle, where shapes are drawn in full again and every text in view is laid
            // out, none of it before; and, for the first run, to just under it, where every titled
            // shape in view big enough on screen has its cover (reported).
            var firsts: [Double] = [], zoomedIn: [Double] = []
            var next = 0.0, covers = 0.0, fitted = Camera(), inView = 0, inViewNear = 0
            for run in 0..<5 {
                let document = generatedBoard(shapes: size)
                let h = EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }
                h.editor.viewportDidResize(to: viewport)
                draw(h.editor, into: context, size: viewport)
                fitted = Camera(fitting: h.editor.shapeBounds, in: viewport, inset: 0)
                h.editor.camera = fitted
                expect(h.editor.drawsSkeletons, "zoomed out, shapes are skeletons")
                firsts.append(threadCPUTime { draw(h.editor, into: context, size: viewport) }.milliseconds)
                if run == 0 {
                    next = median(runs: 21, onThread: true) { draw(h.editor, into: context, size: viewport) }
                    inView = h.editor.paintOrder(in: fitted.toWorld(CGRect(origin: .zero, size: viewport))).count
                }
                let near = camera(centering: h.editor.shapeBounds, at: 0.35, in: viewport)
                h.editor.camera = near
                expect(!h.editor.drawsSkeletons, "at 35%, in full")
                zoomedIn.append(threadCPUTime { draw(h.editor, into: context, size: viewport) }.milliseconds)
                inViewNear = h.editor.paintOrder(in: near.toWorld(CGRect(origin: .zero, size: viewport))).count
                if run == 0 {
                    h.editor.camera = camera(centering: h.editor.shapeBounds, at: 0.34, in: viewport)
                    expect(h.editor.drawsSkeletons, "just under 35%, skeletons")
                    draw(h.editor, into: context, size: viewport)
                    covers = median(runs: 11, onThread: true) { draw(h.editor, into: context, size: viewport) }
                }
            }
            let first = firsts.sorted()[firsts.count / 2], zoomIn = zoomedIn.sorted()[zoomedIn.count / 2]
            report(String(format: "%6d shapes zoomed out to fit the board (%.0f%%, %d in view): the first frame %5.1f ms, the next %5.1f (budget %.0f); zoomed in to 35%% (%d in view), the first frame in full %5.1f, and just under it, with covers, each frame %5.1f (reported)",
                          size, fitted.zoom * 100, inView, first, next, Budget.zoomedOut, inViewNear, zoomIn, covers))
            if holdsToBudgets {
                expect(first < Budget.zoomedOut, "the first frame zoomed out over \(size) shapes took \(first) ms")
                expect(next < Budget.zoomedOut, "a frame zoomed out over \(size) shapes took \(next) ms")
            }
        }
    },
    test("⌘A: a frame with every shape of the board selected fits in a frame at 100%; zoomed out to fit the board, it's reported") {
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        for size in sizes {
            let document = generatedBoard(shapes: size)
            let h = EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }
            // The hover benchmark's camera, then the whole board fitted (as far as the zoom goes),
            // where shapes draw as skeletons and so do their outlines. Each frame with nothing
            // selected, then with everything; the selection's part is the difference, and of it the
            // outlines read (`editor.outlines`: Selection's, with the box around them all) before
            // the core strokes those in view. Each frame timed is a pan's, the camera a point from
            // the last one's, back and forth, so the box around them all is worked out again, as it
            // is on every frame of a pan in the app. Zoomed out it's reported, not held: at 10,000
            // shapes (some 1,700 in view, each outlined) it's within a millisecond or two of a frame.
            var lines: [String] = []
            var atFull = 0.0
            for camera in [Camera(), Camera(fitting: h.editor.shapeBounds, in: viewport, inset: 0)] {
                h.editor.camera = camera
                var step = 0.0
                let pan = {
                    step = step == 0 ? 1 : 0
                    h.editor.camera = Camera(origin: CGPoint(x: camera.origin.x + step / camera.zoom, y: camera.origin.y), zoom: camera.zoom)
                }
                h.editor.selectedShapeIDs = []
                draw(h.editor, into: context, size: viewport)
                let plain = median(runs: 11, prepare: pan, onThread: true) { draw(h.editor, into: context, size: viewport) }
                h.editor.selectAll()
                expectEqual(h.editor.selectedShapeIDs.count, size)
                draw(h.editor, into: context, size: viewport)
                let selected = median(runs: 11, prepare: pan, onThread: true) { draw(h.editor, into: context, size: viewport) }
                let read = median(runs: 11, onThread: true) { _ = h.editor.outlines }
                if camera.zoom == 1 { atFull = selected }
                lines.append(String(format: "at %.0f%% %5.1f ms (%5.1f with nothing selected; the outlines read %4.1f)",
                                    camera.zoom * 100, selected, plain, read))
            }
            report(String(format: "%6d shapes, all selected (⌘A), a frame: %@ (budget %.0f at 100%%; zoomed out, reported)",
                          size, lines.joined(separator: "; "), Budget.frame))
            if holdsToBudgets { expect(atFull < Budget.frame, "a frame at 100% with all \(size) shapes selected took \(atFull) ms") }
        }
    },
    test("a board of the board's worth of shapes, all out of view, costs a frame nothing over an empty board's, at 100% and at 10%, with nothing selected or all of it") {
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let empty = EditorHarness { CanvasEditor(registry: registry, document: CanvasDocument(), scheduler: $0) }
        for size in sizes {
            let h = EditorHarness { CanvasEditor(registry: registry, document: generatedBoard(shapes: size), scheduler: $0) }
            draw(h.editor, into: context, size: viewport)                   // validation's first read, and the rows
            var lines: [String] = []
            var most = -Double.infinity
            for zoom: CGFloat in [1, 0.1] {
                // Empty canvas far to the board's upper left: at 10% the view spans 12,000 × 8,000
                // world units, and the board starts at (0, 0). Both editors at the same camera, so
                // the grid is the same.
                let far = Camera(origin: CGPoint(x: -100_000, y: -60_000), zoom: zoom)
                h.editor.camera = far
                empty.editor.camera = far
                expectEqual(h.editor.paintOrder(in: far.toWorld(CGRect(origin: .zero, size: viewport))).count, 0, "nothing in view")
                // With nothing selected, then with every shape (⌘A): outlined, all out of view.
                var parts: [String] = []
                for selected in [false, true] {
                    if selected { h.editor.selectAll() } else { h.editor.selectedShapeIDs = [] }
                    draw(h.editor, into: context, size: viewport)
                    draw(empty.editor, into: context, size: viewport)
                    // A frame of each in turn, so whatever else slows the machine meanwhile slows both.
                    var boards: [Double] = [], nones: [Double] = []
                    for _ in 0..<21 {
                        boards.append(threadCPUTime { draw(h.editor, into: context, size: viewport) }.milliseconds)
                        nones.append(threadCPUTime { draw(empty.editor, into: context, size: viewport) }.milliseconds)
                    }
                    let board = boards.sorted()[boards.count / 2], none = nones.sorted()[nones.count / 2]
                    most = max(most, board - none)
                    parts.append(String(format: selected ? "all selected %5.2f ms, an empty board's %5.2f" : "%5.2f ms, an empty board's %5.2f", board, none))
                }
                h.editor.selectedShapeIDs = []
                lines.append(String(format: "at %.0f%% %@", zoom * 100, parts.joined(separator: "; ")))
            }
            report(String(format: "%6d shapes out of view, a frame: %@ (budget: %.0f more)", size, lines.joined(separator: "; "), Budget.offscreenBoard))
            if holdsToBudgets { expect(most < Budget.offscreenBoard, "\(size) shapes out of view added \(most) ms to a frame") }
        }
    },
    test("a pinch from 100% to 10% and back, centered on the board, each frame at a zoom of its own (reported)") {
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        for size in sizes {
            let h = EditorHarness { CanvasEditor(registry: registry, document: generatedBoard(shapes: size), scheduler: $0) }
            h.editor.viewportDidResize(to: viewport)
            let bounds = h.editor.shapeBounds
            // A pinch's frames: the zoom times 0.93 each, from 100% down to 10%, then back up by the
            // same steps from there to where it began, the untimed first frame's zoom: no other
            // frame is at a zoom one before it drew (the fonts' sizes, the grid's spacing). Each
            // board's a hair off the one before's (0.3% less), so none of its frames but 10%, where
            // every board's pinch turns (the zoom goes no lower; skeletons there, no text), is at a
            // zoom another board's pinch drew either.
            let shift = pow(0.997, CGFloat(sizes.firstIndex(of: size) ?? 0))
            let down = (1...31).map { shift * pow(0.93, CGFloat($0)) }, up = (1...31).map { shift * 0.1 / pow(0.93, CGFloat($0)) }
            let zooms = down + [0.1] + up + [shift]
            // Where it begins, untimed: validation's first read, and the rows.
            h.editor.camera = camera(centering: bounds, at: shift, in: viewport)
            draw(h.editor, into: context, size: viewport)
            var frames: [(zoom: CGFloat, ms: Double)] = []
            for zoom in zooms {
                let ms = threadCPUTime {
                    h.editor.camera = camera(centering: bounds, at: zoom, in: viewport)
                    draw(h.editor, into: context, size: viewport)
                }.milliseconds
                frames.append((zoom, ms))
            }
            let times = frames.map(\.ms).sorted()
            let worst = try require(frames.max { $0.ms < $1.ms })
            let skeletons = frames.filter { $0.zoom < h.editor.skeletonZoom }
            let worstSkeleton = try require(skeletons.max { $0.ms < $1.ms })
            report(String(format: "%6d shapes, a pinch from 100%% to 10%% and back, %d frames: the median %5.1f ms, the worst %5.1f at %.0f%%, %d over %.0f; of the %d below 35%% (skeletons), the worst %5.1f at %.0f%% (reported: in full just above 35%%, a frame of this board takes more than %.0f)",
                          size, frames.count, times[times.count / 2], worst.ms, worst.zoom * 100, frames.count { $0.ms > Budget.frame }, Budget.frame,
                          skeletons.count, worstSkeleton.ms, worstSkeleton.zoom * 100, Budget.frame))
        }
    },
    test("a drag that snaps with every shape of the board in view: its first event, which reads them, fits in a frame, and each event after costs its input's budget") {
        let viewport = CGSize(width: 1200, height: 800)
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let clock = ContinuousClock()
        for size in sizes {
            // Empty notes 60 × 40, 96 apart in rows of 125: 10,000 fill 12,000 × 7,680, all in view at 10%.
            let shapes = (0..<size).map { i in
                AnyShapeRecord(ShapeRecord(StickyNote(frame: CGRect(x: CGFloat(i % 125) * 96, y: CGFloat(i / 125) * 96, width: 60, height: 40), text: "")))
            }
            let h = EditorHarness { CanvasEditor(registry: registry, document: CanvasDocument(shapes: shapes), scheduler: $0) }
            h.editor.viewportDidResize(to: viewport)
            h.editor.camera = Camera(fitting: h.editor.shapeBounds, in: viewport, inset: 0)
            let first = try require(h.editor.document.shapes.first?.box)
            let center = h.view(CGPoint(x: first.midX, y: first.midY))
            // A lone box follows the pointer from the press, and snaps once the pointer is past the
            // drag threshold: that event reads what's in view. Each drag is undone for the next.
            var reads: [Double] = []
            for run in 0..<11 {
                h.press(at: center)
                reads.append(clock.measure { h.drag(to: center + CGPoint(x: 6, y: CGFloat(run % 3))) }.milliseconds)
                h.release()
                h.editor.undo()
            }
            let read = reads.sorted()[reads.count / 2]
            var step = 0
            h.press(at: center)
            h.drag(to: center + CGPoint(x: 6, y: 0))
            let after = median(runs: 21) {
                step += 1
                h.drag(to: center + CGPoint(x: 6 + CGFloat(step % 20) / 2, y: CGFloat(step % 7) / 2))
            }
            expect(!h.editor.snapGuides.isEmpty, "the drag snaps")
            h.release()
            report(String(format: "%6d shapes in view (%.0f%%): a drag's first event that snaps, reading them, %6.3f ms (budget %.0f); each event after %6.3f (budget %.0f)",
                          size, h.editor.camera.zoom * 100, read, Budget.frame, after, Budget.dragInput))
            if holdsToBudgets {
                expect(read < Budget.frame, "a drag's first event that snaps, with \(size) shapes in view, took \(read) ms")
                expect(after < Budget.dragInput, "a drag event that snaps, with \(size) shapes in view, took \(after) ms")
            }
        }
    },
    test("a hover on a note's dot, and a drag from it drawing an arrow across the board, each with the whole canvas redrawn, fit in a frame") {
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        for size in sizes {
            let document = generatedBoard(shapes: size)
            let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
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
            // arrow, and subboards and schema cards, which don't.
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
            let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
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
    test("a keystroke in the @ picker, the @ that opens it included, costs what's near and what matches, not the board") {
        /// The @ that opens the picker on `owner` (recent picks, none yet, and the shapes nearest the
        /// note), then each character of queries that match by each tier, and one that matches
        /// nothing (the typo pass, over the whole catalog): the @'s time, and the slowest.
        @MainActor func keystrokes(_ mentions: MentionState, owner: ShapeID) -> (opening: Double, worst: (query: String, ms: Double)) {
            let opening = median(runs: 21) { _ = MentionPicker(at: 0, mentions: mentions, scope: AnyMentionable.self, owner: owner) }
            let picker = MentionPicker(at: 0, mentions: mentions, scope: AnyMentionable.self, owner: owner)
            expect(picker.rows.contains { $0.candidate != nil }, "the nearest shapes")
            var worst = (query: "@", ms: opening)
            for query in ["p", "pl", "pla", "plan", "plan 11", "pn11", "paln 11", "title 40", "zzzzq"] {
                let typed = "@" + query as NSString, before = "@" + query.dropLast() as NSString
                let ms = median(runs: 21, prepare: {
                    _ = picker.read(before, selection: NSRange(location: before.length, length: 0), isEdit: true)
                }) {
                    _ = picker.read(typed, selection: NSRange(location: typed.length, length: 0), isEdit: true)
                }
                if ms > worst.ms { worst = ("@" + query, ms) }
            }
            _ = picker.read("@plan 11", selection: NSRange(location: 8, length: 0), isEdit: true)
            expectEqual(picker.highlightedCandidate?.appearance.label, "Plan 11")
            return (opening, worst)
        }
        for size in sizes {
            let document = generatedBoard(shapes: size)
            let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
            let editor = CanvasEditor(registry: registry, document: document, scheduler: ManualScheduler())
            let (opening, worst) = keystrokes(try require(editor.mentions), owner: try require(document.shapes.first { $0.kind == StickyNote.kind }?.id))

            // The same shapes spread over two boards, typed inside the subboard: the catalog is the
            // whole file's, so a keystroke there matches as many.
            let file = generatedFile(root: size / 2, children: [size / 2])
            let child = BoardID(owner: try require(owners(in: file).first))
            let nestedEditor = CanvasEditor(registry: registry, file: file, showing: child, scheduler: ManualScheduler())
            let nested = keystrokes(try require(nestedEditor.mentions),
                                    owner: try require(nestedEditor.document.shapes.first { $0.kind == StickyNote.kind }?.id))

            // A board of few mentionable shapes among many that aren't: the @ finds its few
            // nearby without gathering the board square after square.
            let sparse = sparseBoard(shapes: size)
            let sparseEditor = CanvasEditor(registry: registry, document: sparse.document, scheduler: ManualScheduler())
            let sparseMentions = try require(sparseEditor.mentions)
            let sparseOpening = median(runs: 21) {
                _ = MentionPicker(at: 0, mentions: sparseMentions, scope: AnyMentionable.self, owner: sparse.owner)
            }
            let sparsePicker = MentionPicker(at: 0, mentions: sparseMentions, scope: AnyMentionable.self, owner: sparse.owner)
            expectEqual(Set(sparsePicker.rows.compactMap(\.candidate?.id)), Set(sparse.others), "the other mentionable shapes, nearby")
            report(String(format: "%6d shapes, the @ picker: the @ %6.3f ms, the slowest keystroke %6.3f ms (\"%@\"); on two boards, inside the subboard, %6.3f and %6.3f (\"%@\"); the @ among 3 mentionable shapes %6.3f ms (budget %.0f)",
                          size, opening, worst.ms, worst.query, nested.opening, nested.worst.ms, nested.worst.query, sparseOpening, Budget.pickerKeystroke))
            if holdsToBudgets {
                expect(opening < Budget.pickerKeystroke, "the @ that opens the picker over \(size) shapes took \(opening) ms")
                expect(worst.ms < Budget.pickerKeystroke, "a keystroke in the picker (\(worst.query)) over \(size) shapes took \(worst.ms) ms")
                expect(nested.opening < Budget.pickerKeystroke, "the @ that opens the picker over \(size) shapes on two boards took \(nested.opening) ms")
                expect(nested.worst.ms < Budget.pickerKeystroke,
                       "a keystroke in the picker (\(nested.worst.query)) over \(size) shapes on two boards took \(nested.worst.ms) ms")
                expect(sparseOpening < Budget.pickerKeystroke, "the @ among 3 mentionable shapes of \(size) took \(sparseOpening) ms")
            }
        }
    },
    test("a keystroke in the @ picker on the line of a command that takes few shapes, the @ included, costs what they are, not the board: five subboards among 10,000 notes, by the kinds it names") {
        for size in sizes {
            let board = fewSubboardsBoard(shapes: size)
            let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
            let editor = CanvasEditor(registry: registry, document: board.document, scheduler: ManualScheduler())
            let mentions = try require(editor.mentions)
            // What `/move-to` takes: shapes that hold shapes or own boards, but the note it's typed on
            // and a shape that can't change.
            let kinds = registry.containingKinds.union(registry.boardOwningKinds)
            let rule: @MainActor (ShapeID) -> Bool = { $0 != board.owner && !editor.isReadOnly($0) }
            // The same command with no kinds says it in its rule, asked of every shape the list looks at.
            let ruleAlone: @MainActor (ShapeID) -> Bool = { id in editor.document[id].map { kinds.contains($0.kind) } == true && rule(id) }
            /// The first `@` (which makes the shapes of the kinds, one pass over the catalog), the `@` after it, and
            /// each character of queries that match by each tier and of one that matches nothing: the slowest.
            @MainActor func keystrokes(kinds: Set<ShapeKind>?, rule: @escaping @MainActor (ShapeID) -> Bool)
                -> (first: Double, opening: Double, worst: (query: String, ms: Double)) {
                let open = { _ = MentionPicker(at: 0, mentions: mentions, scope: AnyMentionable.self, owner: board.owner, kinds: kinds, admitting: rule) }
                let first = median(runs: 1, onThread: true, open)
                let opening = median(runs: 21, onThread: true, open)
                let picker = MentionPicker(at: 0, mentions: mentions, scope: AnyMentionable.self, owner: board.owner, kinds: kinds, admitting: rule)
                let listed = picker.rows.compactMap(\.candidate?.id)
                expect(listed.count == (kinds == nil ? MentionRanking.nearbyShown : board.subboards.count) && Set(listed).isSubset(of: Set(board.subboards)),
                       "the subboards, however far they are: all five, by the kinds")
                var worst = (query: "@", ms: opening)
                for query in ["p", "pl", "pla", "plan", "plan 3", "pn3", "paln 3", "note 1", "zzzzq"] {
                    let typed = "@" + query as NSString, before = "@" + query.dropLast() as NSString
                    let ms = median(runs: 21, prepare: {
                        _ = picker.read(before, selection: NSRange(location: before.length, length: 0), isEdit: true)
                    }, onThread: true) {
                        _ = picker.read(typed, selection: NSRange(location: typed.length, length: 0), isEdit: true)
                    }
                    if ms > worst.ms { worst = ("@" + query, ms) }
                }
                _ = picker.read("@plan 3", selection: NSRange(location: 7, length: 0), isEdit: true)
                expectEqual(picker.highlightedCandidate?.appearance.label, "Plan 3")
                return (first, opening, worst)
            }
            let named = keystrokes(kinds: kinds, rule: rule)
            let unnamed = keystrokes(kinds: nil, rule: ruleAlone)
            report(String(format: "%6d shapes, 5 subboards, on a command's line, by its kinds: the first @ %6.3f ms, then %6.3f ms, the slowest keystroke %6.3f ms (\"%@\") (budget %.0f); by its rule alone, reported: the @ %6.3f ms, the slowest keystroke %6.3f ms (\"%@\")",
                          size, named.first, named.opening, named.worst.ms, named.worst.query, Budget.pickerKeystroke, unnamed.opening, unnamed.worst.ms, unnamed.worst.query))
            if holdsToBudgets {
                expect(named.opening < Budget.pickerKeystroke, "the @ on a command's line, by its kinds, over \(size) shapes took \(named.opening) ms")
                expect(named.worst.ms < Budget.pickerKeystroke, "a keystroke there (\(named.worst.query)) over \(size) shapes took \(named.worst.ms) ms")
            }
        }
    },
    test("completing a schema card's JSON near the end of a schema as long as the model writes costs a keystroke") {
        // Fields until the text is as long as the model may write; the caret near its end.
        var fields = #"{"title": "Everything", "type": "object", "properties": {"#
        var names: [String] = []
        while fields.utf8.count < SchemaPrompts.toSchemaMaxLength {
            names.append("field\(names.count)")
            fields += "\n    \"\(names[names.count - 1])\": {\"type\": \"string\", \"description\": \"Field number \(names.count), kept short\", \"maxLength\": 80},"
        }
        let cases: [(what: String, text: String, caret: Int, offered: String)] = [
            // A keyword being typed in the last field's schema, left open.
            ("a key typed", fields + "\n    \"last\": {\"type\": \"string\", \"mi", 0, "minLength"),
            // The root's keywords, beside the members the whole schema holds.
            ("the root's keys", fields + "\n    \"last\": {}\n  }\n  \n}", -2, "description"),
            // A required list, which offers every field's name.
            ("a required name", fields + "\n    \"last\": {}\n  },\n  \"required\": [\"field0\", ]\n}", -3, "field1"),
        ]
        var times: [String] = []
        for (what, text, fromEnd, offered) in cases {
            let caret = (text as NSString).length + fromEnd
            var completions: JSONCompletions?
            let time = median(runs: 21) { completions = SchemaCompletions.completions(in: text, at: caret) }
            expect(completions?.items.contains { $0.label == offered } == true, what)
            times.append(String(format: "%@ %6.3f ms", what, time))
            if holdsToBudgets { expect(time < Budget.schemaCompletion, "completing \(what) in \(text.utf8.count) bytes took \(time) ms") }
        }
        let lengths = cases.map(\.text.utf8.count)
        report(String(format: "a schema card's JSON of %d to %d bytes, %d fields: completing %@ (budget %.0f)",
                      lengths.min() ?? 0, lengths.max() ?? 0, names.count + 1, times.joined(separator: ", "), Budget.schemaCompletion))
    },
    test("renaming a shape mentioned 100 times costs its commit, and reading the rows and validation after it, little more than renaming one mentioned by none") {
        for size in sizes {
            let document = generatedBoard(shapes: size)
            let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
            let editor = CanvasEditor(registry: registry, document: document, scheduler: ManualScheduler())
            let mentions = try require(editor.mentions)
            let contents = try require(editor.tableOfContents)
            let validation = try require(editor.validation)
            var rows = contents.entries
            _ = validation.results
            let mentioned = try require(mentionedSubboard(in: document))
            let unmentioned = try require(document.shapes.last { $0.kind == Subboard.kind && mentions.mentioners(of: $0.id).isEmpty }?.id)
            let mentioners = mentions.mentioners(of: mentioned).count
            var n = 0
            @MainActor func rename(_ id: ShapeID) {
                n += 1
                editor.transact { $0.update(id) { $0[TitleProperty.self] = "Renamed \(n)" } }
            }
            let commitMentioned = median(runs: 21) { rename(mentioned) }
            let commitOther = median(runs: 21) { rename(unmentioned) }
            let rowsMentioned = median(runs: 21, prepare: { rename(mentioned) }) { rows = contents.entries }
            let rowsOther = median(runs: 21, prepare: { rename(unmentioned) }) { rows = contents.entries }
            expectEqual(rowCount(rows), size)
            let first = try require(mentions.mentioners(of: mentioned).first)
            expect(rows.first { $0.id == first }?.label?.text.contains("Renamed \(n - 21)") == true, "a mentioner's row names the subboard as it's called now")
            // Validation checks the mentioners again, as their rules looked the subboard up.
            var results = validation.results
            let validationMentioned = median(runs: 21, prepare: { rename(mentioned) }) { results = validation.results }
            let validationOther = median(runs: 21, prepare: { rename(unmentioned) }) { results = validation.results }
            expect(results.isEmpty, "the generated board has no issues")
            report(String(format: "%6d shapes, renaming a subboard mentioned %d times: the commit %6.3f ms, %6.3f for one mentioned by none (budget: %.0f more); the rows after it %6.3f, %6.3f; validation after it %6.3f, %6.3f (budget: %.0f more)",
                          size, mentioners, commitMentioned, commitOther, Budget.renameMentioned, rowsMentioned, rowsOther,
                          validationMentioned, validationOther, Budget.renameMentioned))
            if holdsToBudgets {
                expectEqual(mentioners, 100)
                expect(commitMentioned - commitOther < Budget.renameMentioned,
                       "renaming a subboard mentioned \(mentioners) times over \(size) shapes took \(commitMentioned) ms, against \(commitOther)")
                expect(validationMentioned - validationOther < Budget.renameMentioned,
                       "validation after renaming a subboard mentioned \(mentioners) times over \(size) shapes took \(validationMentioned) ms, against \(validationOther)")
            }
        }
    },
    test("the panel of a subboard mentioned 100 times, its Mentioned In tab showing, is read after a drag of another note and after a mentioner's rename in a millisecond") {
        for size in sizes {
            let document = generatedBoard(shapes: size)
            let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
            let editor = CanvasEditor(registry: registry, document: document, scheduler: ManualScheduler())
            let panel = try require(editor.detailPanel)
            let mentions = try require(editor.mentions)
            _ = editor.validation?.results
            let subboard = try require(mentionedSubboard(in: document))
            let mentioners = mentions.mentioners(of: subboard)
            let mentioner = try require(mentioners.first)
            let other = try require(document.shapes.first { $0.kind == StickyNote.kind && !mentions.mentions(in: $0.id).contains(subboard) })
            let origin = try require(other.box?.origin)
            var layout = panel.layout(for: try require(editor.document[subboard]))
            expect(layout.tabs.contains(.of(MentionsTab.self)), "the subboard shows what mentions it")
            var step = 0.0
            let afterDrag = median(runs: 21, prepare: {
                step += 1
                editor.transact { $0.moveBox(other.id, to: CGPoint(x: origin.x + step, y: origin.y)) }
            }) { layout = panel.layout(for: editor.document[subboard]!) }
            var n = 0
            @MainActor func rename() {
                n += 1
                editor.transact { $0.update(mentioner) { $0[TitleProperty.self] = "Mentioner \(n)" } }
            }
            let afterRename = median(runs: 21, prepare: rename) { layout = panel.layout(for: editor.document[subboard]!) }
            // What the tab's list reads when a mentioner changes: every line again.
            var lines: [MentionBacklink] = []
            let backlinks = median(runs: 21, prepare: rename) { lines = mentions.backlinks(of: subboard) }
            expectEqual(lines.first?.label, "Mentioner \(n)")
            expect(layout.tabs.contains(.of(MentionsTab.self)))
            report(String(format: "%6d shapes, the panel of a subboard mentioned %d times: after a drag event of another note %6.3f ms, after renaming a mentioner %6.3f (budget %.0f); its Mentioned In lines %6.3f",
                          size, mentioners.count, afterDrag, afterRename, Budget.panelAfterCommit, backlinks))
            if holdsToBudgets {
                expectEqual(mentioners.count, 100)
                expect(afterDrag < Budget.panelAfterCommit, "the panel of a subboard mentioned 100 times, after a drag event over \(size) shapes, took \(afterDrag) ms")
                expect(afterRename < Budget.panelAfterCommit, "the panel of a subboard mentioned 100 times, after a mentioner's rename over \(size) shapes, took \(afterRename) ms")
            }
        }
    },
    test("what's connected to a shape with 100 edges, and how, costs what it returns, not the board") {
        for size in sizes {
            let document = generatedBoard(shapes: size)
            let editor = CanvasEditor(registry: try ShippedPlugins.registry(model: ScriptedLanguageModel()), document: document,
                                      scheduler: ManualScheduler())
            let topology = try require(editor.topology)
            let mentioned = try require(mentionedSubboard(in: document))
            var found: [EdgeTypeID: [ShapeID]] = [:]
            let all = median(runs: 21) { found = topology.neighbors(of: mentioned) }
            let degree = found.values.reduce(0) { $0 + $1.count }
            let mentioners = median(runs: 21) { found = topology.neighbors(of: mentioned, .incoming, types: .only(MentionEdge.id)) }
            let arrows = median(runs: 21) { found = topology.neighbors(of: mentioned, types: .within(EdgeTypeID(rawValue: Arrow.kind.rawValue))) }
            expectEqual(found, [:], "no arrow ends at a subboard")
            report(String(format: "%6d shapes, what's connected to a subboard with %d edges: %6.3f ms, its mentioners alone %6.3f, its arrows (none) %6.3f (budget %.0f)",
                          size, degree, all, mentioners, arrows, Budget.neighbors100))
            if holdsToBudgets {
                expectEqual(degree, 100)
                expect(all < Budget.neighbors100, "what's connected to a shape with \(degree) edges, of \(size) shapes, took \(all) ms")
                expect(mentioners < Budget.neighbors100, "a shape's \(degree) mentioners, of \(size) shapes, took \(mentioners) ms")
            }
        }
    },
    test("entering a subboard of the board's worth of shapes fits the budget once, and going back up to its board and down again, as they were left, costs a frame") {
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        for size in sizes {
            let file = generatedFile(root: size, children: [size])
            let owner = try require(owners(in: file).first)
            let child = BoardID(owner: owner)
            var h = EditorHarness { CanvasEditor(registry: registry, file: file, scheduler: $0) }
            var rows: [ContentsEntry] = []
            // What showing a board takes before it's seen: a frame, the rows, the issues.
            let reads = {
                draw(h.editor, into: context, size: viewport)
                rows = try require(h.editor.tableOfContents).entries
                _ = try require(h.editor.validation).results
            }
            // Cold: a new editor each run, on the root as it's first seen, the subboard selected;
            // then ⌘↓ (the camera's first fit on the way in).
            let cold = try median(runs: 3, prepare: {
                h = EditorHarness { CanvasEditor(registry: registry, file: file, scheduler: $0) }
                h.editor.viewportDidResize(to: viewport)
                try? reads()
                h.editor.selectedShapeIDs = [owner]
            }) {
                h.editor.perform(.openSelection)
                try reads()
            }
            expectEqual(h.editor.board, child, "⌘↓ entered the subboard")
            expectEqual(rowCount(rows), size)
            let fitted = h.editor.camera.zoom
            // As the root's, and the frame benchmark's: the first visit fitted every shape into view,
            // and a frame of them all is a frame of 10,000 shapes, whatever board they're on.
            h.editor.camera = Camera()
            // Warm: ⌘↑ to the root, which selects the subboard, and ⌘↓ into it again, each run
            // going back to the board the one before left.
            let up = try median(runs: 21, prepare: { if h.editor.board.isRoot { h.editor.perform(.openSelection) } }) {
                h.editor.perform(.enclosingBoard)
                try reads()
            }
            expect(h.editor.board.isRoot, "⌘↑ went up")
            expectEqual(rowCount(rows), 1, "the subboard selected, and listed alone")
            let down = try median(runs: 21, prepare: { if !h.editor.board.isRoot { h.editor.perform(.enclosingBoard) } }) {
                h.editor.perform(.openSelection)
                try reads()
            }
            expectEqual(h.editor.board, child, "⌘↓ went down")
            // Up again, then the selection let go of, so the root lists every row: its rows and
            // listing as it was left, taken back.
            let upListed = try median(runs: 21, prepare: {
                if h.editor.board.isRoot {
                    h.editor.selectedShapeIDs = [owner]
                    h.editor.perform(.openSelection)
                }
            }) {
                h.editor.perform(.enclosingBoard)
                h.editor.selectedShapeIDs = []
                try reads()
            }
            expect(h.editor.board.isRoot, "⌘↑ went up")
            expectEqual(rowCount(rows), size + 1, "every shape of the root listed, the subboard's too")
            report(String(format: "%6d shapes on each board: entering the subboard, cold, %6.1f ms (budget %.0f; fitted at %.0f%%); going back up to the root %5.1f ms (listing it all %5.1f), down again %5.1f (budget %.0f)",
                          size, cold, Budget.enterCold, fitted * 100, up, upListed, down, Budget.warmReturn))
            if holdsToBudgets {
                if size >= 10_000 {
                    expect(cold < Budget.enterCold, "entering a subboard of \(size) shapes, cold, took \(cold) ms")
                }
                expect(up < Budget.warmReturn, "going back up to a board of \(size) shapes took \(up) ms")
                expect(upListed < Budget.warmReturn, "going back up to a board of \(size) shapes and listing it all took \(upListed) ms")
                expect(down < Budget.warmReturn, "going back down to a board of \(size) shapes took \(down) ms")
            }
        }
    },
    test("frames and rows cost the board shown: a board beside a subboard of ten times its shapes, and a subboard as big as the root") {
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        // A drag event's input alone (its commit), without the frame: drawing hides a commit's
        // upkeep of the whole file, which a drag on a board beside or inside a subboard mustn't
        // cost more than on a file of that board alone. With the board's first note pressed.
        @MainActor func dragInput(_ h: EditorHarness, from center: CGPoint, step: inout Int) -> Double {
            var at = step
            defer { step = at }
            return median(runs: 51) {
                at += 1
                h.drag(to: center + CGPoint(x: CGFloat(at), y: CGFloat(at) / 2))
            }
        }
        // The same on a file of one board of `size` generated shapes.
        @MainActor func dragInputAlone(_ size: Int) throws -> Double {
            let h = EditorHarness { CanvasEditor(registry: registry, document: generatedBoard(shapes: size), scheduler: $0) }
            h.editor.viewportDidResize(to: viewport)
            let note = try require(h.editor.document.shapes.first { $0.kind == StickyNote.kind })
            let center = CGPoint(x: try require(note.box).midX, y: try require(note.box).midY)
            var step = 0
            h.press(at: center)
            defer { h.release() }
            return dragInput(h, from: center, step: &step)
        }
        // A hover and a drag on the board's first note, each with a frame, the drag's input alone,
        // and the rows (every shape listed) after a drag event.
        @MainActor func frames(_ h: EditorHarness) throws -> (hover: Double, drag: Double, input: Double, rows: Double) {
            let contents = try require(h.editor.tableOfContents)
            let note = try require(h.editor.document.shapes.first { $0.kind == StickyNote.kind })
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
            let input = dragInput(h, from: center, step: &step)
            contents.showAll()
            var rows = contents.entries
            let afterDrag = median(runs: 21, prepare: {
                step += 1
                h.drag(to: center + CGPoint(x: CGFloat(step), y: CGFloat(step) / 2))
            }) { rows = contents.entries }
            h.release()
            expectEqual(rowCount(rows), h.editor.document.shapes.count, "every shape of the board shown listed")
            // Where the pointer put it, or snapped within 8 points of there to a shape in view.
            let moved = try require(h.editor.document[note.id]?.box?.origin.x) - (note.box?.origin.x ?? 0)
            expect(abs(moved - CGFloat(step)) <= 8, "the drag moved the note \(moved), the pointer \(step)")
            return (hover, drag, input, afterDrag)
        }
        for size in sizes {
            // The root: a tenth of the shapes, or all of them at the smallest size, beside a
            // subboard holding them all.
            let beside = EditorHarness { CanvasEditor(registry: registry, file: generatedFile(root: min(1_000, size), children: [size]), scheduler: $0) }
            beside.editor.viewportDidResize(to: viewport)
            let root = try frames(beside)
            // Inside a subboard of the board's worth, the root holding as many: at the frame
            // benchmark's camera, not the first visit's fit.
            let file = generatedFile(root: size, children: [size])
            let inside = EditorHarness { CanvasEditor(registry: registry, file: file, scheduler: $0) }
            inside.editor.viewportDidResize(to: viewport)
            expect(inside.enter(try require(owners(in: file).first)), "entered the subboard")
            inside.editor.camera = Camera()
            let child = try frames(inside)
            expectEqual(inside.file.shapeCount, file.shapeCount)
            let rootAlone = try dragInputAlone(min(1_000, size)), childAlone = try dragInputAlone(size)
            report(String(format: "%6d shapes in a subboard of a root of %d: hover %5.1f ms, drag %5.1f (budget %.0f; its input %6.3f, budget %.0f, %6.3f on that board alone), rows after a drag event %6.3f (budget %.0f)",
                          size, min(1_000, size), root.hover, root.drag, Budget.frame, root.input, Budget.dragInput, rootAlone, root.rows, Budget.contentsRows))
            report(String(format: "%6d shapes inside a subboard, as many on the root: hover %5.1f ms, drag %5.1f (budget %.0f; its input %6.3f, budget %.0f, %6.3f on that board alone), rows after a drag event %6.3f (budget %.0f)",
                          size, child.hover, child.drag, Budget.frame, child.input, Budget.dragInput, childAlone, child.rows, Budget.contentsRows))
            if holdsToBudgets {
                for (what, times) in [("on a root beside a subboard of \(size) shapes", root), ("inside a subboard of \(size) shapes", child)] {
                    expect(times.hover < Budget.frame, "a hover \(what) took \(times.hover) ms")
                    expect(times.drag < Budget.frame, "a drag \(what) took \(times.drag) ms")
                    expect(times.rows < Budget.contentsRows, "reading the rows after a drag event \(what) took \(times.rows) ms")
                }
                if size >= 10_000 {
                    for (what, input, alone) in [("on a root beside a subboard of \(size) shapes", root.input, rootAlone),
                                                 ("inside a subboard of \(size) shapes", child.input, childAlone)] {
                        expect(input < Budget.dragInput, "a drag event's input \(what) took \(input) ms")
                        expect(input < Budget.dragInputOverAlone * alone + Budget.dragInputSlack,
                               "a drag event's input \(what) took \(input) ms, against \(alone) on its board alone")
                    }
                }
            }
        }
    },
    test("canvas draw places shapes on a big board in what's near them: each pushed along a row of the grid to its end") {
        for size in sizes {
            let document = generatedBoard(shapes: size)
            let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
            let editor = CanvasEditor(registry: registry, document: document, scheduler: ManualScheduler())
            editor.viewportDidResize(to: CGSize(width: 1200, height: 800))
            // The worst of it: a note right of a titled note in each of 20 rows, which it lands on the
            // next shape of and is pushed past it, and the next, to the row's end.
            let columns = Int(Double(size).squareRoot().rounded(.up))
            var firstTitled: [Int: String] = [:]       // each row's first titled note in its first half
            for shape in document.shapes {
                guard let box = shape.box, box.minX < CGFloat(columns / 2) * 260, let title = registry.title(of: shape), title.hasPrefix("Title ") else { continue }
                if firstTitled[Int(box.minY / 260)] == nil { firstTitled[Int(box.minY / 260)] = title }
            }
            let rows = firstTitled.keys.sorted(), count = min(20, rows.count)      // a small board has fewer rows
            let lines = (0..<count).map { k in
                "sticky-note \"Mine \(k)\" right of \"\(firstTitled[rows[k * rows.count / count]]!)\" text: \"Pushed along\""
            }
            let commands = registry.hostCommands
            var result: JSON = [:], times: [Double] = []
            for _ in 0..<5 {
                // The draw alone: it answers without suspending, so the clock reads nothing else.
                let (drawn, time) = try awaitResult { () async throws -> (JSON, Double) in
                    let clock = ContinuousClock(), start = clock.now
                    let drawn = try await commands.run("draw", ["script": .string(lines.joined(separator: "\n")), "dryRun": true], editor)
                    return (drawn, (clock.now - start).milliseconds)
                }
                result = drawn
                times.append(time)
            }
            let time = times.sorted()[times.count / 2]
            let pushes = (result["changes"]?.arrayValue ?? []).reduce(0) { $0 + ($1["pushedPast"]?.arrayValue?.count ?? 0) }
            expectEqual(result["changes"]?.arrayValue?.count, count)
            expect(pushes >= count, "every note is pushed: \(pushes)")
            report(String(format: "%6d shapes: a draw of %d notes, pushed %d times in all, %6.1f ms (budget %.0f)", size, count, pushes, time, Budget.draw20))
            if holdsToBudgets, size >= 10_000 { expect(time < Budget.draw20, "a draw of 20 notes on \(size) shapes took \(time) ms") }
        }
    },
    test("the minimap draws a board a frame's worth at a time, and a drag redraws only what moved") {
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        for size in sizes {
            let document = generatedBoard(shapes: size)
            let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
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
    test("the minimap's picture of a subboard entered fills a frame's worth at a time, as the root's did") {
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        for size in sizes {
            let file = generatedFile(root: size, children: [size])
            let h = EditorHarness { CanvasEditor(registry: registry, file: file, scheduler: $0) }
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: viewport), styleMask: [.titled], backing: .buffered, defer: false)
            let canvas = CanvasView(editor: h.editor)
            window.contentView = canvas
            canvas.showsMinimap = true
            let minimap = try require(canvas.minimap)
            let minimapContext = try bitmapContext(minimap.bounds.size, scale: window.backingScaleFactor)
            // Frames as they come, until the picture is all drawn: how many, and the longest (the
            // minimap's part of each).
            let clock = ContinuousClock()
            let fill = { () -> (frames: Int, longest: Double, total: Double) in
                var frames = 0, longest = 0.0, total = 0.0
                while true {
                    let ms = clock.measure { display(minimap, into: minimapContext) }.milliseconds
                    frames += 1
                    longest = max(longest, ms)
                    total += ms
                    guard h.scheduler.pendingCount > 0, frames < 1000 else { break }
                    h.wait(0)                                   // the next frame the minimap asked for
                }
                return (frames, longest, total)
            }
            draw(h.editor, into: context, size: viewport)
            let root = fill()
            expect(h.enter(try require(owners(in: file).first)), "entered the subboard")
            draw(h.editor, into: context, size: viewport)     // the first frame on the board entered
            let entered = fill()
            expectEqual(h.scheduler.pendingCount, 0, "the picture of the board entered is all drawn")
            report(String(format: "%6d shapes on each board: the minimap's picture of the root %.1f ms in %d frames (longest %.1f); of the subboard entered %.1f ms in %d frames, the longest %.1f (budget %.0f)",
                          size, root.total, root.frames, root.longest, entered.total, entered.frames, entered.longest, Budget.frame))
            if holdsToBudgets {
                expect(entered.longest < Budget.frame, "a frame of the minimap's picture of a subboard of \(size) shapes, entered, took \(entered.longest) ms")
            }
        }
    },
    test("ten subboards in view, each holding the board's worth of shapes: their previews fill in a frame's worth at a time") {
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        for size in sizes {
            // Five across and two down, all in view, each board its own (ids are unique in a file).
            let subs = (0..<10).map { i in
                ShapeRecord(Subboard(frame: CGRect(origin: CGPoint(x: 10 + CGFloat(i % 5) * 237, y: 60 + CGFloat(i / 5) * 300), size: Subboard.defaultSize)))
            }
            let file = CanvasFile(root: CanvasDocument(shapes: subs.map(AnyShapeRecord.init)),
                                  children: Dictionary(uniqueKeysWithValues: subs.map { ($0.id, generatedBoard(shapes: size)) }))
            // The cards' first frame loads what drawing them takes (fonts, symbols, formatting a count),
            // which isn't the previews'; and a frame of the cards alone, with nothing inside, is what
            // one costs without them.
            let warm = CanvasFile(root: file.root, children: Dictionary(uniqueKeysWithValues: subs.map { ($0.id, generatedBoard(shapes: 2)) }))
            draw(CanvasEditor(registry: registry, file: warm, scheduler: ManualScheduler()), into: context, size: viewport)
            let empty = CanvasEditor(registry: registry, file: CanvasFile(root: file.root), scheduler: ManualScheduler())
            let cards = median(runs: 11) { draw(empty, into: context, size: viewport) }
            let h = EditorHarness { CanvasEditor(registry: registry, file: file, scheduler: $0) }
            h.editor.viewportDidResize(to: viewport)
            // Frames as they come, until the last preview is built (and drawn, in the frame that
            // builds it): how many, and the longest.
            let clock = ContinuousClock()
            var frames = 0, longest = 0.0, total = 0.0
            repeat {
                let took = clock.measure { draw(h.editor, into: context, size: viewport) }
                let ms = Double(took.components.seconds) * 1000 + Double(took.components.attoseconds) / 1e15
                frames += 1
                longest = max(longest, ms)
                total += ms
                h.wait(0)                                   // the next frame the editor asked for
            } while h.editor.boardPreviews.isPending && frames < 10_000
            expectEqual(h.editor.boardPreviews.keptKeys.count, subs.count, "every preview built")
            expectEqual(h.scheduler.pendingCount, 0, "and no frame asked for after")
            report(String(format: "%6d shapes in each of 10 subboards: their previews all drawn in %d frames (%.1f ms), the longest %.1f ms (budget %.0f); a frame of the cards alone %.1f",
                          size, frames, total, longest, Budget.frame, cards))
            if holdsToBudgets {
                expect(longest < Budget.frame, "a frame while previews of 10 subboards of \(size) shapes filled took \(longest) ms")
            }
        }
    },
    test("previews shown larger than their masks are drawn as paths, a frame's worth of shapes: ten cards on a 2× screen, and one zoomed in") {
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport, scale: 2)
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        // A frame once every preview is built, as paths where they'd be enlarged and as masks alone.
        @MainActor func frames(_ file: CanvasFile, camera: Camera = Camera()) -> (paths: Double, masks: Double) {
            let h = EditorHarness { CanvasEditor(registry: registry, file: file, scheduler: $0) }
            h.editor.viewportDidResize(to: viewport)
            h.editor.camera = camera
            h.editor.boardPreviews.frameBudget = .seconds(60)
            draw(h.editor, into: context, size: viewport)
            h.wait(0)
            let paths = median(runs: 11, onThread: true) { draw(h.editor, into: context, size: viewport) }
            h.editor.boardPreviews.pathShapes = 0
            let masks = median(runs: 11, onThread: true) { draw(h.editor, into: context, size: viewport) }
            return (paths, masks)
        }
        // Ten cards at 100% on a 2× screen, 432 pixels of preview each, every board 100 shapes: the frame's 1,000 as paths.
        let subs = (0..<10).map { i in
            ShapeRecord(Subboard(frame: CGRect(origin: CGPoint(x: 10 + CGFloat(i % 5) * 237, y: 60 + CGFloat(i / 5) * 300), size: Subboard.defaultSize)))
        }
        let ten = CanvasFile(root: CanvasDocument(shapes: subs.map(AnyShapeRecord.init)),
                             children: Dictionary(uniqueKeysWithValues: subs.map { ($0.id, generatedBoard(shapes: 100)) }))
        let cards = frames(ten)
        report(String(format: "ten subboards of 100 shapes on a 2× screen: a frame with their 1,000 as paths %.1f ms, with masks %.1f (budget %.0f)",
                      cards.paths, cards.masks, Budget.frame))
        // One card of the board's worth zoomed in to 800% on its middle: its preview drawn alone, the cells in view as
        // paths, and the mask for the control; and the frame, against the card with nothing on its board.
        let sub = ShapeRecord(Subboard(frame: CGRect(x: 0, y: 0, width: 2400, height: 1600)))
        let middle = camera(centering: CGRect(x: 1100, y: 700, width: 200, height: 200), at: 8, in: viewport)
        let alone = frames(CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(sub)])), camera: middle).masks
        for size in sizes {
            let one = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(sub)]), children: [sub.id: generatedBoard(shapes: size)])
            let zoomed = frames(one, camera: middle)
            let previews = BoardPreviews(registry: registry)
            _ = previews.preview(of: BoardID(owner: sub.id), in: one)
            previews.build(in: one, until: .now + .seconds(60))
            let preview = try require(previews.preview(of: BoardID(owner: sub.id), in: one))
            // As the card draws it, 12 in from its edges at a tenth of its board's size at most (`SubboardStyle`).
            @MainActor func drawing() -> Double {
                median(runs: 11, prepare: { previews.endFrame() }, onThread: true) {
                    context.saveGState()
                    context.scaleBy(x: middle.zoom, y: middle.zoom)
                    context.translateBy(x: -middle.origin.x, y: -middle.origin.y)
                    previews.draw(preview, in: context, fitting: sub.props.frame.insetBy(dx: 12, dy: 12), maxScale: 0.1, color: CGColor(gray: 0.6, alpha: 1))
                    context.restoreGState()
                }
            }
            let paths = drawing()
            previews.pathShapes = 0
            let mask = drawing()
            report(String(format: "%6d shapes in a subboard 2400 × 1600 at 800%% on a 2× screen: its preview, what's in view as paths %.2f ms, its mask %.1f; the frame %.1f, the card alone %.1f",
                          size, paths, mask, zoomed.paths, alone))
            if holdsToBudgets {
                expect(paths < Budget.previewPaths, "the preview zoomed in on a subboard of \(size), as paths, took \(paths) ms")
            }
        }
        if holdsToBudgets {
            expect(cards.paths < Budget.frame, "a frame of ten cards' previews as paths took \(cards.paths) ms")
        }
    },
    test("a shape holding all the view, zoomed in to 800% on a 2× screen, costs a fill, not its shadow's blur: a subboard, a note and a schema card, each on its middle; an edge or a corner in view reported") {
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport, scale: 2)
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let note = StickyNote(frame: CGRect(origin: .zero, size: StickyNote.defaultSize), text: MentionText(plain: "Note: something to do"))
        var schema = SchemaCard(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        // A card as tall as its description: six of these lines, some 140 world units at 320 wide.
        schema.setPrompt(SchemaPromptText(plain: Array(repeating: "Record: its name, a count, and its tags.", count: 6).joined(separator: "\n")))
        let shapes = [("a subboard 2400 × 1600", AnyShapeRecord(ShapeRecord(Subboard(frame: CGRect(x: 0, y: 0, width: 2400, height: 1600))))),
                      ("a note", AnyShapeRecord(ShapeRecord(note))), ("a schema card of six lines", AnyShapeRecord(ShapeRecord(schema)))]
        for (name, shape) in shapes {
            let h = EditorHarness { CanvasEditor(registry: registry, document: CanvasDocument(shapes: [shape]), scheduler: $0) }
            h.editor.viewportDidResize(to: viewport)
            let bounds = h.editor.shapeBounds
            // The camera at 800% with `point` in the middle of the view.
            @MainActor func frame(on point: CGPoint) -> Double {
                h.editor.camera = camera(centering: CGRect(origin: point, size: .zero), at: 8, in: viewport)
                draw(h.editor, into: context, size: viewport)
                return median(runs: 11, onThread: true) { draw(h.editor, into: context, size: viewport) }
            }
            let middle = frame(on: CGPoint(x: bounds.midX, y: bounds.midY))
            // Its shadow drawn, on the CPU here (on screen the GPU blurs it, some 0.7 ms of the process's CPU a frame, measured).
            let edge = frame(on: CGPoint(x: bounds.minX, y: bounds.midY)), corner = frame(on: CGPoint(x: bounds.minX, y: bounds.minY))
            report(String(format: "%@ (%.0f × %.0f) at 800%% on a 2× screen: a frame on its middle %.2f ms (budget %.0f); its left edge down the view's middle %.1f, its corner in the middle %.1f",
                          name, bounds.width, bounds.height, middle, Budget.coveredShape, edge, corner))
            if holdsToBudgets {
                expect(middle < Budget.coveredShape, "\(name) at 800% holding the view: a frame took \(middle) ms")
            }
        }
    },
    test("undo and redo cost what their step changed: a drag's is a frame's worth, whatever the board") {
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        for size in sizes {
            let document = generatedBoard(shapes: size)
            let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
            let h = EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }
            let frame = { draw(h.editor, into: context, size: viewport) }
            frame()
            // A note dragged, as the select tool drags it: one step, Move, undone and redone with the
            // frame after each.
            let note = try require(document.shapes.first { $0.kind == StickyNote.kind })
            let center = CGPoint(x: try require(note.box).midX, y: try require(note.box).midY)
            h.press(at: center)
            for step in 1...10 { h.drag(to: center + CGPoint(x: CGFloat(step * 4), y: CGFloat(step * 2))) }
            h.release()
            expectEqual(h.editor.undoHistory.undoName, "Move")
            let drag = undoAndRedo(h.editor, runs: 21, frame: frame)
            // A tenth of the board moved and deleted at once (none of it locked, which would refuse),
            // each step timed as made too; and every shape deleted, once every lock is off. These
            // time the steps alone, without a frame: the frame after one draws the shapes it brought
            // into view afresh, whatever brought them, as the frame after the step itself does.
            let tenth = Set(document.shapes.filter { !$0.isLocked }.prefix(size / 10).map(\.id))
            var moved = 0.0
            let move = median(runs: 11) {
                moved += 1
                h.editor.transact("Move") { $0.translate(tenth, by: CGPoint(x: 5, y: moved)) }
            }
            let moveUndo = undoAndRedo(h.editor, runs: 11) {}
            let delete = median(runs: 11, prepare: { if h.editor.document[tenth.first!] == nil { h.editor.undo() } }) {
                h.editor.transact("Delete") { $0.delete(tenth) }
            }
            let deleteUndo = undoAndRedo(h.editor, runs: 11) {}
            h.editor.undo()
            h.editor.unlock(h.editor.document.shapes.filter(\.isLocked).map(\.id))
            let every = Set(h.editor.document.shapes.map(\.id))
            h.editor.transact("Delete") { $0.delete(every) }
            expectEqual(h.editor.document.shapes.count, 0, "every shape deleted")
            let all = undoAndRedo(h.editor, runs: 5) {}
            h.editor.undo()
            expectEqual(h.editor.document.shapes.count, size, "every shape back")
            report(String(format: "%6d shapes, undo and redo: a note's drag, with a frame, %5.1f and %5.1f ms (budget %.0f); %d shapes moved %5.1f and %5.1f (moving them %5.1f), deleted %5.1f and %5.1f (deleting them %5.1f), budget %.0f, without a frame; every shape (%d) deleted %5.1f and %5.1f (budget %.0f)",
                          size, drag.undo, drag.redo, Budget.frame, tenth.count, moveUndo.undo, moveUndo.redo, move, deleteUndo.undo, deleteUndo.redo, delete,
                          Budget.frame, every.count, all.undo, all.redo, Budget.undoEveryShape))
            if holdsToBudgets {
                for (what, times, budget) in [("a drag, with a frame,", drag, Budget.frame), ("\(tenth.count) shapes' move", moveUndo, Budget.frame),
                                              ("\(tenth.count) shapes' deletion", deleteUndo, Budget.frame),
                                              ("the deletion of \(every.count) shapes", all, Budget.undoEveryShape)] {
                    expect(times.undo < budget && times.redo < budget, "undoing and redoing \(what) on \(size) shapes took \(times) ms")
                }
            }
        }
    },
    test("deleting a subboard whose boards hold the board's worth of shapes takes a frame, and undoing and redoing it puts them back or takes them whole") {
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        for size in sizes {
            // A subboard on the root, among a few shapes: its board holds half the shapes and a
            // subboard whose board holds the other half, none locked (a locked shape inside keeps it).
            let file = unlocked(generatedFile(root: 20, children: [size], depth: 2))
            let owner = try require(owners(in: file).first)
            let h = EditorHarness { CanvasEditor(registry: registry, file: file, scheduler: $0) }
            h.editor.viewportDidResize(to: viewport)
            let frame = { draw(h.editor, into: context, size: viewport) }
            frame()
            let under = file.shapeCount - file.root.shapes.count
            // Each run deletes it as Delete does (the commit, and every board under it with it),
            // after an untimed undo of the run before.
            let delete = median(runs: 11, prepare: { if h.file.record(owner) == nil { h.editor.undo() } }) {
                h.editor.transact("Delete") { $0.delete([owner]) }
            }
            expectEqual(h.file.shapeCount, file.root.shapes.count - 1, "the subboard, and every board under it")
            expectEqual(h.file.children.count, 0)
            let times = undoAndRedo(h.editor, runs: 5, frame: frame)
            h.editor.undo()
            expectEqual(h.file, registry.fillingDefaults(file), "every board back, every id")
            report(String(format: "%6d shapes under a subboard: deleting it %5.2f ms (budget %.0f); undone %5.1f and redone %5.1f ms, with a frame (budget %.0f)",
                          under, delete, Budget.subboardDeletion, times.undo, times.redo, Budget.undoEveryShape))
            if holdsToBudgets {
                expect(delete < Budget.subboardDeletion, "deleting a subboard holding \(under) shapes took \(delete) ms")
                expect(times.undo < Budget.undoEveryShape && times.redo < Budget.undoEveryShape,
                       "undoing and redoing the deletion of a subboard holding \(under) shapes took \(times) ms")
            }
        }
    },
    test("a chain of 1,000 boards, each inside the one before, is written, read and walked without trouble") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let codec = BoardCodec(registry: registry)
        let levels = 1_000
        // Each board a note and the subboard of the next; the deepest, a note.
        let cards = (0..<levels).map { _ in ShapeRecord(Subboard(frame: CGRect(x: 0, y: 0, width: 240, height: 160))) }
        let note = { AnyShapeRecord(ShapeRecord(StickyNote(frame: CGRect(x: 300, y: 0, width: 200, height: 200), text: "Here"))) }
        var boards: [ShapeID: CanvasDocument] = [:]
        for (i, card) in cards.enumerated() {
            boards[card.id] = CanvasDocument(shapes: [note()] + (i + 1 < levels ? [AnyShapeRecord(cards[i + 1])] : []))
        }
        let file = CanvasFile(root: CanvasDocument(shapes: [note(), AnyShapeRecord(cards[0])]), children: boards)
        let deepest = BoardID(owner: try require(cards.last).id)
        let clock = ContinuousClock()
        var data = Data()
        let save = try clock.measure { data = try codec.encode(file) }.milliseconds
        var read: CanvasFile?
        let open = try clock.measure { read = try codec.decode(data).file }.milliseconds
        expectEqual(read, registry.fillingDefaults(file), "read back as written")
        var path: [BoardID]?
        let walk = clock.measure { path = file.path(to: deepest) }.milliseconds
        expectEqual(path?.count, levels + 1, "the root, then every board down")
        expectEqual(file.subtree(ownedBy: [cards[0].id]).count, levels)
        var editor: CanvasEditor?
        let show = clock.measure { editor = CanvasEditor(registry: registry, file: file, showing: deepest, scheduler: ManualScheduler()) }.milliseconds
        expectEqual(editor?.board, deepest)
        expectEqual(editor?.boardPath.count, levels + 1)
        editor?.goToEnclosingBoard()
        expectEqual(editor?.boardPath.count, levels, "⌘↑ goes up one")
        report(String(format: "a chain of %d boards, %.1f MB: save %.1f ms, open %.1f ms, the path to the deepest %.3f ms, an editor showing it %.1f ms (reported)",
                      levels, Double(data.count) / 1e6, save, open, walk, show))
    },
    test("the root crumb's menu inside a subboard: the root's rows, the first time, after a commit on the board shown, and again") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        for size in sizes {
            let file = generatedFile(root: size, children: [size])
            let child = BoardID(owner: try require(owners(in: file).first))
            var h = EditorHarness { CanvasEditor(registry: registry, file: file, scheduler: $0) }
            var rows: [ContentsEntry] = []
            // What the root's crumb's menu lists: the root's rows.
            let menu = { rows = try require(h.editor.tableOfContents).outline(of: .root) }
            // Cold: a new editor each run, inside the subboard, its own rows listed.
            let first = try median(runs: 3, prepare: {
                h = EditorHarness { CanvasEditor(registry: registry, file: file, showing: child, scheduler: $0) }
                _ = h.editor.tableOfContents?.entries
            }, menu)
            expectEqual(rowCount(rows), size + 1, "every shape of the root, the subboard's too")
            // A note on the board shown moved (a drag's event), which names nothing anew; renamed,
            // which may rename what a note up there mentions: every note's row up there is made again.
            let note = try require(h.editor.document.shapes.first { $0.kind == StickyNote.kind }).id
            var step = 0
            let afterMove = try median(runs: 21, prepare: {
                step += 1
                h.editor.transact("Move") { $0.translate([note], by: CGPoint(x: step % 2 == 0 ? 1 : -1, y: 0)) }
            }, menu)
            let afterRename = try median(runs: 21, prepare: {
                step += 1
                h.editor.transact("Rename") { $0.update(note) { $0[TitleProperty.self] = "Renamed \(step)" } }
            }, menu)
            let again = try median(runs: 21, menu)
            report(String(format: "%6d shapes on the root, inside its subboard: a crumb's menu, the root's rows, first %6.1f ms (reported); after a move on the board shown %6.3f (budget %.0f), a rename %6.2f (budget %.0f); again %6.3f",
                          size, first, afterMove, Budget.contentsRows, afterRename, Budget.frame, again))
            if holdsToBudgets {
                expect(afterMove < Budget.contentsRows, "the rows of a crumb's menu over \(size) shapes after a move took \(afterMove) ms")
                expect(afterRename < Budget.frame, "the rows of a crumb's menu over \(size) shapes after a rename took \(afterRename) ms")
            }
        }
    },
])
