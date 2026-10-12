import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Geometry
import LanguageModels
import Mentions
import Neighbors
import Publishing
import References
import Selection
import ShippedTesting
import StickyNotes
import Subboards
import TableOfContents
import TestKit
import Titles
import Types

// Neighbors over the shipped plugins: hovering a note, or its row in the table of contents, outlines
// what it points to (arrows out of it, what a reference stands for), what points to it, what it
// mentions and what mentions it, each in its color, with a ring for each light a shape is in; the
// arrows between are in their light's color; a note in a subboard lights the subboard's card; and a
// reference's own arrows count with what it stands for.

private let noteLink = NoteLink.id

/// A color as sRGB, 0...255, in an appearance.
@MainActor private func srgb(_ color: NSColor, in name: NSAppearance.Name) -> [Int] {
    var components: [Int] = []
    NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
        let resolved = color.usingColorSpace(.sRGB)!
        components = [resolved.redComponent, resolved.greenComponent, resolved.blueComponent].map { Int(($0 * 255).rounded()) }
    }
    return components
}

/// A color as `renderBitmap` puts it in a bitmap, 0...255 RGBA, resolved in an appearance.
@MainActor private func swatch(_ color: NSColor, in name: NSAppearance.Name) -> [Int] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
        cg.setFillColor(color.cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    }
    return pixel(rep, at: CGPoint(x: 1, y: 1))
}

/// The WCAG contrast ratio of two sRGB colors, 1 for none and 21 for black on white.
private func contrast(_ a: [Int], _ b: [Int]) -> Double {
    func luminance(_ rgb: [Int]) -> Double {
        let linear = rgb.map { value -> Double in
            let c = Double(value) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
    let (first, second) = (luminance(a), luminance(b))
    return (max(first, second) + 0.05) / (min(first, second) + 0.05)
}

/// An arrow bound at both ends, imprecisely, at the centers, on `channel` (nil: on none).
private func arrow(_ from: ShapeID, _ to: ShapeID, on channel: ChannelID? = nil) -> AnyShapeRecord {
    func bound(_ id: ShapeID) -> ArrowTerminal {
        .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
    }
    var record = ShapeRecord(Arrow(start: bound(from), end: bound(to)))
    record[ChannelProperty.self] = channel
    return AnyShapeRecord(record)
}

private func note(_ id: ShapeID, _ column: Int, _ row: Int, _ text: MentionText = "") -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, StickyNote(frame: CGRect(x: column * 400, y: row * 400, width: 200, height: 200), text: text)))
}

/// What the canvas outlines in a light's color: its color, ring and shapes.
private struct Lit: Equatable {
    let color: NSColor
    let ring: Int
    let shapes: Set<ShapeID>

    init(_ color: NSColor, _ ring: Int, _ shapes: Set<ShapeID>) {
        self.color = color
        self.ring = ring
        self.shapes = shapes
    }
}

private extension EditorHarness {
    /// Lets the look at the hover happen and its answer land.
    func settleLights(file: StaticString = #fileID, line: UInt = #line) {
        wait(0)
        guard let neighbors = editor.neighbors else { return }
        spinRunLoop(until: { !neighbors.isAsking }, file: file, line: line)
    }

    var lit: [Lit] { editor.outlines.tinted.map { Lit($0.color, $0.ring, Set($0.shapes)) } }
}

@MainActor private func shipped(_ file: CanvasFile, _ pasteboard: NSPasteboard) throws -> EditorHarness {
    try EditorHarness { scheduler in
        CanvasEditor(registry: try ShippedPlugins.registry(pasteboard: pasteboard, model: ScriptedLanguageModel()), file: file, scheduler: scheduler)
    }
}

/// The shipped lights' colors, as the registry has them, in the order the plugins give them: arrows'
/// two (Connections': what a shape points to, what points to it), then mentions' two (Mentions': what
/// it mentions, what mentions it).
private struct Lights {
    let pointsTo, pointedToBy, mentions, mentionedBy: NSColor

    @MainActor init(_ registry: Registry) throws {
        let lights = registry.neighborLights
        let colors = try require(lights.count == 4 ? lights.map(\.color) : nil, "four lights, not \(lights.count)")
        (pointsTo, pointedToBy, mentions, mentionedBy) = (colors[0], colors[1], colors[2], colors[3])
    }
}

