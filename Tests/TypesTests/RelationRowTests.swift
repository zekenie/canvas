@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Mentions
import TestKit
import Titles
import Topology
import Types

// The rows a relationship type's ends give: a note of a type at a drawn end shows a row for it, and so do both type
// notes, the moment the end is drawn and on every board, whatever any arrow is. Over slips (which show rows) and bonds
// (arrows of the tests' own); the shipped notes and arrows are StickyNotesTests'.

let featureRowsSchema = #"{"type": "object", "properties": {"purpose": {"type": "string"}}}"#
let layerRowsSchema = #"{"type": "object", "properties": {"order": {"type": "number"}, "purpose": {"type": "string"}, "title": {"type": "string"}}}"#

/// The room `count` rows take: with words over them or not, with the dashed line or not.
@MainActor func relationRowsHeight(_ count: Int, hasWords: Bool = true, rule: Bool = false) -> CGFloat {
    (hasWords ? TypesStyle.rowsLead : 0) + CGFloat(count) * TypesStyle.rowHeight + (rule ? TypesStyle.relationRuleHeight : 0)
}

private struct Failure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// A service ahead of Types that asks for a shape's frame as it hears each commit: the trap of a layout kept against what
/// Types has not yet heard.
@MainActor
private final class FrameProbe: EditorService {
    var watching: ShapeID?
    var frames: [CGRect?] = []
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        if let watching { frames.append(editor.frame(inFile: watching)) }
    }
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {}
}

private struct FrameProbePlugin: CanvasPlugin {
    let probe: FrameProbe
    var id: PluginID { "relation-frame-probe" }
    func register(into registrar: inout PluginRegistrar) {
        let probe = probe
        registrar.service { _ in probe }
    }
}

/// A Feature type, a Layer type and a relationship type `in`, on the root; a note of each; and a pocket holding a note of
/// each, so an end reaches a board that is not shown. No end is drawn.
@MainActor
struct RelationScene {
    let harness: EditorHarness
    let heard: RelationshipHeard
    let feature = ShapeID(), layer = ShapeID(), rel = ShapeID(), note = ShapeID(), layerNote = ShapeID()
    let pocket = ShapeID(), away = ShapeID(), awayLayer = ShapeID()
    var editor: CanvasEditor { harness.editor }
    var book: RowBook { editor.rowBook! }
    var index: RelationshipIndex { editor.relationships! }

    init(more: [any CanvasPlugin] = []) throws {
        var related = slipTypeRecord(TypeSchemaProperty.starter, title: "in", at: CGPoint(x: 240, y: 40), id: rel)
        related[RelationshipProperty.self] = true
        let file = CanvasFile(root: CanvasDocument(shapes: [
            slipTypeRecord(featureRowsSchema, words: "A feature", title: "Feature", at: CGPoint(x: 40, y: 40), id: feature),
            slipTypeRecord(layerRowsSchema, words: "A layer", title: "Layer", at: CGPoint(x: 440, y: 40), id: layer),
            related,
            slipRecord("Sign in", of: [feature], at: CGPoint(x: 40, y: 500), id: note),
            slipRecord("Foundation", of: [layer], at: CGPoint(x: 440, y: 500), id: layerNote),
            AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 0, y: 1200, width: 100, height: 100)))),
        ]), children: [pocket: CanvasDocument(shapes: [slipRecord("Away", of: [feature], at: .zero, id: away),
                                                       slipRecord("Down", of: [layer], at: CGPoint(x: 400, y: 0), id: awayLayer)])])
        harness = try EditorHarness { scheduler in try rowEditor(scheduler: scheduler, file: file, more: [BondsPlugin(), RelaysPlugin(), PocketsPlugin()] + more) }
        heard = RelationshipHeard(harness.editor)
        // The pocket's board is entered once, so what it holds is laid out where the editor keeps it.
        expect(editor.showBoard(BoardID(owner: pocket)))
        expect(editor.showBoard(.root))
    }

    /// The end at Feature: an arrow from Feature into the relationship type.
    @discardableResult
    func fromEnd(_ name: String = "") -> ShapeID { editor.addBond(feature, rel, name: name) }
    /// The end at Layer: an arrow out of the relationship type to Layer.
    @discardableResult
    func toEnd(_ name: String = "") -> ShapeID { editor.addBond(rel, layer, name: name) }

    /// A shape's laid-out height, on any board.
    func height(_ id: ShapeID) throws -> CGFloat { try require(editor.frame(inFile: id)).height }
    /// What a note stores and what its rows add to it.
    func stored(_ id: ShapeID) throws -> CGFloat { try require(editor.shape(inFile: id)?.box).height }

    func rows(_ id: ShapeID) -> [ShownRow] { book.rows(of: id) }
    func names(_ id: ShapeID) -> [String] { rows(id).map(\.name) }

    func row(_ id: ShapeID, _ name: String) throws -> ShownRow { try require(rows(id).first { $0.name == name }, "a row \(name) on \(rows(id).map(\.name))") }

    /// A note's values.
    func set(_ id: ShapeID, _ values: JSONObject) {
        editor.transact { $0.update(id) { $0[FieldValuesProperty.self] = FieldValues(values) } }
    }

    /// A relationship: an arrow between two notes, of the relationship type.
    @discardableResult
    func relate(_ from: ShapeID, _ to: ShapeID) -> ShapeID { editor.addBond(from, to, of: [rel]) }
}

