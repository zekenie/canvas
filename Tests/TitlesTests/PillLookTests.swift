import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import TestKit
import Titles

// A plugin gives the pill of the shapes that hold its property a look (`titlePillLook`): its symbol,
// its tint, what an untitled one says, the surface its cover is drawn on, no pill at all. Fixtures
// only: a property, `Starred`, that plaques opt into, and a lozenge that gives its own look.

enum Starred {}

extension Starred: ShapeProperty {
    public static let key: PropertyKey = "starred"
    public static var defaultValue: Bool? { nil }
}

/// Plaques hold `Starred`.
let starPlugin = Contributor(id: "stars") {
    $0.declare(Starred.self)
    $0.optIn(Plaque.self, to: Starred.self)
}

let lookTint = AdornmentTint(NSColor(srgbRed: 0.1, green: 0.4, blue: 0.9, alpha: 1), style: .solid)

/// A look for starred plaques, from `look`, counting how many times it is asked and of which kinds.
@MainActor var looksAsked: [ShapeKind] = []
func looks(id: PluginID = "looks", _ look: @escaping @MainActor (AnyShapeRecord, String?) -> TitlePillLook?) -> Contributor {
    Contributor(id: id) { registrar in
        registrar.titlePillLook(forShapesHolding: Starred.self) { shape, title in
            looksAsked.append(shape.kind)
            return look(shape, title)
        }
    }
}

/// The look of a starred shape: a symbol, a tint, a placeholder.
let starLook: @MainActor (AnyShapeRecord, String?) -> TitlePillLook? = { shape, _ in
    shape[Starred.self] == true ? TitlePillLook(symbol: "star.fill", tint: lookTint, placeholder: "Unnamed") : nil
}

extension CanvasEditor {
    func star(_ id: ShapeID, _ on: Bool? = true) { transact { $0.update(id) { $0[Starred.self] = on } } }
    @discardableResult
    func add(_ lozenge: Lozenge, named name: String? = nil) -> ShapeID {
        var shape = ShapeRecord(lozenge)
        shape[TitleProperty.self] = name
        transact { $0.insert(shape) }
        return shape.id
    }
    /// A shape's title pill, if it shows one.
    func pill(_ id: ShapeID) -> AdornmentLabel? { adornmentFrames(of: id).first { $0.adornment == .of(TitlePill.self) }?.label }
}

/// A kind of its own that gives its own pills a look: tinted, with a symbol, and a placeholder.
struct Lozenge: BoxShapeProps {
    static let kind: ShapeKind = "lozenge"
    static let properties = Properties<Lozenge> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
}

extension Lozenge {
    init() { self.init(.zero) }
}

struct LozengeDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Lozenge>, in context: RenderContext) {}
}

struct LozengesPlugin: CanvasPlugin {
    var id: PluginID { "lozenges" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(LozengeDefinition()) { lozenge in
            lozenge.title()
            lozenge.titlePillLook { _, title in TitlePillLook(symbol: "diamond", tint: lookTint, placeholder: title == nil ? "Lozenge" : nil) }
        }
    }
}

