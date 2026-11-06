import AppKit
import Boards
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Chrome
import Clipboard
import CoreGraphics
import Foundation
import LanguageModels
import Locking
import Mentions
import Publishing
import References
import Selection
import ShippedTesting
import StickyNotes
import Subboards
import TableOfContents
import TestKit
import Titles

// Mentions as shipped in a file of boards: notes on the root and inside a subboard that mention
// each other and a titled note, followed, renamed, deleted with their board, undone, copied as a tree,
// moved by cut and paste, and drawn by `canvas draw`.

/// A file as shipped: on the root, subboard "Plans", a note titled "Ship it", and a note mentioning
/// note Alpha (by the name "Old alpha"); on Plans' board, Alpha, and a note mentioning Alpha and
/// Ship it.
@MainActor private struct PlansFile {
    let plans = ShapeID(), ship = ShapeID(), outer = ShapeID(), alpha = ShapeID(), beta = ShapeID()
    var plansBoard: BoardID { BoardID(owner: plans) }

    var file: CanvasFile {
        var plans = ShapeRecord(id: plans, Subboard(frame: CGRect(x: 100, y: 400, width: 240, height: 160)))
        plans[TitleProperty.self] = "Plans"
        var ship = ShapeRecord(id: ship, StickyNote(frame: CGRect(x: 400, y: 100, width: 200, height: 200), text: MentionText(plain: "Launch")))
        ship[TitleProperty.self] = "Ship it"
        let outer = ShapeRecord(id: outer, StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200),
                                                      text: MentionText([.text("See "), .mention(alpha, label: "Old alpha")])))
        let alpha = ShapeRecord(id: alpha, StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: MentionText(plain: "Alpha")))
        let beta = ShapeRecord(id: beta, StickyNote(frame: CGRect(x: 300, y: 0, width: 200, height: 200),
                                                    text: MentionText([.text("After "), .mention(alpha.id, label: "Alpha"), .text(", "),
                                                                       .mention(ship.id, label: "Ship it")])))
        return CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(plans), AnyShapeRecord(ship), AnyShapeRecord(outer)]),
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

    /// The shape's row.
    fileprivate func contentsRow(_ id: ShapeID) -> String? {
        tableOfContents?.entries.first { $0.id == id }?.label?.text
    }

    fileprivate func setText(_ id: ShapeID, _ text: String) {
        transact { $0.update(id, as: StickyNote.self) { $0.props.text = MentionText(plain: text) } }
    }
}

