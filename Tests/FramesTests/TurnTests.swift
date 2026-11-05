@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Frames
import Selection
import SlashCommands
import TestKit
import Titles
import Transform

/// The Color ▸ items a frame's menu holds, with None checked: a frame has no color yet.
private let frameColorItems = ["Color ▸", "  Gray", "  Red", "  Orange", "  Yellow", "  Green", "  Teal", "  Blue", "  Indigo", "  Purple", "  Pink", "  —", "  ✓ None", "  —", "  Edit Colors…"]

// Frames offer the container channel and know nothing of what takes it: what a frame turns into is
// whatever takes the channel (Subboards, in the app: CompositionTests hold that). Here it's CanvasTesting's
// pocket, a kind that owns a board as a subboard does, taking it as Subboards does: a pocket's size at the
// frame's corner, holding on its board what the frame held.

/// What pockets are to the frame: titled, as a subboard is, so a frame's title is one both kinds hold, and
/// the kind a frame turns into.
@MainActor private func framesTurnIntoPockets() -> [any CanvasPlugin] {
    [PocketsPlugin(), Contributor(id: "frame-pockets") { r in
        r.title(Pocket.self)
        r.turnable(into: Pocket.self, through: ContainerChannel.self, label: "Pocket") { container, transaction in
            guard transaction.turn(container.id, into: Pocket(CGRect(origin: container.frame.origin, size: CGSize(width: 240, height: 160)))) else { return }
            transaction.move(container.inside, toBoardOwnedBy: container.id)
        }
    }]
}

/// An empty board of `framePlugins` and the pocket they turn into.
@MainActor private func turnHarness(_ refusals: RefusalLog = RefusalLog()) throws -> EditorHarness {
    let h = try EditorHarness(plugins: framePlugins(refusals) + framesTurnIntoPockets())
    h.editor.viewportDidResize(to: CGSize(width: 1000, height: 800))
    return h
}

/// Frame Sprint, 600 × 400 from (100, 100), holding boxes A and B and a frame, Inner, which holds box C;
/// and box Z beside it. The frame's border is where the pointer presses it.
@MainActor private struct Sprint {
    let h: EditorHarness
    let sprint: ShapeID, a: ShapeID, b: ShapeID, inner: ShapeID, c: ShapeID, z: ShapeID

    /// Its top edge, where a frame that holds shapes is pressed.
    let edge = CGPoint(x: 400, y: 101)

    init(_ h: EditorHarness) {
        self.h = h
        sprint = h.addFrame(CGRect(x: 100, y: 100, width: 600, height: 400), title: "Sprint")
        a = h.addBox(CGRect(x: 120, y: 120, width: 80, height: 60), in: sprint)
        b = h.addBox(CGRect(x: 220, y: 120, width: 80, height: 60), in: sprint)
        inner = h.addFrame(CGRect(x: 320, y: 200, width: 300, height: 200), title: "Inner")
        h.editor.put([inner], in: sprint)
        c = h.addBox(CGRect(x: 340, y: 220, width: 80, height: 60), in: inner)
        z = h.addBox(CGRect(x: 800, y: 100, width: 80, height: 60))
    }

    /// The pocket's board.
    var board: CanvasDocument { h.file[BoardID(owner: sprint)] }
}