/// On the root: note A, which mentions F and G (G is on subboard S's board); B, which A has an arrow to,
/// and which has one back; C, which A has a note-link to; D, which has an arrow to A; E, which mentions A;
/// and the subboard S, holding G.
private struct Graph {
    let a = ShapeID(), b = ShapeID(), c = ShapeID(), d = ShapeID(), e = ShapeID(), f = ShapeID(), g = ShapeID(), s = ShapeID()
    let ab = ShapeID(), ba = ShapeID(), ac = ShapeID(), da = ShapeID()

    var file: CanvasFile {
        func arrowed(_ id: ShapeID, _ record: AnyShapeRecord) -> AnyShapeRecord { record.copy(as: id) }
        let sub = ShapeRecord(id: s, Subboard(frame: CGRect(x: 1600, y: 0, width: 240, height: 160)))
        return CanvasFile(root: CanvasDocument(shapes: [
            note(a, 1, 1, MentionText([.text("See "), .mention(f, label: "F"), .text(" and "), .mention(g, label: "G")])),
            note(b, 2, 1), note(c, 1, 0), note(d, 0, 1), note(e, 1, 2, MentionText([.text("About "), .mention(a, label: "A")])), note(f, 0, 0),
            AnyShapeRecord(sub), arrowed(ab, arrow(a, b)), arrowed(ba, arrow(b, a)), arrowed(ac, arrow(a, c, on: noteLink)), arrowed(da, arrow(d, a)),
        ]), children: [s: CanvasDocument(shapes: [note(g, 0, 0)])])
    }
}