@MainActor let relationRowTemplateTests = Suite("The rows a relationship type's ends give", [
    test("with no end drawn a note has its fields only, the first end gives the notes of its type a row at once and a dashed line before it, and the second gives the other type's") {
        let s = try RelationScene()
        expectEqual(s.names(s.note), ["purpose"])
        expectEqual(s.names(s.layerNote), ["order", "purpose", "title"])
        expectEqual(try s.height(s.note), try s.stored(s.note) + relationRowsHeight(1))
        s.fromEnd()
        expectEqual(s.names(s.note), ["purpose", "in"], "named for the relationship type while the other side has no type")
        expectEqual(try s.height(s.note), try s.stored(s.note) + relationRowsHeight(2, rule: true), "a row and the dashed line more")
        let purpose = try s.row(s.note, "purpose"), related = try s.row(s.note, "in")
        expectEqual(related.rect.minY - purpose.rect.maxY, TypesStyle.relationRuleHeight, "the dashed line takes eight points between the last field and the first relation row")
        expectEqual(s.names(s.layerNote), ["order", "purpose", "title"], "the other type has no end yet")
        s.toEnd()
        expectEqual(s.names(s.note), ["purpose", "in"], "a from end is named for the relationship type")
        expectEqual(s.names(s.layerNote), ["order", "purpose", "title", "feature"])
        expectEqual(try s.height(s.layerNote), try s.stored(s.layerNote) + relationRowsHeight(4, rule: true))
        expectEqual(try s.row(s.note, "in").content, .empty("add in"), "an empty row reads add and its name")
        expectEqual(try s.row(s.layerNote, "feature").content, .empty("add feature"))
        // Every instance on every board, and the two type notes.
        expectEqual(try s.height(s.away), try s.stored(s.away) + relationRowsHeight(2, rule: true), "on a board that is not shown")
        expectEqual(try s.height(s.awayLayer), try s.stored(s.awayLayer) + relationRowsHeight(4, rule: true))
        expectEqual(s.names(s.feature), ["purpose", "in"])
        expectEqual(s.names(s.layer), ["order", "purpose", "title", "feature"])
        expectEqual(try s.height(s.feature), try s.stored(s.feature) + relationRowsHeight(2, rule: true))
    },
    test("a type's note says the way each row runs and the types at the other end, and an open side is `any`") {
        let s = try RelationScene()
        s.fromEnd()
        expectEqual(try s.row(s.feature, "in").content, .relationType(direction: "→", chips: [], more: 0), "no type at the other end yet: any")
        s.toEnd()
        expectEqual(try s.row(s.feature, "in").content, .relationType(direction: "→", chips: [s.layer], more: 0))
        expectEqual(try s.row(s.layer, "feature").content, .relationType(direction: "←", chips: [s.feature], more: 0))
        // Four more types at the to side: two chips and a count.
        let others = (1...4).map { s.editor.addSlipType(featureRowsSchema, title: "Other \($0)", at: CGPoint(x: 40, y: 2000 + 300 * Double($0))) }
        for other in others { s.editor.addBond(s.rel, other) }
        expectEqual(try s.row(s.feature, "in").content, .relationType(direction: "→", chips: [s.layer, others[0]], more: 3), "several types: named for the relationship type")
    },
    test("a type related to itself is one row for both its ends, and `↔`") {
        let s = try RelationScene()
        let friendship = s.editor.addRelationshipType("Friendship", at: CGPoint(x: 240, y: 300))
        s.editor.addBond(s.feature, friendship)
        s.editor.addBond(friendship, s.feature)
        expectEqual(try s.row(s.feature, "friendship").content, .relationType(direction: "↔", chips: [s.feature], more: 0))
        expectEqual(s.names(s.note), ["purpose", "friendship"], "a type related to itself, unnamed on both sides: the relationship type's name")
    },
    test("a typed name is shown as typed, and the later of two relationship types' rows of one name says whose it is") {
        let s = try RelationScene()
        s.fromEnd("Employer")
        expectEqual(s.names(s.note), ["purpose", "Employer"], "as typed")
        s.toEnd()
        let contract = s.editor.addRelationshipType("Contract", at: CGPoint(x: 240, y: 300))
        s.editor.addBond(s.feature, contract)
        s.editor.addBond(contract, s.layer)
        expectEqual(s.names(s.note), ["purpose", "Employer", "contract"])
        let other = s.editor.addRelationshipType("Contract", at: CGPoint(x: 240, y: 600))
        s.editor.addBond(s.feature, other)
        s.editor.addBond(other, s.layer)
        expectEqual(s.names(s.note), ["purpose", "Employer", "contract", "contract · Contract"])
        s.editor.undo()
        s.editor.undo()
        expectEqual(s.names(s.note), ["purpose", "Employer", "contract"])
        // A rename of the relationship type renames the rows derived from it, and no typed one.
        s.editor.transact("Rename") { $0.update(contract) { $0[TitleProperty.self] = "Deal" } }
        expectEqual(s.names(s.note), ["purpose", "Employer", "deal"])
    },
    test("a relationship type with no title is `untitled`, and an end that names no type at the other end is named for it") {
        let s = try RelationScene()
        let plain = s.editor.addRelationshipType(nil, at: CGPoint(x: 240, y: 300))
        s.editor.addBond(s.feature, plain)
        expectEqual(s.names(s.note), ["purpose", "untitled"])
    },
    test("a relationship type's own note has no relation rows, and neither has a note that is one") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        expectEqual(s.rows(s.rel).count, 0, "the relationship type's note: its ends are its arrows")
        let instance = s.editor.addSlip("Of in", of: [s.rel], at: CGPoint(x: 700, y: 500))
        expectEqual(s.rows(instance).count, 0)
        expectEqual(try s.book.extent(of: require(s.editor.document[instance])), nil)
        // An arrow between the types themselves is no end.
        let between = s.editor.addBond(s.feature, s.layer)
        expect(s.index.end(between) == nil)
    },
    test("a type that builds on another has its rows after its own, faint with the tick, and so have its notes") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        let task = s.editor.addSlipType(featureRowsSchema, words: "A task", title: "Task", at: CGPoint(x: 40, y: 900))
        s.editor.addTypeLink(s.feature, to: task)
        let inherited = try s.row(task, "in")
        expect(inherited.isFaint && inherited.tick == s.feature, "the row Feature gives, ticked in its color")
        expectEqual(inherited.content, .relationType(direction: "→", chips: [s.layer], more: 0))
        let own = try s.row(s.feature, "in")
        expect(!own.isFaint && own.tick == nil)
        let taskNote = s.editor.addSlip("A task", of: [task], at: CGPoint(x: 700, y: 900))
        expectEqual(s.names(taskNote), ["purpose", "in"], "the note of a type that builds on Feature has Feature's row")
    },
    test("a note with fields and no relation rows has no dashed line, and a note with relation rows only has none either") {
        let s = try RelationScene()
        let bare = s.editor.addSlipType(TypeSchemaProperty.starter, words: "No fields", title: "Bare", at: CGPoint(x: 700, y: 40))
        let bareNote = s.editor.addSlip("Bare", of: [bare], at: CGPoint(x: 700, y: 500))
        s.editor.addBond(bare, s.rel)
        expectEqual(s.names(bareNote), ["in"])
        expectEqual(try s.height(bareNote), try s.stored(bareNote) + relationRowsHeight(1), "a row and no line: the hairline opens the rows")
        expectEqual(s.names(bare), ["in"], "a type with no fields shows its relation rows, not `No fields`")
        expectEqual(try s.height(bare), try s.stored(bare) + relationRowsHeight(1))
        expectEqual(s.book.spot(of: bare), .rows)
    },
])

