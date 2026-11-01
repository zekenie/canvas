import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Geometry
import TestKit

// The editor shows one board of its file at a time: `showBoard` goes to another, as a first-class
// step of its own, and keeps what it worked out about the boards shown lately for going back.

private let unit = CGRect(x: 0, y: 0, width: 100, height: 100)

private func box(_ id: ShapeID = ShapeID(), _ frame: CGRect = unit) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Box(frame))) }
private func pocket(_ id: ShapeID, _ frame: CGRect = unit) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Pocket(frame))) }
private func marker(_ id: ShapeID) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Marker(host: nil))) }
private func board(_ records: AnyShapeRecord...) -> CanvasDocument { CanvasDocument(shapes: records) }
private func ids(_ document: CanvasDocument) -> [ShapeID] { document.shapes.map(\.id) }

/// A root holding box A and pocket P, and P's board holding box B and pocket Q, whose board holds
/// box C. Pocket E, on the root, has an empty board.
private struct BoardTree {
    let a = ShapeID(), p = ShapeID(), b = ShapeID(), q = ShapeID(), c = ShapeID(), e = ShapeID()
    var file: CanvasFile {
        CanvasFile(root: board(box(a), pocket(p, CGRect(x: 200, y: 0, width: 100, height: 100)), pocket(e, CGRect(x: 400, y: 0, width: 100, height: 100))),
                   children: [p: board(box(b, CGRect(x: 1000, y: 1000, width: 200, height: 100)), pocket(q)),
                              q: board(box(c, CGRect(x: -500, y: -500, width: 100, height: 100)))])
    }
    var pBoard: BoardID { BoardID(owner: p) }
    var qBoard: BoardID { BoardID(owner: q) }
}

@MainActor private func harness(_ file: CanvasFile, _ more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin()] + more, file: file)
}

@MainActor private final class SwitchLog {
    var events: [String] = []
    var changes: [BoardChange] = []
}

/// Logs what services hear of switches, and keeps each `BoardChange` without reading its change set.
private final class SwitchListener {
    let log: SwitchLog
    init(log: SwitchLog) { self.log = log }
}

extension SwitchListener: EditorService {
    func boardWillChange(from old: BoardID, to new: BoardID, in editor: CanvasEditor) {
        log.events.append("will \(old) → \(new), showing \(editor.board)")
    }
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        log.events.append("did \(change.from) → \(change.to), showing \(editor.board)")
        log.changes.append(change)
    }
    func toolDidChange(from old: ToolID, to new: ToolID, in editor: CanvasEditor) { log.events.append("tool \(old) → \(new)") }
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) { log.events.append("document") }
}

/// A tool and a press that note when they're cancelled.
private final class CancelNotingTool {
    let log: SwitchLog
    init(log: SwitchLog) { self.log = log }
}

extension CancelNotingTool: Tool {
    func pointerDown(_ pointer: Pointer, in editor: CanvasEditor) {}
    func cancel(in editor: CanvasEditor) -> Bool {
        log.events.append("tool cancelled")
        return true
    }
}

private final class CancelNotingSession {
    let log: SwitchLog
    init(log: SwitchLog) { self.log = log }
}

extension CancelNotingSession: Session {
    func drag(_ pointer: Pointer, in editor: CanvasEditor) {}
    func cancel(in editor: CanvasEditor) -> Bool {
        log.events.append("session cancelled")
        return true
    }
}

@MainActor private func listening(_ log: SwitchLog) -> Contributor {
    Contributor(id: "listener") { r in r.service { _ in SwitchListener(log: log) } }
}

/// A host that notes what the editor tells it, and saves the card being edited as editing ends, as
/// an editing view that saves on close does.
private final class SwitchSavingHost: CanvasEditorDelegate {
    let log: SwitchLog
    var editing: ShapeID?
    init(log: SwitchLog) { self.log = log }
    func editorNeedsDisplay(_ editor: CanvasEditor) {}
    func editorCursorDidChange(_ editor: CanvasEditor) {}
    func editorEditingDidChange(_ editor: CanvasEditor) {
        if let editing, editor.editingShapeID == nil {
            log.events.append("editing ended")
            editor.transact { $0.update(editing, as: Card.self) { $0.props.text = "saved on \(editor.board)" } }
        }
        editing = editor.editingShapeID
    }
    func editorBoardDidChange(_ editor: CanvasEditor) { log.events.append("host: \(editor.board)") }
}

