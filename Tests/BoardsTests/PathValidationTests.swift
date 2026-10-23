import Adornments
import Boards
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Keyboard
import Selection
import SlashCommands
import TestKit
import Titles
import Topology
import Validation

// Fixtures only, so these tests show the path warning knows no real kind: cards, pockets (which own
// boards) and corrals (which hold shapes, as frames do) are named (the title Titles keeps), discs'
// titles are worked out from their size, and boxes have none.

/// Titles for the fixtures: cards, pockets and corrals named, discs worked out.
@MainActor private var fixtureTitles: Contributor {
    Contributor(id: "fixture-titles") { registrar in
        registrar.title(Card.self, contents: false)
        registrar.title(Pocket.self, contents: false)
        registrar.title(Corral.self, contents: false)
        registrar.title(Disc.self, contents: false) { disc in "Disc, \(Int(disc.props.frame.width)) × \(Int(disc.props.frame.height))" }
    }
}

/// A harness on `file`, with Topology (the tree paths are read from), Titles (and the slash commands
/// it offers), Validation and `PathValidationPlugin`.
@MainActor private func harness(_ file: CanvasFile = CanvasFile()) throws -> EditorHarness {
    try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FixturesPlugin(), CardsPlugin(), PocketsPlugin(), CorralsPlugin(),
                                ValidationPlugin(), AdornmentsPlugin(), SlashCommandsPlugin(), TitlesPlugin(), fixtureTitles, PathValidationPlugin()], file: file)
}

/// A card called `title`, in `container` if one is given.
@MainActor private func card(_ title: String?, x: CGFloat = 0, in container: ShapeID? = nil) -> AnyShapeRecord {
    var card = AnyShapeRecord(ShapeRecord(Card(CGRect(x: x, y: 0, width: 100, height: 60))))
    card[TitleProperty.self] = title
    return container.map { card.copy(as: card.id, container: $0) } ?? card
}

/// A pocket called `title`.
@MainActor private func pocket(_ title: String? = nil, x: CGFloat = 0) -> AnyShapeRecord {
    var pocket = AnyShapeRecord(ShapeRecord(Pocket(CGRect(x: x, y: 200, width: 200, height: 100))))
    pocket[TitleProperty.self] = title
    return pocket
}

/// A corral called `title`, in `container` if one is given: large, so what it holds is inside it.
@MainActor private func corral(_ title: String? = nil, x: CGFloat = 0, in container: ShapeID? = nil) -> AnyShapeRecord {
    var corral = AnyShapeRecord(ShapeRecord(Corral(CGRect(x: x, y: -400, width: 600, height: 380))))
    corral[TitleProperty.self] = title
    return container.map { corral.copy(as: corral.id, container: $0) } ?? corral
}

/// A file of `root`'s shapes, each pocket's board holding what `boards` gives it.
@MainActor private func file(_ root: [AnyShapeRecord], _ boards: [ShapeID: [AnyShapeRecord]] = [:]) -> CanvasFile {
    CanvasFile(root: CanvasDocument(shapes: root), children: boards.mapValues { CanvasDocument(shapes: $0) })
}

extension EditorHarness {
    /// What the engine finds on the board shown, by shape.
    @MainActor fileprivate var warnings: [ShapeID: [String]] {
        (editor.validation?.results ?? [:]).mapValues { $0.issues.map(\.message) }
    }

    @MainActor fileprivate func rename(_ id: ShapeID, _ title: String?) {
        editor.transact("Rename") { $0.update(inFile: id) { $0[TitleProperty.self] = title } }
    }

    /// The path the index files a shape under, if another shape has it too.
    @MainActor fileprivate func shared(_ id: ShapeID) -> String? {
        editor.pathIndex?.sharedKey(of: id)?.text
    }
}

/// The warning of a shape in no container.
private func shared(_ title: String) -> [String] { ["“\(title)” is another shape’s title too."] }
/// The warning of a shape in a container.
private func sharedPath(_ path: String) -> [String] { ["“\(path)” is another shape’s path too."] }

