import Adornments
import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import Connections
import Engineering
import Frames
import Geometry
import Keyboard
import Locking
import Mentions
import Publishing
import References
import Selection
import ShippedTesting
import StickyNotes
import Subboards
import TestKit
import Titles
import Types

// The census of what the pointer can do on a board with every shipped kind (keyboard navigation's P1, P2 and
// P10): every canvas button, handle and face the select tool finds over a shape is reached by the keys, and
// does what its click does; every item of a shape's context menu, of the canvas's and of a chip's menu is in
// the menu bar or has a key. What it finds open is the pending list's, each with the slice that closes it, so
// the suite stays green and honest; a new clickable thing that no key reaches fails here first.

/// The gaps the census knows of, each "<gap>, <slice id>": let through until the gap closes, then failed so the
/// entry goes. Empty: every click on the sample board has a key.
let reachPending: [String] = []

private let censusFields = #"{"type": "object", "properties": {"role": {"type": "string"}, "since": {"type": "string"}}}"#

/// A board with a shape of every shipped kind in a window, the first minute's types and notes among them (`Minute`):
/// two types with typed notes, a relationship type with fields, a relating arrow, a locked note, a private note that
/// mentions it, an arrow between those two, a reference standing for the locked note, a frame, a subboard, and the engineering kit's table, enum,
/// database and API, with the kit on so its ways in are swept too.
@MainActor
final class CensusBoard {
    let m: Minute
    private(set) var names: [ShapeID: String] = [:]
    var editor: CanvasEditor { m.editor }
    /// The board as the census starts every look from.
    private(set) var start = CanvasDocument()
    /// The tool and the zoom it starts with: a click or a key that only switches the tool or zooms is an effect too.
    private var startTool: ToolID?
    private var startZoom: CGFloat = 1
    /// What menus the canvas popped (a chip's, a pill's), last last.
    private(set) var popped: [NSMenu] = []
    let walk: KeyWalk

