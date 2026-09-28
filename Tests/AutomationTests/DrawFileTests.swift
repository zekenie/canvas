import Automation
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

// `canvas draw` in the editor as it is now: each run one undo step, an agent's change, in a file of
// boards, where what a shape is bound to must be on its board and what it only names may be
// anywhere, or gone.

/// A box a tool places, 40 × 40, bound to a shape (`target`, as a tag is: `ShapeReferencing`) and
/// naming one (`cite`, as a mention does: `ShapeNaming`): a kind a script writes ids into.
struct Pin: BoxShapeProps {
    static let kind: ShapeKind = "pin"
    static let properties = Properties<Pin> {
        Property("frame", \.frame).required()
        Property("target", \.target)
        Property("cite", \.cite)
    }
    var frame: CGRect
    var target: ShapeID?
    var cite: Citation?

    init(_ frame: CGRect = .zero, target: ShapeID? = nil, cite: Citation? = nil) {
        self.frame = frame
        self.target = target
        self.cite = cite
    }

    init() { self.init(.zero) }
}

struct PinDefinition {}

extension PinDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Pin>, in context: RenderContext) {}
}

extension PinDefinition: ShapeReferencing {
    /// A pin whose target goes points at nothing.
    func remappingReferences(of shape: ShapeRecord<Pin>, _ map: (ShapeID) -> ShapeID?, in _: ShapeContext) -> Pin? {
        var pin = shape.props
        pin.target = shape.props.target.flatMap(map)
        return pin
    }
}

let pins = Contributor(id: "pins") { registrar in
    registrar.shape(PinDefinition()) { pin in
        pin.tool(label: "Pin", systemImage: "pin", placing: pin.placement(size: CGSize(width: 40, height: 40)) { Pin() })
    }
}

/// A tool whose press does nothing: a press held, with no session.
@MainActor final class StillTool {}

extension StillTool: Tool {
    func pointerDown(_ pointer: Pointer, in editor: CanvasEditor) {}
}

/// Whether each commit it hears was an agent's.
@MainActor final class AgentLog {
    var commits: [Bool] = []
}

extension AgentLog: EditorService {
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) { commits.append(changes.byAgent) }
}

/// A file: pocket P on the root, a box inside P's board, and a box on a board whose owner isn't in
/// the file (one the app keeps, and can't show).
private struct PocketFile {
    let pocket = ShapeID(), inside = ShapeID(), orphan = ShapeID()

    var file: CanvasFile {
        let box = { (id: ShapeID) in CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: id, Box(CGRect(x: 0, y: 0, width: 10, height: 10))))]) }
        return CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 0, y: 0, width: 10, height: 10))))]),
                          children: [pocket: box(inside), ShapeID(): box(orphan)])
    }
}

