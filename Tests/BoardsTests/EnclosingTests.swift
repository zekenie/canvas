import Boards
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Keyboard
import Selection
import TestKit

// ⌘↑ steps out of what the selection is in before it goes up a board: the group, whole; the container its
// shapes are in; the board.

/// The nested boards, with containers (corrals) and a group fixture's groups.
@MainActor private func enclosingHarness(_ nest: Nest, _ groups: GroupsFixture) throws -> EditorHarness {
    let h = try nestHarness(nest, [CorralsPlugin(), Contributor(id: "fixed-groups") { $0.selectionGroups { _ in groups } }])
    groups.editor = h.editor
    return h
}

@MainActor let enclosingTests = Suite("Stepping out, then up", [
    test("⌘↑ with the selection inside a group selects the group, whole; with nothing left to step out of it goes up a board") {
        let nest = Nest(), groups = GroupsFixture()
        let h = try enclosingHarness(nest, groups)
        expect(h.enter(nest.d))
        expect(h.enter(nest.p))
        groups.paths = [nest.b: ["g"], nest.c: ["g"]]
        h.editor.selectedShapeIDs = [nest.b]
        expectEqual(h.editor.selectionFocus, ["g"])
        expect(h.editor.canPerform(.enclosingBoard))
        expect(h.commandUp())
        expectEqual(h.editor.board, nest.pBoard, "still here")
        expectEqual(h.editor.selectedShapeIDs, [nest.b, nest.c], "the group, whole, as Escape selects it")
        expectEqual(h.editor.selectionFocus, [])
        expect(h.commandUp())
        expectEqual(h.editor.board, nest.dBoard, "no group to leave: up a board")
        expectEqual(h.editor.selectedShapeIDs, [nest.p])
    },
    test("groups in groups are left a level at a time") {
        let nest = Nest(), groups = GroupsFixture()
        let h = try enclosingHarness(nest, groups)
        expect(h.enter(nest.d))
        expect(h.enter(nest.p))
        let third = h.add(Box(CGRect(x: 400, y: 0, width: 100, height: 100)))
        groups.paths = [nest.b: ["outer", "inner"], nest.c: ["outer", "inner"], third: ["outer"]]
        h.editor.selectedShapeIDs = [nest.b]
        h.commandUp()
        expectEqual(h.editor.selectedShapeIDs, [nest.b, nest.c])
        expectEqual(h.editor.selectionFocus, ["outer"])
        h.commandUp()
        expectEqual(h.editor.selectedShapeIDs, [nest.b, nest.c, third])
        expectEqual(h.editor.board, nest.pBoard)
        h.commandUp()
        expectEqual(h.editor.board, nest.dBoard)
    },
    test("⌘↑ with the selected shapes all in a container selects it; then, in none, goes up a board") {
        let nest = Nest(), groups = GroupsFixture()
        let h = try enclosingHarness(nest, groups)
        expect(h.enter(nest.d))
        expect(h.enter(nest.p))
        let corral = h.add(Corral(CGRect(x: -50, y: -50, width: 450, height: 250)))
        h.editor.put([nest.b, nest.c], in: corral)
        h.editor.selectedShapeIDs = [nest.b, nest.c]
        expect(h.commandUp())
        expectEqual(h.editor.selectedShapeIDs, [corral])
        expectEqual(h.editor.board, nest.pBoard)
        expect(h.commandUp())
        expectEqual(h.editor.board, nest.dBoard)
        expectEqual(h.editor.selectedShapeIDs, [nest.p])
        // One in the container and one out of it: the board.
        expect(h.enter(nest.p))
        h.editor.selectedShapeIDs = [nest.b, corral]
        h.commandUp()
        expectEqual(h.editor.board, nest.dBoard, "they're not all in one container")
    },
    test("a group is left before the container it is in") {
        let nest = Nest(), groups = GroupsFixture()
        let h = try enclosingHarness(nest, groups)
        expect(h.enter(nest.d))
        expect(h.enter(nest.p))
        let corral = h.add(Corral(CGRect(x: -50, y: -50, width: 450, height: 250)))
        h.editor.put([nest.b, nest.c], in: corral)
        groups.paths = [nest.b: ["g"], nest.c: ["g"]]
        h.editor.selectedShapeIDs = [nest.b]
        h.commandUp()
        expectEqual(h.editor.selectedShapeIDs, [nest.b, nest.c])
        h.commandUp()
        expectEqual(h.editor.selectedShapeIDs, [corral])
        h.commandUp()
        expectEqual(h.editor.board, nest.dBoard)
    },
    test("on the root it is enabled while it would select a group or a container, and its key passes when it wouldn't") {
        let nest = Nest(), groups = GroupsFixture()
        let h = try enclosingHarness(nest, groups)
        let corral = h.add(Corral(CGRect(x: 0, y: 200, width: 400, height: 200)))
        let inside = h.add(Box(CGRect(x: 50, y: 250, width: 100, height: 100)))
        h.editor.put([inside], in: corral)
        expect(!h.editor.canPerform(.enclosingBoard) && !h.commandUp(), "nothing selected, nothing above")
        h.editor.selectedShapeIDs = [nest.a]
        expect(!h.editor.canPerform(.enclosingBoard), "a shape on the board itself")
        h.editor.selectedShapeIDs = [inside]
        expect(h.editor.canPerform(.enclosingBoard))
        expect(h.commandUp())
        expectEqual(h.editor.selectedShapeIDs, [corral])
        expect(!h.editor.canPerform(.enclosingBoard) && !h.commandUp(), "it holds the corral: nowhere to go")
        groups.paths = [nest.a: ["g"], inside: ["g"]]
        h.editor.selectedShapeIDs = [nest.a]
        expectEqual(h.editor.selectionFocus, ["g"])
        expect(h.commandUp())
        expectEqual(h.editor.selectedShapeIDs, [nest.a, inside])
        expectEqual(h.editor.board, .root)
    },
    test("never mid-press or while a shape is edited, whatever the selection is in") {
        let nest = Nest(), groups = GroupsFixture()
        let h = try enclosingHarness(nest, groups)
        let corral = h.add(Corral(CGRect(x: 0, y: 200, width: 400, height: 200)))
        let card = h.add(Card(CGRect(x: 50, y: 250, width: 100, height: 60)))
        h.editor.put([card], in: corral)
        h.editor.selectedShapeIDs = [card]
        expect(h.editor.canPerform(.enclosingBoard))
        expect(h.editor.beginEditing(card))
        expect(!h.editor.canPerform(.enclosingBoard) && !h.commandUp(), "while editing")
        h.editor.endEditing()
        h.press(at: CGPoint(x: 700, y: 500))
        h.drag(to: CGPoint(x: 720, y: 520))
        expect(!h.editor.canPerform(.enclosingBoard) && !h.commandUp(), "mid-press")
        h.release()
    },
    test("the Go item is named for the step: the group, the container's kind, the board; the command keeps its own title") {
        let nest = Nest(), groups = GroupsFixture()
        let h = try enclosingHarness(nest, groups)
        expect(h.enter(nest.d))
        expect(h.enter(nest.p))
        let corral = h.add(Corral(CGRect(x: -50, y: -50, width: 450, height: 250)))
        h.editor.put([nest.b, nest.c], in: corral)
        groups.paths = [nest.b: ["g"], nest.c: ["g"]]
        expectEqual(h.editor.menuTitle(of: .enclosingBoard), "Enclosing Board", "nothing selected")
        h.editor.selectedShapeIDs = [nest.b]
        expectEqual(h.editor.menuTitle(of: .enclosingBoard), "Enclosing Group")
        h.editor.selectedShapeIDs = [nest.b, nest.c]
        let container = h.editor.registry.label(of: Corral.kind).name
        expectEqual(h.editor.menuTitle(of: .enclosingBoard), "Enclosing \(container)", "what the container's kind is called")
        h.editor.selectedShapeIDs = [corral]
        expectEqual(h.editor.menuTitle(of: .enclosingBoard), "Enclosing Board")
        expectEqual(h.editor.registry.title(of: .enclosingBoard), "Enclosing Board", "what the Keyboard Shortcuts window lists it as")
        expectEqual(h.editor.menuTitle(of: .goBack), nil, "a command whose title doesn't follow the editor has no menu title")
        expectEqual(h.editor.menuTitle(of: "unclaimed"), nil)
    },
    test("stepping out leaves the camera while any of what it selects is in view, and pans to it, never zooming, when none is") {
        let nest = Nest(), groups = GroupsFixture()
        let h = try enclosingHarness(nest, groups)
        let view = CGSize(width: 1000, height: 700)
        h.editor.viewportDidResize(to: view)
        let corral = h.add(Corral(CGRect(x: 0, y: 200, width: 3000, height: 2000)))
        let inside = h.add(Box(CGRect(x: 50, y: 250, width: 100, height: 100)))
        h.editor.put([inside], in: corral)
        h.editor.selectedShapeIDs = [inside]
        h.wait(200)
        let before = h.editor.camera
        h.commandUp()
        h.wait(200)
        expectEqual(h.editor.selectedShapeIDs, [corral])
        // Some of it in view: the camera stays, never zoomed out to fit the 3000 × 2000 corral (U1, structure 15).
        expectEqual(h.editor.zoomPercentage, 100, "not zoomed out")
        expectEqual(h.editor.camera, before, "nor moved")
    },
    test("the way up the table of contents' header offers goes to the board above whatever is selected, and is off on the root") {
        let nest = Nest(), groups = GroupsFixture()
        let h = try enclosingHarness(nest, groups)
        let corral = h.add(Corral(CGRect(x: 0, y: 200, width: 400, height: 200)))
        let inside = h.add(Box(CGRect(x: 50, y: 250, width: 100, height: 100)))
        h.editor.put([inside], in: corral)
        h.editor.selectedShapeIDs = [inside]
        expect(!h.editor.canPerform(.goUpBoard), "the root, though ⌘↑ has the corral to select")
        expect(h.enter(nest.d))
        expect(h.enter(nest.p))
        groups.paths = [nest.b: ["g"], nest.c: ["g"]]
        h.editor.selectedShapeIDs = [nest.b]
        expect(h.editor.canPerform(.goUpBoard))
        expect(h.editor.perform(.goUpBoard))
        expectEqual(h.editor.board, nest.dBoard, "not the group")
        expectEqual(h.editor.selectedShapeIDs, [nest.p])
        expectEqual(h.editor.registry.title(of: .goUpBoard), "Enclosing Board")
    },
])