    /// `extra`: plugins after the shipped list.
    init(extra: [any CanvasPlugin] = []) throws {
        m = try Minute(extra: extra)
        let editor = m.editor
        m.window.setContentSize(CGSize(width: 2400, height: 1600))
        editor.viewportDidResize(to: CGSize(width: 2400, height: 1600))
        let made = try m.nameTheType()
        editor.transact("Fields") { $0.update(made) { $0[TypeSchemaProperty.self] = SchemaText(censusFields) } }
        try m.drag(from: m.featureNote, to: m.layerNote)
        editor.closeCard()
        editor.endEditing()
        var budget = ShapeRecord(StickyNote(frame: CGRect(x: 40, y: 900, width: 200, height: 200), text: MentionText(plain: "Budget for the year")))
        budget[TitleProperty.self] = "Budget"
        var ask = ShapeRecord(StickyNote(frame: CGRect(x: 400, y: 900, width: 200, height: 200),
                                         text: MentionText([.text("Ask "), .mention(budget.id, label: "Budget"), .text(" first")])))
        ask[TitleProperty.self] = "Ask"
        var reference = Reference(frame: CGRect(origin: CGPoint(x: 800, y: 950), size: Reference.defaultSize))
        ReferenceEdits.pick(&reference, ReferenceTarget(id: budget.id, label: "Budget"))
        let pill = ShapeRecord(reference)
        var frame = ShapeRecord(Frame(frame: CGRect(x: 1100, y: 860, width: 400, height: 300)))
        frame[TitleProperty.self] = "Plans"
        var subboard = ShapeRecord(Subboard(frame: CGRect(x: 1600, y: 900, width: 240, height: 160)))
        subboard[TitleProperty.self] = "Ship"
        var table = ShapeRecord(DatabaseTable(frame: CGRect(x: 2000, y: 900, width: 260, height: 92), columns: [
            Column(name: "id", type: TypeRef("uuid"), primaryKey: true), Column(name: "email", type: TypeRef("text"), unique: true),
            Column(name: "placed_at", type: TypeRef("timestamptz"), nullable: true)]))
        table[TitleProperty.self] = "orders"
        var values = ShapeRecord(DatabaseEnum(frame: CGRect(x: 2000, y: 1100, width: 220, height: 68),
                                              values: [EnumValue(text: "pending"), EnumValue(text: "paid")]))
        values[TitleProperty.self] = "order_status"
        var database = ShapeRecord(Database(frame: CGRect(x: 1600, y: 1250, width: 300, height: 200)))
        database[TitleProperty.self] = "shop"
        var api = ShapeRecord(API(frame: CGRect(x: 1960, y: 1460, width: 380, height: 102), server: APIServer(host: "api.shop.dev/v1", auth: "bearer"),
                                  endpoints: ["/orders", "POST /{id}/refunds (NewRefund) → 201 Refund"].compactMap { EndpointGrammar.read($0) }))
        api[TitleProperty.self] = "orders API"
        editor.turn(EngineeringKit.self, on: true)
        // A note of more types than its chips have room for: a "+N" chip.
        let account = editor.addTypeNote(#"{"type": "object", "properties": {}}"#, title: "Customer Account",
                                         frame: CGRect(x: 1900, y: 40, width: 200, height: 200))
        var gig = ShapeRecord(StickyNote(frame: CGRect(x: 1900, y: 500, width: 120, height: 120), text: ""))
        gig[IsAProperty.self] = [TypeLink(m.feature), TypeLink(m.layer), TypeLink(account)]
        gig[TitleProperty.self] = "The gig at the harbour on Friday"
        func bound(_ id: ShapeID) -> ArrowTerminal {
            .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
        }
        let arrow = ShapeRecord(Arrow(start: bound(ask.id), end: bound(budget.id), bend: 40))
        editor.transact("Census") { t in
            t.insert(budget)
            t.insert(ask)
            t.insert(pill)
            t.insert(frame)
            t.insert(subboard)
            t.insert(table)
            t.insert(values)
            t.insert(database)
            t.insert(api)
            t.insert(arrow)
            t.insert(gig)
        }
        editor.makePrivate([ask.id])
        editor.lock([budget.id])
        var names = [m.feature: "Feature", m.layer: "Layer", m.featureNote: "the Feature note", m.layerNote: "the Layer note", made: "in",
                 budget.id: "Budget", ask.id: "Ask", pill.id: "the reference", frame.id: "Plans", subboard.id: "Ship",
                     account: "Customer Account", gig.id: "Gig", table.id: "orders", values.id: "order_status",
                     database.id: "shop", api.id: "orders API"]
        for arrow in m.arrows {
            let from = arrow.props.start.binding.flatMap { names[$0.shapeID] } ?? "?", to = arrow.props.end.binding.flatMap { names[$0.shapeID] } ?? "?"
            names[arrow.id] = "the arrow from \(from) to \(to)"
        }
        self.names = names
        let editorRef = editor
        walk = KeyWalk(m.window, editor: editor, readers: [.canvas(m.canvas, editor: editor, names: names, part: { editorRef.focusedPart?.title })],
                       settle: .manual(m.h.scheduler))
        m.canvas.menuPresenter = { [weak self] menu, _, _ in self?.popped.append(menu) }
        editor.selectedShapeIDs = []
        editor.undoHistory.seal()
        settle()
        // Every key and click turns the run loop, which draws the whole 2400 x 1600 window; the census reads lookups and effects, never pixels,
        // so it is drawn in 8 bits of sRGB, not the screen's half-floats (a third of the time of the census).
        m.window.colorSpace = .sRGB
        m.window.depthLimit = .twentyfourBitRGB
        // And at a pixel a point, not the screen's two (a quarter of the pixels each turn's redraw blends).
        m.canvas.layer?.contentsScale = 1
        start = editor.document
        startTool = editor.currentToolID
        startZoom = editor.camera.zoom
    }

    func close() { m.close() }

    /// A key pressed as the keyboard sends it, routed as NSApplication routes it, and what it set off landed.
    func press(_ chord: Chord) {
        walk.driver.send(chord)
        settle()
    }

