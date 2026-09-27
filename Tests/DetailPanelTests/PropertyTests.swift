import Canvas
import CanvasTesting
import CoreGraphics
import DetailPanel
import Selection
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
    test("a shape's binding binds an added property, nil while it has none: each write one transaction, nil removing it") {
        let editor = try gadgetEditor([BadgesPlugin()])
        let gadget = editor.add(Gadget(gadgetFrame))
        let seal = try require(editor.shapeBinding(gadget, as: Gadget.self))[Seal.self]
        expectEqual(seal.wrappedValue, nil, "no seal yet")
        let revision = editor.revision
        seal.wrappedValue = "wax"
        expectEqual(editor.document[gadget]?[Seal.self], "wax")
        expectEqual(seal.wrappedValue, "wax", "it reads back its own write before the panel draws again")
        expectEqual(editor.revision, revision + 1)
        seal.wrappedValue = "wax"
        expectEqual(editor.revision, revision + 1, "the same value commits nothing")
        seal.wrappedValue = nil
        expectEqual(editor.document[gadget]?[Seal.self], nil)
        expectEqual(editor.revision, revision + 2)
        // Badges every gadget has: a nil write is dropped, and the binding reads what the shape kept.
        let badges = try require(editor.shapeBinding(gadget, as: Gadget.self))[Badges.self]
        badges.wrappedValue = nil
        expectEqual(editor.document[gadget]?[Badges.self], [])
        expectEqual(badges.wrappedValue, [])
        expectEqual(editor.revision, revision + 2)
    },
    test("an added property's binding writes the shape it was made for, whatever is selected by then; nothing once it's gone") {
        let editor = try gadgetEditor([BadgesPlugin()])
        let gadget = editor.add(Gadget(gadgetFrame)), other = editor.add(Gadget(gadgetFrame))
        let seal = try require(editor.shapeBinding(gadget, as: Gadget.self))[Seal.self]
        editor.selection = other
        seal.wrappedValue = "wax"
        expectEqual([gadget, other].map { editor.document[$0]?[Seal.self] }, ["wax", nil])
        editor.transact { $0.delete([gadget]) }
        let revision = editor.revision
        seal.wrappedValue = "stamp"
        expectEqual(editor.revision, revision)
    },
    test("every binding a shape's binding makes of its added properties reads what a write through any of them made, until the panel redraws") {
        let editor = try gadgetEditor([BadgesPlugin()])
        let gadget = editor.add(Gadget(gadgetFrame))
        let shape = try require(editor.shapeBinding(gadget, as: Gadget.self))
        let field = shape[Seal.self], counter = shape[Seal.self]
        field.wrappedValue = "wax"
        expectEqual(counter.wrappedValue, "wax", "a second binding of the same property")
        shape[Seal.self].wrappedValue = (shape[Seal.self].wrappedValue ?? "") + " and ribbon"
        expectEqual(editor.document[gadget]?[Seal.self], "wax and ribbon", "a read-modify-write reads the last write")
        expectEqual(shape[Badges.self].wrappedValue, [], "another property, as the shape has it")
    },
])
