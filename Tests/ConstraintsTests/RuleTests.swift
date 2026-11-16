@_spi(Host) import Canvas
import CanvasTesting
import Constraints
import CoreGraphics
import DetailPanel
import Draw
import Selection
import TestKit
import Titles
import Validation

// The rule: a shape that breaks a constraint whose reach it's in is invalid, told so as "<place> accepts <words>.", the
// issue carrying the constraint as its source and its actions (Move Out, Show Constraint; the root's, Show Constraint only); the
// issue walk's scope of one constraint; and what a `canvas draw` that moves a shape into a refusing place, or draws one
// there, is told.

private let penRect = CGRect(x: 100, y: 100, width: 400, height: 300)

extension EditorHarness {
    /// A shape's issues as Validation keeps them.
    func validationIssues(of id: ShapeID) -> [ValidationIssue] { editor.validation?.results[id]?.issues ?? [] }

    /// Runs an issue's action by its title.
    func perform(_ title: String, on id: ShapeID, file: StaticString = #fileID, line: UInt = #line) throws {
        let action = try require(validationIssues(of: id).flatMap(\.actions).first { $0.title == title }, "\(title) is offered", file: file, line: line)
        action.perform()
    }
}

@MainActor let ruleTests = Suite("Constraints: the rule", [
    test("the message names the place: by its title, an untitled corral by its kind, a pocket's board, the root by its name") {
        let h = try constraintHarness()
        let untitled = h.corral(nil, penRect, [noDiscs])
        let d = h.disc(at: CGPoint(x: 200, y: 200), in: untitled)
        let drawer = h.pocket(nil, CGRect(x: 600, y: 100, width: 200, height: 150), [noDiscs])
        let loose = AnyShapeRecord(ShapeRecord(Disc(CGRect(x: 0, y: 0, width: 50, height: 50))))
        h.editor.transact(on: BoardID(owner: drawer)) { $0.insert(loose) }
        h.settle()
        expectEqual(h.issues(of: d), ["This corral accepts no discs."])
        expectEqual(h.issues(ofShapeOnAnotherBoard: loose.id), ["This board accepts no discs."])
        expectEqual(h.index.name(of: .root), "This board")
        h.editor.nameRoot("Plans")
        expectEqual(h.index.name(of: .root), "Plans")
        let issue = try require(h.validationIssues(of: d).first)
        expectEqual(issue.severity, .error)
        expectEqual(issue.actions.map(\.title), ["Move Out", "Show Constraint"])
        let placed = try require(h.index.breaches(of: d).first)
        expectEqual(issue.source, placed.source)
        expectEqual(PlacedConstraint(source: issue.source!), placed, "the source leads back to the constraint")
        expectEqual(PlacedConstraint(source: IssueSource(plugin: "someone-else", key: placed.source.key)), nil, "another plugin's")
    },
    test("the root's issues offer Show Constraint, which opens the board's popover, and no Move Out: there is nowhere out of the root") {
        let h = try constraintHarness()
        let d = h.disc(at: CGPoint(x: 700, y: 100))
        h.writer.add(noDiscs, to: .root)
        h.settle()
        expectEqual(h.validationIssues(of: d).map(\.message), ["This board accepts no discs."])
        expectEqual(h.validationIssues(of: d).flatMap(\.actions).map(\.title), ["Show Constraint"])
        expect(h.editor.constraintBoard?.isOpen == false)
        try h.perform("Show Constraint", on: d)
        expect(h.editor.constraintBoard?.isOpen == true, "the popover is open")
        expectEqual(h.editor.selectedShapeIDs, [], "nothing selected, nowhere gone")
    },
    test("Move Out puts a shape beside its place, on the level the place is on, one step; refused where that level refuses it too") {
        let log = RefusalLog()
        let h = try constraintHarness(log: log)
        let pen = h.corral("Pen", penRect, [noDiscs])
        let d = h.disc(at: CGPoint(x: 200, y: 200), in: pen)
        h.settle()
        try h.perform("Move Out", on: d)
        expectEqual(h.editor.holder(of: d), nil, "out of Pen")
        let box = try require(h.editor.document[d]?.box)
        expect(!box.intersects(penRect), "beside it, clear of it: \(box)")
        expectEqual(h.editor.undoHistory.undoName, "Move Out")
        expectEqual(h.issues(of: d), [])
        h.editor.undo()
        expectEqual(h.editor.holder(of: d), pen)
        // In a place inside another that accepts no discs either: refused.
        let outer = h.corral("Outer", CGRect(x: 0, y: 0, width: 1400, height: 1000), [noDiscs])
        h.editor.transact("Into Outer") { $0.setContainer(pen, to: outer) }
        h.settle()
        let revision = h.editor.revision
        try h.perform("Move Out", on: d)
        expectEqual(h.editor.holder(of: d), pen, "Outer refuses it")
        expectEqual(h.editor.revision, revision)
        expectEqual(log.refusals.last, [outer])
    },
    test("Move Out of a pocket's board puts the shape on the board the pocket is on, beside it") {
        let h = try constraintHarness()
        let drawer = h.pocket("Drawer", CGRect(x: 600, y: 100, width: 200, height: 150), [noDiscs])
        let loose = AnyShapeRecord(ShapeRecord(Disc(CGRect(x: 0, y: 0, width: 50, height: 50))))
        h.editor.transact(on: BoardID(owner: drawer)) { $0.insert(loose) }
        h.settle()
        let issue = try require(h.editor.registry.validationIssues(of: loose, in: ShapeContext(document: h.editor.contents(of: BoardID(owner: drawer)),
                                                                                                 registry: h.editor.registry), editor: h.editor).first)
        try require(issue.actions.first { $0.title == "Move Out" }).perform()
        expectEqual(h.editor.file.board(containing: loose.id), .root)
        let box = try require(h.editor.document[loose.id]?.box)
        expect(!box.intersects(CGRect(x: 600, y: 100, width: 200, height: 150)), "beside Drawer: \(box)")
        expectEqual(h.index.breaches(of: loose.id), [])
    },
    test("Show Constraint selects the place's frame, one step back, and chooses its Rules tab") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [noDiscs])
        let d = h.disc(at: CGPoint(x: 200, y: 200), in: pen)
        h.settle()
        h.editor.selectedShapeIDs = [d]
        try h.perform("Show Constraint", on: d)
        h.wait(0)
        expectEqual(h.editor.selectedShapeIDs, [pen])
        expectEqual(h.editor.detailPanel?.chosenTab(for: Corral.kind), .of(RulesTab.self))
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [d])
    },
    test("a constraint's walk: its breakers its candidates, its label the place and the words, gone with the constraint") {
        let h = try constraintHarness()
        let pen = h.corral("Backlog", penRect, [noDiscs, onlyTiles])
        let a = h.disc(at: CGPoint(x: 150, y: 150), in: pen), b = h.disc(at: CGPoint(x: 300, y: 150), in: pen)
        let t = h.tile("T", at: CGPoint(x: 150, y: 250), in: pen)
        h.settle()
        let placed = try require(h.index.constraints(of: .shape(pen)).first)
        let scope = try require(h.editor.registry.issueScope(for: placed.source, in: h.editor))
        expectEqual(scope.candidates?(h.editor), [a, b])
        expectEqual(scope.label(h.editor)?.title, "Backlog: no discs")
        expectEqual(scope.label(h.editor)?.owner, pen)
        let issues = h.validationIssues(of: a)
        expectEqual(issues.map { scope.includes($0) }, [true, false], "its own issue, not the other constraint's")
        expectEqual(h.issues(of: t), [])
        h.writer.remove(noDiscs, from: .shape(pen))
        expectEqual(scope.label(h.editor), nil, "the constraint gone: the walk ends")
        expectEqual(h.editor.registry.issueScope(for: placed.source, in: h.editor) == nil, true)
    },
    test("a constraint's walk follows it through a change of its reach or its query; reworded, it's another") {
        let h = try constraintHarness()
        let pen = h.corral("Backlog", penRect, [noDiscs])
        let inner = h.corral("Inner", CGRect(x: 150, y: 150, width: 200, height: 150), in: pen)
        let a = h.disc(at: CGPoint(x: 400, y: 320), in: pen), b = h.disc(at: CGPoint(x: 200, y: 200), in: inner)
        h.settle()
        let placed = try require(h.index.constraints(of: .shape(pen)).first)
        let scope = try require(h.editor.registry.issueScope(for: placed.source, in: h.editor))
        expectEqual(scope.candidates?(h.editor), [a])
        h.writer.setReach(.descendants, of: noDiscs, in: .shape(pen))
        h.settle()
        expectEqual(scope.label(h.editor)?.title, "Backlog: no discs", "the walk goes on")
        expectEqual(scope.isChanged?(ChangeSet(elsewhere: []), h.editor), true, "followed in place")
        expectEqual(scope.isChanged?(ChangeSet(elsewhere: []), h.editor), false, "once")
        expectEqual(scope.candidates?(h.editor), [a, b])
        expectEqual(h.validationIssues(of: b).map { scope.includes($0) }, [true], "the constraint's issues as it is now")
        let deep = Constraint(says: "no discs", query: ":not(disc)", reach: .descendants)
        h.writer.setQuery(":not(disc, tile)", of: deep, in: .shape(pen))
        expect(scope.label(h.editor) != nil, "its query changed: the same")
        h.writer.replace(Constraint(says: "no discs", query: ":not(disc, tile)", reach: .descendants),
                         with: Constraint(says: "nothing round", query: ":not(disc, tile)", reach: .descendants), in: .shape(pen))
        expectEqual(scope.label(h.editor), nil, "reworded: the walk ends")
    },
    test("what a run's writes touch: what a container moved out of a place carries, a subboard's board moved with it; a root list written, its top level") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", CGRect(x: 100, y: 100, width: 600, height: 500), [Constraint(says: "no discs", query: ":not(disc)", reach: .descendants)])
        let inner = h.corral("Inner", CGRect(x: 150, y: 150, width: 200, height: 150), in: pen)
        let d = h.disc(at: CGPoint(x: 200, y: 200), in: inner)
        let bin = h.pocket("Bin", CGRect(x: 900, y: 100, width: 200, height: 150))
        let e = AnyShapeRecord(ShapeRecord(Disc(CGRect(x: 0, y: 0, width: 50, height: 50))))
        h.editor.transact(on: BoardID(owner: bin)) { $0.insert(e) }
        let drawer = h.pocket("Drawer", CGRect(x: 900, y: 400, width: 200, height: 150))
        let top = h.disc(at: CGPoint(x: 1300, y: 100))
        h.settle()
        expectEqual(h.breakers(of: .shape(pen)), [d])
        let registry = h.editor.registry
        _ = h.editor.transactWhole("Probe") { transaction -> Bool in
            transaction.setContainer(inner, to: nil)
            expect(registry.validationTouched(by: transaction.pending, in: transaction.shapes).contains(d), "what Inner carries")
            throw Transaction.Refused()
        }
        _ = h.editor.transactWhole("Probe") { transaction -> Bool in
            _ = transaction.move([bin], toBoardOwnedBy: drawer)
            expect(registry.validationTouched(by: transaction.pending, in: transaction.shapes).contains(e.id), "what's on Bin's board, which goes with it unwritten")
            throw Transaction.Refused()
        }
        _ = h.editor.transactWhole("Probe") { transaction -> Bool in
            transaction.setFileValue(RootConstraintsProperty.self, to: ConstraintList([noDiscs]))
            let touched = registry.validationTouched(by: transaction.pending, in: transaction.shapes)
            expect(touched.contains(top), "the root's top level")
            expect(!touched.contains(d) && !touched.contains(e.id), "not what's in a place: \(touched)")
            throw Transaction.Refused()
        }
    },
    test("draw: moving a shape into a place that refuses it fails cannot_contain in the constraint's words; a shape drawn there goes in, flagged") {
        let h = try constraintHarness(Given(), [DrawPlugin(), TitleNamesPlugin()])
        let pen = h.corral("Pen", penRect, [Constraint(says: "no tiles", query: ":not(tile)")])
        h.tile("T", at: CGPoint(x: 700, y: 150))
        h.settle()
        do throws(DrawError) {
            _ = try draw(script: #"tile "T" in "Pen""#, dryRun: false, reveal: false, program: "canvas", in: h.editor)
            expect(false, "refused")
        } catch {
            expectEqual(error.reason, "cannot_contain")
            expect(error.message.contains("Pen accepts no tiles."), error.message)
        }
        _ = try draw(script: #"tile "N" in "Pen""#, dryRun: false, reveal: false, program: "canvas", in: h.editor)
        let n = try require(h.editor.document.shapes.first { h.editor.registry.title(of: $0) == "N" })
        expectEqual(h.editor.holder(of: n.id), pen, "made there, it goes in")
        h.settle()
        expectEqual(h.issues(of: n.id), ["Pen accepts no tiles."])
    },
])