@MainActor let pathValidationTests = Suite("Paths two shapes share", [
    test("two shapes with one title in no container are each warned about it, about their title; others aren't") {
        let a = card("API"), b = card("API", x: 200), c = card("Billing", x: 400), d = card(nil, x: 600)
        let h = try harness(file([a, b, c, d]))
        expectEqual(h.warnings, [a.id: shared("API"), b.id: shared("API")])
        expectEqual(h.editor.validation?.result(for: a.id)?.issues.first?.field, "title")
        expectEqual(h.editor.validation?.result(for: a.id)?.issues.first?.severity, .warning)
    },
    test("a rename to a title another shape has warns that one too, which the commit didn't change; renamed away or cleared, neither is") {
        let a = card("API"), b = card("Billing", x: 200)
        let h = try harness(file([a, b]))
        expectEqual(h.warnings, [:])
        h.rename(b.id, "API")
        expectEqual(h.warnings, [a.id: shared("API"), b.id: shared("API")])
        h.rename(b.id, "Billing")
        expectEqual(h.warnings, [:])
        h.rename(a.id, "Billing")
        expectEqual(h.warnings, [a.id: shared("Billing"), b.id: shared("Billing")])
        h.rename(b.id, "  ")
        expectEqual(h.warnings, [:], "a blank title is none")
    },
    test("a third shape of a path, and one of three renamed away, leave the others warned") {
        let a = card("API"), b = card("API", x: 200), c = card("Billing", x: 400)
        let h = try harness(file([a, b, c]))
        h.rename(c.id, "API")
        expectEqual(h.warnings, [a.id: shared("API"), b.id: shared("API"), c.id: shared("API")])
        h.rename(a.id, "Gateway")
        expectEqual(h.warnings, [b.id: shared("API"), c.id: shared("API")])
    },
    test("deleting one of two takes the other's warning; undo and redo follow") {
        let a = card("API"), b = card("API", x: 200)
        let h = try harness(file([a, b]))
        expectEqual(h.warnings.count, 2)
        h.editor.transact("Delete") { $0.delete([b.id]) }
        expectEqual(h.warnings, [:])
        h.editor.undo()
        expectEqual(h.warnings, [a.id: shared("API"), b.id: shared("API")])
        h.editor.redo()
        expectEqual(h.warnings, [:])
    },
    test("undoing a rename gives the warnings back") {
        let a = card("API"), b = card("API", x: 200)
        let h = try harness(file([a, b]))
        h.rename(a.id, "Gateway")
        expectEqual(h.warnings, [:])
        h.editor.undo()
        expectEqual(h.warnings, [a.id: shared("API"), b.id: shared("API")])
    },
    test("titles are compared as they read: folded, then exactly") {
        let a = card("Big  plan"), b = card("Big plan", x: 200), c = card("big plan", x: 400)
        let h = try harness(file([a, b, c]))
        expectEqual(h.warnings, [a.id: shared("Big plan"), b.id: shared("Big plan")])
    },
    test("a derived title counts, whatever the kinds: two discs of one size, and a card named as they're called") {
        let one = AnyShapeRecord(ShapeRecord(Disc(CGRect(x: 0, y: 0, width: 40, height: 40))))
        let two = AnyShapeRecord(ShapeRecord(Disc(CGRect(x: 100, y: 0, width: 40, height: 40))))
        let three = AnyShapeRecord(ShapeRecord(Disc(CGRect(x: 200, y: 0, width: 50, height: 50))))
        let named = card("Disc, 50 × 50", x: 300)
        let h = try harness(file([one, two, three, named]))
        expectEqual(h.warnings, [one.id: shared("Disc, 40 × 40"), two.id: shared("Disc, 40 × 40"),
                                 three.id: shared("Disc, 50 × 50"), named.id: shared("Disc, 50 × 50")])
        expectEqual(h.editor.validation?.result(for: three.id)?.issues.first?.field, nil, "a disc keeps no title to point at")
        expectEqual(h.editor.validation?.result(for: named.id)?.issues.first?.field, "title")
    },
    test("one title in two corrals of different titles is no warning; in one corral, it is, saying the path") {
        let alpha = corral("Alpha"), beta = corral("Beta", x: 700)
        let a = card("A", in: alpha.id), b = card("A", x: 700, in: beta.id), c = card("A", x: 200, in: alpha.id)
        let h = try harness(file([alpha, beta, a, b]))
        expectEqual(h.warnings, [:], "Alpha › A and Beta › A")
        h.editor.transact("Add") { $0.insert(c) }
        expectEqual(h.warnings, [a.id: sharedPath("Alpha › A"), c.id: sharedPath("Alpha › A")])
        expectEqual(h.editor.validation?.result(for: a.id)?.issues.first?.field, "title")
    },
    test("a shape on the root and one in a corral or on a pocket's board share a title, never a path") {
        let outer = card("API"), alpha = corral("Alpha", x: 700), held = card("API", x: 700, in: alpha.id), box = pocket("Payments", x: 300), inner = card("API")
        let h = try harness(file([outer, alpha, held, box], [box.id: [inner]]))
        expectEqual(h.warnings, [:])
        expect(h.enter(box.id))
        expectEqual(h.warnings, [:])
        expectEqual(h.editor.pathIndex?.keys[inner.id]?.text, "Payments › API")
    },
    test("paths are the file's: shapes on the boards of two pockets of one title share one, each warned on its own board; of two titles, none") {
        let one = pocket("Payments"), two = pocket("Payments", x: 300), three = pocket("Billing", x: 600)
        let first = card("API"), second = card("API"), third = card("API")
        let h = try harness(file([one, two, three], [one.id: [first], two.id: [second], three.id: [third]]))
        expectEqual(h.warnings, [one.id: shared("Payments"), two.id: shared("Payments")], "the pockets' own titles, on the root")
        expect(h.enter(one.id))
        expectEqual(h.warnings, [first.id: sharedPath("Payments › API")])
        expect(h.enter(three.id))
        expectEqual(h.warnings, [:], "Billing › API is no other shape's")
        expectEqual(h.editor.validation?.affected(by: ChangeSet(elsewhere: [second.id])), [], "nothing was renamed while the pocket wasn't shown")
    },
    test("untitled containers are on a path by their placeholders, so two shapes of one title in two untitled corrals share it") {
        let left = corral(), right = corral(x: 700), a = card("A", in: left.id), b = card("A", x: 700, in: right.id)
        let h = try harness(file([left, right, a, b]))
        let placeholder = h.editor.registry.label(of: Corral.kind).name
        expectEqual(h.warnings, [a.id: sharedPath("\(placeholder) › A"), b.id: sharedPath("\(placeholder) › A")])
        h.rename(right.id, "Right")
        expectEqual(h.warnings, [:], "titled, the corral is on the path by its title")
        h.editor.undo()
        expectEqual(h.warnings, [a.id: sharedPath("\(placeholder) › A"), b.id: sharedPath("\(placeholder) › A")])
    },
    test("a rename on one board warns a shape on a board kept, as it's shown again, and names it for what shows marks") {
        let first = pocket("Box"), second = pocket("Box", x: 300)
        let inner = card("Spec"), other = card("Notes", x: 200), far = card("API")
        let h = try harness(file([first, second], [first.id: [inner, other], second.id: [far]]))
        expect(h.enter(first.id))
        expectEqual(h.warnings, [:])
        h.editor.showBoard(.root)
        expectEqual(h.warnings, [first.id: shared("Box"), second.id: shared("Box")])
        h.rename(far.id, "Spec")
        expectEqual(h.warnings, [first.id: shared("Box"), second.id: shared("Box")])
        let engine = try require(h.editor.validation)
        let checked = PathValidationPlugin.pathsChecked
        expect(h.enter(first.id))
        expectEqual(h.warnings, [inner.id: sharedPath("Box › Spec")])
        expectEqual(PathValidationPlugin.pathsChecked, checked + 1, "the board kept is taken back, its one named shape checked again")
        expectEqual(engine.affected(by: ChangeSet(elsewhere: [far.id])), [inner.id], "the table of contents' catch-up reads its mark again")
        h.editor.showBoard(.root)
        h.rename(far.id, "API")
        expect(h.enter(first.id))
        expectEqual(h.warnings, [:])
    },
    test("a container renamed joins two groups and splits them again: the shapes inside are warned and let go though the commit didn't change them; undo and redo follow") {
        let alpha = corral("Alpha"), beta = corral("Beta", x: 700)
        let a = card("A", in: alpha.id), b = card("A", x: 700, in: beta.id), c = card("C", x: 200, in: alpha.id), d = card("C", x: 900, in: beta.id)
        let h = try harness(file([alpha, beta, a, b, c, d]))
        expectEqual(h.warnings, [:])
        h.rename(beta.id, "Alpha")
        let joined = [alpha.id: shared("Alpha"), beta.id: shared("Alpha"), a.id: sharedPath("Alpha › A"), b.id: sharedPath("Alpha › A"),
                      c.id: sharedPath("Alpha › C"), d.id: sharedPath("Alpha › C")]
        expectEqual(h.warnings, joined)
        expectEqual(h.editor.pathIndex?.affected(by: ChangeSet(elsewhere: [])), [alpha.id, beta.id, a.id, b.id, c.id, d.id],
                    "whose warning the commit changed: the corral it renamed, and what it didn't change")
        h.rename(beta.id, "Gamma")
        expectEqual(h.warnings, [:])
        h.editor.undo()
        expectEqual(h.warnings, joined)
        h.editor.undo()
        expectEqual(h.warnings, [:])
        h.editor.redo()
        expectEqual(h.warnings, joined)
    },
    test("a container renamed while its group is shared says the new path; one alone renamed affects nothing inside it") {
        let alpha = corral("Alpha"), a = card("A", in: alpha.id), b = card("A", x: 200, in: alpha.id), c = card("C", x: 400, in: alpha.id)
        let h = try harness(file([alpha, a, b, c]))
        expectEqual(h.warnings, [a.id: sharedPath("Alpha › A"), b.id: sharedPath("Alpha › A")])
        h.rename(alpha.id, "Omega")
        expectEqual(h.warnings, [a.id: sharedPath("Omega › A"), b.id: sharedPath("Omega › A")])
        expectEqual(h.editor.pathIndex?.affected(by: ChangeSet(elsewhere: [])), [a.id, b.id], "C was alone, and is: its verdict can't change")
    },
    test("a shape dropped into a corral and taken out of it: its path follows, and so do the warnings; undo and redo follow") {
        let alpha = corral("Alpha"), held = card("A", in: alpha.id), loose = card("A", x: 700)
        let h = try harness(file([alpha, held, loose]))
        expectEqual(h.warnings, [:], "Alpha › A and A")
        h.editor.put([loose.id], in: alpha.id)
        expectEqual(h.warnings, [held.id: sharedPath("Alpha › A"), loose.id: sharedPath("Alpha › A")])
        h.editor.put([loose.id], in: nil)
        expectEqual(h.warnings, [:])
        h.editor.undo()
        expectEqual(h.warnings, [held.id: sharedPath("Alpha › A"), loose.id: sharedPath("Alpha › A")])
        h.editor.undo()
        expectEqual(h.warnings, [:])
        h.editor.redo()
        expectEqual(h.warnings, [held.id: sharedPath("Alpha › A"), loose.id: sharedPath("Alpha › A")])
    },
    test("a container moved into another, and out of it: what it holds is somewhere else; undo and redo follow") {
        let alpha = corral("Alpha"), inner = corral("Beta", in: alpha.id), held = card("A", in: inner.id)
        let outer = corral("Beta", x: 700), other = card("A", x: 700, in: outer.id)
        let h = try harness(file([alpha, inner, held, outer, other]))
        expectEqual(h.warnings, [:], "Alpha › Beta › A and Beta › A")
        h.editor.put([inner.id], in: nil)
        let out = [inner.id: shared("Beta"), outer.id: shared("Beta"), held.id: sharedPath("Beta › A"), other.id: sharedPath("Beta › A")]
        expectEqual(h.warnings, out)
        h.editor.put([inner.id, outer.id], in: alpha.id)
        let both = [inner.id: sharedPath("Alpha › Beta"), outer.id: sharedPath("Alpha › Beta"),
                    held.id: sharedPath("Alpha › Beta › A"), other.id: sharedPath("Alpha › Beta › A")]
        expectEqual(h.warnings, both)
        h.editor.undo()
        expectEqual(h.warnings, out)
        h.editor.undo()
        expectEqual(h.warnings, [:])
        h.editor.redo()
        h.editor.redo()
        expectEqual(h.warnings, both)
    },
    test("a pocket moved onto another pocket's board: the shapes on its board are somewhere else; undo and redo follow") {
        let shelf = pocket("Shelf"), box = pocket("Box", x: 300), nested = pocket("Box")
        let a = card("A"), b = card("A")
        let h = try harness(file([shelf, box], [shelf.id: [nested], nested.id: [a], box.id: [b]]))
        expectEqual(h.warnings, [:], "Shelf › Box › A and Box › A")
        h.editor.transact("Move In") { $0.move([box.id], toBoardOwnedBy: shelf.id) }
        expectEqual(h.shared(a.id), "Shelf › Box › A")
        expectEqual(h.shared(b.id), "Shelf › Box › A")
        expectEqual(h.shared(box.id), "Shelf › Box")
        h.editor.undo()
        expectEqual(h.shared(a.id), nil)
        expectEqual(h.shared(b.id), nil)
        h.editor.redo()
        expect(h.enter(shelf.id))
        expectEqual(h.warnings, [nested.id: sharedPath("Shelf › Box"), box.id: sharedPath("Shelf › Box")])
        expect(h.enter(box.id))
        expectEqual(h.warnings, [b.id: sharedPath("Shelf › Box › A")])
    },
    test("a container deleted: what it held falls into its own container, with the path that has; undo and redo follow") {
        let alpha = corral("Alpha"), beta = corral("Beta", in: alpha.id), deep = card("A", in: beta.id), near = card("A", x: 200, in: alpha.id)
        let h = try harness(file([alpha, beta, deep, near]))
        expectEqual(h.warnings, [:], "Alpha › Beta › A and Alpha › A")
        h.editor.transact("Delete") { $0.delete([beta.id]) }
        expectEqual(h.editor.holder(of: deep.id), alpha.id, "it fell into Alpha")
        expectEqual(h.warnings, [deep.id: sharedPath("Alpha › A"), near.id: sharedPath("Alpha › A")])
        h.editor.undo()
        expectEqual(h.warnings, [:])
        h.editor.redo()
        expectEqual(h.warnings, [deep.id: sharedPath("Alpha › A"), near.id: sharedPath("Alpha › A")])
    },
    test("deleting a pocket takes the paths on its board with it, and undo brings them back") {
        let one = pocket("Box"), two = pocket("Box", x: 300), first = card("API"), second = card("API")
        let h = try harness(file([one, two], [one.id: [first], two.id: [second]]))
        expectEqual(h.shared(first.id), "Box › API")
        h.editor.transact("Delete") { $0.delete([two.id]) }
        expectEqual(h.warnings, [:])
        expectEqual(h.shared(first.id), nil)
        h.editor.undo()
        expectEqual(h.warnings, [one.id: shared("Box"), two.id: shared("Box")])
        expectEqual(h.shared(first.id), "Box › API")
    },
    test("shapes moved onto a pocket's board take its path, and back again when undo brings them as it takes the board") {
        // More shapes move than the index files paths and containers for: undo hands every one of them over as on
        // a board taken (`elsewhere`) and as back on the root (`added`), and none of them is gone.
        let outer = card("API"), moved = card("API", x: 200), box = pocket("Box", x: 300), inner = card("API")
        let quiet = (0..<6).map { card(nil, x: 400 + CGFloat($0) * 120) }
        let h = try harness(file([outer, moved, box] + quiet, [box.id: [inner]]))
        expectEqual(h.warnings, [outer.id: shared("API"), moved.id: shared("API")])
        h.editor.transact("Move In") { $0.move(Set([moved.id] + quiet.map(\.id)), toBoardOwnedBy: box.id) }
        expectEqual(h.warnings, [:], "the one left on the root is alone")
        expectEqual(h.shared(moved.id), "Box › API")
        h.editor.undo()
        expectEqual(h.warnings, [outer.id: shared("API"), moved.id: shared("API")])
        expectEqual(h.shared(inner.id), nil)
        h.editor.redo()
        expectEqual(h.warnings, [:])
        expect(h.enter(box.id))
        expectEqual(h.warnings, [moved.id: sharedPath("Box › API"), inner.id: sharedPath("Box › API")])
    },
    test("a pocket's title counts against a card's in no container, wherever its board is") {
        let outer = card("Payments"), box = pocket("Payments", x: 300)
        let h = try harness(file([outer, box]))
        expectEqual(h.warnings, [outer.id: shared("Payments"), box.id: shared("Payments")])
    },
    test("a move checks no path") {
        let a = card("API"), b = card("API", x: 200)
        let h = try harness(file([a, b]))
        expectEqual(h.warnings.count, 2)
        let checked = PathValidationPlugin.pathsChecked
        h.editor.transact("Move") { $0.translate([a.id, b.id], by: CGPoint(x: 10, y: 10)) }
        expectEqual(h.warnings.count, 2)
        expectEqual(PathValidationPlugin.pathsChecked, checked)
    },
    test("a corral dragged with what it holds checks no path, and changes none") {
        let alpha = corral("Alpha"), a = card("A", in: alpha.id), b = card("A", x: 200, in: alpha.id)
        let h = try harness(file([alpha, a, b]))
        expectEqual(h.warnings, [a.id: sharedPath("Alpha › A"), b.id: sharedPath("Alpha › A")])
        let checked = PathValidationPlugin.pathsChecked
        h.editor.transact("Move") { $0.translate([alpha.id], by: CGPoint(x: 40, y: 30)) }
        expectEqual(h.editor.document[a.id]?.box?.minX, 40, "what it holds went with it")
        expectEqual(h.warnings, [a.id: sharedPath("Alpha › A"), b.id: sharedPath("Alpha › A")])
        expectEqual(PathValidationPlugin.pathsChecked, checked)
        expectEqual(h.editor.pathIndex?.affected(by: ChangeSet(elsewhere: [])), [])
    },
    test("a file put in place is read afresh") {
        let a = card("API"), b = card("Billing", x: 200)
        let h = try harness(file([a, b]))
        expectEqual(h.warnings, [:])
        let alpha = corral("Alpha"), c = card("Billing", in: alpha.id), d = card("Billing", x: 200, in: alpha.id)
        h.editor.replaceFile(with: file([alpha, c, d]))
        expectEqual(h.warnings, [c.id: sharedPath("Alpha › Billing"), d.id: sharedPath("Alpha › Billing")])
    },
    test("outside the engine, a shape on another board is warned given the editor (a query's check), and not over a plain context, which reads no file") {
        let one = pocket("Box"), two = pocket("Box", x: 300), first = card("API"), second = card("API")
        let h = try harness(file([one, two], [one.id: [first], two.id: [second]]))
        let board = h.file[BoardID(owner: one.id)], registry = h.editor.registry
        let record = try require(board[first.id])
        expectEqual(registry.validationIssues(of: record, in: ShapeContext(document: board, registry: registry), editor: h.editor).map(\.message),
                    sharedPath("Box › API"))
        expectEqual(registry.validationIssues(of: record, in: ShapeContext(document: board, registry: registry)), [])
    },
    test("writes that have not committed: the rule reads the paths as the transaction leaves them, and says which other holders they reach, on another board too") {
        // Alpha › Checkout (a), Cart (b) and Notes (c) on the root; Shelf › Billing (far) on the pocket's board.
        let alpha = corral("Alpha"), a = card("Checkout", in: alpha.id), b = card("Cart", x: 700), c = card("Notes", x: 900)
        let box = pocket("Shelf", x: 1200), far = card("Billing")
        let h = try harness(file([alpha, a, b, c, box], [box.id: [far]]))
        let registry = h.editor.registry
        expectEqual(h.warnings, [:])
        struct Thrown: Error {}
        /// What the rule says, over its own board, of each shape the writes touch, and of those `written`, which the run
        /// checks as its own.
        @MainActor func uncommitted(_ written: [ShapeID], _ body: (inout Transaction) -> Void) -> [ShapeID: [String]] {
            var found: [ShapeID: [String]] = [:]
            try? h.editor.transact { transaction in
                body(&transaction)
                let shapes = transaction.shapes
                for id in registry.validationTouched(by: transaction.pending, in: shapes).union(written) {
                    guard let on = transaction.board(containing: id) else { continue }
                    let there = transaction.contents(of: on)
                    guard let record = there[id] else { continue }
                    found[id] = registry.validationIssues(of: record, in: shapes.over(there)).map(\.message)
                }
                throw Thrown()
            }
            return found
        }
        expectEqual(uncommitted([b.id]) { $0.update(b.id) { $0[TitleProperty.self] = "Checkout" } }, [b.id: []],
                    "Checkout in no container is not Alpha › Checkout")
        expectEqual(uncommitted([b.id]) { transaction in
            transaction.update(b.id) { $0[TitleProperty.self] = "Checkout" }
            transaction.setContainer(b.id, to: alpha.id)
        }, [a.id: sharedPath("Alpha › Checkout"), b.id: sharedPath("Alpha › Checkout")], "renamed and put in the corral, it shares a's path")
        let added = card("Checkout", x: 300, in: alpha.id)
        expectEqual(uncommitted([added.id]) { $0.insert(added) }, [a.id: sharedPath("Alpha › Checkout"), added.id: sharedPath("Alpha › Checkout")],
                    "a shape added in the corral")
        expectEqual(uncommitted([b.id]) { $0.update(b.id, as: Card.self) { $0.props.text = "words" } }, [b.id: []], "a write that changes no path")
        expectEqual(h.warnings, [:], "nothing was committed")
        // A container renamed: what is inside it reaches the holders of its new path, on another board too.
        h.editor.transact(on: BoardID(owner: box.id), "Rename") { $0.update(far.id) { $0[TitleProperty.self] = "Checkout" } }
        expectEqual(h.warnings, [:], "Shelf › Checkout and Alpha › Checkout")
        expectEqual(uncommitted([alpha.id]) { $0.update(alpha.id) { $0[TitleProperty.self] = "Shelf" } },
                    [alpha.id: shared("Shelf"), box.id: shared("Shelf"), a.id: sharedPath("Shelf › Checkout"), far.id: sharedPath("Shelf › Checkout")],
                    "the corral and the pocket share Shelf, and what each holds Shelf › Checkout, which the run did not write")
        expectEqual(registry.validationIssues(of: try require(h.file[BoardID(owner: box.id)][far.id]),
                                              in: h.editor.shapeContext.over(h.editor.contents(of: BoardID(owner: box.id)))), [],
                    "and the committed file, read through the editor's own reading, says nothing of far")
        // A path taken from one of two holders reaches the one left, which is warned of no longer; deleting one does too.
        h.editor.put([b.id], in: alpha.id)
        h.rename(b.id, "Checkout")
        expectEqual(h.warnings, [a.id: sharedPath("Alpha › Checkout"), b.id: sharedPath("Alpha › Checkout")])
        expectEqual(uncommitted([b.id]) { $0.setContainer(b.id, to: nil) }, [a.id: [], b.id: []])
        expectEqual(uncommitted([]) { $0.delete([b.id]) }, [a.id: []])
        // Two shapes the same transaction gives one path share it, and neither is the other's to name.
        expectEqual(uncommitted([b.id, c.id]) { transaction in
            transaction.update(b.id) { $0[TitleProperty.self] = "Twin" }
            transaction.update(c.id) { $0[TitleProperty.self] = "Twin" }
            transaction.setContainer(c.id, to: alpha.id)
        }, [a.id: [], b.id: sharedPath("Alpha › Twin"), c.id: sharedPath("Alpha › Twin")])
    },
])

