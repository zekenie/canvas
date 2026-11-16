import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Constraints
import CoreGraphics
import Foundation
import Frames
import LanguageModels
import Locking
import Mentions
import Selection
import ShippedTesting
import StickyNotes
import TestKit
import Titles
import Types

// What constraints cost a big board ([constraints](constraints.md)): the index and the standing queries ask again only the shapes a commit
// names, so a commit of a few shapes on a board of 10,000 with three constraints on frames costs those shapes, never the board, and a
// drag's hint over a constrained frame costs the places it enters. The generated board, the shipped list's services all listening, three
// frames beside it each holding a few notes: one accepts only notes, one no subboards, one only titled shapes.

extension Budget {
    /// One commit that changes a few shapes of a board of 10,000 that has three constrained frames: a keystroke in a note on the board,
    /// a drag event of five notes of it, a note put on top, a note put in a constrained frame, a keystroke in a note inside one. The
    /// median of 100, the thread's CPU, release, the answers of what the last commit asked for let land before the next (outside the
    /// timing): the storage commit's figures (`storageCommit`, some 0.02 to 0.07 ms) and what the index adds to them, a judging of the
    /// few shapes the commit names. Some 0.05 to 0.16 ms in two runs alone, on 1,000 shapes and on 10,000 alike; held to 0.3 (measured
    /// 2026-11-15, quiet; a reviewer's quiet runs gave 0.05 to 0.08), so a walk of the board (some 1 ms and more at 10,000) fails it.
    static let constraintCommit = 0.3
    /// And how many times what it costs on the board a tenth the size it may cost: the board's size is none of the commit's business.
    static let constraintCommitOverSmaller = 3.0
    /// And more, for a timing too short to hold to a ratio.
    static let constraintCommitSlack = 0.1
    /// A drag event of a note over a constrained frame that refuses it, on the board of 10,000: its hint asks the place it would enter
    /// whether it accepts the note (the core's admission, the standing answer, no walk). The median of 21 events, the thread's CPU,
    /// release: some 0.05 ms in two runs alone, on both sizes, where the drag's input alone is `dragInput`'s 1 ms; held to 0.2 (measured 2026-11-15, quiet).
    static let constraintHint = 0.2
}

/// The generated board, the shipped list over it, and three frames to its right, each holding notes, standing queries answered.
@MainActor private final class ConstrainedBoard {
    let h: EditorHarness
    let frames: [ShapeID]
    /// A note on the board, away from the frames, and a note of the board's near them, titled or not.
    let note: ShapeID, five: Set<ShapeID>
    /// A note inside the first frame and one on the board a drag carries over the third.
    let inside: ShapeID, loose: ShapeID
    let looseCenter: CGPoint, thirdCenter: CGPoint

    var editor: CanvasEditor { h.editor }

    init(shapes size: Int) throws {
        let document = generatedBoard(shapes: size)
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        h = EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }
        let notes = document.shapes.filter { $0.kind == StickyNote.kind && $0[TypeSchemaProperty.self] == nil && $0[LockedProperty.self] != true }.map(\.id)
        note = try require(notes.last)
        five = Set(notes.suffix(5))
        let bounds = document.shapes.compactMap(\.box).reduce(CGRect.null) { $0.union($1) }
        let left = bounds.maxX + 400
        let lists = [[Constraint(says: "only notes", query: "sticky-note")], [Constraint(says: "no subboards", query: ":not(subboard)")],
                     [Constraint(says: "only titled", query: "[title]")]]
        var ids: [ShapeID] = [], inside = ShapeID()
        let editor = h.editor
        editor.transact("Constrained frames") { transaction in
            for (index, list) in lists.enumerated() {
                var frame = ShapeRecord(Frame(frame: CGRect(x: left + CGFloat(index) * 700, y: 0, width: 600, height: 500)))
                frame[TitleProperty.self] = "Place \(index)"
                frame[ConstraintsProperty.self] = ConstraintList(list)
                transaction.insert(frame)
                ids.append(frame.id)
            }
        }
        for (index, frame) in ids.enumerated() {
            for n in 0..<3 {
                var member = ShapeRecord(StickyNote(frame: CGRect(x: left + CGFloat(index) * 700 + 40 + CGFloat(n) * 180, y: 80, width: 160, height: 120), text: "Member"))
                member[TitleProperty.self] = "Member \(index).\(n)"
                editor.transact { $0.insert(member) }
                editor.put([member.id], in: frame)
                if index == 0, n == 0 { inside = member.id }
            }
        }
        frames = ids
        self.inside = inside
        var loose = ShapeRecord(StickyNote(frame: CGRect(x: left - 300, y: 100, width: 160, height: 120), text: "Loose"))
        loose[TitleProperty.self] = nil
        self.loose = loose.id
        editor.transact { $0.insert(loose) }
        looseCenter = CGPoint(x: left - 300 + 80, y: 160)
        thirdCenter = CGPoint(x: left + 2 * 700 + 300, y: 300)
        settle()
    }

    /// Runs the main run loop until every standing query the index holds has answered.
    func settle() {
        let index = editor.constraintIndex
        _ = spinRunLoop(until: { index?.isSettled ?? true }, timeout: 60)
    }
}

