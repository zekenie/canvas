import Canvas
import CanvasRPC
import CanvasTesting
import Constraints
import CoreGraphics
import Draw
import Foundation
import TestKit
import Titles
import Topology
import Validation

// `canvas draw` says what its writes break once the file's answers have come (Draw's `laterIssues`): a constraint's verdict is a
// standing query's answer, which comes after a commit, so the run's own check can't judge what it wrote. The corrals are the
// fixtures'; a tile is what a script draws, and a corral "accepts only glossy tiles" or "no tiles".

private let penRect = CGRect(x: 100, y: 100, width: 600, height: 400)

@MainActor private func drawHarness(_ given: Given = Given()) throws -> EditorHarness {
    try constraintHarness(given, [DrawPlugin(), TitleNamesPlugin(), ValidationChecksPlugin()])
}

/// A run, as a real one is, then what it says once the answers have come: its warnings as JSON.
@MainActor private func drawnAndAnswered(_ script: String, on h: EditorHarness, dryRun: Bool = false) throws -> (now: [JSON], later: [JSON]) {
    func warnings(_ result: DrawResult) throws -> [JSON] {
        let json = try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(result))
        return json["warnings"]?.arrayValue ?? []
    }
    let result = try draw(script: script, dryRun: dryRun, reveal: false, program: "canvas", in: h.editor)
    let now = try warnings(result)
    let editor = h.editor
    let later = try warnings(try awaitResult { await laterIssues(of: result, in: editor) })
    return (now, later)
}

@MainActor let drawReportTests = Suite("draw: what a run's writes break, said once the answers have come", [
    test("a shape drawn into a place that doesn't accept it is an error on its statement's line, which the run's own check could not say") {
        let h = try drawHarness()
        h.corral("Pen", penRect, [onlyGlossy])
        h.settle()
        let said = try drawnAndAnswered(#"tile "N" in "Pen""#, on: h)
        expectEqual(said.now.filter { $0["severity"] == "error" }, [], "the run's own check is not asked of what it wrote")
        let accepts = said.later.filter { $0["message"]?.stringValue?.contains("Pen accepts only glossy tiles.") == true }
        expectEqual(accepts.count, 1)
        expectEqual(accepts.first?["line"], 1)
        expectEqual(accepts.first?["severity"], "error")
        expectEqual(accepts.first?["message"], #""N": Pen accepts only glossy tiles."#)
        expectEqual(h.issues(of: try require(h.editor.document.shapes.first { h.editor.registry.title(of: $0) == "N" }).id), ["Pen accepts only glossy tiles."], "what :invalid lists")
    },
    test("a shape restated into a misfit is said the same, and one that fits is not") {
        let h = try drawHarness()
        let pen = h.corral("Pen", penRect, [onlyGlossy])
        h.tile("T", at: CGPoint(x: 150, y: 150), finish: .glossy, in: pen)
        h.settle()
        let fits = try drawnAndAnswered(#"tile "T" finish: glossy"#, on: h)
        expectEqual(fits.later, [], "restated as it is")
        let misfit = try drawnAndAnswered(#"tile "T" finish: matte"#, on: h)
        expectEqual(misfit.later.map { $0["message"] }, [#""T": Pen accepts only glossy tiles."#], "the run could not say it: its answer was still to come")
        expectEqual(misfit.later.first?["line"], 1)
        expectEqual(misfit.later.first?["severity"], "error")
    },
    test("a dry run says nothing of it, and a real run of the same script does") {
        let h = try drawHarness()
        h.corral("Pen", penRect, [onlyGlossy])
        h.settle()
        let dry = try drawnAndAnswered(#"tile "M" in "Pen""#, on: h, dryRun: true)
        expectEqual(dry.now + dry.later, [], "no answers come after a run that commits nothing")
        expect(h.editor.document.shapes.allSatisfy { h.editor.registry.title(of: $0) != "M" }, "nothing was drawn")
        let real = try drawnAndAnswered(#"tile "M" in "Pen""#, on: h)
        expectEqual(real.later.count, 1)
    },
    test("only the shapes that break a place's constraint are said, each on the line of its own statement") {
        let h = try drawHarness()
        h.corral("Pen", penRect, [onlyGlossy])
        h.corral("Yard", CGRect(x: 800, y: 100, width: 600, height: 400), [noDiscs])
        h.settle()
        let said = try drawnAndAnswered(#"""
        tile "A" in "Pen" finish: glossy
        tile "B" in "Yard"
        tile "C" in "Pen" below "A"
        """#, on: h)
        let accepts = said.later.filter { $0["message"]?.stringValue?.contains(" accepts ") == true }
        expectEqual(accepts.map { $0["message"] }, [#""C": Pen accepts only glossy tiles."#])
        expectEqual(accepts.first?["line"], 3)
    },
    test("what a run writes into a holder reaches the members of the places that read through it, though the places have no list until it is written") {
        let given = Given()
        let h = try drawHarness(given)
        let pen = h.corral("Pen", penRect)
        let member = h.tile("Member", at: CGPoint(x: 150, y: 150), in: pen)
        let charter = AnyShapeRecord(ShapeRecord(Charter(CGRect(x: 800, y: 100, width: 100, height: 100), name: "Pen", list: "[]")))
        h.editor.transact { $0.insert(charter) }
        h.settle()
        let registry = h.editor.registry
        @MainActor func touched(_ write: (inout Transaction) -> Void) -> Set<ShapeID> {
            var found: Set<ShapeID> = []
            _ = h.editor.transactWhole("Probe") { @MainActor transaction -> Bool in
                write(&transaction)
                found = registry.validationTouched(by: transaction.pending, in: transaction.shapes)
                throw Transaction.Refused()
            }
            return found
        }
        let list = String(decoding: try JSONEncoder().encode(ConstraintList([onlyGlossy])), as: UTF8.self)
        let writeList = { (transaction: inout Transaction) in
            transaction.update(inFile: charter.id, as: Charter.self) { $0.props.list = list }
        }
        expect(!touched(writeList).contains(member), "nothing reads through the charter: nothing is reached")
        given.readers[charter.id] = [pen]
        expect(touched(writeList).contains(member), "the pen reads through it, and has no list of its own kept yet")
        given.readers = [:]
        // A place that keeps the holder among its lists' sources is found without being told.
        given.lists[pen] = [ConstraintSource(holder: charter.id, constraints: [onlyUrgent])]
        h.editor.transact { _ in }
        h.index.inheritedConstraintsDidChange(of: [pen])
        h.settle()
        expect(touched(writeList).contains(member), "a place that has a list from it")
        expectEqual(touched { transaction in transaction.update(inFile: member, as: Tile.self) { $0.props.label = "x" } }.contains(member), false, "a shape written is not touched by its own write")
        // A holder written with its list as it was (its name restated) reaches no one: only a list that changed does.
        h.editor.transact { $0.update(inFile: charter.id, as: Charter.self) { $0.props.list = list } }
        expectEqual(touched { transaction in transaction.update(inFile: charter.id, as: Charter.self) { $0.props.list = list } }.contains(member), false,
                    "a list restated as it is names no member")
        expect(touched { transaction in transaction.update(inFile: charter.id, as: Charter.self) { $0.props.list = "[]" } }.contains(member), "a list that changed does")
    },
])
