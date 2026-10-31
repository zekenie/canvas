import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Clipboard
import CoreGraphics
import Foundation
import LanguageModels
import Locking
import Mentions
import Queries
import Selection
import ShippedTesting
import StickyNotes
import TableOfContents
import TestKit
import Titles
import Topology
import Types
import Validation

// The shipped plugins on a file with boards, until a kind of their own owns one: CanvasTesting's
// pocket, opened by showing its board.

/// Opens a pocket by showing its board.
@MainActor private func openingPockets() -> Contributor {
    Contributor(id: "opening-pockets") { r in
        r.opens(Pocket.self, "Open") { pocket, editor in editor.showBoard(BoardID(owner: pocket.id)) }
    }
}

/// A pocket on the root, and a note on its board.
@MainActor private func pocketWithNote() -> (file: CanvasFile, pocket: ShapeID, note: ShapeID) {
    let pocket = ShapeRecord(Pocket(CGRect(x: 100, y: 100, width: 160, height: 100)))
    let note = ShapeRecord(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: "Inside"))
    let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(pocket)]),
                          children: [pocket.id: CanvasDocument(shapes: [AnyShapeRecord(note)])])
    return (file, pocket.id, note.id)
}

/// The shipped plugins, then pockets and `more`, on `file`, their clipboard on `pasteboard`, their
/// model `model`.
@MainActor private func shippedWithPockets(_ file: CanvasFile, pasteboard: NSPasteboard, model: ScriptedLanguageModel = ScriptedLanguageModel(),
                                           more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try EditorHarness { scheduler in
        CanvasEditor(registry: try Registry(plugins: ShippedPlugins.plugins(pasteboard: pasteboard, model: model) + [PocketsPlugin(), openingPockets()] + more),
                     file: file, scheduler: scheduler)
    }
}

/// A watcher, last of the plugins, that keeps whether each switch's change set had been worked out.
@MainActor private func watching(_ watch: ChangeSetWatch) -> Contributor {
    Contributor(id: "watch") { r in r.service { _ in ChangeSetWatcher(watch: watch) } }
}

/// Keeps whether each switch's change set had been worked out by the time it heard of it.
@MainActor private final class ChangeSetWatch {
    var workedOut: [Bool] = []
}

private final class ChangeSetWatcher {
    let watch: ChangeSetWatch
    init(watch: ChangeSetWatch) { self.watch = watch }
}

extension ChangeSetWatcher: EditorService {
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        #if DEBUG
        watch.workedOut.append(change.hasWorkedOutChanges)
        #endif
    }
}

