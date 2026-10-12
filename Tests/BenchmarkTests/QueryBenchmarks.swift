import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import Connections
import Foundation
import Frames
import Geometry
import LanguageModels
import Mentions
import Queries
import QueryCommands
import QueryLanguage
import QueryTranslation
import Selection
import ShippedTesting
import StickyNotes
import TestKit
import Titles
import Topology
import Types
import Validation

// Queries' budgets, on the generated boards and files: what a query costs the main actor (reading,
// resolving and taking up the file; the vocabulary's first making), what it costs off it (a scan of
// every note's text, a name, an anchor's edges, traversals, pathological queries, ten thousand rows
// and their JSON), its slices (names derived, validity on boards not shown, and the longest of
// all), what a commit costs more while a query holds the file, what the shipped
// list with queries costs a drag event, a frame's lateness while a query's slices run, and `--ask`'s
// request without the model. Main-actor budgets are the test thread's CPU (the engine's own readings,
// `QueryResult.timings.main`, or `threadCPUTime`, or, for a command's many main-actor jobs, `cpu`);
// off-main ones the evaluation's (`timings.offMain`), or, for what the timings don't cover (the
// answer's JSON, `--ask`'s assembly), every other thread's CPU while it runs (`cpu`); a frame's
// lateness alone is the wall clock's, timed as `Budget.frame` is. `./build.sh bench` holds them;
// `./test.sh` runs them small, in debug, and only reports.

/// A budget at 1,000 shapes and at 10,000, in milliseconds: a board of more than 1,000 is held to
/// the second.
struct SizedBudget {
    let thousand: Double
    let tenThousand: Double

    func at(_ size: Int) -> Double { size > 1_000 ? tenThousand : thousand }
}

extension Budget {
    /// A query's main-actor time (`timings.main`): reading and resolving
    /// `sticky-note[text*="note" i]:not(:inside(*))` and the one turn that takes up the file, the
    /// vocabulary made already. Also after a drag event that moved every shape, which leaves a
    /// query nothing to bring up to date; and what the whole `canvas query` command costs the main
    /// actor beyond its query's own, however many rows it answers (`queryRowsMain`).
    static let queryMain = SizedBudget(thousand: 0.2, tenThousand: 0.5)
    /// Making the vocabulary, on the first query of an editor.
    static let queryVocabulary = 1.0
    /// A main slice: 2 ms of the thread's CPU (`QueryBudget.slice`), and the one record that crosses
    /// it.
    static let querySlice = 3.0
    /// That query off the main actor, first after the file opens, 100 rows: every shape walked,
    /// every note's attributes written as JSON and its text read with live names. Also after a drag
    /// event that moved every shape.
    static let queryScan = SizedBudget(thousand: 5, tenThousand: 40)
    /// A note found by its name (`"Title 5004"`) off the main actor: every name read, named ones
    /// there.
    static let queryTitleOffMain = SizedBudget(thousand: 1, tenThousand: 5)
    /// And on it: every derived name asked, in slices, on a board drawn and validated once, as one the
    /// person has looked at is. No shipped kind's names are derived now (a type's is its note's
    /// title), so this holds the main actor's part with none to ask.
    static let queryTitleMain = SizedBudget(thousand: 0.5, tenThousand: 4)
    /// Notes with an edge to a subboard 100 of them mention (`:edge-to(#…)`), off the main actor: the
    /// anchor's edges, never every shape, and the rows in file order, named, brief.
    static let queryByID = 0.5
    /// And their rows as a query lists them unless asked otherwise, with their attributes: each
    /// note's text read with live names (Mentions' text format, in one pass over the stored text)
    /// and its attributes written as JSON. (The design held these rows to `queryByID`, which 100 of
    /// them, some 0.55 ms, just miss.)
    static let queryByIDRows = 2.0
    /// A traversal off the main actor: `:downstream-of` along a chain through every shape, and
    /// `:component-of(*)` over one component of them all.
    static let queryGraph = SizedBudget(thousand: 3, tenThousand: 30)
    /// Queries that touch everything several times over, off the main actor: every construct that
    /// walks, and a nest of `:not(:is(…))` as deep as the language allows.
    static let queryPathological = SizedBudget(thousand: 25, tenThousand: 250)
    /// `:invalid` over a file whose boards not shown hold that many shapes: the main actor's time in
    /// all, in slices (each within `querySlice`). Validation's own first read of 10,000 shapes is
    /// `validation10k`.
    static let queryInvalidHidden = SizedBudget(thousand: 15, tenThousand: 150)
    /// `* --limit 10000` off the main actor: the rows and the answer's JSON, the result let go of
    /// there.
    static let queryRows = SizedBudget(thousand: 15, tenThousand: 150)
    /// And the whole command's main time: its query's (`queryMain`), and its rows' derived names,
    /// which only the main actor can say, asked in slices as a name's are (`queryTitleMain`; no shipped
    /// kind's are derived now). What's beyond the query's own main time, making and letting
    /// go of the answer, is held to `queryMain` alone. (The design held the whole command to
    /// `queryMain`, which rows of derived kinds can't meet.)
    static let queryRowsMain = SizedBudget(thousand: queryMain.thousand + queryTitleMain.thousand,
                                           tenThousand: queryMain.tenThousand + queryTitleMain.tenThousand)
    /// What a commit adding a shape costs more while a query holds the file it took up: the tables
    /// it shares, each copied once.
    static let queryHeldCommit = SizedBudget(thousand: 0.1, tenThousand: 0.5)
    /// What a drag event's input costs more with the shipped list, a query run first, than without
    /// queries: nothing, since queries hear no commit.
    static let queryUpkeep = 0.01
    /// A drag's frame at 60 Hz (a drag event and a draw) while a query's slices run, from its timer's
    /// fire date to its draw's end, on the wall clock (`FrameDriver`): the worst.
    static let queryFrame = frame
    /// A batch of 20 queries by title and by kind, ids only (`matches`, what a plugin that keeps
    /// answers asks), on a board whose types are titled notes: the main actor's time in all, reading
    /// and resolving the 20, taking up the file once and the slices that would read every derived
    /// name once for the whole batch, never once a query. As `queryTitleMain`.
    static let referenceBatchMain = queryTitleMain
    /// A path into a list (`[fieldValues.lineItems.product="Mug1"]`) and a date compared (`[fieldValues.due<"2026-05-01"]`), over
    /// notes holding `fieldValues` (a tenth of the file's shapes, five line items each), off the main actor: each shape's value
    /// walked at the members, a list's items too, and 100 rows written. Some 16 ms at 10,000 (15.4, 15.8 and 16.8 for the list, 17.0, 17.7 and 18.7
    /// for the date, load average 4 to 14; 1.5 to 1.9 at 1,000): held at the scan's budget (`queryScan`), the design's.
    static let queryPathList = queryScan
    static let queryPathDate = queryScan
    /// `:incomplete` over a file with 100 notes of a type that needs a name, none given, 100 rows listed: the command's main time
    /// (`timings.main`, the verdict of each typed note in slices, and each row's `problems` in slices) over the verdicts alone:
    /// the rows' problems are a check each. Some 0.6 ms at both sizes (0.61, 0.59 and 0.64 at 10,000, 0.56, 0.60 and 0.62 at 1,000, against 0.26 for the count
    /// alone; load average 10 to 18): held at the design's `queryRowsMain` and a millisecond.
    static let queryProblemsMain = SizedBudget(thousand: queryRowsMain.thousand + 1, tenThousand: queryRowsMain.tenThousand + 1)
    /// And off it: 20 queries' evaluation over the one snapshot, names read once.
    static let referenceBatchOffMain = SizedBudget(thousand: 20, tenThousand: 100)
    /// `--ask`'s request without the model, on a board looked at: on the main actor (at least
    /// `queryTitleMain`, since its titles ask every derived name), with the fields of the file's types as well: 40 types of 20
    /// fields, their lines (some 5 ms at 1,000 shapes and 20 at 10,000, made once, when a type has changed) ranked and joined
    /// to 8,000 characters (0.2 ms at 1,000 shapes, 1.3 at 10,000; the whole 0.25 and 1.0)...
    static let askAssemblyMain = SizedBudget(thousand: 1, tenThousand: 5)
    /// ...and off it.
    static let askAssemblyOffMain = SizedBudget(thousand: 3, tenThousand: 10)
}

