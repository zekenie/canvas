import Adornments
import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Geometry
import Keyboard
import Selection
import TestKit

// Where adornments come from (the three sugars, `where`, the kind's own taking every shape's
// place) and where they go, as `editor.adornmentFrames(of:)` has them: world units.

/// An added property only boxes hold, in the "`where` picks the kinds that hold…" test.
enum Starred {}
extension Starred: ShapeProperty {
    static let key: PropertyKey = "starred"
    static var defaultValue: Bool? { nil }
}

/// Which kinds are marked: a point of this target's own, declared by the markers plugin, that a
/// kind is opted into as a kind is into Titles. The markers plugin flags the kinds marked `true`.
enum Marked {}
extension Marked: KeyedExtensionPoint {
    typealias Contribution = Bool
    static var owner: PluginID { "markers" }
    static func uniqueKeys(of _: Bool, for target: ShapeTarget) -> [AnyHashable] { [target] }
}

extension CanvasEditor {
    /// A shape's adornments, by type.
    func adornments(_ id: ShapeID) -> [AdornmentID] { adornmentFrames(of: id).map(\.adornment) }
    /// What a shape's adornments say.
    func texts(_ id: ShapeID) -> [String?] { adornmentFrames(of: id).map(\.label.text) }
}

@MainActor let placementTests = Suite("Placing adornments", [
    test("a kind's own adornments, from its registrar, show what its shapes say") {
        let h = try adornedHarness()
        let sign = h.add(Sign(boxFrame, text: "Lobby"))
        expectEqual(h.editor.adornments(sign), [.of(Caption.self)])
        expectEqual(h.editor.adornmentFrames(of: sign).first?.label, AdornmentLabel("Lobby"))
        let caption = try require(h.editor.rects(sign).first)
        expectEqual(caption.origin, CGPoint(x: 100, y: 73))
        expectEqual(caption.height, 18)
        expect(caption.width > 30 && caption.width < 60, "as wide as its text: \(caption.width)")
        h.editor.transact { $0.update(sign, as: Sign.self) { $0.props.isFlagged = true } }
        expectEqual(h.editor.adornments(sign), [.of(Caption.self), .of(Flag.self)])
        expectEqual(h.editor.rects(sign).last, CGRect(x: 282, y: 73, width: 18, height: 18))
        h.editor.transact { $0.update(sign, as: Sign.self) { $0.props.text = "" } }
        expectEqual(h.editor.adornments(sign), [.of(Flag.self)], "nil: nothing on that shape")
    },
    test("a bridge's, on a kind another plugin registers, and on no other kind") {
        let h = try adornedHarness([Contributor(id: "box-counts") { $0.adornment(Count.self, on: Box.self) { _ in AdornmentLabel("3") } }])
        let box = h.add(Box(boxFrame)), disc = h.add(Disc(boxFrame))
        expectEqual(h.editor.adornments(box), [.of(Count.self)])
        let count = try require(h.editor.rects(box).first)
        expectEqual(count.maxX, 306, "6 points past the right edge")
        expectEqual(count.midY, 100, "centered on the top edge")
        expectEqual(count.height, 16)
        expectEqual(h.editor.adornments(disc), [])
    },
    test("every shape's, from a plugin that defines no kind; a shape with no outline has none") {
        let h = try adornedHarness([everyShape(Flag.self) { _ in flagLabel }])
        let box = h.add(Box(boxFrame)), disc = h.add(Disc(boxFrame)), card = h.add(Card(boxFrame)), tag = h.add(Tag(target: box))
        for id in [box, disc, card] { expectEqual(h.editor.adornments(id), [.of(Flag.self)]) }
        expectEqual(h.editor.rects(box), [CGRect(x: 282, y: 73, width: 18, height: 18)])
        expectEqual(h.editor.adornmentFrames(of: tag), [], "a tag has no outline")
        expectEqual(h.editor.adornmentFrames(of: ShapeID()), [], "nor has a shape that isn't there")
    },
    test("`where` picks kinds by their definition, and is asked once per kind: cards, which are editable, and not boxes") {
        var asked: [ShapeKind] = []
        let h = try adornedHarness([everyShape(Flag.self, where: { kind in
            asked.append(kind.kind)
            return kind.definition is any Editable
        }) { _ in flagLabel }])
        let cards = [h.add(Card(boxFrame)), h.add(Card(boxFrame))], box = h.add(Box(boxFrame))
        for _ in 0..<2 {
            for id in cards { expectEqual(h.editor.adornments(id), [.of(Flag.self)]) }
            expectEqual(h.editor.adornments(box), [])
        }
        expectEqual(asked, [Card.kind, Box.kind])
    },
    test("`where` picks kinds by what the registry says of them: another point's contributions, as Titles picks titled kinds") {
        let h = try adornedHarness([
            Contributor(id: "markers") { r in
                r.adornmentForEveryShape(Flag.self, where: { $0.registry.contributions(to: Marked.self, for: $0.kind).first == true }) { _, _ in flagLabel }
            },
            Contributor(id: "marking") { r in
                r.contribute(true, to: Marked.self, for: .kind(Box.kind))
                r.contribute(false, to: Marked.self, for: .kind(Disc.kind))
            },
        ])
        expectEqual(h.editor.adornments(h.add(Box(boxFrame))), [.of(Flag.self)])
        expectEqual(h.editor.adornments(h.add(Disc(boxFrame))), [])
        expectEqual(h.editor.adornments(h.add(Card(boxFrame))), [])
    },
    test("`where` picks the kinds that hold an added property, so an adornment that shows one goes where it does, as Locking's lock") {
        let h = try adornedHarness([
            Contributor(id: "stars") { r in
                r.declare(Starred.self)
                r.optIn(Box.self, to: Starred.self)
                // A label that shows on any shape it's asked of: `where` alone keeps it off the rest.
                r.adornmentForEveryShape(Flag.self, where: { $0.holds(Starred.self) }) { _, _ in flagLabel }
            },
        ])
        expectEqual(h.editor.adornments(h.add(Box(boxFrame))), [.of(Flag.self)])
        expectEqual(h.editor.adornments(h.add(Disc(boxFrame))), [], "a disc can't hold the star")
        expectEqual(h.editor.adornments(h.add(Card(boxFrame))), [], "nor can a card")
    },
    test("a kind's own adornment takes the place of every shape's of its type, even where it shows nothing") {
        let h = try adornedHarness([everyShape(Caption.self) { _ in AdornmentLabel("Every") }])
        let sign = h.add(Sign(boxFrame, text: "Own")), box = h.add(Box(boxFrame))
        expectEqual(h.editor.texts(sign), ["Own"])
        expectEqual(h.editor.texts(box), ["Every"])
        h.editor.transact { $0.update(sign, as: Sign.self) { $0.props.text = "" } }
        expectEqual(h.editor.adornmentFrames(of: sign), [])
    },
    test("in the order they're claimed: by order, then the kind's own, then every shape's, in plugin order") {
        let h = try adornedHarness([everyShape(Pin.self, id: "pins") { _ in pinLabel }, everyShape(Count.self, id: "counts") { _ in AdornmentLabel("3") }])
        let sign = h.add(Sign(boxFrame, text: "A caption much longer than the sign is wide", isFlagged: true))
        expectEqual(h.editor.adornments(sign), [.of(Caption.self), .of(Flag.self), .of(Count.self), .of(Pin.self)])
        let rects = h.editor.rects(sign)
        expectEqual(rects[1].minX, 282, "the flag nearest the row's right end")
        expectEqual(rects[3].minX, 260, "the pin, of a later band, farther out")
        expect(rects[0].maxX == 256, "the caption stops 4 points short of the pin: \(rects[0])")
    },
    test("text is on one line: each run of whitespace folds into a space, and blank text shows nothing") {
        let h = try adornedHarness()
        let sign = h.add(Sign(boxFrame, text: "  Front\n\tdesk  "))
        expectEqual(h.editor.texts(sign), ["Front desk"])
        h.editor.transact { $0.update(sign, as: Sign.self) { $0.props.text = " \n " } }
        expectEqual(h.editor.adornmentFrames(of: sign), [])
    },
    test("a shape kept aside shows none, though its kind has some") {
        let registry = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), AdornmentsPlugin(), everyShape(Flag.self) { _ in flagLabel }])
        let box = ShapeID(), kept = ShapeID()
        let json = """
        { "format" : 1, "schema" : { "box" : 0 }, "shapes" : [
          { "id" : "\(box)", "index" : "a0", "kind" : "box", "props" : { "frame" : [[100, 100], [200, 120]] } },
          { "id" : "\(kept)", "index" : "a1", "kind" : "box", "props" : { "frame" : "wide" } } ] }
        """
        let loaded = try BoardCodec(registry: registry).decode(Data(json.utf8))
        expect(try require(loaded.document[kept]).isOpaque)
        let h = EditorHarness { CanvasEditor(registry: registry, document: loaded.document, scheduler: $0) }
        expectEqual(h.editor.adornments(box), [.of(Flag.self)])
        expectEqual(h.editor.adornmentFrames(of: kept), [])
        // It has no bounds, so it would have no frames anyway: what shows it has none is that its
        // labels are never made, nor kept.
        expectEqual(h.editor.adornmentsKept, 1, "only the box's labels are made and kept")
    },
    test("frames are in world units: a view point's worth down to 25%, 4 world units below; where the shape is, not where it's drawn") {
        let h = try adornedHarness([everyShape(Flag.self) { _ in flagLabel }])
        let box = h.add(Box(boxFrame))
        expectEqual(h.editor.rects(box), [CGRect(x: 282, y: 73, width: 18, height: 18)])
        h.editor.camera = Camera(origin: CGPoint(x: -40, y: 30), zoom: 2)
        expectEqual(h.editor.rects(box), [CGRect(x: 291, y: 86.5, width: 9, height: 9)])
        h.editor.camera = Camera(origin: .zero, zoom: 0.125)
        expectEqual(h.editor.rects(box), [CGRect(x: 228, y: -8, width: 72, height: 72)])
        h.editor.setDrawingOffset(CGPoint(x: 5, y: 0), for: box)
        expectEqual(h.editor.rects(box), [CGRect(x: 228, y: -8, width: 72, height: 72)])
    },
])