/// A box that owns a board and notes, as it's drawn, how many shapes its board holds.
private struct Tally: BoxShapeProps {
    static let kind: ShapeKind = "tally"
    static let properties = Properties<Tally> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
}

extension Tally {
    init() { self.init(frame: .zero) }
}

@MainActor private final class TallyLog {
    var counts: [ShapeID: Int] = [:]
}

private struct TallyDefinition {
    let log: TallyLog
}

extension TallyDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Tally>, in context: RenderContext) {
        log.counts[shape.id] = context.shapeCount(inBoardOwnedBy: shape.id)
    }
}

extension TallyDefinition: BoardOwning {}

private func uuid(_ n: Int) -> String { String(format: "00000000-0000-0000-0000-%012d", n) }

@MainActor let boardSwitchTests = Suite("Showing a board", [
    test("showing a board makes it the document: only its shapes are drawn, hit and in the paint order") {
        let log = IndexLog()
        let rootMarker = ShapeID(), inner = ShapeID(), p = ShapeID()
        let h = try harness(CanvasFile(root: board(marker(rootMarker), pocket(p, CGRect(x: 200, y: 0, width: 100, height: 100))),
                                       children: [p: board(marker(inner))]), [IndexKinds(log: log)])
        expectEqual(h.editor.shape(at: CGPoint(x: 250, y: 50)), p)
        expect(h.enter(p))
        expectEqual(h.editor.board, BoardID(owner: p))
        expectEqual(h.editor.boardPath, [.root, BoardID(owner: p)])
        expectEqual(ids(h.editor.document), [inner])
        expectEqual(h.editor.paintOrder().map(\.id), [inner])
        expectEqual(h.editor.shape(at: CGPoint(x: 250, y: 50)), nil, "the root's pocket isn't here")
        expectEqual(h.editor.shape(at: .zero), inner)
        log.renders = []
        _ = renderBitmap(h.editor, size: CGSize(width: 400, height: 300))
        expectEqual(log.renders, [inner])
        expectEqual(h.file.root.shapes.count, 2, "the root is still in the file")

        let added = h.add(Box(unit))
        expectEqual(h.file.board(containing: added), BoardID(owner: p), "a commit is on the board shown")
        h.editor.transact { expectEqual($0.board, BoardID(owner: p)) }
        expect(h.editor.showBoard(.root))
        expectEqual(ids(h.editor.document), [rootMarker, p])
        expectEqual(h.editor.boardPath, [BoardID.root])
    },
    test("which boards can be shown: the root, and a board every owner above which is in the file, of a kind that owns boards") {
        let tree = BoardTree(), stray = ShapeID()
        var file = tree.file
        file.set(board(box()), for: BoardID(owner: tree.a))            // a box's "board": the box isn't BoardOwning
        file.set(board(box()), for: BoardID(owner: stray))             // no owner in the file
        let h = try harness(file)
        expect(h.editor.canShow(.root))
        expect(h.editor.canShow(tree.pBoard))
        expect(h.editor.canShow(tree.qBoard), "a board under a board")
        expect(h.editor.canShow(BoardID(owner: tree.e)), "a board with no shapes yet")
        expect(!h.editor.canShow(BoardID(owner: tree.a)), "not a box's")
        expect(!h.editor.canShow(BoardID(owner: stray)), "not one no shape in the file owns")
        expect(!h.editor.canShow(BoardID(owner: ShapeID())), "nor one of nothing")
        expect(!h.enter(tree.a))
        expectEqual(h.editor.board, .root)

        let json = """
        { "format" : 4, "versions" : { "kinds" : { "box" : 0, "pocket" : 0 } },
          "shapes" : [ { "id" : "\(uuid(1))", "kind" : "gadget", "index" : "a0", "props" : { } } ],
          "boards" : { "\(uuid(1))" : { "shapes" : [ { "id" : "\(uuid(2))", "kind" : "pocket", "index" : "a0", "props" : { "frame" : [[0, 0], [10, 10]] } } ] } } }
        """
        let registry = try Registry(plugins: [FixturesPlugin(), PocketsPlugin()])
        let loaded = try BoardCodec(registry: registry).decode(Data(json.utf8))
        let kept = try harness(loaded.file)
        let gadget = ShapeID(UUID(uuidString: uuid(1))!), inside = ShapeID(UUID(uuidString: uuid(2))!)
        expect(!kept.editor.canShow(BoardID(owner: gadget)), "not a board whose owner is kept aside")
        expect(!kept.editor.canShow(BoardID(owner: inside)), "nor a board under it")
    },
    test("services hear the board is about to change while it's still shown, then that it did, once each, and the tool is the default") {
        let tree = BoardTree(), log = SwitchLog()
        let h = try harness(tree.file, [listening(log), Contributor(id: "probe") { r in
            r.tool(ToolDescriptor(id: "probe", label: "Probe", systemImage: "circle")) { _ in CancelNotingTool(log: log) }
        }])
        h.editor.setTool("probe")
        log.events = []
        let revision = h.editor.revision
        h.enter(tree.p)
        expectEqual(log.events, ["will root → \(tree.p), showing root", "tool probe → hand", "did root → \(tree.p), showing \(tree.p)"],
                    "the tool is left, not cancelled: nothing was under way")
        expectEqual(h.editor.currentToolID, .hand)
        expectEqual(h.editor.revision, revision + 1, "one revision")
        let change = try require(log.changes.last)
        expectEqual(change.from, .root)
        expectEqual(change.to, tree.pBoard)
        log.events = []
        h.enter(tree.p)
        expectEqual(log.events, [], "already shown: nothing happens")
        expectEqual(h.editor.revision, revision + 1)
        h.editor.showBoard(tree.qBoard)
        expectEqual(log.events, ["will \(tree.p) → \(tree.q), showing \(tree.p)", "did \(tree.p) → \(tree.q), showing \(tree.q)"],
                    "with the default tool already, no tool change")
    },
    test("by default a service hears nothing of a switch; one that follows it as a commit hears every shape of one board taken away and every shape of the other brought") {
        let tree = BoardTree(), changes = ChangeLog(), log = SwitchLog(), plain = ServiceLog()
        let h = try harness(tree.file, [recordingChanges(changes), listening(log),
                                        Contributor(id: "plain") { $0.service { _ in LoggingService(log: plain) } }])
        h.enter(tree.p)
        expect(!plain.events.contains("document"), "a service that only follows commits hears no switch")
        let heard = try require(changes.changes.last)
        expectEqual(heard.removed, [tree.a, tree.p, tree.e])
        expectEqual(heard.added, [tree.b, tree.q])
        expectEqual(heard.changed, [])
        expect(heard.reordered)
        expect(try require(log.changes.last).hasWorkedOutChanges)
    },
    test("a switch doesn't work out its change set unless a service reads it") {
        let tree = BoardTree(), log = SwitchLog()
        let h = try harness(tree.file, [listening(log)])
        h.enter(tree.p)
        let change = try require(log.changes.last)
        expect(!change.hasWorkedOutChanges)
        expectEqual(change.changes.added, [tree.b, tree.q])
        expect(change.hasWorkedOutChanges)
    },
    test("a switch to a board of a file put in place names a shape on both boards as changed, never as removed and added") {
        let p = ShapeID(), x = ShapeID(), changes = ChangeLog()
        let h = try harness(CanvasFile(root: board(pocket(p)), children: [p: board(box(x))]), [recordingChanges(changes)])
        h.enter(p)
        h.editor.replaceFile(with: CanvasFile(root: board(box(x), box())))
        expectEqual(h.editor.board, .root, "P is gone")
        let heard = try require(changes.changes.last)
        expectEqual(heard.changed, [x])
        expectEqual(heard.removed, [])
        expectEqual(heard.added.count, 1)
        expect(!heard.added.contains(x))
    },
    test("a switch clears the hint and the shapes drawn away from where they are") {
        let tree = BoardTree()
        let h = try harness(tree.file)
        h.editor.hintedShapeID = tree.a
        h.editor.setDrawingOffset(CGPoint(x: 5, y: 0), for: tree.a)
        expectEqual(h.editor.hintedShapeID, tree.a)
        h.enter(tree.p)
        expectEqual(h.editor.hintedShapeID, nil)
        h.editor.showBoard(.root)
        expectEqual(h.editor.hintedShapeID, nil, "not outlined again on the way back")
        expectEqual(h.editor.drawingOffset(of: tree.a), .zero, "nor drawn away")
    },
    test("no board changes while a press is under way") {
        let tree = BoardTree(), log = SwitchLog()
        let h = try harness(tree.file, [listening(log)])
        h.editor.session = CancelNotingSession(log: log)
        expect(!h.enter(tree.p))
        expectEqual(h.editor.board, .root)
        expectEqual(log.events, [], "the press isn't cancelled either")
        h.editor.session = nil
        expect(h.enter(tree.p))
    },
    test("editing ends before the switch, once services have heard it's coming, and what saves on closing saves on its own board") {
        let log = SwitchLog(), p = ShapeID(), card = ShapeID()
        let h = try harness(CanvasFile(root: board(AnyShapeRecord(ShapeRecord(id: card, Card(unit))), pocket(p))), [CardsPlugin(), listening(log)])
        let host = SwitchSavingHost(log: log)
        h.editor.delegate = host
        expect(h.editor.beginEditing(card))
        log.events = []
        h.enter(p)
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(log.events.filter { !$0.hasPrefix("document") }, ["will root → \(p), showing root", "editing ended", "did root → \(p), showing \(p)", "host: \(p)"])
        expectEqual(h.file.record(card)?.typed(as: Card.self)?.props.text, "saved on root")
        withExtendedLifetime(host) {}
    },
    test("each board keeps its camera; a first visit fits the board's shapes, no closer than 100%, and an empty board starts where a board does") {
        let tree = BoardTree()
        let h = try harness(tree.file)
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        let rootCamera = Camera(origin: CGPoint(x: 30, y: 40), zoom: 2)
        h.editor.camera = rootCamera
        h.enter(tree.p)
        // B spans (0, 0) to (1200, 1100) with Q: it fits at 536 / 1100, centered.
        let fit = Camera(fitting: CGRect(x: 0, y: 0, width: 1200, height: 1100), in: CGSize(width: 800, height: 600), inset: 64, maxZoom: 1)
        expectEqual(h.editor.camera, fit)
        expect(fit.zoom < 1)
        h.editor.camera.pan(by: CGSize(width: 10, height: 0))
        let pCamera = h.editor.camera
        h.editor.showBoard(tree.qBoard)
        expectEqual(h.editor.camera, Camera(origin: CGPoint(x: -450 - 400, y: -450 - 300), zoom: 1), "one small box: 100%, centered on it")
        h.editor.showBoard(.root)
        expectEqual(h.editor.camera, rootCamera)
        h.enter(tree.p)
        expectEqual(h.editor.camera, pCamera)
        h.editor.showBoard(.root)
        h.enter(tree.e)
        expectEqual(h.editor.camera, Camera(), "no shapes")

        let headless = try harness(tree.file)
        headless.enter(tree.p)
        expectEqual(headless.editor.camera, Camera(), "no view to fit into")
    },
    test("a first visit's fit and Zoom to Fit leave clear what the host covers of the view's top on that board") {
        let tree = BoardTree()
        let h = try harness(tree.file)
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        h.editor.coveredTop = { $0.isRoot ? 0 : 35 }
        expectEqual(h.editor.unobscuredViewport, CGRect(x: 0, y: 0, width: 800, height: 600), "nothing covered on the root")
        h.enter(tree.p)
        expectEqual(h.editor.unobscuredViewport, CGRect(x: 0, y: 35, width: 800, height: 565))
        let clear = CGRect(x: 0, y: 35, width: 800, height: 565)
        expectEqual(h.editor.camera, Camera(fitting: CGRect(x: 0, y: 0, width: 1200, height: 1100), in: clear, inset: 64, maxZoom: 1))
        expectClose(h.editor.camera.toView(CGPoint(x: 600, y: 0)).y, 35 + 32, within: 1e-9)
        h.editor.camera = Camera()
        h.editor.perform(.zoomToFit)
        h.wait(320)
        expectEqual(h.editor.camera, Camera(fitting: CGRect(x: 0, y: 0, width: 1200, height: 1100), in: clear, inset: 64))
    },
    test("a fit leaves clear what the host's chrome covers along the view's edges, and what its views over the canvas cover under the top's") {
        let tree = BoardTree()
        let h = try harness(tree.file)
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        h.editor.coveredEdges = CoveredEdges(top: 52, left: 240, right: 260)
        h.editor.coveredTop = { $0.isRoot ? 0 : 35 }
        expectEqual(h.editor.unobscuredViewport, CGRect(x: 240, y: 52, width: 300, height: 548), "on the root, the chrome alone")
        h.enter(tree.p)
        let clear = CGRect(x: 240, y: 87, width: 300, height: 513)
        expectEqual(h.editor.unobscuredViewport, clear, "inside, the path's pill too, under the title bar's row")
        expectEqual(h.editor.camera, Camera(fitting: CGRect(x: 0, y: 0, width: 1200, height: 1100), in: clear, inset: 64, maxZoom: 1))
        h.editor.coveredEdges = CoveredEdges(left: 900)
        expectEqual(h.editor.unobscuredViewport.width, 1, "covered all over, a point is left")
    },
    test("a camera moving as the board is left stops, and the board keeps where it was headed") {
        let tree = BoardTree()
        let h = try harness(tree.file)
        let target = Camera(origin: CGPoint(x: 500, y: 500), zoom: 1)
        h.editor.animateCamera(to: target, duration: .milliseconds(320))
        h.wait(160)
        h.enter(tree.p)
        let here = h.editor.camera
        h.wait(400)
        expectEqual(h.editor.camera, here, "it stopped")
        h.editor.showBoard(.root)
        expectEqual(h.editor.camera, target)
    },
    test("replacing the file stops a moving camera, and a board it leaves keeps where the camera was headed") {
        let tree = BoardTree()
        let h = try harness(tree.file)
        let target = Camera(origin: CGPoint(x: 500, y: 500), zoom: 1)
        h.editor.animateCamera(to: target, duration: .milliseconds(320))
        h.wait(160)
        h.editor.replaceFile(with: tree.file)
        let here = h.editor.camera
        h.wait(400)
        expectEqual(h.editor.camera, here, "staying on the board, it stopped")

        h.editor.animateCamera(to: target, duration: .milliseconds(320))
        h.wait(160)
        h.editor.replaceFile(with: tree.file, showing: tree.pBoard)
        let there = h.editor.camera
        h.wait(400)
        expectEqual(h.editor.camera, there, "going to another, it stopped")
        h.editor.showBoard(.root)
        expectEqual(h.editor.camera, target)
    },
    test("replacing the file with one that can't show the board shown brings the default tool back before services hear the switch") {
        let tree = BoardTree(), log = SwitchLog()
        let h = try harness(tree.file, [listening(log), Contributor(id: "probe") { r in
            r.tool(ToolDescriptor(id: "probe", label: "Probe", systemImage: "circle")) { _ in CancelNotingTool(log: log) }
        }])
        h.editor.showBoard(tree.qBoard)
        h.editor.setTool("probe")
        log.events = []
        var withoutQ = tree.file
        withoutQ.set(board(box(tree.b)), for: tree.pBoard)
        withoutQ.removeBoards([tree.qBoard])
        h.editor.replaceFile(with: withoutQ)
        expectEqual(h.editor.currentToolID, .hand)
        expectEqual(log.events.filter { !$0.hasPrefix("document") },
                    ["will \(tree.q) → \(tree.p), showing \(tree.q)", "tool probe → hand", "did \(tree.q) → \(tree.p), showing \(tree.p)"])

        h.editor.setTool("probe")
        h.editor.replaceFile(with: withoutQ)
        expectEqual(h.editor.currentToolID, "probe", "staying on the board shown, the tool stays")
    },
    test("the cameras boards were left with, and those the host remembers, are where boards are shown") {
        let tree = BoardTree()
        let h = try harness(tree.file)
        let remembered = Camera(origin: CGPoint(x: 7, y: 8), zoom: 0.5)
        h.editor.rememberedCameras = [tree.pBoard: remembered, tree.qBoard: Camera(zoom: 3)]
        h.editor.camera = Camera(origin: CGPoint(x: 1, y: 2))
        h.enter(tree.p)
        expectEqual(h.editor.camera, remembered)
        h.editor.camera = Camera(origin: CGPoint(x: 9, y: 9))
        expectEqual(h.editor.boardCameras, [.root: Camera(origin: CGPoint(x: 1, y: 2)), tree.pBoard: Camera(origin: CGPoint(x: 9, y: 9)),
                                            tree.qBoard: Camera(zoom: 3)])
        h.editor.showBoard(.root)
        h.enter(tree.p)
        expectEqual(h.editor.camera, Camera(origin: CGPoint(x: 9, y: 9)), "as it was left, over what was remembered")
    },
    test("going back to a board shown lately takes what the editor worked out about it, unless it changed since") {
        let log = IndexLog(), p = ShapeID(), host = ShapeID(), flag = ShapeID()
        let file = CanvasFile(root: board(box(host), AnyShapeRecord(ShapeRecord(id: flag, Marker(host: host))), pocket(p, CGRect(x: 300, y: 0, width: 10, height: 10))),
                              children: [p: board(box())])
        let h = try harness(file, [IndexKinds(log: log)])
        _ = h.editor.paintOrder(in: .infinite)
        let worked = log.geometries.count
        h.enter(p)
        h.editor.showBoard(.root)
        _ = h.editor.paintOrder(in: .infinite)
        expectEqual(log.geometries.count, worked, "the marker's geometry was kept")
        expectEqual(h.editor.shape(at: CGPoint(x: 100, y: 0)), flag)

        h.enter(p)
        h.editor.replaceFile(with: h.file)                  // every board's revision changes, the root's too
        h.editor.showBoard(.root)
        let before = log.geometries.count
        _ = h.editor.paintOrder(in: .infinite)
        expectEqual(log.geometries.count, before + 1, "the root was worked out afresh")
    },
    test("the editor keeps what it worked out of the 8 boards shown last, and of the path's boards longest") {
        // The root holds pocket P, whose board holds pockets Q0…Q9; every board holds a marker.
        let log = IndexLog(), p = ShapeID(), qs = (0..<10).map { _ in ShapeID() }
        var children: [ShapeID: CanvasDocument] = [p: CanvasDocument(shapes: [marker(ShapeID())] + qs.map { pocket($0) })]
        for q in qs { children[q] = board(marker(ShapeID())) }
        let h = try harness(CanvasFile(root: board(marker(ShapeID()), pocket(p)), children: children), [IndexKinds(log: log)])
        @MainActor func worksOut(_ target: BoardID) -> Bool {
            let before = log.geometries.count
            expect(h.editor.showBoard(target))
            _ = h.editor.paintOrder()
            return log.geometries.count > before
        }
        _ = h.editor.paintOrder()
        expect(worksOut(BoardID(owner: p)))
        // Ten of P's boards, one after another: the root and P were kept first, but they're above
        // each, so the Qs shown longest ago go instead.
        for q in qs { expect(worksOut(BoardID(owner: q))) }
        expect(!worksOut(BoardID(owner: p)), "P, above every Q")
        expect(!worksOut(.root), "the root, above every board")
        expect(!worksOut(BoardID(owner: qs[9])), "the Q shown last")
        expect(worksOut(BoardID(owner: qs[1])), "one shown longer ago than the last 8: worked out afresh")
    },
    test("a shape deleted takes what's kept of its board, and a board brought back under its id starts afresh") {
        let log = IndexLog(), p = ShapeID(), inside = ShapeID()
        let h = try harness(CanvasFile(root: board(pocket(p)), children: [p: board(marker(inside))]), [IndexKinds(log: log)])
        h.enter(p)
        _ = h.editor.paintOrder()
        h.editor.camera = Camera(origin: CGPoint(x: 50, y: 50))
        h.editor.showBoard(.root)
        h.editor.transact { $0.delete([p]) }
        expectEqual(h.editor.boardCameras[BoardID(owner: p)], nil)
        h.editor.transact { $0.insert(pocket(p), contents: [p: board(marker(inside))]) }
        let worked = log.geometries.count
        h.enter(p)
        _ = h.editor.paintOrder()
        expectEqual(log.geometries.count, worked + 1)
        expectEqual(h.editor.camera, Camera(), "the camera it was left with went with it")
    },
    test("a render reads how many shapes the board a shape owns holds") {
        let log = TallyLog(), full = ShapeID(), empty = ShapeID(), plain = ShapeID()
        let h = try harness(CanvasFile(root: board(AnyShapeRecord(ShapeRecord(id: full, Tally(frame: unit))),
                                                   AnyShapeRecord(ShapeRecord(id: empty, Tally(frame: CGRect(x: 200, y: 0, width: 100, height: 100)))),
                                                   box(plain, CGRect(x: 400, y: 0, width: 100, height: 100))),
                                       children: [full: board(box(), box(), AnyShapeRecord(ShapeRecord(Tally(frame: unit))))]),
                            [Contributor(id: "tallies") { $0.shape(TallyDefinition(log: log)) }])
        _ = renderBitmap(h.editor, size: CGSize(width: 600, height: 200))
        expectEqual(log.counts, [full: 3, empty: 0], "the shapes on its own board, not those under it")
        h.enter(full)
        h.add(Box(unit))
        h.editor.showBoard(.root)
        _ = renderBitmap(h.editor, size: CGSize(width: 600, height: 200))
        expectEqual(log.counts[full], 4)
    },
    test("replacing the file stays on the board shown if it can, else goes to the nearest board above it, or to the board asked for") {
        let tree = BoardTree(), log = SwitchLog()
        let h = try harness(tree.file, [listening(log)])
        h.editor.showBoard(tree.qBoard)
        h.editor.replaceFile(with: tree.file)
        expectEqual(h.editor.board, tree.qBoard)
        expectEqual(ids(h.editor.document), [tree.c])

        var withoutQ = tree.file
        withoutQ.set(board(box(tree.b)), for: tree.pBoard)
        withoutQ.removeBoards([tree.qBoard])
        log.events = []
        h.editor.replaceFile(with: withoutQ)
        expectEqual(h.editor.board, tree.pBoard, "Q is gone: its parent")
        expectEqual(h.editor.boardPath, [.root, tree.pBoard])
        expectEqual(ids(h.editor.document), [tree.b])
        expectEqual(log.events.filter { !$0.hasPrefix("document") }, ["will \(tree.q) → \(tree.p), showing \(tree.q)", "did \(tree.q) → \(tree.p), showing \(tree.p)"])

        h.editor.replaceDocument(with: board(box()))
        expectEqual(h.editor.board, .root, "nothing above it survives: the root")
        h.editor.replaceFile(with: tree.file, showing: tree.qBoard)
        expectEqual(h.editor.board, tree.qBoard, "the board asked for")
        h.editor.replaceFile(with: tree.file, showing: BoardID(owner: tree.a))
        expectEqual(h.editor.board, tree.qBoard, "one it can't show: as if none was asked for")

        let opened = CanvasEditor(registry: h.editor.registry, file: tree.file, showing: tree.qBoard, scheduler: ManualScheduler())
        expectEqual(opened.board, tree.qBoard)
        expectEqual(opened.boardPath, [.root, tree.pBoard, tree.qBoard])
        expectEqual(ids(opened.document), [tree.c])
        expectEqual(CanvasEditor(registry: h.editor.registry, file: tree.file, showing: BoardID(owner: tree.a), scheduler: ManualScheduler()).board, .root)
    },
    test("a stash keeps a service's state per board, gives it back only while the board is unchanged, and keeps the path's boards longest") {
        let tree = BoardTree()
        let h = try harness(tree.file)
        var stash = BoardStash<String>(limit: 2)
        stash.keep("root", for: .root, in: h.editor)
        expectEqual(stash.take(for: .root, in: h.editor), "root")
        expectEqual(stash.take(for: .root, in: h.editor), nil, "taken")
        stash.keep("root", for: .root, in: h.editor)
        h.add(Box(unit))
        expectEqual(stash.take(for: .root, in: h.editor), nil, "the board changed since")

        h.enter(tree.p)
        h.editor.showBoard(tree.qBoard)                    // the path: root, P, Q
        let x = BoardID(owner: ShapeID()), y = BoardID(owner: ShapeID())
        stash.keep("root", for: .root, in: h.editor)
        stash.keep("x", for: x, in: h.editor)
        stash.keep("y", for: y, in: h.editor)
        expectEqual(stash.boards, [.root, y], "X, off the path and kept longest ago, went first")
        stash.keep("p", for: tree.pBoard, in: h.editor)
        expectEqual(stash.boards, [.root, tree.pBoard], "then Y: the path's boards are kept longest")
        stash.keep("q", for: tree.qBoard, in: h.editor)
        expectEqual(stash.boards, [tree.pBoard, tree.qBoard], "with only the path's, the one kept longest ago")
        stash.forget([tree.pBoard])
        expectEqual(stash.boards, [tree.qBoard])
    },
])
