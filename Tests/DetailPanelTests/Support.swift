import AppKit
import Canvas
import CanvasTesting
import CoreGraphics
import DetailPanel
import Foundation
import Keyboard
import Selection
import SwiftUI
import TestKit

// Fixtures only: the CanvasTesting kinds plus a local gadget, so every test here shows the panel
// knows no real kind.

/// A box kind with one field of each sort a panel edits.
struct Gadget: BoxShapeProps {
    static let kind: ShapeKind = "gadget"
    static let properties = Properties<Gadget> {
        Property("frame", \.frame).required()
        Property("name", \.name)
        Property("mode", \.mode)
        Property("count", \.count)
        Property("remark", \.remark)
        Property("parts", \.parts)
    }
    var frame: CGRect
    var name = ""
    var mode = Mode.plain
    var count = 0.0
    var remark = ""
    var parts: [Part] = []

    enum Mode: String, Codable, CaseIterable, Sendable, SchemaCases {
        case plain, fancy
        var schemaTitle: String { rawValue.capitalized }
    }
    struct Part: SchemaDefined, Hashable, Identifiable, Sendable {
        static let properties = Properties<Part> {
            Property("id", \.id)
            Property("text", \.text)
        }
        var id = UUID()
        var text = ""
    }

    init(_ frame: CGRect, name: String = "", parts: [Part] = []) {
        self.frame = frame
        self.name = name
        self.parts = parts
    }
}

extension Gadget {
    init() { self.init(.zero) }
}

struct GadgetDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Gadget>, in context: RenderContext) {}
}

enum GadgetTab {}
extension GadgetTab: DetailTab { static var title: String { "Gadget" } }

enum PartsTab {}
extension PartsTab: DetailTab { static var title: String { "Parts" } }

/// The gadget kind, its tool, and its panel: Gadget (main, Count), Parts (Items, shown only with
/// parts), Style (Color).
struct GadgetsPlugin: CanvasPlugin {
    var id: PluginID { "gadgets" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(GadgetDefinition()) { gadget in
            let place = gadget.placement(size: CGSize(width: 240, height: 160)) { Gadget(.zero) }
            gadget.tool(label: "Gadget", systemImage: "gearshape", shortcut: "g", placing: place)
            gadget.remarks(\.remark)
            gadget.details(header: { $gadget in DetailHeader(gadget.name.isEmpty ? "Unnamed" : gadget.name, subtitle: gadget.mode.rawValue) }) {
                DetailSection(in: GadgetTab.self) { $gadget in
                    LabeledContent("Name") { TextField("Name", text: $gadget.name) }
                    LabeledContent("Mode") {
                        Picker("Mode", selection: $gadget.mode) { ForEach(Gadget.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                            .pickerStyle(.segmented)
                    }
                }
                DetailSection("Count", in: GadgetTab.self) { $gadget in
                    LabeledContent("Count") { DetailNumberField(value: $gadget.count, unit: "x", in: 0...99) }
                }
                DetailSection("Items", in: PartsTab.self, when: { !$0.parts.isEmpty }) { $gadget in
                    DetailList($gadget.parts, add: { Gadget.Part() }) { $part in TextField("Part", text: $part.text) }
                }
                DetailSection("Color", in: StyleTab.self) { gadget in
                    Text(gadget.wrappedValue.name)
                }
            }
        }
    }
}

// A horizontal's opt-in, in miniature (Checklists' pattern): one line on a kind contributes to the
// horizontal's own point and brings its tab, fully typed, to exactly the kinds that opt in.

enum Remarks: KeyedExtensionPoint {
    typealias Contribution = @MainActor (AnyShapeRecord) -> String?
    static var owner: PluginID { "remarks" }
    static func uniqueKeys(of _: Contribution, for target: ShapeTarget) -> [AnyHashable] { [target] }
}

enum RemarksTab {}
extension RemarksTab: DetailTab {
    static var title: String { "Remarks" }
    static var order: Int { 50 }
}

extension ShapeRegistrar {
    /// Gives this kind a remark, stored at `text` in its props, and a Remarks tab to edit it in.
    mutating func remarks(_ text: WritableKeyPath<Definition.Props, String>) {
        contribute({ $0.typed(as: Definition.Props.self)?.props[keyPath: text] }, to: Remarks.self)
        details {
            DetailSection(in: RemarksTab.self) { $shape in DetailTextArea($shape[dynamicMember: text]) }
        }
    }
}

struct RemarksPlugin: CanvasPlugin {
    var id: PluginID { "remarks" }
    func register(into registrar: inout PluginRegistrar) {}
}

/// A header of a kind's own, which renames the shape in place: the panel's layout, with its
/// header field for a title.
struct RenamingHeader: View {
    @Binding var text: String
    var body: some View { DetailHeaderLabel(subtitle: "Renamed here") { DetailHeaderField($text) } }
}

/// Cards (CanvasTesting's) with a `RenamingHeader` over their text.
struct RenamingCards: CanvasPlugin {
    var id: PluginID { "renaming" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.details(Card.self, header: { $card in RenamingHeader(text: $card.text) }) {}
    }
}

/// Every plugin the gadget needs, then `more`.
@MainActor func gadgetEditor(_ more: [any CanvasPlugin] = [], scheduler: any Scheduler = ManualScheduler()) throws -> CanvasEditor {
    CanvasEditor(registry: try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), GadgetsPlugin(), RemarksPlugin(), DetailPanelPlugin()] + more),
                 scheduler: scheduler)
}

extension CanvasEditor {
    func props<P: ShapeProps>(_ id: ShapeID, as _: P.Type) -> P? { document[id]?.typed(as: P.self)?.props }

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

let gadgetFrame = CGRect(x: 80, y: 40, width: 240, height: 160)
