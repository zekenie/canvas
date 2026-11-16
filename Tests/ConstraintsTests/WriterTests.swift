@_spi(Host) import Canvas
import CanvasTesting
import Constraints
import CoreGraphics
import Foundation
import TestKit

// The one writer: each write one step named for what it does, a write that changes nothing no step, a constraint named
// by its value (so a write after the list changed finds the one it was for, or nothing), a read-only shape refused
// before any transaction, the root's list as the file's value, a holder's through the holder, and several lists in one
// step through a transaction handed in. And the points: a holder read and written, its heading; a list given from
// elsewhere, heard changed with no commit.

private let pen = CGRect(x: 100, y: 100, width: 400, height: 300)

@MainActor let writerTests = Suite("Constraints: the writer", [
    test("add, change and remove a corral's constraints, each one step named for it; undo and redo take each back whole") {
        let h = try constraintHarness()
        let p = h.corral("Pen", pen)
        expect(h.writer.add(onlyTiles, to: .shape(p)))
        expectEqual(h.editor.undoHistory.undoName, "Add Constraint")
        expect(h.writer.add(noDiscs, to: .shape(p)))
        expectEqual(h.writer.constraints(of: .shape(p)), [onlyTiles, noDiscs])
        expect(h.writer.setReach(.descendants, of: onlyTiles, in: .shape(p)))
        let deep = Constraint(says: "only tiles", query: "tile", reach: .descendants)
        expectEqual(h.writer.constraints(of: .shape(p)), [deep, noDiscs], "changed where it is")
        expectEqual(h.editor.undoHistory.undoName, "Change Constraint")
        expect(h.writer.setQuery(":not(tile)", of: noDiscs, in: .shape(p)))
        expectEqual(h.writer.constraints(of: .shape(p))?.last, Constraint(says: "no discs", query: ":not(tile)"))
        expect(h.writer.remove(deep, from: .shape(p)))
        expectEqual(h.editor.undoHistory.undoName, "Remove Constraint")
        expect(h.writer.removeAll(from: .shape(p)))
        expectEqual(h.editor.undoHistory.undoName, "Remove Constraints")
        expectEqual(h.editor.document[p]?[ConstraintsProperty.self], nil, "the last taken away, none")
        h.editor.undo()
        expectEqual(h.writer.constraints(of: .shape(p)), [Constraint(says: "no discs", query: ":not(tile)")])
        h.editor.undo()
        expectEqual(h.writer.constraints(of: .shape(p)), [deep, Constraint(says: "no discs", query: ":not(tile)")])
        h.editor.redo()
        h.editor.redo()
        expectEqual(h.writer.constraints(of: .shape(p)), [])
    },
    test("what changes nothing is false and makes no step: one there already added, one not there removed or changed, none to remove") {
        let h = try constraintHarness()
        let p = h.corral("Pen", pen, [onlyTiles])
        let revision = h.editor.revision
        expect(!h.writer.add(onlyTiles, to: .shape(p)))
        expect(!h.writer.add(Constraint(says: "  only   tiles ", query: " tile "), to: .shape(p)), "the same once folded")
        expect(!h.writer.remove(noDiscs, from: .shape(p)))
        expect(!h.writer.replace(noDiscs, with: onlyUrgent, in: .shape(p)))
        expect(!h.writer.replace(onlyTiles, with: onlyTiles, in: .shape(p)))
        expect(!h.writer.setReach(.children, of: onlyTiles, in: .shape(p)))
        expect(!h.writer.add(Constraint(says: "   "), to: .shape(p)), "no words")
        let empty = h.corral(nil, CGRect(x: 600, y: 100, width: 200, height: 200))
        let before = h.editor.revision
        expect(!h.writer.removeAll(from: .shape(empty)))
        expectEqual(h.editor.revision, before)
        expect(revision < before)
        let t = h.tile("T", at: CGPoint(x: 900, y: 0))
        expectEqual(h.writer.constraints(of: .shape(t)), nil, "a tile has no list")
        expect(!h.writer.add(onlyTiles, to: .shape(t)))
    },
    test("a constraint is named by its value: a write after the list changed hits the one it was for, wherever it is now, or nothing") {
        let h = try constraintHarness()
        let p = h.corral("Pen", pen, [onlyTiles, noDiscs])
        let words = Constraint(says: "only urgent things")
        expect(h.writer.add(words, to: .shape(p)))
        // The list changes before an interpretation lands: one above it goes.
        expect(h.writer.remove(onlyTiles, from: .shape(p)))
        expect(h.writer.replace(words, with: onlyUrgent, in: .shape(p)), "it lands on the words it was for")
        expectEqual(h.writer.constraints(of: .shape(p)), [noDiscs, onlyUrgent])
        expect(!h.writer.replace(words, with: onlyUrgent, in: .shape(p)), "landing again finds nothing")
        // Changed to one the list holds: the list holds each once.
        expect(h.writer.replace(onlyUrgent, with: noDiscs, in: .shape(p)))
        expectEqual(h.writer.constraints(of: .shape(p)), [noDiscs])
    },
    test("a read-only corral is refused before any transaction: it shakes, nothing changes, no step") {
        let log = RefusalLog()
        let h = try constraintHarness(log: log)
        let p = h.corral("Pen", pen, [onlyTiles])
        h.editor.freeze([p])
        let step = h.editor.undoHistory.undoName, revision = h.editor.revision
        expect(!h.writer.add(noDiscs, to: .shape(p)))
        expect(!h.writer.remove(onlyTiles, from: .shape(p)))
        expectEqual(log.refusals, [[p], [p]])
        expectEqual(h.editor.revision, revision)
        expectEqual(h.editor.undoHistory.undoName, step)
        expectEqual(h.writer.constraints(of: .shape(p)), [onlyTiles])
    },
    test("the root's list is the file's value, written and taken back as a step") {
        let h = try constraintHarness()
        expect(h.writer.add(noDiscs, to: .root))
        expectEqual(h.file[RootConstraintsProperty.self].constraints, [noDiscs])
        expectEqual(h.editor.undoHistory.undoName, "Add Constraint")
        expect(h.writer.replace(noDiscs, with: onlyTiles, in: .root))
        expect(h.writer.removeAll(from: .root))
        expectEqual(h.file[RootConstraintsProperty.self], ConstraintList())
        h.editor.undo()
        expectEqual(h.writer.constraints(of: .root), [onlyTiles])
    },
    test("a holder's list is read and written through the holder, its heading its own; a shape of the kind holding none has no list") {
        let h = try constraintHarness()
        let sprint = h.add(Charter(CGRect(x: 0, y: 0, width: 200, height: 100), name: "Sprint"))
        let blank = h.add(Charter(CGRect(x: 300, y: 0, width: 200, height: 100)))
        expectEqual(h.writer.constraints(of: .shape(sprint)), [])
        expect(h.writer.add(onlyTiles, to: .shape(sprint)))
        expectEqual(h.editor.undoHistory.undoName, "Add Constraint")
        let list = try require(h.editor.document[sprint]?.typed(as: Charter.self)?.props.list)
        expectEqual(list, #"[{"query":"tile","reach":"children","says":"only tiles"}]"#, "written its own way")
        expectEqual(h.writer.constraints(of: .shape(sprint)), [onlyTiles])
        expectEqual(h.editor.constraintPlaces(of: sprint), "each sprint", "the holder says what its places are called")
        expectEqual(h.editor.constraintHeading(of: sprint), "Inside each sprint", "and Constraints heads its section with it")
        expectEqual(h.editor.constraintPlaces(of: blank), nil)
        expectEqual(h.writer.constraints(of: .shape(blank)), nil)
        expectEqual(h.editor.constraintHeading(of: blank), nil)
        expect(!h.writer.add(onlyTiles, to: .shape(blank)))
        h.editor.undo()
        expectEqual(h.writer.constraints(of: .shape(sprint)), [])
    },
    test("several lists change in one step through a transaction handed in; a read-only one among them is passed over, for the caller to refuse") {
        let h = try constraintHarness()
        let a = h.corral("A", pen), b = h.corral("B", CGRect(x: 600, y: 100, width: 200, height: 200)),
            c = h.corral("C", CGRect(x: 900, y: 100, width: 200, height: 200))
        h.editor.freeze([c])
        var wrote: [Bool] = []
        h.editor.transact("Constrain") { transaction in
            for target in [ConstraintTarget.shape(a), .shape(b), .shape(c), .root] {
                wrote.append(h.writer.edit(target, in: &transaction) { ConstraintWriter.adding(onlyTiles, to: &$0) })
            }
        }
        expectEqual(wrote, [true, true, false, true])
        expectEqual([a, b, c].map { h.writer.constraints(of: .shape($0)) }, [[onlyTiles], [onlyTiles], []])
        expectEqual(h.writer.constraints(of: .root), [onlyTiles])
        h.editor.undo()
        expectEqual([a, b].map { h.writer.constraints(of: .shape($0)) }, [[], []])
        expectEqual(h.writer.constraints(of: .root), [])
    },
])
