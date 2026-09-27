import Adornments
import Canvas
import CanvasTesting
import CoreGraphics
import Keyboard
import Selection
import TestKit

// What the registry refuses: one adornment twice on a kind, from one side; a contribution without
// Adornments; Adornments without Selection, whose canvas buttons it lends.

@MainActor let registryTests = Suite("Adornments in the registry", [
    test("two plugins putting one adornment on a kind, or on every shape, conflict") {
        let base: [any CanvasPlugin] = [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), SignsPlugin(), AdornmentsPlugin()]
        let boxFlag = { (id: PluginID) in Contributor(id: id) { $0.adornment(Flag.self, on: Box.self) { _ in flagLabel } } }
        expectThrows(RegistryError.conflict(point: "ShapeAdornments", key: "box AdornmentsTests.Flag", plugins: ["a", "b"])) {
            _ = try Registry(plugins: base + [boxFlag("a"), boxFlag("b")])
        }
        // A kind's own and a bridge's.
        expectThrows(RegistryError.conflict(point: "ShapeAdornments", key: "sign AdornmentsTests.Flag", plugins: ["signs", "b"])) {
            _ = try Registry(plugins: base + [Contributor(id: "b") { $0.adornment(Flag.self, on: Sign.self) { _ in flagLabel } }])
        }
        expectThrows(RegistryError.conflict(point: "ShapeAdornments", key: "* AdornmentsTests.Flag", plugins: ["a", "b"])) {
            _ = try Registry(plugins: base + [everyShape(Flag.self, id: "a") { _ in flagLabel }, everyShape(Flag.self, id: "b") { _ in flagLabel }])
        }
    },
    test("a kind's own and every shape's of one adornment don't: the kind's own takes its place") {
        _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), SignsPlugin(), AdornmentsPlugin(),
                                   everyShape(Flag.self) { _ in flagLabel }])
    },
    test("an adornment needs Adornments, and Adornments needs Selection; a bridge's needs its kind") {
        expectThrows(RegistryError.ownerNotInstalled(point: "ShapeAdornments", owner: .adornments, contributor: "flags")) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), everyShape(Flag.self, id: "flags") { _ in flagLabel }])
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "CanvasButtons", owner: .selection, contributor: .adornments)) {
            _ = try Registry(plugins: [FixturesPlugin(), AdornmentsPlugin()])
        }
        expectThrows(RegistryError.unknownKind(Sign.kind, point: "ShapeAdornments", contributor: "b")) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), AdornmentsPlugin(),
                                       Contributor(id: "b") { $0.adornment(Flag.self, on: Sign.self) { _ in flagLabel } }])
        }
    },
    test("the report names each adornment and what it's on") {
        let registry = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), AdornmentsPlugin(), Contributor(id: "flags") { r in
            r.adornment(Flag.self, on: Box.self) { _ in flagLabel }
            r.adornmentForEveryShape(Pin.self) { _, _ in pinLabel }
        }])
        expectEqual(registry.report, """
        core          tool hand
        keyboard      service KeyboardState · key strokes · shortcut H → tool hand · shortcut ⎋ → Cancel · shortcut ⌘. → Cancel
        selection     service SelectionState · tool select · shortcut V → tool select · default tool select · outlines · overlay HandlesOverlay · command delete · shortcut ⌫ → command delete · shortcut ⌦ → command delete · command selectAll · shortcut ⌘A → command selectAll · command goBack · shortcut ⌘[ → command goBack · shortcut ↩ → Edit Selection · shortcut ⌤ → Edit Selection
        fixtures      shape box · shape disc · shape tag
        adornments    service AdornmentState · overlay AdornmentOverlay · CanvasButtons · DecorationHits
        flags         adornment Flag → box · adornment Pin → every shape
        """)
    },
])
