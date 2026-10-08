import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import ContextMenus
import DetailPanel
import Connections
import Foundation
import Geometry
import Keyboard
import Mentions
import Publishing
import Queries
import References
import Selection
import SlashCommands
import TableOfContents
import TestKit
import TextEditing
import Titles
import Topology
import Validation

// The shipped Reference over CanvasTesting's boxes and tiles as what it stands for (named by a
// title, mentionable, public by choice, as the shipped kinds are) and its links as the arrows that
// run into it (a wire each carries): so every test here shows References knows no real kind.

enum WireEdge: EdgeType {
    static let id: EdgeTypeID = "wire"
}

/// What a reference can stand for: boxes and tiles, named by their titles and mentionable (a box
/// "Box", a tile "Tile" while untitled), and the wire a link carries between what it joins.
struct TargetsPlugin: CanvasPlugin {
    var id: PluginID { "targets" }

    func register(into registrar: inout PluginRegistrar) {
        registrar.edgeType(WireEdge.self)
        registrar.edges(CanvasTesting.Link.self) { record, _, sink in
            guard let link = record.props as? CanvasTesting.Link, let from = link.from, let to = link.to else { return }
            sink.emit(WireEdge.id, from: from, to: to)
        }
        registrar.title(Box.self)
        registrar.mentionable(Box.self, untitled: { _ in "A box" }, symbol: { _ in "shippingbox" }, tint: { _ in .systemOrange })
        registrar.title(Tile.self)
        registrar.mentionable(Tile.self, symbol: { _ in "square.on.square" }, tint: { _ in .systemPurple })
    }
}

/// Queries name shapes by their titles, as the shipped lexicon names them by Titles'.
let targetNames = Contributor(id: "target-names") { registrar in
    registrar.queryNames(attribute: TitleProperty.key.rawValue,
                         source: { kind, registry in registry.properties(for: kind).contains(TitleProperty.key) ? .named : .none },
                         named: { TitleProperty.folded($0[TitleProperty.self]) },
                         derived: { _, _ in nil },
                         fold: { TitleProperty.folded($0) })
}

/// The plugins a reference builds on and shows itself on: the keys, the selection, the graph, the
/// context menu, the panel, adornments, ports (the pill has ports on every channel), slash commands,
/// validation (its rule on a query that can't be read), titles, mentions, publishing, the query engine
/// (what a dynamic reference asks; `queries: false` leaves it out); References before the table of
/// contents, so it hears each commit first; then `more`.
@MainActor func referencePlugins(_ more: [any CanvasPlugin] = [], queries: Bool = true, names: (any CanvasPlugin)? = targetNames) -> [any CanvasPlugin] {
    [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FixturesPlugin(), TilesPlugin(), LinksPlugin(), ContextMenusPlugin(),
     DetailPanelPlugin(), AdornmentsPlugin(), PortsPlugin(), SlashCommandsPlugin(), ValidationPlugin(), TitlesPlugin(), MentionsPlugin(), PublishingPlugin(),
     TargetsPlugin()] + (queries ? [QueriesPlugin()] + (names.map { [$0] } ?? []) : []) + [ReferencesPlugin(), TableOfContentsPlugin()] + more
}

/// An empty board of `referencePlugins`, its view 1000 × 800 at 100%, where view points are world units.
@MainActor func referenceHarness(_ more: [any CanvasPlugin] = [], file: CanvasFile = CanvasFile(), queries: Bool = true,
                                  names: (any CanvasPlugin)? = targetNames) throws -> EditorHarness {
    let h = try EditorHarness(plugins: referencePlugins(more, queries: queries, names: names), file: file)
    h.editor.viewportDidResize(to: CGSize(width: 1000, height: 800))
    return h
}

/// Titles for the kind that owns a board (CanvasTesting's pocket), so a board has a name to say.
let pocketTitles = Contributor(id: "pocket-titles") { $0.title(Pocket.self, pill: false, contents: false) }

