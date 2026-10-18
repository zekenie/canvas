@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Keyboard
import Selection
import TestKit

/// Groups a test says outright (`SelectionGroups`): each shape's groups, outermost first, by name; a
/// group's shapes back to front, as the board has them. Setting `paths` tells the editor, as a source
/// tells it once it has heard a commit.
@MainActor
final class GroupsFixture: SelectionGroupSource {
    weak var editor: CanvasEditor?
    var paths: [ShapeID: [String]] = [:] {
        didSet { editor?.selectionGroupsDidChange() }
    }

    func groups(of id: ShapeID) -> [AnyHashable] { (paths[id] ?? []).map(AnyHashable.init) }

    func shapes(in group: AnyHashable) -> [ShapeID] {
        guard let name = group.base as? String, let editor else { return [] }
        return editor.document.shapes.map(\.id).filter { paths[$0]?.contains(name) == true }
    }
}

/// An editor with keys, the selection, the fixtures and cards, whose groups are `fixture`'s, and `more`.
@MainActor func groupsHarness(_ fixture: GroupsFixture, _ more: [any CanvasPlugin] = []) throws -> EditorHarness {
    let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), CardsPlugin(),
                                        Contributor(id: "fixed-groups") { $0.selectionGroups { _ in fixture } }] + more)
    fixture.editor = h.editor
    return h
}

/// Four 100-point boxes in a row, 100 apart: a, b, c, d, whose middles are at x 50, 250, 450, 650.
@MainActor
struct Row {
    let h: EditorHarness
    let a, b, c, d: ShapeID
    init(_ h: EditorHarness) {
        self.h = h
        a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        b = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        c = h.add(Box(CGRect(x: 400, y: 0, width: 100, height: 100)))
        d = h.add(Box(CGRect(x: 600, y: 0, width: 100, height: 100)))
    }
    func middle(_ id: ShapeID) -> CGPoint {
        [a: CGPoint(x: 50, y: 50), b: CGPoint(x: 250, y: 50), c: CGPoint(x: 450, y: 50), d: CGPoint(x: 650, y: 50)][id]!
    }
}

