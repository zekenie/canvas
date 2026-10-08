import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Composition
import Connections
import CoreGraphics
import DetailPanel
import Frames
import Geometry
import LanguageModels
import Locking
import Mentions
import Schemas
import Selection
import StickyNotes
import Subboards
import TableOfContents
import TestKit
import Titles

// Frames as shipped: notes put in and out of frames by hand (dropped, nudged across an edge, refused by
// a locked frame), frames moved, nested, resized, deleted and drawn, pressed hollow, mentioned, locked,
// and zoomed out. The camera is at the origin at 100%, so view points are world units, and the view
// has no size, so nothing snaps (Snapping reads the shapes in view).

/// A frame most tests here hold notes in: 600 × 400, from (100, 100).
private let sprint = CGRect(x: 100, y: 100, width: 600, height: 400)

/// An empty board as shipped, its clipboard on a pasteboard of its own.
@MainActor private func frameBoard(_ pasteboard: NSPasteboard = .withUniqueName()) -> EditorHarness {
    EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0, pasteboard: pasteboard, model: ScriptedLanguageModel()) }
}

extension EditorHarness {
    /// A frame at `rect`, titled `title`, in a transaction of its own.
    @discardableResult
    fileprivate func frame(_ rect: CGRect = sprint, title: String? = nil) -> ShapeID {
        var frame = ShapeRecord(Frame(frame: rect))
        frame[TitleProperty.self] = title
        editor.transact { $0.insert(frame) }
        return frame.id
    }

    /// A note at `origin` (200 × 200), saying `text`, put in `container` (none: on the board).
    @discardableResult
    fileprivate func note(at origin: CGPoint, _ text: String = "", in container: ShapeID? = nil) -> ShapeID {
        let id = add(StickyNote(frame: CGRect(origin: origin, size: StickyNote.defaultSize), text: MentionText(plain: text)))
        if let container { editor.put([id], in: container) }
        return id
    }

    /// Drags from `from` by `delta` in two steps, past the drag threshold, and lets go.
    fileprivate func drag(from: CGPoint, by delta: CGPoint) {
        press(at: from)
        drag(to: from + delta / 2)
        drag(to: from + delta)
        release()
    }

    /// Where a shape is in the stack.
    fileprivate func depth(_ id: ShapeID) -> Int { editor.document.index(of: id) ?? -1 }
}

extension CanvasEditor {
    fileprivate func box(_ id: ShapeID) -> CGRect? { document[id]?.box }
}

/// A file of frames: on the root, frame Roadmap holding frame Sprint 3 (which holds a note and
/// subboard Research) and a schema card, Order; beside it, frame Done, locked, holding a note; on
/// Research's board, a note. The ids are fixed, so it's the file `Fixtures/files/frames.v5.json`
/// was written from: format 5, since shapes are in frames.
struct FrameFile {
    static func id(_ n: Int) -> ShapeID { ShapeID(UUID(uuidString: "F0000000-0000-4000-8000-0000000000\(String(format: "%02d", n))")!) }
    let roadmap = id(1), sprint = id(2), interview = id(3), research = id(4), order = id(5), done = id(6), shipped = id(7), inside = id(8)

    private func titled<P: ShapeProps>(_ id: ShapeID, _ props: P, _ title: String? = nil, in container: ShapeID? = nil) -> AnyShapeRecord {
        var shape = ShapeRecord(id: id, props)
        shape[TitleProperty.self] = title
        let record = AnyShapeRecord(shape)
        return container.map { record.copy(as: id, container: $0) } ?? record
    }

    var file: CanvasFile {
        var done = titled(self.done, Frame(frame: CGRect(x: 1400, y: 100, width: 500, height: 400)), "Done")
        done[LockedProperty.self] = true
        let schema = SchemaText(#"{"title": "Order", "type": "object", "properties": {"id": {"type": "string"}}}"#)
        let root = [
            titled(roadmap, Frame(frame: CGRect(x: 100, y: 100, width: 1200, height: 800)), "Roadmap"),
            titled(sprint, Frame(frame: CGRect(x: 150, y: 150, width: 700, height: 500)), "Sprint 3", in: roadmap),
            titled(interview, StickyNote(frame: CGRect(x: 180, y: 200, width: 200, height: 200), text: "Interview five customers"), in: sprint),
            titled(research, Subboard(frame: CGRect(x: 450, y: 200, width: 240, height: 160)), "Research", in: sprint),
            titled(order, SchemaCard(frame: CGRect(x: 900, y: 200, width: 240, height: 52), schema: schema), in: roadmap),
            done,
            titled(shipped, StickyNote(frame: CGRect(x: 1450, y: 200, width: 200, height: 200), text: "Shipped"), in: self.done),
        ]
        return CanvasFile(root: CanvasDocument(shapes: root),
                          children: [research: CanvasDocument(shapes: [titled(inside, StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: "Inside the subboard"))])])
    }