// MARK: Seeded commits

/// A reproducible stream of choices.
private struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Every titled shape's path, read afresh from the file as it is: Topology's ancestors, outermost first, each by its
/// container's name, then the title; on every board the editor can show, none kept aside.
@MainActor private func freshPaths(_ editor: CanvasEditor) -> [ShapeID: ShapePath.Key] {
    var found: [ShapeID: ShapePath.Key] = [:]
    let registry = editor.registry
    for board in editor.showableBoards {
        for record in editor.contents(of: board).shapes where !record.isOpaque {
            guard let title = registry.title(of: record) else { continue }
            let names = (editor.topology?.ancestors(of: record.id) ?? []).reversed().map { registry.containerName(of: editor.shape(inFile: $0)!).text }
            found[record.id] = ShapePath.Key(names + [title])
        }
    }
    return found
}

/// A file of corrals and pockets, two levels deep, with cards of two titles among them.
@MainActor private func seededFile() -> CanvasFile {
    let one = corral("X"), two = corral("Y", x: 700), three = corral(nil, x: 1400, in: nil)
    let left = pocket("P", x: 0), right = pocket("P", x: 300), lone = pocket(nil, x: 600)
    let inside = corral("X")
    var root: [AnyShapeRecord] = [one, two, three, left, right, lone]
    root += [card("A", in: one.id), card("B", x: 100, in: one.id), card("A", x: 700, in: two.id), card("A", x: 1400, in: three.id), card("B", x: 2000)]
    return file(root, [left.id: [inside, card("A", in: inside.id), card("A", x: 700)],
                       right.id: [card("A", x: 700), card("B", x: 800)],
                       lone.id: [corral("Y"), card("B")]])
}

