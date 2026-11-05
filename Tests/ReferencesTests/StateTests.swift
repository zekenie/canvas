import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Chrome
import CoreGraphics
import Mentions
import Publishing
import References
import TestKit
import Titles

// What a reference stands for now (`ReferenceState.state(of:)`): a function of its record and the
// file, so a rename, a deletion or a change of publicness of the shape it names is seen at once, and
// which references name which shape is kept as the commits come, across the boards of the file.

/// Pockets, the shapes that own boards, titled, so a board has a name.
@MainActor private func pockets() -> [any CanvasPlugin] {
    [PocketsPlugin(), Contributor(id: "pocket-titles") { $0.title(Pocket.self, pill: false, contents: false) }]
}

/// A box on a board of its own, which a pocket on the root owns: its id, and its pocket's.
@MainActor private func boxInPocket(_ h: EditorHarness, title: String, pocketTitle: String) throws -> (box: ShapeID, pocket: ShapeID) {
    var pocket = ShapeRecord(Pocket(CGRect(x: 600, y: 100, width: 100, height: 100)))
    pocket[TitleProperty.self] = pocketTitle
    h.editor.transact { $0.insert(pocket) }
    expect(h.enter(pocket.id), "its board is shown")
    let box = h.addBox(title)
    expect(h.editor.showBoard(.root), "and the root again")
    return (box, pocket.id)
}

