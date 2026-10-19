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

struct GaugeDefinition {}

extension GaugeDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Gauge>, in context: RenderContext) {}
}

/// A box whose props count how often they're written as JSON: how often its schema is checked.
struct Counted: BoxShapeProps {
    static let kind: ShapeKind = "counted"
    static let properties = Properties<Counted> {
        Property("frame", \.frame).required()
        Property("label", \.label).maxLength(3)
        Property("tally", \.tally)
    }
    var frame = CGRect(x: 0, y: 0, width: 10, height: 10)
    var label = ""
    var tally = Tally()
}

/// Counts its encodings.
struct Tally: Codable, Equatable, Sendable, SchemaDescribed {
    nonisolated(unsafe) static var encodings = 0
    static func schema(in _: inout SchemaDefinitions) -> JSONObject { ["type": "integer"] }
    init() {}
    init(from _: any Decoder) throws {}
    func encode(to encoder: any Encoder) throws {
        Self.encodings += 1
        var container = encoder.singleValueContainer()
        try container.encode(0)
    }
}

struct CountedDefinition {}

extension CountedDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Counted>, in context: RenderContext) {}
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
    test("a shape that only moves keeps its schema's issues, unchecked; any other change checks it again") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), Rules { $0.shape(CountedDefinition()) }])
        let id = h.add(Counted(label: "long"))
        let engine = try require(h.editor.validation)
        let tooLong = ValidationIssue.warning("Label is 4 characters long, and should be at most 3.", field: "label")
        expectEqual(engine.result(for: id)?.issues, [tooLong])
        let checked = Tally.encodings
        for _ in 1...3 {
            h.editor.transact { $0.translate([id], by: CGPoint(x: 10, y: 5)) }
            expectEqual(engine.result(for: id)?.issues, [tooLong], "kept")
        }
        // A drag, as the select tool starts one: each event only moves the shape.
        h.move(to: CGPoint(x: 5, y: 5))
        h.editor.session = TranslatingSession(ids: [id], from: CGPoint(x: 5, y: 5), in: h.editor)
        for step in 1...3 {
            h.drag(to: CGPoint(x: 5 + 10 * step, y: 5))
            expectEqual(engine.result(for: id)?.issues, [tooLong], "kept")
        }
        h.release()
        expectEqual(Tally.encodings, checked, "never written as JSON, so never checked")

        h.editor.transact { $0.update(id) { $0.box = CGRect(x: 0, y: 0, width: 40, height: 30) } }
        expectEqual(engine.result(for: id)?.issues, [tooLong])
        expectEqual(Tally.encodings, checked + 1, "resized, not moved: checked")
        h.editor.transact { $0.update(id, as: Counted.self) { $0.props.label = "ok" } }
        expectEqual(engine.result(for: id), nil)
        expectEqual(Tally.encodings, checked + 2, "anything else: checked")
        h.editor.transact { $0.translate([id], by: CGPoint(x: -5, y: 0)) }
        expectEqual(engine.result(for: id), nil, "and what it found kept")
        expectEqual(Tally.encodings, checked + 2)
    },
    test("the schema's rule is Validation's own, one for every kind, in the report") {
        let registry = try Registry(plugins: [FixturesPlugin(), ValidationPlugin()])
        expectEqual(registry.report.split(separator: "\n").last.map(String.init),
                    "validation    service ValidationEngine · overlay ValidationOverlay · ValidationRules → every shape")
    },
])

extension Gauge {
    init(level: Double = 0, label: String = "") {
        self.init()
        self.level = level
        self.label = label
    }
}
