import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Connections
import ContextMenus
import Foundation
import Geometry
import LanguageModels
import Mentions
import Selection
import ShippedTesting
import StickyNotes
import TestKit
import Titles
import Types

// Board 6 of the relationships wireframes, "Words", on the shipped list with real notes: a Feature type whose words say it
// "is in a" Layer, the Layer type mentioned there as a pill. The model writes fields only (`purpose`, never a `layer`); a
// click on the pill offers `Relate to Layer`, and choosing it puts a relationship type between the two in one step, writing
// neither type's words nor schema and asking the model nothing. Once related (or when the type embeds Layer) the pill is
// Mentions' again, which begins editing. Acceptance steps W1 to W10 of the design. (The offer's cases are TypesTests'.)

private let purposeOnly = #"{"type": "object", "properties": {"purpose": {"type": "string"}}}"#

/// The words of the Feature type: `prefix`, a mention of the Layer type, and a full stop.
private func feature(_ layer: ShapeID, _ prefix: String = "A feature has a purpose and is in a ") -> MentionText {
    MentionText([.text(prefix), .mention(layer, label: "Layer"), .text(".")])
}

/// Answers the sync's requests in turn and the highlights' with a failure, so a request for highlights (a type drawn in full is
/// asked about, once, as it comes into step) never takes the answer meant for the sync.
@MainActor
final class SyncAnswers {
    var queued: [String] = []

    init(_ model: ScriptedLanguageModel) {
        model.fallback = { [unowned self] request in
            if request.messages.first?.text.hasPrefix("<prose>") == true { return .failure(.server(status: 0, message: "no highlights in this test")) }
            guard !queued.isEmpty else { return .failure(.server(status: 0, message: "no answer queued")) }
            return .success(ModelResponse(text: queued.removeFirst()))
        }
    }
}

extension Minute {
    /// The person writing the Feature type's words.
    func say(_ words: MentionText) {
        editor.transact("Typing") { $0.update(feature, as: StickyNote.self) { $0.props.text = words } }
    }

    /// What the sync asked the model: every request but the highlights'.
    var asks: [ModelRequest] { model.requests.filter { $0.messages.first?.text.hasPrefix("<prose>") != true } }

    /// Advances past the idle delay and waits for the one answer to land.
    func sync(_ answers: SyncAnswers, answer: String) throws {
        answers.queued.append(answer)
        let asked = asks.count
        h.scheduler.advance(by: TypeSync<TypeSchemaProperty>.idleDelay)
        expect(spinRunLoop(until: { self.asks.count > asked && self.editor.typeSync?.status(of: self.feature) == .idle }), "the call landed")
    }

    /// Where the Feature type's first pill is, in view points.
    func pill() throws -> CGPoint {
        let frame = try require(editor.mentionPills(of: feature).first?.frame, "a pill in the words")
        return h.view(CGPoint(x: frame.midX, y: frame.midY))
    }

    var featureSchema: String { editor.schemaText(feature) ?? "" }
    var words: MentionText? { editor.document[feature]?.typed(as: StickyNote.self)?.props.text }
}

