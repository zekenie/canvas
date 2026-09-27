import Canvas
import CanvasTesting
import CoreGraphics
import DetailPanel
import SwiftUI
import TestKit

/// Badges every shape of an opted-in kind has.
enum Badges {}
extension Badges: ShapeProperty {
    static let key: PropertyKey = "badges"
    static var defaultValue: [String]? { [] }
}

/// A seal only the shapes someone seals have.
enum Seal {}
extension Seal: ShapeProperty {
    static let key: PropertyKey = "seal"
    static var defaultValue: String? { nil }
}

enum BadgesTab {}
extension BadgesTab: DetailTab {
    static var title: String { "Badges" }
    static var order: Int { 50 }
}

/// Declares both, with sections over each on every shape that has it; gadgets opt in.
struct BadgesPlugin: CanvasPlugin {
    var id: PluginID { "badges" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.declare(Badges.self)
        registrar.declare(Seal.self)
        registrar.optIn(Gadget.self, to: Badges.self)
        registrar.optIn(Gadget.self, to: Seal.self)
        registrar.details(of: Badges.self) {
            DetailSection("Badges", in: BadgesTab.self) { $badges in Text("\($badges.wrappedValue.count)") }
        }
        registrar.details(of: Seal.self) {
            DetailSection("Seal", in: BadgesTab.self) { $seal in TextField("Seal", text: $seal[dynamicMember: \.self]) }
        }
    }
}

@MainActor let propertySectionTests = Suite("Property sections", [
    test("a property's sections show on the shapes that have it: every shape of a kind that opts in, or only those it's set on") {
        let editor = try gadgetEditor([BadgesPlugin()])
        let gadget = editor.add(Gadget(gadgetFrame)), box = editor.add(Box(gadgetFrame))
        var outline = try editor.layout(gadget).outline
        expect(outline.contains("Badges: Badges"), "\(outline)")
        expect(try !editor.layout(box).outline.contains { $0.hasPrefix("Badges") }, "boxes don't opt in")
        editor.transact { $0.update(gadget) { $0[Seal.self] = "wax" } }
        outline = try editor.layout(gadget).outline
        expect(outline.contains("Badges: Badges, Seal"), "\(outline)")
    },
    test("a property's binding writes its value on the live shape, one transaction per write, and nothing for the same value") {
        let editor = try gadgetEditor([BadgesPlugin()])
        let gadget = editor.add(Gadget(gadgetFrame)), box = editor.add(Box(gadgetFrame))
        let badges = try require(editor.propertyBinding(gadget, Badges.self))
        let revision = editor.revision
        badges.update { $0.append("gold") }
        expectEqual(editor.document[gadget]?[Badges.self], ["gold"])
        expectEqual(editor.revision, revision + 1)
        try require(editor.propertyBinding(gadget, Badges.self)).update { $0 = ["gold"] }
        expectEqual(editor.revision, revision + 1)
        expect(editor.propertyBinding(gadget, Seal.self) == nil, "no seal yet")
        let field = try require(editor.propertyBinding(gadget, Badges.self))[dynamicMember: \.self]
        field.wrappedValue = ["bronze"]
        expectEqual(field.wrappedValue, ["bronze"], "a binding reads back its own write before the panel draws again")
        expect(editor.propertyBinding(box, Badges.self) == nil, "boxes have no badges")
    },
    test("a kind's own sections and header read its added values through the shape") {
        let editor = try gadgetEditor([BadgesPlugin()])
        let gadget = editor.add(Gadget(gadgetFrame))
        editor.transact { $0.update(gadget) { $0[Badges.self] = ["gold", "silver"] } }
        let binding = try require(editor.shapeBinding(gadget, as: Gadget.self))
        expectEqual(binding.shape[Badges.self], ["gold", "silver"])
        expectEqual(binding.shape.props, binding.wrappedValue)
    },
])
