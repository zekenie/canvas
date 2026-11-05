import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Chrome
import Mentions
import Publishing
import QueryTranslation
import References
import TableOfContents
import TestKit
import TextEditing
import Titles
import Topology

// The path a reference's row says before the name of what it stands for: the frames and boards that
// shape is inside and the reference isn't, outermost first, over CanvasTesting's corrals (which hold
// shapes, as frames do) and pockets (which own boards), each named by its title. A change to a shape
// the path was read from remakes the row, and no other.

/// Corrals named by Titles, as `pocketTitles` names pockets.
private let corralTitles = Contributor(id: "corral-titles") { $0.title(Corral.self, pill: false, contents: false) }

@MainActor private func pathHarness() throws -> EditorHarness {
    try referenceHarness([PocketsPlugin(), CorralsPlugin(), pocketTitles, corralTitles])
}

extension EditorHarness {
    /// The pill `id` as wide as a pill is, so its place is said whole.
    fileprivate func widen(_ ids: ShapeID...) {
        for id in ids { editor.transact { $0.update(id, as: Reference.self) { $0.props.frame.size.width = 280 } } }
    }

    /// A corral or a pocket titled `title` on the board shown, `at` its top left.
    @discardableResult
    fileprivate func addCorral(_ title: String?, at origin: CGPoint = CGPoint(x: 0, y: 0)) -> ShapeID {
        var corral = ShapeRecord(Corral(CGRect(origin: origin, size: CGSize(width: 300, height: 300))))
        corral[TitleProperty.self] = title
        editor.transact { $0.insert(corral) }
        return corral.id
    }

    @discardableResult
    fileprivate func addPocket(_ title: String?, at origin: CGPoint = CGPoint(x: 600, y: 0)) -> ShapeID {
        var pocket = ShapeRecord(Pocket(CGRect(origin: origin, size: CGSize(width: 100, height: 100))))
        pocket[TitleProperty.self] = title
        editor.transact { $0.insert(pocket) }
        return pocket.id
    }
}

/// The row of `id` among `entries`, at any depth.
@MainActor private func find(_ id: ShapeID, in entries: [ContentsEntry]) -> ContentsEntry? {
    for entry in entries {
        if entry.id == id { return entry }
        if let found = find(id, in: entry.children ?? []) { return found }
    }
    return nil
}

@MainActor private func label(_ h: EditorHarness, _ id: ShapeID) throws -> ContentsLabel {
    try require(try require(find(id, in: try require(h.editor.tableOfContents).entries), "a row for the reference").label)
}

@MainActor private func path(_ h: EditorHarness, _ id: ShapeID) throws -> [String] { try label(h, id).path.map(\.text) }