/// The longest main slice and the costliest record any query here has made, and which: what
/// `querySlice` holds each test to, reported at the end.
@MainActor final class SlicesSeen {
    var longest: (ms: Double, query: String) = (0, "none")
    var costliest: (ms: Double, query: String) = (0, "none")

    func note(_ result: QueryResult, _ what: String) {
        let longestSlice = result.timings.longestSlice.milliseconds, costliestRecord = result.timings.costliestRecord.milliseconds
        if longestSlice > longest.ms { longest = (longestSlice, what) }
        if costliestRecord > costliest.ms { costliest = (costliestRecord, what) }
    }
}

@MainActor let slicesSeen = SlicesSeen()

/// A query's answer on `editor`, the run loop turned until it comes; its slices noted, unless
/// something else ran in them (`noting`).
@MainActor func queried(_ text: String, on editor: CanvasEditor, limit: Int = QueryBudget.rows, countOnly: Bool = false,
                        properties: QueryRequest.Properties = .all, noting: Bool = true,
                        file: StaticString = #fileID, line: UInt = #line) throws -> QueryResult {
    let queries = try require(editor.queries, file: file, line: line)
    let result = try awaitResult(timeout: 60, file: file, line: line) {
        try await queries.run(QueryRequest(text, limit: limit, countOnly: countOnly, properties: properties))
    }
    if noting { slicesSeen.note(result, text.count > 60 ? String(text.prefix(57)) + "…" : text) }
    return result
}

/// The median of some values.
func middle(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

/// Runs `body` on the main actor to its end, turning the main run loop only when something is to
/// run there, and returns what it returns, with the CPU this (the main) thread spent meanwhile and
/// every other thread of the process: a command's main time, and what it ran off the main actor
/// (nothing else runs in a benchmark's process). Unlike `awaitResult`, it never wakes the run loop
/// to look, so the main thread's time is the jobs' and the run loop's own between them.
@MainActor func cpu<T>(_ body: @escaping @MainActor () async throws -> T) throws -> (value: T, main: Double, offMain: Double) {
    let outcome = Answered<T>()
    let processStart = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID), mainStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    let task = Task { @MainActor in
        do { outcome.result = .success(try await body()) } catch { outcome.result = .failure(error) }
    }
    let deadline = Date(timeIntervalSinceNow: 60)
    while outcome.result == nil, Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 1))
    }
    let mainEnd = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID), processEnd = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
    if outcome.result == nil { task.cancel() }
    let value = try require(outcome.result, "it took more than 60 s").get()
    let main = Double(mainEnd - mainStart) / 1e6
    return (value, main, Double(processEnd - processStart) / 1e6 - main)
}

@MainActor private final class Answered<T> {
    var result: Result<T, any Error>?
}

/// The shipped list on a pasteboard of its own (never the person's), and the model tests use.
@MainActor func shippedPlugins(_ pasteboard: NSPasteboard) -> [any CanvasPlugin] {
    ShippedPlugins.plugins(pasteboard: pasteboard, model: ScriptedLanguageModel())
}

/// An arrow from one shape to another, bound at both ends at their centers: one edge between them.
func arrow(from start: ShapeID, to end: ShapeID) -> AnyShapeRecord {
    let bound = { (id: ShapeID) in ArrowTerminal.bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)) }
    return AnyShapeRecord(ShapeRecord(Arrow(start: bound(start), end: bound(end))))
}

/// A generated board's notes, subboards and cards (not its arrows), each joined to the
/// next in the board's order by an arrow bound at both ends: a chain through every note, and every
/// other shape an arrow can end on, one component of them all, `count` shapes with the arrows.
@MainActor func chainedBoard(shapes count: Int) -> CanvasDocument {
    let nodes = Array(generatedBoard(shapes: count).shapes.filter { $0.kind != Arrow.kind }.prefix((count + 1) / 2))
    return CanvasDocument(shapes: nodes + zip(nodes, nodes.dropFirst()).map { arrow(from: $0.id, to: $1.id) })
}


/// A generated board (`generatedBoard`) whose box shapes are all held: each 20 of them, in the
/// board's order, by a corral (CanvasTesting's container, standing in for frames) just below them,
/// and each 5 of those corrals by one more, below them all. Its arrows stay on the board directly.
@MainActor func corralledBoard(shapes count: Int) -> CanvasDocument {
    var shapes: [AnyShapeRecord] = [], outer: ShapeID?, inner: ShapeID?, held = 0, inners = 0
    for record in generatedBoard(shapes: count).shapes {
        guard record.box != nil else {
            shapes.append(record)
            continue
        }
        if held % 20 == 0 {
            if inners % 5 == 0 {
                let id = ShapeID()
                shapes.append(AnyShapeRecord(ShapeRecord(id: id, Corral(.zero))))
                outer = id
            }
            let id = ShapeID()
            shapes.append(AnyShapeRecord(ShapeRecord(id: id, Corral(.zero))).copy(as: id, container: outer))
            inner = id
            inners += 1
        }
        shapes.append(record.copy(as: record.id, container: inner))
        held += 1
    }
    return CanvasDocument(shapes: shapes)
}

/// The title of a note on a generated board of `size` shapes, near its middle: "Title 504" of 1,000,
/// "Title 5004" of 10,000.
func middleTitle(_ size: Int) -> String { "Title \(size / 2 + 4)" }

/// Drag frames at 60 Hz on a harness's board (a drag under way), each a drag event and a draw,
/// asked for by a timer on the main queue, which the main run loop serves between its other jobs
/// (a query's slices), turned as the app's is, and timed on the wall clock from the timer's fire
/// date to the draw's end; and, meanwhile, a query run again and again, if one is given.
///
/// The timer is dispatch's, strict, with no leeway: a run loop's `Timer` in this process (no app,
/// no window) fires up to 7 ms after its date with nothing else running, the system's coalescing,
/// which the worst of 30 frames showed as 17.7 ms without any query, and would hide what slices do.
/// Strict, a frame starts 0.1 ms late with nothing else to run, and at most a slice late while a
/// query's slices run. A frame the main thread was too busy to begin before the next fire is one
/// frame, drawn once, and timed from the first fire it answers: a frame dropped is as late as that.
@MainActor final class FrameDriver {
    let h: EditorHarness
    let context: CGContext
    let viewport: CGSize
    let center: CGPoint
    private var step = 0
    /// Each frame's milliseconds from its timer's fire date to its draw's end, and how late it began.
    private(set) var times: [Double] = []
    private(set) var late: [Double] = []
    /// The queries that ran meanwhile, and their slices.
    private(set) var queries = 0
    private(set) var slices = 0
    private var stop = false
    /// How many times the timer has fired, and how many of those fires found the main thread too
    /// busy to begin their frame before the next.
    private var fires = 0
    private(set) var dropped = 0

