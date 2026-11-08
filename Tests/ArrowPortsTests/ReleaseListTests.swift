import Adornments
import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import DetailPanel
import Draw
import Mentions
import Selection
import TestKit
import Titles
import Types

// One release list (Connections' `ConnectionMade`), with real arrows and real presses: a connection drawn on a titled channel
// that two or more titled channels fit is drawn plain and they're offered, each the pill a pick would put on the line, a rule, a
// gray Plain arrow, the first highlighted; a pick is its own step, "Change Relation", so one Undo returns to the plain arrow and a
// second removes it. One titled channel is taken silently, an untitled one (a subboard's link, here a crate's hook) never asks,
// and Types' relationship types are offered in the same list after the channels', a rule between.

private enum Feeds {}
extension Feeds: Channel {
    static let id: ChannelID = "feeds"
    static var title: String? { "feeds" }
    static var color: NSColor { NSColor(srgbRed: 0.75, green: 0.18, blue: 0.45, alpha: 1) }
}

private enum Drains {}
extension Drains: Channel {
    static let id: ChannelID = "drains"
    static var title: String? { "drains" }
    static var color: NSColor { NSColor(srgbRed: 0.15, green: 0.5, blue: 0.25, alpha: 1) }
}

private enum Hooks {}
extension Hooks: Channel {
    static let id: ChannelID = "hooks"
}

/// A box open to every channel after its own untitled one, as a subboard is.
private struct Crate: BoxShapeProps {
    static let kind: ShapeKind = "crate"
    static let properties = Properties<Crate> { Property("frame", \.frame).required() }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
    init() { self.init(.zero) }
}

@MainActor private struct CrateDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Crate>, in context: RenderContext) {}
}

/// A note as far as Types knows (a type, an instance), whose ports are the two titled channels: a release between two of them
/// offers both channels and the relationship types that fit.
private struct Plank: BoxShapeProps {
    static let kind: ShapeKind = "plank"
    static let properties = Properties<Plank>(title: "Plank") {
        Property("frame", \.frame).required()
        Property("text", \.text)
    }
    var frame: CGRect
    var text: MentionText
    init(_ frame: CGRect, text: MentionText = "") {
        self.frame = frame
        self.text = text
    }
    init() { self.init(.zero) }
}

@MainActor private struct PlankDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Plank>, in context: RenderContext) {}
}

/// Boxes A and B take feeds and drains; disc C takes feeds alone; crates E and F their hook, then every channel.
@MainActor private struct ReleaseBoard {
    let h: EditorHarness
    let a: ShapeID, b: ShapeID, c: ShapeID, e: ShapeID, f: ShapeID

    static let crateE = CGRect(x: 80, y: 700, width: 200, height: 200)
    static let crateF = CGRect(x: 460, y: 700, width: 200, height: 200)

    static var plugins: [any CanvasPlugin] {
        let titled = Contributor(id: "titled-channels") { registrar in
            registrar.channel(Feeds.self)
            registrar.channel(Drains.self)
            registrar.channel(Hooks.self)
            registrar.shape(CrateDefinition())
            registrar.shape(PlankDefinition()) { plank in
                plank.mentionable(untitled: { $0.props.text.firstLine })
                plank.typeWords(\.text, drawnIn: { _ in nil })
                plank.canBeType()
                plank.canBeRelationshipType()
                plank.typeable()
            }
            registrar.title(Plank.self)
            registrar.ports(Box.self, on: Feeds.self)
            registrar.ports(Box.self, on: Drains.self)
            registrar.ports(Disc.self, on: Feeds.self)
            registrar.ports(Crate.self, on: Hooks.self)
            registrar.portsOnEveryChannel(Crate.self)
            registrar.ports(Plank.self, on: Feeds.self)
            registrar.ports(Plank.self, on: Drains.self)
        }
        return PortBoard.plugins(more: [titled, ConnectionPillsPlugin(), DetailPanelPlugin(), DrawPlugin(), PortEdgesPlugin()]).filter { $0.id != "channels" }
    }

    init() throws {
        _ = NSApplication.shared
        h = try EditorHarness(plugins: Self.plugins)
        h.editor.viewportDidResize(to: CGSize(width: 1400, height: 1400))
        a = h.add(Box(boxA))
        b = h.add(Box(boxB))
        c = h.add(Disc(discC))
        e = h.add(Crate(Self.crateE))
        f = h.add(Crate(Self.crateF))
        h.editor.undoHistory.seal()
    }

    var arrows: [ShapeRecord<Arrow>] { h.editor.document.shapes.compactMap { $0.typed(as: Arrow.self) } }

    /// A port's drag from the right side of `frame` to `point`, hovering first, released.
    func drag(from frame: CGRect, to point: CGPoint) {
        h.move(to: CGPoint(x: frame.midX, y: frame.midY))
        h.move(to: CGPoint(x: frame.maxX + 12, y: frame.midY))
        h.press()
        h.drag(to: point, speed: fast)
        h.release()
    }

