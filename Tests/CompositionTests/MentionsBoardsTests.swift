import AppKit
import Boards
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Clipboard
import Composition
import CoreGraphics
import Foundation
import LanguageModels
import Locking
import Mentions
import Selection
import StickyNotes
import Subboards
import TableOfContents
import TaskCards
import TestKit
import Titles

// Mentions as shipped in a file of boards: notes on the root and inside a subboard that mention
// each other and a task, followed, renamed, deleted with their board, undone, copied as a tree,
// and drawn by `canvas draw`.

/// A file as shipped: on the root, subboard "Plans", task "Ship it", and a note mentioning note
/// Alpha (by the name "Old alpha"); on Plans' board, Alpha, and a note mentioning Alpha and the
/// task.
@MainActor private struct PlansFile {
    let plans = ShapeID(), task = ShapeID(), outer = ShapeID(), alpha = ShapeID(), beta = ShapeID()
    var plansBoard: BoardID { BoardID(owner: plans) }

    var file: CanvasFile {
        var plans = ShapeRecord(id: plans, Subboard(frame: CGRect(x: 100, y: 400, width: 240, height: 160)))
        plans[TitleProperty.self] = "Plans"
        var task = ShapeRecord(id: task, TaskCard(frame: CGRect(x: 400, y: 100, width: 240, height: 200)))
        task[TitleProperty.self] = "Ship it"
        let outer = ShapeRecord(id: outer, StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200),
                                                      text: MentionText([.text("See "), .mention(alpha, label: "Old alpha")])))
        let alpha = ShapeRecord(id: alpha, StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: MentionText(plain: "Alpha")))
        let beta = ShapeRecord(id: beta, StickyNote(frame: CGRect(x: 300, y: 0, width: 200, height: 200),
                                                    text: MentionText([.text("After "), .mention(alpha.id, label: "Alpha"), .text(", "),
                                                                       .mention(task.id, label: "Ship it")])))
        return CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(plans), AnyShapeRecord(task), AnyShapeRecord(outer)]),
                          children: [plans.id: CanvasDocument(shapes: [AnyShapeRecord(alpha), AnyShapeRecord(beta)])])
    }

    /// The file in an editor of the shipped plugins, its clipboard on `pasteboard`, on a 1000 × 700 view.
    func harness(_ pasteboard: NSPasteboard) throws -> EditorHarness {
        let file = file
        let h = try EditorHarness { scheduler in
            CanvasEditor(registry: try ShippedPlugins.registry(pasteboard: pasteboard, model: ScriptedLanguageModel()), file: file, scheduler: scheduler)
        }
        h.editor.viewportDidResize(to: CGSize(width: 1000, height: 700))
        return h
    }
}

extension CanvasEditor {
    /// The note's text, on whatever board it is.
    fileprivate func text(of id: ShapeID) -> MentionText? { file.record(id)?.typed(as: StickyNote.self)?.props.text }

    /// The shape's row, with every row listed (going up selects the board's owner, which would list
    /// only it).
    fileprivate func contentsRow(_ id: ShapeID) -> String? {
        tableOfContents?.showAll()
        return tableOfContents?.entries.first { $0.id == id }?.label?.text
    }

    fileprivate func setText(_ id: ShapeID, _ text: String) {
        transact { $0.update(id, as: StickyNote.self) { $0.props.text = MentionText(plain: text) } }
    }
}

