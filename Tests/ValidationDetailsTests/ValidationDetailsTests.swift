import Canvas
import CanvasTesting
import CoreGraphics
import DetailPanel
import TestKit
import Validation
import ValidationDetails

/// A box with no size has four issues, from two rules, in no particular order of severity.
let emptyBoxRules = Contributor(id: "rules") { r in
    r.validateEveryShape { shape, _ in shape.box?.width == 0 ? [.info("Empty."), .error("No width."), .warning("Odd.")] : [] }
    r.validate(Box.self) { box, _ in box.frame.height == 0 ? [.error("No height.")] : [] }
}

@MainActor func harness(_ plugins: [any CanvasPlugin]) throws -> EditorHarness {
    try EditorHarness(plugins: [FixturesPlugin()] + plugins)
}

extension EditorHarness {
    func statuses(_ id: ShapeID) throws -> [DetailStatus] {
        try require(editor.detailPanel).statuses(for: require(editor.document[id]))
    }
}

@MainActor let validationDetailsTests = Suite("Validation details", [
    test("a shape's issues become statuses, worst first, with matching tones; ties keep the rules' order") {
        let h = try harness([ValidationPlugin(), DetailPanelPlugin(), ValidationDetailsPlugin(), emptyBoxRules])
        let box = h.add(Box(.zero))
        expectEqual(try h.statuses(box), [
            DetailStatus("No height.", tone: .error),
            DetailStatus("No width.", tone: .error),
            DetailStatus("Odd.", tone: .warning),
            DetailStatus("Empty.", tone: .info),
        ])
    },
    test("a valid shape has none, and they follow the document") {
        let h = try harness([ValidationPlugin(), DetailPanelPlugin(), ValidationDetailsPlugin(), emptyBoxRules])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 40, height: 40)))
        let tag = h.add(Tag(target: box))
        expectEqual(try h.statuses(box), [])
        expectEqual(try h.statuses(tag), [])
        h.editor.transact { $0.update(box, as: Box.self) { $0.frame.size.height = 0 } }
        expectEqual(try h.statuses(box), [DetailStatus("No height.", tone: .error)])
    },
    test("without validation installed, there are no statuses") {
        let h = try harness([DetailPanelPlugin(), ValidationDetailsPlugin()])
        expectEqual(try h.statuses(h.add(Box(.zero))), [])
    },
    test("without the panel installed, the bridge is refused") {
        expectThrows(RegistryError.ownerNotInstalled(point: "DetailStatuses", owner: .detailPanel, contributor: "validation-details")) {
            _ = try Registry(plugins: [FixturesPlugin(), ValidationPlugin(), ValidationDetailsPlugin()])
        }
    },
    test("the bridge is one line in the report, and contributes to Validation nothing") {
        let registry = try Registry(plugins: [ValidationPlugin(), DetailPanelPlugin(), ValidationDetailsPlugin()])
        expectEqual(registry.report, """
        core                tool hand [h]
        validation          service ValidationEngine · overlay ValidationOverlay
        detail-panel        service DetailPanelState · ShapeDetails
        validation-details  DetailStatuses
        """)
    },
])