@MainActor let pillLookTests = Suite("Pill looks", [
    test("a concern's look is asked of the shapes of the kinds that hold its property, and of no other kind's") {
        looksAsked = []
        let editor = try titleEditor([starPlugin, looks(starLook), LozengesPlugin(), CardsPlugin(), CardTitlesPlugin()])
        editor.add(Plaque(plaqueFrame), named: "Lobby")
        editor.add(Card(CGRect(x: 300, y: 100, width: 80, height: 60), text: "Desk"))
        editor.add(Lozenge(CGRect(x: 20, y: 20, width: 80, height: 60)), named: "Gem")
        _ = editor.adornmentFrames(of: editor.document.shapes[0].id)
        for shape in editor.document.shapes { _ = editor.adornmentFrames(of: shape.id) }
        expect(!looksAsked.isEmpty)
        expectEqual(Set(looksAsked), ["plaque"], "the plaque holds Starred; the card and the lozenge don't")
    },
    test("it is asked only for kinds that show a pill, and only where the pill is made, not at each draw") {
        looksAsked = []
        let editor = try titleEditor([starPlugin, looks(starLook), Contributor(id: "pill-less") { $0.title(Disc.self, pill: false) }])
        editor.add(Disc(CGRect(x: 20, y: 20, width: 80, height: 60)))
        let plaque = editor.add(Plaque(plaqueFrame), named: "Lobby")
        _ = render(editor)
        expectEqual(Set(looksAsked), ["plaque"])
        let asked = looksAsked.count
        _ = render(editor)
        _ = render(editor)
        expectEqual(looksAsked.count, asked, "the pill is kept")
        editor.star(plaque)
        _ = render(editor)
        expect(looksAsked.count > asked, "and made again when a commit names the shape")
    },
    test("a list with a look and no Titles is refused by the registry, naming the point") {
        expectThrows(RegistryError.ownerNotInstalled(point: "TitlePillLooks", owner: .titles, contributor: "looks")) {
            _ = try Registry(plugins: [Contributor(id: "stars") { $0.declare(Starred.self) }, looks(starLook)])
        }
    },
    test("the symbol and the tint show in the pill, and it is the plain pill on a shape the look says nothing of") {
        let editor = try titleEditor([starPlugin, looks(starLook)])
        let starred = editor.add(Plaque(plaqueFrame), named: "Lobby")
        let plain = editor.add(Plaque(CGRect(x: 300, y: 100, width: 80, height: 60)), named: "Hall")
        editor.star(starred)
        let pill = try require(editor.pill(starred))
        expectEqual(pill.text, "Lobby")
        expectEqual(pill.systemImage, "star.fill")
        expectEqual(pill.tint, lookTint)
        let bare = try require(editor.pill(plain))
        expectEqual(bare, AdornmentLabel("Hall"))
        let rect = editor.camera.toView(try require(editor.adornmentFrames(of: starred).first?.rect))
        let fill = pixel(render(editor), at: CGPoint(x: rect.minX + 3, y: rect.midY))
        expect(zip(fill, [26, 102, 230]).allSatisfy { abs($0 - $1) <= 4 }, "in the tint's color: \(fill)")
        editor.star(starred, nil)
        expectEqual(editor.pill(starred), AdornmentLabel("Lobby"), "as it was once the shape doesn't hold it")
    },
    test("an untitled shape with a placeholder shows a dimmed pill, and with none, as before, none") {
        let editor = try titleEditor([starPlugin, looks(starLook)])
        let id = editor.add(Plaque(plaqueFrame))
        expectEqual(editor.pill(id), nil)
        editor.star(id)
        let pill = try require(editor.pill(id))
        expectEqual(pill.text, "Unnamed")
        expectEqual(pill.isPlaceholder, true)
        expectEqual(pill.tint, lookTint)
        expectEqual(editor.title(id), nil, "never a title")
        let quiet = try titleEditor([starPlugin, looks { shape, _ in shape[Starred.self] == true ? TitlePillLook(symbol: "star.fill") : nil }])
        let other = quiet.add(Plaque(plaqueFrame))
        quiet.star(other)
        expectEqual(quiet.pill(other), nil, "no placeholder, no pill")
    },
    test("hidesPill removes the pill, the cover aside") {
        let editor = try titleEditor([starPlugin, looks { _, _ in TitlePillLook(hidesPill: true) }])
        let id = editor.add(Plaque(plaqueFrame), named: "Lobby")
        editor.star(id)
        expectEqual(editor.pill(id), nil)
    },
    test("fields merge in plugin order: the first non-nil of each, hidesPill if any") {
        let first = looks(id: "first") { shape, _ in shape[Starred.self] == true ? TitlePillLook(symbol: "one") : nil }
        let second = looks(id: "second") { shape, _ in shape[Starred.self] == true ? TitlePillLook(symbol: "two", tint: lookTint) : nil }
        let editor = try titleEditor([starPlugin, first, second])
        let id = editor.add(Plaque(plaqueFrame), named: "Lobby")
        editor.star(id)
        let pill = try require(editor.pill(id))
        expectEqual(pill.systemImage, "one")
        expectEqual(pill.tint, lookTint)
        let hiding = try titleEditor([starPlugin, first, looks(id: "hider") { _, _ in TitlePillLook(hidesPill: true) }])
        let hidden = hiding.add(Plaque(plaqueFrame), named: "Lobby")
        hiding.star(hidden)
        expectEqual(hiding.pill(hidden), nil)
    },
    test("a kind's own look is asked of its shapes alone") {
        let editor = try titleEditor([LozengesPlugin()])
        let gem = editor.add(Lozenge(CGRect(x: 20, y: 20, width: 80, height: 60)), named: "Gem")
        let blank = editor.add(Lozenge(CGRect(x: 120, y: 20, width: 80, height: 60)))
        let plaque = editor.add(Plaque(plaqueFrame), named: "Lobby")
        expectEqual(editor.pill(gem)?.systemImage, "diamond")
        expectEqual(editor.pill(gem)?.tint, lookTint)
        expectEqual(editor.pill(blank)?.text, "Lozenge")
        expectEqual(editor.pill(plaque), AdornmentLabel("Lobby"))
    },
    test("the cover's surface is per shape, and its ink follows the surface's luminance") {
        let dark = NSColor(white: 0.1, alpha: 1), light = NSColor(white: 0.95, alpha: 1)
        @MainActor func cover(on surface: NSColor?) throws -> NSBitmapImageRep {
            let editor = try titleEditor([starPlugin, looks { shape, _ in shape[Starred.self] == true ? TitlePillLook(coverSurface: surface) : nil }])
            editor.camera = Camera(origin: .zero, zoom: 0.3)
            let id = editor.add(Plaque(world(plaqueFrame, atZoom: 0.3)), named: "Front desk")
            editor.star(id)
            return render(editor)
        }
        let onDark = try cover(on: dark), onLight = try cover(on: light)
        let text = CGRect(x: 100, y: 130, width: 120, height: 50)
        expect(inkPixels(onDark, in: text, dark: false) > inkPixels(onLight, in: text, dark: false), "a light ink on a dark surface")
        expect(inkPixels(onLight, in: text, dark: true) > inkPixels(onDark, in: text, dark: true), "a dark ink on a light one")
        // Two plaques of one kind, one starred.
        let editor = try titleEditor([starPlugin, looks { shape, _ in shape[Starred.self] == true ? TitlePillLook(coverSurface: dark) : nil }])
        editor.camera = Camera(origin: .zero, zoom: 0.3)
        let plain = editor.add(Plaque(world(CGRect(x: 20, y: 100, width: 140, height: 90), atZoom: 0.3)), named: "Plain")
        let starred = editor.add(Plaque(world(CGRect(x: 220, y: 100, width: 140, height: 90), atZoom: 0.3)), named: "Starred")
        editor.star(starred)
        let both = render(editor)
        let left = CGRect(x: 20, y: 100, width: 140, height: 90), right = CGRect(x: 220, y: 100, width: 140, height: 90)
        expect(inkPixels(both, in: left, dark: true) > inkPixels(both, in: left, dark: false), "the plain one's ink is dark")
        expect(inkPixels(both, in: right, dark: false) > inkPixels(both, in: right, dark: true), "the starred one's is light")
        _ = (plain, starred)
    },
    test("the registry's report has the point's line") {
        let registry = try titleEditor([starPlugin, looks(starLook), LozengesPlugin()]).registry
        expect(registry.report.contains("title pill look → every shape"), registry.report)
        expect(registry.report.contains("title pill look → lozenge"), registry.report)
    },
    test("a tinted pill is laid out where a plain one is, above the shape, so it is the shape's to point at") {
        let editor = try titleEditor([starPlugin, looks(starLook)])
        let id = editor.add(Plaque(plaqueFrame), named: "Lobby")
        let plain = try require(editor.adornmentFrames(of: id).first?.rect)
        editor.star(id)
        let tinted = try require(editor.adornmentFrames(of: id).first)
        expectEqual(editor.adornmentFrames(of: id).count, 1)
        expectEqual(tinted.adornment, .of(TitlePill.self))
        expect(tinted.rect.maxY <= plaqueFrame.minY && tinted.rect.minX == plain.minX, "above the shape's top-left corner: \(tinted.rect)")
    },
])