@MainActor let pathAgreementTests = Suite("Paths kept agree with the file read afresh", [
    test("after every step of seeded commits on any board (renames, shapes put in and taken out of corrals, corrals moved into others, shapes moved onto pockets' boards, deletions, additions, undo, redo, other boards shown), the index has every path a fresh read has, and the warnings kept on the board shown are a fresh check's") {
        for seed in [UInt64(1), 7, 42] {
            var random = Seeded(state: seed)
            let h = try harness(seededFile())
            let editor = h.editor, registry = editor.registry
            let titles: [String?] = ["A", "B", "X", "Y", "P", nil]
            for step in 0..<80 {
                let boards = editor.showableBoards
                let board = boards.randomElement(using: &random)!
                let shapes = editor.contents(of: board).shapes
                let corrals = shapes.filter { $0.kind == Corral.kind }.map(\.id)
                let cards = shapes.filter { $0.kind == Card.kind }.map(\.id)
                switch Int.random(in: 0..<10, using: &random) {
                case 0, 1:
                    if let id = shapes.randomElement(using: &random)?.id, let title = titles.randomElement(using: &random) {
                        editor.transact(on: board, "Rename") { $0.update(id) { $0[TitleProperty.self] = title } }
                    }
                case 2:
                    if let id = cards.randomElement(using: &random) {
                        let into = Bool.random(using: &random) ? corrals.randomElement(using: &random) : nil
                        editor.transact(on: board, "Put") { $0.setContainer(id, to: into) }
                    }
                case 3:
                    if let id = corrals.randomElement(using: &random) {
                        let into = corrals.filter { $0 != id && !(editor.topology?.isInside($0, id) ?? true) }.randomElement(using: &random)
                        editor.transact(on: board, "Put") { $0.setContainer(id, to: Bool.random(using: &random) ? into : nil) }
                    }
                case 4:
                    let owners = editor.document.shapes.filter { $0.kind == Pocket.kind }.map(\.id)
                    let loose = editor.document.shapes.filter { $0.kind == Card.kind }.map(\.id)
                    if let owner = owners.randomElement(using: &random), let id = loose.randomElement(using: &random) {
                        editor.transact("Move In") { $0.move([id], toBoardOwnedBy: owner) }
                    }
                case 5:
                    let pockets = shapes.filter { $0.kind == Pocket.kind }.map(\.id)
                    if let id = [corrals, cards, pockets].randomElement(using: &random)?.randomElement(using: &random) {
                        editor.transact(on: board, "Delete") { $0.delete([id]) }
                    }
                case 6:
                    let title = titles.randomElement(using: &random) ?? nil
                    let into = corrals.randomElement(using: &random)
                    let added = Bool.random(using: &random) ? card(title, x: CGFloat(step) * 10, in: into) : corral(title, x: CGFloat(step) * 10, in: into)
                    editor.transact(on: board, "Add") { $0.insert(added) }
                case 7:
                    editor.undo()
                case 8:
                    editor.redo()
                default:
                    if let other = boards.randomElement(using: &random) { editor.showBoard(other) }
                }
                let index = try require(editor.pathIndex)
                let fresh = freshPaths(editor)
                expectEqual(index.keys, fresh, "seed \(seed), step \(step): every path")
                var holders: [ShapePath.Key: Set<ShapeID>] = [:]
                for (id, key) in fresh { holders[key, default: []].insert(id) }
                for (key, ids) in holders where index.holders(of: key) != ids {
                    expectEqual(index.holders(of: key), ids, "seed \(seed), step \(step): who holds \(key.text)")
                }
                // The warnings kept on the board shown, against a check of each shape there from nothing.
                var expected: [ShapeID: [String]] = [:]
                for record in editor.document.shapes {
                    let issues = registry.validationIssues(of: record, in: editor.shapeContext, editor: editor).map(\.message)
                    if !issues.isEmpty { expected[record.id] = issues }
                    if let key = fresh[record.id], (holders[key]?.count ?? 0) > 1 {
                        expectEqual(issues, [key.isTopLevel ? shared(key.name)[0] : sharedPath(key.text)[0]], "seed \(seed), step \(step)")
                    }
                }
                expectEqual(h.warnings, expected, "seed \(seed), step \(step): the warnings kept on \(editor.board)")
            }
        }
    },
])