    /// 60 Hz, in nanoseconds.
    static let interval: UInt64 = 1_000_000_000 / 60

    init(_ h: EditorHarness, context: CGContext, viewport: CGSize, from center: CGPoint) {
        self.h = h
        self.context = context
        self.viewport = viewport
        self.center = center
    }

    /// At least `count` frames and, while `query` runs, at least `runs` of it, one after another.
    func run(_ count: Int, while query: String? = nil, runs: Int = 0) throws {
        let queries = try require(h.editor.queries)
        let interval = Self.interval
        let first = DispatchTime.now().uptimeNanoseconds + interval
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.setEventHandler { [self, timer] in
            let missed = Int(timer.data)
            MainActor.assumeIsolated {
                // The first fire this is for: timed from the latest, a main thread busy for more than
                // a frame would show as a frame on time.
                let fired = first + UInt64(fires) * interval
                fires += missed
                dropped += missed - 1
                frame(firedAt: fired)
            }
        }
        timer.schedule(deadline: DispatchTime(uptimeNanoseconds: first), repeating: .nanoseconds(Int(interval)), leeway: .nanoseconds(0))
        let running = Task { @MainActor in
            guard let query else { return }
            while !stop {
                let result = try await queries.run(QueryRequest(query, countOnly: true))
                self.queries += 1
                slices += result.timings.slices
                slicesSeen.note(result, "\(query), frames drawn meanwhile")
            }
        }
        timer.activate()
        let started = Date()
        while times.count < count || (query != nil && self.queries < runs), Date().timeIntervalSince(started) < 60 {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        timer.cancel()
        stop = true
        try awaitResult(timeout: 60) { try await running.value }
    }

    /// A frame for the fire at `fired` (uptime nanoseconds).
    private func frame(firedAt fired: UInt64) {
        let began = DispatchTime.now().uptimeNanoseconds
        step += 1
        h.drag(to: center + CGPoint(x: CGFloat(step), y: CGFloat(step) / 2))
        draw(h.editor, into: context, size: viewport)
        let ended = DispatchTime.now().uptimeNanoseconds
        times.append(Double(Int64(ended) - Int64(fired)) / 1e6)
        late.append(Double(Int64(began) - Int64(fired)) / 1e6)
    }
}

/// A word only the main actor answers, which runs `during` (once) as it's asked: a commit landing
/// while the query holds the file it took up.
@MainActor final class HeldCommit {
    var during: (() -> Void)?
}

func heldCommitPlugin(_ held: HeldCommit) -> Contributor {
    Contributor(id: "bench-held-commit") { registrar in
        registrar.queryPseudoClass("held-commit", "a commit lands while the query holds the file", example: ":held-commit",
                                   prepare: { _ in () }, matches: { _, _ in .onMain },
                                   onMain: { _, _, _, _ in
                                       held.during?()
                                       held.during = nil
                                       return true
                                   })
    }
}

@MainActor let queryBenchmarks = Suite("Query benchmarks", [
    test("the vocabulary is made in a millisecond, on an editor's first query") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let registry = try Registry(plugins: shippedPlugins(pasteboard))
        var vocabulary: QueryVocabulary?
        let times = (0..<21).map { _ in threadCPUTime { vocabulary = QueryVocabulary(registry: registry) }.milliseconds }
        let made = middle(times)
        expect(vocabulary?.kinds.contains { $0.kind == StickyNote.kind } == true, "notes are in it")
        report(String(format: "the query vocabulary, %d kinds, %d edge types, %d words, %d characters: made in %6.3f ms (budget %.0f)",
                      vocabulary?.kinds.count ?? 0, vocabulary?.edgeTypes.count ?? 0, vocabulary?.words.count ?? 0,
                      vocabulary?.text.count ?? 0, made, Budget.queryVocabulary))
        if holdsToBudgets { expect(made < Budget.queryVocabulary, "making the vocabulary took \(made) ms") }
    },
    test("a query costs the main actor its reading and one turn, and every note's text is read off it: first after opening, and after a drag event that moved every shape") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let registry = try Registry(plugins: shippedPlugins(pasteboard))
        let text = #"\#(StickyNote.kind.rawValue)[text*="note" i]:not(:inside(*))"#
        for size in sizes {
            let document = generatedBoard(shapes: size)
            let notes = document.shapes.count { $0.kind == StickyNote.kind }
            // First after opening: an editor each run, its vocabulary made first.
            var mains: [Double] = [], offs: [Double] = [], result: QueryResult?
            for _ in 0..<7 {
                let editor = CanvasEditor(registry: registry, document: document, scheduler: ManualScheduler())
                _ = try require(editor.queries).vocabulary
                let answered = try queried(text, on: editor)
                mains.append(answered.timings.main.milliseconds)
                offs.append(answered.timings.offMain.milliseconds)
                result = answered
            }
            expectEqual(result?.count, notes, "every note says “Note”, and none is inside anything")
            expectEqual(result?.rows.count, min(notes, QueryBudget.rows))
            expect(result?.rows.first?.properties?["text"]?.stringValue?.hasPrefix("Note ") == true, "the text read as it reads")
            // ⌘A, and a drag from a note, as a user moves the whole board: each run a drag event, then
            // the query.
            let h = EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }
            let queries = try require(h.editor.queries)
            _ = queries.vocabulary
            h.hold(.command)
            h.key("a")
            h.hold([])
            let note = try require(document.shapes.first { $0.kind == StickyNote.kind })
            let center = CGPoint(x: try require(note.box).midX, y: try require(note.box).midY)
            // Once ⌘, let go, no longer counts as held: a press with it would brush.
            h.press(at: center, after: 200)
            var dragMains: [Double] = [], dragOffs: [Double] = [], nudge = 0.0
            for _ in 0..<11 {
                nudge += 1
                h.drag(to: center + CGPoint(x: nudge, y: 0))
                let answered = try queried(text, on: h.editor)
                dragMains.append(answered.timings.main.milliseconds)
                dragOffs.append(answered.timings.offMain.milliseconds)
                result = answered
            }
            expectEqual(h.editor.document[note.id]?.box?.origin.x, (note.box?.origin.x ?? 0) + nudge, "the drag moves what ⌘A selected")
            h.release()
            expectEqual(result?.count, notes)
            #if DEBUG
            expectEqual(queries.liveSnapshots, 0, "no query holds the file once it's answered")
            #endif
            let main = middle(mains), off = middle(offs), dragMain = middle(dragMains), dragOff = middle(dragOffs)
            report(String(format: "%6d shapes, a query of every note's text (%d match): main %6.3f ms (budget %.1f), off it %6.2f (budget %.0f); after a drag event that moved every shape %6.3f and %6.2f",
                          size, notes, main, Budget.queryMain.at(size), off, Budget.queryScan.at(size), dragMain, dragOff))
            if holdsToBudgets {
                expect(main < Budget.queryMain.at(size), "a query's main time on \(size) shapes was \(main) ms")
                expect(off < Budget.queryScan.at(size), "a scan of every note's text on \(size) shapes took \(off) ms off the main actor")
                expect(dragMain < Budget.queryMain.at(size), "a query's main time after a drag of \(size) shapes was \(dragMain) ms")
                expect(dragOff < Budget.queryScan.at(size), "a scan after a drag of \(size) shapes took \(dragOff) ms off the main actor")
            }
        }
    },
    test("a note found by its name reads every name, derived ones (none shipped) in slices: on a board looked at, and on one never shown") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let registry = try Registry(plugins: shippedPlugins(pasteboard))
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        for size in sizes {
            let document = generatedBoard(shapes: size)
            let title = middleTitle(size), text = "\"\(title)\""
            let types = document.shapes.count { $0[TypeSchemaProperty.self] != nil }
            // Warm: the board shown, drawn and validated once, as a board the person has looked at is.
            let h = EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }
            h.editor.viewportDidResize(to: viewport)
            draw(h.editor, into: context, size: viewport)
            _ = try require(h.editor.validation).results
            var mains: [Double] = [], offs: [Double] = [], slices: [Int] = [], longest = 0.0, result: QueryResult?
            for _ in 0..<11 {
                let answered = try queried(text, on: h.editor)
                mains.append(answered.timings.main.milliseconds)
                offs.append(answered.timings.offMain.milliseconds)
                slices.append(answered.timings.slices)
                longest = max(longest, answered.timings.longestSlice.milliseconds)
                result = answered
            }
            expectEqual(result?.count, 1, "one note is titled \(title)")
            expectEqual(result?.rows.first?.title, title)
            #if DEBUG
            let asked = try require(h.editor.queries).derivedTitlesAsked
            expectEqual(asked, 0, "no shipped kind's names are derived: a type's is its note's title")
            #endif
            // On a board never shown, of a file generated afresh each run (new ids): as it opens, the
            // types' sync reads every type of the file, as it reads each as it changes, so a query
            // reads no schema (a type's is unread only once its reading is evicted, past the 4,096 kept).
            var openedMains: [Double] = []
            for _ in 0..<5 {
                let file = generatedFile(root: 0, children: [size])
                let editor = CanvasEditor(registry: registry, file: file, scheduler: ManualScheduler())
                _ = try require(editor.queries).vocabulary
                #if DEBUG
                let read = TypesPlugin.schemasRead
                #endif
                let opened = try queried(text, on: editor)
                #if DEBUG
                expectEqual(TypesPlugin.schemasRead - read, 0, "every type read as the file opened")
                #endif
                expectEqual(opened.count, 1)
                expectEqual(opened.rows.first?.inside.count, 1, "the note is inside the subboard")
                openedMains.append(opened.timings.main.milliseconds)
            }
            let main = middle(mains), off = middle(offs), opened = middle(openedMains)
            report(String(format: "%6d shapes, a note by its name, %d of them types: off the main actor %6.3f ms (budget %.1f), main %6.3f in %d slices (budget %.1f); on a board never shown, main %6.3f as the file opens; the longest slice %5.3f (budget %.0f)",
                          size, types, off, Budget.queryTitleOffMain.at(size), main, Int(middle(slices.map(Double.init))),
                          Budget.queryTitleMain.at(size), opened, longest, Budget.querySlice))
            if holdsToBudgets {
                expect(off < Budget.queryTitleOffMain.at(size), "a name on \(size) shapes took \(off) ms off the main actor")
                expect(main < Budget.queryTitleMain.at(size), "a name on \(size) shapes took \(main) ms on the main actor")
                expect(longest < Budget.querySlice, "a slice asking names on \(size) shapes took \(longest) ms")
            }
        }
    },
    test("notes with an edge to a shape start from its edges: they cost its degree, not the board") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let registry = try Registry(plugins: shippedPlugins(pasteboard))
        for size in sizes {
            let document = generatedBoard(shapes: size)
            let editor = CanvasEditor(registry: registry, document: document, scheduler: ManualScheduler())
            let queries = try require(editor.queries)
            let subboard = try require(mentionedSubboard(in: document))
            let text = "\(StickyNote.kind.rawValue):edge-to(#\(subboard))"
            let mentioners = try require(editor.mentions).mentioners(of: subboard).count
            _ = try queried(text, on: editor)
            #if DEBUG
            let walks = queries.universeWalks, seeded = queries.seededFromAnchors
            #endif
            // Brief rows (id, kind, name, board), then every row's attributes too, each note's text
            // read with live names by Mentions' text format.
            var result: QueryResult?
            @MainActor func offMain(_ listing: QueryRequest.Properties) throws -> Double {
                middle(try (0..<21).map { _ in
                    let answered = try queried(text, on: editor, properties: listing)
                    result = answered
                    return answered.timings.offMain.milliseconds
                })
            }
            let brief = try offMain(.none), whole = try offMain(.all)
            expectEqual(result?.count, mentioners, "the notes that mention it")
            expect(result?.rows.first?.properties?["text"]?.stringValue?.contains("@") == true, "their text, its mentions read")
            #if DEBUG
            expectEqual(queries.universeWalks, walks, "no walk of every shape")
            expectEqual(queries.seededFromAnchors, seeded + 42, "each started from the subboard's edges")
            #endif
            report(String(format: "%6d shapes, the notes with an edge to a subboard %d mention, from its edges, off the main actor: %6.3f ms (budget %.1f), with their attributes, text read, %6.3f (budget %.1f)",
                          size, mentioners, brief, Budget.queryByID, whole, Budget.queryByIDRows))
            if holdsToBudgets {
                expectEqual(mentioners, 100)
                expect(brief < Budget.queryByID, "the notes with an edge to a shape of degree \(mentioners), of \(size) shapes, took \(brief) ms")
                expect(whole < Budget.queryByIDRows, "the notes with an edge to a shape of degree \(mentioners), of \(size) shapes, with their attributes took \(whole) ms")
            }
        }
    },
    test("traversals cost what they reach: downstream along a chain through every shape, and one component of them all") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let registry = try Registry(plugins: shippedPlugins(pasteboard))
        for size in sizes {
            let document = chainedBoard(shapes: size)
            let nodes = document.shapes.count { $0.kind != Arrow.kind }
            let editor = CanvasEditor(registry: registry, document: document, scheduler: ManualScheduler())
            let first = try require(document.shapes.first)
            var times: [String: Double] = [:]
            for (what, text, expected) in [("downstream", ":downstream-of(#\(first.id))", nodes - 1), ("component", ":component-of(*)", nodes)] {
                var offs: [Double] = [], result: QueryResult?
                for _ in 0..<7 {
                    let answered = try queried(text, on: editor)
                    offs.append(answered.timings.offMain.milliseconds)
                    result = answered
                }
                // Downstream of the first, every shape after it, and the first too once a note mentions it.
                expect((expected...expected + 1).contains(result?.count ?? 0), "\(what): \(result?.count ?? 0) of \(nodes)")
                times[what] = middle(offs)
            }
            let downstream = times["downstream"] ?? .nan, component = times["component"] ?? .nan
            report(String(format: "%6d shapes, %d joined in a chain: downstream of the first %6.2f ms, the component of any %6.2f ms, off the main actor (budget %.0f)",
                          document.shapes.count, nodes, downstream, component, Budget.queryGraph.at(size)))
            if holdsToBudgets {
                expect(downstream < Budget.queryGraph.at(size), "downstream of the first of \(nodes) chained shapes took \(downstream) ms")
                expect(component < Budget.queryGraph.at(size), "the component of any of \(nodes) chained shapes took \(component) ms")
            }
        }
    },
    test("pathological queries, every construct that walks and the deepest nest, stay within their bound, on a board and on nested boards") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let registry = try Registry(plugins: shippedPlugins(pasteboard))
        let walks = ":is(:has(*), :inside(*)):not(:downstream-of(*)):not(:upstream-of(*)), :component-of(*)"
        // `:not(:is(` as deep as the language nests, around every note that says “note”.
        let pairs = QueryLimits.depth / 2
        let nest = String(repeating: ":not(:is(", count: pairs) + #"\#(StickyNote.kind.rawValue)[text*="note" i]"# + String(repeating: "))", count: pairs)
        for size in sizes {
            let tenth = size / 10
            let files = [("a board", CanvasFile(root: generatedBoard(shapes: size))),
                         ("ten boards deep", generatedFile(root: tenth, children: Array(repeating: tenth, count: 9), depth: 10))]
            var lines: [String] = []
            for (place, file) in files {
                let editor = CanvasEditor(registry: registry, file: file, scheduler: ManualScheduler())
                for (what, text) in [("walks", walks), ("the nest", nest)] {
                    var offs: [Double] = []
                    for _ in 0..<5 {
                        let answered = try queried(text, on: editor)
                        offs.append(answered.timings.offMain.milliseconds)
                        expect(answered.count > 0, "\(what) on \(place) matches")
                    }
                    let off = middle(offs)
                    lines.append(String(format: "%@ on %@ %6.1f", what, place, off))
                    if holdsToBudgets {
                        expect(off < Budget.queryPathological.at(size), "\(what) on \(place) of \(file.shapeCount) shapes took \(off) ms off the main actor")
                    }
                }
            }
            report(String(format: "%6d shapes, pathological queries off the main actor: %@ ms (budget %.0f)",
                          size, lines.joined(separator: ", "), Budget.queryPathological.at(size)))
        }
    },
    test(":invalid over a board not shown is asked in slices, each 2 ms and a record") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let registry = try Registry(plugins: shippedPlugins(pasteboard))
        for size in sizes {
            // The top board holds only the subboard, whose board holds them all: each shape's rules
            // run against the board as the app has it.
            let editor = CanvasEditor(registry: registry, file: generatedFile(root: 0, children: [size]), scheduler: ManualScheduler())
            _ = try require(editor.queries).vocabulary
            let first = try queried(":invalid", on: editor)
            var mains: [Double] = [], slices: [Int] = [], longest = first.timings.longestSlice.milliseconds
            for _ in 0..<5 {
                let answered = try queried(":invalid", on: editor)
                expectEqual(answered.count, 0, "the generated board has no issues")
                mains.append(answered.timings.main.milliseconds)
                slices.append(answered.timings.slices)
                longest = max(longest, answered.timings.longestSlice.milliseconds)
            }
            let main = middle(mains), cold = first.timings.main.milliseconds
            report(String(format: "%6d shapes on a board not shown, :invalid: main %6.2f ms in %d slices, the first time %6.2f in %d (budget %.0f); the longest slice %5.3f (budget %.0f)",
                          size, main, Int(middle(slices.map(Double.init))), cold, first.timings.slices, Budget.queryInvalidHidden.at(size),
                          longest, Budget.querySlice))
            if holdsToBudgets {
                expect(main < Budget.queryInvalidHidden.at(size), ":invalid over \(size) shapes not shown took \(main) ms on the main actor")
                expect(cold < Budget.queryInvalidHidden.at(size), ":invalid over \(size) shapes not shown took \(cold) ms on the main actor the first time")
                expect(longest < Budget.querySlice, "a slice of :invalid over \(size) shapes not shown took \(longest) ms")
            }
        }
    },
    test("a drag's frames, 60 a second, stay within a frame while :invalid's slices run between them, each starting at most a slice late") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let registry = try Registry(plugins: shippedPlugins(pasteboard))
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        for size in sizes {
            // The board shown holds as many shapes as the one below it, which :invalid asks about
            // again and again, in slices.
            let h = EditorHarness { CanvasEditor(registry: registry, file: generatedFile(root: size, children: [size]), scheduler: $0) }
            h.editor.viewportDidResize(to: viewport)
            _ = try require(h.editor.queries).vocabulary
            let note = try require(h.editor.document.shapes.first { $0.kind == StickyNote.kind })
            let center = CGPoint(x: try require(note.box).midX, y: try require(note.box).midY)
            draw(h.editor, into: context, size: viewport)
            // A drag under way: its first events (past the drag threshold, snapping's first read of
            // what's in view) aren't the frames timed.
            h.press(at: center)
            for step in 1...3 {
                h.drag(to: center + CGPoint(x: CGFloat(step) * 4, y: 0))
                draw(h.editor, into: context, size: viewport)
            }
            let alone = FrameDriver(h, context: context, viewport: viewport, from: center)
            try alone.run(30)
            let querying = FrameDriver(h, context: context, viewport: viewport, from: center)
            try querying.run(30, while: ":invalid", runs: 2)
            h.release()
            expect(querying.queries >= 2, "\(querying.queries) queries ran")
            let worst = querying.times.max() ?? .nan
            report(String(format: "%6d shapes on the board shown, as many below it: %d frames (%d dropped) while %d queries of :invalid ran in %d slices, the worst %5.1f ms from its timer's fire date (budget %.0f), the median %5.1f, the latest start %4.1f; without queries the worst %5.1f, the median %5.1f, the latest start %4.1f (%d dropped)",
                          size, querying.times.count, querying.dropped, querying.queries, querying.slices, worst, Budget.queryFrame,
                          middle(querying.times), querying.late.max() ?? .nan, alone.times.max() ?? .nan, middle(alone.times),
                          alone.late.max() ?? .nan, alone.dropped))
            if holdsToBudgets { expect(worst < Budget.queryFrame, "a frame over \(size) shapes while slices ran took \(worst) ms from its fire date") }
        }
    },
    test("a query's 10,000 rows and their JSON are made and let go of off the main actor: the command's main time is its query's") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let registry = try Registry(plugins: shippedPlugins(pasteboard))
        let commands = registry.hostCommands
        for size in sizes {
            let document = generatedBoard(shapes: size)
            let editor = CanvasEditor(registry: registry, document: document, scheduler: ManualScheduler())
            let queries = try require(editor.queries)
            _ = queries.vocabulary
            // The command, as `canvas` asks it.
            let params: JSON = ["query": .string("*"), "limit": .number(Double(QueryBudget.maxRows))]
            var mains: [Double] = [], offs: [Double] = [], answer: JSON = [:]
            for _ in 0..<5 {
                let run = try cpu { try await commands.run("query", params, editor) }
                mains.append(run.main)
                offs.append(run.offMain)
                answer = run.value
            }
            expectEqual(answer["count"]?.numberValue, Double(size))
            expectEqual(answer["rows"]?.arrayValue?.count, min(size, QueryBudget.maxRows))
            #if DEBUG
            expectEqual(QueryOutput.lastBuiltOnMainThread, false, "the answer's JSON is built off the main thread")
            #endif
            // What the command runs, its query's own timings kept: the main actor's time beyond what
            // the query spent there (reading, taking up the file, the rows' derived names in slices)
            // is what making and letting go of the answer cost it. And the command's main time beyond
            // that query's own, the medians': what the command adds around them (its params read and
            // checked, the answer handed on).
            var beyond: [Double] = [], own: [Double] = [], evaluations: [Double] = []
            for _ in 0..<5 {
                let run = try cpu { () async throws -> (JSON, QueryTimings) in
                    let result = try await queries.run(QueryRequest("*", limit: QueryBudget.maxRows))
                    let timings = result.timings
                    return (await QueryOutput.json(consume result, countOnly: false), timings)
                }
                beyond.append(run.main - run.value.1.main.milliseconds)
                own.append(run.value.1.main.milliseconds)
                evaluations.append(run.value.1.offMain.milliseconds)
            }
            let main = middle(mains), off = middle(offs), rest = middle(beyond), budget = Budget.queryRowsMain.at(size)
            let command = main - middle(own)
            report(String(format: "%6d shapes, `query '*' --limit 10000`: off the main actor %6.1f ms (budget %.0f), of which the evaluation and its rows %6.1f; the command's main time %6.3f (budget %.1f), of which beyond its query's own %6.3f (the query and its answer alone %6.3f; budget %.1f)",
                          size, off, Budget.queryRows.at(size), middle(evaluations), main, budget, command, rest, Budget.queryMain.at(size)))
            if holdsToBudgets {
                expect(off < Budget.queryRows.at(size), "\(size) rows and their JSON took \(off) ms off the main actor")
                expect(main < budget, "the command answering \(size) rows took \(main) ms on the main actor")
                expect(command < Budget.queryMain.at(size), "the command answering \(size) rows took \(command) ms on the main actor beyond its query's own")
                expect(rest < Budget.queryMain.at(size), "the query answering \(size) rows, and its answer, took \(rest) ms on the main actor beyond its own")
            }
        }
    },
    test("a commit while a query holds the file it took up costs little more: each table it shares copied once") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let held = HeldCommit()
        let registry = try Registry(plugins: shippedPlugins(pasteboard) + [heldCommitPlugin(held)])
        for size in sizes {
            let document = generatedBoard(shapes: size)
            let editor = CanvasEditor(registry: registry, document: document, scheduler: ManualScheduler())
            let queries = try require(editor.queries)
            _ = queries.vocabulary
            let anchor = try require(document.shapes.first { $0.kind == StickyNote.kind }?.id)
            let add = { editor.add(StickyNote(frame: CGRect(x: -1000, y: -1000, width: 200, height: 200), text: "Added")) }
            var plain: [Double] = [], during: [Double] = []
            for _ in 0..<21 {
                plain.append(threadCPUTime { _ = add() }.milliseconds)
                held.during = {
                    #if DEBUG
                    expectEqual(queries.liveSnapshots, 1, "the query holds the file")
                    #endif
                    during.append(threadCPUTime { _ = add() }.milliseconds)
                }
                _ = try queried("#\(anchor):held-commit", on: editor, countOnly: true, noting: false)
            }
            expectEqual(during.count, 21, "a commit landed during each query")
            expectEqual(editor.document.shapes.count, size + 42)
            let alone = middle(plain), whileHeld = middle(during)
            report(String(format: "%6d shapes, a commit adding a note: %6.3f ms, while a query holds the file %6.3f (budget: %.1f more)",
                          size, alone, whileHeld, Budget.queryHeldCommit.at(size)))
            if holdsToBudgets {
                expect(whileHeld - alone < Budget.queryHeldCommit.at(size),
                       "a commit on \(size) shapes while a query holds the file took \(whileHeld) ms, against \(alone)")
            }
        }
    },
    test("queries cost a drag event nothing: the shipped list, a query run first, against it without queries") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let shipped = try Registry(plugins: shippedPlugins(pasteboard))
        // Without Queries, and so without the plugins that give it words and the commands that build on it:
        // those between them in the shipped list.
        var plugins = shippedPlugins(pasteboard)
        let first = try require(plugins.firstIndex { $0.id == .queries }), last = try require(plugins.firstIndex { $0.id == .queryCommands })
        plugins.removeSubrange(first...last)
        let without = try Registry(plugins: plugins)
        expect(!without.answersQueries && shipped.answersQueries)
        for size in sizes {
            let document = generatedBoard(shapes: size)
            let note = try require(document.shapes.first { $0.kind == StickyNote.kind })
            let center = CGPoint(x: try require(note.box).midX, y: try require(note.box).midY)
            let with = EditorHarness { CanvasEditor(registry: shipped, document: document, scheduler: $0) }
            let alone = EditorHarness { CanvasEditor(registry: without, document: document, scheduler: $0) }
            _ = try queried("*", on: with.editor, countOnly: true)
            with.press(at: center)
            alone.press(at: center)
            // Each run one drag event on each, in turn, so neither has the machine to itself longer.
            var withTimes: [Double] = [], aloneTimes: [Double] = []
            for step in 1...201 {
                let to = center + CGPoint(x: CGFloat(step), y: CGFloat(step) / 2)
                withTimes.append(threadCPUTime { with.drag(to: to) }.milliseconds)
                aloneTimes.append(threadCPUTime { alone.drag(to: to) }.milliseconds)
            }
            with.release()
            alone.release()
            expectEqual(with.editor.document[note.id], alone.editor.document[note.id], "both dragged alike")
            let withQueries = middle(withTimes), withoutQueries = middle(aloneTimes)
            report(String(format: "%6d shapes, a drag event's input: %6.4f ms with queries, a query run first, %6.4f without (budget: %.2f more, and %.0f)",
                          size, withQueries, withoutQueries, Budget.queryUpkeep, Budget.dragInput))
            if holdsToBudgets {
                expect(withQueries - withoutQueries < Budget.queryUpkeep,
                       "a drag event on \(size) shapes took \(withQueries) ms with queries, \(withoutQueries) without")
                expect(withQueries < Budget.dragInput, "a drag event on \(size) shapes took \(withQueries) ms with queries")
            }
        }
    },
    test("--ask's request, without the model: where the person is, the titles and the fields of 40 types of 20, on a board looked at") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let registry = try Registry(plugins: shippedPlugins(pasteboard))
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        for size in sizes {
            // Forty of the notes are types of twenty fields each, whose lines `--ask` is told (`<fields>`).
            var shapes = generatedBoard(shapes: size).shapes
            var made = 0
            for index in shapes.indices where shapes[index].kind == StickyNote.kind && shapes[index][TypeSchemaProperty.self] == nil && made < 40 {
                let properties = (1...20).map { #""field\#($0)": {"type": "string"}"# }.joined(separator: ", ")
                shapes[index][TypeSchemaProperty.self] = SchemaText(#"{"type": "object", "properties": {\#(properties)}}"#)
                shapes[index][TitleProperty.self] = "Fields type \(made)"
                made += 1
            }
            let document = CanvasDocument(shapes: shapes)
            let h = EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }
            h.editor.viewportDidResize(to: viewport)
            draw(h.editor, into: context, size: viewport)
            _ = try require(h.editor.validation).results
            let queries = try require(h.editor.queries)
            _ = queries.vocabulary
            let cold = threadCPUTime { _ = h.editor.fileFields?.text(for: "") }.milliseconds
            h.editor.selectedShapeIDs = Array(document.shapes.prefix(3).map(\.id))
            // The product's prompt, read out of this executable once, as the shipped translator reads it.
            let system = try require(ShippedText.named(QueryTranslationPlugin.promptFile))
            // A question many names share a word with (the titles listed are those first), and one no
            // name shares a word with, which ranks every name there is.
            var lines: [String] = []
            for question in ["Which notes mention Plan 10, and what's in \(middleTitle(size))?", "Which notes mention the gateway?"] {
                var mains: [Double] = [], offs: [Double] = [], request: ModelRequest?, facts: [Double] = []
                for _ in 0..<11 {
                    facts.append(threadCPUTime { _ = h.editor.fileFields?.text(for: question) }.milliseconds)
                    let run = try cpu { () async throws -> ModelRequest in
                        let place = try await queries.whereThePersonIs(selectedLimit: AskStyle.selected)
                        let titles = try await queries.titles(for: question, limit: AskStyle.titles)
                        return AskRequest.request(question: question, vocabulary: queries.vocabulary.text, where: place, titles: titles,
                                                  system: system, style: .shipped,
                                                  facts: [(tag: "fields", text: h.editor.fileFields?.text(for: question) ?? "")])
                    }
                    mains.append(run.main)
                    offs.append(run.offMain)
                    request = run.value
                }
                let message = try require(request?.messages.first?.text)
                let listed = message.components(separatedBy: "<titles>\n").last?.components(separatedBy: "\n</titles>").first?.split(separator: "\n") ?? []
                expectEqual(listed.count, min(AskStyle.titles, document.shapes.count { registry.title(of: $0) != nil }), "as many titles as are asked")
                expect(message.contains("Selected: "), "what's selected")
                expect(message.contains("</titles>\n\n<fields>\nFields type "), "the types' fields, after the titles")
                let main = middle(mains), off = middle(offs)
                lines.append(String(format: "“%@” main %6.3f ms (the fields' %6.3f), off %6.3f", question, main, middle(facts), off))
                if holdsToBudgets {
                    expect(main < Budget.askAssemblyMain.at(size), "--ask's request for “\(question)” on \(size) shapes took \(main) ms on the main actor")
                    expect(off < Budget.askAssemblyOffMain.at(size), "--ask's request for “\(question)” on \(size) shapes took \(off) ms off the main actor")
                }
            }
            report(String(format: "%6d shapes, --ask's request without the model: %@ (budget %.0f main, %.0f off); the types' lines made first: %6.3f ms",
                          size, lines.joined(separator: "; "), Budget.askAssemblyMain.at(size), Budget.askAssemblyOffMain.at(size), cold))
        }
    },
    test("containers cost a query what they hold: a board whose shapes are all held two deep within the scan's, the walks' and the rows' budgets, and one without them what it did beside a kind that holds shapes") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        // The shipped list without frames, so with no kind that holds shapes, and as it ships.
        let bare = try Registry(plugins: shippedPlugins(pasteboard).filter { $0.id != .framing })
        let shipped = try Registry(plugins: shippedPlugins(pasteboard))
        let holding = try Registry(plugins: shippedPlugins(pasteboard) + [CorralsPlugin()])
        let scan = #"\#(StickyNote.kind.rawValue)[text*="note" i]:not(:inside(*))"#
        let through = #"\#(Corral.kind.rawValue) \#(StickyNote.kind.rawValue)[text*="note" i]"#
        let walks = ":is(:has(*), :inside(*)):not(:downstream-of(*)):not(:upstream-of(*)), :component-of(*)"
        for size in sizes {
            // No container on the board: the scan with no kind that holds shapes, and with frames
            // beside it, as the app ships, each first after the file opens, by turns.
            let document = generatedBoard(shapes: size)
            var without: [Double] = [], beside: [Double] = []
            for _ in 0..<7 {
                for registry in [bare, shipped] {
                    let editor = CanvasEditor(registry: registry, document: document, scheduler: ManualScheduler())
                    _ = try require(editor.queries).vocabulary
                    let off = try queried(scan, on: editor).timings.offMain.milliseconds
                    if registry.containingKinds.isEmpty { without.append(off) } else { beside.append(off) }
                }
            }
            // Every box shape held, two deep: every note's text read through the containers, the
            // walks, and every shape's row, its inside naming the corrals it's in.
            let held = corralledBoard(shapes: size)
            let editor = CanvasEditor(registry: holding, document: held, scheduler: ManualScheduler())
            _ = try require(editor.queries).vocabulary
            var scans: [Double] = [], paths: [Double] = [], rows: [Double] = []
            var notes = 0, listed: QueryResult?
            for _ in 0..<5 {
                let answered = try queried(through, on: editor)
                scans.append(answered.timings.offMain.milliseconds)
                notes = answered.count
                paths.append(try queried(walks, on: editor).timings.offMain.milliseconds)
                let all = try queried("*", on: editor, limit: QueryBudget.maxRows, properties: .none)
                rows.append(all.timings.offMain.milliseconds)
                listed = all
            }
            expectEqual(notes, held.shapes.count { $0.kind == StickyNote.kind }, "every note is held, and says “Note”")
            expectEqual(listed?.rows.first { $0.kind == StickyNote.kind }?.inside, [Corral.kind.rawValue, Corral.kind.rawValue],
                        "each untitled corral by its kind's label")
            let plain = middle(without), withKind = middle(beside), scanned = middle(scans), walked = middle(paths), made = middle(rows)
            report(String(format: "%6d shapes, no container: the scan off the main actor %6.2f ms, %6.2f beside a kind that holds shapes; all held two deep (%d corrals): every held note's text %6.2f (budget %.0f), the walks %6.2f (budget %.0f), %d rows %6.2f (budget %.0f)",
                          size, plain, withKind, held.shapes.count - document.shapes.count, scanned, Budget.queryScan.at(size), walked,
                          Budget.queryPathological.at(size), listed?.rows.count ?? 0, made, Budget.queryRows.at(size)))
            if holdsToBudgets {
                expect(withKind < max(plain * 1.25, plain + 0.5), "the scan on \(size) shapes took \(withKind) ms beside a kind that holds shapes, \(plain) without")
                expect(scanned < Budget.queryScan.at(size), "every held note's text on \(size) shapes took \(scanned) ms")
                expect(walked < Budget.queryPathological.at(size), "the walks on \(size) held shapes took \(walked) ms")
                expect(made < Budget.queryRows.at(size), "every row of \(size) held shapes took \(made) ms")
            }
        }
    },
    test("a batch of twenty queries, ids only, reads every name once: the main actor's slices for the batch, not for each query") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let registry = try Registry(plugins: shippedPlugins(pasteboard))
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        for size in sizes {
            let document = generatedBoard(shapes: size)
            let h = EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }
            h.editor.viewportDidResize(to: viewport)
            draw(h.editor, into: context, size: viewport)
            _ = try require(h.editor.validation).results
            let queries = try require(h.editor.queries)
            // Ten types by title, five by kind and title, a note by its title, and four by kind and a test: each of the
            // titles a note's name, so every request reads names.
            let records = (0..<10).map { "Record \(9 + 10 * $0)" }
            var texts = records.map { "\"\($0)\"" } + records.prefix(5).map { "sticky-note\"\($0)\"" } + ["\"\(middleTitle(size))\""]
            texts += ["sticky-note[schema]", "subboard[title]", "sticky-note:not([title])", #"sticky-note[schema][title^="Record"]"#]
            expectEqual(texts.count, 20)
            let requests = texts.map { QueryMatchRequest($0, edges: .recorded, limit: 50) }
            var mains: [Double] = [], offs: [Double] = [], answers: [Result<QueryMatches, QueryError>] = []
            for _ in 0..<11 {
                #if DEBUG
                let asked = queries.derivedTitlesAsked
                #endif
                let (value, main, off) = try cpu { await queries.matches(requests) }
                #if DEBUG
                expectEqual(queries.derivedTitlesAsked - asked, 0, "no derived name to ask: a type's is its note's title")
                #endif
                mains.append(main)
                offs.append(off)
                answers = value
            }
            #if DEBUG
            expectEqual(queries.liveSnapshots, 0)
            #endif
            for (text, answer) in zip(texts.prefix(16), answers) {
                guard case .success(let matches) = answer else {
                    expect(false, "\(text) was refused: \(answer)")
                    continue
                }
                expect(matches.count >= 1, "\(text) matched nothing")
            }
            let main = middle(mains), off = middle(offs)
            report(String(format: "%6d shapes, a batch of 20 queries by title and kind: main %6.3f ms (budget %.1f), off the main actor %6.2f (budget %.0f)",
                          size, main, Budget.referenceBatchMain.at(size), off, Budget.referenceBatchOffMain.at(size)))
            if holdsToBudgets {
                expect(main < Budget.referenceBatchMain.at(size), "a batch of 20 queries on \(size) shapes took \(main) ms on the main actor")
                expect(off < Budget.referenceBatchOffMain.at(size), "a batch of 20 queries on \(size) shapes took \(off) ms off the main actor")
            }
        }
    },
    test("a path into a list, and a date compared, are walked off the main actor within the scan's budget: a tenth of the file holds values") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let registry = try Registry(plugins: shippedPlugins(pasteboard))
        let products = ["Mug", "Pen", "Cup", "Ink", "Lamp"]
        for size in sizes {
            var shapes = generatedBoard(shapes: size).shapes
            var held = 0
            for index in shapes.indices where shapes[index].kind == StickyNote.kind && shapes[index][TypeSchemaProperty.self] == nil && held < size / 10 {
                let items: [JSONValue] = (0..<5).map { ["product": .string(products[($0 + held) % 5] + "\(held % 7)"), "qty": .number(Double($0))] }
                shapes[index][FieldValuesProperty.self] = FieldValues(["lineItems": .array(items), "due": .string("2026-0\(1 + held % 9)-15")])
                held += 1
            }
            let document = CanvasDocument(shapes: shapes)
            for (name, text, budget) in [("a path into a list", #"[fieldValues.lineItems.product="Mug1"]"#, Budget.queryPathList),
                                         ("a date compared", #"[fieldValues.due<"2026-05-01"]"#, Budget.queryPathDate)] {
                var offs: [Double] = [], mains: [Double] = [], count = 0
                for _ in 0..<7 {
                    let editor = CanvasEditor(registry: registry, document: document, scheduler: ManualScheduler())
                    _ = try require(editor.queries).vocabulary
                    let answered = try queried(text, on: editor, limit: 100)
                    offs.append(answered.timings.offMain.milliseconds)
                    mains.append(answered.timings.main.milliseconds)
                    count = answered.count
                }
                expect(count > 0, "\(text) matched nothing")
                let off = middle(offs), main = middle(mains)
                report(String(format: "%6d shapes, %@ over %d notes' values (%d match): main %6.3f ms (budget %.1f), off it %6.2f (budget %.0f)",
                              size, name, held, count, main, Budget.queryMain.at(size), off, budget.at(size)))
                if holdsToBudgets {
                    expect(main < Budget.queryMain.at(size), "\(name) took \(main) ms on the main actor over \(size) shapes")
                    expect(off < budget.at(size), "\(name) took \(off) ms off the main actor over \(size) shapes")
                }
            }
        }
    },
    test("a row's problems are asked of the rows returned alone, in slices: 100 incomplete notes among the file's shapes") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let registry = try Registry(plugins: shippedPlugins(pasteboard))
        for size in sizes {
            var shapes = generatedBoard(shapes: size).shapes
            var type: ShapeID?, held = 0
            for index in shapes.indices where shapes[index].kind == StickyNote.kind && shapes[index][TypeSchemaProperty.self] == nil {
                if let type {
                    guard held < 100 else { break }
                    shapes[index][IsAProperty.self] = [TypeLink(type)]
                    held += 1
                } else {
                    shapes[index][TypeSchemaProperty.self] = SchemaText(#"{"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]}"#)
                    shapes[index][TitleProperty.self] = "Record"
                    type = shapes[index].id
                }
            }
            let document = CanvasDocument(shapes: shapes)
            var mains: [Double] = [], without: [Double] = [], count = 0, listed = 0
            for _ in 0..<7 {
                let editor = CanvasEditor(registry: registry, document: document, scheduler: ManualScheduler())
                _ = try require(editor.queries).vocabulary
                let counted = try queried(":incomplete", on: editor, countOnly: true)
                without.append(counted.timings.main.milliseconds)
                let editorAgain = CanvasEditor(registry: registry, document: document, scheduler: ManualScheduler())
                _ = try require(editorAgain.queries).vocabulary
                let answered = try queried(":incomplete", on: editorAgain)
                mains.append(answered.timings.main.milliseconds)
                count = answered.count
                listed = answered.rows.count { $0.problems?.count == 1 }
            }
            expectEqual(count, 100)
            expectEqual(listed, 100, "each lists the one name it needs")
            let main = middle(mains), alone = middle(without)
            report(String(format: "%6d shapes, :incomplete over 100 notes needing a name: main %6.3f ms with their problems (budget %.1f), %6.3f counted alone",
                          size, main, Budget.queryProblemsMain.at(size), alone))
            if holdsToBudgets { expect(main < Budget.queryProblemsMain.at(size), "`:incomplete` with 100 rows took \(main) ms on the main actor over \(size) shapes") }
        }
    },
    test("no slice of any query here is longer than 2 ms and the record that crosses it") {
        report(String(format: "of every query here, the longest slice %5.3f ms (%@; budget %.0f), the costliest record %5.3f (%@)",
                      slicesSeen.longest.ms, slicesSeen.longest.query, Budget.querySlice, slicesSeen.costliest.ms, slicesSeen.costliest.query))
        if holdsToBudgets { expect(slicesSeen.longest.ms < Budget.querySlice, "a slice of \(slicesSeen.longest.query) took \(slicesSeen.longest.ms) ms") }
    },
])