    /// "Budget (Note)": a shape as a census line names it.
    func name(_ id: ShapeID) -> String {
        let kind = editor.document[id].map { editor.registry.label(of: $0.kind).name } ?? "shape"
        return "\(names[id] ?? String(id.description.prefix(8))) (\(kind))"
    }

    /// What a key or a click set off, landed: the scheduler's actions due now, and a turn of the run loop (a menu
    /// the canvas pops on the next turn).
    func settle() {
        for _ in 0..<2 {
            m.h.scheduler.advance(by: .zero)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
            m.window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    /// Back to the board as it started, `shape` alone selected, nothing open or edited, the canvas with the keyboard.
    func reset(selecting shape: ShapeID?) {
        editor.closeCard()
        editor.endEditing()
        settle()
        if editor.board != .root { _ = editor.showBoard(.root) }
        editor.undoHistory.seal()
        var undone = 0
        while editor.document != start, editor.canUndo, undone < 6 {
            editor.undo()
            undone += 1
        }
        // A leftover change would make every later look's "changed nothing" wrong without any failure.
        expect(editor.document == start, "the census board isn't back as it started after \(undone) undos")
        if editor.currentToolID != startTool, let startTool { editor.setTool(startTool) }
        if editor.camera.zoom != startZoom { editor.camera.zoom = startZoom }
        editor.selectedShapeIDs = []
        if let shape { editor.selection = shape }
        m.window.makeFirstResponder(m.canvas)
        settle()
        popped = []
    }

    /// What has changed since the last `reset`, as a click's or a key's effect is compared.
    func effect() -> CensusEffect {
        settle()
        return CensusEffect(document: editor.document == start ? nil : editor.document, selection: editor.selectedShapeIDs.map(name),
                            editing: editor.editingShapeID.map(name), board: editor.board == .root ? nil : "\(editor.board)",
                            card: editor.card.map { "\($0.id)" }, menu: popped.last?.outline,
                            tool: editor.currentToolID == startTool ? nil : "\(editor.currentToolID)",
                            zoom: editor.camera.zoom == startZoom ? nil : editor.camera.zoom)
    }

    /// A plain click at a world point, as the person's: the pointer moved there, pressed and released.
    func click(at world: CGPoint) -> CensusEffect {
        let view = editor.camera.toView(world)
        m.h.move(to: view)
        m.h.click(at: view, clickCount: 1)
        return effect()
    }

    /// The selected shape's part `part`, reached with ⌥Tab and pressed with Return; nil when ⌥Tab never focuses it.
    func pressByKeys(_ part: ShapePart, of shape: ShapeID) -> CensusEffect? {
        guard reach(part, of: shape) else { return nil }
        press(.return)
        return effect()
    }

    /// ⌥Tab from the shape until its part `part` has the keyboard: whether it got there, at most once round. A ⌥Tab moves the focus
    /// at once and sets nothing off that a turn of the run loop lands (the run loop's turn is a redraw of the whole window, most of
    /// what the census costs), so the keys on the way land only what the scheduler has due, and the turn comes once, when the walk ends.
    func reach(_ part: ShapePart, of shape: ShapeID) -> Bool {
        let count = editor.shapeParts(of: shape).count
        defer { settle() }
        for _ in 0...count {
            walk.driver.send(.optionTab)
            m.h.scheduler.advance(by: .zero)
            if editor.focusedPart?.id == part.id { return true }
        }
        return false
    }
}

/// What a click or a key did, from the board as the census starts each look.
struct CensusEffect: Equatable, CustomStringConvertible {
    var document: CanvasDocument?
    var selection: [String]
    var editing: String?
    var board: String?
    var card: String?
    var menu: [String]?
    var tool: String?
    var zoom: CGFloat?

    var description: String {
        var said: [String] = []
        if document != nil { said.append("changed the board") }
        said.append("selected \(selection.isEmpty ? "nothing" : selection.joined(separator: ", "))")
        if let editing { said.append("edited \(editing)") }
        if let board { said.append("showed \(board)") }
        if let card { said.append("opened a card \(card)") }
        if let menu { said.append("popped \(menu)") }
        if let tool { said.append("switched to the \(tool) tool") }
        if let zoom { said.append("zoomed to \(zoom)") }
        return said.joined(separator: "; ")
    }
}

/// One thing the select tool presses over a shape before the shape itself: a canvas button, a handle or a face,
/// where it was found (world units).
struct PointerThing {
    enum Kind: String { case button, handle, face }
    let kind: Kind
    let identity: AnyHashable
    /// The shape it is on.
    let owner: ShapeID
    var points: [CGPoint] = []

    /// The point found nearest the middle of all of them: on it, whatever its shape.
    var point: CGPoint {
        let middle = CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count), y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
        return points.min { $0.distance(to: middle) < $1.distance(to: middle) } ?? middle
    }
}

/// What the census says of a shape's things: the gaps ("Type chip "+2" on Budget (Note): no part or command") and
/// each thing reached, with how.
struct CensusReport {
    var gaps: [String] = []
    var reached: [String] = []
}

extension CensusBoard {
    /// The pointer's things over `shape` selected alone: swept every `CensusStyle.step` world units over the shape and its parts, each
    /// found once (a face that knows its point, once per what it is), port dots left out (⌘L is their keyboard twin).
    func things(over shape: ShapeID) -> [PointerThing] {
        reset(selecting: shape)
        guard var area = editor.shapeContext.bounds(of: [shape]) else { return [] }
        for part in editor.shapeParts(of: shape) { area = area.union(part.rect) }
        area = area.insetBy(dx: -CensusStyle.reach, dy: -CensusStyle.reach)
        var found: [String: PointerThing] = [:], order: [String] = []
        func note(_ kind: PointerThing.Kind, _ identity: AnyHashable, owner: ShapeID, at point: CGPoint) {
            guard owner == shape else { return }
            let key = "\(kind) \(Self.stable(identity))"
            if found[key] == nil {
                found[key] = PointerThing(kind: kind, identity: identity, owner: owner)
                order.append(key)
            }
            found[key]?.points.append(point)
        }
        var y = area.minY
        while y <= area.maxY {
            var x = area.minX
            while x <= area.maxX {
                let world = CGPoint(x: x, y: y), view = editor.camera.toView(world)
                if let button = editor.button(atViewPoint: view) {
                    if !(button.base is PortDot) {
                        let owner = (button.base as? AdornmentButton)?.shape ?? editor.selectableShape(at: world) ?? shape
                        note(.button, button, owner: owner, at: world)
                    }
                } else if let handle = editor.handle(atViewPoint: view) {
                    note(.handle, handle, owner: shape, at: world)
                } else if let face = editor.face(atViewPoint: view) {
                    note(.face, face.face, owner: face.shape, at: world)
                }
                x += CensusStyle.step
            }
            y += CensusStyle.step
        }
        return order.compactMap { found[$0] }
    }

