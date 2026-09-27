@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import TestKit
import Validation

/// A box with bounded properties: a level of 0 to 10, and a label of at most 5 characters.
struct Gauge: BoxShapeProps {
    static let kind: ShapeKind = "gauge"
    static let properties = Properties<Gauge>(title: "Gauge") {
        Property("frame", \.frame).required()
        Property("level", \.level).minimum(0).maximum(10)
        Property("label", \.label).maxLength(5)
    }
    var frame: CGRect = CGRect(x: 0, y: 0, width: 10, height: 10)
    var level = 0.0
    var label = ""
}

/// A note on any shape given one, of at most 8 characters.
enum Remark {}
extension Remark: ShapeProperty {
    static let key: PropertyKey = "remark"
    static var defaultValue: String? { nil }
    static var keywords: PropertyKeywords<String> { PropertyKeywords().maxLength(8) }
}

struct GaugeDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Gauge>, in context: RenderContext) {}
}

@MainActor private func gauges(_ rules: @escaping @MainActor (inout ShapeRegistrar<GaugeDefinition>) -> Void = { _ in }) throws -> EditorHarness {
    try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), Rules { r in
        r.shape(GaugeDefinition()) { rules(&$0) }
        r.declare(Remark.self)
        r.optIn(Box.self, to: Remark.self)
    }])
}

@MainActor let schemaRuleTests = Suite("Validation against the schema", [
    test("each place a shape breaks its kind's schema is a warning about the property it's in; within the bounds, nothing") {
        let h = try gauges()
        let fine = h.add(Gauge(level: 10, label: "ok"))
        let off = h.add(Gauge(level: 11, label: "gauges"))
        let engine = try require(h.editor.validation)
        expectEqual(engine.result(for: fine), nil)
        expectEqual(engine.result(for: off)?.issues, [
            .warning("Label is 6 characters long, and should be at most 5.", field: "label"),
            .warning("Level is 11, and should be at most 10.", field: "level"),
        ])
        expectEqual(engine.result(for: off)?.isValid, true, "warnings: the shape is still valid")
    },
    test("an added property's bounds are its schema's too, on every kind that opts in") {
        let h = try gauges()
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        h.editor.transact { $0.update(box) { $0[Remark.self] = "much too long" } }
        expectEqual(h.editor.validation?.result(for: box)?.issues,
                    [.warning("Remark is 13 characters long, and should be at most 8.", field: "remark")])
    },
    test("a number that isn't finite breaks its type, as a board writes it") {
        let h = try gauges()
        let id = h.add(Gauge(level: .nan))
        expectEqual(h.editor.validation?.result(for: id)?.issues, [.warning("Level should be a number, not \"nan\".", field: "level")])
    },
    test("the kind's own rules come first, then the schema's; a change checks the shape again") {
        let h = try gauges { gauge in
            gauge.validate { shape, _ in shape.props.label.isEmpty ? [.error("A gauge needs a label.", field: "label")] : [] }
        }
        let id = h.add(Gauge(level: -1))
        let engine = try require(h.editor.validation)
        expectEqual(engine.result(for: id)?.issues, [
            .error("A gauge needs a label.", field: "label"),
            .warning("Level is -1, and should be at least 0.", field: "level"),
        ])
        h.editor.transact { $0.update(id, as: Gauge.self) { $0.props.level = 3; $0.props.label = "tank" } }
        expectEqual(engine.result(for: id), nil)
    },
    test("the schema's rule is Validation's own, one for every kind, in the report") {
        let registry = try Registry(plugins: [FixturesPlugin(), ValidationPlugin()])
        expectEqual(registry.report.split(separator: "\n").last.map(String.init),
                    "validation    service ValidationEngine · overlay ValidationOverlay · ValidationRules")
    },
])

extension Gauge {
    init(level: Double = 0, label: String = "") {
        self.init()
        self.level = level
        self.label = label
    }
}
