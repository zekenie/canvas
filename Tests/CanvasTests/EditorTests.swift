@_spi(Host) import Canvas
import CanvasTesting
import AppKit
import CoreGraphics
import Geometry
import Observation
import TestKit

// The core on its own: with no plugin claiming it, the Hand is the default tool.
@MainActor let editorTests = Suite("Editor", [
    test("a place tool that edits: centered, following the pointer while pressed, edited on the release, and back to the default tool") {
        let h = try EditorHarness(plugins: [CardsPlugin()])
        h.editor.setTool(ToolID(placing: Card.kind))
        expectEqual(h.editor.currentToolID, ToolID(placing: Card.kind))
        expectEqual(h.editor.cursor, .crosshair)
        h.press(at: CGPoint(x: 100, y: 100))
        let card = try require(h.editor.document.shapes.first)
        expectEqual(card.box?.origin, CGPoint(x: 50, y: 70))
        expectEqual(h.editor.currentToolID, .hand)
        expectEqual(h.editor.editingShapeID, nil, "not while the press lasts")
        h.drag(to: CGPoint(x: 130, y: 110))
        expectEqual(h.editor.document[card.id]?.box?.origin, CGPoint(x: 80, y: 80), "it follows the pointer, as a translating placement does")
        h.release()
        expectEqual(h.editor.editingShapeID, card.id)
        expectEqual(h.editor.undoHistory.undoName, "Add Card")
        h.editor.endEditing()
        h.click(at: CGPoint(x: 400, y: 400))
        expectEqual(h.editor.editingShapeID, nil, "the hand's click places nothing")
        h.editor.setTool(ToolID(placing: Card.kind))
        h.click(at: CGPoint(x: 400, y: 400))
        expectEqual(h.editor.editingShapeID, h.editor.document.shapes.last?.id, "a click: edited once it's let go")
        expectEqual(h.editor.document.shapes.last?.box?.origin, CGPoint(x: 350, y: 370))
    },
    test("Escape while a placed shape follows the pointer takes it away: the press's step comes to nothing, and the release edits nothing") {
        let h = try EditorHarness(plugins: [CardsPlugin(), discTools()])
        for kind in [Card.kind, Disc.kind] {
            h.editor.setTool(ToolID(placing: kind))
            h.press(at: CGPoint(x: 100, y: 100))
            h.drag(to: CGPoint(x: 150, y: 120))
            h.escape()
            expectEqual(h.editor.document.shapes, [], "\(kind)")
            h.drag(to: CGPoint(x: 200, y: 200))
            h.release()
            expectEqual(h.editor.document.shapes, [])
            expectEqual(h.editor.editingShapeID, nil)
            expect(!h.editor.canUndo, "nothing to undo")
            expectEqual(h.editor.currentToolID, .hand)
        }
    },
    test("placed with no press under way, an editing placement's shape is edited at once, and any other stays where it's placed") {
        let h = try EditorHarness(plugins: [CardsPlugin(), discTools()])
        h.editor.place(try require(h.editor.registry.placement(for: Card.kind)), at: CGPoint(x: 100, y: 100))
        let card = try require(h.editor.document.shapes.first?.id)
        expectEqual(h.editor.editingShapeID, card)
        h.editor.endEditing()
        h.editor.place(try require(h.editor.registry.placement(for: Disc.kind)), at: CGPoint(x: 300, y: 300))
        expect(h.editor.session == nil)
        expectEqual(h.editor.document.shapes.last?.box?.origin, CGPoint(x: 280, y: 280))
    },
    test("a place tool that translates keeps dragging the new shape after switching to the default tool") {
        let h = try EditorHarness(plugins: [discTools()])
        h.editor.setTool(ToolID(placing: Disc.kind))
        h.press(at: CGPoint(x: 100, y: 100))
        expectEqual(h.editor.currentToolID, .hand)
        h.drag(to: CGPoint(x: 130, y: 110))
        expectEqual(h.editor.document.shapes.first?.box?.origin, CGPoint(x: 110, y: 90))
        expectEqual(h.editor.camera.origin, .zero, "the drag moves the shape; the hand doesn't pan")
        h.release()
    },
    test("Escape on a drag puts back where the shape was, and only that: what else changed while it moved stays") {
        let h = try EditorHarness(plugins: [discTools()])
        let id = h.add(Disc(CGRect(x: 80, y: 80, width: 40, height: 40)))
        let disc = try require(h.editor.document[id])
        let placed = try require(disc.box)
        h.press(at: CGPoint(x: 100, y: 100))
        h.editor.session = TranslatingSession(ids: [disc.id], from: CGPoint(x: 100, y: 100), in: h.editor)
        h.drag(to: CGPoint(x: 130, y: 110))
        // Something other than the drag writes the shape while it moves (a model's answer landing).
        h.editor.transact { $0.update(disc.id) { $0.box?.size.width += 40 } }
        h.editor.cancel()
        expectEqual(h.editor.document[disc.id]?.box, CGRect(origin: placed.origin, size: CGSize(width: placed.width + 40, height: placed.height)))
        expect(h.editor.session == nil)
    },
    test("services hear of a placed shape once the default tool is back, before it's edited or starts following the pointer") {
        let log = ServiceLog()
        let h = try EditorHarness(plugins: [CardsPlugin(), discTools(), Contributor(id: "log") { r in r.service { _ in LoggingService(log: log) } }])
        h.editor.setTool(ToolID(placing: Card.kind))
        log.events = []
        h.press(at: CGPoint(x: 100, y: 100)); h.release()
        let card = try require(h.editor.document.shapes.first?.id)
        expectEqual(log.events, ["document", "tool card → hand", "placed \(card) in hand, editing nil, session none"])
        expectEqual(h.editor.editingShapeID, card)
        h.editor.setTool(ToolID(placing: Disc.kind))
        log.events = []
        h.press(at: CGPoint(x: 300, y: 300))
        let disc = try require(h.editor.document.shapes.last?.id)
        expectEqual(log.events.last, "placed \(disc) in hand, editing nil, session none")
        expect(h.editor.session != nil, "then it follows the pointer")
        h.release()
    },
    test("services hear of every transaction that changed the document, and of no other") {
        let log = ServiceLog()
        let h = try EditorHarness(plugins: [FixturesPlugin(), Contributor(id: "log") { r in r.service { _ in LoggingService(log: log) } }])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        h.editor.transact { $0.bringToFront(box) }              // already in front: nothing changes
        h.editor.transact { $0.delete([box]) }
        expectEqual(log.events, ["document", "document"])
    },
    test("a transaction whose body throws commits nothing: no change to hear, no refusal, no undo step, and the error comes out") {
        struct Stop: Error, Equatable {}
        let log = ServiceLog(), refusals = RefusalLog()
        let h = try EditorHarness(plugins: [FixturesPlugin(), FreezingPlugin(log: refusals),
                                            Contributor(id: "log") { r in r.service { _ in LoggingService(log: log) } }])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let frozen = h.add(Box(CGRect(x: 100, y: 0, width: 10, height: 10)))
        h.editor.freeze([frozen])
        h.editor.undoHistory.clear()
        let undo = UndoEvents(h.editor)
        log.events = []
        @MainActor func throwing() {
            do {
                try h.editor.transact("Throw") { tx in
                    tx.update(box) { $0.box = CGRect(x: 50, y: 50, width: 10, height: 10) }
                    tx.insert(ShapeRecord(Box(CGRect(x: 0, y: 100, width: 10, height: 10))))
                    tx.update(frozen) { $0.box = .zero }             // refused, which would be reported
                    tx.delete([box])
                    throw Stop()
                }
                expect(false, "the error didn't come out")
            } catch {
                expectEqual(error as? Stop, Stop())
            }
        }
        let document = h.editor.document, revision = h.editor.revision
        throwing()
        expectEqual(h.editor.document, document)
        expectEqual(h.editor.revision, revision)
        expectEqual(log.events, [], "no change set")
        expectEqual(refusals.refusals, [], "no refusal")
        expectEqual(undo.events, [], "no step began, so the board isn't edited")
        expect(!h.editor.canUndo)
        h.editor.transact("Move") { $0.update(box) { $0.box = CGRect(x: 50, y: 50, width: 10, height: 10) } }
        expectEqual(log.events, ["document"], "and the next transaction is as any other")
        expectEqual(undo.events, [.began, .closed])
        // What there was to redo stays.
        h.editor.undo()
        expect(h.editor.canRedo)
        undo.events = []
        throwing()
        expect(h.editor.canRedo, "a throw clears nothing")
        expectEqual(undo.events, [])
        expectEqual(h.editor.undoHistory.redoName, "Move")
    },
    test("tool switches are observable, so the toolbar follows ones made on the canvas with no callback") {
        let h = try EditorHarness(plugins: [CardsPlugin()])
        let changed = Flag()
        withObservationTracking { _ = h.editor.currentToolID } onChange: { changed.set() }
        h.editor.setTool(ToolID(placing: Card.kind))
        expect(changed.isSet)
    },
    test("the document and the file read within withoutObservingDocument observe nothing; read outside, they're observed") {
        let h = try EditorHarness(plugins: [CardsPlugin()])
        let unobserved = Flag(), observed = Flag()
        withObservationTracking {
            let count = h.editor.withoutObservingDocument {
                h.editor.document.shapes.count + h.editor.file.root.shapes.count + h.editor.contents(of: .root).shapes.count
            }
            expectEqual(count, 0)
        } onChange: { unobserved.set() }
        withObservationTracking {
            _ = h.editor.withoutObservingDocument { h.editor.withoutObservingDocument { h.editor.file } }
            _ = h.editor.document
        } onChange: { observed.set() }
        h.editor.transact { $0.insert(ShapeRecord(Card(CGRect(x: 0, y: 0, width: 10, height: 10)))) }
        expect(!unobserved.isSet)
        expect(observed.isSet, "nested, it ends with the outermost")
    },
    test("Escape: the session's, else the tool's own, else back to the default tool") {
        let log = ServiceLog()
        let h = try EditorHarness(plugins: [CardsPlugin(), Contributor(id: "escapes") {
            $0.tool(ToolDescriptor(id: "keeper", label: "Keeper", systemImage: "circle")) { _ in EscapeKeeper(log: log) }
        }])
        h.editor.setTool(ToolID(placing: Card.kind)); h.escape()
        expectEqual(h.editor.currentToolID, .hand)
        h.editor.setTool("keeper"); h.escape()
        expectEqual(h.editor.currentToolID, "keeper", "the tool handled it")
        expectEqual(log.events, ["keeper cancelled"])
        h.escape()
        expectEqual(h.editor.currentToolID, "keeper")
    },
    test("an anchored shape paints just above its anchor, or on top without one") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let tagA = h.add(Tag(target: a))
        let loose = h.add(Tag(target: nil))
        let b = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        let tagB = h.add(Tag(target: b))
        expectEqual(h.editor.paintOrder().map(\.id), [a, tagA, b, tagB, loose])
        h.editor.transact { $0.bringToFront(a) }
        expectEqual(h.editor.paintOrder().map(\.id), [b, tagB, a, tagA, loose])
    },
    test("shape(at:) finds the front-most shape under a point, of those it's asked about") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let back = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let front = h.add(Disc(CGRect(x: 0, y: 0, width: 100, height: 100)))
        expectEqual(h.editor.shape(at: CGPoint(x: 50, y: 50)), front)
        expectEqual(h.editor.shape(at: CGPoint(x: 50, y: 50)) { $0.kind == Box.kind }, back)
        expectEqual(h.editor.shape(at: CGPoint(x: 2, y: 2)), back, "the disc's corner is empty")
        expectEqual(h.editor.shape(at: CGPoint(x: 50, y: 50)) { _ in false }, nil)
    },
    test("an editing view's context writes through a transaction and ends editing") {
        let h = try EditorHarness(plugins: [CardsPlugin()])
        let card = h.add(Card(CGRect(x: 0, y: 0, width: 100, height: 60)))
        expect(h.editor.beginEditing(card))
        let field = try require(h.editor.makeEditingView()?.view as? CardField)
        field.context.update { $0.text = "hi" }
        expectEqual(h.editor.document[card]?.typed(as: Card.self)?.props.text, "hi")
        field.context.end()
        expectEqual(h.editor.editingShapeID, nil)
        expect(h.editor.makeEditingView() == nil)
    },
    test("where editing began is the editing view's to read, and is kept only while it lasts") {
        let h = try EditorHarness(plugins: [CardsPlugin()])
        let card = h.add(Card(CGRect(x: 0, y: 0, width: 100, height: 60)))
        expect(h.editor.beginEditing(card, at: CGPoint(x: 30, y: 20)))
        expectEqual(h.editor.editingStartPoint, CGPoint(x: 30, y: 20))
        expectEqual(try require(h.editor.makeEditingView()?.view as? CardField).context.startPoint, CGPoint(x: 30, y: 20))
        expect(h.editor.beginEditing(card, at: CGPoint(x: 70, y: 40)), "begun again, from another press")
        expectEqual(try require(h.editor.makeEditingView()?.view as? CardField).context.startPoint, CGPoint(x: 70, y: 40))
        h.editor.endEditing()
        expectEqual(h.editor.editingStartPoint, nil)
        expect(h.editor.beginEditing(card))
        expectEqual(h.editor.editingStartPoint, nil, "a beginning that doesn't say leaves the view to choose")
        expectEqual(try require(h.editor.makeEditingView()?.view as? CardField).context.startPoint, nil)
        expect(h.editor.beginEditing(card, at: CGPoint(x: 10, y: 10)))
        h.editor.transact { $0.delete([card]) }
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(h.editor.editingStartPoint, nil, "gone with the shape, as editing is")
    },
    test("a beginning that's refused keeps no point") {
        let h = try EditorHarness(plugins: [CardsPlugin(), FixturesPlugin(), FreezingPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 60)))
        let frozen = h.add(Card(CGRect(x: 200, y: 0, width: 100, height: 60)))
        h.editor.freeze([frozen])
        expect(!h.editor.beginEditing(box, at: CGPoint(x: 5, y: 5)))
        expect(!h.editor.beginEditing(frozen, at: CGPoint(x: 205, y: 5)))
        expectEqual(h.editor.editingStartPoint, nil)
    },
    test("an editing view's context lends the editor's services, as the panel's and the table of contents' do") {
        let log = ServiceLog()
        let h = try EditorHarness(plugins: [CardsPlugin(), Contributor(id: "log") { $0.service { _ in LoggingService(log: log) } }])
        let card = h.add(Card(CGRect(x: 0, y: 0, width: 100, height: 60)))
        expect(h.editor.beginEditing(card))
        let context = try require(h.editor.makeEditingView()?.view as? CardField).context
        expect(context.service(LoggingService.self) === h.editor.service(LoggingService.self))
        expect(context.service(LoggingService.self) != nil)
        expect(context.service(ChangeRecorder.self) == nil, "one no plugin registers")
    },
    test("only an editable kind can be edited") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 60)))
        expect(!h.editor.beginEditing(box))
        expectEqual(h.editor.editingShapeID, nil)
    },
    test("any transaction that deletes a shape lets go of it: hint and editing") {
        let h = try EditorHarness(plugins: [CardsPlugin()])
        let card = h.add(Card(CGRect(x: 0, y: 0, width: 100, height: 60)))
        h.editor.hintedShapeID = card
        h.editor.beginEditing(card)
        expectEqual(h.editor.hintedShapeID, card); expectEqual(h.editor.editingShapeID, card)
        h.editor.transact { $0.delete([card]) }
        expectEqual(h.editor.hintedShapeID, nil)
        expectEqual(h.editor.editingShapeID, nil)
    },
    test("pressing the canvas ends editing") {
        let h = try EditorHarness(plugins: [CardsPlugin()])
        let card = h.add(Card(CGRect(x: 0, y: 0, width: 100, height: 60)))
        h.editor.beginEditing(card)
        h.press(at: CGPoint(x: 500, y: 500)); h.release()
        expectEqual(h.editor.editingShapeID, nil)
    },
    test("the hint only ever names a shape that exists") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        h.editor.hintedShapeID = box
        h.editor.hintedShapeID = ShapeID()
        expectEqual(h.editor.hintedShapeID, nil)
    },
    test("setting the hint to a shape that isn't there, when unset, changes nothing: no redraw, no notification") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let host = DisplayCounter()
        h.editor.delegate = host
        let changed = Flag()
        withObservationTracking { _ = h.editor.hintedShapeID } onChange: { changed.set() }
        h.editor.hintedShapeID = ShapeID()
        expectEqual(host.redraws, 0)
        expect(!changed.isSet)
    },
    test("switching tools redraws, since what plugins draw can depend on the tool") {
        let h = try EditorHarness(plugins: [CardsPlugin()])
        let host = DisplayCounter()
        h.editor.delegate = host
        h.editor.setTool(ToolID(placing: Card.kind))
        let afterSwitch = host.redraws
        expect(afterSwitch >= 1)
        h.escape()
        expect(host.redraws > afterSwitch)
    },
    test("setNeedsDisplay reaches the hosting view") {
        let h = try EditorHarness(plugins: [])
        let host = DisplayCounter()
        h.editor.delegate = host
        h.editor.setNeedsDisplay()
        expectEqual(host.redraws, 1)
    },
    test("a kind can have two place tools, each with its own id") {
        let h = try EditorHarness(plugins: [Contributor(id: "discs") { r in
            r.shape(DiscDefinitionForTests()) { disc in
                disc.tool(label: "Disc", systemImage: "circle", placing: disc.placement(size: CGSize(width: 40, height: 40)) { Disc(.zero) })
                disc.tool("small-disc", label: "Small disc", systemImage: "circle.fill",
                          placing: disc.placement(size: CGSize(width: 10, height: 10)) { Disc(.zero) })
            }
        }])
        expectEqual(h.editor.registry.tools.map(\.id), [.hand, ToolID(placing: Disc.kind), "small-disc"])
        h.editor.setTool("small-disc"); h.press(at: CGPoint(x: 100, y: 100)); h.release()
        h.editor.setTool(ToolID(placing: Disc.kind)); h.press(at: CGPoint(x: 300, y: 300)); h.release()
        expectEqual(h.editor.document.shapes.map(\.box), [CGRect(x: 95, y: 95, width: 10, height: 10), CGRect(x: 280, y: 280, width: 40, height: 40)])
    },
    test("an editing view keeps a rect in view (its caret): the camera pans at once, as little as it takes, 16 points in from the clear part of the view; no zoom, no step") {
        let h = try EditorHarness(plugins: [CardsPlugin()])
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        let card = h.add(Card(CGRect(x: 100, y: 700, width: 100, height: 60)))
        h.editor.replaceDocument(with: h.editor.document)
        expect(h.editor.beginEditing(card))
        let field = try require(h.editor.makeEditingView()?.view as? CardField)
        let caret = CGRect(x: 10, y: 10, width: 1, height: 16)          // in the view's coordinates: from the card's corner
        field.context.keepInView(caret)
        expectEqual(h.editor.camera, Camera(origin: CGPoint(x: 0, y: 142), zoom: 1), "726, its bottom, to 584")
        field.context.keepInView(caret)
        expectEqual(h.editor.camera.origin, CGPoint(x: 0, y: 142), "in view: nothing")
        h.editor.coveredTop = { _ in 35 }
        h.editor.camera = Camera(origin: CGPoint(x: 0, y: 700), zoom: 2)
        field.context.keepInView(caret)
        expectEqual(h.editor.camera, Camera(origin: CGPoint(x: 0, y: 700 - 15.5), zoom: 2), "at its top, 20 points down: to 51, 16 below the covered top")
        field.context.keepInView(CGRect(x: 90, y: 10, width: 1, height: 16))
        expectEqual(h.editor.camera.origin.x, 0, "190 at 200%: 380 points in, in view")
        expect(!h.editor.canUndo, "the camera's moves are no step")
    },
    test("a rect an editing view keeps in view that is in the clear view already is not nudged the margin in by a few points when the caller skips nudges (a pick); one cut by the edge is; a caret typed toward the edge pans for every character (UX walk 5 firstminute-5-2)") {
        let h = try EditorHarness(plugins: [CardsPlugin()])
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        let card = h.add(Card(CGRect(x: 100, y: 562, width: 100, height: 60)))
        h.editor.replaceDocument(with: h.editor.document)
        expect(h.editor.beginEditing(card))
        let field = try require(h.editor.makeEditingView()?.view as? CardField)
        // 572 to 588: in the view, 4 points into the 16-point margin.
        field.context.keepInView(CGRect(x: 10, y: 10, width: 1, height: 16), skippingNudges: true)
        expectEqual(h.editor.camera.origin, .zero, "in view: a 4-point pan would only move the board")
        // 9 points in: past the least pan, it's brought the margin in.
        field.context.keepInView(CGRect(x: 10, y: 15, width: 1, height: 16), skippingNudges: true)
        expectEqual(h.editor.camera.origin, CGPoint(x: 0, y: 9), "593, its bottom, to 584")
        // Cut by the edge by a point: brought the margin in.
        h.editor.camera = Camera(origin: .zero, zoom: 1)
        field.context.keepInView(CGRect(x: 10, y: 22, width: 1, height: 17), skippingNudges: true)
        expectEqual(h.editor.camera.origin, CGPoint(x: 0, y: 17), "601 to 584")
        // A caret typed toward the edge: each character follows it, however few points it moves.
        h.editor.camera = Camera(origin: .zero, zoom: 1)
        field.context.keepInView(CGRect(x: 10, y: 10, width: 1, height: 16))
        expectEqual(h.editor.camera.origin, CGPoint(x: 0, y: 4), "4 points into the margin: followed")
        field.context.keepInView(CGRect(x: 10, y: 14, width: 1, height: 16))
        expectEqual(h.editor.camera.origin, CGPoint(x: 0, y: 8), "and 4 more: no character skipped, none panned twice")
    },
    test("the root board is called what the host says, nothing until it does; whoever reads the name hears it change, and only then") {
        let h = try EditorHarness(plugins: [CardsPlugin()])
        expectEqual(h.editor.rootName, "")
        let named = Flag()
        withObservationTracking { _ = h.editor.rootName } onChange: { named.set() }
        h.add(Card(CGRect(x: 0, y: 0, width: 100, height: 60)))
        expect(!named.isSet, "a commit doesn't touch it")
        h.editor.nameRoot("Plans")
        expect(named.isSet)
        expectEqual(h.editor.rootName, "Plans")
        let again = Flag()
        withObservationTracking { _ = h.editor.rootName } onChange: { again.set() }
        h.editor.nameRoot("Plans")
        expect(!again.isSet, "the same name is no change")
        h.editor.replaceFile(with: CanvasFile())
        expectEqual(h.editor.rootName, "Plans", "the editor's, not the file's: another file put in place is the window's to name")
        expect(!h.editor.canUndo, "naming it is no step")
    },
    test("an editing text's selection reads each attachment that reads as text as that text, and drops the rest") {
        /// A pill-like attachment that reads as a name, and one that doesn't.
        final class Named: NSTextAttachment, ReadsAsText {
            var readsAs: String { "Walrus" }
        }
        let text = NSMutableAttributedString(string: "Feed ")
        text.append(NSAttributedString(attachment: Named()))
        text.append(NSAttributedString(string: " and "))
        text.append(NSAttributedString(attachment: NSTextAttachment()))
        text.append(NSAttributedString(string: "now"))
        expectEqual(text.length, 15)
        expectEqual(text.readingAttachments(in: NSRange(location: 0, length: text.length)), "Feed Walrus and now")
        expectEqual(text.readingAttachments(in: NSRange(location: 5, length: 1)), "Walrus")
        expectEqual(text.readingAttachments(in: NSRange(location: 11, length: 1)), "", "an attachment that doesn't read as text is dropped")
        expectEqual(text.readingAttachments(in: NSRange(location: 2, length: 4)), "ed Walrus")
    },
])