@MainActor let mentionsBoardsTests = Suite("Mentions in a file of boards, as shipped", [
    test("rows and pills that name notes on other boards stay right across switches: renamed away, undone, deleted with their board, undone") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let f = PlansFile()
        let h = try f.harness(pasteboard)
        let mentions = try require(h.editor.mentions)
        expectEqual(h.editor.contentsRow(f.outer), "See @Alpha", "the note inside Plans, by its name now")
        expectEqual(h.editor.mentionPills(of: f.outer).map(\.isLive), [true])

        // Alpha renamed inside Plans: the root's row, kept, is made again on going back up.
        expect(h.enter(f.plans))
        expectEqual(h.editor.contentsRow(f.beta), "After @Alpha, @Ship it", "and the task on the root, from inside")
        h.editor.setText(f.alpha, "Alpha plan")
        h.editor.goToEnclosingBoard()
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.contentsRow(f.outer), "See @Alpha plan")
        expectEqual(mentions.resolve(f.alpha).appearance?.label, "Alpha plan")

        // The task renamed on the root: Plans' row, kept, is made again on going back in.
        h.editor.transact { $0.update(f.task) { $0[TitleProperty.self] = "Shipped" } }
        expect(h.enter(f.plans))
        expectEqual(h.editor.contentsRow(f.beta), "After @Alpha plan, @Shipped")
        h.editor.goToEnclosingBoard()

        // Undoing the task's rename, then Alpha's, which shows Plans first.
        h.editor.undo()
        h.editor.undo()
        expectEqual(h.editor.board, f.plansBoard)
        expectEqual(h.editor.contentsRow(f.beta), "After @Alpha, @Ship it")
        h.editor.goToEnclosingBoard()
        expectEqual(h.editor.contentsRow(f.outer), "See @Alpha")

        // Plans deleted takes Alpha: the name the text holds, dashed; undone, live again.
        h.editor.transact { $0.delete([f.plans]) }
        expectEqual(mentions.resolve(f.alpha), .missing)
        expectEqual(h.editor.contentsRow(f.outer), "See @Old alpha")
        expectEqual(h.editor.mentionPills(of: f.outer).map(\.isLive), [false])
        h.editor.undo()
        expectEqual(h.editor.contentsRow(f.outer), "See @Alpha")
        expectEqual(h.editor.mentionPills(of: f.outer).map(\.isLive), [true])
    },

    test("a double-click on a locked note's pill naming a note inside a subboard opens the subboard there with the note selected; Back returns") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let f = PlansFile()
        let h = try f.harness(pasteboard)
        h.editor.lock([f.outer])
        let pill = try require(h.editor.mentionPills(of: f.outer).first)
        h.click(at: h.view(CGPoint(x: pill.frame.midX, y: pill.frame.midY)), clickCount: 2)
        expectEqual(h.editor.board, f.plansBoard)
        expectEqual(h.editor.selection, f.alpha)
        expectEqual(h.editor.boardPath, [.root, f.plansBoard])
        h.editor.goBack()
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.selection, f.outer)
    },

    test("copying a subboard with a note that mentions one beside it: every copy mentions the copies copied with it, on any board of the tree, and the rest what it did") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let f = PlansFile()
        let h = try f.harness(pasteboard)

        // Plans and the root's note together.
        h.editor.selectedShapeIDs = [f.plans, f.outer]
        h.editor.copySelection()
        var before = h.editor.document
        h.editor.paste()
        var pasted = h.editor.shapes(since: before)
        var plansCopy = try require(pasted.first { $0.kind == Subboard.kind }?.id)
        let outerCopy = try require(pasted.first { $0.kind == StickyNote.kind }?.id)
        var inside = h.editor.contents(of: BoardID(owner: plansCopy)).shapes.map(\.id)
        expectEqual(inside.count, 2)
        var alphaCopy = inside[0], betaCopy = inside[1]
        expectEqual(h.editor.text(of: outerCopy), MentionText([.text("See "), .mention(alphaCopy, label: "Old alpha")]),
                    "the root's copy names the copy of the note inside")
        expectEqual(h.editor.text(of: betaCopy), MentionText([.text("After "), .mention(alphaCopy, label: "Alpha"), .text(", "),
                                                              .mention(f.task, label: "Ship it")]),
                    "inside, the copy named, and the task, not copied, as it was")
        expectEqual(h.editor.contentsRow(outerCopy), "See @Alpha")
        expectEqual(h.editor.mentions?.resolve(alphaCopy).appearance?.label, "Alpha")
        expectEqual(h.editor.text(of: f.beta)?.mentioned, [f.alpha, f.task], "the originals as they were")

        // Plans alone.
        h.editor.selectedShapeIDs = [f.plans]
        h.editor.copySelection()
        before = h.editor.document
        h.editor.paste()
        pasted = h.editor.shapes(since: before)
        plansCopy = try require(pasted.first?.id)
        inside = h.editor.contents(of: BoardID(owner: plansCopy)).shapes.map(\.id)
        (alphaCopy, betaCopy) = (inside[0], inside[1])
        expectEqual(h.editor.text(of: betaCopy)?.mentioned, [alphaCopy, f.task])

        // The root's note alone: still the note inside Plans, live.
        h.editor.selectedShapeIDs = [f.outer]
        h.editor.copySelection()
        before = h.editor.document
        h.editor.paste()
        let alone = try require(h.editor.shapes(since: before).first?.id)
        expectEqual(h.editor.text(of: alone)?.mentioned, [f.alpha])
        expectEqual(h.editor.contentsRow(alone), "See @Alpha")
    },

    test("moving a subboard by cut and paste gives what it holds new ids, so a mention from outside it of a note inside names the note cut, missing (not built yet); undoing both brings it back") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let f = PlansFile()
        let h = try f.harness(pasteboard)
        expectEqual(h.editor.contentsRow(f.outer), "See @Alpha")
        h.editor.selectedShapeIDs = [f.plans]
        h.editor.perform(.cut)
        expectEqual(h.editor.file.record(f.alpha), nil, "cut with Plans")
        let before = h.editor.document
        h.editor.perform(.paste)
        let plansCopy = try require(h.editor.shapes(since: before).first?.id)
        let inside = h.editor.contents(of: BoardID(owner: plansCopy)).shapes.map(\.id)
        expectEqual(inside.count, 2)
        expect(!inside.contains(f.alpha), "a paste gets new ids, even of what a cut took")
        expectEqual(h.editor.text(of: inside[1])?.mentioned, [inside[0], f.task], "inside, the copy of Alpha named, as a copy does")
        expectEqual(h.editor.text(of: f.outer)?.mentioned, [f.alpha], "outside, the note cut, which nothing renames")
        expectEqual(h.editor.mentions?.resolve(f.alpha), .missing)
        expectEqual(h.editor.contentsRow(f.outer), "See @Old alpha")
        expectEqual(h.editor.mentionPills(of: f.outer).map(\.isLive), [false])
        h.editor.undo()
        h.editor.undo()
        expectEqual(h.editor.contentsRow(f.outer), "See @Alpha")
        expectEqual(h.editor.mentionPills(of: f.outer).map(\.isLive), [true])
    },

    test("canvas draw sticky-note mentioning a note inside a subboard: made without a warning, its pill live, and its row following the note") {
        try configureBoards()
        let nest = NestedFile()
        let board = try nestedDocument()
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let (inside, _) = nest.notes(on: 3)
        // Untitled, so its row is its text; found as the shape the draw made, since it names no ids.
        let before = Set(board.editor.document.shapes.map(\.id))
        let result = try canvas(server, ["draw", #"sticky-note text: "See @[Old](shape:\#(inside.rawValue.uuidString))""#])
        expectEqual(result.status, 0, result.error)
        let json = try JSON(text: result.output)
        expectEqual(json["warnings"], [], "the note is in the file, two boards down")
        let id = try require(board.editor.document.shapes.first { !before.contains($0.id) }?.id)
        expectEqual(board.editor.board, .root)
        expectEqual(board.editor.mentionPills(of: id).map(\.isLive), [true])
        expectEqual(board.editor.contentsRow(id), "See @Inside, first")
        board.editor.transact(on: nest.tBoard, "Change") { $0.update(inside, as: StickyNote.self) { $0.props.text = MentionText(plain: "Deep down") } }
        expectEqual(board.editor.contentsRow(id), "See @Deep down")
    },
])