    /// The fixture: the file as this app wrote it.
    static var fixture: Data {
        get throws { try Data(contentsOf: URL(fileURLWithPath: "Tests/CompositionTests/Fixtures/files/frames.v5.json")) }
    }
}

/// A point on a box: its middle.
private func middle(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

@MainActor let framesShippedTests = Suite("Frames, as shipped", [
    test("a note dropped mostly inside a frame joins it, rises above what it holds, and is nudged in from the edge, gliding there, as one step") {
        let h = frameBoard()
        let dropped = h.note(at: CGPoint(x: 800, y: 150), "Dropped")      // below the frame in the stack
        let frame = h.frame()
        let held = h.note(at: CGPoint(x: 150, y: 150), "Held", in: frame)
        h.drag(from: CGPoint(x: 900, y: 250), by: CGPoint(x: -250, y: 0))       // to 550…750: three quarters inside
        expectEqual(h.editor.holder(of: dropped), frame)
        expectEqual(h.editor.box(dropped)?.origin, CGPoint(x: 484, y: 150), "16 inside its right edge")
        expect(h.depth(frame) < h.depth(held) && h.depth(held) < h.depth(dropped), "above the frame and what it held")
        expect(h.editor.isGliding(dropped), "gliding in")
        h.wait(300)
        expectEqual(h.editor.drawingOffset(of: dropped), .zero, "and there")
        expectEqual(h.editor.undoHistory.undoName, "Move")
        h.editor.undo()
        expectEqual(h.editor.box(dropped)?.origin, CGPoint(x: 800, y: 150))
        expectEqual(h.editor.holder(of: dropped), nil)
        expect(h.depth(dropped) < h.depth(frame), "back where it was in the stack")
    },
    test("a note dragged mostly out of its frame leaves it, nudged clear of the edge") {
        let h = frameBoard()
        let frame = h.frame()
        let note = h.note(at: CGPoint(x: 450, y: 250), in: frame)
        h.drag(from: CGPoint(x: 550, y: 350), by: CGPoint(x: 200, y: 0))     // to 650…850: a quarter inside
        expectEqual(h.editor.holder(of: note), nil)
        expectEqual(h.editor.box(note)?.origin, CGPoint(x: 716, y: 250), "16 outside its right edge")
    },
    test("notes dragged together across an edge are judged together, and nudged in by one move, keeping their arrangement") {
        let h = frameBoard()
        let frame = h.frame()
        let top = h.note(at: CGPoint(x: 800, y: 150)), bottom = h.note(at: CGPoint(x: 800, y: 280))
        h.editor.selectedShapeIDs = [top, bottom]
        h.drag(from: CGPoint(x: 900, y: 250), by: CGPoint(x: -250, y: 0))
        expectEqual(h.editor.holder(of: top), frame)
        expectEqual(h.editor.holder(of: bottom), frame)
        expectEqual(h.editor.box(top)?.origin, CGPoint(x: 484, y: 150))
        expectEqual(h.editor.box(bottom)?.origin, CGPoint(x: 484, y: 280), "one nudge for both")
    },
    test("a note dropped into a locked frame goes back where it was, gliding, the frame shakes, and the drag leaves no step") {
        let h = frameBoard()
        let note = h.note(at: CGPoint(x: 800, y: 150))
        let frame = h.frame()
        h.editor.lock([frame])
        let before = h.editor.undoHistory.undoName
        h.drag(from: CGPoint(x: 900, y: 250), by: CGPoint(x: -250, y: 0))
        expectEqual(h.editor.box(note)?.origin, CGPoint(x: 800, y: 150), "back where it was")
        expectEqual(h.editor.holder(of: note), nil)
        expect(h.editor.isGliding(note), "gliding back")
        h.wait(16)
        expect(h.editor.drawingOffset(of: frame) != .zero, "the frame shakes")
        expectEqual(h.editor.undoHistory.undoName, before, "no step")
    },
    test("a frame moved carries what it holds, a locked note in it too, as one step") {
        let h = frameBoard()
        let frame = h.frame()
        let locked = h.note(at: CGPoint(x: 150, y: 150), in: frame), free = h.note(at: CGPoint(x: 400, y: 250), in: frame)
        h.editor.lock([locked])
        h.drag(from: CGPoint(x: 400, y: 101), by: CGPoint(x: 100, y: 50))     // its top edge
        expectEqual(h.editor.box(frame)?.origin, CGPoint(x: 200, y: 150))
        expectEqual(h.editor.box(locked)?.origin, CGPoint(x: 250, y: 200), "riding along, locked")
        expectEqual(h.editor.box(free)?.origin, CGPoint(x: 500, y: 300))
        expect(h.editor.isLocked(locked))
        expectEqual(h.editor.undoHistory.undoName, "Move")
        h.editor.undo()
        expectEqual(h.editor.box(locked)?.origin, CGPoint(x: 150, y: 150), "one step")
        expectEqual(h.editor.box(frame)?.origin, sprint.origin)
    },
    test("a frame in a frame: moving the outer moves the inner and what it holds; the inner dragged out leaves with what it holds") {
        let h = frameBoard()
        let outer = h.frame(CGRect(x: 100, y: 100, width: 800, height: 500), title: "Q4")
        let inner = h.frame(CGRect(x: 150, y: 150, width: 300, height: 260), title: "Sprint 3")
        h.editor.put([inner], in: outer)
        let note = h.note(at: CGPoint(x: 180, y: 180), in: inner)
        h.drag(from: CGPoint(x: 500, y: 101), by: CGPoint(x: 50, y: 0))
        expectEqual(h.editor.box(inner)?.origin, CGPoint(x: 200, y: 150))
        expectEqual(h.editor.box(note)?.origin, CGPoint(x: 230, y: 180))
        // The inner frame by its top edge, mostly out of the outer (150…950 now), past its left edge.
        h.drag(from: CGPoint(x: 350, y: 151), by: CGPoint(x: -300, y: 0))       // 200…500 to -100…200: a sixth inside
        expectEqual(h.editor.holder(of: inner), nil, "out of the outer")
        expectEqual(h.editor.holder(of: note), inner, "with what it holds")
        expectEqual(h.editor.box(inner)?.maxX, 150 - 16, "nudged clear of the outer's left edge")
        expectEqual(h.editor.box(note).map { $0.minX - h.editor.box(inner)!.minX }, 30, "where it was in it")
    },
    test("a frame resized over notes: at the end of the resize, a note it leaves hanging is nudged in, or leaves if it's mostly out, and one it grows over joins") {
        let h = frameBoard()
        let frame = h.frame()
        let hanging = h.note(at: CGPoint(x: 480, y: 150), in: frame)         // 480…680
        let outside = h.note(at: CGPoint(x: 760, y: 150))                    // 760…960
        h.editor.selection = frame
        h.move(to: CGPoint(x: 700, y: 300))
        h.drag(from: CGPoint(x: 700, y: 300), by: CGPoint(x: -60, y: 0))     // its right edge to 640
        expectEqual(h.editor.box(frame)?.maxX, 640)
        expectEqual(h.editor.holder(of: hanging), frame)
        expectEqual(h.editor.box(hanging)?.origin, CGPoint(x: 424, y: 150), "most of it inside: nudged in")
        expectEqual(h.editor.undoHistory.undoName, "Resize")
        h.move(to: CGPoint(x: 640, y: 300))
        h.drag(from: CGPoint(x: 640, y: 300), by: CGPoint(x: 260, y: 0))     // to 900, over most of the other
        expectEqual(h.editor.holder(of: outside), frame, "grown over: taken in")
        expectEqual(h.editor.box(outside)?.origin, CGPoint(x: 684, y: 150), "and nudged in")
        h.move(to: CGPoint(x: 900, y: 300))
        h.drag(from: CGPoint(x: 900, y: 300), by: CGPoint(x: -380, y: 0))    // to 520: the first mostly out
        expectEqual(h.editor.holder(of: hanging), nil, "mostly outside: it leaves")
        expectEqual(h.editor.box(hanging)?.minX, 536, "nudged out")
    },
    test("deleting a frame leaves what it holds where it is, on the board; undone, it holds it again") {
        let h = frameBoard()
        let frame = h.frame()
        let a = h.note(at: CGPoint(x: 150, y: 150), in: frame), b = h.note(at: CGPoint(x: 400, y: 250), in: frame)
        h.editor.selection = frame
        expect(h.key("\u{7f}"))
        expectEqual(h.editor.document[frame], nil)
        expectEqual(h.editor.box(a)?.origin, CGPoint(x: 150, y: 150))
        expectEqual(h.editor.box(b)?.origin, CGPoint(x: 400, y: 250))
        expectEqual(h.editor.holder(of: a), nil)
        h.editor.undo()
        expectEqual(h.editor.holder(of: a), frame)
        expectEqual(h.editor.holder(of: b), frame)
    },
    test("a press on a frame's empty inside is the canvas, a marquee there selects what it holds; its pill and its border grab it") {
        let h = frameBoard()
        let frame = h.frame(title: "Sprint 3")
        let note = h.note(at: CGPoint(x: 150, y: 150), in: frame)
        h.drag(from: CGPoint(x: 120, y: 120), by: CGPoint(x: 300, y: 300))
        expectEqual(h.editor.selectedShapeIDs, [note], "a marquee")
        expectEqual(h.editor.box(frame), sprint)
        let pill = try require(h.editor.adornmentFrames(of: frame).first?.rect)
        h.drag(from: middle(pill), by: CGPoint(x: 0, y: 40))
        expectEqual(h.editor.box(frame)?.origin, CGPoint(x: 100, y: 140), "by its pill")
        expectEqual(h.editor.selectedShapeIDs, [frame])
        h.drag(from: CGPoint(x: 699, y: 300), by: CGPoint(x: 0, y: 40))
        expectEqual(h.editor.box(frame)?.origin, CGPoint(x: 100, y: 180), "by its border")
        expectEqual(h.editor.box(note)?.origin, CGPoint(x: 150, y: 230), "what it holds with it")
    },
    test("an untitled frame's pill says Frame, dimmed; titled, its title, and its row's") {
        let h = frameBoard()
        let frame = h.frame()
        expectEqual(h.editor.adornmentFrames(of: frame).map(\.label), [AdornmentLabel(placeholder: "Frame")])
        expectEqual(h.editor.tableOfContents?.entries.first { $0.id == frame }?.label?.text, "Untitled Frame")
        let untitled = renderBitmap(h.editor, size: CGSize(width: 800, height: 600))
        h.editor.transact { $0.update(frame) { $0[TitleProperty.self] = "Sprint 3" } }
        expectEqual(h.editor.adornmentFrames(of: frame).map(\.label), [AdornmentLabel("Sprint 3")])
        expectEqual(h.editor.tableOfContents?.entries.first { $0.id == frame }?.label?.text, "Sprint 3")
        let titled = renderBitmap(h.editor, size: CGSize(width: 800, height: 600))
        let row = CGRect(x: 100, y: 70, width: 200, height: 24)
        expect(changedPixels(untitled, titled, in: row) > 50, "the pill, in the row above it")
        expectEqual(changedPixels(untitled, titled, in: sprint.insetBy(dx: 2, dy: 2)), 0, "the frame draws no title")
    },
    test("the Frame tool as shipped: F, a drag over notes draws a frame that takes them in, Add Frame; a click into a locked frame puts none down, and it shakes") {
        let h = frameBoard()
        let a = h.note(at: CGPoint(x: 150, y: 150)), b = h.note(at: CGPoint(x: 400, y: 150))
        expect(h.key("f"))
        h.drag(from: CGPoint(x: 100, y: 100), by: CGPoint(x: 900, y: 600))
        let frame = try require(h.editor.document.shapes.first { $0.kind == Frame.kind }?.id)
        expectEqual(h.editor.box(frame), CGRect(x: 100, y: 100, width: 900, height: 600))
        expectEqual(h.editor.selection, frame)
        expectEqual(h.editor.holder(of: a), frame)
        expectEqual(h.editor.holder(of: b), frame)
        expectEqual(h.editor.undoHistory.undoName, "Add Frame")
        h.editor.lock([frame])
        expect(h.key("f"))
        h.click(at: CGPoint(x: 550, y: 400))                                  // 640 × 400, inside it
        expectEqual(h.editor.document.shapes.filter { $0.kind == Frame.kind }.count, 1, "none in the locked frame")
        h.wait(16)
        expect(h.editor.drawingOffset(of: frame) != .zero, "which shakes")
        h.wait(500)
        expect(h.key("n"))
        h.click(at: CGPoint(x: 550, y: 400))
        expectEqual(h.editor.document.shapes.filter { $0.kind == StickyNote.kind }.count, 2, "nor a note")
        h.wait(16)
        expect(h.editor.drawingOffset(of: frame) != .zero, "which shakes again")
    },
    test("in a locked frame, what it holds is locked too: it refuses edits, moves and deletion, and shakes; only the frame shows the lock") {
        let h = frameBoard()
        let frame = h.frame()
        let note = h.note(at: CGPoint(x: 150, y: 150), "Fixed", in: frame)
        h.editor.lock([frame])
        expect(h.editor.isReadOnly(note))
        expect(!h.editor.isLocked(note), "read-only through its frame, not locked itself")
        expect(!h.editor.beginEditing(note), "no editing")
        h.drag(from: CGPoint(x: 250, y: 250), by: CGPoint(x: 100, y: 0))
        expectEqual(h.editor.box(note)?.origin, CGPoint(x: 150, y: 150), "no moving")
        h.editor.selection = note
        expect(h.key("\u{7f}"))
        expect(h.editor.document[note] != nil, "no deleting")
        h.wait(16)
        expect(h.editor.drawingOffset(of: note) != .zero, "it shakes")
        expectEqual(h.editor.adornmentFrames(of: note), [], "no lock of its own")
        expectEqual(h.editor.adornmentFrames(of: frame).count, 2, "the frame's pill, and its lock")
    },
    test("zoomed out to 30% a frame is its skeleton, square; at 35%, in full") {
        let h = frameBoard()
        let frame = h.frame(title: "Sprint 3")
        h.note(at: CGPoint(x: 150, y: 150), "Inside", in: frame)
        let size = CGSize(width: 300, height: 240)
        for (zoom, skeleton) in [(0.3, true), (0.35, false)] {
            h.editor.camera = Camera(origin: .zero, zoom: zoom)
            h.editor.skeletonZoom = 0.35
            let drawn = renderBitmap(h.editor, size: size)
            h.editor.skeletonZoom = 0
            let full = renderBitmap(h.editor, size: size)
            let corner = h.view(sprint.origin)
            if skeleton {
                expect(changedPixels(drawn, full, in: CGRect(origin: corner, size: CGSize(width: 4, height: 4))) > 0, "a square corner, where it's rounded in full")
            } else {
                expectEqual(changedPixels(drawn, full, in: CGRect(origin: .zero, size: size)), 0, "in full at 35%")
            }
        }
    },
    test("two notes and the bent arrow between them, selected: Create Frame, first in their menu, puts a frame around all three that holds the notes, the arrow bound to them as it was, and takes in a note it mostly covers; one step, and Undo takes it all back") {
        let h = frameBoard()
        let milk = h.note(at: CGPoint(x: 100, y: 100), "Milk"), eggs = h.note(at: CGPoint(x: 500, y: 100), "Eggs")
        func bound(_ id: ShapeID) -> ArrowTerminal {
            .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
        }
        let arrow = h.add(Arrow(start: bound(milk), end: bound(eggs), bend: 200))
        let below = h.note(at: CGPoint(x: 300, y: 300), "Below")      // between them, hanging below the frame they'll get
        let arc = try require(h.editor.shapeContext.bounds(of: [arrow]))
        expect(arc.maxY > 332, "the arrow bends further below the notes than the frame would reach without it: \(arc)")
        h.editor.selectedShapeIDs = [milk, eggs, arrow]
        let menu = try require(h.secondaryClick(at: CGPoint(x: 200, y: 200)))
        expectEqual(Array(menu.outline.prefix(3)), ["Create Frame", "—", "Cut"], "\(menu.outline)")
        try menu.choose("Create Frame")
        let frame = try require(h.editor.selection)
        let box = try require(h.editor.box(frame))
        expectEqual(h.editor.document[frame]?.kind, Frame.kind)
        expect(box.contains(CGRect(x: 100, y: 100, width: 600, height: 200).insetBy(dx: -32, dy: -32)), "32 past the notes: \(box)")
        expect(box.maxY >= arc.maxY + 31.99, "and 32 past the arrow's bend: \(box), \(arc)")
        expectEqual(h.editor.holder(of: milk), frame)
        expectEqual(h.editor.holder(of: eggs), frame)
        expectEqual(h.editor.holder(of: arrow), nil, "an arrow is in no frame: it follows its notes")
        let ends = try require(h.editor.document[arrow]?.typed(as: Arrow.self)?.props)
        expectEqual(ends.start.binding?.shapeID, milk)
        expectEqual(ends.end.binding?.shapeID, eggs)
        expectEqual(h.editor.holder(of: below), frame, "mostly inside it: taken in")
        let moved = try require(h.editor.box(below))
        expect(moved.minY < 300, "nudged up: \(moved)")
        // 16 inside its edge, a hair less for the arrow's bounds, which aren't whole numbers.
        expect(box.insetBy(dx: 15.99, dy: 15.99).contains(moved), "nudged fully in, 16 inside its edge")
        expectEqual(h.editor.undoHistory.undoName, "Create Frame")
        h.editor.undo()
        expectEqual(h.editor.document[frame], nil)
        expectEqual(h.editor.holder(of: milk), nil)
        expectEqual(h.editor.box(below)?.origin, CGPoint(x: 300, y: 300))
    },
    test("a mentioned frame's menu has Show What Mentions, which goes to what mentions it") {
        let h = frameBoard()
        let frame = h.frame(title: "Sprint 3")
        let note = h.add(StickyNote(frame: CGRect(x: 800, y: 150, width: 200, height: 200), text: MentionText([.text("See "), .mention(frame, label: "Sprint 3")])))
        let menu = try require(h.secondaryClick(at: CGPoint(x: 400, y: 101)))
        expect(menu.outline.contains("Show What Mentions"), "\(menu.outline)")
        try menu.choose("Show What Mentions")
        h.wait(0)
        expectEqual(h.editor.selectedShapeIDs, [note])
    },
    test("the frames file reads as it was written, every shape in its frame, the locked frame's note read-only, and writes back byte for byte") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let codec = BoardCodec(registry: registry)
        let data = try FrameFile.fixture
        let loaded = try codec.decode(data)
        let frames = FrameFile()
        expectEqual(loaded.file, registry.fillingDefaults(frames.file))
        expect(loaded.report.isEmpty, "\(loaded.report)")
        expectEqual(try codec.encode(loaded.file), data)
        expect(String(decoding: data, as: UTF8.self).contains(#""format" : 5"#), "format 5: shapes in frames")
        let editor = CanvasEditor(registry: registry, file: loaded.file, scheduler: ManualScheduler())
        expectEqual(editor.holder(of: frames.sprint), frames.roadmap)
        expectEqual(editor.holder(of: frames.interview), frames.sprint)
        expectEqual(editor.holder(of: frames.research), frames.sprint)
        expectEqual(editor.holder(of: frames.order), frames.roadmap)
        expectEqual(editor.holder(of: frames.shipped), frames.done)
        expect(editor.isReadOnly(frames.shipped), "in a locked frame")
        expect(!editor.isReadOnly(frames.interview))
        expect(editor.showBoard(BoardID(owner: frames.research)))
        expectEqual(editor.document.shapes.map(\.id), [frames.inside])
    },
    test("canvas draw draws a frame by its tool's placement: 640 × 400 unless its size says otherwise, named by its title") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        editor.viewportDidResize(to: CGSize(width: 1440, height: 900))
        _ = try drawnInProcess(#"frame "Sprint 3""#, on: editor)
        let sprint = try require(editor.document.shapes.first { $0.kind == Frame.kind })
        expectEqual(sprint.box?.size, Frame.defaultSize)
        expectEqual(sprint[TitleProperty.self], "Sprint 3")
        _ = try drawnInProcess(#"frame "Q4" size: 900x600 right of "Sprint 3""#, on: editor)
        let q4 = try require(editor.document.shapes.first { $0[TitleProperty.self] == "Q4" })
        expectEqual(q4.box?.size, CGSize(width: 900, height: 600))
        let right = try require(q4.box).minX, edge = try require(sprint.box).maxX
        expect(right > edge, "right of it")
    },
    test("canvas draw moves bands holding notes into each other's places in one run: each lands where it's placed, holding its note, and nothing is pushed or nudged") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        editor.viewportDidResize(to: CGSize(width: 1440, height: 900))
        /// A band's statement, at `y` below the anchor's top, as the dogfood scripts place them.
        func band(_ title: String, _ height: Int, _ y: Int) -> String {
            #"frame "\#(title)" size: 600x\#(height) right of "Anchor" left (gap: 200) below "Anchor" top (gap: \#(y))"#
        }
        // The anchor at (40, 40); the bands stacked down from (240, 40), 40 apart.
        _ = try drawnInProcess(#"sticky-note "Anchor" size: 160x100 inside view top-left"#, on: editor)
        _ = try drawnInProcess([band("Band 1", 200, 0), band("Band 2", 240, 240), band("Band 3", 280, 520)].joined(separator: "\n"), on: editor)
        _ = try drawnInProcess(["One", "Two", "Three"].enumerated().map { #"sticky-note "\#($1)" size: 160x100 in "Band \#($0 + 1)""# }
            .joined(separator: "\n"), on: editor)
        @MainActor func shape(_ title: String) throws -> AnyShapeRecord { try require(editor.document.shapes.first { $0[TitleProperty.self] == title }) }
        // Turned upside down: Band 3 over all of where Band 1 was and some of Band 2, Band 1 over some of Band 3.
        let result = try drawnInProcess([band("Band 3", 280, 0), band("Band 2", 240, 320), band("Band 1", 200, 600)].joined(separator: "\n"), on: editor)
        expectEqual(result["changes"]?.arrayValue?.compactMap { $0["pushedPast"] }, [])
        expectEqual(result["warnings"]?.arrayValue?.compactMap { $0["message"]?.stringValue } ?? [], [])
        let bands = try ["Band 1", "Band 2", "Band 3"].map(shape)
        expectEqual(bands.map(\.box), [CGRect(x: 240, y: 640, width: 600, height: 200), CGRect(x: 240, y: 360, width: 600, height: 240),
                                       CGRect(x: 240, y: 40, width: 600, height: 280)])
        let notes = try ["One", "Two", "Three"].map(shape)
        expectEqual(notes.map(\.box), [CGRect(x: 280, y: 680, width: 160, height: 100), CGRect(x: 280, y: 400, width: 160, height: 100),
                                       CGRect(x: 280, y: 80, width: 160, height: 100)], "each 40 in from its band's top-left still")
        expectEqual(notes.map { editor.holder(of: $0.id) }, bands.map(\.id))
        expectEqual(bands.map { editor.holder(of: $0.id) }, [nil, nil, nil])
    },
    test("in the app's canvas view, a note mentions a titled frame from the @ picker; the frame's panel lists it, its menu shows what does, and following it goes to it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let scheduler = ManualScheduler()
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: scheduler, pasteboard: pasteboard, model: ScriptedLanguageModel())
        let (window, _) = windowed(editor)
        var frame = ShapeRecord(Frame(frame: CGRect(x: 500, y: 100, width: 400, height: 300)))
        frame[TitleProperty.self] = "Sprint 3"
        editor.transact { $0.insert(frame) }
        let note = editor.add(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: "See "))
        editor.selection = note
        expect(editor.beginEditing(note))
        let text = try require(window.firstResponder as? MentionTextView<AnyMentionable>, "the note's editor has the keyboard")
        text.setSelectedRange(NSRange(location: 4, length: 0))
        window.type("@spr")
        let picker = try require(text.picker, "the picker is open")
        expectEqual(picker.highlightedCandidate?.id, frame.id)
        window.pressReturn()
        window.pressEscape()
        expectEqual(editor.document[note]?.typed(as: StickyNote.self)?.props.text,
                    MentionText([.text("See "), .mention(frame.id, label: "Sprint 3"), .text(" ")]))
        expectEqual(editor.mentionPills(of: note).map(\.isLive), [true])
        let layout = try require(editor.detailPanel?.layout(for: try require(editor.document[frame.id])))
        expect(layout.tabs.map(\.title).contains("Mentioned In"), "\(layout.tabs.map(\.title))")
        expectEqual(editor.mentions?.backlinks(of: frame.id).map(\.id), [note])
        editor.selection = note
        editor.mentions?.follow(frame.id)
        scheduler.advance(by: .milliseconds(0))
        expectEqual(editor.selection, frame.id, "followed: gone to")
    },
])
