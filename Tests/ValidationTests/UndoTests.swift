@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import TestKit
import Validation

@MainActor let undoTests = Suite("Validation and undo", [
    test("issues follow undo and redo, a rule that looks at another shape's included, as a fresh editor would find them") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), Rules { r in
            r.validate(Box.self) { box, _ in box.frame.width < 10 ? [.error("too small")] : [] }
            r.validate(Tag.self) { tag, context in
                guard let target = tag.props.target else { return [.warning("names nothing")] }
                return (context.shape(target)?.box?.width ?? 0) < 10 ? [.warning("on a small box")] : []
            }
        }])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 50, height: 50)))
        let tag = h.add(Tag(target: box))
        @MainActor func fresh() -> [ShapeID: [String]] {
            let editor = CanvasEditor(registry: h.editor.registry, document: h.editor.document, scheduler: ManualScheduler())
            return (editor.validation?.results ?? [:]).mapValues { $0.issues.map(\.message) }
        }
        @MainActor func now() -> [ShapeID: [String]] { (h.editor.validation?.results ?? [:]).mapValues { $0.issues.map(\.message) } }
        expectEqual(now(), [:])
        h.editor.transact { $0.update(box, as: Box.self) { $0.frame.size.width = 5 } }
        expectEqual(now(), [box: ["too small"], tag: ["on a small box"]])
        h.editor.transact { $0.delete([box]) }
        expectEqual(now(), [tag: ["names nothing"]])
        for _ in 0..<2 {
            h.editor.undo()
            expectEqual(now(), fresh())
        }
        expectEqual(now(), [:])
        for _ in 0..<2 {
            h.editor.redo()
            expectEqual(now(), fresh())
        }
        expectEqual(now(), [tag: ["names nothing"]])
    },
])
