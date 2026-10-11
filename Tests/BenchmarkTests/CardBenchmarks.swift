import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import CoreGraphics
import Foundation
import Geometry
import LanguageModels
import Mentions
import ShippedTesting
import StickyNotes
import TestKit
import Titles
import Types

// The card (`editor.card`, a plugin's view under a rect of the board): a frame with one open costs what
// laying it out does, one `camera.toView`, two calls of the plugin's `size` and a frame set if it
// moved, whatever the board.

extension Budget {
    /// A pan's frame of the 10,000-shape board with a card open (the camera moved, `CanvasView` told, the
    /// card laid out, the canvas drawn) over the same frame with none, the two alternating. The thread's
    /// CPU, release: 0.05, 0.00 and 0.16 ms in three runs alone at a load average of 15 (the frame
    /// itself 9 to 12 ms, whose noise is the floor), and the plan's 0.3.
    static let cardFrame = 0.3
    /// The Types card of a note's 200-line table of four columns (a list of groups) opened: the form made, its sheet
    /// of 200 lines asked of the book once, laid out, the first stop focused, and the core's card shown. The thread's
    /// CPU, release: 3.25, 3.31 and 3.40 ms in three runs alone at a load average of 5, and about three times their median.
    static let cardOpen = 10.0
    /// One keystroke's `reload` of that card after a write to a cell of it (the write itself is a commit like any
    /// other, and is not counted): the sheet of the level shown asked again, O(its cells), the lines in view drawn. Release: 0.87, 0.88 and 0.89 ms in the same runs, and about three times their median.
    static let cardKeystroke = 3.0
}

/// A note that is a Stock, its `lineItems` a table of `lines` lines, in an unshown window, and its card's request.
@MainActor private final class TableCard {
    let editor: CanvasEditor
    let window: NSWindow
    let canvas: CanvasView
    let note: ShapeID
    let path = FieldPath(field: "lineItems")

    init(lines: Int, pasteboard: NSPasteboard) throws {
        let schema = #"{"type": "object", "properties": {"lineItems": {"type": "array", "items": {"type": "object", "properties": {"product": {"type": "string"}, "quantity": {"type": "integer"}, "price": {"type": "number"}, "note": {"type": "string"}}}}}}"#
        let typeID = ShapeID()
        var type = AnyShapeRecord(ShapeRecord(id: typeID, StickyNote(frame: CGRect(x: 600, y: 40, width: 200, height: 200), text: MentionText(plain: "A stock list."))))
        type[TypeSchemaProperty.self] = SchemaText(schema)
        type[TitleProperty.self] = "Stock"
        var instance = AnyShapeRecord(ShapeRecord(StickyNote(frame: CGRect(x: 40, y: 40, width: 320, height: 220), text: MentionText(plain: "Stock"))))
        instance[IsAProperty.self] = [TypeLink(typeID)]
        note = instance.id
        editor = CanvasEditor(registry: try Registry(plugins: shippedPlugins(pasteboard)), document: CanvasDocument(shapes: [type, instance]), scheduler: ManualScheduler())
        let items: [JSONValue] = (0..<lines).map { ["product": .string("Item \($0)"), "quantity": .number(Double($0 % 9 + 1)), "price": 9.5, "note": "-"] }
        expect(editor.fieldWriter?.set(.array(items), at: path, of: note) == true)
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        canvas = CanvasView(editor: editor)
        window.contentView = canvas
    }

    func request() -> FieldCardRequest {
        FieldCardRequest(shape: note, target: .field(path), mode: .values, isReadOnly: false, rowRect: CGRect(x: 160, y: 120, width: 180, height: 22),
                         closed: {}, tabbedOut: { _ in })
    }
}

@MainActor let cardBenchmarks = Suite("Card benchmarks", [
    test("a pan's frame of the board with a card open costs hardly more than the same frame with none") {
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        for size in sizes {
            let document = generatedBoard(shapes: size)
            let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
            let h = EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: viewport), styleMask: [.titled], backing: .buffered, defer: false)
            let canvas = CanvasView(editor: h.editor)
            window.contentView = canvas
            let note = try require(document.shapes.first { $0.kind == StickyNote.kind })
            let box = try require(note.box)
            h.editor.camera = camera(centering: box, at: 0.5, in: viewport)
            draw(h.editor, into: context, size: viewport)      // the first frame works out every shape's geometry
            let probe = CardProbe(frame: .zero)
            let log = ClosingLog()
            let card = probeCard("bench", about: note.id, anchor: CGRect(x: box.minX + 10, y: box.minY + 10, width: 100, height: 22),
                                 probe: probe, closings: log)
            // Frames with and without the card alternate, so whatever else the machine does is in both; the
            // card is shown and taken down (untimed) between them.
            var without: [Double] = [], with: [Double] = []
            for run in 0..<200 {
                let open = run % 2 == 1
                if open { expect(h.editor.showCard(card)) }
                let time = threadCPUTime {
                    h.editor.camera.pan(by: CGSize(width: run % 4 < 2 ? 1 : -1, height: 0))
                    draw(h.editor, into: context, size: viewport)
                }.milliseconds
                if open { with.append(time) } else { without.append(time) }
                if open { h.editor.closeCard() }
            }
            expectEqual(log.closings.filter { $0 != .asked }, [], "the card stayed open through the pans")
            let added = with.sorted()[with.count / 2] - without.sorted()[without.count / 2]
            report(String(format: "%6d shapes: a pan's frame %5.2f ms, %5.2f more with a card open (budget %.1f)", size, without.sorted()[without.count / 2], added, Budget.cardFrame))
            if holdsToBudgets, size >= 10_000 { expect(added < Budget.cardFrame, "a card open added \(added) ms to a pan's frame over \(size) shapes") }
        }
    },
    test("a table of 200 lines opens as a card, and a keystroke in it reloads the form, each within a budget") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let rig = try TableCard(lines: 200, pasteboard: pasteboard)
        defer { rig.window.close() }
        let cards = try require(rig.editor.fieldCards)
        expect(cards.open(rig.request()))
        cards.close()
        let opened = median(runs: 11, onThread: true) {
            expect(cards.open(rig.request()))
            cards.close()
        }
        expect(cards.open(rig.request()))
        let form = try require(cards.openForm)
        expectEqual(form.sheet.lines.count, 201, "200 lines and the one waiting")
        var count = 0
        let reloaded = median(runs: 21, prepare: {
            count += 1
            expect(rig.editor.fieldWriter?.set(.number(Double(count)), at: rig.path.index(100).key("price"), of: rig.note, step: .card(key: "bench")) == true)
        }, onThread: true) { form.reload() }
        report(String(format: "a 200-line table of four columns: opened %5.2f ms (budget %.0f), a keystroke's reload %5.2f ms (budget %.0f)", opened, Budget.cardOpen, reloaded, Budget.cardKeystroke))
        cards.close()
        if holdsToBudgets {
            expect(opened < Budget.cardOpen, "opening the card took \(opened) ms")
            expect(reloaded < Budget.cardKeystroke, "a keystroke's reload took \(reloaded) ms")
        }
    },
])
