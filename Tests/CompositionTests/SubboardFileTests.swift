import AppKit
import Arrows
import Boards
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Composition
import CoreGraphics
import Foundation
import Geometry
import LanguageModels
import Mentions
import Selection
import StickyNotes
import Subboards
import TableOfContents
import TestKit
import Titles

/// A file of three boards, each inside the last: the root, subboard S's ("Plans"), and, inside
/// that, untitled subboard T's; on each, two notes and an arrow bound from one to the other. The
/// ids are fixed, so it's the file `Fixtures/files/nested-mentions.v4.json` was written from, once
/// notes' text could hold mentions (`sticky-note` 3), though none of its notes mentions anything,
/// and `nested.v4.json`, from before. With `acrossBoards`, the root's first note mentions T's first
/// (by the name "Old inside") and T's second mentions the root's second ("Old root"), two boards
/// apart each way: `Fixtures/files/nested-mentions-across.v4.json`.
struct NestedFile {
    var acrossBoards = false

    let s = ShapeID(UUID(uuidString: "5B000000-0000-0000-0000-000000000001")!)
    let t = ShapeID(UUID(uuidString: "5B000000-0000-0000-0000-000000000002")!)
    var sBoard: BoardID { BoardID(owner: s) }
    var tBoard: BoardID { BoardID(owner: t) }

    /// The notes on each board: the root's, S's, then T's.
    func notes(on board: Int) -> (ShapeID, ShapeID) {
        (ShapeID(UUID(uuidString: "0000000\(board)-0000-0000-0000-00000000000A")!),
         ShapeID(UUID(uuidString: "0000000\(board)-0000-0000-0000-00000000000B")!))
    }

    func arrow(on board: Int) -> ShapeID { ShapeID(UUID(uuidString: "0000000\(board)-0000-0000-0000-00000000000C")!) }

    /// Board `board`'s two notes, saying `text`, and the arrow from the first to the second.
    private func shapes(on board: Int, _ text: String) -> [AnyShapeRecord] {
        let (a, b) = notes(on: board)
        var first = MentionText(plain: "\(text), first"), second = MentionText(plain: "\(text), second")
        if acrossBoards, board == 1 { first = MentionText([.text("\(text), first, see "), .mention(notes(on: 3).0, label: "Old inside")]) }
        if acrossBoards, board == 3 { second = MentionText([.text("\(text), second, after "), .mention(notes(on: 1).1, label: "Old root")]) }
        func bound(_ id: ShapeID) -> ArrowTerminal {
            .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
        }
        return [AnyShapeRecord(ShapeRecord(id: a, StickyNote(frame: CGRect(x: 80, y: 80, width: 200, height: 200), text: first))),
                AnyShapeRecord(ShapeRecord(id: b, StickyNote(frame: CGRect(x: 460, y: 80, width: 200, height: 200), text: second))),
                AnyShapeRecord(ShapeRecord(id: arrow(on: board), Arrow(start: bound(a), end: bound(b))))]
    }

    var file: CanvasFile {
        var plans = ShapeRecord(id: s, Subboard(frame: CGRect(x: 80, y: 420, width: 240, height: 160)))
        plans[TitleProperty.self] = "Plans"
        let inner = ShapeRecord(id: t, Subboard(frame: CGRect(x: 80, y: 420, width: 240, height: 160)))
        return CanvasFile(root: CanvasDocument(shapes: shapes(on: 1, "Root") + [AnyShapeRecord(plans)]),
                          children: [s: CanvasDocument(shapes: shapes(on: 2, "Plans") + [AnyShapeRecord(inner)]),
                                     t: CanvasDocument(shapes: shapes(on: 3, "Inside"))])
    }

    /// The fixture: the file as this app wrote it.
    static var fixture: Data {
        get throws { try Data(contentsOf: URL(fileURLWithPath: "Tests/CompositionTests/Fixtures/files/nested-mentions.v4.json")) }
    }

