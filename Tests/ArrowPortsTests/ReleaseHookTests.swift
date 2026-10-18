import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import DetailPanel
import Draw
import Geometry
import Mentions
import Selection
import TableOfContents
import TestKit
import Titles
import Types

// What a port's release makes of the arrow it drew, with real arrows and a real press: Connections tells Types the
// arrow is finished (`ArrowConnecting.finished`), in the press, after the transaction that completed it and before the
// press's step closes; so the one type that fits is part of "Add Arrow", and the drag between two types is the step
// "New Relationship Type". A drag that passes over a relationship type counts as no end until the release, whichever
// way it ends.

/// A box of words that can be a type, be given one, and be placed by a tool: a note, as far as Types knows.
struct Slab: BoxShapeProps {
    static let kind: ShapeKind = "slab"
    static let properties = Properties<Slab>(title: "Slab") {
        Property("frame", \.frame).required()
        Property("text", \.text)
    }
    var frame: CGRect
    var text: MentionText
    init(_ frame: CGRect = CGRect(x: 0, y: 0, width: 200, height: 200), text: MentionText = "") {
        self.frame = frame
        self.text = text
    }
    init() { self.init(CGRect(x: 0, y: 0, width: 200, height: 200)) }
}

@MainActor struct SlabDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Slab>, in context: RenderContext) {}
}

struct SlabsPlugin: CanvasPlugin {
    var id: PluginID { "slabs" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(SlabDefinition()) { slab in
            slab.tool(label: "Slab", systemImage: "note.text", placing: slab.placement(size: CGSize(width: 200, height: 200)) { Slab() })
            slab.mentionable(untitled: { $0.props.text.firstLine })
            slab.typeWords(\.text, drawnIn: { _ in nil })
            slab.canBeType()
            slab.canBeRelationshipType()
            slab.typeable()
        }
        registrar.title(Slab.self)
        registrar.ports(Slab.self, on: Wire.self)
    }
}

/// Person and Company types, a relationship type Employment with an end to each, a Person note and a Company note, at known
/// places on a board where a port's drag can be made.
@MainActor private struct Release {
    let h: EditorHarness
    let person: ShapeID, company: ShapeID, employment: ShapeID, ann: ShapeID, acme: ShapeID

    static let annFrame = CGRect(x: 80, y: 80, width: 200, height: 200)
    static let acmeFrame = CGRect(x: 460, y: 80, width: 200, height: 200)
    static let personFrame = CGRect(x: 80, y: 700, width: 200, height: 200)
    static let companyFrame = CGRect(x: 900, y: 700, width: 200, height: 200)
    static let employmentFrame = CGRect(x: 460, y: 1000, width: 200, height: 200)

    init(ends: Bool = true) throws {
        h = try EditorHarness(plugins: PortBoard.plugins(more: [DetailPanelPlugin(), DrawPlugin(), PortEdgesPlugin(), SlabsPlugin()]))
        h.editor.viewportDidResize(to: CGSize(width: 1400, height: 1400))
        func slab(_ frame: CGRect, title: String? = nil, schema: String? = nil, relationship: Bool = false, of types: [ShapeID] = []) -> AnyShapeRecord {
            var record = ShapeRecord(Slab(frame))
            if let title { record[TitleProperty.self] = title }
            if let schema { record[TypeSchemaProperty.self] = SchemaText(schema) }
            if relationship { record[RelationshipProperty.self] = true }
            if !types.isEmpty { record[IsAProperty.self] = types.map(TypeLink.init) }
            return AnyShapeRecord(record)
        }
        let people = slab(Self.personFrame, title: "Person", schema: TypeSchemaProperty.starter)
        let companies = slab(Self.companyFrame, title: "Company", schema: TypeSchemaProperty.starter)
        let employments = slab(Self.employmentFrame, title: "Employment", schema: TypeSchemaProperty.starter, relationship: true)
        let ann = slab(Self.annFrame, title: "Ann", of: [people.id]), acme = slab(Self.acmeFrame, title: "Acme", of: [companies.id])
        h.editor.transact { transaction in
            for record in [people, companies, employments, ann, acme] { transaction.insert(record) }
        }
        (person, company, employment, self.ann, self.acme) = (people.id, companies.id, employments.id, ann.id, acme.id)
        if ends {
            h.editor.transact { transaction in
                transaction.insert(AnyShapeRecord(ShapeRecord(Arrow(start: binding(people.id), end: binding(employments.id)))))
                transaction.insert(AnyShapeRecord(ShapeRecord(Arrow(start: binding(employments.id), end: binding(companies.id)))))
            }
        }
        h.editor.undoHistory.seal()
        h.editor.replaceDocument(with: h.editor.document)
    }