    /// An identity less what changes from point to point of one thing (a face that keeps where it was found).
    static func stable(_ identity: AnyHashable) -> String {
        var text = "\(identity.base)"
        for marker in [", at: (", ", center: (", ", point: ("] {
            while let range = text.range(of: marker), let close = text[range.upperBound...].firstIndex(of: ")") {
                text.removeSubrange(range.lowerBound...close)
            }
        }
        return text
    }

    /// What a census line calls a thing: an adornment by its type and label ("TypeChip “in”"), else its type.
    func label(of thing: PointerThing) -> String {
        if let button = thing.identity.base as? AdornmentButton {
            let label = editor.adornmentFrames(of: button.shape)
                .first { $0.adornment == button.adornment && $0.tag == button.tag && $0.isOverflow == button.isOverflow }?.label.text
            return "\(button.adornment.name.split(separator: ".").last ?? "")" + (label.map { " “\($0)”" } ?? "")
        }
        return "\(type(of: thing.identity.base))"
    }

    /// Each pointer thing over each shape (or those of `only`), held to its key: a handle is a part the arrows move; any other thing is
    /// a part that ⌥Tab reaches and Return presses to the same effect as its click, or its click only selects the
    /// shape (Tab's), or edits it (Return's, whose editing Tab walks).
    func census(of only: Set<ShapeID>? = nil) -> CensusReport {
        var report = CensusReport()
        for record in start.shapes where only?.contains(record.id) ?? true {
            let shape = record.id
            for thing in things(over: shape) {
                let line = "\(label(of: thing)) \(thing.kind) on \(name(shape))"
                reset(selecting: shape)
                let parts = editor.shapeParts(of: shape)
                let at = thing.point
                let part = parts.first { $0.id == thing.identity }
                    ?? parts.filter { $0.rect.insetBy(dx: -1, dy: -1).contains(at) }.min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
                if thing.kind == .handle {
                    guard let part, part.role == .handle, part.adjust != nil else {
                        report.gaps.append("\(line): no handle part the arrows move")
                        continue
                    }
                    guard reach(part, of: shape) else {
                        report.gaps.append("\(line): ⌥Tab never reaches “\(part.title)”")
                        continue
                    }
                    // A handle moves as its drag does, along the ways it can: an arrow's bend across the line only.
                    let revision = editor.revision
                    press(.right)
                    if editor.revision == revision { press(.down) }
                    if editor.revision == revision { report.gaps.append("\(line): the arrows move nothing on “\(part.title)”") } else {
                        report.reached.append("\(line): “\(part.title)”, moved by the arrows")
                    }
                    continue
                }
                // What the board is after a reset, before the click (a reset leaves it the same each time).
                let unchanged = effect()
                let clicked = click(at: at)
                if clicked == unchanged {
                    report.reached.append("\(line): a click only selects the shape, which Tab does")
                    continue
                }
                if clicked.editing == name(shape), clicked.card == nil, clicked.menu == nil {
                    reset(selecting: shape)
                    press(.return)
                    if effect().editing == name(shape) {
                        report.reached.append("\(line): a click edits the shape, which Return does")
                        continue
                    }
                }
                if let part {
                    reset(selecting: shape)
                    guard let pressed = pressByKeys(part, of: shape) else {
                        report.gaps.append("\(line): ⌥Tab never reaches “\(part.title)”")
                        continue
                    }
                    if pressed == clicked { report.reached.append("\(line): “\(part.title)”, Return") } else {
                        report.gaps.append("\(line): Return on “\(part.title)” \(pressed), a click \(clicked)")
                    }
                    continue
                }
                if let keys = inEditing(shape, doing: clicked) {
                    report.reached.append("\(line): \(keys)")
                    continue
                }
                report.gaps.append("\(line): no part or command (a click \(clicked))")
            }
        }
        reset(selecting: nil)
        return report
    }
}

extension CensusBoard {
    /// The keys that do what `clicked` did from inside the shape's editing: Return, Tab to a stop of its own, → along
    /// its line, Return ("Return, Tab ×2, → ×1, Return": a note's row, its first pill followed). Nil when no stop does,
    /// or the shape isn't edited. (Where a stop is drawn can't guide it: a note being edited is laid out apart.)
    func inEditing(_ shape: ShapeID, doing clicked: CensusEffect) -> String? {
        for tabs in 0..<CensusStyle.editingStops {
            for rights in 0...CensusStyle.lineStops {
                reset(selecting: shape)
                press(.return)
                guard editor.editingShapeID == shape else { return nil }
                for _ in 0..<tabs { press(.tab) }
                for _ in 0..<rights { press(.right) }
                guard editor.editingShapeID == shape else { break }
                press(.return)
                if effect() == clicked { return "Return, Tab ×\(tabs), → ×\(rights), Return" }
            }
        }
        return nil
    }
}

/// The census's sweep.
private enum CensusStyle {
    /// How many stops of a shape's editing the census tries (a note's words and rows).
    static let editingStops = 8
    /// How many stops along a line of the shape's editing the census tries (a row's pills).
    static let lineStops = 2
    /// How far round a shape the sweep looks, world units: its chips and pills, its handles.
    static let reach: CGFloat = 48
    /// The sweep's step, world units: finer than the smallest thing (a handle, hit within 12 points of its middle; a chip, 18 tall).
    static let step: CGFloat = 8
}

// MARK: Menus

extension CensusBoard {
    /// Every title of `outline`, indented or not, without its marks: "Is a ▸" is "Is a", "(Make Private)" "Make Private".
    static func titles(_ outline: [String]) -> [String] {
        outline.compactMap { line in
            var title = line.trimmingCharacters(in: .whitespaces)
            guard title != "—" else { return nil }
            if title.hasPrefix("("), title.hasSuffix(")") { title = String(title.dropFirst().dropLast()) }
            for mark in ["✓ ", "– "] where title.hasPrefix(mark) { title = String(title.dropFirst(mark.count)) }
            if title.hasSuffix(" ▸") { title = String(title.dropLast(2)) }
            return title
        }
    }

