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
        // A kind's own and another plugin's for it.
        expectThrows(RegistryError.conflict(point: "ShapeAdornments", key: "sign AdornmentsTests.Flag", plugins: ["signs", "b"])) {
            _ = try Registry(plugins: base + [Contributor(id: "b") { $0.adornment(Flag.self, on: Sign.self) { _ in flagLabel } }])
        }
        expectThrows(RegistryError.conflict(point: "ShapeAdornments", key: "every shape AdornmentsTests.Flag", plugins: ["a", "b"])) {
            _ = try Registry(plugins: base + [everyShape(Flag.self, id: "a") { _ in flagLabel }, everyShape(Flag.self, id: "b") { _ in flagLabel }])
        }
    },
    test("a kind's own and every shape's of one adornment don't: the kind's own takes its place") {
        _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), SignsPlugin(), AdornmentsPlugin(),
                                   everyShape(Flag.self) { _ in flagLabel }])
    },
    test("an adornment needs Adornments, and Adornments needs Selection; one on another plugin's kind needs that kind") {
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
            r.forEveryShape { scope in
                scope.adornment(Pin.self) { _, _ in pinLabel }
            }
        }])
        expectEqual(registry.report, """
        core          tool hand · command undo · command redo · command insertBeside first in InsertMenu.Shapes · command zoomIn in ViewMenu.Zoom · command zoomOut in ViewMenu.Zoom · command zoomToActualSize in ViewMenu.Zoom · command zoomToFit in ViewMenu.Zoom · command pageUp · command pageDown · command scrollToStart · command scrollToEnd
        keyboard      service KeyboardState · tool tips · menu keys · keyboard help · key strokes · key releases · shortcut H → tool hand · shortcut Space → Pan · shortcut ⎋ → Cancel · shortcut ⌘. → Cancel · shortcut ⌘Z → command undo · shortcut ⇧⌘Z → command redo · shortcut Q → Tool Lock · shortcut ⇧↩ → command insertBeside · shortcut ⌘= → command zoomIn · shortcut ⌘- → command zoomOut · shortcut = → command zoomIn · shortcut - → command zoomOut · shortcut ⌘0 → command zoomToActualSize · shortcut ⇧0 → command zoomToActualSize · shortcut ⇧1 → command zoomToFit · shortcut ⇞ → command pageUp · shortcut ⇟ → command pageDown · shortcut ↖ → command scrollToStart · shortcut ↘ → command scrollToEnd · key hint ⇧ Drag Move Along One Axis · key hint ⌘ Scroll Zoom
        selection     service SelectionState · service RefusalShake · tool select · shortcut V → tool select · default tool select · outlines · overlay GroupFocusOverlay · overlay HandlesOverlay · overlay PartFocusOverlay · overlay ItemsOverlay · key hint ⇧ or ⌘ Click Add or Remove From Selection · key hint ⌘ Drag Select Shapes Wholly in the Box · key hint ⌥ Drag Drag a Copy · key hint ⇧ Resize Keep Proportions · key hint ⌥ Resize Resize From the Center · command shapes · accessible order · accessible parts · command delete · shortcut ⌫ → command delete · shortcut ⌦ → command delete · command selectAll · shortcut ⌘A → command selectAll · command goBack in NavigationSection · shortcut ⌘[ → command goBack · shortcut ⌃- → command goBack · command goForward after goBack in NavigationSection · shortcut ⌘] → command goForward · shortcut ⌃_ → command goForward · command openSelection in NavigationSection · shortcut ⌘↓ → command openSelection · shortcut ↩ → Open Selection · shortcut ⌤ → Open Selection · shortcut ⌥↩ → Open Selection · press focused · command zoomToSelection in ViewMenu.Zoom · shortcut ⇧2 → command zoomToSelection · command smartMagnify · shortcut ← → Nudge, Pan or Step Rows · shortcut ⇧← → Nudge, Pan or Step Rows · shortcut → → Nudge, Pan or Step Rows · shortcut ⇧→ → Nudge, Pan or Step Rows · shortcut ↑ → Nudge, Pan or Step Rows · shortcut ⇧↑ → Nudge, Pan or Step Rows · shortcut ↓ → Nudge, Pan or Step Rows · shortcut ⇧↓ → Nudge, Pan or Step Rows · shortcut ⌥← → Resize or Move Rows · shortcut ⌥⇧← → Resize or Move Rows · shortcut ⌥→ → Resize or Move Rows · shortcut ⌥⇧→ → Resize or Move Rows · shortcut ⌥↑ → Resize or Move Rows · shortcut ⌥⇧↑ → Resize or Move Rows · shortcut ⌥↓ → Resize or Move Rows · shortcut ⌥⇧↓ → Resize or Move Rows · shortcut ⌥⇥ → Next Part · shortcut ⌥⇧⇥ → Previous Part · shortcut ⇥ → Next Shape · shortcut ⇧⇥ → Previous Shape · shortcut ⌥⌘← → Select Nearest Shape · shortcut ⌥⇧⌘← → Add Nearest Shape to Selection · shortcut ⌥⌘→ → Select Nearest Shape · shortcut ⌥⇧⌘→ → Add Nearest Shape to Selection · shortcut ⌥⌘↑ → Select Nearest Shape · shortcut ⌥⇧⌘↑ → Add Nearest Shape to Selection · shortcut ⌥⌘↓ → Select Nearest Shape · shortcut ⌥⇧⌘↓ → Add Nearest Shape to Selection
        fixtures      shape box · shape disc · shape tag
        adornments    service AdornmentState · service ChipFade · layout input adornment-lead · overlay AdornmentOverlay · CanvasButtons · DecorationHits
        flags         adornment Flag → box · adornment Pin last → every shape · parts Pin → every shape
        """)
    },
    test("adornments placed beside each other in a circle are refused") {
        expectThrows(RegistryError.invalid(point: "ShapeAdornments", reason: "adornments placed beside each other in a circle: PingChip after PongChip, PongChip after PingChip")) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), AdornmentsPlugin(), Contributor(id: "loop") { r in
                r.adornment(PingChip.self, on: Box.self) { _ in flagLabel }
                r.adornment(PongChip.self, on: Box.self) { _ in flagLabel }
            }])
        }
    },
])

/// Two adornments each placed right after the other: no order would do.
enum PingChip {}
extension PingChip: Adornment {
    static var placement: AdornmentPlacement { .aboveTopRight }
    static var order: Order<Self> { .after(PongChip.self) }
}

enum PongChip {}
extension PongChip: Adornment {
    static var placement: AdornmentPlacement { .aboveTopRight }
    static var order: Order<Self> { .after(PingChip.self) }
}