/// Where most tests put what a reference stands for, and the reference.
let boxFrame = CGRect(x: 100, y: 100, width: 150, height: 100)
let pillOrigin = CGPoint(x: 400, y: 300)

extension EditorHarness {
    /// A box titled `title`, public if `isPublic`: a transaction of its own.
    @discardableResult
    func addBox(_ title: String? = nil, public isPublic: Bool = true, at frame: CGRect = boxFrame, id: ShapeID = ShapeID()) -> ShapeID {
        var box = ShapeRecord(id: id, Box(frame))
        box[TitleProperty.self] = title
        if isPublic { box[PublicProperty.self] = true }
        editor.transact { $0.insert(box) }
        return id
    }

    /// A tile titled `title`, public if `isPublic`.
    @discardableResult
    func addTile(_ title: String? = nil, public isPublic: Bool = true, at frame: CGRect = CGRect(x: 100, y: 400, width: 120, height: 80)) -> ShapeID {
        var tile = ShapeRecord(Tile(frame))
        tile[TitleProperty.self] = title
        if isPublic { tile[PublicProperty.self] = true }
        editor.transact { $0.insert(tile) }
        return tile.id
    }

    /// A reference standing for `target`, called `label` (what picking it from the list would have
    /// stored), fitted to it, at `origin` (the pill's top left).
    @discardableResult
    func addReference(to target: ShapeID, label: String, at origin: CGPoint = pillOrigin) -> ShapeID {
        var props = Reference(frame: CGRect(origin: origin, size: Reference.defaultSize))
        ReferenceEdits.pick(&props, ReferenceTarget(id: target, label: label))
        return add(props)
    }

    /// A reference to words, interpreted into `query` if given.
    @discardableResult
    func addReference(words: String, query: String? = nil, all: Bool = false, at origin: CGPoint = pillOrigin) -> ShapeID {
        var props = Reference(frame: CGRect(origin: origin, size: Reference.defaultSize), all: all)
        ReferenceEdits.find(&props, words: words, query: query)
        return add(props)
    }

    /// An empty reference, as placed.
    @discardableResult
    func addEmptyReference(at origin: CGPoint = pillOrigin) -> ShapeID {
        add(Reference(frame: CGRect(origin: origin, size: Reference.defaultSize)))
    }

    /// A link from `from` to `to`, whose wire is an edge between them.
    @discardableResult
    func connect(_ from: ShapeID, _ to: ShapeID) -> ShapeID {
        add(CanvasTesting.Link(from: from, to: to))
    }

    /// The reference's props.
    func reference(_ id: ShapeID) -> Reference? { editor.document[id]?.typed(as: Reference.self)?.props }

    /// What the reference stands for now.
    func state(of id: ShapeID) -> ReferenceCondition? { editor.references?.state(of: id) }

    /// A reference that finds what `query` matches, the first or `all`.
    @discardableResult
    func addReference(query: String, all: Bool = false, at origin: CGPoint = pillOrigin) -> ShapeID {
        addReference(words: "", query: query, all: all, at: origin)
    }

    /// Lets answers come: the scheduler's clock moves `ms` (a hop at 0, the wait for quiet at 250),
    /// then the main run loop turns until no batch is out, its answers landed. Fails the test if a
    /// wait is still armed then.
    func answer(after ms: Int = 0, file: StaticString = #fileID, line: UInt = #line) {
        wait(ms)
        guard let state = editor.references else { return }
        _ = spinRunLoop(until: { !state.isFinding }, file: file, line: line)
    }

    /// The shapes the reference stands for now, as Topology forwards to them.
    func standsFor(_ id: ShapeID) -> [ShapeID] { editor.topology?.forwards(of: id) ?? [] }

    /// How the reference's query was answered.
    func status(_ id: ShapeID) -> ReferenceStatus? { editor.references?.status(of: id) }
}

extension CanvasEditor {
    /// The shapes a wire joins from `id`, as the graph reads them.
    func wired(from id: ShapeID, view: EdgeView = .resolved) -> [ShapeID] {
        topology?.edges(of: id, .outgoing, types: .only(WireEdge.id), view: view).map(\.target) ?? []
    }
}