    /// The point nearest the middle of a shape's bounds where a click presses the shape itself (on an arrow's line).
    func point(on shape: ShapeID) -> CGPoint? {
        guard let bounds = editor.shapeContext.bounds(of: [shape]) else { return nil }
        let middle = CGPoint(x: bounds.midX, y: bounds.midY)
        var best: CGPoint?
        var y = bounds.minY
        while y <= bounds.maxY {
            var x = bounds.minX
            while x <= bounds.maxX {
                let point = CGPoint(x: x, y: y)
                if editor.selectableShape(at: point) == shape, best.map({ point.distance(to: middle) < $0.distance(to: middle) }) ?? true { best = point }
                x += CensusStyle.step
            }
            y += CensusStyle.step
        }
        return best
    }

    /// The menu bar as the app makes it, the Shape menu filled for the selection now.
    func menuBar() -> NSMenu {
        let menus = BoardMenus.make(appName: "Infinite Canvas", registry: editor.registry, editor: { [editor] in editor })
        if let shape = menus.main.item(withTitle: "Shape")?.submenu { shape.delegate?.menuNeedsUpdate?(shape) }
        return menus.main
    }

    /// What can be done from the menu bar and the keys now, by title: every item of the menu bar; every item of the
    /// selection's menu whose command a menu bar item runs (the Shape menu leaves those out: Open is Go › Open
    /// Selection); every shortcut's.
    func reachableTitles() -> Set<String> {
        let bar = menuBar()
        var commands = Set<CanvasCommand>()
        func collect(_ menu: NSMenu) {
            for item in menu.items {
                if let command = BoardMenus.command(of: item) { commands.insert(command) }
                if let submenu = item.submenu { collect(submenu) }
            }
        }
        collect(bar)
        let all = Set(Self.titles(editor.menuForSelection(omitting: [])?.outline ?? []))
        let left = Set(Self.titles(editor.menuForSelection(omitting: commands)?.outline ?? []))
        return Set(Self.titles(bar.outline)).union(all.subtracting(left)).union(editor.registry.keyboardHelpRows.map(\.title))
    }

