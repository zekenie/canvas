@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Selection
import SlashCommands
import Subboards
import TestKit
import Titles

// `/create-subboard`: an untitled subboard made for the shapes it's typed for, holding them on its board
// (the core's `place(_:taking:)`, which CanvasTests hold with pockets), typed for the shapes selected (the
// command bar's target, run headlessly through `editor.slashCommands`) or on a line of a shape's text, over
// CanvasTesting's boxes and links, with its corrals standing in for frames. The camera is at the origin at
// 100%.

/// The subboard's plugins, with corrals, links, the freezing flag (refusals in `refusals`) and
/// `/create-subboard` (`SubboardSlashPlugin`, which goes with Subboards' plugin).
@MainActor private func createHarness(_ refusals: RefusalLog = RefusalLog()) throws -> EditorHarness {
    let h = try EditorHarness(plugins: subboardPlugins() + [CorralsPlugin(), LinksPlugin(), FreezingPlugin(log: refusals), SubboardSlashPlugin()])
    h.editor.viewportDidResize(to: CGSize(width: 1000, height: 800))
    return h
}

extension EditorHarness {
    /// What the board a shape owns holds, back to front.
    fileprivate func inside(_ owner: ShapeID) -> [ShapeID] { file[BoardID(owner: owner)].shapes.map(\.id) }
    fileprivate var stack: [ShapeID] { editor.document.shapes.map(\.id) }
    /// `/create-subboard` for the shapes selected, as the command bar runs it: whether it ran.
    fileprivate func createSubboard(for ids: [ShapeID]) -> Bool {
        editor.slashCommands?.run("create-subboard", for: .selection(ids), with: SlashArguments([])) ?? false
    }
}