    /// The file with mentions across its boards, as this app wrote it.
    static var acrossFixture: Data {
        get throws { try Data(contentsOf: URL(fileURLWithPath: "Tests/CompositionTests/Fixtures/files/nested-mentions-across.v4.json")) }
    }

    /// The file as it was written before sticky notes held mentions (`sticky-note` 2).
    static var olderFixture: Data {
        get throws { try Data(contentsOf: URL(fileURLWithPath: "Tests/CompositionTests/Fixtures/files/nested.v4.json")) }
    }
}

/// A board document holding the nested file, as the fixture opens, with its view remembered in
/// `memory` for `url`.
@MainActor func nestedDocument(memory: BoardViewMemory? = nil, url: URL? = nil) throws -> BoardDocument {
    let board = BoardDocument()
    if let memory { board.viewMemory = memory }
    try board.read(from: NestedFile.fixture, ofType: boardType)
    board.fileURL = url
    return board
}

/// A view memory of its own, in a defaults suite `body` has for itself.
@MainActor func withViewMemory(_ body: (BoardViewMemory, UserDefaults) throws -> Void) throws {
    let suite = "SubboardFileTests-\(UUID().uuidString)"
    let defaults = try require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(BoardViewMemory(defaults: defaults), defaults)
}

@MainActor private func addNote(_ board: BoardDocument, _ text: String) -> ShapeID {
    board.editor.add(StickyNote(frame: CGRect(x: 800, y: 80, width: 200, height: 200), text: MentionText(plain: text)))
}