@MainActor let drawUndoTests = Suite("draw: undo", [
    test("a run is one undo step, Draw: undone, the board is as it was; redone, as the run left it, ids and all") {
        let editor = try drawEditor()
        let empty = editor.document
        _ = try drawn(threeShapes + "\n" + #"edge "Hub" -> "East""#, on: editor)
        let made = editor.document
        expectEqual(made.shapes.count, 4)
        expectEqual(editor.undoHistory.undoName, "Draw")
        editor.undo()
        expectEqual(editor.document, empty)
        expect(!editor.canUndo, "one step")
        editor.redo()
        expectEqual(editor.document, made)
    },
    test("a dry run, a refused script and a run that changes nothing make no step, and leave what there was to redo") {
        let editor = try drawEditor()
        _ = try drawn(threeShapes, on: editor)
        _ = try drawn(#"tile "Hub" finish: glossy"#, on: editor)
        editor.undo()
        var events: [UndoEvent] = []
        editor.undoHistory.didChange = { events.append($0) }
        _ = try drawn(#"tile "Hub" finish: glossy"#, on: editor, ["--dry-run"])
        expectEqual(try refused(#"tile "Hub" right of "Nowhere""#, on: editor).reason, "unknown_title")
        expectEqual(rows(try drawn(threeShapes, on: editor)).map { $0["did"] }, ["unchanged", "unchanged", "unchanged"])
        expectEqual(events, [])
        expect(editor.canRedo)
        expectEqual(editor.undoHistory.redoName, "Draw")
    },
    test("a press held leaves the board alone, as a drag does: what committed during it would be part of its step") {
        let still = Contributor(id: "still") { $0.tool(ToolDescriptor(id: "still", label: "Still", systemImage: "hand.raised")) { _ in StillTool() } }
        let h = try EditorHarness { _ in try drawEditor([still]) }
        h.editor.setTool("still")
        h.press(at: CGPoint(x: 10, y: 10))
        let busy = try refused("tile", on: h.editor)
        expectEqual(busy.reason, "busy")
        expectEqual(busy.message, "someone is pressing on this board")
        h.release()
        expectEqual(rows(try drawn("tile", on: h.editor)).map { $0["did"] }, ["created"])
        expectEqual(h.editor.undoHistory.undoName, "Draw")
    },
    test("a draw is an agent's change: its commit says so, and a person's doesn't") {
        let log = AgentLog()
        let editor = try drawEditor([Contributor(id: "agents") { $0.service { _ in log } }])
        _ = try drawn(threeShapes, on: editor)
        _ = try drawn(#"tile "Hub" finish: glossy"#, on: editor, ["--dry-run"])
        let hub = try require(shape("Hub", in: editor))
        editor.transact("Move") { $0.update(hub.id) { $0.box = CGRect(x: 0, y: 0, width: 120, height: 80) } }
        expectEqual(log.commits, [true, false])
    },
])

@MainActor let drawFileTests = Suite("draw: a file of boards", [
    test("a shape may be bound only to shapes on its board: one in no board, one on another, and one the script deletes are refused") {
        let f = PocketFile()
        let editor = try drawEditor([PocketsPlugin(), pins])
        editor.replaceFile(with: f.file)
        expectEqual(rows(try drawn(#"pin target: "\#(f.pocket)""#, on: editor)).map { $0["did"] }, ["created"])
        let missing = try refused(#"pin target: "\#(ShapeID())""#, on: editor)
        expectEqual(missing.reason, "invalid_value")
        expectEqual(missing.message, "the pin on line 1 is bound to a shape that isn't on this board")
        expectEqual(missing.hint, "a shape can be bound only to shapes on its own board")
        let away = try refused(#"pin target: "\#(f.inside)""#, on: editor)
        expectEqual(away.message, "the pin on line 1 is bound to a shape on another board of the file")
        _ = try drawn(#"tile "Hub""#, on: editor)
        let deleted = try refused(#"delete "Hub""# + "\n" + #"pin target: "\#(try require(shape("Hub", in: editor)).id)""#, on: editor)
        expectEqual(deleted.message, "the pin on line 2 is bound to a shape that isn't on this board")
        expect(editor.showBoard(BoardID(owner: f.pocket)))
        expectEqual(rows(try drawn(#"pin target: "\#(f.inside)""#, on: editor)).map { $0["did"] }, ["created"], "on the board it works on now")
    },
    test("a shape may name shapes anywhere in the file, or gone: it's drawn, and what isn't there, or can't be shown, is said") {
        let f = PocketFile()
        let editor = try drawEditor([PocketsPlugin(), pins])
        editor.replaceFile(with: f.file)
        let gone = ShapeID()
        let result = try drawn(#"pin cite: "\#(gone)""#, on: editor)
        expectEqual(messages(result), ["the pin on line 1: cite names shapes that aren't in the file: \(gone); they show as missing"])
        expectEqual(result["warnings"]?.arrayValue?.first?["attribute"], "cite")
        expectEqual(editor.document.shapes.compactMap { $0.typed(as: Pin.self)?.props.cite }, [Citation(gone)], "drawn, naming it")
        expectEqual(messages(try drawn(#"pin cite: "\#(f.inside)""#, on: editor)), [], "a shape on another board of the file is there")
        expectEqual(messages(try drawn(#"pin cite: "\#(f.orphan)""#, on: editor)),
                    ["the pin on line 1: cite names shapes on boards this app can't show: \(f.orphan); they show as missing"])
        _ = try drawn(#"tile "Hub""#, on: editor)
        let hub = try require(shape("Hub", in: editor)).id
        expectEqual(messages(try drawn(#"delete "Hub""# + "\n" + #"pin cite: "\#(hub)""#, on: editor)),
                    ["the pin on line 2: cite names shapes that aren't in the file: \(hub); they show as missing"], "one the script deletes is gone")
    },
])
