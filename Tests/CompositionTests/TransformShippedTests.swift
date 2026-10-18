import Adornments
import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import DetailPanel
import Frames
import LanguageModels
import Locking
import Mentions
import Selection
import ShippedTesting
import SlashCommands
import StickyNotes
import Subboards
import TableOfContents
import TestKit
import Titles
import Topology
import Transform
import Validation

// Turning as shipped: a frame into a subboard, from its context menu and as a command, with everything
// the app has around it: a note that mentions the frame, arrows bound to what it holds, a lock, and a
// file that has to read back. The camera is at the origin at 100%, so view points are world units.

/// Frame Groceries, 900 × 700 from (100, 100), holding notes Milk and Eggs and a frame, Dairy, which holds
/// note Cheese; an arrow from Milk to Eggs and another from Milk to Receipt, a note beside the frame that
/// mentions Groceries.
@MainActor private struct Groceries {
    let h: EditorHarness
    let frame: ShapeID, milk: ShapeID, eggs: ShapeID, dairy: ShapeID, cheese: ShapeID, receipt: ShapeID, between: ShapeID, out: ShapeID

    /// The frame's top edge, where it's pressed, since a frame that holds shapes is pressed only on its border.
    let edge = CGPoint(x: 500, y: 101)

    init(_ pasteboard: NSPasteboard) {
        h = EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0, pasteboard: pasteboard, model: ScriptedLanguageModel()) }
        func note(_ x: CGFloat, _ y: CGFloat, _ text: MentionText) -> ShapeRecord<StickyNote> {
            ShapeRecord(StickyNote(frame: CGRect(x: x, y: y, width: 200, height: 200), text: text))
        }
        func bound(_ id: ShapeID) -> ArrowTerminal {
            .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
        }
        var groceries = ShapeRecord(Frame(frame: CGRect(x: 100, y: 100, width: 900, height: 700)))
        groceries[TitleProperty.self] = "Groceries"
        var dairyFrame = ShapeRecord(Frame(frame: CGRect(x: 130, y: 400, width: 400, height: 360)))
        dairyFrame[TitleProperty.self] = "Dairy"
        let milkNote = note(130, 130, "Milk"), eggsNote = note(400, 130, "Eggs"), cheeseNote = note(150, 430, "Cheese")
        let receiptNote = note(1100, 100, MentionText([.text("See "), .mention(groceries.id, label: "Groceries")]))
        let betweenArrow = ShapeRecord(Arrow(start: bound(milkNote.id), end: bound(eggsNote.id)))
        let outArrow = ShapeRecord(Arrow(start: bound(milkNote.id), end: bound(receiptNote.id)))
        frame = groceries.id
        milk = milkNote.id
        eggs = eggsNote.id
        dairy = dairyFrame.id
        cheese = cheeseNote.id
        receipt = receiptNote.id
        between = betweenArrow.id
        out = outArrow.id
        // Back to front, as they're drawn: the frame, what it holds, then what's beside it and the arrows.
        h.editor.transact { transaction in
            transaction.insert(groceries)
            transaction.insert(milkNote)
            transaction.insert(eggsNote)
            transaction.insert(dairyFrame)
            transaction.insert(cheeseNote)
            transaction.insert(receiptNote)
            transaction.insert(betweenArrow)
            transaction.insert(outArrow)
        }
        h.editor.put([milk, eggs, dairy], in: frame)
        h.editor.put([cheese], in: dairy)
    }

    /// What the table of contents says a shape is, on the board shown: it lists every shape (`showAll`), whatever
    /// is selected, as it lists the selection alone otherwise.
    func row(_ id: ShapeID) -> String? {
        h.editor.tableOfContents?.showAll()
        return h.editor.tableOfContents?.entries.first { $0.id == id }?.label?.text
    }

    /// An arrow's ends' bindings, from the file, wherever the arrow is.
    func ends(of arrow: ShapeID) -> (start: ShapeID?, end: ShapeID?)? {
        h.file.record(arrow)?.typed(as: Arrow.self).map { ($0.props.start.binding?.shapeID, $0.props.end.binding?.shapeID) }
    }
}