@MainActor let constraintBenchmarks = Suite("Constraint benchmarks", [
    test("a commit that changes a few shapes of a board with constrained frames costs those, not the board; a drag's hint over a frame costs the places it enters") {
        var smaller: [String: Double] = [:]
        for size in sizes {
            let board = try ConstrainedBoard(shapes: size)
            let editor = board.editor
            var n = 0
            let note = board.note, five = board.five, inside = board.inside, frames = board.frames
            let timings: [(String, Double)] = [
                ("a keystroke in a note", median(runs: 100, prepare: { board.settle() }, onThread: true) {
                    n += 1
                    editor.transact { $0.update(note, as: StickyNote.self) { $0.props.text = MentionText(plain: String(repeating: "a", count: n)) } }
                }),
                ("a drag event of five notes", median(runs: 100, prepare: { board.settle() }, onThread: true) {
                    n += 1
                    editor.transact { $0.translate(five, by: CGPoint(x: n % 2 == 0 ? 1 : -1, y: 0)) }
                }),
                ("a note put on top", median(runs: 100, prepare: { board.settle() }, onThread: true) {
                    editor.add(StickyNote(frame: CGRect(x: -1000, y: -1000, width: 200, height: 200), text: "Added"))
                }),
                ("a note put in a constrained frame", median(runs: 100, prepare: { board.settle() }, onThread: true) {
                    n += 1
                    var added = ShapeRecord(StickyNote(frame: CGRect(x: 0, y: 0, width: 100, height: 60), text: "In"))
                    added[TitleProperty.self] = "In \(n)"
                    editor.transact { transaction in
                        transaction.insert(added)
                        transaction.setContainer([added.id], to: frames[n % 3])
                    }
                }),
                ("a keystroke in a note in one", median(runs: 100, prepare: { board.settle() }, onThread: true) {
                    n += 1
                    editor.transact { $0.update(inside, as: StickyNote.self) { $0.props.text = MentionText(plain: String(repeating: "b", count: n)) } }
                }),
            ]
            for (name, cost) in timings {
                let before = smaller[name]
                report(String(format: "%7d shapes, constrained frames, %@: %6.3f ms (budget %.1f)%@", size, name, cost, Budget.constraintCommit,
                              before.map { String(format: ", %.1f times the %.3f ms on the board before", cost / max($0, 0.0001), $0) } ?? ""))
                if holdsToBudgets {
                    expect(cost < Budget.constraintCommit, "\(name) over \(size) shapes took \(cost) ms")
                    if let before { expect(cost < before * Budget.constraintCommitOverSmaller + Budget.constraintCommitSlack, "\(name) took \(cost) ms over \(size) shapes, \(before) on the board before") }
                }
                smaller[name] = cost
            }
            // A note dragged by its middle over the third frame, which accepts only titled shapes and so refuses it: each event's hint.
            let h = board.h
            h.press(at: board.looseCenter)
            h.drag(to: CGPoint(x: board.thirdCenter.x - 200, y: board.thirdCenter.y))
            var step = 0
            let hint = median(runs: 21, prepare: { board.settle() }, onThread: true) {
                step += 1
                h.drag(to: CGPoint(x: board.thirdCenter.x - 100 + CGFloat(step % 40), y: board.thirdCenter.y + CGFloat(step % 7)))
            }
            expectEqual(editor.hintedShapeID, nil, "no outline over the frame that refuses it")
            h.release()
            expectEqual(editor.holder(of: board.loose), nil, "and it went back")
            let key = "a hint over a frame"
            let beforeHint = smaller[key]
            report(String(format: "%7d shapes, constrained frames, %@: %6.3f ms (budget %.1f)%@", size, key, hint, Budget.constraintHint,
                          beforeHint.map { String(format: ", %.1f times the %.3f ms on the board before", hint / max($0, 0.0001), $0) } ?? ""))
            if holdsToBudgets {
                expect(hint < Budget.constraintHint, "a drag's hint over a constrained frame over \(size) shapes took \(hint) ms")
                if let beforeHint { expect(hint < beforeHint * Budget.constraintCommitOverSmaller + Budget.constraintCommitSlack, "the hint took \(hint) ms over \(size) shapes, \(beforeHint) on the board before") }
            }
            smaller[key] = hint
        }
    },
])