    func rows(_ menu: NSMenu) -> [String] { menu.items.map { $0.isSeparatorItem ? "" : $0.title } }
}

private func middle(_ frame: CGRect) -> CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

@MainActor let releaseListTests = Suite("One release list", [
    test("several titled channels fit: the arrow is drawn plain, and the list offers each as its pill, a rule, a gray Plain arrow, the first highlighted, the arrow selected") {
        let w = try ReleaseBoard()
        w.drag(from: boxA, to: middle(boxB))
        let arrow = try require(w.arrows.last)
        expectEqual(arrow[ChannelProperty.self], nil, "plain until a pick")
        expectEqual(w.h.editor.undoHistory.undoName, "Add Arrow")
        let (menu, _) = try require(w.h.editor.menuToPopUp)
        expectEqual(w.rows(menu), ["feeds", "drains", "", "Plain arrow"])
        expect(w.h.editor.menuItemToHighlight === menu.items.first, "the first highlighted, so Return takes it")
        expectEqual(w.h.editor.selectedShapeIDs, [arrow.id])
        expect(menu.items[0].image != nil && menu.items[1].image != nil, "each row is the pill it would put on the line")
        expectEqual(menu.items[0].image?.accessibilityDescription, "feeds")
        let plain = try require(menu.items.last)
        expectEqual(plain.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .secondaryLabelColor)
    },
    test("a pick is its own step, Change Relation: one Undo returns to the plain arrow, a second removes it") {
        let w = try ReleaseBoard()
        let start = w.h.editor.document
        w.drag(from: boxA, to: middle(boxB))
        let arrow = try require(w.arrows.last).id
        let (menu, _) = try require(w.h.editor.menuToPopUp)
        menu.performActionForItem(at: 1)
        expectEqual(w.h.editor.document[arrow]?[ChannelProperty.self], Drains.id)
        expectEqual(w.h.editor.undoHistory.undoName, ConnectionsStyle.changeRelation)
        expectEqual(w.h.editor.registry.channelTitle(Drains.id), "drains")
        w.h.editor.undo()
        expect(w.h.editor.document[arrow] != nil, "the arrow stays")
        expectEqual(w.h.editor.document[arrow]?[ChannelProperty.self], nil, "plain again")
        expectEqual(w.h.editor.undoHistory.undoName, "Add Arrow")
        w.h.editor.undo()
        expectEqual(w.h.editor.document, start, "and gone")
    },
    test("Plain arrow, a press elsewhere, and a stale pick change nothing") {
        let w = try ReleaseBoard()
        w.drag(from: boxA, to: middle(boxB))
        let arrow = try require(w.arrows.last).id
        let menu = try require(w.h.editor.menuToPopUp).menu
        let drawn = w.h.editor.document
        menu.performActionForItem(at: menu.items.count - 1)
        expectEqual(w.h.editor.document, drawn, "Plain arrow")
        expectEqual(w.h.editor.undoHistory.undoName, "Add Arrow")
        // A press elsewhere before the host pops it drops it (Escape, once it's up, is AppKit's, and picks nothing).
        w.h.move(to: CGPoint(x: 1000, y: 1200))
        w.h.press()
        w.h.release()
        expect(w.h.editor.menuToPopUp == nil, "a press drops the list")
        expectEqual(w.h.editor.document[arrow]?[ChannelProperty.self], nil)
        // Put on a channel some other way since: the pick is stale.
        w.h.editor.setChannel(Feeds.id, of: arrow)
        let fed = w.h.editor.document
        menu.performActionForItem(at: 1)
        expectEqual(w.h.editor.document, fed, "given a relation in the meantime")
        // Deleted: nothing happens.
        w.h.editor.transact("Delete") { $0.delete([arrow]) }
        let gone = w.h.editor.document
        menu.performActionForItem(at: 0)
        expectEqual(w.h.editor.document, gone, "deleted in the meantime")
    },
    test("a pick an end doesn't take refuses with the shake and no step") {
        let w = try ReleaseBoard()
        w.drag(from: boxA, to: middle(boxB))
        let arrow = try require(w.arrows.last).id
        // Re-aimed onto the disc while the list was open: drains, which it doesn't take, is refused.
        w.h.editor.transact("Move Arrow End") { transaction in
            transaction.update(arrow, as: Arrow.self) { $0.props.end = binding(w.c) }
        }
        let before = w.h.editor.document
        let menu = try require(w.h.editor.menuToPopUp).menu
        menu.performActionForItem(at: 1)
        expectEqual(w.h.editor.document, before, "nothing written")
        expect(w.h.editor.service(RefusalShake.self)?.isShaking == true, "the arrow and its ends shake")
        expectEqual(w.h.editor.undoHistory.undoName, "Move Arrow End")
        // Feeds it takes.
        menu.performActionForItem(at: 0)
        expectEqual(w.h.editor.document[arrow]?[ChannelProperty.self], Feeds.id)
    },
    test("one titled channel fits: it's the arrow's at once, in the press's step, and nothing asks") {
        let w = try ReleaseBoard()
        w.drag(from: boxA, to: middle(discC))
        let arrow = try require(w.arrows.last)
        expectEqual(arrow[ChannelProperty.self], Feeds.id)
        expect(w.h.editor.menuToPopUp == nil, "no list")
        expectEqual(w.h.editor.undoHistory.undoName, "Add Arrow")
        expectEqual(w.h.editor.adornmentFrames(of: arrow.id).map(\.label.text), ["feeds"], "its pill on the line")
    },
    test("a crate to a crate (a subboard to a subboard) is drawn on its own untitled channel and never asks, though both take the titled ones") {
        let w = try ReleaseBoard()
        w.drag(from: ReleaseBoard.crateE, to: middle(ReleaseBoard.crateF))
        let arrow = try require(w.arrows.last)
        expectEqual(arrow[ChannelProperty.self], Hooks.id)
        expect(w.h.editor.menuToPopUp == nil)
        expectEqual(w.h.editor.adornmentFrames(of: arrow.id).map(\.label.text), [], "an untitled channel has no pill")
    },
    test("Types' relationship types are offered in the same list, after the channels', a rule between; a pick of one is Add Type") {
        let w = try ReleaseBoard()
        func plank(_ frame: CGRect, title: String, schema: Bool = false, relationship: Bool = false, of types: [ShapeID] = []) -> AnyShapeRecord {
            var record = ShapeRecord(Plank(frame))
            record[TitleProperty.self] = title
            if schema { record[TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter) }
            if relationship { record[RelationshipProperty.self] = true }
            if !types.isEmpty { record[IsAProperty.self] = types.map(TypeLink.init) }
            return AnyShapeRecord(record)
        }
        let person = plank(CGRect(x: 900, y: 80, width: 200, height: 200), title: "Person", schema: true)
        let company = plank(CGRect(x: 900, y: 400, width: 200, height: 200), title: "Company", schema: true)
        let employment = plank(CGRect(x: 1200, y: 80, width: 200, height: 200), title: "Employment", schema: true, relationship: true)
        let mentorship = plank(CGRect(x: 1200, y: 400, width: 200, height: 200), title: "Mentorship", schema: true, relationship: true)
        let annFrame = CGRect(x: 80, y: 1000, width: 200, height: 200), acmeFrame = CGRect(x: 460, y: 1000, width: 200, height: 200)
        let ann = plank(annFrame, title: "Ann", of: [person.id]), acme = plank(acmeFrame, title: "Acme", of: [company.id])
        w.h.editor.transact { transaction in
            for record in [person, company, employment, mentorship, ann, acme] { transaction.insert(record) }
            for type in [employment.id, mentorship.id] {
                transaction.insert(AnyShapeRecord(ShapeRecord(Arrow(start: binding(person.id), end: binding(type)))))
                transaction.insert(AnyShapeRecord(ShapeRecord(Arrow(start: binding(type), end: binding(company.id)))))
            }
        }
        w.h.editor.undoHistory.seal()
        w.drag(from: annFrame, to: middle(acmeFrame))
        let arrow = try require(w.arrows.last).id
        let (menu, _) = try require(w.h.editor.menuToPopUp)
        expectEqual(w.rows(menu), ["feeds", "drains", "", "Employment", "Mentorship", "", "Plain arrow"])
        expectEqual(w.h.editor.document[arrow]?[ChannelProperty.self], nil)
        menu.performActionForItem(at: 4)
        expectEqual(w.h.editor.document[arrow]?[IsAProperty.self]?.map(\.shape), [mentorship.id])
        expectEqual(w.h.editor.undoHistory.undoName, "Add Type")
        w.h.editor.undo()
        expectEqual(w.h.editor.document[arrow]?[IsAProperty.self]?.map(\.shape) ?? [], [])
        expectEqual(w.h.editor.undoHistory.undoName, "Add Arrow")
    },
    test("Connect (⌘L) on two shapes gives the release a drag gives: the same list, the arrow plain, in the Connect step") {
        let w = try ReleaseBoard()
        w.h.editor.connect([w.a, w.b])
        let arrow = try require(w.arrows.last)
        expectEqual(arrow[ChannelProperty.self], nil)
        expectEqual(w.h.editor.undoHistory.undoName, "Connect")
        let (menu, _) = try require(w.h.editor.menuToPopUp)
        expectEqual(w.rows(menu), ["feeds", "drains", "", "Plain arrow"])
        menu.performActionForItem(at: 0)
        expectEqual(w.h.editor.undoHistory.undoName, ConnectionsStyle.changeRelation)
    },
])
