import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Selection
import TestKit

// The lead of an open shape's label (`AdornmentPlacement.inLabelLead`): a pill that sits in the label's frame ahead of its
// words, in the room the shape's geometry keeps for it (`ShapeGeometry.labelLead`), drawn and pointed at in world units. The
// geometry asks how wide it is (`AdornmentLead.faces`, a layout input Adornments provides) and takes the first face that fits
// the room it has. The tether is an open shape of this target's own that does what an arrow does.

/// The lead on every tether, clickable.
enum Lead {}
extension Lead: Adornment {
    static var placement: AdornmentPlacement { .inLabelLead }
}
extension Lead: ClickableAdornment {
    static func click(_ click: AdornmentClick, in editor: CanvasEditor) {
        clicked.append(click.shape)
        clicks.append(click)
    }
}

/// An open shape between two points whose label is the lead alone, as wide as the face that fits `room` along its length: the first
/// of the faces Adornments says it has that, with a padding of 4 either side, is no wider than `room`, else the last.
struct Tether: ShapeProps {
    static let kind: ShapeKind = "tether"
    static let properties = Properties<Tether> {
        Property("from", \.from)
        Property("to", \.to)
        Property("room", \.room)
    }
    var from: CGPoint
    var to: CGPoint
    var room: Double

    init(from: CGPoint, to: CGPoint, room: Double = 1_000) {
        self.from = from
        self.to = to
        self.room = room
    }
}

extension Tether {
    init() { self.init(from: .zero, to: .zero) }
}

struct TetherDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Tether>, in context: RenderContext) {}

    func geometry(of shape: ShapeRecord<Tether>, in context: ShapeContext) -> ShapeGeometry {
        let props = shape.props
        let middle = CGPoint(x: (props.from.x + props.to.x) / 2, y: (props.from.y + props.to.y) / 2)
        let outline = [props.from, middle, props.to]
        guard let faces = context.layoutInput(AdornmentLead.faces, of: shape)?.sizes, let last = faces.last else {
            return ShapeGeometry(outline: outline, isClosed: false)
        }
        let face = faces.first { $0.width + 8 <= CGFloat(props.room) } ?? last
        let label = CGRect(x: (middle.x - (face.width + 8) / 2).rounded(), y: (middle.y - (face.height + 8) / 2).rounded(),
                           width: face.width + 8, height: face.height + 8)
        let lead = CGRect(x: label.minX + 4, y: label.minY + 4, width: face.width, height: face.height)
        return ShapeGeometry(outline: outline, bounds: CGRect(enclosing: outline).union(label), isClosed: false, label: label, labelLead: lead)
    }
}

struct TethersPlugin: CanvasPlugin {
    var id: PluginID { "tethers" }
    func register(into registrar: inout PluginRegistrar) { registrar.shape(TetherDefinition()) }
}

let leadTag = AdornmentTag("lead")
let owner = AdornmentLabel("Owner").tinted(lightTint).tagged(leadTag)
let ownerWithValue = owner.noted("2021").narrowing(to: [owner, AdornmentLabel.mark(.dot).tinted(lightTint).tagged(leadTag)])

@MainActor func leadHarness(_ label: AdornmentLabel? = ownerWithValue, more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try adornedHarness([TethersPlugin(), StrandsPlugin()] + (label.map { label in [everyShape(Lead.self, id: "leads") { _ in label }] } ?? []) + more)
}

let tetherFrom = CGPoint(x: 50, y: 150), tetherTo = CGPoint(x: 350, y: 150)