    /// The Shape menu's items that do something, each by its path of titles ("Is a", "Feature").
    func shapeMenuLeaves() -> [[String]] {
        guard let shape = menuBar().item(withTitle: "Shape")?.submenu else { return [] }
        func leaves(_ menu: NSMenu, _ path: [String]) -> [[String]] {
            menu.items.flatMap { item -> [[String]] in
                if item.isSeparatorItem || !item.isEnabled { return [] }
                if let submenu = item.submenu { return leaves(submenu, path + [item.title]) }
                return [path + [item.title]]
            }
        }
        return leaves(shape, [])
    }

    /// Runs the item at `path` of `menu`, as choosing it does.
    func choose(_ path: [String], in menu: NSMenu) {
        _ = NSApplication.shared
        var menu = menu
        for (depth, title) in path.enumerated() {
            let index = menu.indexOfItem(withTitle: title)
            guard index >= 0, let item = menu.item(at: index) else { return }
            if depth == path.count - 1 { menu.performActionForItem(at: index) } else if let submenu = item.submenu { menu = submenu }
        }
    }

    /// The Shape menu item that does what `item` of the menu `pops` pops does on `shape`, by the effect of each:
    /// its path ("Is a ▸ Feature"), or nil when none does.
    func shapeMenuTwin(of item: String, poppedBy pops: ShapePart, on shape: ShapeID) -> String? {
        reset(selecting: shape)
        guard pressByKeys(pops, of: shape) != nil, let menu = popped.last else { return nil }
        popped = []
        choose([item], in: menu)
        let chosen = effect()
        reset(selecting: shape)
        guard chosen != effect() else { return nil }
        for path in shapeMenuLeaves() {
            reset(selecting: shape)
            let bar = menuBar()
            guard let shapeMenu = bar.item(withTitle: "Shape")?.submenu else { return nil }
            choose(path, in: shapeMenu)
            if effect() == chosen { return path.joined(separator: " ▸ ") }
        }
        return nil
    }

