@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import TestKit
import Validation

/// A vertical that opts in, the way sticky-notes does, but with fixture kinds.
struct Rules: CanvasPlugin {
    let id: PluginID
    let body: @MainActor (inout PluginRegistrar) -> Void
    init(_ id: PluginID = "rules", _ body: @escaping @MainActor (inout PluginRegistrar) -> Void) {
        self.id = id
        self.body = body
    }
    func register(into registrar: inout PluginRegistrar) { body(&registrar) }
}

struct TinyBoxDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Tiny>, in context: RenderContext) {}
}
struct Tiny: BoxShapeProps {
    static let kind: ShapeKind = "tiny"
    var frame: CGRect
}

@MainActor var calls = 0

@MainActor let validationTests = Suite("Validation", [
    test("a rule registered in a shape's registrar gets typed props and applies only to its kind") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), Rules { r in
            r.shape(TinyBoxDefinition()) { tiny in
                tiny.validate { shape, _ in shape.props.frame.width < 10 ? [.error("too small")] : [] }
            }
        }])
        let small = h.add(Tiny(frame: CGRect(x: 0, y: 0, width: 5, height: 5)))
        h.add(Tiny(frame: CGRect(x: 0, y: 0, width: 50, height: 50)))
        h.add(Box(CGRect(x: 0, y: 0, width: 1, height: 1)))
        let results = try require(h.editor.validation).results
        expectEqual(Array(results.keys), [small])
        expectEqual(results[small]?.isValid, false)
    },
    test("a plugin can add a rule for another plugin's kind, and one for every kind; kind rules run first") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), Rules { r in
            r.validateEveryShape { _, _ in [.warning("every")] }
            r.validate(Box.self) { box, _ in box.frame.isEmpty ? [.warning("empty box")] : [] }
        }])
        let box = h.add(Box(.zero))
        let disc = h.add(Disc(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let results = try require(h.editor.validation).results
        expectEqual(results[box]?.issues.map(\.message), ["empty box", "every"])
        expectEqual(results[disc]?.issues.map(\.message), ["every"])
    },
    test("validity is derived: an error makes a shape invalid; warnings don't") {
        expectEqual(ValidationResult(issues: [.warning("w"), .error("e")]).isValid, false)
        expectEqual(ValidationResult(issues: [.warning("w"), .error("e")]).worst, .error)
        expectEqual(ValidationResult(issues: [.warning("w"), .warning("v")]).isValid, true)
        expectEqual(ValidationResult(issues: [.warning("w"), .warning("v")]).worst, .warning)
    },
    test("worst first: the errors, then the warnings, each in the rules' order") {
        let result = ValidationResult(issues: [.warning("w1"), .error("e1"), .warning("w2"), .error("e2")])
        expectEqual(result.worstFirst.map(\.message), ["e1", "e2", "w1", "w2"])
    },
    test("results recompute after a change, and only then") {
        calls = 0
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), Rules { r in
            r.validate(Box.self) { box, _ in calls += 1; return box.frame.isEmpty ? [.warning("empty")] : [] }
        }])
        let box = h.add(Box(.zero))
        let engine = try require(h.editor.validation)
        expect(engine.result(for: box) != nil)
        _ = engine.results
        expectEqual(calls, 1)
        h.editor.transact { $0.update(box, as: Box.self) { $0.frame.size = CGSize(width: 5, height: 5) } }
        expect(engine.result(for: box) == nil)
        expectEqual(calls, 2)
        h.editor.transact { $0.delete([box]) }
        expect(engine.results.isEmpty)
    },
    test("rules can read other shapes through the context") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), Rules { r in
            r.validate(Tag.self) { tag, context in
                tag.props.target.flatMap { context.shape($0) } == nil ? [.error("dangling")] : []
            }
        }])
        let box = h.add(Box(.zero))
        let tag = h.add(Tag(target: box))
        expect(h.editor.validation?.result(for: tag) == nil)
        h.editor.transact { $0.delete([box]) }
        expectEqual(h.editor.validation?.result(for: tag)?.issues.map(\.message), ["dangling"])
    },
    test("after a change, only the shapes it touched are checked again, and those whose rules looked one of them up") {
        calls = 0
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), Rules { r in
            r.validate(Tag.self) { tag, context in
                calls += 1
                guard let box = tag.props.target.flatMap({ context.shape($0)?.box }) else { return [.error("dangling")] }
                return box.isEmpty ? [.warning("empty target")] : []
            }
        }])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let other = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let tag = h.add(Tag(target: box))
        let engine = try require(h.editor.validation)
        expect(engine.result(for: tag) == nil)
        expectEqual(calls, 1)
        h.editor.transact { $0.update(other, as: Box.self) { $0.frame.size = .zero } }
        _ = engine.results
        expectEqual(calls, 1, "the tag's rule never looked at the other box")
        h.editor.transact { $0.update(box, as: Box.self) { $0.frame.size = .zero } }
        expectEqual(engine.result(for: tag)?.issues.map(\.message), ["empty target"])
        expectEqual(calls, 2)
        h.editor.transact { $0.update(tag, as: Tag.self) { $0.props.target = other } }
        expectEqual(engine.result(for: tag)?.issues.map(\.message), ["empty target"], "the other box is empty too")
        expectEqual(calls, 3)
        h.editor.transact { $0.update(box, as: Box.self) { $0.frame.size = CGSize(width: 5, height: 5) } }
        _ = engine.results
        expectEqual(calls, 3, "the tag no longer looks at the first box")
    },
    test("a shape's dependents are the shapes whose rules looked it up when they were last checked") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), Rules { r in
            r.validate(Tag.self) { tag, context in
                tag.props.target.flatMap { context.shape($0) } == nil ? [.error("dangling")] : []
            }
        }])
        let box = h.add(Box(.zero)), other = h.add(Box(.zero))
        let tag = h.add(Tag(target: box))
        let engine = try require(h.editor.validation)
        _ = engine.results
        expectEqual(engine.dependents(of: [box]), [tag])
        expectEqual(engine.dependents(of: [other, tag]), [])
        h.editor.transact { $0.update(tag, as: Tag.self) { $0.props.target = other } }
        _ = engine.results
        expectEqual(engine.dependents(of: [box]), [])
        expectEqual(engine.dependents(of: [box, other]), [tag])
    },
    test("contributing a rule without the validation plugin installed is an error") {
        expectThrows(RegistryError.ownerNotInstalled(point: "ValidationRules", owner: .validation, contributor: "rules")) {
            _ = try Registry(plugins: [FixturesPlugin(), Rules { r in r.validate(Box.self) { _, _ in [] } }])
        }
    },
    test("the overlay outlines a flagged shape 3 view points outside it, colored by the worst issue") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), Rules { r in
            r.validate(Box.self) { box, _ in
                switch box.frame.minX {
                case ..<100: [.warning("left"), .warning("again")]
                case ..<200: [.warning("middle"), .error("right")]
                default: []
                }
            }
        }])
        h.add(Box(CGRect(x: 40, y: 40, width: 40, height: 40)))
        h.add(Box(CGRect(x: 140, y: 40, width: 40, height: 40)))
        h.add(Box(CGRect(x: 240, y: 40, width: 40, height: 40)))
        h.editor.camera = Camera(origin: .zero, zoom: 2)
        let rep = renderBitmap(h.editor, size: CGSize(width: 600, height: 200))
        // Each box's top edge, 3 pt out. Orange and red differ in green: about 141 and 56.
        let warning = pixel(rep, at: CGPoint(x: 60 * 2, y: 40 * 2 - 3))
        let error = pixel(rep, at: CGPoint(x: 160 * 2, y: 40 * 2 - 3))
        let clean = pixel(rep, at: CGPoint(x: 260 * 2, y: 40 * 2 - 3))
        expect(warning[0] > 200 && warning[1] > 110 && warning[2] < 100, "orange outline: \(warning)")
        expect(error[0] > 200 && error[1] < 100 && error[2] < 100, "red outline: \(error)")
        expect(clean[0] < 250 && abs(clean[0] - clean[2]) < 10, "no outline: \(clean)")
    },
])