@MainActor let transformShippedTests = Suite("Turning, as shipped", [
    test("a frame's menu has Turn into Subboard, after Show What Mentions and before the clipboard's: choosing it makes the frame a 240 × 160 subboard at its corner, titled Groceries, holding on its board what it held, with the mention of it, and the arrow between its notes, still good; Undo takes it all back") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let g = Groceries(pasteboard)
        let h = g.h
        let mentions = try require(h.editor.mentions), topology = try require(h.editor.topology)
        expectEqual(mentions.resolve(g.frame).appearance?.systemImage, "rectangle.dashed")
        expectEqual(g.row(g.receipt), "See @Groceries")
        expectEqual(h.editor.adornmentFrames(of: g.frame).map(\.label), [AdornmentLabel("Groceries")], "a frame's pill has no symbol")
        let panel = try require(h.editor.detailPanel)
        expectEqual(panel.layout(for: try require(h.editor.document[g.frame])).tabs.map(\.title), ["Connections", "Style"])
        expectEqual(h.editor.transforms?.targets(of: g.frame), [Subboard.kind])
        let children = topology.children(of: g.frame), dairysChildren = topology.children(of: g.dairy)
        expectEqual(Set(children), [g.milk, g.eggs, g.dairy])
        expectEqual(dairysChildren, [g.cheese])

        h.editor.selection = g.frame
        h.move(to: g.edge)
        let size = CGSize(width: 1400, height: 900)
        let eggs = CGRect(x: 400, y: 130, width: 200, height: 200), lowerRight = CGRect(x: 600, y: 450, width: 350, height: 300)
        let before = h.file, framed = renderBitmap(h.editor, size: size)
        let menu = try require(h.secondaryClick(at: g.edge))
        let item = try require(menu.outline.firstIndex(of: "Turn into Subboard"), "\(menu.outline)")
        expectEqual(menu.outline[item - 2 ... item + 4], ["Show What Mentions", "—", "Turn into Subboard", "—", "Create Frame", "—", "Cut"],
                    "its own band, between the mention's and Create Frame's, before the clipboard's")
        expectEqual(h.editor.selectedShapeIDs, [g.frame])
        try menu.choose("Turn into Subboard")

        let subboard = try require(h.file.record(g.frame))
        expectEqual(subboard.kind, Subboard.kind, "the frame's id is a subboard")
        expectEqual(subboard.box, CGRect(x: 100, y: 100, width: 240, height: 160), "a subboard's size at the frame's corner")
        expectEqual(subboard[TitleProperty.self], "Groceries")
        expectEqual(h.editor.document.shapes.map(\.id), [g.frame, g.receipt, g.out], "the notes and the frame inside are off this board")
        let board = h.file[BoardID(owner: g.frame)]
        expectEqual(board.shapes.map(\.id), [g.milk, g.eggs, g.dairy, g.cheese, g.between], "on its board, in the order they were")
        expectEqual(board.shapes.map(\.kind), [StickyNote.kind, StickyNote.kind, Frame.kind, StickyNote.kind, Arrow.kind], "the frame inside is still a frame")
        expectEqual(board[g.cheese]?.container, g.dairy, "holding its note")
        expectEqual(board[g.dairy]?.container, nil)
        expectEqual(board[g.dairy]?[TitleProperty.self], "Dairy")
        expectEqual(board[g.milk]?.box, before.record(g.milk)?.box, "where it was")
        expectEqual(board[g.cheese]?.box, before.record(g.cheese)?.box)

        expectEqual(mentions.resolve(g.frame).appearance?.label, "Groceries", "what mentions it names it still")
        expectEqual(mentions.resolve(g.frame).appearance?.systemImage, "rectangle.stack", "as a subboard now")
        expect(mentions.resolve(g.frame).isLive)
        expectEqual(h.editor.mentionPills(of: g.receipt).map(\.isLive), [true])
        expectEqual(g.row(g.receipt), "See @Groceries")
        expectEqual(mentions.mentioners(of: g.frame), [g.receipt])
        expectEqual(g.row(g.frame), "Groceries")
        expectEqual(h.editor.tableOfContents?.entries.first { $0.id == g.frame }?.label?.systemImage, "rectangle.stack")
        expectEqual(h.editor.adornmentFrames(of: g.frame).map(\.label), [AdornmentLabel("Groceries", systemImage: "rectangle.stack")], "its pill has the subboard's symbol")
        let layout = panel.layout(for: try require(h.editor.document[g.frame]))
        expectEqual(layout.tabs.map(\.title), ["Description", "Connections", "Style"], "the panel's tabs are a subboard's")
        expectEqual(layout.header(as: TitleHeader.self)?.placeholder, "Untitled Subboard")
        expectEqual(topology.children(of: g.frame), children + [g.between], "containment is the tree it was, a subboard's shapes inside it as a frame's were, and now the arrow too")
        expectEqual(topology.children(of: g.dairy), dairysChildren)
        expectEqual(topology.parent(of: g.dairy), g.frame)
        expectEqual(g.ends(of: g.between)?.start, g.milk, "an arrow between two of its notes rode along, bound")
        expectEqual(g.ends(of: g.between)?.end, g.eggs)
        expectEqual(h.file.board(containing: g.between), BoardID(owner: g.frame))
        expectEqual(g.ends(of: g.out)?.start, nil, "one to a note outside let go of its end on a note that moved, where it's drawn")
        expectEqual(g.ends(of: g.out)?.end, g.receipt)
        expectEqual(h.file.board(containing: g.out), .root)
        expectEqual(h.editor.undoHistory.undoName, "Turn into Subboard")
        expectEqual(h.editor.selectedShapeIDs, [g.frame], "still selected")
        let turned = renderBitmap(h.editor, size: size)
        expect(changedPixels(framed, turned, in: eggs) > 1000, "Eggs isn't on this board, and the frame's surface is gone")
        expect(changedPixels(framed, turned, in: lowerRight) > 1000, "nor is the frame's surface under it")

        let after = h.file
        h.editor.undo()
        expectEqual(h.file, before, "the frame, every shape in it, and every binding")
        expectEqual(mentions.resolve(g.frame).appearance?.systemImage, "rectangle.dashed")
        expectEqual(topology.children(of: g.frame), children)
        expectEqual(changedPixels(framed, renderBitmap(h.editor, size: size), in: eggs), 0, "drawn as it was")
        expectEqual(changedPixels(framed, renderBitmap(h.editor, size: size), in: lowerRight), 0)
        h.editor.redo()
        expectEqual(h.file, after, "and the subboard again")
        expect(h.enter(g.frame), "which opens onto its board")
        expectEqual(h.editor.document.shapes.map(\.id), [g.milk, g.eggs, g.dairy, g.cheese, g.between])
        expectEqual(h.editor.holder(of: g.cheese), g.dairy)
        expect(h.editor.showBoard(.root))

        // The file as the app saves it reads back as it is, and writes back byte for byte.
        let codec = BoardCodec(registry: h.editor.registry)
        let data = try codec.encode(h.file)
        let loaded = try codec.decode(data)
        expectEqual(loaded.file, h.file)
        expect(loaded.report.isEmpty, "\(loaded.report)")
        expectEqual(try codec.encode(loaded.file), data)
    },

    test("/turn-into-subboard is offered on a frame, before the commands a text view lists for what has text: running it makes the same step the menu's item does") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let g = Groceries(pasteboard)
        let h = g.h
        let state = try require(h.editor.slashCommands)
        expectEqual(state.commands(for: g.frame).map(\.name), ["turn-into-subboard", "title", "lock", "public", "color", "move-to", "move-near"], "a command is placed where its plugin is: Subboards' is before Titles', Locking's, Publishing's and Moving's")
        expectEqual(state.commands(for: g.milk).map(\.name), ["title", "lock", "public", "is-a", "color", "move-to", "move-near"], "a note has nothing to turn into")
        expectEqual(state.commands(for: g.frame).first?.title, "Turn into Subboard")
        let before = h.file
        h.editor.selectedShapeIDs = [g.frame, g.milk]
        expect(state.run("turn-into-subboard", on: g.frame, with: SlashArguments([])))
        expectEqual(h.editor.document[g.frame]?.kind, Subboard.kind)
        expectEqual(h.editor.selectedShapeIDs, [g.frame], "a selected note it moved off the board leaves the selection")
        expectEqual(h.editor.undoHistory.undoName, "Turn into Subboard")
        expectEqual(h.file[BoardID(owner: g.frame)].shapes.map(\.id), [g.milk, g.eggs, g.dairy, g.cheese, g.between])
        expectEqual(state.commands(for: g.frame).map(\.name), ["title", "lock", "public", "color", "move-to", "move-near"], "a subboard has nothing to turn into either")
        expect(!state.run("turn-into-subboard", on: g.frame, with: SlashArguments([])))
        expect(!state.run("turn-into-subboard", on: g.frame, with: "now"), "it takes no arguments")
        h.editor.undo()
        expectEqual(h.file, before)
        expect(!state.run("turn-into-subboard", on: g.frame, with: "now"), "nor with arguments, before it was turned")
        expectEqual(h.editor.document[g.frame]?.kind, Frame.kind)
    },

    test("a frame that holds a locked note, or a locked frame, is left as it is: nothing changes, no step is made, and the locked shape shakes") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let g = Groceries(pasteboard)
        let h = g.h
        let transforms = try require(h.editor.transforms)
        h.editor.lock([g.cheese])
        let step = h.editor.undoHistory.undoName, before = h.file, revision = h.editor.revision
        h.editor.selection = g.frame
        let menu = try require(h.secondaryClick(at: g.edge))
        expect(menu.outline.contains("Turn into Subboard"), "the item is there: what stops it is the lock")
        try menu.choose("Turn into Subboard")
        expectEqual(h.file, before, "a locked note in the frame inside it keeps all of it where it is")
        expectEqual(h.editor.revision, revision, "nothing committed")
        expectEqual(h.editor.undoHistory.undoName, step, "no step")
        h.wait(16)
        expect(h.editor.drawingOffset(of: g.cheese) != .zero, "the locked note shakes")
        expectEqual(h.editor.drawingOffset(of: g.milk), .zero, "and no other")
        expect(!transforms.turn([g.frame], into: Subboard.kind))
        expectEqual(h.file, before)

        h.wait(500)
        h.editor.unlock([g.cheese])
        h.editor.lock([g.frame])
        let locked = h.file
        expect(!transforms.turn([g.frame], into: Subboard.kind), "a locked frame")
        expectEqual(h.file, locked)
        h.wait(16)
        expect(h.editor.drawingOffset(of: g.frame) != .zero, "the frame shakes")
        expect(!transforms.turn([g.dairy], into: Subboard.kind), "the frame inside it is locked with it")
        expectEqual(h.file, locked)

        h.wait(500)
        h.editor.unlock([g.frame])
        expect(transforms.turn([g.frame], into: Subboard.kind), "unlocked, it turns")
        expectEqual(h.editor.document[g.frame]?.kind, Subboard.kind)
    },

    test("a frame whose notes a locked arrow joins is left as it is, as for a locked note in it: nothing changes, no step is made, and the arrow shakes; unlocked, the arrow goes with the notes, and Undo and Redo are exact") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let g = Groceries(pasteboard)
        let h = g.h
        let transforms = try require(h.editor.transforms)
        h.editor.lock([g.between])
        expect(h.editor.isReadOnly(g.between), "the arrow is locked")
        let step = h.editor.undoHistory.undoName, before = h.file, revision = h.editor.revision
        expect(!transforms.turn([g.frame], into: Subboard.kind), "refused: the locked arrow would be left behind")
        expectEqual(h.file, before, "nothing changed")
        expectEqual(h.editor.revision, revision, "nothing committed")
        expectEqual(h.editor.undoHistory.undoName, step, "no step")
        h.wait(16)
        expect(h.editor.drawingOffset(of: g.between) != .zero, "the locked arrow shakes")

        h.wait(500)
        h.editor.unlock([g.between])
        let unlocked = h.file
        expect(transforms.turn([g.frame], into: Subboard.kind), "unlocked, it turns")
        expectEqual(h.file.board(containing: g.between), BoardID(owner: g.frame), "and the arrow with the notes")
        expect(g.ends(of: g.between)?.start == g.milk && g.ends(of: g.between)?.end == g.eggs, "bound at both ends")
        let after = h.file
        h.editor.undo()
        expectEqual(h.file, unlocked, "undo")
        h.editor.redo()
        expectEqual(h.file, after, "redo")
    },

    test("a frame and the frame inside it, selected together, both turn, the inner one first: its subboard, with its note, is on the outer one's board") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let g = Groceries(pasteboard)
        let h = g.h
        let before = h.file
        h.editor.selectedShapeIDs = [g.frame, g.dairy]
        let menu = try require(h.secondaryClick(at: g.edge))
        expect(menu.outline.contains("Turn into Subboard"), "\(menu.outline)")
        try menu.choose("Turn into Subboard")
        expectEqual(h.editor.document.shapes.map(\.id), [g.frame, g.receipt, g.out])
        expectEqual(h.file[BoardID(owner: g.frame)].shapes.map(\.id), [g.milk, g.eggs, g.dairy, g.between])
        expectEqual(h.file[BoardID(owner: g.dairy)].shapes.map(\.id), [g.cheese])
        expectEqual(h.file.record(g.dairy)?.kind, Subboard.kind, "the frame inside is a subboard too")
        expectEqual(h.file.record(g.dairy)?[TitleProperty.self], "Dairy")
        expectEqual(h.file.record(g.dairy)?.box, CGRect(x: 130, y: 400, width: 240, height: 160), "at its own corner")
        expectEqual(h.file.path(to: BoardID(owner: g.dairy)), [.root, BoardID(owner: g.frame), BoardID(owner: g.dairy)])
        expectEqual(h.file.record(g.dairy)?.container, nil, "it isn't in the subboard it moved onto")
        expectEqual(h.editor.undoHistory.undoName, "Turn into Subboard")
        h.editor.undo()
        expectEqual(h.file, before, "one step")
    },

    test("a frame on a subboard's board turns there, its own board one deeper in the file; Undo from the root shows the board it was made on and brings the frame back") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var plans = ShapeRecord(Subboard(frame: CGRect(x: 80, y: 420, width: 240, height: 160)))
        plans[TitleProperty.self] = "Plans"
        var sprint = ShapeRecord(Frame(frame: CGRect(x: 100, y: 100, width: 500, height: 300)))
        sprint[TitleProperty.self] = "Sprint"
        let note = ShapeRecord(StickyNote(frame: CGRect(x: 130, y: 130, width: 200, height: 200), text: "Ship it"))
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(plans)]),
                              children: [plans.id: CanvasDocument(shapes: [AnyShapeRecord(sprint), AnyShapeRecord(note).copy(as: note.id, container: sprint.id)])])
        let h = try EditorHarness { scheduler in
            CanvasEditor(registry: try ShippedPlugins.registry(pasteboard: pasteboard, model: ScriptedLanguageModel()), file: file, scheduler: scheduler)
        }
        let before = h.file, plansBoard = BoardID(owner: plans.id)
        expect(h.enter(plans.id))
        try require(h.secondaryClick(at: CGPoint(x: 350, y: 101))).choose("Turn into Subboard")
        expectEqual(h.editor.board, plansBoard, "still on the board it was turned on")
        expectEqual(h.editor.document.shapes.map(\.id), [sprint.id])
        expectEqual(h.editor.document[sprint.id]?.kind, Subboard.kind)
        expectEqual(h.file[BoardID(owner: sprint.id)].shapes.map(\.id), [note.id])
        expectEqual(h.file.path(to: BoardID(owner: sprint.id)), [.root, plansBoard, BoardID(owner: sprint.id)], "one board deeper")
        expectEqual(h.editor.mentions?.resolve(sprint.id).appearance?.label, "Sprint")
        let after = h.file

        expect(h.editor.showBoard(.root))
        h.editor.undo()
        expectEqual(h.editor.board, plansBoard, "undoing a step made on another board shows it")
        expectEqual(h.file, before)
        expectEqual(h.editor.document[sprint.id]?.kind, Frame.kind)
        expectEqual(h.editor.holder(of: note.id), sprint.id)
        h.editor.redo()
        expectEqual(h.file, after)
    },

    test("a frame holding a frame that holds a note and a subboard with a board of its own, and a type note, turns: every id is in the tree of boards where it was, the subboard's board with it; the locked frame beside it can't") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let frames = FrameFile()
        let h = try EditorHarness { scheduler in
            CanvasEditor(registry: try ShippedPlugins.registry(pasteboard: pasteboard, model: ScriptedLanguageModel()), file: frames.file, scheduler: scheduler)
        }
        let before = h.file
        let transforms = try require(h.editor.transforms)
        expect(!transforms.turn([frames.done], into: Subboard.kind), "Done is locked")
        expectEqual(h.file, before)

        expect(transforms.turn([frames.roadmap], into: Subboard.kind))
        expectEqual(h.editor.document.shapes.map(\.id), [frames.roadmap, frames.done, frames.shipped])
        expectEqual(h.file[BoardID(owner: frames.roadmap)].shapes.map(\.id), [frames.sprint, frames.interview, frames.research, frames.order])
        expectEqual(h.file[BoardID(owner: frames.research)].shapes.map(\.id), [frames.inside], "Research's board went with it")
        expectEqual(h.file.path(to: BoardID(owner: frames.research)), [.root, BoardID(owner: frames.roadmap), BoardID(owner: frames.research)])
        expectEqual(h.file.record(frames.roadmap)?[TitleProperty.self], "Roadmap")
        expectEqual(h.file.record(frames.roadmap)?.box, CGRect(x: 100, y: 100, width: 240, height: 160))
        expectEqual(h.file.record(frames.sprint)?.kind, Frame.kind, "Sprint 3 is still a frame, holding its note and Research")
        expectEqual(h.file[BoardID(owner: frames.roadmap)].shapes.map(\.container), [nil, frames.sprint, frames.sprint, nil])
        expect(h.enter(frames.roadmap) && h.enter(frames.research), "both open")
        expectEqual(h.editor.document.shapes.map(\.id), [frames.inside])
        expect(h.editor.showBoard(.root))
        expectEqual(h.editor.mentions?.resolve(frames.roadmap).appearance?.label, "Roadmap")
        expectEqual(h.editor.validation?.results.count, 0, "nothing the turn moved is flagged")

        let codec = BoardCodec(registry: h.editor.registry)
        let data = try codec.encode(h.file)
        let loaded = try codec.decode(data)
        expectEqual(loaded.file, h.file)
        expect(loaded.report.isEmpty, "\(loaded.report)")
        expectEqual(try codec.encode(loaded.file), data)

        h.editor.undo()
        expectEqual(h.file, before, "the file as it was")
    },
])
