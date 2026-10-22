import Adornments
import AppKit
import Canvas
import CanvasTesting
import Geometry
import Keyboard
import Selection

// Fixtures only (CanvasTesting's boxes, discs, tags and cards, and a local sign), so every test
// here shows the horizontal knows no real kind. Four adornments of this target's own, one or two in
// each place.

/// Text at the row's left end, as a title's pill.
enum Caption {}
extension Caption: Adornment {
    static var placement: AdornmentPlacement { .aboveTopLeft }
}

/// A symbol at the row's right end.
enum Flag {}
extension Flag: Adornment {
    static var placement: AdornmentPlacement { .aboveTopRight }
}

/// A symbol at the row's right end, farthest out, that a click does something with, as a lock.
enum Pin {}
extension Pin: Adornment {
    static var placement: AdornmentPlacement { .aboveTopRight }
    static var order: Order<Self> { .last }
}
extension Pin: ClickableAdornment {
    static func click(_ click: AdornmentClick, in editor: CanvasEditor) {
        clicked.append(click.shape)
        clicks.append(click)
    }
}

/// The shapes a pin was clicked on, in order.
@MainActor var clicked: [ShapeID] = []
/// What each of those clicks said.
@MainActor var clicks: [AdornmentClick] = []

/// Text on the top-right corner: a tally, "☑ 2/5".
enum Count {}
extension Count: Adornment {
    static var placement: AdornmentPlacement { .onTopRightCorner }
}

let flagLabel = AdornmentLabel(systemImage: "flag.fill")
let pinLabel = AdornmentLabel(systemImage: "pin.fill")

/// A box kind of this target's own, with its own caption (its text) and flag: a kind's own
/// adornments, from its registrar.
struct Sign: BoxShapeProps {
    static let kind: ShapeKind = "sign"
    static let properties = Properties<Sign> {
        Property("frame", \.frame).required()
        Property("text", \.text)
        Property("isFlagged", \.isFlagged)
    }
    var frame: CGRect
    var text = ""
    var isFlagged = false

    init(_ frame: CGRect, text: String = "", isFlagged: Bool = false) {
        self.frame = frame
        self.text = text
        self.isFlagged = isFlagged
    }
}

extension Sign {
    init() { self.init(.zero) }
}

struct SignDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Sign>, in context: RenderContext) {}
}

struct SignsPlugin: CanvasPlugin {
    var id: PluginID { "signs" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(SignDefinition()) { sign in
            sign.adornment(Caption.self) { $0.props.text.isEmpty ? nil : AdornmentLabel($0.props.text) }
            sign.adornment(Flag.self) { $0.props.isFlagged ? flagLabel : nil }
        }
    }
}

/// A plugin that puts `A` on every shape of the kinds `where` picks (a capability the plugin states, "that
/// <id> picks"), else on every shape, showing what `label` says.
@MainActor func everyShape<A: Adornment>(_: A.Type, id: PluginID = "every-shape", where appliesTo: (@MainActor @Sendable (RegisteredKind) -> Bool)? = nil,
                                         _ label: @escaping @MainActor (AnyShapeRecord) -> AdornmentLabel?) -> Contributor {
    Contributor(id: id) { r in
        let adorn: (inout ScopedRegistrar) -> Void = { $0.adornment(A.self) { shape, _ in label(shape) } }
        if let appliesTo { r.forShapes(adopting: ShapeCapability("that \(id) picks", appliesTo), adorn) } else { r.forEveryShape(adorn) }
    }
}

/// What the app has around Adornments (the keys and the selection), the fixtures, signs and cards
/// (which claim the double-click on empty canvas), then `more`.
@MainActor func adornedHarness(_ more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), SignsPlugin(),
                                CardsPlugin { card, place in card.createOnDoubleClick(place) }, AdornmentsPlugin()] + more)
}

/// The view these tests draw: 400 by 300 points.
let wholeView = CGRect(x: 0, y: 0, width: 400, height: 300)

@MainActor func render(_ h: EditorHarness) -> NSBitmapImageRep { renderBitmap(h.editor, size: wholeView.size) }

/// The test box: its top-left corner at (100, 100), 200 wide, so at 100% a flag at the row's right
/// end is at (282, 73), 18 points square, centered at (291, 82).
let boxFrame = CGRect(x: 100, y: 100, width: 200, height: 120)
let flagCenter = CGPoint(x: 291, y: 82)

extension CanvasEditor {
    /// A shape's adornments' frames, in world units.
    func rects(_ id: ShapeID) -> [CGRect] { adornmentFrames(of: id).map(\.rect) }
}

/// A random number generator that always gives the same numbers from the same seed (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// Fixtures for several labels in one adornment (a group), and for an open shape with a label.

/// A group of tagged chips at the row's left end, clickable, as a shape's type chips are.
enum Chips {}
extension Chips: Adornment {
    static var placement: AdornmentPlacement { .aboveTopLeft }
    static var order: Order<Self> { .after(Caption.self) }
}
extension Chips: ClickableAdornment {
    static func click(_ click: AdornmentClick, in editor: CanvasEditor) {
        clicked.append(click.shape)
        clicks.append(click)
    }
}

/// A group put where only one label goes: the registry refuses it.
enum RightChips {}
extension RightChips: Adornment {
    static var placement: AdornmentPlacement { .aboveTopRight }
}

enum CornerChips {}
extension CornerChips: Adornment {
    static var placement: AdornmentPlacement { .onTopRightCorner }
}

/// A chip named `name`, tagged by it.
func chip(_ name: String) -> AdornmentLabel { AdornmentLabel(name).tagged(AdornmentTag(name)) }

/// A plugin that shows `names` as `Chips` on every shape.
@MainActor func chipsPlugin(_ names: [String], id: PluginID = "chips") -> Contributor {
    Contributor(id: id) { $0.forEveryShape { scope in
        scope.adornments(Chips.self) { _, _ in names.map(chip) }
    } }
}

/// An open shape from one point to another through a middle one, with a label's rect if it has one:
/// as an arrow is. Its bounds hold all of them.
struct Strand: ShapeProps {
    static let kind: ShapeKind = "strand"
    static let properties = Properties<Strand> {
        Property("from", \.from)
        Property("to", \.to)
        Property("label", \.label)
        Property("isLabelled", \.isLabelled)
    }
    var from: CGPoint
    var to: CGPoint
    var label: CGRect
    var isLabelled: Bool

    init(from: CGPoint, to: CGPoint, label: CGRect? = nil) {
        self.from = from
        self.to = to
        self.label = label ?? .zero
        isLabelled = label != nil
    }
}

extension Strand {
    init() { self.init(from: .zero, to: .zero) }
}

struct StrandDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Strand>, in context: RenderContext) {}

    func geometry(of shape: ShapeRecord<Strand>, in context: ShapeContext) -> ShapeGeometry {
        let props = shape.props
        let middle = CGPoint(x: (props.from.x + props.to.x) / 2, y: (props.from.y + props.to.y) / 2)
        let outline = [props.from, middle, props.to]
        let label: CGRect? = props.isLabelled ? props.label : nil
        return ShapeGeometry(outline: outline, bounds: label.map { CGRect(enclosing: outline).union($0) }, isClosed: false, label: label)
    }
}

struct StrandsPlugin: CanvasPlugin {
    var id: PluginID { "strands" }
    func register(into registrar: inout PluginRegistrar) { registrar.shape(StrandDefinition()) }
}