@MainActor let relateWordsShippedTests = Suite("Words never draw, and one click does, shipped", [
    test("board 6, W1 to W9: the model writes fields only; the pill offers Relate to Layer on a click and keeps its hover; choosing it makes the relationship type between the two in one step with the model not asked; the pill is Mentions' again; one Undo and Redo; edits of either side leave it alone; deleting the relationship type brings the offer back") {
        let m = try Minute()
        defer { m.close() }
        let editor = m.editor
        let answers = SyncAnswers(m.model)
        // W1: the words say "is in a" and mention Layer; three seconds later one request, with Layer in <schemas>.
        m.say(feature(m.layer))
        try m.sync(answers, answer: purposeOnly)
        expectEqual(m.asks.count, 1)
        let request = try require(m.asks.first)
        expect(request.messages.first?.text.hasPrefix("<schemas>\n@Layer\n</schemas>") == true, "\(request.messages.first?.text ?? "")")
        expect(request.system?.contains(SchemaPrompts.toSchemaReferences) == true, "the references literal is sent")
        expect(m.featureSchema.contains("\"purpose\"") && !m.featureSchema.contains("$ref") && !m.featureSchema.contains("urn:uuid:"), "purpose only: \(m.featureSchema)")
        expect(m.words?.runs.contains(.mention(m.layer, label: "Layer")) == true, "the words keep the mention")
        expectEqual(m.names(of: m.featureNote), ["purpose"], "Feature shows the row purpose and nothing under a dashed line")
        expect(m.arrows.isEmpty && editor.document.shapes.filter { $0[RelationshipProperty.self] == true }.isEmpty, "no arrow, no relationship type")
        editor.selectedShapeIDs = [m.feature]
        editor.undoHistory.seal()
        let atPill = editor.document
        // W2: the pointer over the pill outlines Layer; nothing is edited.
        m.h.move(to: try m.pill())
        expectEqual(editor.hovered, m.layer)
        expect(editor.editingShapeID == nil)
        // W3: a click: the note is not being edited; one menu waits with one item.
        m.h.click()
        expect(editor.editingShapeID == nil, "not being edited")
        let queued = try require(editor.menuToPopUp, "a menu waits")
        expectEqual(queued.menu.items.map(\.title), ["Relate to Layer"])
        // W4: pick it.
        let known = Set(editor.document.shapes.map(\.id))
        let featureType = editor.document[m.feature], layerType = editor.document[m.layer]
        try queued.menu.choose("Relate to Layer")
        editor.menuDidPopUp()
        let added = editor.document.shapes.filter { !known.contains($0.id) }
        expectEqual(added.count, 3, "a relationship type and its two arrows: \(added.map(\.kind))")
        let made = try require(added.first { $0[RelationshipProperty.self] == true }).id
        let box = try m.frame(made)
        let featureBox = try m.frame(m.feature), layerBox = try m.frame(m.layer)
        expect(!box.intersects(featureBox) && !box.intersects(layerBox), "overlapping neither: \(box)")
        let toIt = try require(m.arrows.first { $0.props.start.binding?.shapeID == m.feature && $0.props.end.binding?.shapeID == made })
        let fromIt = try require(m.arrows.first { $0.props.start.binding?.shapeID == made && $0.props.end.binding?.shapeID == m.layer })
        expect(toIt.props.endArrowhead && fromIt.props.endArrowhead, "one head each")
        expectEqual(editor.document[m.feature], featureType, "Feature's words and schema")
        expectEqual(editor.document[m.layer], layerType)
        expectEqual(editor.selectedShapeIDs, [made], "the relationship type is selected")
        expectEqual(editor.undoHistory.undoName, TypesStyle.newRelationshipType)
        expectEqual(m.asks.count, 1, "the scripted model's request count is still 1")
        editor.closeCard()
        // W5: the rows; a second click on the pill is Mentions' (it begins editing at the pill).
        expectEqual(m.rows.rows(of: m.feature).last?.content, .relationType(direction: "→", chips: [m.layer], more: 0))
        expectEqual(m.rows.rows(of: m.layer).last?.content, .relationType(direction: "←", chips: [m.feature], more: 0))
        expectEqual(m.names(of: m.featureNote), ["purpose", "layer"])
        editor.selectedShapeIDs = [m.feature]
        m.h.click(at: try m.pill())
        expect(editor.menuToPopUp == nil, "the offer stopped: no menu waits")
        expectEqual(editor.editingShapeID, m.feature, "and editing begins at the pill")
        editor.endEditing(discarding: false)
        // W6: Undo, then Redo.
        let related = editor.document
        editor.undo()
        expectEqual(editor.document, atPill, "the board as at the pill")
        editor.selectedShapeIDs = [m.feature]
        m.h.click(at: try m.pill())
        expectEqual(editor.menuToPopUp?.menu.items.map(\.title), ["Relate to Layer"], "the offer is back")
        editor.menuDidPopUp()
        editor.redo()
        expectEqual(editor.document.shapes.map(\.id), related.shapes.map(\.id), "Redo returns the three shapes")
        expectEqual(editor.document[made]?.typed(as: StickyNote.self) != nil, true)
        // W7: edit Feature's words; the second request is a to-schema one adding priority; no layer property; the mention stays.
        m.say(feature(m.layer, "A feature has a purpose and a priority and is in a "))
        try m.sync(answers, answer: #"{"type": "object", "properties": {"purpose": {"type": "string"}, "priority": {"type": "integer"}}}"#)
        expectEqual(m.asks.count, 2)
        expect(m.asks[1].messages.first?.text.hasPrefix("<schemas>") == true)
        expect(m.featureSchema.contains("\"priority\"") && !m.featureSchema.lowercased().contains("layer") && !m.featureSchema.contains("$ref"), m.featureSchema)
        expect(m.words?.runs.contains(.mention(m.layer, label: "Layer")) == true, "the mention is still a mention")
        // W8: a hand edit of the JSON; a to-words request whose answer returns the words with the pill.
        editor.transact("Typing") {
            $0.update(m.feature) {
                $0[TypeSchemaProperty.self] = SchemaText(#"{"type": "object", "properties": {"purpose": {"type": "string"}, "priority": {"type": "integer"}, "owner": {"type": "string"}}}"#)
            }
        }
        try m.sync(answers, answer: "A feature has a purpose, a priority and an owner, and is in a @Layer.")
        expectEqual(m.asks.count, 3)
        let words = try require(m.words)
        expect(words.runs.contains(.mention(m.layer, label: "Layer")), "the words hold the mention: \(words.runs)")
        expect(words.stored.contains("is in a"), words.stored)
        expect(!m.featureSchema.lowercased().contains("layer"), "still no layer property")
        // W9: delete the relationship type: the offer is back on the pill.
        editor.transact("Delete") { $0.delete([made]) }
        editor.selectedShapeIDs = [m.feature]
        m.h.click(at: try m.pill())
        expectEqual(editor.menuToPopUp?.menu.items.map(\.title), ["Relate to Layer"], "the offer is back")
        editor.menuDidPopUp()
        // A pill in a note that is no type is Mentions' as ever: editing begins at it.
        editor.transact("Typing") { $0.update(m.featureNote, as: StickyNote.self) { $0.props.text = MentionText([.text("in a "), .mention(m.layer, label: "Layer")]) } }
        editor.selectedShapeIDs = [m.featureNote]
        let notePill = try require(editor.mentionPills(of: m.featureNote).first?.frame)
        m.h.click(at: m.h.view(CGPoint(x: notePill.midX, y: notePill.midY)))
        expect(editor.menuToPopUp == nil, "no menu on a note that is no type")
        expectEqual(editor.editingShapeID, m.featureNote, "its pill begins editing, as before")
        editor.endEditing(discarding: false)
    },
    test("board 6, W10: words that say the type holds Layer (\"its\"), the model embeds it: the schema holds a $ref to Layer, so the pill is not offered and a click on it begins editing") {
        let m = try Minute()
        defer { m.close() }
        let editor = m.editor
        let answers = SyncAnswers(m.model)
        m.say(feature(m.layer, "A feature has a purpose and its "))
        try m.sync(answers, answer: #"{"type": "object", "properties": {"purpose": {"type": "string"}, "layer": {"$ref": "@Layer"}}}"#)
        expect(m.featureSchema.contains("$ref") && m.featureSchema.contains(SchemaReferences.uri(of: m.layer)), m.featureSchema)
        editor.selectedShapeIDs = [m.feature]
        let before = editor.document
        m.h.click(at: try m.pill())
        expect(editor.menuToPopUp == nil, "the schema holds a $ref to Layer: nothing is offered")
        expectEqual(editor.editingShapeID, m.feature, "the pill is Mentions': it begins editing")
        editor.endEditing(discarding: false)
        expectEqual(editor.document, before, "nothing else changes")
        expectEqual(m.asks.count, 1)
    },
])