@MainActor let pathTests = Suite("The path a reference's row says before its name", [
    test("on a subboard, a reference to a shape in a frame on the root says the top board, as its pill does, and the frame; in a frame of its own it nests there and says the same") {
        let h = try pathHarness()
        let foo = h.addCorral("foo"), bar = h.addBox("bar")
        h.editor.put([bar], in: foo)
        let sub = h.addPocket("sub")
        expect(h.enter(sub))
        let reference = h.addReference(to: bar, label: "bar")
        let other = h.addBox("something else", at: CGRect(x: 700, y: 400, width: 100, height: 100))
        expectEqual(try path(h, reference), ["Board", "foo"])
        expectEqual(try label(h, reference).text, "bar")
        expectEqual(try label(h, reference).help, "Board › foo › bar", "the tooltip has it whole")
        expectEqual(try label(h, other).path, [], "a shape's own row has none")
        expectEqual(try label(h, reference).path.map(\.isPlaceholder), [false, false], "a title, at the path's strength")
        let ffff = h.addCorral("ffff", at: CGPoint(x: 300, y: 200))
        h.editor.put([reference], in: ffff)
        let contents = try require(h.editor.tableOfContents)
        let frameRow = try require(contents.entries.first { $0.id == ffff }, "the frame's row")
        expectEqual(frameRow.children?.map(\.id), [reference], "nested under its own frame, as any shape is")
        expectEqual(try path(h, reference), ["Board", "foo"], "where its original is, not where it is")
    },
    test("only what the reference isn't inside too: nothing for a shape in its frame or on its board; the board it is on for one above it; the frames and boards between otherwise") {
        let h = try pathHarness()
        let zone = h.addCorral("zone"), inner = h.addCorral("inner", at: CGPoint(x: 20, y: 20))
        let near = h.addBox("near"), deep = h.addBox("deep", at: CGRect(x: 40, y: 40, width: 50, height: 50))
        let loose = h.addBox("loose", at: CGRect(x: 0, y: 500, width: 100, height: 100))
        h.editor.put([inner, near], in: zone)
        h.editor.put([deep], in: inner)
        let beside = h.addReference(to: near, label: "near")
        expectEqual(try path(h, beside), ["zone"], "from the board, the frame it's in")
        h.editor.put([beside], in: zone)
        expectEqual(try path(h, beside), [], "in the same frame")
        let down = h.addReference(to: deep, label: "deep", at: CGPoint(x: 400, y: 400))
        expectEqual(try path(h, down), ["zone", "inner"], "outermost first")
        h.editor.put([down], in: zone)
        expectEqual(try path(h, down), ["inner"], "less the frame they share")
        let up = h.addReference(to: loose, label: "loose", at: CGPoint(x: 400, y: 500))
        h.editor.put([up], in: inner)
        expectEqual(try path(h, up), [], "a shape above it")
        // Boards: a shape on another subboard's board is under that subboard; one on the board
        // above is led by that board, as the pill says it.
        let a = h.addPocket("A"), b = h.addPocket("B", at: CGPoint(x: 800, y: 0))
        expect(h.enter(b))
        let pen = h.addCorral("pen"), far = h.addBox("far")
        h.editor.put([far], in: pen)
        let here = h.addReference(to: far, label: "far")
        expectEqual(try path(h, here), ["pen"], "on its own board: the frame, not the board")
        expect(h.editor.showBoard(.root))
        expectEqual(try path(h, h.addReference(to: far, label: "far", at: CGPoint(x: 400, y: 600))), ["B", "pen"])
        expect(h.enter(a))
        expectEqual(try path(h, h.addReference(to: far, label: "far")), ["B", "pen"], "from a sibling board")
        expectEqual(try path(h, h.addReference(to: loose, label: "loose", at: CGPoint(x: 400, y: 400))), ["Board"], "on the board above: its name")
        expectEqual(try path(h, h.addReference(to: deep, label: "deep", at: CGPoint(x: 400, y: 500))), ["Board", "zone", "inner"])
    },
    test("a pill inside a frame inside its original's says nothing, pill and row alike, until its frame is taken out: then the original's frame") {
        let h = try pathHarness()
        let outer = h.addCorral("Outer"), inner = h.addCorral("Inner", at: CGPoint(x: 400, y: 0))
        let acme = h.addBox("Acme")
        h.editor.put([acme, inner], in: outer)
        let pill = h.addReference(to: acme, label: "Acme", at: CGPoint(x: 420, y: 40))
        h.editor.put([pill], in: inner)
        h.widen(pill)
        _ = render(h.editor)
        let state = try require(h.editor.references)
        expectEqual(state.drawnPlace(of: pill)?.text, nil, "in its original's frame: nothing to say")
        expectEqual(try path(h, pill), [], "and its row nothing")
        h.editor.transact { $0.setContainer(inner, to: nil) }
        _ = render(h.editor)
        expectEqual(state.drawnPlace(of: pill)?.text, "Outer", "the frame between taken out: the pill says where its original is")
        expectEqual(try path(h, pill), ["Outer"], "and so does its row")
    },
    test("a query's pill says where its first match is, and follows it into another frame") {
        let h = try pathHarness()
        let drawer = h.addCorral("Drawer"), bin = h.addCorral("Bin", at: CGPoint(x: 0, y: 400))
        let acme = h.addBox("Acme")
        h.editor.put([acme], in: drawer)
        let first = h.addReference(words: "acme", query: "\"Acme\"", at: CGPoint(x: 400, y: 200))
        h.widen(first)
        h.answer()
        _ = render(h.editor)
        let state = try require(h.editor.references)
        expectEqual(state.drawnPlace(of: first)?.text, "Drawer")
        h.editor.transact { $0.setContainer(acme, to: bin) }
        _ = render(h.editor)
        expectEqual(state.drawnPlace(of: first)?.text, "Bin", "the match moved: its place is read again")
    },
    test("an untitled frame or board is called by its kind; a shape gone private keeps its path, one deleted has none") {
        let h = try pathHarness()
        let frame = h.addCorral(nil), pocket = h.addPocket(nil)
        let box = h.addBox("bar")
        h.editor.put([box], in: frame)
        let reference = h.addReference(to: box, label: "bar")
        let registry = h.editor.registry
        expectEqual(try path(h, reference), [registry.label(of: Corral.kind).name])
        expectEqual(try label(h, reference).path.map(\.isPlaceholder), [true], "fainter: nobody named it that")
        expect(h.enter(pocket))
        let inside = h.addBox("inside")
        expect(h.editor.showBoard(.root))
        let into = h.addReference(to: inside, label: "inside", at: CGPoint(x: 400, y: 400))
        expectEqual(try path(h, into), [registry.label(of: Pocket.kind).name])
        expectEqual(try label(h, into).path.map(\.isPlaceholder), [true])
        h.editor.transact { $0.update(pocket) { $0[TitleProperty.self] = "Plans" } }
        expectEqual(try label(h, into).path, [ContentsPathName("Plans", opensBoard: true)], "named: a title, and a board")
        expectEqual(try label(h, reference).path.map(\.opensBoard), [false], "a frame is a region of its board")
        h.editor.transact { $0.update(box) { $0[PublicProperty.self] = nil } }
        expect(try label(h, reference).isPlaceholder, "not public: dimmed")
        expectEqual(try path(h, reference).count, 1, "still where it is")
        expectEqual(try label(h, reference).help, "\(registry.label(of: Corral.kind).name) › bar")
        h.editor.transact { $0.delete([box]) }
        expectEqual(try path(h, reference), [], "nowhere")
        expectEqual(try label(h, reference).help, nil)
    },
    test("renaming a frame its path names, or putting the shape or the frame somewhere else, remakes its row and no other; a move remakes none") {
        let h = try pathHarness()
        let foo = h.addCorral("foo"), baz = h.addCorral("baz", at: CGPoint(x: 0, y: 400)), outer = h.addCorral("outer", at: CGPoint(x: 400, y: 400))
        let bar = h.addBox("bar"), plain = h.addBox("plain", at: CGRect(x: 0, y: 720, width: 100, height: 100))
        h.editor.put([bar], in: foo)
        let reference = h.addReference(to: bar, label: "bar", at: CGPoint(x: 800, y: 300))
        let aside = h.addReference(to: plain, label: "plain", at: CGPoint(x: 800, y: 400))
        let contents = try require(h.editor.tableOfContents), references = try require(h.editor.references)
        expectEqual(try path(h, reference), ["foo"])
        expectEqual(try path(h, aside), [])
        var read = references.pathsRead
        /// How many references' rows a change made again: each reads its path as it's made.
        @MainActor func remade(_ change: @MainActor () -> Void) -> Int {
            change()
            _ = contents.entries
            defer { read = references.pathsRead }
            return references.pathsRead - read
        }
        expectEqual(remade { h.editor.transact { $0.update(foo) { $0[TitleProperty.self] = "food" } } }, 1, "the reference's row, for the frame's rename")
        expectEqual(try path(h, reference), ["food"])
        expectEqual(remade { h.editor.transact { $0.update(baz) { $0[TitleProperty.self] = "bazaar" } } }, 0, "a frame no path names")
        expectEqual(remade { h.editor.transact { $0.moveBox(foo, to: CGPoint(x: 10, y: 10)) } }, 0, "a move")
        expectEqual(remade { h.editor.put([bar], in: baz) }, 1, "the shape put in another frame")
        expectEqual(try path(h, reference), ["bazaar"])
        expectEqual(remade { h.editor.transact { $0.update(foo) { $0[TitleProperty.self] = "foo" } } }, 0, "the frame it left")
        expectEqual(remade { h.editor.put([baz], in: outer) }, 1, "its frame put in another")
        expectEqual(try path(h, reference), ["outer", "bazaar"])
        expectEqual(remade { h.editor.transact { $0.update(outer) { $0[TitleProperty.self] = "out" } } }, 1, "the frame its frame is in")
        expectEqual(try path(h, reference), ["out", "bazaar"])
        h.editor.undo()
        h.editor.undo()
        expectEqual(try path(h, reference), ["bazaar"], "undone")
        read = references.pathsRead
        expectEqual(remade { h.editor.put([bar], in: nil) }, 1, "taken out")
        expectEqual(try path(h, reference), [])
        expectEqual(remade { h.editor.transact { $0.update(baz) { $0[TitleProperty.self] = "baz" } } }, 0, "a frame it's no longer in")
        expectEqual(try path(h, aside), [], "the other reference never read a frame")
    },
    test("across boards: a frame renamed on a board that isn't shown, and the reference's own board put in the frame its original is under") {
        let h = try pathHarness()
        let zone = h.addCorral("zone"), foo = h.addCorral("foo", at: CGPoint(x: 20, y: 20)), bar = h.addBox("bar", at: CGRect(x: 40, y: 40, width: 50, height: 50))
        h.editor.put([foo], in: zone)
        h.editor.put([bar], in: foo)
        let sub = h.addPocket("sub")
        expect(h.enter(sub))
        let reference = h.addReference(to: bar, label: "bar")
        let contents = try require(h.editor.tableOfContents)
        expectEqual(try path(h, reference), ["Board", "zone", "foo"])
        h.editor.transact(on: .root) { $0.update(foo) { $0[TitleProperty.self] = "food" } }
        expectEqual(try path(h, reference), ["Board", "zone", "food"], "a write to the board above")
        h.editor.transact(on: .root) { $0.setContainer(sub, to: zone) }
        expectEqual(try path(h, reference), ["Board", "food"], "its board is in the zone now, as its original is")
        // Away, on the root: what changes there reaches the row when its board is shown again.
        expect(h.editor.showBoard(.root))
        h.editor.transact { $0.update(foo) { $0[TitleProperty.self] = "feed" } }
        expectEqual(try require(contents.outline(of: BoardID(owner: sub)).first { $0.id == reference }?.label).path.map(\.text), ["Board", "feed"], "under its subboard's row")
        expect(h.enter(sub))
        expectEqual(try path(h, reference), ["Board", "feed"])
    },

    // MARK: Where a shape is, in the pill, the header, the list and the matches

    test("a pill says where its shape is by its path from where the pill is: the frames they don't share; the board's name for a shape in none") {
        let h = try pathHarness()
        let cart = h.addCorral("Cart"), items = h.addCorral("Items", at: CGPoint(x: 20, y: 20))
        h.editor.put([items], in: cart)
        let note = h.addBox("Checkout", at: CGRect(x: 40, y: 40, width: 50, height: 50))
        h.editor.put([note], in: items)
        let outside = h.addReference(to: note, label: "Checkout", at: CGPoint(x: 800, y: 400))
        let inCart = h.addReference(to: note, label: "Checkout", at: CGPoint(x: 100, y: 200))
        h.editor.put([inCart], in: cart)
        let inItems = h.addReference(to: note, label: "Checkout", at: CGPoint(x: 100, y: 250))
        h.editor.put([inItems], in: items)
        _ = render(h.editor)
        let state = try require(h.editor.references)
        expectEqual(state.drawnPlace(of: outside)?.text, "Cart › Items")
        expectEqual(state.drawnPlace(of: inCart)?.text, "Items", "the frame it is in is left out")
        expectEqual(state.drawnPlace(of: inItems)?.text, nil, "in the same frame: as it always looked")
        // A rename of a frame its path was read from is said at the next draw, in the pills that read it.
        h.editor.transact { $0.update(cart) { $0[TitleProperty.self] = "Basket" } }
        _ = render(h.editor)
        expectEqual(state.drawnPlace(of: outside)?.text, "Basket › Items")
        expectEqual(state.drawnPlace(of: inCart)?.text, "Items")
        // The pill's own frame put in the frame its shape is in changes what it shares.
        h.editor.put([cart], in: nil)
        h.editor.put([items], in: nil)
        _ = render(h.editor)
        expectEqual(state.drawnPlace(of: outside)?.text, "Items", "the frame taken out of Basket")
        expectEqual(state.drawnPlace(of: inCart)?.text, "Items")
        expectEqual(state.drawnPlace(of: inItems)?.text, nil)
        h.editor.put([note], in: nil)
        _ = render(h.editor)
        expectEqual(state.drawnPlace(of: outside)?.text, nil, "on the board directly, as the pill is")
        // A shape in no frame on another board says that board's name.
        let pocket = h.addPocket("Clients")
        expect(h.enter(pocket))
        let far = h.addBox("Acme")
        expect(h.editor.showBoard(.root))
        let farPill = h.addReference(to: far, label: "Acme", at: CGPoint(x: 800, y: 500))
        _ = render(h.editor)
        expectEqual(state.drawnPlace(of: farPill)?.text, "Clients")
        // And a frame on that board adds to it, as a path does.
        expect(h.enter(pocket))
        let drawer = h.addCorral("Drawer", at: CGPoint(x: 300, y: 300))
        h.editor.put([far], in: drawer)
        expect(h.editor.showBoard(.root))
        _ = render(h.editor)
        expectEqual(state.drawnPlaceSteps(of: farPill)?.map(\.name), ["Clients", "Drawer"])
        expectEqual(state.drawnPlaceSteps(of: farPill)?.map(\.opensBoard), [true, false], "the pocket opens a board, the corral does not")
    },

    test("when the shape is on another board and no step opens one, that board leads: the file's name for the root, \"Board\" with none, else its owner") {
        let h = try pathHarness()
        let drawer = h.addCorral("Drawer")
        let plan = h.addBox("Plan", at: CGRect(x: 40, y: 40, width: 50, height: 50))
        h.editor.put([plan], in: drawer)
        let loose = h.addBox("Loose", at: CGRect(x: 500, y: 400, width: 50, height: 50))
        let clients = h.addPocket("Clients")
        expect(h.enter(clients))
        let inFrame = h.addReference(to: plan, label: "Plan")
        let onRoot = h.addReference(to: loose, label: "Loose", at: CGPoint(x: 400, y: 400))
        h.editor.nameRoot("Shop")
        h.widen(inFrame, onRoot)
        _ = render(h.editor)
        let state = try require(h.editor.references)
        expectEqual(state.drawnPlace(of: inFrame)?.text, "Shop › Drawer", "a frame on the root, from a pocket's board")
        expectEqual(state.drawnPlaceSteps(of: inFrame)?.map(\.opensBoard), [true, false], "the lead is a board, the frame is not")
        expectEqual(state.drawnPlace(of: onRoot)?.text, "Shop", "a shape on the root in no frame: the root alone")
        expectEqual(state.drawnPlaceSteps(of: onRoot), [PlaceStep(name: "Shop", opensBoard: true)])
        // The file renamed, with no commit: said at the next draw.
        h.editor.nameRoot("Atlas")
        _ = render(h.editor)
        expectEqual(state.drawnPlace(of: inFrame)?.text, "Atlas › Drawer")
        expectEqual(state.drawnPlace(of: onRoot)?.text, "Atlas")
        // A file with no name: "Board", as Boards names the root everywhere.
        h.editor.nameRoot("")
        _ = render(h.editor)
        expectEqual(state.drawnPlace(of: onRoot)?.text, "Board")
    },
    test("the board that leads is its owner's when it isn't the root: a pill on a pocket's inner board, its shape in a frame on the pocket's own board") {
        let h = try pathHarness()
        let clients = h.addPocket("Clients")
        expect(h.enter(clients))
        let drawer = h.addCorral("Drawer")
        let plan = h.addBox("Plan", at: CGRect(x: 40, y: 40, width: 50, height: 50))
        h.editor.put([plan], in: drawer)
        let inner = h.addPocket("Inner")
        expect(h.enter(inner))
        let pill = h.addReference(to: plan, label: "Plan")
        h.widen(pill)
        _ = render(h.editor)
        let state = try require(h.editor.references)
        expectEqual(state.drawnPlace(of: pill)?.text, "Clients › Drawer")
        expectEqual(state.drawnPlaceSteps(of: pill)?.map(\.opensBoard), [true, false])
        // Untitled, it is called as its board is.
        h.editor.transact(on: BoardID.root) { $0.update(clients) { $0[TitleProperty.self] = nil } }
        _ = render(h.editor)
        let lead = try require(state.drawnPlaceSteps(of: pill)?.first)
        expect(lead.isPlaceholder && lead.opensBoard, "untitled, a placeholder that opens a board")
        expectEqual(lead.name, h.editor.registry.label(of: Pocket.kind).name, "called as a path calls a container of its kind")
    },
    test("a step that opens a board leads on its own: the original on a pocket's board, from the root, gets no other lead") {
        let h = try pathHarness()
        let clients = h.addPocket("Clients")
        expect(h.enter(clients))
        let drawer = h.addCorral("Drawer")
        let plan = h.addBox("Plan", at: CGRect(x: 40, y: 40, width: 50, height: 50))
        h.editor.put([plan], in: drawer)
        expect(h.editor.showBoard(.root))
        h.editor.nameRoot("Shop")
        let pill = h.addReference(to: plan, label: "Plan")
        h.widen(pill)
        _ = render(h.editor)
        let state = try require(h.editor.references)
        expectEqual(state.drawnPlace(of: pill)?.text, "Clients › Drawer", "not Shop › Clients › Drawer")
        expectEqual(state.drawnPlaceSteps(of: pill)?.map(\.name), ["Clients", "Drawer"])
    },
    test("the line a pill keeps is folded at its width less 46, so a wider pill says more of a long place, and a frame folds nothing") {
        let h = try pathHarness()
        let outer = h.addCorral("Platform layer"), middle = h.addCorral("Horizontals: shape traits", at: CGPoint(x: 10, y: 10)), inner = h.addCorral("Types", at: CGPoint(x: 20, y: 20))
        h.editor.put([middle], in: outer)
        h.editor.put([inner], in: middle)
        let note = h.addBox("Fields", at: CGRect(x: 40, y: 40, width: 50, height: 50))
        h.editor.put([note], in: inner)
        let narrow = h.addReference(to: note, label: "Fields", at: CGPoint(x: 800, y: 100))
        let wide = h.addReference(to: note, label: "Fields", at: CGPoint(x: 800, y: 200))
        h.editor.transact { $0.update(narrow, as: Reference.self) { $0.props.frame.size.width = 160 } }
        h.editor.transact { $0.update(wide, as: Reference.self) { $0.props.frame.size.width = 280 } }
        _ = render(h.editor)
        let state = try require(h.editor.references)
        let whole = ["Platform layer", "Horizontals: shape traits", "Types"]
        expectEqual(state.drawnPlaceSteps(of: narrow)?.map(\.name), whole, "the steps are whole")
        let short = try require(state.drawnPlace(of: narrow)), long = try require(state.drawnPlace(of: wide))
        expect(short.isFolded || short.isCut, "folded at 114: \(short.text)")
        expect(short.width <= 160 - 46, "within the room: \(short.width)")
        expect(long.width <= 280 - 46 && long.width > short.width, "a wider pill, a longer line: \(long.text)")
        // A pill in the frame the shape is in folds nothing: it has no place.
        h.editor.put([narrow], in: inner)
        _ = render(h.editor)
        expectEqual(state.drawnPlace(of: narrow)?.text, nil)
    },
    test("a pill made by name and told where it sits is as wide as what it will say there, as a pick is fitted; with nothing to say, as wide as its name") {
        let h = try pathHarness()
        let cart = h.addCorral("Shopping cart"), items = h.addCorral("Items in the cart", at: CGPoint(x: 20, y: 20))
        h.editor.put([items], in: cart)
        let note = h.addBox("Checkout", at: CGRect(x: 40, y: 40, width: 50, height: 50))
        h.editor.put([note], in: items)
        let standIns = h.editor.registry.standIns
        @MainActor func made(for target: ShapeID, _ label: String, _ seat: StandInSeat) throws -> ShapeRecord<Reference> {
            var record = try require(standIns.make(Reference.kind, standingFor: target, label: label))
            standIns.seat(&record, at: seat, in: h.editor.shapeContext)
            return try require(record.typed(as: Reference.self))
        }
        let named = try require(standIns.make(Reference.kind, standingFor: note, label: "Checkout")?.typed(as: Reference.self)).props
        @MainActor func width(_ place: [String]) -> CGFloat { ReferenceEdits.width(of: named, place: place.map { PlaceStep(name: $0) }) }
        expect(width(["Shopping cart", "Items in the cart"]) > width([]))
        expectEqual(named.frame.width, width([]), "made, it is as wide as its name")
        expectEqual(try made(for: note, "Checkout", .file(container: nil, board: .root)).props.frame.width, width(["Shopping cart", "Items in the cart"]))
        expectEqual(try made(for: note, "Checkout", .file(container: cart, board: .root)).props.frame.width, width(["Items in the cart"]), "the frame it sits in is left out")
        expectEqual(try made(for: note, "Checkout", .file(container: items, board: .root)).props.frame.width, width([]), "in its shape's own frame")
        expectEqual(try made(for: note, "Checkout", .written(shape: ["Shopping cart", "Items in the cart"], seat: [])).props.frame.width, width(["Shopping cart", "Items in the cart"]), "as a measure writes it")
        expectEqual(try made(for: note, "Checkout", .written(shape: ["Shopping cart", "Items in the cart"], seat: ["Shopping cart"])).props.frame.width, width(["Items in the cart"]))
        expectEqual(try made(for: note, "Checkout", .written(shape: ["Shopping cart"], seat: ["Shopping cart", "Bag"])).props.frame.width, width([]))
        // Put down where it was told it sits, it says what it was fitted for.
        var outside = try made(for: note, "Checkout", .file(container: nil, board: .root))
        outside.props.frame.origin = CGPoint(x: 800, y: 400)
        h.editor.transact { $0.insert(outside) }
        _ = render(h.editor)
        expectEqual(try require(h.editor.references).drawnPlace(of: outside.id)?.text, "Shopping cart › Items in the cart")
        // A shape on a pocket's board in no frame is where that board is, seen from the root; from its own board, nowhere.
        let pocket = h.addPocket("Clients")
        expect(h.enter(pocket))
        let far = h.addBox("Acme")
        expect(h.editor.showBoard(.root))
        let acme = try require(standIns.make(Reference.kind, standingFor: far, label: "Acme")?.typed(as: Reference.self)).props
        expectEqual(try made(for: far, "Acme", .file(container: nil, board: .root)).props.frame.width, ReferenceEdits.width(of: acme, place: [PlaceStep(name: "Clients", opensBoard: true)]))
        expectEqual(try made(for: far, "Acme", .file(container: nil, board: BoardID(owner: pocket))).props.frame.width, acme.frame.width)
    },
    test("a pill told where it sits keeps the width it was fitted to, whatever that comes to, the width a pill is placed at among them") {
        let h = try pathHarness()
        let note = h.addBox("x")
        let standIns = h.editor.registry.standIns
        // Short names and places, some of which come to 120, the width the tool places a pill at: the kind's derive takes a
        // pill that wide for one placed, not one fitted to a place, so a seat that derived it again would lose the place.
        for name in ["ui", "db", "x", "io", "api", "app", "lib", "web", "auth", "core"] {
            for place in ["Billing", "Cart", "Items", "Ops", "Payments", "Sync", "Admin", "Search"] {
                var record = try require(standIns.make(Reference.kind, standingFor: note, label: name))
                standIns.seat(&record, at: .written(shape: [place], seat: []), in: h.editor.shapeContext)
                let props = try require(record.typed(as: Reference.self)).props
                expectEqual(props.frame.width, ReferenceEdits.width(of: props, place: [PlaceStep(name: place)]), "\(name) in \(place)")
            }
        }
    },
    test("the list over a pill's field says a shape's path: \"Kind · path\" for two called alike, the path for one alone") {
        let h = try pathHarness()
        let alpha = h.addCorral("Alpha"), beta = h.addCorral("Beta", at: CGPoint(x: 400, y: 0))
        let a = h.addBox("Plan", at: CGRect(x: 20, y: 20, width: 50, height: 50)), b = h.addBox("Plan", at: CGRect(x: 420, y: 20, width: 50, height: 50))
        let solo = h.addBox("Budget", at: CGRect(x: 40, y: 100, width: 50, height: 50))
        h.editor.put([a, solo], in: alpha)
        h.editor.put([b], in: beta)
        let picker = ReferencePicker(state: try require(h.editor.references), owner: nil, text: "")
        let kind = h.editor.registry.label(of: Box.kind).name
        @MainActor func lines(_ text: String) -> [(title: String, detail: String?, spoken: String)] {
            picker.setText(text)
            return picker.list.rows.compactMap(\.item).filter { $0.symbol != "magnifyingglass" }.map { ($0.title, $0.detail, $0.spoken) }
        }
        let plans = lines("plan")
        expectEqual(Set(plans.compactMap(\.detail)), ["\(kind) · Alpha", "\(kind) · Beta"])
        expectEqual(Set(plans.map(\.spoken)).count, 2, "told apart to a screen reader too")
        expect(plans.allSatisfy { $0.spoken.contains(", in ") }, "\(plans.map(\.spoken))")
        let one = lines("budget")
        expectEqual(one.map(\.detail), ["Alpha"], "one alone: its path")
        expectEqual(one.map(\.spoken), ["Budget, \(kind), in Alpha, 1 of 1"])
        // The words of a path find it: \"beta plan\" is the Plan in Beta.
        let byPath = lines("beta plan")
        expectEqual(byPath.map(\.detail), ["Beta"], "the shapes found by their path, alone in their name now")
    },

    test("the panel's header says \"Kind · path\", and the Matches rows the path, from the board shown") {
        let h = try pathHarness()
        let cart = h.addCorral("Cart"), items = h.addCorral("Items", at: CGPoint(x: 20, y: 20))
        h.editor.put([items], in: cart)
        let note = h.addBox("Checkout", at: CGRect(x: 40, y: 40, width: 50, height: 50))
        h.editor.put([note], in: items)
        let pill = h.addReference(to: note, label: "Checkout", at: CGPoint(x: 800, y: 400))
        let query = h.addReference(query: "box[title=\"Checkout\"]", at: CGPoint(x: 800, y: 500))
        h.answer()
        let state = try require(h.editor.references)
        let kind = try require(h.state(of: pill)?.appearance).kindName
        expectEqual(state.header(of: try require(h.reference(pill)), id: pill).subtitle, kind + " · Cart › Items")
        expectEqual(state.matchRows(of: query).rows.map(\.place), ["Cart › Items"])
        // From inside the frame the shape is in, the frames the board shown is in are its own: left out.
        let loose = h.addBox("Loose", at: CGRect(x: 600, y: 600, width: 50, height: 50))
        let far = h.addReference(to: loose, label: "Loose", at: CGPoint(x: 800, y: 300))
        expectEqual(state.header(of: try require(h.reference(far)), id: far).subtitle, try require(h.state(of: far)?.appearance).kindName, "directly on the board shown: its kind alone")
    },
])
