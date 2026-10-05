import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Composition
import CoreGraphics
import Geometry
import LanguageModels
import Mentions
import Publishing
import Queries
import References
import Schemas
import StickyNotes
import Subboards
import TestKit
import Titles
import Topology

// Pills in view: a board of a thousand of them, in a view at 40% (just over where shapes become
// skeletons), half standing for notes on the board, half for notes on another board of the file, a
// frame drawn again with the camera a point from the last one's, as a pan's is; and the same zoomed
// out to 30%, where each is one square fill. Each pill reads its shape through the context (a
// dictionary hit, or a walk to its board) and draws a kept label and symbol. And the list over a
// pill's field: a keystroke in it over a board of mentionable shapes of which few are public.

extension Budget {
    /// A frame of 1,000 pills in view, at 40% and zoomed out: a frame. The thread's CPU time.
    static let referencePills = frame
}

extension Budget {
    /// Twenty dynamic references answered after a commit, by title and by kind, on a board whose
    /// schema cards' names are derived (asked of the main actor in slices), every card and note public:
    /// the main actor's time in all, from the wait for quiet firing to the answers landing: the batch's
    /// (reading and resolving the twenty, taking up the file once, the slices that read every name once,
    /// `referenceBatchMain`) and the landing's (one provide, the pills, rows and panels told). The
    /// thread's CPU time.
    static let referenceAnswersMain = SizedBudget(thousand: 1, tenThousand: 5)
}

extension Budget {
    /// A keystroke in the list over a pill's field, the one that opens it included, over a board of
    /// 10,000 shapes of which 20 are public: the `@` picker's. The thread's CPU time.
    static let referencePickerKeystroke = pickerKeystroke
}