@MainActor let stateTests = Suite("What a reference stands for", [
    test("a public shape is live: its kind's symbol and tint, and its name, as a mention of it shows") {
        let h = try referenceHarness()
        let box = h.addBox("shapes")
        let reference = h.addReference(to: box, label: "shapes")
        guard case .live(let appearance)? = h.state(of: reference) else { return expect(false, "live: \(String(describing: h.state(of: reference)))") }
        expectEqual(appearance.label, "shapes")
        expectEqual(appearance.systemImage, "shippingbox")
        expectEqual(appearance.tint, .systemOrange)
        expect(h.state(of: reference)?.hasOriginal == true)
        expect(h.state(of: reference)?.standsForNothing == false)
    },
    test("a rename is seen at once, and the stored name stays what it was picked as") {
        let h = try referenceHarness()
        let box = h.addBox("shapes")
        let reference = h.addReference(to: box, label: "shapes")
        h.editor.transact { $0.update(box) { $0[TitleProperty.self] = "Things" } }
        expectEqual(h.state(of: reference)?.appearance?.label, "Things")
        expectEqual(h.reference(reference)?.target?.label, "shapes", "nothing was written to the reference")
    },
    test("a shape that's no longer public is not public: the pill stands for nothing, with the name the shape has; public again, live") {
        let h = try referenceHarness()
        let box = h.addBox("shapes")
        let reference = h.addReference(to: box, label: "shapes")
        h.editor.transact { $0.update(box) { $0[PublicProperty.self] = nil } }
        guard case .notPublic(let appearance)? = h.state(of: reference) else { return expect(false, "not public") }
        expectEqual(appearance.label, "shapes")
        expect(h.state(of: reference)?.standsForNothing == true)
        expect(h.state(of: reference)?.hasOriginal == true, "there's still a shape to go to")
        h.editor.undo()
        expect(h.state(of: reference) == .live(appearance), "undone, it's live again")
    },
    test("a deleted shape is missing, the name it was picked as dashed, and an undo brings it back") {
        let h = try referenceHarness()
        let box = h.addBox("shapes")
        let reference = h.addReference(to: box, label: "Shapes (picked)")
        h.editor.transact { $0.delete([box]) }
        expectEqual(h.state(of: reference), .missing(label: "Shapes (picked)"))
        expect(h.state(of: reference)?.hasOriginal == false, "nothing to go to")
        h.editor.undo()
        expect(h.state(of: reference)?.appearance != nil, "back, with its id")
    },
    test("a shape on a board the app can't show is not available, not missing") {
        let nowhere = ShapeID()      // an owner no shape of the file has
        let hidden = ShapeRecord(Box(boxFrame))
        let file = CanvasFile(root: CanvasDocument(), children: [nowhere: CanvasDocument(shapes: [AnyShapeRecord(hidden)])])
        let h = try referenceHarness(file: file)
        let reference = h.addReference(to: hidden.id, label: "Out of sight")
        expectEqual(h.state(of: reference), .unavailable(label: "Out of sight"))
        expectEqual(h.state(of: h.addReference(to: ShapeID(), label: "Gone")), .missing(label: "Gone"))
    },
    test("a reference on a board the app can't show names nothing: Topology, which keeps who names what, keeps no stand-in there") {
        let nowhere = ShapeID()      // an owner no shape of the file has
        let box = ShapeRecord(Box(boxFrame))
        var props = Reference(frame: CGRect(origin: pillOrigin, size: Reference.defaultSize))
        ReferenceEdits.pick(&props, ReferenceTarget(id: box.id, label: "On the root"))
        let hidden = ShapeRecord(props)
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(box)]), children: [nowhere: CanvasDocument(shapes: [AnyShapeRecord(hidden)])])
        let h = try referenceHarness(file: file)
        let state = try require(h.editor.references)
        expectEqual(state.directReferences(naming: [box.id]), [])
        expectEqual(state.target(of: hidden.id), nil)
        let shown = h.addReference(to: box.id, label: "On the root")
        expectEqual(state.directReferences(naming: [box.id]), [shown], "one on a board the app can show does")
        expectEqual(state.target(of: shown), box.id)
    },
    test("a shape of a kind that can't be mentioned is not available") {
        let h = try referenceHarness()
        let disc = h.add(Disc(boxFrame))
        let reference = h.addReference(to: disc, label: "A disc")
        expectEqual(h.state(of: reference), .unavailable(label: "A disc"))
    },
    test("dynamic: words with no query stand for nothing until they're interpreted; with a query, they look; and empty is empty") {
        let h = try referenceHarness()
        expectEqual(h.state(of: h.addReference(words: "blocked work")), .notInterpreted(text: "blocked work"))
        expectEqual(h.state(of: h.addReference(words: "blocked work", query: "box")), .finding(text: "blocked work"))
        expectEqual(h.state(of: h.addReference(words: "", query: "box")), .finding(text: "box"), "an agent's, written by its query alone")
        expectEqual(h.state(of: h.addEmptyReference()), .empty)
        expectEqual(h.state(of: h.addBox("not a reference")), nil)
    },
    test("which references name which shape is kept as commits come, undo and redo, and a reference re-pointed") {
        let h = try referenceHarness()
        let box = h.addBox("a"), tile = h.addTile("b")
        let state = try require(h.editor.references)
        expectEqual(state.directReferences(naming: [box]), [])
        let first = h.addReference(to: box, label: "a"), second = h.addReference(to: box, label: "a", at: CGPoint(x: 400, y: 400))
        expectEqual(state.directReferences(naming: [box]), [first, second])
        expectEqual(state.target(of: first), box)
        h.editor.transact { $0.update(second, as: Reference.self) { ReferenceEdits.pick(&$0.props, ReferenceTarget(id: tile, label: "b")) } }
        expectEqual(state.directReferences(naming: [box]), [first], "re-pointed, it names the other")
        expectEqual(state.directReferences(naming: [tile]), [second])
        h.editor.transact { $0.delete([first]) }
        expectEqual(state.directReferences(naming: [box]), [])
        h.editor.undo()
        expectEqual(state.directReferences(naming: [box]), [first])
        h.editor.undo()
        expectEqual(state.directReferences(naming: [box]), [first, second], "undone to when it named the box")
        h.editor.redo()
        expectEqual(state.directReferences(naming: [box]), [first], "and redone")
    },
    test("a drag, which only moves, costs the index nothing it can't answer: the references still name their shapes") {
        let h = try referenceHarness()
        let box = h.addBox("a")
        let reference = h.addReference(to: box, label: "a")
        h.editor.transact { $0.moveBox(reference, to: CGPoint(x: 10, y: 10)) }
        expectEqual(try require(h.editor.references).directReferences(naming: [box]), [reference])
    },
    test("across boards: a reference to a shape on another board, and a reference on one, are both kept") {
        let h = try referenceHarness(pockets())
        let (box, pocket) = try boxInPocket(h, title: "inside", pocketTitle: "Drawer")
        let outside = h.addReference(to: box, label: "inside")
        let state = try require(h.editor.references)
        expectEqual(state.directReferences(naming: [box]), [outside])
        expect(h.state(of: outside)?.appearance?.label == "inside", "its shape is read on the board it's on")
        // A reference on the other board, to a shape on the root.
        let rootBox = h.addBox("root box", at: CGRect(x: 300, y: 100, width: 100, height: 100))
        expect(h.enter(pocket))
        let inner = h.addReference(to: rootBox, label: "root box")
        expectEqual(state.directReferences(naming: [rootBox]), [inner])
        expect(h.editor.showBoard(.root))
        // Deleting the pocket takes its board, and the reference on it, with it.
        h.editor.transact { $0.delete([pocket]) }
        expectEqual(state.directReferences(naming: [rootBox]), [], "gone with its board")
        expectEqual(h.state(of: outside), .missing(label: "inside"), "and what was on it is missing")
        h.editor.undo()
        expectEqual(state.directReferences(naming: [rootBox]), [inner], "back with it")
        expect(h.state(of: outside)?.appearance != nil)
    },
    test("a file put in place is read afresh") {
        let h = try referenceHarness()
        let box = h.addBox("a")
        let reference = h.addReference(to: box, label: "a")
        let state = try require(h.editor.references)
        let other = try referenceHarness()
        let box2 = other.addBox("b")
        let reference2 = other.addReference(to: box2, label: "b")
        h.editor.replaceFile(with: other.editor.file)
        expectEqual(state.directReferences(naming: [box]), [])
        expectEqual(state.directReferences(naming: [box2]), [reference2])
        expectEqual(state.target(of: reference), nil)
    },
    test("the panel's header says what it stands for, and where, when that isn't the board shown") {
        let h = try referenceHarness(pockets())
        let box = h.addBox("shapes")
        let live = h.addReference(to: box, label: "shapes")
        let state = try require(h.editor.references)
        let props = try require(h.reference(live))
        let kind = try require(state.state(of: props).appearance).kindName
        expectEqual(state.header(of: props), ReferenceHeaderContent(symbol: "shippingbox", title: "shapes", subtitle: kind))
        let (inside, _) = try boxInPocket(h, title: "inside", pocketTitle: "Drawer")
        let far = try require(h.reference(h.addReference(to: inside, label: "inside")))
        expectEqual(state.header(of: far), ReferenceHeaderContent(symbol: "shippingbox", title: "inside", subtitle: kind + " · Drawer", lead: kind + " · ",
                                                                  place: [PlaceStep(name: "Drawer", opensBoard: true)]),
                    "the kind, then the board it's on, which the header folds at its width")
    },
])