@MainActor let mentionsBoardsTests = Suite("Mentions in a file of boards, as shipped", [
    test("a shape on an untitled subboard's board is on \"Untitled Subboard\", as the path says it, in the @ picker's line and a reference's") {
        let f = PlansFile()
        let h = try f.harness(ShippedPlugins.pasteboard)
        h.editor.transact { $0.update(f.plans) { $0[TitleProperty.self] = nil } }
        expectEqual(h.editor.name(of: f.plansBoard), "Untitled Subboard", "the path's")
        expectEqual(try require(h.editor.mentions).boardName(ofShape: f.alpha), "Untitled Subboard", "the @ picker's line")
        expect(h.enter(f.plans))
        h.editor.goToEnclosingBoard()
        var props = Reference(frame: CGRect(origin: CGPoint(x: 600, y: 400), size: Reference.defaultSize))
        ReferenceEdits.pick(&props, ReferenceTarget(id: f.alpha, label: "Alpha"))
        let pill = h.editor.add(props)
        let references = try require(h.editor.references)
        expectEqual(references.header(of: props, id: pill).subtitle, "Note · Untitled Subboard", "the reference's header")
        _ = renderBitmap(h.editor, size: CGSize(width: 1000, height: 700))
        expectEqual(references.drawnPlaceSteps(of: pill)?.map(\.name), ["Untitled Subboard"], "and its pill")
    },
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
        expectEqual(h.editor.contentsRow(f.beta), "After @Alpha, @Ship it", "and the note on the root, from inside")
        h.editor.setText(f.alpha, "Alpha plan")
        h.editor.goToEnclosingBoard()
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.contentsRow(f.outer), "See @Alpha plan")
        expectEqual(mentions.resolve(f.alpha).appearance?.label, "Alpha plan")

        // Ship it renamed on the root: Plans' row, kept, is made again on going back in.
        h.editor.transact { $0.update(f.ship) { $0[TitleProperty.self] = "Shipped" } }
        expect(h.enter(f.plans))
        expectEqual(h.editor.contentsRow(f.beta), "After @Alpha plan, @Shipped")
        h.editor.goToEnclosingBoard()

        // Undoing the rename of Ship it, then Alpha's, which shows Plans first.
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

    test("a note mentions a subboard by its title, picked with @ on its board; a double-click on the pill enters it, and Back returns to the note") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let f = PlansFile()
        let h = try f.harness(pasteboard)
        let mentions = try require(h.editor.mentions)
        expectEqual(mentions.candidates(matching: "Plans", in: AnyMentionable.self, for: f.outer).all.first?.id, f.plans)
        h.editor.transact { $0.update(f.outer, as: StickyNote.self) { $0.props.text = MentionText([.text("In "), .mention(f.plans, label: "Plans")]) } }
        let pill = try require(h.editor.mentionPills(of: f.outer).first)
        expect(pill.isLive)
        h.editor.lock([f.outer])                                    // a double-click on an editable note's pill is its text view's
        h.click(at: h.view(CGPoint(x: pill.frame.midX, y: pill.frame.midY)), clickCount: 2)
        expectEqual(h.editor.board, f.plansBoard)
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
                                                              .mention(f.ship, label: "Ship it")]),
                    "inside, the copy named, and Ship it, not copied, as it was")
        expectEqual(h.editor.contentsRow(outerCopy), "See @Alpha")
        expectEqual(h.editor.mentions?.resolve(alphaCopy).appearance?.label, "Alpha")
        expectEqual(h.editor.text(of: f.beta)?.mentioned, [f.alpha, f.ship], "the originals as they were")

        // Plans alone.
        h.editor.selectedShapeIDs = [f.plans]
        h.editor.copySelection()
        before = h.editor.document
        h.editor.paste()
        pasted = h.editor.shapes(since: before)
        plansCopy = try require(pasted.first?.id)
        inside = h.editor.contents(of: BoardID(owner: plansCopy)).shapes.map(\.id)
        (alphaCopy, betaCopy) = (inside[0], inside[1])
        expectEqual(h.editor.text(of: betaCopy)?.mentioned, [alphaCopy, f.ship])

        // The root's note alone: still the note inside Plans, live.
        h.editor.selectedShapeIDs = [f.outer]
        h.editor.copySelection()
        before = h.editor.document
        h.editor.paste()
        let alone = try require(h.editor.shapes(since: before).first?.id)
        expectEqual(h.editor.text(of: alone)?.mentioned, [f.alpha])
        expectEqual(h.editor.contentsRow(alone), "See @Alpha")
    },

    test("moving a subboard by cut and paste keeps every id, so a mention from outside it of a note inside, missing after the cut, is live again after the paste; undoing the paste, missing; undoing the cut, live") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let f = PlansFile()
        let h = try f.harness(pasteboard)
        let original = h.editor.file
        expectEqual(h.editor.contentsRow(f.outer), "See @Alpha")
        h.editor.selectedShapeIDs = [f.plans]
        h.editor.perform(.cut)
        expectEqual(h.editor.file.record(f.alpha), nil, "cut with Plans")
        expectEqual(h.editor.mentions?.resolve(f.alpha), .missing)
        expectEqual(h.editor.contentsRow(f.outer), "See @Old alpha")
        expectEqual(h.editor.mentionPills(of: f.outer).map(\.isLive), [false])
        h.editor.perform(.paste)
        expectEqual(h.editor.selection, f.plans, "Plans itself, moved")
        expectEqual(h.editor.contents(of: f.plansBoard).shapes.map(\.id), [f.alpha, f.beta])
        expectEqual(h.editor.text(of: f.beta)?.mentioned, [f.alpha, f.ship])
        expectEqual(h.editor.text(of: f.outer)?.mentioned, [f.alpha])
        expect(h.editor.mentions?.resolve(f.alpha).isLive == true)
        expectEqual(h.editor.contentsRow(f.outer), "See @Alpha")
        expectEqual(h.editor.mentionPills(of: f.outer).map(\.isLive), [true])
        h.editor.undo()
        expectEqual(h.editor.mentions?.resolve(f.alpha), .missing)
        expectEqual(h.editor.contentsRow(f.outer), "See @Old alpha")
        expectEqual(h.editor.mentionPills(of: f.outer).map(\.isLive), [false])
        h.editor.undo()
        expectEqual(h.editor.contentsRow(f.outer), "See @Alpha")
        expectEqual(h.editor.mentionPills(of: f.outer).map(\.isLive), [true])
        expectEqual(h.editor.file, original, "as it was")
    },

    test("a note cut inside a subboard and pasted on the root is the same note: a mention of it there is live again, and going to it stays on the root") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let f = PlansFile()
        let h = try f.harness(pasteboard)
        expect(h.enter(f.plans))
        h.editor.selection = f.alpha
        h.editor.perform(.cut)
        expectEqual(h.editor.text(of: f.beta)?.mentioned, [f.alpha, f.ship], "beside it, the name stays")
        expectEqual(h.editor.mentionPills(of: f.beta).map(\.isLive), [false, true])
        h.editor.goToEnclosingBoard()
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.contentsRow(f.outer), "See @Old alpha")
        h.editor.perform(.paste)
        expectEqual(h.editor.file.board(containing: f.alpha), .root)
        expectEqual(h.editor.file.record(f.alpha)?.copiedFrom, nil)
        expectEqual(h.editor.contentsRow(f.outer), "See @Alpha")
        expectEqual(h.editor.mentionPills(of: f.outer).map(\.isLive), [true])
        h.editor.selection = nil
        let mentions = try require(h.editor.mentions)
        mentions.follow(f.alpha)
        h.wait(0)
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.selection, f.alpha)
        expect(h.enter(f.plans))
        expectEqual(h.editor.mentionPills(of: f.beta).map(\.isLive), [true, true], "live again, of the note on the root")
        expect(h.editor.mentions?.resolve(f.alpha).isLive == true)
    },

    test("canvas draw sticky-note mentioning a note inside a subboard: made without a warning, its pill live, and its row following the note") {
        try configureBoards()
        let nest = NestedFile()
        let board = try nestedDocument()
        defer { board.close() }
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