@MainActor final class ServiceLog {
    var events: [String] = []
}

/// Logs what the editor tells services.
final class LoggingService {
    let log: ServiceLog
    init(log: ServiceLog) { self.log = log }
}

extension LoggingService: EditorService {
    func toolDidChange(from old: ToolID, to new: ToolID, in editor: CanvasEditor) { log.events.append("tool \(old) → \(new)") }
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) { log.events.append("document") }
    func didPlace(_ ids: [ShapeID], in editor: CanvasEditor) {
        log.events.append("placed \(ids.map(\.description).joined(separator: ", ")) in \(editor.currentToolID), editing \(editor.editingShapeID.map(\.description) ?? "nil"), "
                          + "session \(editor.session == nil ? "none" : "running")")
    }
}

/// A tool that keeps Escape for itself.
final class EscapeKeeper {
    let log: ServiceLog
    init(log: ServiceLog) { self.log = log }
}

extension EscapeKeeper: Tool {
    func pointerDown(_ pointer: Pointer, in editor: CanvasEditor) {}
    func cancel(in editor: CanvasEditor) -> Bool {
        log.events.append("keeper cancelled")
        return true
    }
}

/// Counts what the editor tells its view. (Its delegate protocol is the host's, so it can't be
/// public in CanvasTesting.)
final class DisplayCounter: CanvasEditorDelegate {
    var redraws = 0
    func editorNeedsDisplay(_ editor: CanvasEditor) { redraws += 1 }
    func editorCursorDidChange(_ editor: CanvasEditor) {}
    func editorEditingDidChange(_ editor: CanvasEditor) {}
}
