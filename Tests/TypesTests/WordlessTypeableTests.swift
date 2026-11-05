@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import LanguageModels
import TestKit
import Topology
import Types
import Validation

// A kind that is `typeable(fillsFromWords: false)` and says no words (a frame, but for its kind): it takes a type, holds values the
// field writer sets, and no model is asked to fill them; and the rules of a relationship's ends are checked on it as on a note,
// though it draws no rows. Over a folio of the tests' own.

/// A box with nothing but its frame: no words, no rows.
private struct Folio: BoxShapeProps {
    static let kind: ShapeKind = "folio"
    static let properties = Properties<Folio>(title: "Folio") {
        Property("frame", \.frame).required()
    }
    var frame = CGRect(x: 0, y: 0, width: 200, height: 120)
    init() {}
    init(_ frame: CGRect) { self.frame = frame }
}

@MainActor private struct FolioDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Folio>, in context: RenderContext) {}
}

private struct FoliosPlugin: CanvasPlugin {
    var id: PluginID { "folios" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(FolioDefinition()) { folio in folio.typeable(fillsFromWords: false) }
    }
}

@MainActor private func addFolio(_ editor: CanvasEditor, of types: [ShapeID] = [], at origin: CGPoint = CGPoint(x: 40, y: 900)) -> ShapeID {
    var record = AnyShapeRecord(ShapeRecord(id: ShapeID(), Folio(CGRect(origin: origin, size: CGSize(width: 200, height: 120)))))
    if !types.isEmpty { record[IsAProperty.self] = types.map(TypeLink.init) }
    editor.transact { $0.insert(record) }
    return record.id
}

private let folioSchema = #"{"type": "object", "properties": {"purpose": {"type": "string"}}}"#
private let neededRule = EndRule(needed: true, onlyOne: false)
private let onlyOneRule = EndRule(needed: false, onlyOne: true)

@MainActor let wordlessTypeableTests = Suite("A typeable kind with no words", [
    test("it takes a type, holds values the field writer sets, and no model is asked to fill them") {
        let model = ScriptedLanguageModel()
        let h = try EditorHarness { scheduler in try typeEditor(scheduler: scheduler, model: model, more: [FoliosPlugin()]) }
        let editor = h.editor
        expectEqual(editor.registry.properties(for: Folio.kind).contains(AutofillProperty.key), false, "nothing to fill from")
        expect(editor.registry.isTypeable(Folio.kind))
        let type = editor.addType(folioSchema, title: "Project", at: CGPoint(x: 600, y: 40))
        let folio = addFolio(editor)
        editor.addTypeLink(type, to: folio)
        expectEqual(editor.typesOf(folio), [type])
        let writer = try require(editor.fieldWriter)
        expect(writer.set("ship it", at: FieldPath(field: "purpose"), of: folio))
        expectEqual(editor.document[folio]?[FieldValuesProperty.self]?["purpose"], "ship it")
        let fill = try require(editor.fieldFill)
        fill.editingDidEnd(folio, in: editor)
        h.scheduler.advance(by: .seconds(10))
        for _ in 0..<10 { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.002)) }
        expectEqual(model.requests.count, 0, "the model got no request")
        expectEqual(editor.document[folio]?[FieldValuesProperty.self]?["purpose"], "ship it", "and the value is the person's")
        editor.undo()
        expectEqual(editor.document[folio]?[FieldValuesProperty.self]?["purpose"], nil)
    },
    test("the rules of a relationship's ends are checked on it with no rows drawn: Needed is amber, Only one broken by two arrows is an error") {
        let editor = try bondEditor(more: [FoliosPlugin()])
        let feature = editor.addSlipType(folioSchema, words: "A feature", title: "Feature", at: CGPoint(x: 40, y: 40))
        let layer = editor.addSlipType(folioSchema, words: "A layer", title: "Layer", at: CGPoint(x: 440, y: 40))
        let rel = editor.addRelationshipType("in", at: CGPoint(x: 240, y: 40))
        let fromEnd = editor.addBond(feature, rel, name: "layer", rule: neededRule)
        editor.addBond(rel, layer)
        let folio = addFolio(editor, of: [feature])
        let one = editor.addSlip("Foundation", of: [layer], at: CGPoint(x: 440, y: 500))
        let two = editor.addSlip("Ground", of: [layer], at: CGPoint(x: 440, y: 700))
        expectEqual(editor.registry.typeRows(of: Folio.kind) == nil, true, "it draws no rows")
        let checks = try require(editor.fieldChecks)
        @MainActor func check() throws -> FieldCheck { checks.fullCheck(of: try require(editor.file.record(folio))) }
        expectEqual(try check().problems.map(\.message), ["layer is needed"])
        expectEqual(try check().problems.first?.kind, .needed)
        let amber = try check()
        expect(amber.isIncomplete && !amber.isWrong)
        expectEqual(editor.issues(folio).map(\.severity), [.incomplete])
        let first = editor.addBond(folio, one, of: [rel])
        expectEqual(try check().problems.map(\.message), [], "an arrow is the row's")
        editor.transact { $0.update(fromEnd) { $0[RelationshipEndProperty.self] = onlyOneRule } }
        expectEqual(try check().problems.map(\.message), [], "one is Only one")
        let second = editor.addBond(folio, two, of: [rel])
        expectEqual(try check().problems.map(\.message), ["layer has 2 notes, and should have at most 1"])
        expectEqual(try check().problems.first?.kind, .wrong)
        expectEqual(editor.issues(folio).map(\.severity), [.error])
        expectEqual(editor.issues(first) + editor.issues(second), [], "none on the arrows")
    },
])