@MainActor let relationRowBookTests = Suite("Relation rows kept and announced", [
    test("a note's height is a function of its types and the drawn ends: drawing and deleting a relationship changes no height, lays out nothing, and lets go of the two notes' rows only") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        let third = s.editor.addSlip("Other", of: [s.feature], at: CGPoint(x: 800, y: 500))
        let otherLayer = s.editor.addSlip("Another", of: [s.layer], at: CGPoint(x: 1200, y: 500))
        let notes = [s.note, s.layerNote, third, otherLayer]
        let ids = notes + [s.feature, s.layer]
        for id in notes { _ = s.rows(id) }
        let heights = try ids.map { try s.height($0) }
        let layout = s.editor.layoutRevision, rowsShown = s.book.rowsShown
        let relation = s.relate(s.note, s.layerNote)
        expectEqual(try ids.map { try s.height($0) }, heights, "drawn")
        expectEqual(s.editor.layoutRevision, layout, "and no layout announced for it")
        expect(s.heard.last?.layout.isEmpty == true && s.heard.last?.notes.isSuperset(of: [s.note, s.layerNote]) == true, "\(String(describing: s.heard.last))")
        for id in notes { _ = s.rows(id) }
        expectEqual(s.book.rowsShown - rowsShown, 2, "the two notes' rows were built again, no others")
        guard case .related(let pills, 0) = try s.row(s.note, "in").content else { throw Failure("a pill") }
        expectEqual(pills.map(\.target), [s.layerNote])
        // Deleted, undone, redone: the same.
        let shown = s.book.rowsShown
        s.editor.transact("Delete") { $0.delete([relation]) }
        expectEqual(try ids.map { try s.height($0) }, heights, "deleted")
        expectEqual(s.editor.layoutRevision, layout)
        for id in notes { _ = s.rows(id) }
        expectEqual(s.book.rowsShown - shown, 2)
        expectEqual(try s.row(s.note, "in").content, .empty("add in"))
        s.editor.undo()
        expectEqual(try ids.map { try s.height($0) }, heights, "and back")
        // Re-aimed at another note of the type.
        s.editor.transact("Re-aim") { $0.update(relation, as: Bond.self) { $0.props.to = otherLayer } }
        expectEqual(try ids.map { try s.height($0) }, heights, "re-aimed")
        expectEqual(s.editor.layoutRevision, layout)
        guard case .related(let aimed, 0) = try s.row(s.note, "in").content else { throw Failure("a pill") }
        expectEqual(aimed.map(\.target), [otherLayer])
        expectEqual(try s.row(s.layerNote, "feature").content, .empty("add feature"), "the note it left shows nothing")
    },
    test("an end drawn lays out every note of its type on every board, and both type notes, and not the others; deleting it and undo do the same") {
        let s = try RelationScene()
        let unrelated = s.editor.addSlip("Not a feature", of: [], at: CGPoint(x: 900, y: 500))
        let layerHeights = try [s.layerNote, s.awayLayer].map { try s.height($0) }
        let before = try [s.note, s.away, s.feature].map { try s.height($0) }
        let unrelatedFrame = s.editor.laidOut(unrelated)
        let end = s.fromEnd()
        let rise = relationRowsHeight(2, rule: true) - relationRowsHeight(1)
        expectEqual(try [s.note, s.away, s.feature].map { try s.height($0) }, before.map { $0 + rise }, "Feature's notes, near, far, and its own note")
        expectEqual(try [s.layerNote, s.awayLayer].map { try s.height($0) }, layerHeights, "Layer has no end yet")
        expectEqual(s.editor.laidOut(unrelated), unrelatedFrame)
        expect(s.heard.last?.layout.contains(s.feature) == true)
        s.editor.transact("Delete") { $0.delete([end]) }
        expectEqual(try [s.note, s.away, s.feature].map { try s.height($0) }, before, "deleted: the rows go with the end")
        s.editor.undo()
        expectEqual(try [s.note, s.away, s.feature].map { try s.height($0) }, before.map { $0 + rise })
        s.editor.undo()
        expectEqual(try [s.note, s.away, s.feature].map { try s.height($0) }, before, "undone")
        // The second end changes the first row's name and not any height.
        s.fromEnd()
        let heights = try [s.note, s.away, s.feature].map { try s.height($0) }
        let layout = s.editor.layoutRevision
        s.toEnd()
        expectEqual(try [s.note, s.away, s.feature].map { try s.height($0) }, heights, "a row that was there is renamed, not added")
        expectEqual(s.names(s.note), ["purpose", "in"])
        expectEqual(try s.height(s.awayLayer), try s.stored(s.awayLayer) + relationRowsHeight(4, rule: true))
        expect(s.editor.layoutRevision > layout, "Layer's notes were laid out")
    },
    test("an end's name renames the row on every note of the type with no layout and no row built for a note nobody reads; a type's rename renames the derived rows") {
        let s = try RelationScene()
        let end = s.fromEnd()
        s.toEnd()
        s.editor.addSlip("Nobody reads it", of: [s.feature], at: CGPoint(x: 900, y: 500))
        _ = s.rows(s.note)
        let layout = s.editor.layoutRevision, built = s.book.rowsShown
        s.editor.transact("Name") { $0.update(end, as: Bond.self) { $0.props.text = MentionText(plain: "layers") } }
        expectEqual(s.book.rowsShown, built, "no row is built by the rename")
        expectEqual(s.names(s.note), ["purpose", "layers"])
        expectEqual(s.book.rowsShown - built, 1, "only the note that is read has its rows built")
        expectEqual(s.editor.layoutRevision, layout, "no layout")
        expect(s.heard.last?.rows == true && s.heard.last?.layout.isEmpty == true)
        s.editor.transact("Rename") { $0.update(s.feature) { $0[TitleProperty.self] = "Story" } }
        expectEqual(try s.row(s.layerNote, "story").name, "story")
        expectEqual(s.editor.layoutRevision, layout, "a rename moves no size")
    },
    test("a mark flip lays out what it must: unmarking the relationship type takes the rows from every note, and undo gives them back") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        let with = try [s.note, s.layerNote, s.away, s.awayLayer, s.feature, s.layer].map { try s.height($0) }
        s.editor.transact("Unmark") { $0.update(s.rel) { $0[RelationshipProperty.self] = nil } }
        let without = try [s.note, s.layerNote, s.away, s.awayLayer, s.feature, s.layer].map { try s.height($0) }
        expect(zip(with, without).allSatisfy { $0 > $1 }, "every one is shorter: \(with) \(without)")
        expectEqual(s.names(s.note), ["purpose"])
        s.editor.undo()
        expectEqual(try [s.note, s.layerNote, s.away, s.awayLayer, s.feature, s.layer].map { try s.height($0) }, with)
        expectEqual(s.names(s.note), ["purpose", "in"])
        // Deleted outright and brought back.
        s.editor.transact("Delete") { $0.delete([s.rel]) }
        expectEqual(s.names(s.note), ["purpose"])
        s.editor.undo()
        expectEqual(s.names(s.note), ["purpose", "in"])
    },
    test("a lineage edit lays out what it must: a type that starts to build on Feature gains its rows, with its notes near and far, and undo takes them away") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        let task = s.editor.addSlipType(featureRowsSchema, words: "A task", title: "Task", at: CGPoint(x: 40, y: 900))
        let taskNote = s.editor.addSlip("A task", of: [task], at: CGPoint(x: 700, y: 900))
        expectEqual(s.names(taskNote), ["purpose"])
        let before = try s.height(taskNote)
        s.editor.addTypeLink(s.feature, to: task)
        expectEqual(s.names(taskNote), ["purpose", "in"])
        expectEqual(try s.height(taskNote), before + TypesStyle.rowHeight + TypesStyle.relationRuleHeight)
        expectEqual(s.names(task), ["purpose", "in"])
        s.editor.undo()
        expectEqual(s.names(taskNote), ["purpose"])
        expectEqual(try s.height(taskNote), before)
        expectEqual(s.names(task), ["purpose"])
    },
    test("one template for a list however many notes ask, made again when the ends change and not when an arrow is drawn") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        let notes = (0..<10).map { s.editor.addSlip("Of feature \($0)", of: [s.feature], at: CGPoint(x: 400 * Double($0), y: 1500)) }
        let records = try notes.map { try require(s.editor.document[$0]) }
        _ = s.book.extent(of: records[0])
        #if DEBUG
        let made = s.book.templatesMade
        #endif
        for ask in 0..<1_000 { expectEqual(s.book.extent(of: records[ask % 10])?.height, relationRowsHeight(2, rule: true), "ask \(ask)") }
        s.relate(notes[0], s.layerNote)
        for record in records { _ = s.book.extent(of: record) }
        #if DEBUG
        expectEqual(s.book.templatesMade, made, "a relationship drawn makes no template again")
        #endif
        s.fromEnd("again")
        for record in records { _ = s.book.extent(of: record) }
        #if DEBUG
        expect(s.book.templatesMade > made, "an end drawn does")
        #endif
    },
    test("a drag lets go of nothing, and a file with no relationship type makes one template for its one list") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        _ = s.rows(s.note)
        let built = s.book.rowsShown
        s.editor.transact("Move") { $0.translate([s.note], by: CGPoint(x: 100, y: 50)) }
        _ = s.rows(s.note)
        expectEqual(s.book.rowsShown, built, "a move builds no rows again")
        // A file with a type and a note and no relationship type.
        let idle = try rowEditor()
        let type = idle.addSlipType(featureRowsSchema, title: "Feature")
        let instance = idle.addSlip("A", of: [type])
        let plain = idle.addSlip("Plain")
        let book = try require(idle.rowBook)
        #if DEBUG
        let made = book.templatesMade
        #endif
        expectEqual(book.extent(of: try require(idle.document[instance]))?.height, relationRowsHeight(1))
        expectEqual(book.extent(of: try require(idle.document[plain])), nil)
        expectEqual(book.rows(of: instance).map(\.name), ["purpose"])
        #if DEBUG
        expectEqual(book.templatesMade - made, 1, "one template, for the one list")
        #endif
    },
    test("a service ahead of Types that asks for a note's frame as it hears the commit that draws an end still sees the right frame at the next read") {
        let probe = FrameProbe()
        let file = CanvasFile(root: CanvasDocument())
        let registry = try Registry(plugins: [FrameProbePlugin(probe: probe)] + typePlugins() + [RowSlipsPlugin(), BondsPlugin(), PocketsPlugin()])
        let editor = CanvasEditor(registry: registry, file: file, scheduler: ManualScheduler())
        let feature = editor.addSlipType(featureRowsSchema, words: "A feature", title: "Feature")
        let rel = editor.addRelationshipType("in")
        let note = editor.addSlip("Sign in", of: [feature])
        let one = try require(editor.laidOut(note)).height
        probe.watching = note
        editor.addBond(feature, rel)
        expect(!probe.frames.isEmpty, "the probe asked as it heard the commit")
        expectEqual(editor.laidOut(note)?.height, one + TypesStyle.rowHeight + TypesStyle.relationRuleHeight, "the next read is the new frame")
        expectEqual(editor.frame(inFile: note)?.height, one + TypesStyle.rowHeight + TypesStyle.relationRuleHeight)
    },
    test("a type, an end and an instance written together: the instance is sized with the new row in the transaction, as it is after the commit") {
        let editor = try bondEditor()
        let type = slipTypeRecord(featureRowsSchema, words: "A feature", title: "Feature")
        var related = slipTypeRecord(TypeSchemaProperty.starter, title: "in", at: CGPoint(x: 300, y: 40))
        related[RelationshipProperty.self] = true
        let instance = slipRecord("Sign in", of: [type.id])
        let end = AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: type.id, to: related.id)))
        var inside: CGRect?
        editor.transact { transaction in
            transaction.insert(type)
            transaction.insert(related)
            transaction.insert(instance)
            transaction.insert(end)
            inside = transaction.shapes.frame(of: instance.id)
        }
        let stored = try require(editor.document[instance.id]?.box).height
        // The run's own graph (`graph(in: reading)`) holds the end the transaction wrote, so the row is there before the commit.
        expectEqual(inside?.height, stored + relationRowsHeight(2, rule: true), "the run's own ends: the new one is in them")
        expectEqual(editor.laidOut(instance.id)?.height, stored + relationRowsHeight(2, rule: true), "after the commit, laid out by the announcement")
    },
])