    var arrows: [ShapeRecord<Arrow>] { h.editor.document.shapes.compactMap { $0.typed(as: Arrow.self) } }

    /// A port's drag from the right side of `frame` to `point`, hovering first; released unless told not to.
    func drag(from frame: CGRect, to point: CGPoint, release: Bool = true) {
        h.move(to: CGPoint(x: frame.midX, y: frame.midY))
        h.move(to: CGPoint(x: frame.maxX + 12, y: frame.midY))
        h.press()
        h.drag(to: point, speed: fast)
        if release { h.release() }
    }

    func center(_ frame: CGRect) -> CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
}

@MainActor let releaseHookTests = Suite("The release of a port's drag, in the press", [
    test("one type fits: the arrow takes it in the press, so it is still the step Add Arrow and one Undo takes back the arrow and its type together; no list opens") {
        let w = try Release()
        let start = w.h.editor.document
        w.drag(from: Release.annFrame, to: w.center(Release.acmeFrame))
        let drawn = try require(w.arrows.last { w.h.editor.relationships?.end($0.id) == nil })
        expectEqual(drawn[IsAProperty.self]?.map(\.shape), [w.employment])
        expectEqual(w.h.editor.undoHistory.undoName, "Add Arrow")
        expect(w.h.editor.menuToPopUp == nil, "no list")
        let after = w.h.editor.document
        w.h.editor.undo()
        expectEqual(w.h.editor.document, start, "one Undo")
        expect(!w.h.editor.canUndo, "and one step")
        w.h.editor.redo()
        expectEqual(w.h.editor.document, after)
    },
    test("several fit: the list opens at the arrow, the arrow is selected, and the step is still Add Arrow; a pick is the step Add Type") {
        _ = NSApplication.shared
        let w = try Release()
        // A second relationship type with the same ends.
        let mentorship = ShapeID()
        var record = ShapeRecord(id: mentorship, Slab(CGRect(x: 800, y: 1000, width: 200, height: 200)))
        record[TitleProperty.self] = "Mentorship"
        record[TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter)
        record[RelationshipProperty.self] = true
        let made = AnyShapeRecord(record)
        w.h.editor.transact { transaction in
            transaction.insert(made)
            transaction.insert(AnyShapeRecord(ShapeRecord(Arrow(start: binding(w.person), end: binding(mentorship)))))
            transaction.insert(AnyShapeRecord(ShapeRecord(Arrow(start: binding(mentorship), end: binding(w.company)))))
        }
        w.h.editor.undoHistory.seal()
        w.drag(from: Release.annFrame, to: w.center(Release.acmeFrame))
        let drawn = try require(w.arrows.last { w.h.editor.relationships?.end($0.id) == nil })
        expectEqual(drawn[IsAProperty.self]?.map(\.shape) ?? [], [], "nothing given yet")
        expectEqual(w.h.editor.selectedShapeIDs, [drawn.id], "the arrow is selected while the list is open")
        let (menu, _) = try require(w.h.editor.menuToPopUp)
        expectEqual(menu.items.map { $0.isSeparatorItem ? "" : $0.title }, ["Employment", "Mentorship", "", "Plain arrow"])
        expect(w.h.editor.menuItemToHighlight === menu.items.first)
        expectEqual(w.h.editor.undoHistory.undoName, "Add Arrow")
        menu.performActionForItem(at: 1)
        expectEqual(w.h.editor.document[drawn.id]?[IsAProperty.self]?.map(\.shape), [mentorship])
        expectEqual(w.h.editor.undoHistory.undoName, "Add Type")
        w.h.editor.undo()
        expectEqual(w.h.editor.document[drawn.id]?[IsAProperty.self]?.map(\.shape) ?? [], [])
        expectEqual(w.h.editor.undoHistory.undoName, "Add Arrow", "and the next Undo takes the arrow")
    },
    test("none fits: the arrow stays plain, one step, no list; a drag from a type to a relationship type is an end and one step") {
        let w = try Release()
        w.drag(from: Release.annFrame, to: w.center(Release.annFrame.offsetBy(dx: 0, dy: 300)))   // onto nothing: nothing drawn
        expectEqual(w.arrows.count, 2)
        let beforeEnds = w.arrows.count
        let ann2 = ShapeID()
        w.h.editor.transact { $0.insert(AnyShapeRecord(ShapeRecord(id: ann2, Slab(CGRect(x: 80, y: 380, width: 200, height: 200))))) }
        w.h.editor.undoHistory.seal()
        w.drag(from: Release.annFrame, to: w.center(CGRect(x: 80, y: 380, width: 200, height: 200)))
        expectEqual(w.arrows.count, beforeEnds + 1)
        let plain = try require(w.arrows.last)
        expectEqual(plain[IsAProperty.self]?.map(\.shape) ?? [], [], "a Person note to a note of no type: plain")
        expect(w.h.editor.menuToPopUp == nil)
        expectEqual(w.h.editor.undoHistory.undoName, "Add Arrow")
        // A third end: Person to Employment, again.
        let before = w.arrows.count
        w.drag(from: Release.personFrame, to: w.center(Release.employmentFrame))
        expectEqual(w.arrows.count, before + 1)
        expect(w.h.editor.relationships?.end(try require(w.arrows.last).id) != nil)
        expectEqual(w.h.editor.undoHistory.undoName, "Add Arrow")
        expectEqual(w.h.editor.document.shapes.count, 5 + 2 + 3, "no relationship type made")
    },
    test("between two types: the arrow is replaced by a relationship type and two arrows in one step, New Relationship Type; the type is selected; one Undo returns the board") {
        let w = try Release()
        let start = w.h.editor.document
        w.h.editor.selection = w.ann
        let selected = w.h.editor.selectedShapeIDs
        w.h.editor.undoHistory.seal()
        w.drag(from: Release.personFrame, to: w.center(Release.companyFrame))
        let made = try require(w.h.editor.document.shapes.last { $0[RelationshipProperty.self] == true && $0.id != w.employment })
        expectEqual(w.h.editor.undoHistory.undoName, "New Relationship Type")
        expectEqual(w.h.editor.selectedShapeIDs, [made.id])
        expect(w.h.editor.editingShapeID == nil, "a slab has no editing view")
        expect(w.h.editor.card == nil, "and no card asks a name")
        expectEqual(w.arrows.count, 4, "the drag's arrow is gone, two new ones")
        let toIt = try require(w.arrows.first { $0.props.end.binding?.shapeID == made.id && $0.props.start.binding?.shapeID == w.person })
        let fromIt = try require(w.arrows.first { $0.props.start.binding?.shapeID == made.id && $0.props.end.binding?.shapeID == w.company })
        expect(toIt.props.endArrowhead && !toIt.props.startArrowhead, "one head")
        expect(fromIt.props.endArrowhead && !fromIt.props.startArrowhead)
        expectEqual(w.h.editor.undoHistory.undoName, "New Relationship Type")
        w.h.editor.undo()
        expectEqual(w.h.editor.document.shapes.map(\.id), start.shapes.map(\.id), "the board as it was")
        _ = selected
        w.h.editor.redo()
        expect(w.h.editor.document[made.id] != nil)
        expectEqual(w.arrows.count, 4)
    },
    test("released on nothing, or let go of with Escape: no step, nothing held, no end and nothing laid out") {
        let w = try Release()
        let heard = ReleaseHeard(w.h.editor)
        w.drag(from: Release.personFrame, to: w.center(Release.employmentFrame), release: false)
        let arrow = try require(w.arrows.last { w.h.editor.relationships?.end($0.id) == nil && $0.props.end.binding?.shapeID == w.employment }).id
        #if DEBUG
        expectEqual(w.h.editor.relationships?.heldConnections, [arrow], "a pass over a relationship type holds the arrow")
        #endif
        expect(heard.changes.isEmpty, "and names nothing: \(heard.changes.map(\.layout))")
        expectEqual(w.h.editor.relationships?.graph.sides(of: w.employment).from.count, 1, "the end drawn before is the only one")
        w.h.drag(to: CGPoint(x: 700, y: 1300), speed: fast)
        w.h.release()
        #if DEBUG
        expectEqual(w.h.editor.relationships?.heldConnections, [])
        #endif
        expectEqual(w.arrows.count, 2, "released on nothing: nothing drawn")
        expect(!w.h.editor.canUndo, "no step")
        w.drag(from: Release.personFrame, to: w.center(Release.employmentFrame), release: false)
        w.h.key("\u{1b}")
        w.h.release()
        #if DEBUG
        expectEqual(w.h.editor.relationships?.heldConnections, [])
        #endif
        expectEqual(w.arrows.count, 2)
        expect(!w.h.editor.canUndo)
        expect(heard.changes.allSatisfy { $0.layout.isEmpty }, "nothing laid out: \(heard.changes.map(\.layout))")
    },
    test("a drag from a type over a relationship type and released on it draws an end once: the instances are laid out at the release, not at the pass") {
        let w = try Release(ends: false)
        let heard = ReleaseHeard(w.h.editor)
        w.drag(from: Release.personFrame, to: w.center(Release.employmentFrame), release: false)
        expect(heard.changes.isEmpty, "nothing named while the drag is over it")
        w.h.release()
        let arrow = try require(w.arrows.last).id
        expectEqual(w.h.editor.relationships?.end(arrow)?.type, w.employment)
        expect(heard.changes.contains { $0.layout.contains(w.person) }, "Person's notes gain the row at the release")
        expectEqual(w.h.editor.undoHistory.undoName, "Add Arrow")
        w.h.editor.undo()
        expectEqual(w.arrows.count, 0)
        expectEqual(w.h.editor.relationships?.graph.sides(of: w.employment).isEmpty, true)
    },
    test("the arrow's row in the table of contents is titled by its relationship type: given at the release it reads Employment, a rename of the type renames it, and taken back it reads Arrow") {
        let w = try Release()
        let contents = try require(w.h.editor.tableOfContents)
        @MainActor func rowText(of arrow: ShapeID) -> String? {
            @MainActor func find(_ entries: [ContentsEntry]) -> ContentsEntry? {
                for entry in entries { if entry.id == arrow { return entry } else if let found = find(entry.children ?? []) { return found } }
                return nil
            }
            w.h.editor.selectedShapeIDs = []
            return find(contents.entries)?.label?.text
        }
        w.drag(from: Release.annFrame, to: w.center(Release.acmeFrame))
        let drawn = try require(w.arrows.last { w.h.editor.relationships?.end($0.id) == nil }).id
        expectEqual(rowText(of: drawn), "Employment")
        w.h.editor.transact("Rename") { $0.update(w.employment) { $0[TitleProperty.self] = "Job" } }
        expectEqual(rowText(of: drawn), "Job", "the type renamed")
        w.h.editor.transact("Rename") { $0.update(w.employment) { $0[TitleProperty.self] = nil } }
        expectEqual(rowText(of: drawn), "Arrow", "untitled: the arrow's own")
        w.h.editor.transact("Rename") { $0.update(w.employment) { $0[TitleProperty.self] = "Employment" } }
        expectEqual(rowText(of: drawn), "Employment")
        w.h.editor.removeTypeLink(w.employment, from: drawn)
        expectEqual(rowText(of: drawn), "Arrow", "taken back")
    },
    test("a re-aimed end is counted at its release, not at the hovers") {
        let w = try Release()
        let arrow = try require(w.arrows.first).id
        expectEqual(w.h.editor.relationships?.end(arrow)?.type, w.employment)
        let heard = ReleaseHeard(w.h.editor)
        w.h.editor.selection = arrow
        // The arrow runs from Person to Employment: its end handle is where its line meets Employment's pill.
        let geometry = try require(w.h.editor.arrowGeometry(of: arrow))
        let handle = w.h.editor.camera.toView(geometry.end)
        w.h.move(to: handle)
        w.h.press()
        w.h.drag(to: w.center(Release.companyFrame), speed: fast)
        expectEqual(w.h.editor.relationships?.end(arrow)?.type, w.employment, "still an end while the drag goes on")
        expect(heard.changes.isEmpty, "nothing named by the hovers")
        w.h.release()
        expect(w.h.editor.relationships?.end(arrow) == nil, "Person to Company is no end of Employment")
        expect(heard.changes.contains { $0.layout.contains(w.person) }, "Person's notes lose the row at the release")
    },
])

/// What the relationship index told, commit after commit.
@MainActor private final class ReleaseHeard {
    var changes: [RelationshipChange] = []
    init(_ editor: CanvasEditor) { editor.relationships?.onChange { [weak self] in self?.changes.append($0) } }
}