@MainActor let neighborsShippedTests = Suite("Neighbors, as shipped", [
    test("it follows the query plugins in the shipped list, and the plugins that own the edges give it four lights: arrows' green and purple, then mentions' teal and lavender") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let registry = try ShippedPlugins.registry(pasteboard: pasteboard, model: ScriptedLanguageModel())
        let plugins = ShippedPlugins.plugins(pasteboard: pasteboard, model: ScriptedLanguageModel()).map(\.id.rawValue)
        let neighbors = try require(plugins.firstIndex(of: PluginID.neighbors.rawValue))
        expect(try require(plugins.firstIndex(of: "queries")) < neighbors, "after the engine it asks")
        expect(try require(plugins.firstIndex(of: "query-commands")) < neighbors)
        // The lights are their owners' faces, each a plugin of its own: arrows' first, so a shape both pointed to and mentioned has its arrow's ring first.
        let arrowLights = try require(plugins.firstIndex(of: PluginID.arrowLights.rawValue))
        let mentionLights = try require(plugins.firstIndex(of: PluginID.mentionLights.rawValue))
        expect(neighbors < arrowLights && arrowLights < mentionLights, "Neighbors, then arrows' lights, then mentions'")
        expect(registry.report.contains("neighbors"))
        let lights = registry.neighborLights
        expectEqual(lights.count, 4)
        // Each light asks for the shape named by its id, with the edge types' ids the plugins declare.
        let selector = "#\(ShapeID())"
        let queries = lights.map { $0.query(selector) }
        expectEqual(queries, [":edge-from(\(selector), arrow|stands-for), :starts-at(\(selector), arrow), :end-of(\(selector), arrow)",
                              ":edge-to(\(selector), arrow|stands-for), :ends-at(\(selector), arrow), :start-of(\(selector), arrow)",
                              ":edge-from(\(selector), mention)", ":edge-to(\(selector), mention)"])
    },
    test("a list without Neighbors leaves the lights out, and one with a light and no Neighbors is refused") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let all = ShippedPlugins.plugins(pasteboard: pasteboard, model: ScriptedLanguageModel())
        let faces: Set<PluginID> = [.neighbors, .arrowLights, .mentionLights]
        let without = try Registry(plugins: all.filter { !faces.contains($0.id) })
        expectEqual(without.neighborLights.count, 0)
        expectThrows(RegistryError.ownerNotInstalled(point: "NeighborLights", owner: .neighbors, contributor: .arrowLights)) {
            _ = try Registry(plugins: all.filter { $0.id != .neighbors })
        }
    },
    test("the colors are the design audit's: one sRGB value each in the light and the dark, each at least 3:1 against the canvas it's drawn over") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let lights = try Lights(ShippedPlugins.registry(pasteboard: pasteboard, model: ScriptedLanguageModel()))
        let chosen: [(color: NSColor, light: [Int], dark: [Int])] = [
            (lights.pointsTo, [0x07, 0x93, 0x3B], [0x2F, 0xD3, 0x59]),
            (lights.pointedToBy, [0x8C, 0x21, 0xA4], [0xB8, 0x51, 0xFD]),
            (lights.mentions, [0x0E, 0x97, 0xB0], [0x32, 0x9A, 0xB4]),
            (lights.mentionedBy, [0xA7, 0x6F, 0xE2], [0xD0, 0xB0, 0xFE]),
        ]
        // The canvas's own backgrounds (`Style.canvasBackground`): white 0.965 and 0.11.
        let (lightCanvas, darkCanvas) = ([246, 246, 246], [28, 28, 28])
        for (i, light) in chosen.enumerated() {
            expectEqual(srgb(light.color, in: .aqua), light.light, "light \(i) in the light appearance")
            expectEqual(srgb(light.color, in: .darkAqua), light.dark, "light \(i) in the dark")
            expect(contrast(light.light, lightCanvas) >= 3, "light \(i) on the light canvas: \(contrast(light.light, lightCanvas)):1")
            expect(contrast(light.dark, darkCanvas) >= 3, "light \(i) on the dark canvas: \(contrast(light.dark, darkCanvas)):1")
        }
        expectEqual(Set(chosen.map(\.light)).count, 4, "four colors")
        expectEqual(Set(chosen.map(\.dark)).count, 4)
    },
    test("hovering a note outlines what it points to, what points to it, what it mentions and what mentions it, and the arrows between, each in its color") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let graph = Graph()
        let h = try shipped(graph.file, pasteboard)
        let lights = try Lights(h.editor.registry)
        expectEqual(h.lit, [])
        h.editor.hovered = graph.a
        h.settleLights()
        // B is pointed to by A and points to A: its second light is a ring further out. G is on S's board: S is where it's drawn.
        expectEqual(h.lit, [Lit(lights.pointsTo, 0, [graph.b, graph.c, graph.ab, graph.ac]),
                            Lit(lights.pointedToBy, 0, [graph.d, graph.da, graph.ba]), Lit(lights.pointedToBy, 1, [graph.b]),
                            Lit(lights.mentions, 0, [graph.f, graph.s]), Lit(lights.mentionedBy, 0, [graph.e])])
        expectEqual(h.editor.outlines.faintShapes, [graph.a], "Selection's hover, on the shape itself")
        h.editor.hovered = nil
        h.wait(0)
        expectEqual(h.lit, [])
        // E mentions A, and nothing else is connected to it.
        h.editor.hovered = graph.e
        h.settleLights()
        expectEqual(h.lit, [Lit(lights.mentions, 0, [graph.a])])
        // D has an arrow to A, and nothing else.
        h.editor.hovered = graph.d
        h.settleLights()
        expectEqual(h.lit, [Lit(lights.pointsTo, 0, [graph.a, graph.da])])
        // The subboard S is connected to nothing: A mentions the note on its board, not the card.
        h.editor.hovered = graph.s
        h.settleLights()
        expectEqual(h.lit, [])
    },
    test("a lit arrow is covered in its light's color, as wide as its line and a point more, so its own line doesn't stripe it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let graph = Graph()
        let h = try shipped(graph.file, pasteboard)
        let lights = try Lights(h.editor.registry)
        h.editor.hovered = graph.a
        h.settleLights()
        // D's arrow to A, along y = 500 between them (A's left edge is at 400): lit as what points to A, in its purple.
        let size = CGSize(width: 1200, height: 800)
        let drawn = renderBitmap(h.editor, size: size)
        let purple = Array(swatch(lights.pointedToBy, in: .aqua).prefix(3))
        let column = (480..<520).map { pixel(drawn, at: CGPoint(x: 300, y: CGFloat($0))) }
        // Its line is 3.5 wide: its cover 4.5, centered on y = 500, the four rows between 497.75 and 502.25 whole.
        expectEqual(column.filter { Array($0.prefix(3)) == purple }.count, 4, "four whole pixels of the light's purple across it")
        expectEqual(column.filter { $0[0] < 100 && $0[1] < 100 && $0[2] < 100 }.count, 0, "none of the arrow's own line")
        // Unlit, the line is there, and wider than the tint's old 2.
        h.editor.hovered = nil
        h.wait(0)
        let unlit = renderBitmap(h.editor, size: size)
        expect((480..<520).filter { y in let p = pixel(unlit, at: CGPoint(x: 300, y: CGFloat(y))); return p[0] < 100 && p[1] < 100 && p[2] < 100 }.count >= 3,
               "the arrow's own line, dark, when nothing's lit")
    },
    test("hovering an arrow outlines the shape it ends at as what it points to, and the shape it starts at as what points to it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let graph = Graph()
        let h = try shipped(graph.file, pasteboard)
        let lights = try Lights(h.editor.registry)
        h.editor.hovered = graph.ab
        h.settleLights()
        expectEqual(h.lit, [Lit(lights.pointsTo, 0, [graph.b]), Lit(lights.pointedToBy, 0, [graph.a])])
        // A note-link is an arrow too: its type is under `arrow`.
        h.editor.hovered = graph.ac
        h.settleLights()
        expectEqual(h.lit, [Lit(lights.pointsTo, 0, [graph.c]), Lit(lights.pointedToBy, 0, [graph.a])])
        // The arrow back from B to A: the other way round.
        h.editor.hovered = graph.ba
        h.settleLights()
        expectEqual(h.lit, [Lit(lights.pointsTo, 0, [graph.a]), Lit(lights.pointedToBy, 0, [graph.b])])
        // Re-aimed at D while it's hovered: it ends there now, and undone, back (its edge changed, which the change lists by its ends).
        let toD = ArrowTerminal.bound(ArrowBinding(shapeID: graph.d, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
        h.editor.transact("Re-aim") { $0.update(graph.ba, as: Arrow.self) { $0.props.end = toD } }
        h.settleLights()
        expectEqual(h.lit, [Lit(lights.pointsTo, 0, [graph.d]), Lit(lights.pointedToBy, 0, [graph.b])])
        h.editor.undo()
        h.settleLights()
        expectEqual(h.lit, [Lit(lights.pointsTo, 0, [graph.a]), Lit(lights.pointedToBy, 0, [graph.b])])
    },
    test("hovering a row of the table of contents does the same: a row of the board shown hovers its shape, a row of the subboard's board outlines its card faintly") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let graph = Graph()
        let h = try shipped(graph.file, pasteboard)
        let lights = try Lights(h.editor.registry)
        let contents = try require(h.editor.tableOfContents)
        contents.hover(graph.a)
        h.settleLights()
        expectEqual(h.lit.count, 5)
        expectEqual(h.lit.first, Lit(lights.pointsTo, 0, [graph.b, graph.c, graph.ab, graph.ac]))
        contents.endHover(graph.a)
        h.wait(0)
        expectEqual(h.lit, [])
        // G is a row under S's, on a board the canvas doesn't show: the shape is hovered elsewhere, A mentions it, and
        // S is where it is, which Selection outlines faintly.
        contents.hover(graph.g)
        h.settleLights()
        expectEqual(h.editor.hovered, nil)
        expectEqual(h.editor.hoveredElsewhere, graph.g)
        expectEqual(h.lit, [Lit(lights.mentionedBy, 0, [graph.a])])
        expectEqual(h.editor.outlines.faintShapes, [graph.s], "the card holding it")
        contents.endHover(graph.g)
        h.wait(0)
        expectEqual(h.lit, [])
        expectEqual(h.editor.outlines.faintShapes, [])
    },
    test("a reference's own arrows count with what it stands for: the note is pointed to by the pill and what points at it; the pill by its arrows") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let target = ShapeID(), x = ShapeID(), r = ShapeID(), into = ShapeID()
        var public_ = note(target, 2, 0, "Orders")
        public_[PublicProperty.self] = true
        var props = Reference(frame: CGRect(x: 800, y: 600, width: Reference.defaultSize.width, height: Reference.defaultSize.height))
        ReferenceEdits.pick(&props, ReferenceTarget(id: target, label: "Orders"))
        let pill = AnyShapeRecord(ShapeRecord(id: r, props))
        let h = try shipped(CanvasFile(root: CanvasDocument(shapes: [public_, note(x, 0, 1, "Checkout"), pill, arrow(x, r).copy(as: into)])), pasteboard)
        let lights = try Lights(h.editor.registry)
        // The pill's arrow into it is, to the graph, an arrow into the note it stands for.
        h.editor.hovered = target
        h.settleLights()
        expectEqual(h.lit, [Lit(lights.pointedToBy, 0, [x, r, into])])
        // Checkout points to the note, as the graph reads it, and to the pill, as drawn.
        h.editor.hovered = x
        h.settleLights()
        expectEqual(h.lit, [Lit(lights.pointsTo, 0, [target, r, into])])
        // The pill stands for the note, and the arrow is into it as drawn.
        h.editor.hovered = r
        h.settleLights()
        expectEqual(h.lit, [Lit(lights.pointsTo, 0, [target]), Lit(lights.pointedToBy, 0, [x, into])])
    },
    test("what's outlined is drawn: a note's first ring green and its second purple, 4 and 8 points off its edge, in the app's own editor") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let graph = Graph()
        // No harness (which draws outlines on the shapes' edges): the app's editor stands them off by 4.
        let scheduler = ManualScheduler()
        let editor = CanvasEditor(registry: try ShippedPlugins.registry(pasteboard: pasteboard, model: ScriptedLanguageModel()), file: graph.file,
                                  scheduler: scheduler)
        expectEqual(editor.outlineGap, 4, "what ships")
        let lights = try Lights(editor.registry)
        editor.camera = Camera(origin: CGPoint(x: -100, y: -100), zoom: 0.8)
        editor.hovered = graph.a
        scheduler.advance(by: .zero)
        let neighbors = try require(editor.neighbors)
        spinRunLoop(until: { !neighbors.isAsking })
        let drawn = renderBitmap(editor, size: CGSize(width: 1200, height: 800))
        // B is the note at (800, 400), 200 × 200: on screen its right edge is at x = 880, and its middle at y = 480.
        let right = (800 + 200 + 100) * 0.8, middle = (400 + 100 + 100) * 0.8
        @MainActor func color(_ x: CGFloat) -> [Int] { pixel(drawn, at: CGPoint(x: right + x, y: middle)) }
        // The lights are drawn in the light appearance's values (`renderBitmap` is aqua), each line 2 points wide: 3 to 5 out and 7 to 9.
        @MainActor func ink(_ color: NSColor) -> [Int] { Array(swatch(color, in: .aqua).prefix(3)) }
        let first = ink(lights.pointsTo), second = ink(lights.pointedToBy)
        for x in [3.5, 4.5] { expectEqual(Array(color(x).prefix(3)), first, "ring 0, in the first light's green, \(x) out") }
        for x in [7.5, 8.5] { expectEqual(Array(color(x).prefix(3)), second, "ring 1, in the second light's purple, \(x) out") }
        // Where the line isn't, the canvas is the canvas's: between the rings, and past the second.
        for x in [5.5, 6.5, 10] { expect(color(x)[0] > 230 && color(x)[1] > 230, "the canvas, \(x) out: \(color(x))") }
    },
    test("a pointer lights as a mention does: hovering the Order outlines the Person it points at in mentions' teal, and hovering her the Order in the lavender") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let (ann, order) = (ShapeID(), ShapeID())
        var person = note(ann, 1, 0)
        person[TitleProperty.self] = "Ann Lee"
        person[IsAProperty.self] = [TypeLink(FieldFixtures.personID)]
        var placed = note(order, 0, 0)
        placed[IsAProperty.self] = [TypeLink(FieldFixtures.orderID)]
        placed[FieldValuesProperty.self] = FieldValues(["customer": FieldLink(target: ann, stored: "Ann Lee").value])
        let types = [typeNote(FieldFixtures.person.schema, title: "Person", id: FieldFixtures.personID), typeNote(FieldFixtures.order.schema, title: "Order", id: FieldFixtures.orderID)]
        let h = try shipped(CanvasFile(root: CanvasDocument(shapes: [person, placed] + types)), pasteboard)
        let lights = try Lights(h.editor.registry)
        h.editor.hovered = order
        h.settleLights()
        expectEqual(h.lit, [Lit(lights.mentions, 0, [ann])])
        h.editor.hovered = ann
        h.settleLights()
        expectEqual(h.lit, [Lit(lights.mentionedBy, 0, [order])])
    },
])