@MainActor let subboardFileTests = Suite("Subboards in files", [
    test("the nested file reads as it was written, and writes back byte for byte") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let codec = BoardCodec(registry: registry)
        let data = try NestedFile.fixture
        let loaded = try codec.decode(data)
        expectEqual(loaded.file, registry.fillingDefaults(NestedFile().file))
        expect(loaded.report.isEmpty, "\(loaded.report)")
        expectEqual(try codec.encode(loaded.file), data)
    },
    test("the nested file with mentions two boards apart reads as it was written, shows them live opened on either board, and writes back byte for byte") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let codec = BoardCodec(registry: registry)
        let data = try NestedFile.acrossFixture
        let nest = NestedFile(acrossBoards: true)
        let loaded = try codec.decode(data)
        expectEqual(loaded.file, registry.fillingDefaults(nest.file))
        expect(loaded.report.isEmpty, "\(loaded.report)")
        expectEqual(try codec.encode(loaded.file), data)

        let (rootFirst, rootSecond) = nest.notes(on: 1), (insideFirst, insideSecond) = nest.notes(on: 3)
        let editor = CanvasEditor(registry: registry, scheduler: ManualScheduler())
        editor.replaceFile(with: loaded.file, showing: nest.tBoard)
        expectEqual(editor.board, nest.tBoard, "opened on T, two boards down")
        let mentions = try require(editor.mentions)
        @MainActor func row(_ id: ShapeID) -> String? { editor.tableOfContents?.entries.first { $0.id == id }?.label?.text }
        expectEqual(mentions.resolve(rootSecond).appearance?.label, "Root, second", "the root's note, by its name now")
        expectEqual(editor.mentionPills(of: insideSecond).map(\.isLive), [true])
        expectEqual(row(insideSecond), "Inside, second, after @Root, second")
        expect(editor.showBoard(.root))
        expectEqual(mentions.resolve(insideFirst).appearance?.label, "Inside, first")
        expectEqual(editor.mentionPills(of: rootFirst).map(\.isLive), [true])
        expectEqual(row(rootFirst), "Root, first, see @Inside, first")
        expectEqual(try codec.encode(editor.file), data, "as it was read")

        // Opened on the root, as a file opens, then into T through S.
        let opened = CanvasEditor(registry: registry, file: loaded.file, scheduler: ManualScheduler())
        expectEqual(opened.mentionPills(of: rootFirst).map(\.isLive), [true])
        expect(opened.showBoard(nest.sBoard) && opened.showBoard(nest.tBoard))
        expectEqual(opened.mentionPills(of: insideSecond).map(\.isLive), [true])
        expectEqual(opened.tableOfContents?.entries.first { $0.id == insideSecond }?.label?.text, "Inside, second, after @Root, second")
    },
    test("the nested file from before notes held mentions reads, each board's notes brought up to date") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let codec = BoardCodec(registry: registry)
        let loaded = try codec.decode(try NestedFile.olderFixture)
        expectEqual(loaded.file, registry.fillingDefaults(NestedFile().file))
        expect(loaded.report.isEmpty, "\(loaded.report)")
        expectEqual(try codec.encode(loaded.file), try NestedFile.fixture)
    },
    test("saving writes every board, as they are, the one shown or not") {
        try configureBoards()
        let nest = NestedFile()
        let board = try nestedDocument()
        defer { board.close() }
        expect(board.editor.showBoard(nest.sBoard))
        expect(board.editor.showBoard(nest.tBoard))
        let added = addNote(board, "Deep")
        expect(board.editor.showBoard(nest.sBoard))
        let saved = try board.data(ofType: boardType)
        expectEqual(saved, try BoardCodec(registry: board.editor.registry).encode(board.editor.file))

        let reopened = BoardDocument()
        try reopened.read(from: saved, ofType: boardType)
        expectEqual(reopened.editor.file, board.editor.file)
        expectEqual(reopened.editor.board, .root, "a file opens on its root, unless this Mac left it elsewhere")
        expectEqual(reopened.editor.contents(of: nest.tBoard).shapes.map(\.id).last, added)
        expectEqual(Set(reopened.editor.file.children.keys), [nest.s, nest.t])
    },
    test("reopening shows the board left open, each board with the camera it was left with, and no step back to the root") {
        try configureBoards()
        try withViewMemory { memory, _ in
            let nest = NestedFile(), url = URL(fileURLWithPath: "/tmp/nested.canvasboard")
            let board = try nestedDocument(memory: memory, url: url)
            board.makeWindowControllers()
            let root = Camera(origin: CGPoint(x: 10, y: 20), zoom: 0.5), plans = Camera(origin: CGPoint(x: -30, y: 40), zoom: 2)
            let inside = Camera(origin: CGPoint(x: 5, y: 6), zoom: 1.5)
            board.editor.camera = root
            expect(board.editor.showBoard(nest.sBoard))
            board.editor.camera = plans
            expect(board.editor.showBoard(nest.tBoard))
            board.editor.camera = inside
            board.close()
            let view = try require(memory.recall(for: url))
            expectEqual(view.camera, root)
            expectEqual(view.openBoard, nest.tBoard)
            expectEqual(view.cameras, [nest.sBoard: plans, nest.tBoard: inside])

            let reopened = try nestedDocument(memory: memory, url: url)
            reopened.makeWindowControllers()
            defer { reopened.close() }
            expectEqual(reopened.editor.board, nest.tBoard)
            expectEqual(reopened.editor.camera, inside)
            expect(!reopened.editor.canGoBack, "opening there isn't a step")
            expect(!reopened.isDocumentEdited)
            reopened.editor.goToEnclosingBoard()
            expectEqual(reopened.editor.board, nest.sBoard)
            expectEqual(reopened.editor.selectedShapeIDs, [nest.t])
            expectEqual(reopened.editor.camera, plans)
            reopened.editor.goToEnclosingBoard()
            expectEqual(reopened.editor.camera, root)
            expect(!reopened.isDocumentEdited, "going about the boards edits nothing")
        }
    },
    test("a view remembered before files had boards is the root's; one of a board that's gone opens on the root") {
        try configureBoards()
        try withViewMemory { memory, defaults in
            let nest = NestedFile(), url = URL(fileURLWithPath: "/tmp/old.canvasboard")
            let old = #"[{ "path" : "/tmp/old.canvasboard", "view" : { "x" : 1, "y" : 2, "zoom" : 3, "showsDetails" : false, "showsMinimap" : true } }]"#
            defaults.set(Data(old.utf8), forKey: "BoardViews")
            let view = try require(memory.recall(for: url))
            expectEqual(view, BoardViewMemory.View(x: 1, y: 2, zoom: 3, showsDetails: false))
            expectEqual(view.openBoard, nil)
            expectEqual(view.cameras, [:])
            let board = try nestedDocument(memory: memory, url: url)
            board.makeWindowControllers()
            expectEqual(board.editor.board, .root)
            expectEqual(board.editor.camera, Camera(origin: CGPoint(x: 1, y: 2), zoom: 3))
            board.close()
            expectEqual(memory.recall(for: url), BoardViewMemory.View(x: 1, y: 2, zoom: 3, showsDetails: false), "the root's alone: as it was")

            let gone = BoardID(owner: ShapeID())
            memory.remember(BoardViewMemory.View(x: 1, y: 2, zoom: 3, showsDetails: true, board: gone.description,
                                                 boards: [gone.description: .init(x: 0, y: 0, zoom: 4), nest.sBoard.description: .init(x: 7, y: 8, zoom: 2)]), for: url)
            let elsewhere = try nestedDocument(memory: memory, url: url)
            elsewhere.makeWindowControllers()
            expectEqual(elsewhere.editor.board, .root)
            expect(elsewhere.editor.showBoard(nest.sBoard))
            expectEqual(elsewhere.editor.camera, Camera(origin: CGPoint(x: 7, y: 8), zoom: 2), "the rest still remembered")
            elsewhere.close()
            let pruned = try require(memory.recall(for: url))
            expectEqual(pruned.openBoard, nest.sBoard)
            expectEqual(Set(pruned.cameras.keys), [nest.sBoard], "only boards the file can show")
        }
    },
    test("a file's view keeps the cameras of the 50 boards shown most lately, across sessions") {
        try configureBoards()
        try withViewMemory { memory, _ in
            let url = URL(fileURLWithPath: "/tmp/many.canvasboard")
            let owners = (0..<60).map { i in ShapeRecord(Subboard(frame: CGRect(x: CGFloat(i) * 300, y: 0, width: 240, height: 160))) }
            let data = try BoardCodec(registry: try ShippedPlugins.registry(model: ScriptedLanguageModel()))
                .encode(CanvasFile(root: CanvasDocument(shapes: owners.map(AnyShapeRecord.init))))
            @MainActor func open() throws -> BoardDocument {
                let board = BoardDocument()
                board.viewMemory = memory
                try board.read(from: data, ofType: boardType)
                board.fileURL = url
                board.makeWindowControllers()
                return board
            }
            let boards = owners.map { BoardID(owner: $0.id) }
            let first = try open()
            for (i, board) in boards.enumerated() {
                expect(first.editor.showBoard(board))
                first.editor.camera = Camera(origin: CGPoint(x: i, y: 0), zoom: 1)
            }
            first.close()
            let view = try require(memory.recall(for: url))
            expectEqual(view.openBoard, boards[59])
            expectEqual(view.recentBoards, Array(boards[10...].reversed()), "the board shown, then those left, the last first")
            expectEqual(Set(view.cameras.keys), Set(boards[10...]))
            expectEqual(view.cameras[boards[10]], Camera(origin: CGPoint(x: 10, y: 0), zoom: 1))

            let second = try open()
            expectEqual(second.editor.board, boards[59])
            expect(second.editor.showBoard(boards[0]))
            second.close()
            let next = try require(memory.recall(for: url))
            expectEqual(next.recentBoards, [boards[0], boards[59]] + boards[11..<59].reversed(),
                        "this session's, then the last session's as it had them: board 10's, shown longest ago, goes")
        }
    },
    test("reverting inside a board that's gone shows the nearest board above it, unedited") {
        try configureBoards()
        let nest = NestedFile(), url = scratchURL("revert.canvasboard")
        defer { try? FileManager.default.removeItem(at: url) }
        let board = try nestedDocument()
        defer { board.close() }
        expect(board.editor.showBoard(nest.sBoard))
        board.editor.transact("Delete") { $0.delete([nest.t]) }
        try board.data(ofType: boardType).write(to: url)
        board.fileURL = url
        board.editor.undo()
        expect(board.editor.showBoard(nest.tBoard))
        _ = addNote(board, "Unsaved")
        try board.revert(toContentsOf: url, ofType: boardType)
        expectEqual(board.editor.board, nest.sBoard)
        expectEqual(board.editor.file.children[nest.t], nil)
        runLoop { false }
        expect(!board.isDocumentEdited)
    },
    test("Delete Hidden Shapes reaches the shapes kept aside inside subboards, and an opaque owner's boards") {
        try configureBoards()
        let s = ShapeID(), gadget = ShapeID(), box = ShapeID(), note = ShapeID(), inBox = ShapeID()
        func record(_ id: ShapeID, _ kind: String, _ index: String) -> String {
            #"{ "id" : "\#(id)", "index" : "\#(index)", "kind" : "\#(kind)", "props" : { "frame" : [[0, 0], [10, 10]] } }"#
        }
        let json = """
        { "format" : 4, "versions" : { "kinds" : { "subboard" : 0, "sticky-note" : 3 } },
          "shapes" : [ \(record(s, "subboard", "a0")), \(record(box, "gadget-box", "a1")) ],
          "boards" : { "\(s)" : { "shapes" : [ \(record(note, "sticky-note", "a0")), \(record(gadget, "gadget", "a1")) ] },
                       "\(box)" : { "shapes" : [ \(record(inBox, "sticky-note", "a0")) ] } } }
        """
        let board = BoardDocument()
        defer { board.close() }
        try board.read(from: Data(json.utf8), ofType: boardType)
        expectEqual(Set(board.loadReport.keptAside.map(\.id)), [gadget, box])
        expectEqual(board.loadReport.keptBoards.map(\.key), [box.description])
        let summary = try require(board.loadReport.summary)
        expect(summary.details.contains("1 board in this file can’t be opened (1 shape on it)"), summary.details)
        expect(board.editor.canShow(BoardID(owner: s)))
        expect(!board.editor.canShow(BoardID(owner: box)), "its owner is kept aside")

        board.deleteHiddenShapes()
        expectEqual(board.editor.document.shapes.map(\.id), [s])
        expectEqual(board.editor.contents(of: BoardID(owner: s)).shapes.map(\.id), [note])
        expectEqual(Set(board.editor.file.children.keys), [s])
        expect(board.isDocumentEdited)
        board.editor.undo()
        expect(!board.isDocumentEdited, "one step, undone")
        expectEqual(board.editor.contents(of: BoardID(owner: s)).shapes.map(\.id), [note, gadget])
    },
    test("editing inside a subboard marks the file edited; going in and out doesn't") {
        try configureBoards()
        let nest = NestedFile()
        let board = try nestedDocument()
        defer { board.close() }
        runLoop { false }
        expect(board.editor.showBoard(nest.sBoard))
        expect(board.editor.showBoard(nest.tBoard))
        board.editor.goToEnclosingBoard()
        expect(!board.isDocumentEdited)
        let (first, _) = nest.notes(on: 2)
        board.editor.transact("Move") { $0.update(first, as: StickyNote.self) { $0.frame.origin.x += 40 } }
        expect(board.isDocumentEdited)
        board.editor.goToEnclosingBoard()
        board.editor.undo()
        expectEqual(board.editor.board, nest.sBoard, "undoing shows the board the step was made on")
        expect(!board.isDocumentEdited)
    },
])
