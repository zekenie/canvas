import Adornments
import AppKit
import Canvas
import CanvasTesting
import Checklists
import ContextMenus
import DetailPanel
import Keyboard
import Selection
import SwiftUI
import TestKit

// Fixtures only: the CanvasTesting kinds plus a local chore, so every test here shows the
// horizontal knows no real kind.

/// A box kind with a checklist, which it doesn't declare: Checklists adds it.
struct Chore: BoxShapeProps {
    static let kind: ShapeKind = "chore"
    static let properties = Properties<Chore> {
        Property("frame", \.frame).required()
        Property("name", \.name)
    }
    var frame: CGRect
    var name = ""

    init(_ frame: CGRect) {
        self.frame = frame
    }
}

extension Chore {
    init() { self.init(.zero) }
}

struct ChoreDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Chore>, in context: RenderContext) {
        context.fillWithShadow(CGPath(rect: shape.frame, transform: nil), .white)
    }
}

/// A second kind, opted in without the chip, as a kind that draws its own list would.
struct Errand: BoxShapeProps {
    static let kind: ShapeKind = "errand"
    static let properties = Properties<Errand> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
}

extension Errand {
    init() { self.init(frame: .zero) }
}

struct ErrandDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Errand>, in context: RenderContext) {
        context.fillWithShadow(CGPath(rect: shape.frame, transform: nil), .white)
    }
}

enum ChoreTab {}
extension ChoreTab: DetailTab { static var title: String { "Chore" } }

/// The chore kind, with its own tab, and the errand kind, each opted into checklists in one line.
struct ChoresPlugin: CanvasPlugin {
    var id: PluginID { "chores" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(ChoreDefinition()) { chore in
            chore.checklist()
            chore.details {
                DetailSection(in: ChoreTab.self) { $chore in LabeledContent("Name") { TextField("Name", text: $chore.name) } }
            }
        }
        registrar.shape(ErrandDefinition()) { $0.checklist(badge: false) }
    }
}

/// Every plugin a chore needs (Adornments lays out and draws its chip), then `more`.
@MainActor func choreEditor(_ more: [any CanvasPlugin] = [], scheduler: any Scheduler = ManualScheduler()) throws -> CanvasEditor {
    CanvasEditor(registry: try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), ChoresPlugin(), AdornmentsPlugin(), ChecklistsPlugin(),
                                                         DetailPanelPlugin(), ContextMenusPlugin()] + more),
                 scheduler: scheduler)
}

/// "wash", "dry", "fold"; the first `done` of them checked.
func laundry(done: Int = 0) -> [ChecklistItem] {
    ["wash", "dry", "fold"].enumerated().map { ChecklistItem(text: $1, isDone: $0 < done) }
}

extension CanvasEditor {
    func items(_ id: ShapeID) -> [ChecklistItem]? { document[id]?[ChecklistProperty.self] }

    /// Inserts a shape with these checklist items, in a transaction of its own.
    @discardableResult
    func add<P: ShapeProps>(_ props: P, items: [ChecklistItem]) -> ShapeID {
        var record = AnyShapeRecord(ShapeRecord(props))
        record[ChecklistProperty.self] = items
        transact { $0.insert(record) }
        return record.id
    }

    func layout(_ id: ShapeID) throws -> DetailLayout {
        let state = try require(detailPanel), record = try require(document[id])
        return state.layout(for: record)
    }
}

extension DetailLayout {
    /// "Tab: section, section" per tab, which reads well in a failure.
    var outline: [String] {
        tabs.map { tab in "\(tab.title): " + sections(in: tab).map(\.section).joined(separator: ", ") }
    }
}

let choreFrame = CGRect(x: 80, y: 40, width: 240, height: 160)
