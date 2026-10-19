import Canvas
import CanvasTesting
import CoreGraphics
import TestKit
import Validation

/// Asks the engine for verdicts as it hears each commit: made before the engine, so it hears of each commit first,
/// and its asking has the engine hear it then.
@MainActor
private final class EarlyAsker {
    var asked: [ShapeID] = []
    var heard: [CachedVerdict] = []
}

extension EarlyAsker: EditorService {
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        heard += asked.map { editor.validation?.cachedResult(for: $0) ?? .unknown }
    }
}

/// A root holding an empty box (an issue), a sized one (none), a tag on the sized one (an error
/// while the shape it's on is empty: its rule looks that shape up) and a pocket, whose board holds
/// another empty box. Every check of a box or a tag counts (`calls`).
@MainActor private struct Checked {
    let h: EditorHarness
    let asker = EarlyAsker()
    let pocket = ShapeID(), empty = ShapeID(), sized = ShapeID(), tag = ShapeID(), inner = ShapeID()
    var engine: ValidationEngine { h.editor.validation! }

    init() throws {
        let file = CanvasFile(root: CanvasDocument(shapes: [
            AnyShapeRecord(ShapeRecord(id: empty, Box(.zero))),
            AnyShapeRecord(ShapeRecord(id: sized, Box(CGRect(x: 0, y: 0, width: 10, height: 10)))),
            AnyShapeRecord(ShapeRecord(id: tag, Tag(target: sized))),
            AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 0, y: 0, width: 200, height: 100)))),
        ]), children: [pocket: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: inner, Box(.zero)))])])
        let asker = asker
        h = try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin(), Contributor(id: "asker") { $0.service { _ in asker } },
                                        ValidationPlugin(), Rules { r in
            r.validate(Box.self) { box, _ in
                calls += 1
                return box.frame.isEmpty ? [.warning("empty")] : []
            }
            r.validate(Tag.self) { tag, context in
                calls += 1
                return tag.props.target.flatMap { context.shape($0) }?.box?.isEmpty == false ? [] : [.error("empty target")]
            }
        }], file: file)
    }

    func verdicts() -> [CachedVerdict] { [empty, sized, tag].map(engine.cachedResult) }

    func resize(_ id: ShapeID, to size: CGSize) {
        h.editor.transact("Resize") { $0.update(id, as: Box.self) { $0.frame.size = size } }
    }
}

private let emptyBox = CachedVerdict.current(ValidationResult(issues: [.warning("empty")]))
private let emptyTarget = CachedVerdict.current(ValidationResult(issues: [.error("empty target")]))

@MainActor let cachedResultTests = Suite("Cached verdicts", [
    test("unknown until the engine has read the board shown; then what it found, none included, and the reading runs no rule") {
        calls = 0
        let c = try Checked()
        expectEqual(c.verdicts(), [.unknown, .unknown, .unknown], "nothing read yet")
        expectEqual(calls, 0, "asking reads nothing")
        _ = c.engine.results
        let checked = calls
        expectEqual(c.verdicts(), [emptyBox, .current(nil), .current(nil)])
        for _ in 0..<3 { _ = c.verdicts() }
        expectEqual(calls, checked, "asking runs no rule")
    },
    test("a shape changed, moved, or whose rule looked up one that changed, is unknown until it's checked again; the rest stay current") {
        calls = 0
        let c = try Checked()
        _ = c.engine.results
        let checked = calls
        c.resize(c.sized, to: .zero)
        expectEqual(c.verdicts(), [emptyBox, .unknown, .unknown], "the box changed, and the tag looked it up")
        expectEqual(calls, checked, "asking checks nothing")
        _ = c.engine.results
        expectEqual(c.verdicts(), [emptyBox, emptyBox, emptyTarget])
        c.h.editor.transact("Move") { $0.translate([c.empty], by: CGPoint(x: 5, y: 5)) }
        expectEqual(c.verdicts(), [.unknown, emptyBox, emptyTarget], "a move waits for the rules that don't ignore moves")
        _ = c.engine.results
        expectEqual(c.verdicts(), [emptyBox, emptyBox, emptyTarget])
        c.h.editor.transact("Delete") { $0.delete([c.empty]) }
        expectEqual(c.engine.cachedResult(for: c.empty), .unknown, "gone, and waiting")
        _ = c.engine.results
        expectEqual(c.engine.cachedResult(for: c.empty), .unknown, "not on the board shown")
    },
    test("only the board shown's: a shape on another board is unknown, and going back takes back what was found there") {
        calls = 0
        let c = try Checked()
        _ = c.engine.results
        expectEqual(c.engine.cachedResult(for: c.inner), .unknown, "on the pocket's board")
        c.h.enter(c.pocket)
        expectEqual(c.engine.cachedResult(for: c.inner), .unknown, "not read since it was shown")
        _ = c.engine.results
        expectEqual(c.engine.cachedResult(for: c.inner), emptyBox)
        expectEqual(c.verdicts(), [.unknown, .unknown, .unknown], "the root isn't shown")
        let checked = calls
        c.h.editor.showBoard(.root)
        expectEqual(c.verdicts(), [emptyBox, .current(nil), .current(nil)], "taken back as it was left, checking nothing")
        expectEqual(calls, checked)
    },
    test("asked by a service that hears a commit before the engine would, as the engine has heard it") {
        calls = 0
        let c = try Checked()
        _ = c.engine.results
        c.asker.asked = [c.empty, c.sized]
        c.resize(c.empty, to: CGSize(width: 3, height: 3))
        expectEqual(c.asker.heard, [.unknown, .current(nil)], "the engine heard the commit as it was asked: the shape it changed waits to be checked, the other is current")
        expectEqual(c.engine.cachedResult(for: c.sized), .current(nil))
    },
])