    /// Every item of each shape's context menu, the canvas's, and each chip's or pill's menu (Return on a part that
    /// pops one), held to the menu bar and the keys (P10): by title, else, for a chip's item, by a Shape menu item
    /// with the same effect.
    func menuCensus() -> CensusReport {
        var report = CensusReport()
        for record in start.shapes {
            let shape = record.id
            reset(selecting: shape)
            let reachable = reachableTitles()
            if let on = point(on: shape), let menu = m.h.secondaryClick(at: editor.camera.toView(on)) {
                let what = "the context menu of \(name(shape))"
                let lines = Self.titles(menu.outline).filter { !reachable.contains($0) }.map { "“\($0)” in \(what): in no menu bar menu and no key" }
                report.gaps += lines
                if lines.isEmpty { report.reached.append(what) }
            }
            for part in editor.shapeParts(of: shape) where part.role == .menuButton {
                reset(selecting: shape)
                let reachable = reachableTitles()
                guard pressByKeys(part, of: shape) != nil, let menu = popped.last else { continue }
                let what = "the menu of “\(part.title)” on \(name(shape))"
                var clean = true
                for title in Self.titles(menu.outline) where !reachable.contains(title) {
                    if let twin = shapeMenuTwin(of: title, poppedBy: part, on: shape) {
                        report.reached.append("“\(title)” in \(what): Shape ▸ \(twin)")
                    } else {
                        clean = false
                        report.gaps.append("“\(title)” in \(what): in no menu bar menu and no key")
                    }
                }
                if clean { report.reached.append(what) }
            }
        }
        reset(selecting: nil)
        let reachable = reachableTitles()
        if let menu = m.h.secondaryClick(at: editor.camera.toView(CGPoint(x: 2200, y: 1400))) {
            report.gaps += Self.titles(menu.outline).filter { !reachable.contains($0) }.map { "“\($0)” in the canvas's context menu: in no menu bar menu and no key" }
            report.reached.append("the canvas's context menu")
        }
        reset(selecting: nil)
        return report
    }
}

/// What the planted face is (`PlantedFacePlugin`).
private struct PlantedFace: Hashable, Sendable {
    let shape: ShapeID
}

/// A face in the bottom right corner of every note whose click names the note "Planted", with no part and no key: what
/// the census exists to catch.
private struct PlantedFacePlugin: CanvasPlugin {
    var id: PluginID { "planted-face" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.shapeFaces(at: { (_: CanvasEditor, shape: AnyShapeRecord, point: CGPoint) -> PlantedFace? in
            guard shape.kind == StickyNote.kind, let box = shape.box, CGRect(x: box.maxX - 40, y: box.maxY - 40, width: 32, height: 32).contains(point) else { return nil }
            return PlantedFace(shape: shape.id)
        }, click: { (face: PlantedFace, editor: CanvasEditor) in editor.transact("Plant") { $0.update(face.shape) { $0[TitleProperty.self] = "Planted" } } })
    }
}

@MainActor let reachCensusTests = Suite("Reach census", [
    test("the census board holds a shape of every shipped kind") {
        let b = try CensusBoard()
        defer { b.close() }
        let kinds = Set(b.editor.document.shapes.map(\.kind))
        for kind in b.editor.registry.kinds { expect(kinds.contains(kind), "no \(kind) on the census board") }
    },
    test("every button, handle and face the pointer presses on the board is a part ⌥Tab reaches and Return presses to the click's effect, or the click only selects or edits (P1, P2)") {
        let b = try CensusBoard()
        defer { b.close() }
        let report = b.census()
        b.walk.pending = reachPending.filter { !$0.hasPrefix("“") }
        b.walk.expectGaps(report.gaps)
        // What the board holds to be a census of: each of these found and reached.
        for thing in ["LockChip button", "PrivateChip", "TypeChips “+", "RelationshipPill", "GoButton button", "MentionFace face",
                      "DefinitionFace face", "RowFace face", "ResizeHandle handle", "ArrowHandle handle"] {
            expect(report.reached.contains { $0.hasPrefix(thing) }, "the census found no \(thing): \(report.reached)")
        }
        if ProcessInfo.processInfo.environment["CENSUS"] == "1" { print(report.reached.joined(separator: "\n")) }
    },
    test("a face with no part and no key is a gap the census names, as an actionable line") {
        let b = try CensusBoard(extra: [PlantedFacePlugin()])
        defer { b.close() }
        let ask = try require(b.names.first { $0.value == "Ask" }?.key)
        let report = b.census(of: [ask])
        let planted = report.gaps.filter { $0.hasPrefix("PlantedFace face on Ask (Note): no part or command") }
        expectEqual(planted.count, 1, "\(report.gaps)")
        expect(planted.first?.contains("changed the board") == true, "it says what the click did: \(planted)")
        // Pending, it passes; pending with no gap, the entry fails.
        b.walk.pending = planted.map { "\($0), reach-census" }
        b.walk.expectGaps(report.gaps)
    },
    test("the issue walk's band, its count, its list and a warning line's “9 of 63” each have a menu item or a key (P1, P2, P10), with nothing pending") {
        let b = try CensusBoard()
        defer { b.close() }
        // The band's ‹, › and Done are the commands of Previous Issue, Next Issue and End Issue Walk, its count and the list
        // Issue List, and the list's Ignore Issue: items of the menu bar (Go), the first four with keys.
        let reachable = b.reachableTitles()
        for title in ["Previous Issue", "Next Issue", "Issue List", "Ignore Issue", "End Issue Walk"] {
            expect(reachable.contains(title), "\(title) is in no menu bar menu: \(reachable.sorted())")
        }
        let keyed = Set(b.editor.registry.keyboardHelpRows.map(\.title))
        for title in ["Previous Issue", "Next Issue", "Issue List", "Ignore Issue"] { expect(keyed.contains(title), "\(title) has no key in the Keyboard Shortcuts window") }
        expect(!keyed.contains("End Issue Walk"), "End Issue Walk has no key: its item is in the menu bar (Done's twin)")
        // A flagged listing's warning line says “1 of 4”, which begins the rule's walk: its menu way is Walk Flagged ▸, in the
        // selection's menu (so the Shape menu), beside Ignore Rule ▸.
        let scene = try ListWalk(boards: false)
        scene.editor.selection = scene.mustang
        scene.w.window.settle()
        let menu = (scene.editor.menuForSelection(omitting: [])?.outline ?? []).joined(separator: "\n")
        expect(menu.contains("Walk Flagged ▸"), "the shape's menu: \(menu)")
        expect(menu.contains("Ignore Rule ▸"), "and Ignore Rule beside it: \(menu)")
        expect(reachPending.isEmpty, "the census has no pending entry: \(reachPending)")
    },
    test("every item of a shape's, a chip's and the canvas's menu is in the menu bar or has a key (P10)") {
        let b = try CensusBoard()
        defer { b.close() }
        let report = b.menuCensus()
        b.walk.pending = reachPending.filter { $0.hasPrefix("“") }
        b.walk.expectGaps(report.gaps)
        expect(report.reached.contains { $0.hasPrefix("the menu of") }, "a chip's menu was checked: \(report.reached)")
        if ProcessInfo.processInfo.environment["CENSUS"] == "1" { print(report.reached.joined(separator: "\n")) }
    },
])