/// The canvas, `size` view points, drawn as `renderBitmap` draws it (`scale` device pixels to a
/// point), in the light appearance or the dark.
@MainActor func render(_ editor: CanvasEditor, size: CGSize = CGSize(width: 800, height: 600), dark: Bool = false, scale: CGFloat = 1) -> NSBitmapImageRep {
    guard dark else { return renderBitmap(editor, size: size, scale: scale) }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    cg.scaleBy(x: scale, y: scale)
    cg.translateBy(x: 0, y: size.height)
    cg.scaleBy(x: 1, y: -1)
    NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        let bounds = CGRect(origin: .zero, size: size)
        editor.draw(in: cg, bounds: bounds, dirtyRect: bounds)
        NSGraphicsContext.restoreGraphicsState()
    }
    return rep
}

@MainActor func expectColor(_ actual: [Int], _ expected: [Int], _ what: String, within tolerance: Int = 3,
                            file: StaticString = #fileID, line: UInt = #line) {
    expect(zip(actual, expected).allSatisfy { abs($0 - $1) <= tolerance }, "\(what): \(actual) is not about \(expected)", file: file, line: line)
}

/// The editing view of the pill being edited, in an unshown window with the keyboard, laid over its
/// editing frame as the canvas lays it, so keys, the list under it and what's typed are as they are
/// on the canvas. `layout()` lays it again after what a key wrote changed the pill.
@MainActor
final class Field {
    let h: EditorHarness
    let id: ShapeID
    let editing: EditingView
    let window: NSWindow
    let textView: EditingTextView

    init(_ h: EditorHarness, editing id: ShapeID) throws {
        self.h = h
        self.id = id
        expectEqual(h.editor.editingShapeID, id, "the pill is being edited")
        editing = try require(h.editor.makeEditingView())
        window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 1000, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = FieldHost(frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        window.contentView?.addSubview(editing.view)
        textView = try require(editing.firstResponder as? EditingTextView)
        layout()
        window.makeFirstResponder(textView)
    }

    /// Lays the view over the pill where the canvas has it.
    func layout() {
        guard let box = h.editor.editingFrame else { return }
        editing.view.frame = h.editor.camera.toView(box)
        editing.view.bounds = CGRect(origin: .zero, size: box.size)
    }

    var list: CaretListWindow? { textView.caretListWindow }
    var rows: [CaretListRow] { list?.list.rows ?? [] }
    /// The titles of the list's items, in order.
    var titles: [String] { rows.compactMap { $0.item?.title } }

    func type(_ text: String) {
        for character in text {
            window.press(String(character))
            layout()
        }
    }

    func press(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        window.press(characters, code: code, modifiers: modifiers)
        layout()
    }

    func down() { press("\u{F701}", code: 125, modifiers: [.numericPad, .function]) }
    func up() { press("\u{F700}", code: 126, modifiers: [.numericPad, .function]) }
    func tab() { press("\t", code: 48) }
    func returnKey(_ modifiers: NSEvent.ModifierFlags = []) { press("\r", code: 36, modifiers: modifiers) }
    func escape() { press("\u{1b}", code: 53) }

    func close() {
        list?.dismiss()
        window.contentView = nil
    }
}

private final class FieldHost: NSView {
    override var isFlipped: Bool { true }
}

extension EditorHarness {
    /// Places a pill with the Reference tool at `point` (R, then a click) and gives the field the keyboard.
    func placeReference(at point: CGPoint = CGPoint(x: 300, y: 300)) throws -> Field {
        expect(key("r"), "R is the Reference tool's key")
        press(at: point)
        release()
        return try Field(self, editing: try require(editor.editingShapeID, "editing begins at once"))
    }

    /// Edits the pill, as Return does, and gives the field the keyboard.
    func editReference(_ id: ShapeID) throws -> Field {
        editor.selectedShapeIDs = [id]
        expect(key("\r"), "Return edits it")
        return try Field(self, editing: id)
    }
}
