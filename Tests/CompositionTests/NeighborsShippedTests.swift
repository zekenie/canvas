import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import DetailPanel
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
// what it points to (arrows out of it, what a reference stands for), with ⌥ held what points to it
// (and what is of a type), and with ⌃⌥ what it mentions and what mentions it, each in its color, with a
// ring for each light shown a shape is in; the arrows between are in their light's color; a note in a
// subboard lights the subboard's card; and a reference's own arrows count with what it stands for.

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
/// two (Arrows': what a shape points to, what points to it), then mentions' two (Mentions': what
/// it mentions, what mentions it), then types' two (Types': what is of it, and the types built on it).
private struct Lights {
    let pointsTo, pointedToBy, mentions, mentionedBy, instances, subtypes: NSColor

    @MainActor init(_ registry: Registry) throws {
        let lights = registry.neighborLights
        let colors = try require(lights.count == 6 ? lights.map(\.color) : nil, "six lights, not \(lights.count)")
        (pointsTo, pointedToBy, mentions, mentionedBy, instances, subtypes) = (colors[0], colors[1], colors[2], colors[3], colors[4], colors[5])
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

/// On the root: the type T; A, a note that is a T; U, a type built on T; V, a note that is a U; P, a plain
/// note; and the subboard S, whose board holds G, a T too.
private struct Kinds {
    let t = ShapeID(), a = ShapeID(), u = ShapeID(), v = ShapeID(), p = ShapeID(), s = ShapeID(), g = ShapeID()

    var file: CanvasFile {
        func shape(_ id: ShapeID, _ column: Int, _ row: Int, type: Bool = false, is types: [ShapeID] = []) -> AnyShapeRecord {
            var record = ShapeRecord(id: id, StickyNote(frame: CGRect(x: column * 400, y: row * 400, width: 200, height: 200)))
            if type { record[TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter) }
            if !types.isEmpty { record[IsAProperty.self] = types.map(TypeLink.init) }
            return AnyShapeRecord(record)
        }
        let sub = ShapeRecord(id: s, Subboard(frame: CGRect(x: 1600, y: 0, width: 240, height: 160)))
        return CanvasFile(root: CanvasDocument(shapes: [
            shape(t, 0, 0, type: true), shape(a, 1, 0, is: [t]), shape(u, 0, 1, type: true, is: [t]), shape(v, 1, 1, is: [u]), shape(p, 2, 1),
            AnyShapeRecord(sub),
        ]), children: [s: CanvasDocument(shapes: [shape(g, 0, 0, is: [t])])])
    }
}

@MainActor let neighborsShippedTests = Suite("Neighbors, as shipped", [
    test("it follows the query plugins in the shipped list, and the plugins that own the edges give it six titled lights: arrows' green and purple, mentions' teal and lavender, then types' two in pink, and its panel's tab comes last") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let registry = try ShippedPlugins.registry(pasteboard: pasteboard, model: ScriptedLanguageModel())
        let plugins = ShippedPlugins.plugins(pasteboard: pasteboard, model: ScriptedLanguageModel()).map(\.id.rawValue)
        let neighbors = try require(plugins.firstIndex(of: PluginID.neighbors.rawValue))
        expect(try require(plugins.firstIndex(of: "queries")) < neighbors, "after the engine it asks")
        expect(try require(plugins.firstIndex(of: "query-commands")) < neighbors)
        // The lights are their owners' faces, each a plugin of its own: arrows' first, so a shape both pointed to and mentioned has its arrow's ring first. The panel's list of them is the last.
        let arrowLights = try require(plugins.firstIndex(of: PluginID.arrowLights.rawValue))
        let mentionLights = try require(plugins.firstIndex(of: PluginID.mentionLights.rawValue))
        let typeLights = try require(plugins.firstIndex(of: PluginID.typeLights.rawValue))
        let details = try require(plugins.firstIndex(of: PluginID.neighborDetails.rawValue))
        expect(neighbors < arrowLights && arrowLights < mentionLights && mentionLights < typeLights && typeLights < details,
               "Neighbors, then arrows' lights, then mentions', then types', then the tab that lists them")
        expect(registry.report.contains("neighbors"))
        let lights = registry.neighborLights
        expectEqual(lights.count, 6)
        expectEqual(lights.map(\.title), ["Points To", "Pointed To By", "Mentions", "Mentioned By", "Instances", "Subtypes"])
        // Each light asks for the shape named by its id, with the edge types' ids the plugins declare.
        let selector = "#\(ShapeID())"
        expectEqual(lights.map { $0.query(selector) }, [":edge-from(\(selector), arrow|stands-for), :end-of(\(selector), arrow)",
                                                       ":edge-to(\(selector), arrow|stands-for), :start-of(\(selector), arrow)",
                                                       ":edge-from(\(selector), mention)", ":edge-to(\(selector), mention)",
                                                       ":is-a(\(selector)[schema]):not([schema])", "[schema]:is-a(\(selector)[schema])"])
        // The arrows run between, lit and never listed; mentions and types have none.
        expectEqual(lights.map { $0.between?(selector) }, [":starts-at(\(selector), arrow)", ":ends-at(\(selector), arrow)", nil, nil, nil, nil])
        expectEqual(lights.map { $0.lit(selector) }, [":edge-from(\(selector), arrow|stands-for), :end-of(\(selector), arrow), :starts-at(\(selector), arrow)",
                                                     ":edge-to(\(selector), arrow|stands-for), :start-of(\(selector), arrow), :ends-at(\(selector), arrow)",
                                                     ":edge-from(\(selector), mention)", ":edge-to(\(selector), mention)",
                                                     ":is-a(\(selector)[schema]):not([schema])", "[schema]:is-a(\(selector)[schema])"])
        // What mentions a shape has its text around the mention under it; nothing else has a line.
        expectEqual(lights.map { $0.caption != nil }, [false, false, false, true, false, false])
        // A plain hover shows what it points to; ⌥ what points to it, as what is of a type does (its `is-a` runs to the type); ⌃⌥ its mentions.
        expectEqual(lights.map(\.keys), [[], .option, [.control, .option], [.control, .option], .option, .option])
    },
    test("a list without Neighbors leaves the lights out, and one with a light and no Neighbors is refused") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let all = ShippedPlugins.plugins(pasteboard: pasteboard, model: ScriptedLanguageModel())
        let faces: Set<PluginID> = [.neighbors, .arrowLights, .mentionLights, .typeLights, .neighborDetails]
        let without = try Registry(plugins: all.filter { !faces.contains($0.id) })
        expectEqual(without.neighborLights.count, 0)
        expectThrows(RegistryError.ownerNotInstalled(point: "NeighborLights", owner: .neighbors, contributor: .arrowLights)) {
            _ = try Registry(plugins: all.filter { $0.id != .neighbors })
        }
    },
    test("the tab that lists what the lights match is a plugin of its own: a list without it keeps the six lights and the hover, and the panels lose the Connections tab") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let all = ShippedPlugins.plugins(pasteboard: pasteboard, model: ScriptedLanguageModel())
        let without = try Registry(plugins: all.filter { $0.id != .neighborDetails })
        expectEqual(without.neighborLights.map(\.title), ["Points To", "Pointed To By", "Mentions", "Mentioned By", "Instances", "Subtypes"])
        let editor = CanvasEditor(registry: without, document: CanvasDocument(), scheduler: ManualScheduler())
        expect(editor.neighbors != nil, "the hover")
        expect(editor.neighborList == nil, "the list")
        let id = editor.add(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: "Milk"))
        expectEqual(try require(editor.detailPanel).layout(for: try require(editor.document[id])).tabs.map(\.title), ["Style"], "Colors' tab stays; the list's is gone")
        // And with it, a note has that tab, then Style.
        let shipped = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), pasteboard: pasteboard, model: ScriptedLanguageModel())
        let note = shipped.add(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: "Milk"))
        expectEqual(try require(shipped.detailPanel).layout(for: try require(shipped.document[note])).tabs.map(\.title), ["Connections", "Style"])
    },
    test("the colors are the design audit's, and types' pink beside them: one sRGB value each in the light and the dark, each at least 3:1 against the canvas it's drawn over") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let lights = try Lights(ShippedPlugins.registry(pasteboard: pasteboard, model: ScriptedLanguageModel()))
        let chosen: [(color: NSColor, light: [Int], dark: [Int])] = [
            (lights.pointsTo, [0x07, 0x93, 0x3B], [0x2F, 0xD3, 0x59]),
            (lights.pointedToBy, [0x8C, 0x21, 0xA4], [0xB8, 0x51, 0xFD]),
            (lights.mentions, [0x0E, 0x97, 0xB0], [0x32, 0x9A, 0xB4]),
            (lights.mentionedBy, [0xA7, 0x6F, 0xE2], [0xD0, 0xB0, 0xFE]),
            (lights.instances, [0xC2, 0x30, 0x7A], [0xF0, 0x7A, 0xB5]),
        ]
        // The canvas's own backgrounds (`Style.canvasBackground`): white 0.965 and 0.11.
        let (lightCanvas, darkCanvas) = ([246, 246, 246], [28, 28, 28])
        for (i, light) in chosen.enumerated() {
            expectEqual(srgb(light.color, in: .aqua), light.light, "light \(i) in the light appearance")
            expectEqual(srgb(light.color, in: .darkAqua), light.dark, "light \(i) in the dark")
            expect(contrast(light.light, lightCanvas) >= 3, "light \(i) on the light canvas: \(contrast(light.light, lightCanvas)):1")
            expect(contrast(light.dark, darkCanvas) >= 3, "light \(i) on the dark canvas: \(contrast(light.dark, darkCanvas)):1")
        }
        expectEqual(Set(chosen.map(\.light)).count, 5, "five colors")
        expectEqual(lights.subtypes, lights.instances, "a type built on it in the pink of what is of it: a shape is one or the other")
        expectEqual(Set(chosen.map(\.dark)).count, 5)
    },
    test("hovering a note outlines what it points to; with ⌥ what points to it; with ⌃⌥ what it mentions and what mentions it; the arrows between with them, each in its color") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let graph = Graph()
        let h = try shipped(graph.file, pasteboard)
        let lights = try Lights(h.editor.registry)
        expectEqual(h.lit, [])
        h.editor.hovered = graph.a
        h.settleLights()
        expectEqual(h.lit, [Lit(lights.pointsTo, 0, [graph.b, graph.c, graph.ab, graph.ac])])
        expectEqual(h.editor.outlines.faintShapes, [graph.a], "Selection's hover, on the shape itself")
        // B is pointed to by A and points to A: with ⌥ it's in the one light shown, so its first ring.
        h.hold(.option)
        h.wait(0)
        expectEqual(h.lit, [Lit(lights.pointedToBy, 0, [graph.d, graph.da, graph.ba, graph.b])])
        // G is on S's board: S is where it's drawn.
        h.hold([.control, .option])
        h.wait(0)
        expectEqual(h.lit, [Lit(lights.mentions, 0, [graph.f, graph.s]), Lit(lights.mentionedBy, 0, [graph.e])])
        h.editor.hovered = nil
        h.wait(0)
        expectEqual(h.lit, [])
        // E mentions A, and nothing else is connected to it.
        h.editor.hovered = graph.e
        h.settleLights()
        expectEqual(h.lit, [Lit(lights.mentions, 0, [graph.a])])
        h.hold([])
        h.wait(0)
        expectEqual(h.lit, [], "it points to nothing")
        // D has an arrow to A, and nothing else.
        h.editor.hovered = graph.d
        h.settleLights()
        expectEqual(h.lit, [Lit(lights.pointsTo, 0, [graph.a, graph.da])])
        // The subboard S is connected to nothing: A mentions the note on its board, not the card.
        for keys: Modifiers in [[], .option, [.control, .option]] {
            h.hold(keys)
            h.editor.hovered = graph.s
            h.settleLights()
            expectEqual(h.lit, [])
        }
    },
    test("a lit arrow is covered in its light's color, as wide as its line and a point more, so its own line doesn't stripe it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let graph = Graph()
        let h = try shipped(graph.file, pasteboard)
        let lights = try Lights(h.editor.registry)
        h.hold(.option)
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
    test("hovering an arrow outlines the shape it ends at as what it points to, and with ⌥ the shape it starts at as what points to it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let graph = Graph()
        let h = try shipped(graph.file, pasteboard)
        let lights = try Lights(h.editor.registry)
        /// What the arrow hovered lights plainly, then with ⌥, then let go.
        @MainActor func both() -> [[Lit]] {
            let plain = h.lit
            h.hold(.option)
            h.wait(0)
            defer {
                h.hold([])
                h.wait(0)
            }
            return [plain, h.lit]
        }
        h.editor.hovered = graph.ab
        h.settleLights()
        expectEqual(both(), [[Lit(lights.pointsTo, 0, [graph.b])], [Lit(lights.pointedToBy, 0, [graph.a])]])
        // A note-link is an arrow too: its type is under `arrow`.
        h.editor.hovered = graph.ac
        h.settleLights()
        expectEqual(both(), [[Lit(lights.pointsTo, 0, [graph.c])], [Lit(lights.pointedToBy, 0, [graph.a])]])
        // The arrow back from B to A: the other way round.
        h.editor.hovered = graph.ba
        h.settleLights()
        expectEqual(both(), [[Lit(lights.pointsTo, 0, [graph.a])], [Lit(lights.pointedToBy, 0, [graph.b])]])
        // Re-aimed at D while it's hovered: it ends there now, and undone, back (its edge changed, which the change lists by its ends).
        let toD = ArrowTerminal.bound(ArrowBinding(shapeID: graph.d, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
        h.editor.transact("Re-aim") { $0.update(graph.ba, as: Arrow.self) { $0.props.end = toD } }
        h.settleLights()
        expectEqual(both(), [[Lit(lights.pointsTo, 0, [graph.d])], [Lit(lights.pointedToBy, 0, [graph.b])]])
        h.editor.undo()
        h.settleLights()
        expectEqual(both(), [[Lit(lights.pointsTo, 0, [graph.a])], [Lit(lights.pointedToBy, 0, [graph.b])]])
    },
    test("hovering a type with ⌥ outlines what is of it in pink, however far: a note, what is of a type built on it and the subboard whose board holds one, and apart from them the type built on it; an instance hovered lights no type") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let kinds = Kinds()
        let h = try shipped(kinds.file, pasteboard)
        let lights = try Lights(h.editor.registry)
        h.editor.hovered = kinds.t
        h.settleLights()
        expectEqual(h.lit, [], "a plain hover shows what it points to: nothing")
        h.hold(.option)
        h.wait(0)
        expectEqual(h.lit, [Lit(lights.instances, 0, [kinds.a, kinds.v, kinds.s]), Lit(lights.subtypes, 0, [kinds.u])])
        // A note given the type while it's hovered is lit, and with the undo, not.
        h.editor.addTypeLink(kinds.t, to: kinds.p)
        h.settleLights()
        expectEqual(h.lit, [Lit(lights.instances, 0, [kinds.a, kinds.v, kinds.s, kinds.p]), Lit(lights.subtypes, 0, [kinds.u])])
        h.editor.undo()
        h.settleLights()
        expectEqual(h.lit, [Lit(lights.instances, 0, [kinds.a, kinds.v, kinds.s]), Lit(lights.subtypes, 0, [kinds.u])])
        // The type built on it lights what is of it alone, and nothing it builds on.
        h.editor.hovered = kinds.u
        h.settleLights()
        expectEqual(h.lit, [Lit(lights.instances, 0, [kinds.v])])
        // What a shape is isn't lit from it: its chips say that.
        h.editor.hovered = kinds.a
        h.settleLights()
        expectEqual(h.lit, [])
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
        expectEqual(h.lit, [Lit(lights.pointsTo, 0, [graph.b, graph.c, graph.ab, graph.ac])])
        contents.endHover(graph.a)
        h.wait(0)
        expectEqual(h.lit, [])
        // G is a row under S's, on a board the canvas doesn't show: the shape is hovered elsewhere, A mentions it (⌃⌥),
        // and S is where it is, which Selection outlines faintly. The keys reach it as they would with the list's keyboard.
        h.editor.modifiersChangedInWindow(held: [.control, .option])
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
        let public_ = note(target, 2, 0, "Orders")
        var props = Reference(frame: CGRect(x: 800, y: 600, width: Reference.defaultSize.width, height: Reference.defaultSize.height))
        ReferenceEdits.pick(&props, ReferenceTarget(id: target, label: "Orders"))
        let pill = AnyShapeRecord(ShapeRecord(id: r, props))
        let h = try shipped(CanvasFile(root: CanvasDocument(shapes: [public_, note(x, 0, 1, "Checkout"), pill, arrow(x, r).copy(as: into)])), pasteboard)
        let lights = try Lights(h.editor.registry)
        // The pill's arrow into it is, to the graph, an arrow into the note it stands for.
        h.hold(.option)
        h.editor.hovered = target
        h.settleLights()
        expectEqual(h.lit, [Lit(lights.pointedToBy, 0, [x, r, into])])
        // Checkout points to the note, as the graph reads it, and to the pill, as drawn.
        h.hold([])
        h.editor.hovered = x
        h.settleLights()
        expectEqual(h.lit, [Lit(lights.pointsTo, 0, [target, r, into])])
        // The pill stands for the note, and the arrow is into it as drawn.
        h.editor.hovered = r
        h.settleLights()
        expectEqual(h.lit, [Lit(lights.pointsTo, 0, [target])])
        h.hold(.option)
        h.wait(0)
        expectEqual(h.lit, [Lit(lights.pointedToBy, 0, [x, into])])
    },
    test("what's outlined is drawn: a note's first ring teal and its second lavender, 4 and 8 points off its edge, in the app's own editor") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        // A and B mention each other: with ⌃⌥ on A, B is in both lights shown, what A mentions and what mentions A.
        let a = ShapeID(), b = ShapeID()
        let file = CanvasFile(root: CanvasDocument(shapes: [note(a, 1, 1, MentionText([.mention(b, label: "B")])),
                                                            note(b, 2, 1, MentionText([.mention(a, label: "A")]))]))
        // No harness (which draws outlines on the shapes' edges): the app's editor stands them off by 4.
        let scheduler = ManualScheduler()
        let editor = CanvasEditor(registry: try ShippedPlugins.registry(pasteboard: pasteboard, model: ScriptedLanguageModel()), file: file,
                                  scheduler: scheduler)
        expectEqual(editor.outlineGap, 4, "what ships")
        let lights = try Lights(editor.registry)
        editor.camera = Camera(origin: CGPoint(x: -100, y: -100), zoom: 0.8)
        editor.modifiersChangedInWindow(held: [.control, .option])
        editor.hovered = a
        scheduler.advance(by: .zero)
        let neighbors = try require(editor.neighbors)
        spinRunLoop(until: { !neighbors.isAsking })
        let drawn = renderBitmap(editor, size: CGSize(width: 1200, height: 800))
        // B is the note at (800, 400), 200 × 200: on screen its right edge is at x = 880, and its middle at y = 480.
        let right = (800 + 200 + 100) * 0.8, middle = (400 + 100 + 100) * 0.8
        @MainActor func color(_ x: CGFloat) -> [Int] { pixel(drawn, at: CGPoint(x: right + x, y: middle)) }
        // The lights are drawn in the light appearance's values (`renderBitmap` is aqua), each line 2 points wide: 3 to 5 out and 7 to 9.
        @MainActor func ink(_ color: NSColor) -> [Int] { Array(swatch(color, in: .aqua).prefix(3)) }
        let first = ink(lights.mentions), second = ink(lights.mentionedBy)
        for x in [3.5, 4.5] { expectEqual(Array(color(x).prefix(3)), first, "ring 0, in the first light's teal, \(x) out") }
        for x in [7.5, 8.5] { expectEqual(Array(color(x).prefix(3)), second, "ring 1, in the second light's lavender, \(x) out") }
        // Where the line isn't, the canvas is the canvas's: between the rings, and past the second.
        for x in [5.5, 6.5, 10] { expect(color(x)[0] > 230 && color(x)[1] > 230, "the canvas, \(x) out: \(color(x))") }
    },
])