@MainActor let referenceBenchmarks = Suite("Reference benchmarks", [
    test("a thousand pills in view, half standing for shapes on another board, draw within a frame in full and zoomed out") {
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let pills = holdsToBudgets ? 1_000 : 300
        // Notes far below the pills (out of view), public and titled: the root's, and a subboard's.
        func note(_ index: Int, y: CGFloat) -> AnyShapeRecord {
            var record = AnyShapeRecord(ShapeRecord(StickyNote(frame: CGRect(x: CGFloat(index % 50) * 260, y: y, width: 200, height: 200), text: "")))
            record[TitleProperty.self] = "Target \(index)"
            record[PublicProperty.self] = true
            return record
        }
        let near = (0..<pills / 2).map { note($0, y: 20_000) }, far = (0..<pills / 2).map { note($0, y: 20_000) }
        let owner = ShapeRecord(Subboard(frame: CGRect(x: -400, y: 20_000, width: 240, height: 160)))
        let columns = 23
        var shapes: [AnyShapeRecord] = near + [AnyShapeRecord(owner)]
        for index in 0..<pills {
            let target = index.isMultiple(of: 2) ? near[index / 2] : far[index / 2]
            var props = Reference(frame: CGRect(x: CGFloat(index % columns) * 130, y: CGFloat(index / columns) * 42, width: 120, height: 32))
            ReferenceEdits.pick(&props, ReferenceTarget(id: target.id, label: "Target \(index / 2)"))
            shapes.append(AnyShapeRecord(ShapeRecord(props)))
        }
        let file = CanvasFile(root: CanvasDocument(shapes: shapes), children: [owner.id: CanvasDocument(shapes: far)])
        let h = EditorHarness { CanvasEditor(registry: registry, file: file, scheduler: $0) }
        h.editor.viewportDidResize(to: viewport)
        var lines: [String] = []
        var worst = 0.0
        for zoom in [0.4, 0.3] as [CGFloat] {
            h.editor.camera = Camera(origin: .zero, zoom: zoom)
            var step = 0.0
            let pan = {
                step = step == 0 ? 1 : 0
                h.editor.camera = Camera(origin: CGPoint(x: step / zoom, y: 0), zoom: zoom)
            }
            draw(h.editor, into: context, size: viewport)
            let frame = median(runs: 11, prepare: pan, onThread: true) { draw(h.editor, into: context, size: viewport) }
            expectEqual(h.editor.drawsSkeletons, zoom < 0.35, "skeletons below 35%")
            lines.append(String(format: "at %.0f%% %5.1f ms", zoom * 100, frame))
            worst = max(worst, frame)
        }
        report(String(format: "%6d pills in view, half for shapes on another board, a frame: %@ (budget %.0f)", pills, lines.joined(separator: "; "), Budget.referencePills))
        if holdsToBudgets { expect(worst < Budget.referencePills, "a frame of \(pills) pills took \(worst) ms") }
    },
    test("twenty dynamic references answered after a commit: the main actor's time from the wait firing to the answers landing") {
        for size in sizes {
            let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
            let document = generatedBoard(shapes: size)
            let h = EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }
            h.editor.viewportDidResize(to: CGSize(width: 1200, height: 800))
            h.editor.makePublic(document.shapes.filter { $0.kind == SchemaCard.kind || $0.kind == StickyNote.kind }.map(\.id))
            // As the batch benchmark asks: ten cards by title, five by kind and title, a note by its title, four by kind and a test.
            let records = (0..<10).map { "Record \(9 + 10 * $0)" }
            var texts = records.map { "\"\($0)\"" } + records.prefix(5).map { "schema-card\"\($0)\"" } + ["\"\(middleTitle(size))\""]
            texts += ["schema-card", "subboard[title]", "sticky-note:not([title])", #"schema-card[title^="Record"]"#]
            var pills: [ShapeID] = []
            for (index, text) in texts.enumerated() {
                var props = Reference(frame: CGRect(x: CGFloat(index) * 130, y: -200, width: 120, height: 32), all: index.isMultiple(of: 2))
                ReferenceEdits.find(&props, words: "", query: text)
                pills.append(h.editor.add(props))
            }
            let topology = try require(h.editor.topology), state = try require(h.editor.references)
            h.wait(0)
            _ = try awaitResult(timeout: 60) { await topology.settled(timeout: .seconds(600)) }
            var mains: [Double] = []
            for run in 0..<11 {
                _ = h.editor.add(StickyNote(frame: CGRect(x: CGFloat(run) * 210, y: -500, width: 200, height: 200), text: ""))
                expect(state.isFinding, "the commit armed the wait")
                let (_, main, _) = try cpu {
                    h.wait(250)
                    _ = await topology.settled(timeout: .seconds(600))
                }
                mains.append(main)
            }
            for (text, pill) in zip(texts.prefix(16), pills) {
                guard case .answered(let matches)? = state.status(of: pill), matches.count >= 1 else {
                    expect(false, "\(text) found nothing: \(String(describing: state.status(of: pill)))")
                    continue
                }
            }
            let main = middle(mains)
            report(String(format: "%6d shapes, 20 dynamic references answered after a commit: main %6.3f ms (budget %.1f)",
                          size, main, Budget.referenceAnswersMain.at(size)))
            if holdsToBudgets { expect(main < Budget.referenceAnswersMain.at(size), "twenty references answered on \(size) shapes took \(main) ms on the main actor") }
        }
    },
    test("a keystroke in the list over a pill's field costs what matches, not the board: 10,000 mentionable shapes of which 20 are public") {
        for size in sizes {
            let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
            let document = generatedBoard(shapes: size)
            let editor = CanvasEditor(registry: registry, document: document, scheduler: ManualScheduler())
            let titled = document.shapes.filter { $0.kind == Subboard.kind }
            let publics = (0..<20).map { titled[$0 * titled.count / 20].id }
            editor.makePublic(publics)
            let pill = editor.add(Reference(frame: CGRect(x: 0, y: 0, width: 120, height: 32)))
            let state = try require(editor.references)
            // The first ask makes the public shapes' members, one pass over the catalog; every one after costs what they are.
            let first = median(runs: 1, onThread: true) { _ = ReferencePicker(state: state, owner: pill) }
            let opening = median(runs: 21, onThread: true) { _ = ReferencePicker(state: state, owner: pill) }
            let picker = ReferencePicker(state: state, owner: pill)
            expect(picker.rows.contains { if case .shape = $0 { true } else { false } }, "the public shapes nearest the pill")
            var worst = (query: "", ms: opening)
            for query in ["p", "pl", "pla", "plan", "plan 11", "pn11", "paln 11", "title 40", "zzzzq"] {
                let before = String(query.dropLast())
                let ms = median(runs: 21, prepare: { picker.setText(before) }, onThread: true) { picker.setText(query) }
                if ms > worst.ms { worst = (query, ms) }
            }
            picker.setText("plan")
            expect(picker.rows.last == .words("plan"), "the words row is last")
            report(String(format: "%6d shapes, 20 public, the list over a pill's field: first opened %6.3f ms, then %6.3f ms, the slowest keystroke %6.3f ms (\"%@\") (budget %.0f)",
                          size, first, opening, worst.ms, worst.query, Budget.referencePickerKeystroke))
            if holdsToBudgets {
                expect(opening < Budget.referencePickerKeystroke, "opening the list over \(size) shapes took \(opening) ms")
                expect(worst.ms < Budget.referencePickerKeystroke, "a keystroke in the list (\(worst.query)) over \(size) shapes took \(worst.ms) ms")
            }
        }
    },
])