@MainActor let groupSelectionTests = Suite("Groups selected as one", [
    test("a click on a shape in a group selects the group, all of it; a drag moves it all") {
        let groups = GroupsFixture()
        let h = try groupsHarness(groups)
        let row = Row(h)
        groups.paths = [row.a: ["g"], row.b: ["g"]]
        h.click(at: row.middle(row.a))
        expectEqual(h.editor.selectedShapeIDs, [row.a, row.b])
        expectEqual(h.editor.selectionFocus, [])
        h.press(at: row.middle(row.b))
        h.drag(to: CGPoint(x: 250, y: 150))
        h.release()
        expectEqual(h.editor.document[row.a]?.box, CGRect(x: 0, y: 100, width: 100, height: 100))
        expectEqual(h.editor.document[row.b]?.box, CGRect(x: 200, y: 100, width: 100, height: 100))
        expectEqual(h.editor.document[row.c]?.box, CGRect(x: 400, y: 0, width: 100, height: 100), "not in it")
        h.click(at: row.middle(row.c))
        expectEqual(h.editor.selectedShapeIDs, [row.c], "a shape in no group alone")
    },
    test("a click on a shape of a selected group selects it alone, inside the group; there a click selects another alone; Escape selects the group whole, then nothing") {
        let groups = GroupsFixture()
        let h = try groupsHarness(groups)
        let row = Row(h)
        groups.paths = [row.a: ["g"], row.b: ["g"], row.c: ["g"]]
        h.click(at: row.middle(row.b))
        expectEqual(h.editor.selectedShapeIDs, [row.a, row.b, row.c])
        h.click(at: row.middle(row.b))
        expectEqual(h.editor.selectedShapeIDs, [row.b])
        expectEqual(h.editor.selectionFocus, ["g"])
        h.click(at: row.middle(row.c))
        expectEqual(h.editor.selectedShapeIDs, [row.c], "inside the group, its parts one at a time")
        h.hold(.shift)
        h.click(at: row.middle(row.a))
        h.hold([])
        expectEqual(h.editor.selectedShapeIDs, [row.c, row.a])
        expectEqual(h.editor.selectionFocus, ["g"])
        h.escape()
        expectEqual(h.editor.selectedShapeIDs, [row.a, row.b, row.c], "out of it, the group whole")
        expectEqual(h.editor.selectionFocus, [])
        h.escape()
        expectEqual(h.editor.selectedShapeIDs, [])
    },
    test("inside a group, a lone shape follows the pointer from the press, and the group stays") {
        let groups = GroupsFixture()
        let h = try groupsHarness(groups)
        let row = Row(h)
        groups.paths = [row.a: ["g"], row.b: ["g"]]
        h.click(at: row.middle(row.a))
        h.click(at: row.middle(row.a))
        expectEqual(h.editor.selectedShapeIDs, [row.a])
        h.press(at: row.middle(row.a))
        h.drag(to: CGPoint(x: 52, y: 60))
        h.release()
        expectEqual(h.editor.document[row.a]?.box, CGRect(x: 2, y: 10, width: 100, height: 100))
        expectEqual(h.editor.document[row.b]?.box, CGRect(x: 200, y: 0, width: 100, height: 100))
        expectEqual(h.editor.selectionFocus, ["g"])
    },
    test("a double-click on a shape in a group selects it alone rather than opening it; once it's the part, a double-click opens it") {
        let groups = GroupsFixture()
        let h = try groupsHarness(groups)
        let card = h.add(Card(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let box = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        groups.paths = [card: ["g"], box: ["g"]]
        h.click(at: CGPoint(x: 50, y: 50))
        h.press(at: CGPoint(x: 50, y: 50), clickCount: 2)
        h.release()
        expectEqual(h.editor.selectedShapeIDs, [card])
        expectEqual(h.editor.editingShapeID, nil, "not opened")
        h.wait(500)
        h.click(at: CGPoint(x: 250, y: 50))
        expectEqual(h.editor.selectedShapeIDs, [box])
        h.wait(500)
        h.click(at: CGPoint(x: 50, y: 50))
        h.press(at: CGPoint(x: 50, y: 50), clickCount: 2)
        h.release()
        expectEqual(h.editor.editingShapeID, card, "inside the group the card is a part of its own")
    },
    test("groups in groups: a click takes the outermost, each click on a selected one goes a level in, and Escape a level out") {
        let groups = GroupsFixture()
        let h = try groupsHarness(groups)
        let row = Row(h)
        groups.paths = [row.a: ["outer", "inner"], row.b: ["outer", "inner"], row.c: ["outer"]]
        h.click(at: row.middle(row.a))
        expectEqual(h.editor.selectedShapeIDs, [row.a, row.b, row.c])
        h.click(at: row.middle(row.a))
        expectEqual(h.editor.selectedShapeIDs, [row.a, row.b])
        expectEqual(h.editor.selectionFocus, ["outer"])
        h.click(at: row.middle(row.a))
        expectEqual(h.editor.selectedShapeIDs, [row.a])
        expectEqual(h.editor.selectionFocus, ["outer", "inner"])
        h.escape()
        expectEqual(h.editor.selectedShapeIDs, [row.a, row.b])
        h.escape()
        expectEqual(h.editor.selectedShapeIDs, [row.a, row.b, row.c])
        h.escape()
        expectEqual(h.editor.selectedShapeIDs, [])
        // Inside the outer group, a click on c selects it alone, and one on a the inner group whole.
        h.click(at: row.middle(row.c))
        h.click(at: row.middle(row.c))
        expectEqual(h.editor.selectedShapeIDs, [row.c])
        h.click(at: row.middle(row.a))
        expectEqual(h.editor.selectedShapeIDs, [row.a, row.b])
        expectEqual(h.editor.selectionFocus, ["outer"])
    },
    test("inside a group, a click on a shape outside it selects that shape, or its group whole, and the selection is inside it no more") {
        let groups = GroupsFixture()
        let h = try groupsHarness(groups)
        let row = Row(h)
        groups.paths = [row.a: ["g"], row.b: ["g"], row.c: ["h"], row.d: ["h"]]
        h.click(at: row.middle(row.a))
        h.click(at: row.middle(row.a))
        expectEqual(h.editor.selectionFocus, ["g"])
        h.click(at: row.middle(row.c))
        expectEqual(h.editor.selectedShapeIDs, [row.c, row.d])
        expectEqual(h.editor.selectionFocus, [])
    },
    test("⇧ adds a group whole, and on a shape of a selected group puts that shape in the group's place") {
        let groups = GroupsFixture()
        let h = try groupsHarness(groups)
        let row = Row(h)
        groups.paths = [row.a: ["g"], row.b: ["g"]]
        h.click(at: row.middle(row.c))
        h.hold(.shift)
        h.click(at: row.middle(row.a))
        expectEqual(h.editor.selectedShapeIDs, [row.c, row.a, row.b])
        h.click(at: row.middle(row.b))
        expectEqual(h.editor.selectedShapeIDs, [row.c, row.b])
        h.click(at: row.middle(row.c))
        expectEqual(h.editor.selectedShapeIDs, [row.b], "a shape in no group is taken away as ever")
        h.hold([])
    },
    test("the marquee takes groups whole; with ⌘ only those it holds every shape of") {
        let groups = GroupsFixture()
        let h = try groupsHarness(groups)
        let row = Row(h)
        groups.paths = [row.a: ["g"], row.b: ["g"]]
        h.press(at: CGPoint(x: 50, y: 150))
        h.drag(to: CGPoint(x: 60, y: 60))
        expectEqual(h.editor.selectedShapeIDs, [row.a, row.b], "touching a brings b")
        h.drag(to: CGPoint(x: 460, y: 60))
        expectEqual(h.editor.selectedShapeIDs, [row.a, row.b, row.c])
        h.release()
        h.hold(.command)
        h.press(at: CGPoint(x: -10, y: -10))
        h.drag(to: CGPoint(x: 150, y: 150))
        expectEqual(h.editor.selectedShapeIDs, [], "a alone is held, not the group")
        h.drag(to: CGPoint(x: 350, y: 150))
        expectEqual(h.editor.selectedShapeIDs, [row.a, row.b])
        h.release()
        h.hold([])
    },
    test("inside a group, a marquee from its box selects its parts; a press outside its box leaves it") {
        let groups = GroupsFixture()
        let h = try groupsHarness(groups)
        let row = Row(h)
        groups.paths = [row.a: ["g"], row.b: ["g"]]
        h.click(at: row.middle(row.a))
        h.click(at: row.middle(row.a))
        h.press(at: CGPoint(x: 150, y: 50))
        expectEqual(h.editor.selectionFocus, ["g"], "in its box, between its shapes")
        h.drag(to: CGPoint(x: 260, y: 60))
        expectEqual(h.editor.selectedShapeIDs, [row.b])
        h.release()
        h.press(at: CGPoint(x: 150, y: 300))
        expectEqual(h.editor.selectionFocus, [])
        h.drag(to: CGPoint(x: 260, y: 60))
        expectEqual(h.editor.selectedShapeIDs, [row.a, row.b], "outside it, groups whole")
        h.release()
    },
    test("the hover outlines what a click would select, the group whole, and a list's hover the shape alone") {
        let groups = GroupsFixture()
        let h = try groupsHarness(groups)
        let row = Row(h)
        groups.paths = [row.a: ["g"], row.b: ["g"]]
        h.move(to: row.middle(row.a))
        expectEqual(h.editor.outlines.faintShapes, [row.a, row.b])
        h.move(to: row.middle(row.c))
        expectEqual(h.editor.outlines.faintShapes, [row.c])
        h.move(to: CGPoint(x: 150, y: 300))
        h.editor.hovered = row.a
        expectEqual(h.editor.outlines.faintShapes, [row.a], "a row hovered: the shape alone")
        h.click(at: row.middle(row.a))
        h.move(to: row.middle(row.b))
        expectEqual(h.editor.outlines.faintShapes, [], "a selected shape has no faint outline, a group's as any")
    },
    test("a shape's faces answer once a click has gone into its group: before, a click on one selects the group, and the hover is the group's") {
        let groups = GroupsFixture()
        let log = FaceLog()
        let h = try groupsHarness(groups, [facesPlugin(log)])
        let row = Row(h)
        groups.paths = [row.a: ["g"], row.b: ["g"]]
        log.names = row.c
        let onFace = CGPoint(x: 20, y: 20)
        h.move(to: onFace)
        expectEqual(h.editor.hovered, row.a, "not the shape the face names")
        expectEqual(h.editor.outlines.faintShapes, [row.a, row.b])
        h.click(at: onFace)
        expectEqual(h.editor.selectedShapeIDs, [row.a, row.b])
        h.wait(500)
        h.click(at: onFace)
        expectEqual(h.editor.selectedShapeIDs, [row.a], "into the group")
        expectEqual(log.clicks, [], "no face clicked yet")
        h.wait(500)
        h.click(at: onFace)
        expectEqual(log.clicks, [row.a])
        h.move(to: CGPoint(x: 21, y: 21))
        expectEqual(h.editor.hovered, row.c, "inside the group, the face names what it hovers")
        groups.paths[row.c] = ["h"]
        groups.paths[row.d] = ["h"]
        h.move(to: CGPoint(x: 22, y: 22))
        expectEqual(h.editor.outlines.faintShapes, [row.c], "a shape a face names is outlined alone: a click on the face doesn't select its group")
    },
    test("a right-click's menu is for the group: Selection says what a click on a shape selects") {
        let groups = GroupsFixture()
        let h = try groupsHarness(groups)
        let row = Row(h)
        groups.paths = [row.a: ["g"], row.b: ["g"]]
        expectEqual(h.editor.selectionUnit(of: row.a), [row.a, row.b])
        expectEqual(h.editor.selectionUnit(of: row.c), [row.c])
        h.click(at: row.middle(row.a))
        h.click(at: row.middle(row.a))
        expectEqual(h.editor.selectionUnit(of: row.b), [row.b], "inside the group, a part")
    },
    test("groups changing under the selection: what it's inside is worked out again, and an empty selection keeps only groups still there") {
        let groups = GroupsFixture()
        let h = try groupsHarness(groups)
        let row = Row(h)
        groups.paths = [row.a: ["g"], row.b: ["g"]]
        h.click(at: row.middle(row.a))
        h.click(at: row.middle(row.a))
        expectEqual(h.editor.selectionFocus, ["g"])
        groups.paths = [:]
        expectEqual(h.editor.selectionFocus, [])
        groups.paths = [row.a: ["g"], row.b: ["g"]]
        expectEqual(h.editor.selectionFocus, ["g"], "a alone, inside g again")
        h.editor.selectedShapeIDs = []
        expectEqual(h.editor.selectionFocus, ["g"], "an empty selection keeps it")
        groups.paths = [:]
        expectEqual(h.editor.selectionFocus, [])
    },
    test("another board shown: the selection is inside no group") {
        let groups = GroupsFixture()
        let boards = PocketBoards()
        let h = try pocketsHarness(boards, [Contributor(id: "fixed-groups") { $0.selectionGroups { _ in groups } }])
        groups.editor = h.editor
        groups.paths = [boards.a: ["g"], boards.c: ["g"]]
        h.click(at: boards.aPoint)
        h.click(at: boards.aPoint)
        expectEqual(h.editor.selectionFocus, ["g"])
        expect(h.enter(boards.p))
        expectEqual(h.editor.selectionFocus, [])
    },
])