@MainActor let boardsTests = Suite("Boards, as shipped", [
    test("no shipped service works out a switch's change set: each follows a switch on its own") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let watch = ChangeSetWatch()
        let (file, pocket, _) = pocketWithNote()
        // Services hear a switch in plugin order: the watcher, last, hears it after every shipped one.
        let h = try shippedWithPockets(file, pasteboard: pasteboard,
                                       more: [Contributor(id: "watch") { r in r.service { _ in ChangeSetWatcher(watch: watch) } }])
        h.editor.selection = pocket
        expect(h.key("\r"))
        expectEqual(h.editor.board, BoardID(owner: pocket))
        h.editor.goBack()
        expectEqual(h.editor.board, .root)
        #if DEBUG
        expectEqual(watch.workedOut, [false, false])
        #endif
    },
    test("queries keep nothing per board: a switch works out no change set for them, and each query after one takes up the board shown") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let watch = ChangeSetWatch()
        let (file, pocket, note) = pocketWithNote()
        let h = try shippedWithPockets(file, pasteboard: pasteboard, more: [watching(watch)])
        let queries = try require(h.editor.queries, "the shipped list answers queries")
        @MainActor func shown() throws -> [ShapeID] {
            try awaitResult { try await queries.run(QueryRequest(":current-board", properties: .none)) }.rows.map(\.id)
        }
        expectEqual(try shown(), [pocket])
        expect(h.enter(pocket))
        expectEqual(try shown(), [note])
        h.editor.goBack()
        expectEqual(h.editor.board, .root)
        expectEqual(try shown(), [pocket])
        #if DEBUG
        expectEqual(watch.workedOut, [false, false])
        expectEqual(queries.captures, 3, "each query takes up the file afresh")
        expectEqual(queries.liveSnapshots, 0, "and none outlives its query")
        #endif
    },
    test("mentions are indexed for the whole file, as it opens (no board's mention text is read on entering it), and the picker finds shapes on every board") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        func note(_ x: CGFloat, _ text: MentionText) -> ShapeRecord<StickyNote> {
            ShapeRecord(StickyNote(frame: CGRect(x: x, y: 0, width: 200, height: 200), text: text))
        }
        let pocket = ShapeRecord(Pocket(CGRect(x: 0, y: 300, width: 160, height: 100)))
        let target = note(0, MentionText(plain: "Target")), deep = note(0, MentionText(plain: "Deep"))
        let outer = note(300, MentionText([.text("See "), .mention(target.id, label: "Target")]))
        let inner = note(300, MentionText([.text("See "), .mention(deep.id, label: "Deep")]))
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(pocket), AnyShapeRecord(target), AnyShapeRecord(outer)]),
                              children: [pocket.id: CanvasDocument(shapes: [AnyShapeRecord(deep), AnyShapeRecord(inner)])])
        let h = try shippedWithPockets(file, pasteboard: pasteboard)
        let mentions = try require(h.editor.mentions)
        expectEqual(mentions.mentioners(of: target.id), [outer.id])
        expectEqual(mentions.mentioners(of: deep.id), [inner.id], "the pocket's note, before its board is ever shown")
        #if DEBUG
        let read = try require(h.editor.topology).recordsRead
        #endif
        h.editor.showBoard(BoardID(owner: pocket.id))
        expectEqual(mentions.mentioners(of: deep.id), [inner.id])
        expectEqual(mentions.mentions(in: outer.id), [target.id],
                    "the root's note, with another board shown: the index is Topology's, the file's (it was the board shown's alone)")
        expectEqual(mentions.candidates(matching: "Deep", in: AnyMentionable.self, for: nil).matches.map(\.id), [deep.id])
        expectEqual(mentions.candidates(matching: "Target", in: AnyMentionable.self, for: nil).matches.map(\.id), [target.id], "on the root")
        h.editor.showBoard(.root)
        expectEqual(mentions.mentions(in: outer.id), [target.id])
        expectEqual(mentions.candidates(matching: "Target", in: AnyMentionable.self, for: nil).matches.map(\.id), [target.id])
        #if DEBUG
        expectEqual(try require(h.editor.topology).recordsRead, read, "no mention text read on going in or back")
        #endif
    },
    test("what main's services keep of a board comes back with it as it was left, and no switch works out a change set") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let watch = ChangeSetWatch()
        let (file, pocket, note) = pocketWithNote()
        let h = try shippedWithPockets(file, pasteboard: pasteboard, more: [watching(watch)])
        h.editor.viewportDidResize(to: CGSize(width: 1000, height: 700))
        expect(h.enter(pocket))
        h.editor.transact { $0.update(note) { $0[TitleProperty.self] = "Inner" } }
        h.editor.lock([note])
        let card = h.editor.addTypeNote("{ \"type\": ", frame: CGRect(x: 300, y: 0, width: 200, height: 200))
        let frames = h.editor.adornmentFrames(of: note)
        expectEqual(frames.count, 2, "the title's pill and the lock")
        let rows = try require(h.editor.tableOfContents).entries.map(\.id)
        let issues = h.editor.validation?.result(for: card)?.issues ?? []
        expect(!issues.isEmpty, "a schema that isn't JSON")
        expect(h.editor.showBoard(.root))
        expectEqual(h.editor.adornmentFrames(of: note), [], "not on the board shown")
        expect(h.enter(pocket))
        expectEqual(h.editor.adornmentFrames(of: note), frames)
        expectEqual(try require(h.editor.tableOfContents).entries.map(\.id), rows)
        expectEqual(h.editor.validation?.result(for: card)?.issues ?? [], issues)
        expect(h.editor.isReadOnly(note))
        h.editor.goBack()
        #if DEBUG
        expectEqual(watch.workedOut, [false, false, false, false])
        #endif
    },
    test("a type note's answer that lands while its board isn't shown is written there, and undoing it shows that board") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let model = ScriptedLanguageModel()
        let (file, pocket, _) = pocketWithNote()
        let h = try shippedWithPockets(file, pasteboard: pasteboard, model: model)
        expect(h.enter(pocket))
        let card = h.editor.addTypeNote(TypeSchemaProperty.starter, frame: CGRect(x: 300, y: 0, width: 200, height: 200))
        h.editor.transact("Typing") { $0.update(card, as: StickyNote.self) { $0.props.text = "a person: name and email" } }
        h.editor.goBack()
        expectEqual(h.editor.board, .root)
        let schema = #"{ "title": "Person", "type": "object", "properties": { "name": { "type": "string" }, "email": { "type": "string" } } }"#
        model.queue(schema)
        h.scheduler.advance(by: TypeSync<TypeSchemaProperty>.idleDelay)
        let kept = #"{ "type": "object", "properties": { "name": { "type": "string" }, "email": { "type": "string" } } }"#
        spinRunLoop(until: { h.editor.schemaText(card) == kept })
        expectEqual(h.file.record(card)?[TitleProperty.self], "Person", "named by the model's title, its schema keeping none")
        expectEqual(h.editor.board, .root, "nothing is shown for it")
        expectEqual(h.editor.undoHistory.undoName, "Update Schema")
        h.editor.undo()
        expectEqual(h.editor.board, BoardID(owner: pocket))
        expectEqual(h.editor.document[card]?[TypeSchemaProperty.self]?.text, TypeSchemaProperty.starter)
    },
    test("a locked note inside a copied pocket pastes locked, and holds the pocket from being cut") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let (file, pocket, note) = pocketWithNote()
        let h = try shippedWithPockets(file, pasteboard: pasteboard)
        h.editor.showBoard(BoardID(owner: pocket))
        h.editor.lock([note])
        h.editor.showBoard(.root)
        h.editor.selection = pocket
        h.hold(.command)
        expect(h.key("x"))
        expect(h.editor.document[pocket] != nil, "the lock inside refuses the pocket's deletion")
        let before = Set(h.editor.document.shapes.map(\.id))
        expect(h.key("v"))
        h.hold([])
        let copy = try require(h.editor.document.shapes.first { !before.contains($0.id) })
        expectEqual(copy.copiedFrom, pocket)
        let inside = h.editor.file[BoardID(owner: copy.id)].shapes
        expectEqual(inside.map(\.copiedFrom), [note])
        expect(inside.allSatisfy(\.isLocked), "the copy of a locked note is locked")
    },
    test("a type note cut from a pocket and pasted on the root is the same note there: its row and its issues go with it, and the pocket's list, taken back, doesn't have it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let (file, pocket, note) = pocketWithNote()
        let h = try shippedWithPockets(file, pasteboard: pasteboard)
        let contents = try require(h.editor.tableOfContents)
        expect(h.enter(pocket))
        let card = h.editor.addTypeNote("{ \"type\": ", frame: CGRect(x: 300, y: 0, width: 200, height: 200))
        let issues = h.editor.validation?.result(for: card)?.issues ?? []
        expect(!issues.isEmpty, "a schema that isn't JSON")
        expectEqual(contents.entries.map(\.id), [note, card])
        expect(h.editor.showBoard(.root))
        expect(h.enter(pocket))
        h.editor.selection = card
        h.editor.perform(.cut)
        expectEqual(contents.entries.map(\.id), [note])
        expect(h.editor.showBoard(.root))
        h.editor.perform(.paste)
        expectEqual(h.editor.selection, card)
        expectEqual(h.editor.file.board(containing: card), .root)
        expectEqual(contents.entries.map(\.id), [pocket, card])
        expectEqual(h.editor.validation?.result(for: card)?.issues ?? [], issues)
        expect(h.enter(pocket))
        expectEqual(contents.entries.map(\.id), [note], "the pocket's rows, as the cut left them")
    },
])
