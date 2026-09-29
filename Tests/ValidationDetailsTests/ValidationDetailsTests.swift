import Canvas
import CanvasTesting
import CoreGraphics
import DetailPanel
import SwiftUI
import TestKit
import Validation
import ValidationDetails

/// A box with no size has three issues, from two rules, in no particular order of severity.
let emptyBoxRules = Contributor(id: "rules") { r in
    r.validateEveryShape { shape, _ in shape.box?.width == 0 ? [.warning("Odd."), .error("No width.")] : [] }
    r.validate(Box.self) { box, _ in box.frame.height == 0 ? [.error("No height.")] : [] }
}

/// A tab every box has here, so there's a tab before Issues.
enum BoxTab {}
extension BoxTab: DetailTab { static var title: String { "Box" } }

let boxSections = Contributor(id: "box-sections") { r in
    r.detailsForEveryBox { DetailSection(in: BoxTab.self) { _ in Text("Box") } }
}

@MainActor func harness(_ plugins: [any CanvasPlugin]) throws -> EditorHarness {
    try EditorHarness(plugins: [FixturesPlugin()] + plugins)
}

extension EditorHarness {
    func layout(_ id: ShapeID) throws -> DetailLayout {
        try require(editor.detailPanel).layout(for: require(editor.document[id]))
    }

    /// The lines of the shape's Issues tab.
    func issues(_ id: ShapeID) throws -> [DetailStatus] { try layout(id).statuses(in: .of(IssuesTab.self)) }

    func footer(_ id: ShapeID) throws -> [DetailStatus] {
        try require(editor.detailPanel).statuses(for: require(editor.document[id]))
    }
}

@MainActor let validationDetailsTests = Suite("Validation details", [
    test("a shape's issues are the lines of its Issues tab, worst first, in their tones; ties keep the rules' order") {
        let h = try harness([ValidationPlugin(), DetailPanelPlugin(), ValidationDetailsPlugin(), emptyBoxRules])
        let box = h.add(Box(.zero))
        expectEqual(try h.issues(box), [
            DetailStatus("No height.", tone: .error),
            DetailStatus("No width.", tone: .error),
            DetailStatus("Odd.", tone: .warning),
        ])
        expectEqual(try h.footer(box), [], "nothing in the footer")
    },
    test("the Issues tab shows only while the shape has issues, after every other tab") {
        let h = try harness([ValidationPlugin(), DetailPanelPlugin(), ValidationDetailsPlugin(), emptyBoxRules, boxSections])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 40, height: 40)))
        expectEqual(try h.layout(box).tabs.map(\.title), ["Box"])
        h.editor.transact { $0.update(box, as: Box.self) { $0.frame.size.height = 0 } }
        expectEqual(try h.layout(box).tabs.map(\.title), ["Box", "Issues"])
        expectEqual(try h.issues(box), [DetailStatus("No height.", tone: .error)])
        h.editor.transact { $0.update(box, as: Box.self) { $0.frame.size.height = 40 } }
        expectEqual(try h.layout(box).tabs.map(\.title), ["Box"])
    },
    test("the panel remembers Issues as the tab chosen for a kind: a shape with issues opens on it, one without on its first tab") {
        let h = try harness([ValidationPlugin(), DetailPanelPlugin(), ValidationDetailsPlugin(), emptyBoxRules, boxSections])
        let state = try require(h.editor.detailPanel)
        let flat = h.add(Box(CGRect(x: 0, y: 0, width: 40, height: 0)))
        let fine = h.add(Box(CGRect(x: 0, y: 0, width: 40, height: 40)))
        expectEqual(state.currentTab(in: try h.layout(flat), for: Box.kind), .of(BoxTab.self), "the first tab, until one's chosen")
        state.choose(.of(IssuesTab.self), for: Box.kind)
        expectEqual(state.currentTab(in: try h.layout(flat), for: Box.kind), .of(IssuesTab.self))
        expectEqual(state.currentTab(in: try h.layout(fine), for: Box.kind), .of(BoxTab.self))
        h.editor.transact { $0.update(flat, as: Box.self) { $0.frame.size.height = 40 } }
        expectEqual(state.currentTab(in: try h.layout(flat), for: Box.kind), .of(BoxTab.self), "its issues fixed, the tab goes")
        h.editor.transact { $0.update(fine, as: Box.self) { $0.frame.size.height = 0 } }
        expectEqual(state.currentTab(in: try h.layout(fine), for: Box.kind), .of(IssuesTab.self), "and is back for the next shape with issues")
    },
    test("a kind without other tabs gets just Issues; a valid shape none") {
        let h = try harness([ValidationPlugin(), DetailPanelPlugin(), ValidationDetailsPlugin(), Contributor(id: "rules") { r in
            r.validate(Tag.self) { tag, _ in tag.props.target == nil ? [.warning("Points at nothing.")] : [] }
        }])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 40, height: 40)))
        let tag = h.add(Tag(target: nil))
        expectEqual(try h.layout(tag).tabs.map(\.title), ["Issues"])
        expectEqual(try h.issues(tag), [DetailStatus("Points at nothing.", tone: .warning)])
        h.editor.transact { $0.update(tag, as: Tag.self) { $0.props.target = box } }
        expectEqual(try h.layout(tag).tabs, [])
    },
    test("without validation installed, there's no Issues tab") {
        let h = try harness([DetailPanelPlugin(), ValidationDetailsPlugin()])
        expectEqual(try h.layout(h.add(Box(.zero))).tabs, [])
    },
    test("without the panel installed, the bridge is refused") {
        expectThrows(RegistryError.ownerNotInstalled(point: "DetailStatuses", owner: .detailPanel, contributor: "validation-details")) {
            _ = try Registry(plugins: [FixturesPlugin(), ValidationPlugin(), ValidationDetailsPlugin()])
        }
    },
    test("the bridge is one line in the report, and contributes to Validation nothing") {
        let registry = try Registry(plugins: [ValidationPlugin(), DetailPanelPlugin(), ValidationDetailsPlugin()])
        expectEqual(registry.report, """
        core                tool hand · command undo · command redo · command zoomIn · command zoomOut · command zoomToActualSize · command zoomToFit
        validation          service ValidationEngine · overlay ValidationOverlay · ValidationRules
        detail-panel        service DetailPanelState
        validation-details  DetailStatuses in Issues
        """)
    },
])