@MainActor let leadTests = Suite("The lead of an open shape's label", [
    test("it is drawn where the geometry kept room for it, in world units, at every zoom: its frame is that rect") {
        let h = try leadHarness()
        let tether = h.add(Tether(from: tetherFrom, to: tetherTo))
        let lead = try require(h.editor.shapeContext.geometry(of: tether)?.labelLead)
        for zoom in [1, 0.5, 2] as [CGFloat] {
            h.editor.camera = Camera(origin: .zero, zoom: zoom)
            let frames = h.editor.adornmentFrames(of: tether)
            expectEqual(frames.map(\.adornment), [.of(Lead.self)])
            expectEqual(frames.first?.rect, lead, "at \(zoom)")
        }
        expect(lead.width > 40, "the whole face, name and note: \(lead)")
    },
    test("the geometry reads each face's size, widest first, and the tint: the whole pill, the name alone, a dot") {
        let h = try leadHarness()
        let tether = h.add(Tether(from: tetherFrom, to: tetherTo))
        let faces = try require(h.editor.shapeContext.layoutInput(AdornmentLead.faces, for: tether))
        expectEqual(faces.sizes.count, 3)
        expect(faces.sizes[0].width > faces.sizes[1].width && faces.sizes[1].width > faces.sizes[2].width, "\(faces.sizes)")
        expectEqual(faces.sizes[0].height, 18)
        expectEqual(faces.sizes[2], CGSize(width: 10, height: 10), "a dot")
        expectEqual(faces.tint, lightTint)
    },
    test("the face drawn is the one whose size the room is: the whole, the name alone, a dot") {
        let h = try leadHarness()
        let first = h.add(Tether(from: tetherFrom, to: tetherTo))
        let faces = try require(h.editor.shapeContext.layoutInput(AdornmentLead.faces, for: first)).sizes
        @MainActor func label(room: Double) throws -> AdornmentLabel {
            let tether = h.add(Tether(from: tetherFrom, to: tetherTo, room: room))
            return try require(h.editor.adornmentFrames(of: tether).first?.label)
        }
        let whole = try label(room: faces[0].width + 8)
        expectEqual(whole.text, "Owner")
        expectEqual(whole.note, "2021")
        let name = try label(room: faces[1].width + 8)
        expectEqual(name.text, "Owner")
        expectEqual(name.note, nil)
        let dot = try label(room: 5)
        expectEqual(dot.text, nil)
        expectEqual(dot.mark, .dot)
        expectEqual(dot.tag, leadTag, "each face is the lead's: a click on any of them is the same click")
    },
    test("a shape whose geometry keeps no room shows no lead, and a shape with no lead asks for none: nothing is made for it") {
        let h = try leadHarness()
        let strand = h.add(Strand(from: strandFrom, to: strandTo, label: CGRect(x: 200, y: 185, width: 60, height: 30)))
        expectEqual(h.editor.adornmentFrames(of: strand), [], "a label with no lead")
        let bare = try leadHarness(nil)
        let tether = bare.add(Tether(from: tetherFrom, to: tetherTo))
        expectEqual(bare.editor.shapeContext.layoutInput(AdornmentLead.faces, for: tether), nil)
        expectEqual(bare.editor.shapeContext.geometry(of: tether)?.label, nil)
    },
    test("it is a canvas button: a click in it says the shape, the tag and the rect, and one in the cut around it, or off it, says nothing") {
        clicks = []
        clicked = []
        let h = try leadHarness()
        let tether = h.add(Tether(from: tetherFrom, to: tetherTo))
        let geometry = try require(h.editor.shapeContext.geometry(of: tether))
        let lead = try require(geometry.labelLead), label = try require(geometry.label)
        h.click(at: h.editor.camera.toView(CGPoint(x: lead.midX, y: lead.midY)))
        expectEqual(clicks, [AdornmentClick(shape: tether, tag: leadTag, rect: lead)])
        h.editor.camera = Camera(origin: .zero, zoom: 0.5)
        h.click(at: h.editor.camera.toView(CGPoint(x: lead.midX, y: lead.midY)))
        expectEqual(clicks.count, 2, "at 50%")
        h.editor.camera = Camera()
        h.click(at: CGPoint(x: label.minX - 20, y: label.midY))
        expectEqual(clicks.count, 2, "off it")
        let hand = h.editor.hoveredButton
        h.move(to: CGPoint(x: lead.midX, y: lead.midY))
        expectEqual(h.editor.hoveredButton, AnyHashable(AdornmentButton(Lead.self, on: tether, tag: leadTag)))
        expect(hand != h.editor.hoveredButton)
    },
    test("it is drawn in its rect and nowhere else, in world units: the same pixels, scaled, at 200%") {
        let h = try leadHarness()
        let without = try leadHarness(nil)
        let tether = h.add(Tether(from: tetherFrom, to: tetherTo))
        without.add(Tether(from: tetherFrom, to: tetherTo))
        let lead = try require(h.editor.shapeContext.geometry(of: tether)?.labelLead)
        let drawn = render(h), bare = render(without)
        let slot = lead.insetBy(dx: -AdornmentLayout.slotMargin, dy: -AdornmentLayout.slotMargin)
        expect(changedPixels(drawn, bare, in: lead) > 100, "ink in the rect")
        expectEqual(changedPixels(drawn, bare, in: CGRect(x: 0, y: 0, width: 400, height: slot.minY)), 0, "none above")
        expectEqual(changedPixels(drawn, bare, in: CGRect(x: 0, y: slot.maxY, width: 400, height: 300 - slot.maxY)), 0, "none below")
        expectEqual(changedPixels(drawn, bare, in: CGRect(x: 0, y: 0, width: slot.minX, height: 300)), 0, "none left")
        expectEqual(changedPixels(drawn, bare, in: CGRect(x: slot.maxX, y: 0, width: 400 - slot.maxX, height: 300)), 0, "none right")
        h.editor.camera = Camera(origin: .zero, zoom: 2)
        without.editor.camera = Camera(origin: .zero, zoom: 2)
        let big = renderBitmap(h.editor, size: CGSize(width: 800, height: 600)), bigBare = renderBitmap(without.editor, size: CGSize(width: 800, height: 600))
        let scaled = CGRect(x: lead.minX * 2, y: lead.minY * 2, width: lead.width * 2, height: lead.height * 2)
        expect(changedPixels(big, bigBare, in: scaled) > 100)
        var box = CGRect.null
        for y in 0..<600 { for x in 0..<800 where pixel(big, at: CGPoint(x: x, y: y)) != pixel(bigBare, at: CGPoint(x: x, y: y)) { box = box.union(CGRect(x: x, y: y, width: 1, height: 1)) } }
        expect(scaled.insetBy(dx: -8, dy: -8).contains(box), "its size follows the zoom: all of it within \(scaled), at 200%: \(box)")
    },
    test("a dot is the tint's color, strong, and a ghost is a dashed outline with no fill; each is its own face and says something") {
        let dot = AdornmentLabel.mark(.dot).tinted(lightTint), ghost = AdornmentLabel.mark(.ghost)
        expect(dot != ghost)
        expect(dot.showsSomethingForTests && ghost.showsSomethingForTests)
        for (name, label, width) in [("dot", dot, 10), ("ghost", ghost, 30)] as [(String, AdornmentLabel, CGFloat)] {
            let h = try leadHarness(label.tagged(leadTag), more: [])
            let tether = h.add(Tether(from: tetherFrom, to: tetherTo))
            let lead = try require(h.editor.shapeContext.geometry(of: tether)?.labelLead)
            expectEqual(lead.width, width, name)
            let bare = try leadHarness(nil)
            bare.add(Tether(from: tetherFrom, to: tetherTo))
            let ink = changedPixels(render(h), render(bare), in: lead.insetBy(dx: -2, dy: -2))
            expect(ink > 8, "\(name) draws something: \(ink)")
            if label.mark == .ghost { expect(ink < Int(lead.width * lead.height) / 2, "a ghost is dashes, not a fill: \(ink)") }
        }
    },
    test("what the pill says changing with no commit to the shape lays it out again, once, and only if its size moved") {
        let h = try leadHarness(nil, more: [pinsPlugin2()])
        let tether = h.add(Tether(from: tetherFrom, to: tetherTo))
        expectEqual(h.editor.shapeContext.geometry(of: tether)?.label, nil, "nothing said yet")
        let words = try require(h.editor.service(LeadWords.self))
        words.say = AdornmentLabel("Owner").tagged(leadTag)
        h.editor.adornmentsDidChange(for: [tether])
        let short = try require(h.editor.shapeContext.geometry(of: tether)?.labelLead)
        let layout = h.editor.layoutRevision
        words.say = AdornmentLabel("Owner or primary driver").tagged(leadTag)
        h.editor.adornmentsDidChange(for: [tether])
        let long = try require(h.editor.shapeContext.geometry(of: tether)?.labelLead)
        expect(long.width > short.width, "the room follows what it says: \(short) then \(long)")
        expectEqual(h.editor.layoutRevision, layout + 1)
        h.editor.adornmentsDidChange(for: [tether])
        expectEqual(h.editor.layoutRevision, layout + 1, "told again with nothing changed: no new layout")
        words.say = nil
        h.editor.adornmentsDidChange(for: [tether])
        expectEqual(h.editor.shapeContext.geometry(of: tether)?.labelLead, nil, "nothing to say: no room kept")
    },
    test("a shape laid out again with nothing changed (a note it is bound to moved) asks the label no more; a commit that changes it, or adornmentsDidChange, does") {
        let asked = Asked()
        let h = try leadHarness(nil, more: [Contributor(id: "counted") { r in
            r.forEveryShape { scope in
                scope.adornment(Lead.self) { _, _ in
                    asked.count += 1
                    return ownerWithValue
                }
            }
        }])
        let tether = h.add(Tether(from: tetherFrom, to: tetherTo))
        _ = h.editor.shapeContext.geometry(of: tether)
        let first = asked.count
        expect(first > 0)
        for _ in 0..<5 {
            h.editor.shapesDidChangeLayout([tether])
            _ = h.editor.shapeContext.geometry(of: tether)
        }
        expectEqual(asked.count, first, "the answer is kept")
        h.editor.adornmentsDidChange(for: [tether])
        _ = h.editor.shapeContext.geometry(of: tether)
        expect(asked.count > first, "asked again once told")
        let told = asked.count
        h.editor.transact("Room") { $0.update(tether, as: Tether.self) { $0.props.room = 50 } }
        _ = h.editor.shapeContext.geometry(of: tether)
        expect(asked.count > told, "and for a commit that changed the shape")
    },
    test("a label's note, narrower faces and marks: copies keep them, blank is none, a face has no narrower faces of its own, and a note needs text") {
        let label = AdornmentLabel("Owner").noted("  2021 \n")
        expectEqual(label.note, "2021")
        expectEqual(label.wrong().note, "2021")
        expectEqual(label.tagged(AdornmentTag("a")).note, "2021")
        expectEqual(AdornmentLabel("Owner").noted("  ").note, nil)
        expectEqual(AdornmentLabel(systemImage: "flag").noted("2021").note, nil)
        expectEqual(AdornmentLabel.line("a").noted("2021").note, nil)
        let narrowed = label.narrowing(to: [AdornmentLabel("Owner").narrowing(to: [AdornmentLabel("x")]), AdornmentLabel.mark(.dot)])
        expectEqual(narrowed.narrowerFaces.count, 2)
        expect(narrowed.narrowerFaces.allSatisfy { $0.narrowerFaces.isEmpty }, "a face's own narrower faces go")
        expect(narrowed != label, "part of what makes two labels equal")
        expectEqual(narrowed.opacity(0.5).narrowerFaces.count, 2)
    },
])

@MainActor final class Asked {
    var count = 0
}

/// What a service says the lead is: a label that changes, with the shapes told when it does.
@MainActor final class LeadWords {
    var say: AdornmentLabel?
}
extension LeadWords: EditorService {}

@MainActor func pinsPlugin2() -> Contributor {
    Contributor(id: "lead-words") { r in
        r.service { _ in LeadWords() }
        r.forEveryShape { scope in
            scope.adornment(Lead.self) { _, context in context.service(LeadWords.self)?.say }
        }
    }
}

extension AdornmentLabel {
    /// Whether it is laid out at all: Adornments leaves out a label that says nothing.
    @MainActor var showsSomethingForTests: Bool { mark != nil || text != nil }
}