@MainActor let createSubboardTests = Suite("/create-subboard", [
    test("for the boxes selected: an untitled subboard of a subboard's size at their top-left corner, where the lowest of them was, holding them on its board where they were; selected, the board shown staying; one step, undone and redone whole") {
        let h = try createHarness()
        let a = h.add(Box(CGRect(x: 100, y: 120, width: 100, height: 80)))
        let far = h.add(Box(CGRect(x: 800, y: 600, width: 50, height: 50)))
        let b = h.add(Box(CGRect(x: 300, y: 150, width: 100, height: 80)))
        h.editor.selectedShapeIDs = [a, b]
        let before = h.file
        let state = try require(h.editor.slashCommands)
        let offered = try require(state.command(named: "create-subboard", for: .selection([a, b])))
        expectEqual(offered.shapes, [a, b], "together: every shape it reaches, once")
        expect(!offered.isPartial)
        expectEqual(offered.argument, nil, "it takes nothing")
        expect(state.run(offered, with: SlashArguments([])))
        let sub = try require(h.editor.selection, "the subboard is selected")
        let card = try require(h.editor.document[sub]?.typed(as: Subboard.self))
        expectEqual(card.props.frame, CGRect(x: 100, y: 120, width: 240, height: 160))
        expectEqual(card[TitleProperty.self], nil, "untitled")
        expectEqual(h.stack, [sub, far], "where the lowest of them was")
        expectEqual(h.inside(sub), [a, b])
        expectEqual(h.file[BoardID(owner: sub)][a]?.box, CGRect(x: 100, y: 120, width: 100, height: 80), "where it was")
        expectEqual(h.file[BoardID(owner: sub)][b]?.box, CGRect(x: 300, y: 150, width: 100, height: 80))
        expectEqual(h.editor.board, .root, "the board shown stays")
        expectEqual(h.editor.undoHistory.undoName, "Create Subboard")
        let after = h.file
        h.editor.undo()
        expectEqual(h.file, before, "both boards as they were")
        expectEqual(h.editor.selectedShapeIDs, [a, b])
        h.editor.redo()
        expectEqual(h.file, after)
        expect(h.enter(sub))
        expectEqual(h.stack, [a, b], "its board shows them")
    },

    test("on a line of a shape's text it takes that shape; a box offers it alone, and a subboard after what its own plugins give it") {
        let h = try createHarness()
        let a = h.add(Box(CGRect(x: 100, y: 100, width: 100, height: 80)))
        let plans = h.add(Subboard(frame: CGRect(x: 500, y: 100, width: 240, height: 160)))
        let state = try require(h.editor.slashCommands)
        expectEqual(state.commands(for: a).map(\.name), ["create-subboard"])
        expectEqual(state.commands(for: plans).map(\.name).last, "create-subboard", "its plugin after the kinds'")
        expect(!state.run("create-subboard", on: a, with: SlashArguments([.text("now")])), "it takes no words")
        expect(state.run("create-subboard", on: a, with: SlashArguments([])))
        let sub = try require(h.editor.selection)
        expect(sub != plans)
        expectEqual(h.inside(sub), [a])
        expectEqual(h.editor.document[sub]?.box, CGRect(x: 100, y: 100, width: 240, height: 160))
    },

    test("a link between two of them goes along and one to a shape left out lets go of it; a selected link isn't among those it acts on, `2 of 3`") {
        let h = try createHarness()
        let a = h.add(Box(CGRect(x: 100, y: 100, width: 60, height: 60)))
        let b = h.add(Box(CGRect(x: 300, y: 100, width: 60, height: 60)))
        let c = h.add(Box(CGRect(x: 600, y: 100, width: 60, height: 60)))
        let between = h.add(Link(from: a, to: b))
        let across = h.add(Link(from: b, to: c))
        let state = try require(h.editor.slashCommands)
        let offered = try require(state.command(named: "create-subboard", for: .selection([a, b, between])))
        expectEqual(offered.shapes, [a, b])
        expect(offered.isPartial)
        expect(state.run(offered, with: SlashArguments([])))
        let sub = try require(h.editor.selection)
        expectEqual(Set(h.inside(sub)), [a, b, between], "the link between them with them")
        let left = try require(h.editor.document[across]?.typed(as: Link.self))
        expectEqual(left.props.from, nil, "let go of b")
        expectEqual(left.props.to, c)
    },

    test("in the corral they're all in: the subboard in it, kept the gap inside its edge, in from a near edge and back from the far ones") {
        let h = try createHarness()
        let pen = h.add(Corral(CGRect(x: 0, y: 0, width: 600, height: 400)))
        let a = h.add(Box(CGRect(x: 10, y: 30, width: 100, height: 80)))
        let b = h.add(Box(CGRect(x: 200, y: 100, width: 100, height: 80)))
        h.editor.put([a, b], in: pen)
        expect(h.createSubboard(for: [a, b]))
        let sub = try require(h.editor.selection)
        expectEqual(h.editor.holder(of: sub), pen)
        expectEqual(h.editor.document[sub]?.box, CGRect(x: 16, y: 30, width: 240, height: 160))

        let corner = h.add(Box(CGRect(x: 500, y: 300, width: 50, height: 40)))
        h.editor.put([corner], in: pen)
        expect(h.createSubboard(for: [corner]))
        let far = try require(h.editor.selection)
        expectEqual(h.editor.holder(of: far), pen)
        expectEqual(h.editor.document[far]?.box, CGRect(x: 344, y: 224, width: 240, height: 160), "16 inside the right and bottom edges")
        expectEqual(h.inside(sub), [a, b])
    },

    test("a locked box among those selected is left out, `1 of 2`, and the rest go with nothing shaken; a locked link between two of them leaves it all as it was, with no step, and shakes") {
        let refusals = RefusalLog()
        let h = try createHarness(refusals)
        let a = h.add(Box(CGRect(x: 100, y: 100, width: 60, height: 60)))
        let locked = h.add(Box(CGRect(x: 300, y: 100, width: 60, height: 60)))
        h.editor.freeze([locked])
        let state = try require(h.editor.slashCommands)
        let offered = try require(state.command(named: "create-subboard", for: .selection([a, locked])))
        expectEqual(offered.shapes, [a])
        expect(offered.isPartial)
        expect(state.command(named: "create-subboard", for: .selection([locked])) == nil, "no row that could only be refused")
        expect(state.run(offered, with: SlashArguments([])))
        let sub = try require(h.editor.selection)
        expectEqual(h.inside(sub), [a])
        expect(h.editor.document[locked] != nil, "the locked box stays")
        expectEqual(refusals.refusals, [])

        let c = h.add(Box(CGRect(x: 100, y: 400, width: 60, height: 60)))
        let d = h.add(Box(CGRect(x: 300, y: 400, width: 60, height: 60)))
        let link = h.add(Link(from: c, to: d))
        h.editor.freeze([link])
        let steps = h.editor.undoHistory.undoName, shapes = h.stack
        expect(h.createSubboard(for: [c, d]), "it runs, and is refused")
        expectEqual(h.stack, shapes, "all as it was")
        expectEqual(refusals.refusals, [[link]])
        expectEqual(h.editor.undoHistory.undoName, steps, "no step")
    },

    test("with nothing selected the bar is for every shape on the board: all of them onto its board, the subboard alone left") {
        let h = try createHarness()
        let a = h.add(Box(CGRect(x: 100, y: 100, width: 100, height: 80)))
        let b = h.add(Box(CGRect(x: 600, y: 400, width: 100, height: 80)))
        let state = try require(h.editor.slashCommands)
        let offered = try require(state.command(named: "create-subboard", for: .everything([a, b])))
        expect(!offered.isPartial)
        expect(state.run(offered, with: SlashArguments([])))
        let sub = try require(h.editor.selection)
        expectEqual(h.stack, [sub])
        expectEqual(h.inside(sub), [a, b])
    },

    test("the report's line: on every shape with a box") {
        let registry = try Registry(plugins: subboardPlugins() + [SubboardSlashPlugin()])
        let line = try require(registry.report.split(separator: "\n").first { $0.hasPrefix("subboard-slash ") })
        expectEqual(line.split(separator: " ").joined(separator: " "), "subboard-slash /create-subboard → every shape with a box", "the id's column apart")
    },
])
