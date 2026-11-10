import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Publishing
import References
import Selection
import TestKit

// A reference shown as a mirror (`ReferenceMirror.swift`): Expand and Collapse, the plan it's laid out by, following its
// original with no commit of its own, what it draws, its handles, the menus and VoiceOver. Over CanvasTesting's boxes, a
// box's original 150 by 100 (`boxFrame`), the pill at `pillOrigin`.

/// A box on a board of its own, which a pocket on the root owns, and the pill for it on the root.
@MainActor private func mirrorOfBoxInPocket(_ h: EditorHarness) throws -> (box: ShapeID, pocket: ShapeID, pill: ShapeID) {
    let pocket = h.add(Pocket(CGRect(x: 800, y: 100, width: 100, height: 100)))
    expect(h.enter(pocket))
    let box = h.addBox("inside")
    expect(h.editor.showBoard(.root))
    let pill = h.addReference(to: box, label: "inside")
    expect(h.editor.perform(.expandReference, on: [pill]))
    return (box, pocket, pill)
}

@MainActor let mirrorTests = Suite("Mirrors", [
    test("a mirror's plan: the mat under the pill's middle, the body its original's size times the scale, the pill inset 16 in the frame") {
        let pill = CGRect(x: 400, y: 300, width: 120, height: 40)
        let plan = MirrorPlan(pill: pill, original: CGSize(width: 150, height: 100), scale: 2)
        expectEqual(plan.body, CGRect(x: 394, y: 348, width: 300, height: 200), "the body 10 in from the mat and 8 under the pill")
        expectEqual(plan.mat, CGRect(x: 384, y: 320, width: 320, height: 238))
        expectEqual(plan.frame, CGRect(x: 384, y: 300, width: 320, height: 258), "the pill's top half above the mat")
        let laid = CGRect(origin: CGPoint(x: pill.minX + (pill.width - plan.frame.width) * plan.anchor.x, y: pill.minY), size: plan.frame.size)
        expectEqual(laid, plan.frame, "the anchor puts the laid-out frame where the plan has it")
        let small = MirrorPlan(pill: pill, original: CGSize(width: 20, height: 10), scale: 1)
        expectEqual(small.frame.width, 152, "never narrower than the pill and its insets")
        expectEqual(CGPoint(x: 10, y: 20).applying(plan.transform(from: CGRect(x: 10, y: 20, width: 150, height: 100))), CGPoint(x: 394, y: 348),
                    "the original's top left at the body's")
        expectEqual(MirrorPlan.firstScale(for: CGSize(width: 150, height: 100)), 1, "its own size when it fits")
        expectEqual(MirrorPlan.firstScale(for: CGSize(width: 960, height: 360)), 0.5, "fitted to 480 by 360 when it doesn't")
    },
    test("Expand makes a pill a mirror in one step, the pill where it was and the body hanging under it; Collapse takes the body away") {
        let h = try referenceHarness()
        let box = h.addBox("shapes")
        let pill = h.addReference(to: box, label: "shapes")
        let stored = try require(h.editor.document[pill]?.box)
        expect(h.editor.canPerform(.expandReference, on: [pill]))
        expect(!h.editor.canPerform(.collapseReference, on: [pill]), "a pill has no body to take away")
        expect(h.editor.perform(.expandReference, on: [pill]))
        expectEqual(h.reference(pill)?.look, .mirror)
        expectEqual(h.reference(pill)?.scale, 1, "a box of 150 by 100 fits at its own size")
        expectEqual(h.editor.undoHistory.undoName, "Expand Reference")
        expectEqual(h.editor.document[pill]?.box, stored, "the pill doesn't move")
        let plan = MirrorPlan(pill: stored, original: boxFrame.size, scale: 1)
        expectEqual(h.editor.shapeContext.frame(of: pill), plan.frame, "laid out as its plan says")
        expect(!h.editor.canPerform(.expandReference, on: [pill]), "it is one")
        expect(h.editor.perform(.collapseReference, on: [pill]))
        expectEqual(h.reference(pill)?.look, .pill)
        expectEqual(h.editor.undoHistory.undoName, "Collapse Reference")
        expectEqual(h.editor.shapeContext.frame(of: pill), stored, "its pill again")
        h.editor.undo()
        expectEqual(h.editor.shapeContext.frame(of: pill), plan.frame, "undone, the mirror's back")
    },
    test("Expand is for a pill that stands for one shape it can draw: not words, an empty pill, every match, a gone or private original") {
        let h = try referenceHarness()
        let words = h.addReference(words: "stuff", at: CGPoint(x: 400, y: 100))
        let empty = h.addEmptyReference(at: CGPoint(x: 400, y: 200))
        h.addBox("first", at: CGRect(x: 100, y: 600, width: 100, height: 80))
        let every = h.addReference(query: "box", all: true, at: CGPoint(x: 400, y: 300))
        let gone = h.addReference(to: ShapeID(), label: "gone", at: CGPoint(x: 400, y: 400))
        let secret = h.addReference(to: h.addBox("secret", public: false, at: CGRect(x: 100, y: 300, width: 100, height: 80)), label: "secret",
                                    at: CGPoint(x: 400, y: 500))
        h.answer(after: 250)
        for (id, what) in [(words, "words"), (empty, "empty"), (every, "every match"), (gone, "gone"), (secret, "not public")] {
            expect(!h.editor.canPerform(.expandReference, on: [id]), what)
        }
        let first = h.addReference(query: "box", all: false, at: CGPoint(x: 400, y: 600))
        h.answer(after: 0)
        expect(h.editor.canPerform(.expandReference, on: [first]), "a query's first match can be mirrored")
    },
    test("a mirror follows its original on another board: grown there, gone and back, gone private, with no commit to the mirror") {
        let h = try referenceHarness([PocketsPlugin()])
        let (box, pocket, pill) = try mirrorOfBoxInPocket(h)
        let stored = try require(h.editor.document[pill]?.box)
        expectEqual(h.editor.shapeContext.frame(of: pill), MirrorPlan(pill: stored, original: boxFrame.size, scale: 1).frame)
        let board = BoardID(owner: pocket), revision = h.editor.file.revision(of: .root)
        h.editor.transact(on: board, "Grow") { $0.update(box, as: Box.self) { $0.props.frame.size = CGSize(width: 300, height: 200) } }
        expectEqual(h.editor.file.revision(of: .root), revision, "nothing written here")
        expectEqual(h.editor.shapeContext.frame(of: pill), MirrorPlan(pill: stored, original: CGSize(width: 300, height: 200), scale: 1).frame,
                    "grown with it")
        h.editor.transact(on: board, "Delete") { $0.delete([box]) }
        expectEqual(h.editor.shapeContext.frame(of: pill), stored, "gone: its pill")
        expectEqual(h.reference(pill)?.look, .mirror, "and still a mirror")
        h.editor.undo()
        _ = h.editor.showBoard(.root)
        expectEqual(h.editor.shapeContext.frame(of: pill), MirrorPlan(pill: stored, original: CGSize(width: 300, height: 200), scale: 1).frame,
                    "back")
        h.editor.transact(on: board, "Make Private") { $0.update(box) { $0[PrivateProperty.self] = true } }
        expectEqual(h.editor.shapeContext.frame(of: pill), stored, "private: no body, so a mirror never shows a private shape")
    },
    test("a first match's mirror follows the answer") {
        let h = try referenceHarness()
        let small = h.addBox("small", at: CGRect(x: 100, y: 100, width: 100, height: 50))
        let pill = h.addReference(query: "box", all: false)
        h.answer(after: 0)
        expect(h.editor.perform(.expandReference, on: [pill]))
        let stored = try require(h.editor.document[pill]?.box)
        expectEqual(h.editor.shapeContext.frame(of: pill)?.height, MirrorPlan(pill: stored, original: CGSize(width: 100, height: 50), scale: 1).frame.height)
        h.editor.transact { $0.delete([small]) }
        h.answer(after: 250)
        expectEqual(h.editor.shapeContext.frame(of: pill), stored, "no match: its pill")
        h.addBox("tall", at: CGRect(x: 100, y: 100, width: 100, height: 300))
        h.answer(after: 250)
        expectEqual(h.editor.shapeContext.frame(of: pill)?.height, MirrorPlan(pill: stored, original: CGSize(width: 100, height: 300), scale: 1).frame.height,
                    "the new first match's size")
    },
    test("it draws the mat and its original quieted in the body, the pill over them; through another stand-in, its pill") {
        let h = try referenceHarness([PocketsPlugin()])
        let (box, _, pill) = try mirrorOfBoxInPocket(h)
        let stored = try require(h.editor.document[pill]?.box)
        let plan = MirrorPlan(pill: stored, original: boxFrame.size, scale: 1)
        let picture = render(h.editor, size: CGSize(width: 1000, height: 800))
        let inBody = pixel(picture, at: CGPoint(x: plan.body.midX, y: plan.body.midY))
        let canvas = pixel(picture, at: CGPoint(x: 20, y: 780))
        expect(inBody != canvas, "the box is drawn in the body: \(inBody)")
        let red = inBody[0], green = inBody[1], blue = inBody[2]
        expect(max(red, green, blue) - min(red, green, blue) < 60, "quieted toward gray: \(inBody)")
        h.editor.transact(on: try require(h.editor.file.board(containing: box)), "Delete") { $0.delete([box]) }
        let after = render(h.editor, size: CGSize(width: 1000, height: 800))
        expectEqual(pixel(after, at: CGPoint(x: plan.body.midX, y: plan.body.midY)), canvas, "gone: nothing under the pill")
    },
    test("a mirror is hit on its pill and its mat, not beside the pill above the mat; its handles scale it in proportion, the pill with its corner") {
        let h = try referenceHarness([PocketsPlugin()])
        let (_, _, pill) = try mirrorOfBoxInPocket(h)
        let stored = try require(h.editor.document[pill]?.box)
        let frame = try require(h.editor.shapeContext.frame(of: pill))
        expectEqual(h.editor.shape(at: CGPoint(x: stored.midX, y: stored.midY)), pill, "the pill")
        expectEqual(h.editor.shape(at: CGPoint(x: frame.midX, y: frame.maxY - 5)), pill, "the mat")
        expectEqual(h.editor.shape(at: CGPoint(x: frame.maxX - 3, y: stored.minY + 3)), nil, "beside the pill, above the mat")
        h.editor.selectedShapeIDs = [pill]
        h.press(at: h.view(CGPoint(x: frame.maxX, y: frame.maxY)))
        h.drag(to: h.view(CGPoint(x: frame.maxX + 170, y: frame.maxY + 40)))
        h.release()
        let scale = try require(h.reference(pill)?.scale)
        expectClose(scale, (frame.width + 170 - 20) / boxFrame.width, within: 0.01)
        expectEqual(h.editor.document[pill]?.box?.origin, stored.origin, "the top left stays, and the pill with it")
        expectEqual(h.editor.shapeContext.frame(of: pill), MirrorPlan(pill: stored, original: boxFrame.size, scale: scale).frame, "in proportion")
        expectEqual(h.editor.undoHistory.undoName, "Resize")
    },
    test("the menu has Expand right under Go to Original for a pill, Collapse for a mirror, dimmed where it can't; /expand and /collapse too") {
        let h = try referenceHarness()
        let pill = h.addReference(to: h.addBox("shapes"), label: "shapes")
        let frame = try require(h.editor.document[pill]?.box)
        let menu = try require(h.secondaryClick(at: h.view(CGPoint(x: frame.midX, y: frame.midY))))
        expectEqual(Array(menu.outline.prefix(2)), ["Go to Original", "Expand"])
        try menu.choose("Expand")
        expectEqual(h.reference(pill)?.look, .mirror)
        h.editor.selectedShapeIDs = []
        let mirrorMenu = try require(h.secondaryClick(at: h.view(CGPoint(x: frame.midX, y: frame.midY))))
        expectEqual(Array(mirrorMenu.outline.prefix(2)), ["Go to Original", "Collapse"], "\(mirrorMenu.outline)")
        h.editor.selectedShapeIDs = []
        let every = h.addReference(query: "box", all: true, at: CGPoint(x: 400, y: 600))
        h.answer(after: 0)
        let everyMenu = try require(h.secondaryClick(at: h.view(CGPoint(x: 440, y: 620))))
        expect(everyMenu.outline.contains("(Expand)"), "dimmed for every match: \(everyMenu.outline)")
        _ = every
    },
    test("VoiceOver says a mirror as its pill, Mirror in Reference's place, then what its original says") {
        let h = try referenceHarness()
        let box = h.addBox("shapes")
        let pill = h.addReference(to: box, label: "shapes")
        expectEqual(h.editor.accessibleDescription(of: pill)?.kind, "Reference")
        expect(h.editor.perform(.expandReference, on: [pill]))
        let said = try require(h.editor.accessibleDescription(of: pill))
        expectEqual(said.kind, "Mirror")
        expect(said.label.hasPrefix("shapes, Mirror"), said.label)
        expectEqual(said.value, h.editor.accessibleDescription(of: box)?.label, "then the box as it says itself")
    },
    test("a mirror survives a save and a read: its look and its scale") {
        let h = try referenceHarness()
        let pill = h.addReference(to: h.addBox("shapes"), label: "shapes")
        h.editor.transact { $0.update(pill, as: Reference.self) { $0.props.look = .mirror; $0.props.scale = 0.6 } }
        let codec = BoardCodec(registry: h.editor.registry)
        let read = try codec.decode(try codec.encode(h.editor.file)).file
        expectEqual(read.root[pill]?.typed(as: Reference.self)?.props.look, .mirror)
        expectEqual(read.root[pill]?.typed(as: Reference.self)?.props.scale, 0.6)
    },
])