@MainActor let turnTests = Suite("Frames turning into other kinds", [
    test("a frame offers the container channel and knows nothing of what takes it: it turns into nothing until a kind does, and brings no Turn into item or command of its own") {
        let registry = try Registry(plugins: framePlugins())
        let framing = try require(registry.report.split(separator: "\n").first { $0.hasPrefix("framing") })
        expect(framing.hasSuffix("ShapeDetails → frame · offers channel container → frame · property is → frame · property fieldValues → frame · accessibility → frame · ports frame-link → frame · channel frame-link · edge type frame-link · command createFrame · shortcut ⇧⌘F → command createFrame · CanvasContextMenu in FramesMenuGroup after TransformMenuGroup"), "\(framing)")
        expectEqual(registry.turnTargets(of: Frame.kind), [])

        let h = try frameHarness()
        let frame = h.addFrame(title: "Sprint")
        h.addBox(CGRect(x: 120, y: 120, width: 80, height: 60), in: frame)
        expectEqual(h.editor.transforms?.targets(of: frame), [])
        expect(h.editor.transforms?.turn([frame], into: Pocket.kind) == false, "nothing to turn into")
        expectEqual(h.editor.slashCommands?.commands(for: frame).map(\.name), ["color", "title", "is-a"], "a target brings /turn-into-…, not the kind that offers")
        expectEqual(try require(h.secondaryClick(at: CGPoint(x: 300, y: 101))).outline, ["Create Frame", "—"] + frameColorItems + ["—", "Delete"], "Create Frame is Frames' own, for any shapes")

        let turning = try Registry(plugins: framePlugins() + framesTurnIntoPockets())
        expectEqual(turning.turnTargets(of: Frame.kind), [Pocket.kind])
        expectEqual(turning.turnTargets(of: Pocket.kind), [])
    },

    test("a frame titled Sprint, holding boxes and a frame of its own, turns into a pocket: the same shape under its id with its title, what it held on the pocket's board where it was, the frame inside still a frame holding its box") {
        let s = Sprint(try turnHarness())
        let h = s.h
        let before = h.file
        expectEqual(h.editor.transforms?.targets(of: s.sprint), [Pocket.kind])
        expect(h.editor.transforms?.turn([s.sprint], into: Pocket.kind) == true)

        let pocket = try require(h.editor.document[s.sprint])
        expectEqual(pocket.kind, Pocket.kind, "under its id")
        expectEqual(pocket.box, CGRect(x: 100, y: 100, width: 240, height: 160), "a pocket's size at the frame's corner")
        expectEqual(pocket[TitleProperty.self], "Sprint", "its title, which both kinds hold")
        expectEqual(h.editor.document.shapes.map(\.id), [s.sprint, s.z], "what it held is off the board")
        expectEqual(s.board.shapes.map(\.id), [s.a, s.b, s.inner, s.c], "on its board, in the order they were")
        expectEqual(s.board.shapes.map(\.kind), [Box.kind, Box.kind, Frame.kind, Box.kind], "the frame inside is still a frame")
        expectEqual(s.board.shapes.map(\.container), [nil, nil, nil, s.inner], "holding its box, and in none of what's gone")
        expectEqual(s.board[s.inner]?[TitleProperty.self], "Inner", "with its title")
        expectEqual(s.board[s.inner]?.box, before.record(s.inner)?.box, "where it was")
        expectEqual(s.board[s.c]?.box, before.record(s.c)?.box)
        expectEqual(h.editor.undoHistory.undoName, "Turn into Pocket")

        let after = h.file
        h.editor.undo()
        expectEqual(h.file, before, "the frame, and everything in it")
        h.editor.redo()
        expectEqual(h.file, after)
    },

    test("a frame's menu has the target's item once a kind takes the channel, and /turn-into-pocket is offered; either turns it") {
        let s = Sprint(try turnHarness())
        let h = s.h
        expectEqual(h.editor.slashCommands?.commands(for: s.sprint).map(\.name), ["color", "title", "is-a", "turn-into-pocket"])
        expectEqual(h.editor.slashCommands?.commands(for: s.z).map(\.name), [], "a box offers no channel")
        let menu = try require(h.secondaryClick(at: s.edge))
        expectEqual(menu.outline, ["Turn into Pocket", "—", "Create Frame", "—"] + frameColorItems + ["—", "Delete"])
        try menu.choose("Turn into Pocket")
        expectEqual(h.editor.document[s.sprint]?.kind, Pocket.kind)
        expectEqual(h.editor.selectedShapeIDs, [s.sprint], "still selected")
        h.editor.undo()

        expect(h.editor.slashCommands?.run("turn-into-pocket", on: s.sprint, with: SlashArguments([])) == true)
        expectEqual(h.editor.document[s.sprint]?.kind, Pocket.kind)
        expectEqual(h.editor.undoHistory.undoName, "Turn into Pocket")
        expectEqual(h.editor.slashCommands?.commands(for: s.sprint).map(\.name), ["title"], "a pocket offers nothing to turn into")
    },

    test("frames selected together turn together, the one inside first: the pocket it makes goes onto the outer one's board") {
        let h = try turnHarness()
        let outer = h.addFrame(CGRect(x: 100, y: 100, width: 600, height: 400), title: "Roadmap")
        let inner = h.addFrame(CGRect(x: 150, y: 150, width: 300, height: 260), title: "Sprint 3")
        h.editor.put([inner], in: outer)
        let note = h.addBox(CGRect(x: 180, y: 180, width: 80, height: 60), in: inner)
        let before = h.file
        h.editor.selectedShapeIDs = [outer, inner]
        let menu = try require(h.secondaryClick(at: CGPoint(x: 400, y: 101)))
        try menu.choose("Turn into Pocket")
        expectEqual(h.editor.document.shapes.map(\.id), [outer])
        expectEqual(h.file[BoardID(owner: outer)].shapes.map(\.id), [inner])
        expectEqual(h.file[BoardID(owner: inner)].shapes.map(\.id), [note])
        expectEqual(h.file.record(inner)?.kind, Pocket.kind, "both are pockets")
        expectEqual(h.file.record(outer)?.kind, Pocket.kind)
        expectEqual(h.file.record(inner)?[TitleProperty.self], "Sprint 3")
        expectEqual(h.file.path(to: BoardID(owner: inner)), [.root, BoardID(owner: outer), BoardID(owner: inner)])
        h.editor.undo()
        expectEqual(h.file, before, "one step")
    },

    test("a locked shape the frame holds, or a locked frame, keeps it a frame: nothing changes, no step, and the read-only shapes are heard refused; unlocked, it turns") {
        let log = RefusalLog()
        let s = Sprint(try turnHarness(log))
        let h = s.h
        let transforms = try require(h.editor.transforms)
        h.editor.undoHistory.group("Freeze") { h.editor.freeze([s.c]) }
        let before = h.file, revision = h.editor.revision
        expect(!transforms.turn([s.sprint], into: Pocket.kind), "a box in the frame inside it, which is in the way too")
        expectEqual(h.file, before)
        expectEqual(h.editor.revision, revision, "nothing committed")
        expectEqual(h.editor.undoHistory.undoName, "Freeze", "no step")
        expectEqual(log.refusals, [[s.c]])

        h.editor.undoHistory.group("Thaw") { h.editor.freeze([s.c], false) }
        h.editor.undoHistory.group("Freeze") { h.editor.freeze([s.sprint]) }
        let frozen = h.file
        expect(!transforms.turn([s.sprint], into: Pocket.kind))
        expectEqual(h.file, frozen)
        expectEqual(log.refusals, [[s.c], [s.sprint]], "the frame itself")

        h.editor.freeze([s.sprint], false)
        expect(transforms.turn([s.sprint], into: Pocket.kind))
        expectEqual(h.editor.document[s.sprint]?.kind, Pocket.kind)
    },

    test("a frame with nothing in it turns into an empty pocket: no board is kept for it") {
        let h = try turnHarness()
        let frame = h.addFrame(title: "Later")
        expect(h.editor.transforms?.turn([frame], into: Pocket.kind) == true)
        expectEqual(h.editor.document[frame]?.kind, Pocket.kind)
        expectEqual(h.editor.document[frame]?.box, CGRect(x: 100, y: 100, width: 240, height: 160))
        expectEqual(h.file.children.count, 0, "an empty board isn't kept")
        expect(h.enter(frame), "though it opens")
        expectEqual(h.editor.document.shapes.count, 0)
    },
])
